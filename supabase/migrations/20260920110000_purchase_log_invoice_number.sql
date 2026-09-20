begin;

alter table public.branch_purchase_logs
  add column if not exists invoice_number text;

alter table public.branch_purchase_logs
  add constraint branch_purchase_logs_invoice_number_check
  check (invoice_number is null or (invoice_number = pg_catalog.btrim(invoice_number) and length(invoice_number) between 1 and 120));

drop function public.list_branch_purchase_logs(uuid, uuid);

create function public.list_branch_purchase_logs(actor_user_id uuid,target_branch_id uuid)
returns table(
  id uuid,branch_id uuid,branch_name text,category text,item_name text,quantity numeric,
  amount numeric,before_tax_amount numeric,tax_amount numeric,
  vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,
  reimbursed_at timestamptz,reimbursed_by uuid,invoice_storage_path text,invoice_original_name text,
  invoice_number text,created_by uuid,created_at timestamptz,updated_at timestamptz
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
    l.invoice_original_name,l.invoice_number,l.created_by,l.created_at,l.updated_at
  from public.branch_purchase_logs l
  join public.branches b on b.id=l.branch_id
  where l.organization_id=c.organization_id and l.branch_id=c.branch_id
  order by l.purchase_date desc,l.created_at desc;
exception when no_data_found or too_many_rows then
  raise exception 'purchase log access denied' using errcode='42501';
end
$$;

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
  clean_invoice_number text:=private.clean_purchase_text(payload->>'invoice_number',null,120);
  money_pattern constant text := '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$';
  raw_before text:=nullif(payload->>'before_tax_amount','');
  raw_tax text:=nullif(payload->>'tax_amount','');
  raw_amount text:=nullif(payload->>'amount','');
  q numeric;
  before_amount numeric;
  tax_amount_value numeric;
  amount_value numeric;
  has_breakdown boolean:=false;
  d date;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
  if clean_category not in('stationery','kitchen','equipment','food_item') or clean_status not in('unpaid','reimbursed') then
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

  if raw_before is not null or raw_tax is not null then
    if raw_before is null or raw_tax is null then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    has_breakdown:=true;
  elsif raw_amount is not null then
    if raw_amount !~ money_pattern then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    amount_value:=raw_amount::numeric;
  else
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;

  if has_breakdown then
    if raw_before !~ money_pattern or raw_tax !~ money_pattern then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    before_amount:=raw_before::numeric;
    tax_amount_value:=raw_tax::numeric;
    amount_value:=before_amount+tax_amount_value;
  end if;
  if amount_value>9999999999.99 then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;

  if has_breakdown and raw_amount is not null then
    if raw_amount !~ money_pattern then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    amount_value:=raw_amount::numeric;
    if amount_value<>before_amount+tax_amount_value then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
  end if;

  return query insert into public.branch_purchase_logs(
    organization_id,branch_id,supervisor_team_id,category,item_name,quantity,amount,
    before_tax_amount,tax_amount,vendor_name,purchase_date,notes,payment_status,
    reimbursement_note,reimbursed_at,reimbursed_by,invoice_storage_path,invoice_original_name,
    invoice_number,created_by
  )
  values(
    c.organization_id,c.branch_id,c.legacy_team_id,clean_category,clean_item,q,amount_value,
    before_amount,tax_amount_value,clean_vendor,d,clean_notes,clean_status,
    clean_note,case when clean_status='reimbursed' then now() end,
    case when clean_status='reimbursed' then actor_user_id end,
    clean_path,clean_name,clean_invoice_number,actor_user_id
  )
  returning *;
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
  created_at timestamptz, updated_at timestamptz
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
    creator.full_name, log.created_at, log.updated_at
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

revoke all on function public.list_branch_purchase_logs(uuid,uuid) from public, anon, authenticated;
grant execute on function public.list_branch_purchase_logs(uuid,uuid) to service_role;
revoke all on function public.create_branch_purchase_log(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.create_branch_purchase_log(uuid,uuid,jsonb) to service_role;
revoke all on function public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date) from public, anon, authenticated;
grant execute on function public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date) to service_role;

commit;
