alter table public.branch_purchase_logs
  drop constraint if exists branch_purchase_logs_category_check;

alter table public.branch_purchase_logs
  add constraint branch_purchase_logs_category_check
  check (category in ('stationery','kitchen','equipment','food_item'));

create or replace function public.create_branch_purchase_log(actor_user_id uuid,target_branch_id uuid,payload jsonb)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
  c record;
  clean_category text:=payload->>'category';
  clean_item text:=private.clean_purchase_text(payload->>'item_name',null,120);
  clean_vendor text:=private.clean_purchase_text(payload->>'vendor_name','N/A',120);
  clean_notes text:=private.clean_purchase_text(payload->>'notes',null,2000);
  clean_status text:=coalesce(nullif(payload->>'payment_status',''),'unpaid');
  clean_note text:=private.clean_purchase_text(payload->>'reimbursement_note',null,500);
  clean_path text:=private.clean_purchase_text(payload->>'invoice_storage_path',null,260);
  clean_name text:=private.clean_purchase_text(payload->>'invoice_original_name',null,180);
  q numeric;
  a numeric;
  d date;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
  if clean_category not in('stationery','kitchen','equipment','food_item') or clean_status not in('unpaid','reimbursed') then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;
  begin
    q:=(payload->>'quantity')::numeric;
    a:=(payload->>'amount')::numeric;
    d:=(payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end;
  if q<=0 or a<0 or d is null then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;
  return query insert into public.branch_purchase_logs(
    organization_id,branch_id,supervisor_team_id,category,item_name,quantity,amount,
    vendor_name,purchase_date,notes,payment_status,reimbursement_note,reimbursed_at,
    reimbursed_by,invoice_storage_path,invoice_original_name,created_by
  )
  values(
    c.organization_id,c.branch_id,c.legacy_team_id,clean_category,clean_item,q,a,
    clean_vendor,d,clean_notes,clean_status,clean_note,
    case when clean_status='reimbursed' then now() end,
    case when clean_status='reimbursed' then actor_user_id end,
    clean_path,clean_name,actor_user_id
  )
  returning *;
exception when no_data_found or too_many_rows then
  raise exception 'purchase log access denied' using errcode='42501';
end
$$;

create or replace function public.list_managed_purchase_logs(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  category_filter text default null, payment_status_filter text default null,
  date_from_filter date default null, date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, supervisor_team_id uuid, branch_name text,
  category text, item_name text, quantity numeric, amount numeric, vendor_name text,
  purchase_date date, notes text, payment_status text, reimbursement_note text,
  reimbursed_at timestamptz, reimbursed_by uuid, invoice_storage_path text,
  invoice_original_name text, created_by uuid, created_by_name text, created_at timestamptz,
  updated_at timestamptz
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
    log.category, log.item_name, log.quantity, log.amount, log.vendor_name, log.purchase_date,
    log.notes, log.payment_status, log.reimbursement_note, log.reimbursed_at, log.reimbursed_by,
    log.invoice_storage_path, log.invoice_original_name, log.created_by, creator.full_name,
    log.created_at, log.updated_at
  from public.branch_purchase_logs log
  join public.branches branch on branch.id = log.branch_id
  left join public.profiles creator on creator.id = log.created_by
  where log.organization_id = target_organization_id
    and (branch_filter is null or log.branch_id = branch_filter)
    and (category_filter is null or log.category = category_filter)
    and (payment_status_filter is null or log.payment_status = payment_status_filter)
    and (date_from_filter is null or log.purchase_date >= date_from_filter)
    and (date_to_filter is null or log.purchase_date <= date_to_filter)
  order by log.purchase_date desc, log.created_at desc;
end
$$;

revoke all on function public.create_branch_purchase_log(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.create_branch_purchase_log(uuid,uuid,jsonb) to service_role;
revoke all on function public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date) from public, anon, authenticated;
grant execute on function public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date) to service_role;
