insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'branch-supplier-receiving-photos',
  'branch-supplier-receiving-photos',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public=false,
  file_size_limit=5242880,
  allowed_mime_types=array['image/jpeg','image/png','image/webp'];

create table if not exists public.branch_supplier_receivings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  supervisor_team_id uuid not null references public.branch_supervisor_teams(id) on delete restrict,
  category text not null,
  supplier_name_en text not null,
  supplier_name_ar text null,
  quantity numeric not null,
  unit text not null,
  notes text null,
  photo_storage_path text null,
  photo_original_name text null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_supplier_receivings_category_check check (category in ('raw','frozen','juice')),
  constraint branch_supplier_receivings_quantity_check check (quantity > 0),
  constraint branch_supplier_receivings_supplier_en_check check (supplier_name_en = pg_catalog.btrim(supplier_name_en) and length(supplier_name_en) between 1 and 120),
  constraint branch_supplier_receivings_supplier_ar_check check (supplier_name_ar is null or (supplier_name_ar = pg_catalog.btrim(supplier_name_ar) and length(supplier_name_ar) between 1 and 120)),
  constraint branch_supplier_receivings_unit_check check (unit = pg_catalog.btrim(unit) and length(unit) between 1 and 40),
  constraint branch_supplier_receivings_notes_check check (notes is null or (notes = pg_catalog.btrim(notes) and length(notes) between 1 and 2000)),
  constraint branch_supplier_receivings_photo_name_check check (photo_original_name is null or (photo_original_name = pg_catalog.btrim(photo_original_name) and length(photo_original_name) between 1 and 180)),
  constraint branch_supplier_receivings_photo_path_check check (photo_storage_path is null or photo_storage_path ~ '^branches/[0-9a-fA-F-]{36}/supplier-receivings/[0-9a-fA-F-]{36}/[^/]{1,180}$')
);

create index if not exists branch_supplier_receivings_team_created_idx on public.branch_supplier_receivings(supervisor_team_id, created_at desc);
create index if not exists branch_supplier_receivings_branch_created_idx on public.branch_supplier_receivings(branch_id, created_at desc);

drop trigger if exists branch_supplier_receivings_set_updated_at on public.branch_supplier_receivings;
create trigger branch_supplier_receivings_set_updated_at
before update on public.branch_supplier_receivings
for each row execute function private.set_updated_at();

alter table public.branch_supplier_receivings enable row level security;
revoke all on table public.branch_supplier_receivings from public, anon, authenticated, service_role;
grant select on table public.branch_supplier_receivings to authenticated;

create or replace function private.require_supervisor_supplier_receiving_team(actor_user_id uuid, target_branch_id uuid)
returns public.branch_supervisor_teams
language plpgsql
security definer
set search_path=public, private
as $$
declare target_team public.branch_supervisor_teams%rowtype;
begin
  select team.* into target_team
  from public.branch_supervisor_teams team
  where team.branch_id = target_branch_id
    and team.supervisor_user_id = actor_user_id
    and team.active
  order by team.created_at desc
  limit 1;
  if target_team.id is null or not private.actor_owns_operational_team(actor_user_id, target_branch_id, target_team.id) then
    raise exception 'supplier receiving access denied' using errcode='42501';
  end if;
  return target_team;
end;
$$;

create or replace function private.clean_supplier_receiving_text(value text, fallback text default null, max_length integer default 120)
returns text
language plpgsql
immutable
as $$
declare cleaned text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(value,'')), '[[:space:]]+', ' ', 'g'), '');
begin
  cleaned := coalesce(cleaned, fallback);
  if cleaned is null then return null; end if;
  if length(cleaned) > max_length then
    raise exception 'invalid supplier receiving text' using errcode='22023';
  end if;
  return cleaned;
end;
$$;

create or replace function public.list_branch_supplier_receivings(actor_user_id uuid, target_branch_id uuid)
returns table(
  id uuid,
  branch_id uuid,
  branch_name text,
  category text,
  supplier_name_en text,
  supplier_name_ar text,
  quantity numeric,
  unit text,
  notes text,
  photo_storage_path text,
  photo_original_name text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=public, private
as $$
declare target_team public.branch_supervisor_teams%rowtype;
begin
  target_team := private.require_supervisor_supplier_receiving_team(actor_user_id, target_branch_id);
  return query
  select receiving.id, receiving.branch_id, branch.name, receiving.category, receiving.supplier_name_en,
    receiving.supplier_name_ar, receiving.quantity, receiving.unit, receiving.notes,
    receiving.photo_storage_path, receiving.photo_original_name, receiving.created_by,
    receiving.created_at, receiving.updated_at
  from public.branch_supplier_receivings receiving
  join public.branches branch on branch.id = receiving.branch_id
  where receiving.supervisor_team_id = target_team.id
  order by receiving.created_at desc;
end;
$$;

create or replace function public.create_branch_supplier_receiving(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns setof public.branch_supplier_receivings
language plpgsql
security definer
set search_path=public, private
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  clean_category text := payload->>'category';
  clean_supplier_en text := private.clean_supplier_receiving_text(payload->>'supplier_name_en', null, 120);
  clean_supplier_ar text := private.clean_supplier_receiving_text(payload->>'supplier_name_ar', null, 120);
  clean_unit text := private.clean_supplier_receiving_text(payload->>'unit', null, 40);
  clean_notes text := private.clean_supplier_receiving_text(payload->>'notes', null, 2000);
  clean_photo_path text := private.clean_supplier_receiving_text(payload->>'photo_storage_path', null, 260);
  clean_photo_name text := private.clean_supplier_receiving_text(payload->>'photo_original_name', null, 180);
  parsed_quantity numeric;
begin
  target_team := private.require_supervisor_supplier_receiving_team(actor_user_id, target_branch_id);
  if clean_category not in ('raw','frozen','juice') or clean_supplier_en is null or clean_unit is null then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end if;
  begin
    parsed_quantity := (payload->>'quantity')::numeric;
  exception when others then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end;
  if parsed_quantity <= 0 then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end if;

  return query
  insert into public.branch_supplier_receivings(
    organization_id, branch_id, supervisor_team_id, category, supplier_name_en,
    supplier_name_ar, quantity, unit, notes, photo_storage_path, photo_original_name, created_by
  ) values (
    target_team.organization_id, target_team.branch_id, target_team.id, clean_category,
    clean_supplier_en, clean_supplier_ar, parsed_quantity, clean_unit, clean_notes,
    clean_photo_path, clean_photo_name, actor_user_id
  )
  returning *;
end;
$$;

revoke all on function private.require_supervisor_supplier_receiving_team(uuid, uuid) from public, anon, authenticated;
grant execute on function private.require_supervisor_supplier_receiving_team(uuid, uuid) to service_role;
revoke all on function private.clean_supplier_receiving_text(text, text, integer) from public, anon, authenticated;
grant execute on function private.clean_supplier_receiving_text(text, text, integer) to service_role;
revoke all on function public.list_branch_supplier_receivings(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_branch_supplier_receiving(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.list_branch_supplier_receivings(uuid, uuid) to service_role;
grant execute on function public.create_branch_supplier_receiving(uuid, uuid, jsonb) to service_role;
