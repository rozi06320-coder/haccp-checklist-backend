insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'branch-purchase-invoices',
  'branch-purchase-invoices',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp','application/pdf']
)
on conflict (id) do update set
  public=false,
  file_size_limit=5242880,
  allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf'];

create table if not exists public.branch_purchase_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  supervisor_team_id uuid not null references public.branch_supervisor_teams(id) on delete restrict,
  category text not null,
  item_name text not null,
  quantity numeric not null,
  amount numeric not null,
  vendor_name text not null default 'N/A',
  purchase_date date not null,
  notes text null,
  payment_status text not null default 'unpaid',
  reimbursement_note text null,
  reimbursed_at timestamptz null,
  reimbursed_by uuid null references public.profiles(id) on delete set null,
  invoice_storage_path text null,
  invoice_original_name text null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_purchase_logs_category_check check (category in ('stationery','kitchen','equipment')),
  constraint branch_purchase_logs_quantity_check check (quantity > 0),
  constraint branch_purchase_logs_amount_check check (amount >= 0),
  constraint branch_purchase_logs_payment_status_check check (payment_status in ('unpaid','reimbursed')),
  constraint branch_purchase_logs_item_name_check check (item_name = pg_catalog.btrim(item_name) and length(item_name) between 1 and 120),
  constraint branch_purchase_logs_vendor_name_check check (vendor_name = pg_catalog.btrim(vendor_name) and length(vendor_name) between 1 and 120),
  constraint branch_purchase_logs_notes_check check (notes is null or (notes = pg_catalog.btrim(notes) and length(notes) between 1 and 2000)),
  constraint branch_purchase_logs_reimbursement_note_check check (reimbursement_note is null or (reimbursement_note = pg_catalog.btrim(reimbursement_note) and length(reimbursement_note) between 1 and 500)),
  constraint branch_purchase_logs_invoice_name_check check (invoice_original_name is null or (invoice_original_name = pg_catalog.btrim(invoice_original_name) and length(invoice_original_name) between 1 and 180)),
  constraint branch_purchase_logs_invoice_path_check check (invoice_storage_path is null or invoice_storage_path ~ '^branches/[0-9a-fA-F-]{36}/purchase-logs/[0-9a-fA-F-]{36}/[^/]{1,180}$')
);

create index if not exists branch_purchase_logs_team_date_idx on public.branch_purchase_logs(supervisor_team_id, purchase_date desc, created_at desc);
create index if not exists branch_purchase_logs_branch_date_idx on public.branch_purchase_logs(branch_id, purchase_date desc, created_at desc);

drop trigger if exists branch_purchase_logs_set_updated_at on public.branch_purchase_logs;
create trigger branch_purchase_logs_set_updated_at
before update on public.branch_purchase_logs
for each row execute function private.set_updated_at();

alter table public.branch_purchase_logs enable row level security;
revoke all on table public.branch_purchase_logs from public, anon, authenticated, service_role;
grant select on table public.branch_purchase_logs to authenticated;

create or replace function private.require_supervisor_purchase_team(actor_user_id uuid, target_branch_id uuid)
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
    raise exception 'purchase log access denied' using errcode='42501';
  end if;
  return target_team;
end;
$$;

create or replace function private.clean_purchase_text(value text, fallback text default null, max_length integer default 120)
returns text
language plpgsql
immutable
as $$
declare cleaned text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(value,'')), '[[:space:]]+', ' ', 'g'), '');
begin
  cleaned := coalesce(cleaned, fallback);
  if cleaned is null then return null; end if;
  if length(cleaned) > max_length then
    raise exception 'invalid purchase text' using errcode='22023';
  end if;
  return cleaned;
end;
$$;

create or replace function public.list_branch_purchase_logs(actor_user_id uuid, target_branch_id uuid)
returns table(
  id uuid,
  branch_id uuid,
  branch_name text,
  category text,
  item_name text,
  quantity numeric,
  amount numeric,
  vendor_name text,
  purchase_date date,
  notes text,
  payment_status text,
  reimbursement_note text,
  reimbursed_at timestamptz,
  reimbursed_by uuid,
  invoice_storage_path text,
  invoice_original_name text,
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
  target_team := private.require_supervisor_purchase_team(actor_user_id, target_branch_id);
  return query
  select log.id, log.branch_id, branch.name, log.category, log.item_name, log.quantity, log.amount,
    log.vendor_name, log.purchase_date, log.notes, log.payment_status, log.reimbursement_note,
    log.reimbursed_at, log.reimbursed_by, log.invoice_storage_path, log.invoice_original_name,
    log.created_by, log.created_at, log.updated_at
  from public.branch_purchase_logs log
  join public.branches branch on branch.id = log.branch_id
  where log.supervisor_team_id = target_team.id
  order by log.purchase_date desc, log.created_at desc;
end;
$$;

create or replace function public.create_branch_purchase_log(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=public, private
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  clean_category text := payload->>'category';
  clean_item text := private.clean_purchase_text(payload->>'item_name', null, 120);
  clean_vendor text := private.clean_purchase_text(payload->>'vendor_name', 'N/A', 120);
  clean_notes text := private.clean_purchase_text(payload->>'notes', null, 2000);
  clean_status text := coalesce(nullif(payload->>'payment_status',''), 'unpaid');
  clean_reimbursement_note text := private.clean_purchase_text(payload->>'reimbursement_note', null, 500);
  clean_invoice_path text := private.clean_purchase_text(payload->>'invoice_storage_path', null, 260);
  clean_invoice_name text := private.clean_purchase_text(payload->>'invoice_original_name', null, 180);
  parsed_quantity numeric;
  parsed_amount numeric;
  parsed_date date;
begin
  target_team := private.require_supervisor_purchase_team(actor_user_id, target_branch_id);
  if clean_category not in ('stationery','kitchen','equipment') or clean_status not in ('unpaid','reimbursed') then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;
  begin
    parsed_quantity := (payload->>'quantity')::numeric;
    parsed_amount := (payload->>'amount')::numeric;
    parsed_date := (payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end;
  if parsed_quantity <= 0 or parsed_amount < 0 or parsed_date is null then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;

  return query
  insert into public.branch_purchase_logs(
    organization_id, branch_id, supervisor_team_id, category, item_name, quantity, amount,
    vendor_name, purchase_date, notes, payment_status, reimbursement_note,
    reimbursed_at, reimbursed_by, invoice_storage_path, invoice_original_name, created_by
  ) values (
    target_team.organization_id, target_team.branch_id, target_team.id, clean_category, clean_item,
    parsed_quantity, parsed_amount, clean_vendor, parsed_date, clean_notes, clean_status,
    clean_reimbursement_note, case when clean_status = 'reimbursed' then now() else null end,
    case when clean_status = 'reimbursed' then actor_user_id else null end,
    clean_invoice_path, clean_invoice_name, actor_user_id
  )
  returning *;
end;
$$;

create or replace function public.update_branch_purchase_log_payment_status(
  actor_user_id uuid,
  target_branch_id uuid,
  target_purchase_log_id uuid,
  new_payment_status text,
  new_reimbursement_note text
)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=public, private
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  clean_status text := coalesce(nullif(new_payment_status,''), 'unpaid');
  clean_note text := private.clean_purchase_text(new_reimbursement_note, null, 500);
begin
  target_team := private.require_supervisor_purchase_team(actor_user_id, target_branch_id);
  if clean_status not in ('unpaid','reimbursed') then
    raise exception 'invalid purchase status' using errcode='22023';
  end if;
  return query
  update public.branch_purchase_logs log
  set payment_status = clean_status,
      reimbursement_note = clean_note,
      reimbursed_at = case when clean_status = 'reimbursed' then coalesce(log.reimbursed_at, now()) else null end,
      reimbursed_by = case when clean_status = 'reimbursed' then coalesce(log.reimbursed_by, actor_user_id) else null end
  where log.id = target_purchase_log_id
    and log.branch_id = target_branch_id
    and log.supervisor_team_id = target_team.id
  returning log.*;
  if not found then
    raise exception 'purchase log access denied' using errcode='42501';
  end if;
end;
$$;

revoke all on function private.require_supervisor_purchase_team(uuid, uuid) from public, anon, authenticated;
grant execute on function private.require_supervisor_purchase_team(uuid, uuid) to service_role;
revoke all on function private.clean_purchase_text(text, text, integer) from public, anon, authenticated;
grant execute on function private.clean_purchase_text(text, text, integer) to service_role;
revoke all on function public.list_branch_purchase_logs(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_branch_purchase_log(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.update_branch_purchase_log_payment_status(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.list_branch_purchase_logs(uuid, uuid) to service_role;
grant execute on function public.create_branch_purchase_log(uuid, uuid, jsonb) to service_role;
grant execute on function public.update_branch_purchase_log_payment_status(uuid, uuid, uuid, text, text) to service_role;
