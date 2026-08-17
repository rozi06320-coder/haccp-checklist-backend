create table if not exists public.branch_suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  supervisor_team_id uuid not null references public.branch_supervisor_teams(id) on delete restrict,
  supplier_name_en text not null,
  supplier_name_ar text null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_suppliers_supplier_en_check check (supplier_name_en = pg_catalog.btrim(supplier_name_en) and length(supplier_name_en) between 1 and 120),
  constraint branch_suppliers_supplier_ar_check check (supplier_name_ar is null or (supplier_name_ar = pg_catalog.btrim(supplier_name_ar) and length(supplier_name_ar) between 1 and 120))
);

create unique index if not exists branch_suppliers_team_name_key
on public.branch_suppliers(supervisor_team_id, lower(pg_catalog.btrim(supplier_name_en)));
create index if not exists branch_suppliers_branch_name_idx on public.branch_suppliers(branch_id, supplier_name_en);

drop trigger if exists branch_suppliers_set_updated_at on public.branch_suppliers;
create trigger branch_suppliers_set_updated_at
before update on public.branch_suppliers
for each row execute function private.set_updated_at();

alter table public.branch_suppliers enable row level security;
revoke all on table public.branch_suppliers from public, anon, authenticated, service_role;
grant select on table public.branch_suppliers to authenticated;

alter table public.branch_supplier_receivings
add column if not exists supplier_id uuid null references public.branch_suppliers(id) on delete set null;
create index if not exists branch_supplier_receivings_supplier_idx on public.branch_supplier_receivings(supplier_id);

create or replace function private.upsert_branch_supplier_for_team(
  target_team public.branch_supervisor_teams,
  actor_user_id uuid,
  clean_supplier_en text,
  clean_supplier_ar text
)
returns public.branch_suppliers
language plpgsql
security definer
set search_path=public, private
as $$
declare target_supplier public.branch_suppliers%rowtype;
begin
  if clean_supplier_en is null then
    raise exception 'invalid supplier payload' using errcode='22023';
  end if;

  insert into public.branch_suppliers(
    organization_id, branch_id, supervisor_team_id, supplier_name_en, supplier_name_ar, created_by
  ) values (
    target_team.organization_id, target_team.branch_id, target_team.id, clean_supplier_en, clean_supplier_ar, actor_user_id
  )
  on conflict do nothing
  returning * into target_supplier;

  if target_supplier.id is null then
    select supplier.* into target_supplier
    from public.branch_suppliers supplier
    where supplier.supervisor_team_id = target_team.id
      and lower(pg_catalog.btrim(supplier.supplier_name_en)) = lower(pg_catalog.btrim(clean_supplier_en))
    limit 1;
    if target_supplier.id is null then
      raise exception 'invalid supplier payload' using errcode='22023';
    end if;
    if target_supplier.supplier_name_ar is null and clean_supplier_ar is not null then
      update public.branch_suppliers supplier
      set supplier_name_ar = clean_supplier_ar
      where supplier.id = target_supplier.id
      returning * into target_supplier;
    end if;
  end if;

  return target_supplier;
end;
$$;

create or replace function public.list_branch_suppliers(actor_user_id uuid, target_branch_id uuid)
returns table(
  id uuid,
  branch_id uuid,
  supplier_name_en text,
  supplier_name_ar text,
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
  select supplier.id, supplier.branch_id, supplier.supplier_name_en, supplier.supplier_name_ar,
    supplier.created_at, supplier.updated_at
  from public.branch_suppliers supplier
  where supplier.supervisor_team_id = target_team.id
  order by supplier.supplier_name_en asc, supplier.created_at asc;
end;
$$;

create or replace function public.create_branch_supplier(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns setof public.branch_suppliers
language plpgsql
security definer
set search_path=public, private
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  clean_supplier_en text := private.clean_supplier_receiving_text(payload->>'supplier_name_en', null, 120);
  clean_supplier_ar text := private.clean_supplier_receiving_text(payload->>'supplier_name_ar', null, 120);
  target_supplier public.branch_suppliers%rowtype;
begin
  target_team := private.require_supervisor_supplier_receiving_team(actor_user_id, target_branch_id);
  target_supplier := private.upsert_branch_supplier_for_team(target_team, actor_user_id, clean_supplier_en, clean_supplier_ar);
  return query select target_supplier.*;
end;
$$;

drop function if exists public.list_branch_supplier_receivings(uuid, uuid);
create or replace function public.list_branch_supplier_receivings(actor_user_id uuid, target_branch_id uuid)
returns table(
  id uuid,
  branch_id uuid,
  branch_name text,
  supplier_id uuid,
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
  select receiving.id, receiving.branch_id, branch.name, receiving.supplier_id, receiving.category,
    receiving.supplier_name_en, receiving.supplier_name_ar, receiving.quantity, receiving.unit,
    receiving.notes, receiving.photo_storage_path, receiving.photo_original_name, receiving.created_by,
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
  target_supplier public.branch_suppliers%rowtype;
  clean_category text := payload->>'category';
  clean_supplier_en text := private.clean_supplier_receiving_text(payload->>'supplier_name_en', null, 120);
  clean_supplier_ar text := private.clean_supplier_receiving_text(payload->>'supplier_name_ar', null, 120);
  clean_unit text := private.clean_supplier_receiving_text(payload->>'unit', null, 40);
  clean_notes text := private.clean_supplier_receiving_text(payload->>'notes', null, 2000);
  clean_photo_path text := private.clean_supplier_receiving_text(payload->>'photo_storage_path', null, 260);
  clean_photo_name text := private.clean_supplier_receiving_text(payload->>'photo_original_name', null, 180);
  requested_supplier_id uuid;
  parsed_quantity numeric;
begin
  target_team := private.require_supervisor_supplier_receiving_team(actor_user_id, target_branch_id);
  if clean_category not in ('raw','frozen','juice') or clean_unit is null then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end if;
  begin
    parsed_quantity := (payload->>'quantity')::numeric;
    requested_supplier_id := nullif(payload->>'supplier_id','')::uuid;
  exception when others then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end;
  if parsed_quantity <= 0 then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end if;

  if requested_supplier_id is not null then
    select supplier.* into target_supplier
    from public.branch_suppliers supplier
    where supplier.id = requested_supplier_id
      and supplier.supervisor_team_id = target_team.id
      and supplier.branch_id = target_team.branch_id
    limit 1;
    if target_supplier.id is null then
      raise exception 'supplier receiving access denied' using errcode='42501';
    end if;
    if target_supplier.supplier_name_ar is null and clean_supplier_ar is not null then
      update public.branch_suppliers supplier
      set supplier_name_ar = clean_supplier_ar
      where supplier.id = target_supplier.id
      returning * into target_supplier;
    end if;
  else
    target_supplier := private.upsert_branch_supplier_for_team(target_team, actor_user_id, clean_supplier_en, clean_supplier_ar);
  end if;

  return query
  insert into public.branch_supplier_receivings(
    organization_id, branch_id, supervisor_team_id, supplier_id, category, supplier_name_en,
    supplier_name_ar, quantity, unit, notes, photo_storage_path, photo_original_name, created_by
  ) values (
    target_team.organization_id, target_team.branch_id, target_team.id, target_supplier.id, clean_category,
    target_supplier.supplier_name_en, coalesce(clean_supplier_ar, target_supplier.supplier_name_ar),
    parsed_quantity, clean_unit, clean_notes, clean_photo_path, clean_photo_name, actor_user_id
  )
  returning *;
end;
$$;

revoke all on function private.upsert_branch_supplier_for_team(public.branch_supervisor_teams, uuid, text, text) from public, anon, authenticated;
grant execute on function private.upsert_branch_supplier_for_team(public.branch_supervisor_teams, uuid, text, text) to service_role;
revoke all on function public.list_branch_suppliers(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_branch_supplier(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.list_branch_suppliers(uuid, uuid) to service_role;
grant execute on function public.create_branch_supplier(uuid, uuid, jsonb) to service_role;
