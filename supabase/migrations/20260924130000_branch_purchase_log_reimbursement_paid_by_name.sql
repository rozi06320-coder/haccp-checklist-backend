begin;

alter table public.branch_purchase_logs
  add column if not exists reimbursement_paid_by_name text;

alter table public.branch_purchase_logs
  drop constraint if exists branch_purchase_logs_reimbursement_paid_by_name_check,
  add constraint branch_purchase_logs_reimbursement_paid_by_name_check
    check (
      reimbursement_paid_by_name is null
      or pg_catalog.length(pg_catalog.btrim(reimbursement_paid_by_name)) between 1 and 120
    );

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
    'reimbursement_paid_by_name', row_data.reimbursement_paid_by_name,
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

drop function if exists public.list_branch_purchase_logs(uuid, uuid);

create function public.list_branch_purchase_logs(actor_user_id uuid,target_branch_id uuid)
returns table(
  id uuid,branch_id uuid,branch_name text,category text,item_name text,quantity numeric,
  amount numeric,before_tax_amount numeric,tax_amount numeric,
  vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,
  reimbursement_paid_by_name text,reimbursed_at timestamptz,reimbursed_by uuid,invoice_storage_path text,
  invoice_original_name text,invoice_number text,source_type text,source_purchase_request_id uuid,
  source_purchase_request_item_id uuid,created_by uuid,created_at timestamptz,updated_at timestamptz,
  revision bigint
)
language plpgsql
security definer
set search_path=''
as $$
declare
  c record;
begin
  select * into strict c from private.purchase_log_branch_context(actor_user_id,target_branch_id);
  return query
  select l.id,l.branch_id,b.name,l.category,l.item_name,l.quantity,l.amount,
    l.before_tax_amount,l.tax_amount,l.vendor_name,l.purchase_date,l.notes,
    l.payment_status,l.reimbursement_note,l.reimbursement_paid_by_name,l.reimbursed_at,l.reimbursed_by,
    l.invoice_storage_path,l.invoice_original_name,l.invoice_number,l.source_type,l.source_purchase_request_id,
    l.source_purchase_request_item_id,l.created_by,l.created_at,l.updated_at,l.revision
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

drop function if exists public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text);

create function public.update_branch_purchase_log_payment_status(
  actor_user_id uuid,
  target_branch_id uuid,
  target_purchase_log_id uuid,
  new_payment_status text,
  new_reimbursement_note text,
  new_reimbursement_paid_by_name text
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
 clean_status text:=coalesce(nullif(new_payment_status,''),'unpaid');
 clean_note text:=private.clean_purchase_text(new_reimbursement_note,null,500);
 clean_paid_by_name text:=private.clean_purchase_text(new_reimbursement_paid_by_name,null,120);
begin
 select * into c from private.purchase_log_branch_context(actor_user_id,target_branch_id);
 if not found then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if clean_status not in('unpaid','reimbursed') then
  raise exception 'invalid payment status' using errcode='22023';
 end if;
 if clean_status='reimbursed' and clean_paid_by_name is null then
  raise exception 'reimbursement paid by name is required' using errcode='22023';
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
     reimbursement_paid_by_name=case when clean_status='reimbursed' then clean_paid_by_name else null end,
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

drop function if exists public.list_managed_purchase_logs(uuid, uuid, uuid, text, text, date, date);

create function public.list_managed_purchase_logs(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  category_filter text default null,
  payment_status_filter text default null,
  date_from_filter date default null,
  date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, supervisor_team_id uuid, branch_name text,
  category text, item_name text, quantity numeric, amount numeric, before_tax_amount numeric,
  tax_amount numeric, vendor_name text, purchase_date date, notes text, payment_status text,
  reimbursement_note text, reimbursement_paid_by_name text, reimbursed_at timestamptz, reimbursed_by uuid,
  invoice_storage_path text, invoice_original_name text, invoice_number text, source_type text,
  source_purchase_request_id uuid, source_purchase_request_item_id uuid, created_by uuid,
  created_by_name text, created_at timestamptz, updated_at timestamptz, revision bigint
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
    or category_filter is not null and category_filter not in ('stationery','kitchen','equipment','food_item','other')
    or payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed')
    or date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter then
    raise exception 'managed purchase log access denied' using errcode = '42501';
  end if;

  return query
  select log.id, log.organization_id, log.branch_id, log.supervisor_team_id, branch.name,
    log.category, log.item_name, log.quantity, log.amount, log.before_tax_amount,
    log.tax_amount, log.vendor_name, log.purchase_date, log.notes, log.payment_status,
    log.reimbursement_note, log.reimbursement_paid_by_name, log.reimbursed_at, log.reimbursed_by,
    log.invoice_storage_path, log.invoice_original_name, log.invoice_number, log.source_type,
    log.source_purchase_request_id, log.source_purchase_request_item_id, log.created_by,
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

drop function if exists public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text);

create function public.list_purchasing_purchase_logs(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  payment_status_filter text default null,
  date_from_filter date default null,
  date_to_filter date default null,
  search_filter text default null
)
returns table(
  id uuid,
  branch_id uuid,
  branch_name text,
  category text,
  item_name text,
  quantity numeric,
  amount numeric,
  before_tax_amount numeric,
  tax_amount numeric,
  vendor_name text,
  purchase_date date,
  notes text,
  payment_status text,
  reimbursement_note text,
  reimbursement_paid_by_name text,
  reimbursed_at timestamptz,
  reimbursed_by uuid,
  invoice_storage_path text,
  invoice_original_name text,
  invoice_number text,
  source_type text,
  source_purchase_request_id uuid,
  source_purchase_request_item_id uuid,
  created_by uuid,
  created_by_name text,
  created_at timestamptz,
  updated_at timestamptz,
  revision bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  clean_search text := nullif(pg_catalog.btrim(coalesce(search_filter, '')), '');
begin
  if not private.has_active_purchasing_membership(actor_user_id, target_organization_id) then
    raise exception 'purchasing purchase log access denied' using errcode = '42501';
  end if;

  if payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed') then
    raise exception 'invalid purchase log payment status' using errcode = '22023';
  end if;

  if date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter then
    raise exception 'invalid purchase log date range' using errcode = '22023';
  end if;

  return query
  select
    log.id,
    log.branch_id,
    branch.name,
    log.category,
    log.item_name,
    log.quantity,
    log.amount,
    log.before_tax_amount,
    log.tax_amount,
    log.vendor_name,
    log.purchase_date,
    log.notes,
    log.payment_status,
    log.reimbursement_note,
    log.reimbursement_paid_by_name,
    log.reimbursed_at,
    log.reimbursed_by,
    log.invoice_storage_path,
    log.invoice_original_name,
    log.invoice_number,
    log.source_type,
    log.source_purchase_request_id,
    log.source_purchase_request_item_id,
    log.created_by,
    creator.full_name,
    log.created_at,
    log.updated_at,
    log.revision
  from public.branch_purchase_logs log
  join public.branches branch
    on branch.id = log.branch_id
   and branch.organization_id = target_organization_id
   and branch.active
  join public.organizations organization
    on organization.id = branch.organization_id
   and organization.active
  left join public.profiles creator
    on creator.id = log.created_by
  where log.organization_id = target_organization_id
    and log.deleted_at is null
    and (branch_filter is null or log.branch_id = branch_filter)
    and (payment_status_filter is null or log.payment_status = payment_status_filter)
    and (date_from_filter is null or log.purchase_date >= date_from_filter)
    and (date_to_filter is null or log.purchase_date <= date_to_filter)
    and (
      clean_search is null
      or log.item_name ilike '%' || clean_search || '%'
      or log.vendor_name ilike '%' || clean_search || '%'
      or coalesce(log.invoice_number, '') ilike '%' || clean_search || '%'
      or branch.name ilike '%' || clean_search || '%'
      or coalesce(branch.code, '') ilike '%' || clean_search || '%'
    )
  order by log.purchase_date desc, log.created_at desc, log.id desc
  limit 500;
end
$function$;

revoke all on function private.branch_purchase_log_snapshot(public.branch_purchase_logs) from public, anon, authenticated;
revoke all on function public.list_branch_purchase_logs(uuid,uuid) from public, anon, authenticated;
revoke all on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text,text) from public, anon, authenticated;
revoke all on function public.list_managed_purchase_logs(uuid, uuid, uuid, text, text, date, date) from public, anon, authenticated;
revoke all on function public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text) from public, anon, authenticated;

grant execute on function public.list_branch_purchase_logs(uuid,uuid) to service_role;
grant execute on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text,text) to service_role;
grant execute on function public.list_managed_purchase_logs(uuid, uuid, uuid, text, text, date, date) to service_role;
grant execute on function public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text) to service_role;

commit;
