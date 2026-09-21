begin;

alter table public.branch_purchase_logs
  add column if not exists revision bigint not null default 1,
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles(id) on delete restrict,
  add column if not exists delete_reason text,
  add column if not exists delete_reason_note text;

alter table public.branch_purchase_logs
  drop constraint if exists branch_purchase_logs_revision_check,
  add constraint branch_purchase_logs_revision_check check (revision >= 1),
  drop constraint if exists branch_purchase_logs_delete_state_check,
  add constraint branch_purchase_logs_delete_state_check check (
    (
      deleted_at is null
      and deleted_by is null
      and delete_reason is null
      and delete_reason_note is null
    )
    or (
      deleted_at is not null
      and deleted_by is not null
      and delete_reason in ('duplicate','wrong_entry','purchase_cancelled','other')
      and (
        delete_reason_note is null
        or (
          delete_reason_note = pg_catalog.btrim(delete_reason_note)
          and length(delete_reason_note) between 10 and 500
        )
      )
      and (
        delete_reason <> 'other'
        or (
          delete_reason_note is not null
          and length(delete_reason_note) between 10 and 500
        )
      )
    )
  );

create index if not exists branch_purchase_logs_active_branch_date_idx
  on public.branch_purchase_logs(branch_id, purchase_date desc, created_at desc)
  where deleted_at is null;

create index if not exists branch_purchase_logs_active_org_branch_date_idx
  on public.branch_purchase_logs(organization_id, branch_id, purchase_date desc, created_at desc)
  where deleted_at is null;

create table if not exists public.branch_purchase_log_events (
  id uuid primary key default gen_random_uuid(),
  purchase_log_id uuid not null references public.branch_purchase_logs(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  event_type text not null,
  actor_user_id uuid not null references public.profiles(id) on delete restrict,
  reason_code text not null,
  reason_note text,
  old_values jsonb not null default '{}'::jsonb,
  new_values jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  constraint branch_purchase_log_events_type_check
    check (event_type in ('edited','soft_deleted','payment_status_changed')),
  constraint branch_purchase_log_events_reason_check
    check (reason_code in ('correction','duplicate','wrong_entry','purchase_cancelled','other','payment_status_change')),
  constraint branch_purchase_log_events_reason_note_check
    check (
      reason_note is null
      or (
        reason_note = pg_catalog.btrim(reason_note)
        and length(reason_note) between 10 and 500
      )
    ),
  constraint branch_purchase_log_events_values_check
    check (jsonb_typeof(old_values) = 'object' and jsonb_typeof(new_values) = 'object')
);

alter table public.branch_purchase_log_events enable row level security;
revoke all on table public.branch_purchase_log_events from public, anon, authenticated, service_role;

create unique index if not exists branch_purchase_log_events_one_soft_delete_idx
  on public.branch_purchase_log_events(purchase_log_id)
  where event_type = 'soft_deleted';

create index if not exists branch_purchase_log_events_purchase_created_idx
  on public.branch_purchase_log_events(purchase_log_id, created_at desc);

create or replace function private.branch_purchase_log_snapshot(row_data public.branch_purchase_logs)
returns jsonb
language sql
stable
set search_path=''
as $$
  select jsonb_build_object(
    'id', row_data.id,
    'organization_id', row_data.organization_id,
    'branch_id', row_data.branch_id,
    'supervisor_team_id', row_data.supervisor_team_id,
    'category', row_data.category,
    'item_name', row_data.item_name,
    'quantity', row_data.quantity,
    'amount', row_data.amount,
    'before_tax_amount', row_data.before_tax_amount,
    'tax_amount', row_data.tax_amount,
    'vendor_name', row_data.vendor_name,
    'purchase_date', row_data.purchase_date,
    'invoice_number', row_data.invoice_number,
    'notes', row_data.notes,
    'payment_status', row_data.payment_status,
    'reimbursement_note', row_data.reimbursement_note,
    'reimbursed_at', row_data.reimbursed_at,
    'reimbursed_by', row_data.reimbursed_by,
    'invoice_storage_path', row_data.invoice_storage_path,
    'invoice_original_name', row_data.invoice_original_name,
    'created_by', row_data.created_by,
    'revision', row_data.revision,
    'deleted_at', row_data.deleted_at,
    'deleted_by', row_data.deleted_by,
    'delete_reason', row_data.delete_reason,
    'delete_reason_note', row_data.delete_reason_note,
    'created_at', row_data.created_at,
    'updated_at', row_data.updated_at
  )
$$;

create or replace function private.clean_purchase_reason(raw_value text)
returns text
language sql
stable
set search_path=''
as $$
  select nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(raw_value,'')), '\s+', ' ', 'g'), '')
$$;

drop function public.list_branch_purchase_logs(uuid, uuid);

create function public.list_branch_purchase_logs(actor_user_id uuid,target_branch_id uuid)
returns table(
  id uuid,branch_id uuid,branch_name text,category text,item_name text,quantity numeric,
  amount numeric,before_tax_amount numeric,tax_amount numeric,
  vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,
  reimbursed_at timestamptz,reimbursed_by uuid,invoice_storage_path text,invoice_original_name text,
  invoice_number text,created_by uuid,created_at timestamptz,updated_at timestamptz,revision bigint
)
language plpgsql
security definer
set search_path=''
as $$
declare
  c record;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
  return query
  select l.id,l.branch_id,b.name,l.category,l.item_name,l.quantity,l.amount,
    l.before_tax_amount,l.tax_amount,l.vendor_name,l.purchase_date,l.notes,
    l.payment_status,l.reimbursement_note,l.reimbursed_at,l.reimbursed_by,l.invoice_storage_path,
    l.invoice_original_name,l.invoice_number,l.created_by,l.created_at,l.updated_at,l.revision
  from public.branch_purchase_logs l
  join public.branches b on b.id=l.branch_id
  where l.organization_id=c.organization_id
    and l.branch_id=c.branch_id
    and l.deleted_at is null
  order by l.purchase_date desc,l.created_at desc;
exception when no_data_found or too_many_rows then
  raise exception 'purchase log access denied' using errcode='42501';
end
$$;

drop function public.list_managed_purchase_logs(uuid, uuid, uuid, text, text, date, date);

create function public.list_managed_purchase_logs(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  category_filter text default null, payment_status_filter text default null,
  date_from_filter date default null, date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, supervisor_team_id uuid, branch_name text,
  category text, item_name text, quantity numeric, amount numeric,
  before_tax_amount numeric, tax_amount numeric, vendor_name text,
  purchase_date date, notes text, payment_status text, reimbursement_note text,
  reimbursed_at timestamptz, reimbursed_by uuid, invoice_storage_path text,
  invoice_original_name text, invoice_number text, created_by uuid, created_by_name text,
  created_at timestamptz, updated_at timestamptz, revision bigint
)
language plpgsql
security definer
set search_path=''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (branch_filter is not null and not exists (
      select 1 from public.branches managed_branch
      where managed_branch.id = branch_filter and managed_branch.organization_id = target_organization_id
    ))
    or category_filter is not null and category_filter not in ('stationery','kitchen','equipment','food_item')
    or payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed')
    or date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter then
    raise exception 'managed purchase log access denied' using errcode = '42501';
  end if;

  return query
  select log.id, log.organization_id, log.branch_id, log.supervisor_team_id, branch.name,
    log.category, log.item_name, log.quantity, log.amount, log.before_tax_amount,
    log.tax_amount, log.vendor_name, log.purchase_date,
    log.notes, log.payment_status, log.reimbursement_note, log.reimbursed_at, log.reimbursed_by,
    log.invoice_storage_path, log.invoice_original_name, log.invoice_number, log.created_by,
    creator.full_name, log.created_at, log.updated_at, log.revision
  from public.branch_purchase_logs log
  join public.branches branch on branch.id = log.branch_id
  left join public.profiles creator on creator.id = log.created_by
  where log.organization_id = target_organization_id
    and log.deleted_at is null
    and (branch_filter is null or log.branch_id = branch_filter)
    and (category_filter is null or log.category = category_filter)
    and (payment_status_filter is null or log.payment_status = payment_status_filter)
    and (date_from_filter is null or log.purchase_date >= date_from_filter)
    and (date_to_filter is null or log.purchase_date <= date_to_filter)
  order by log.purchase_date desc, log.created_at desc;
end
$$;

create or replace function public.update_branch_purchase_log_payment_status(actor_user_id uuid,target_branch_id uuid,target_purchase_log_id uuid,new_payment_status text,new_reimbursement_note text)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
 c record;
 existing public.branch_purchase_logs;
 updated public.branch_purchase_logs;
 clean_status text:=coalesce(nullif(new_payment_status,''),'unpaid');
 clean_note text:=private.clean_purchase_text(new_reimbursement_note,null,500);
begin
 select * into c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if not found then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if clean_status not in('unpaid','reimbursed') then
  raise exception 'invalid payment status' using errcode='22023';
 end if;
 select * into existing from public.branch_purchase_logs l
 where l.id=target_purchase_log_id and l.organization_id=c.organization_id and l.branch_id=c.branch_id
 for update;
 if not found or existing.deleted_at is not null then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 update public.branch_purchase_logs l
 set payment_status=clean_status,
     reimbursement_note=clean_note,
     reimbursed_at=case when clean_status='reimbursed' then coalesce(l.reimbursed_at,statement_timestamp()) else null end,
     reimbursed_by=case when clean_status='reimbursed' then coalesce(l.reimbursed_by,actor_user_id) else null end,
     revision=l.revision+1
 where l.id=existing.id
 returning * into updated;
 insert into public.branch_purchase_log_events(purchase_log_id,organization_id,branch_id,event_type,actor_user_id,reason_code,reason_note,old_values,new_values)
 values(updated.id,updated.organization_id,updated.branch_id,'payment_status_changed',actor_user_id,'payment_status_change',null,private.branch_purchase_log_snapshot(existing),private.branch_purchase_log_snapshot(updated));
 return next updated;
end
$$;

create or replace function public.update_branch_purchase_log(
  actor_user_id uuid,target_branch_id uuid,target_purchase_log_id uuid,
  expected_revision bigint,correction_reason text,payload jsonb
)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
 c record;
 existing public.branch_purchase_logs;
 updated public.branch_purchase_logs;
 clean_reason text:=private.clean_purchase_reason(correction_reason);
 clean_category text:=payload->>'category';
 clean_item text:=private.clean_purchase_text(payload->>'item_name',null,120);
 clean_vendor text:=private.clean_purchase_text(payload->>'vendor_name','N/A',120);
 clean_notes text:=private.clean_purchase_text(payload->>'notes',null,2000);
 clean_invoice_number text:=private.clean_purchase_text(payload->>'invoice_number',null,120);
 money_pattern constant text := '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$';
 raw_before text:=nullif(payload->>'before_tax_amount','');
 raw_tax text:=nullif(payload->>'tax_amount','');
 raw_amount text:=nullif(payload->>'amount','');
 q numeric;
 before_amount numeric;
 tax_amount_value numeric;
 amount_value numeric;
 d date;
begin
 select * into c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if not found then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if clean_reason is null or length(clean_reason)<10 or length(clean_reason)>500 then
  raise exception 'invalid purchase log correction reason' using errcode='22023';
 end if;
 if expected_revision is null or expected_revision<1 then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 if exists(select 1 from jsonb_object_keys(payload) as key where key not in('category','item_name','quantity','amount','before_tax_amount','tax_amount','vendor_name','purchase_date','invoice_number','notes')) then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 if clean_category not in('stationery','kitchen','equipment','food_item') then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 begin
  q:=(payload->>'quantity')::numeric;
  d:=(payload->>'purchase_date')::date;
 exception when others then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end;
 if q<=0 or d is null then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 if raw_before is null or raw_tax is null or raw_before !~ money_pattern or raw_tax !~ money_pattern then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 before_amount:=raw_before::numeric;
 tax_amount_value:=raw_tax::numeric;
 amount_value:=before_amount+tax_amount_value;
 if amount_value>9999999999.99 then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 if raw_amount is not null then
  if raw_amount !~ money_pattern or raw_amount::numeric<>amount_value then
   raise exception 'invalid purchase log payload' using errcode='22023';
  end if;
 end if;
 select * into existing from public.branch_purchase_logs l
 where l.id=target_purchase_log_id and l.organization_id=c.organization_id and l.branch_id=c.branch_id
 for update;
 if not found or existing.deleted_at is not null then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if existing.revision<>expected_revision then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 if existing.payment_status<>'unpaid' then
  raise exception 'reimbursed purchase logs are read only' using errcode='55000';
 end if;
 update public.branch_purchase_logs l
 set category=clean_category,item_name=clean_item,quantity=q,amount=amount_value,
     before_tax_amount=before_amount,tax_amount=tax_amount_value,vendor_name=clean_vendor,
     purchase_date=d,invoice_number=clean_invoice_number,notes=clean_notes,revision=l.revision+1
 where l.id=existing.id
 returning * into updated;
 insert into public.branch_purchase_log_events(purchase_log_id,organization_id,branch_id,event_type,actor_user_id,reason_code,reason_note,old_values,new_values)
 values(updated.id,updated.organization_id,updated.branch_id,'edited',actor_user_id,'correction',clean_reason,private.branch_purchase_log_snapshot(existing),private.branch_purchase_log_snapshot(updated));
 return next updated;
end
$$;

create or replace function public.soft_delete_branch_purchase_log(
  actor_user_id uuid,target_branch_id uuid,target_purchase_log_id uuid,
  expected_revision bigint,delete_reason text,delete_reason_note text
)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
 c record;
 existing public.branch_purchase_logs;
 updated public.branch_purchase_logs;
 clean_reason text:=nullif(delete_reason,'');
 clean_note text:=private.clean_purchase_reason(delete_reason_note);
begin
 select * into c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if not found then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if clean_reason not in('duplicate','wrong_entry','purchase_cancelled','other') then
  raise exception 'invalid delete reason' using errcode='22023';
 end if;
 if clean_note is not null and length(clean_note)>500 then
  raise exception 'invalid delete reason' using errcode='22023';
 end if;
 if clean_reason='other' and (clean_note is null or length(clean_note)<10) then
  raise exception 'invalid delete reason' using errcode='22023';
 end if;
 if expected_revision is null or expected_revision<1 then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 select * into existing from public.branch_purchase_logs l
 where l.id=target_purchase_log_id and l.organization_id=c.organization_id and l.branch_id=c.branch_id
 for update;
 if not found or existing.deleted_at is not null then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if existing.revision<>expected_revision then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 if existing.payment_status<>'unpaid' then
  raise exception 'reimbursed purchase logs are read only' using errcode='55000';
 end if;
 update public.branch_purchase_logs l
 set deleted_at=statement_timestamp(),deleted_by=actor_user_id,delete_reason=clean_reason,
     delete_reason_note=clean_note,revision=l.revision+1
 where l.id=existing.id
 returning * into updated;
 insert into public.branch_purchase_log_events(purchase_log_id,organization_id,branch_id,event_type,actor_user_id,reason_code,reason_note,old_values,new_values)
 values(updated.id,updated.organization_id,updated.branch_id,'soft_deleted',actor_user_id,clean_reason,clean_note,private.branch_purchase_log_snapshot(existing),private.branch_purchase_log_snapshot(updated));
 return next updated;
end
$$;

revoke all on function private.branch_purchase_log_snapshot(public.branch_purchase_logs) from public, anon, authenticated, service_role;
revoke all on function private.clean_purchase_reason(text) from public, anon, authenticated, service_role;

revoke all on function public.list_branch_purchase_logs(uuid,uuid) from public, anon, authenticated;
grant execute on function public.list_branch_purchase_logs(uuid,uuid) to service_role;
revoke all on function public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date) from public, anon, authenticated;
grant execute on function public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date) to service_role;
revoke all on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text) to service_role;
revoke all on function public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb) from public, anon, authenticated;
grant execute on function public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb) to service_role;
revoke all on function public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text) from public, anon, authenticated;
grant execute on function public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text) to service_role;

commit;
