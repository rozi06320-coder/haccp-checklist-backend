alter table public.maintenance_purchase_logs
  add column if not exists unit text not null default 'other';

alter table public.maintenance_purchase_logs
  drop constraint if exists maintenance_purchase_unit_check;

alter table public.maintenance_purchase_logs
  add constraint maintenance_purchase_unit_check
  check(unit in ('pcs','meter','kg','box','bag','roll','set','liter','other'));

drop function if exists public.list_maintenance_purchase_logs(uuid,uuid);
drop function if exists public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date);

create or replace function public.list_maintenance_purchase_logs(actor_user_id uuid,target_issue_id uuid)
returns table(id uuid,branch_id uuid,item_name text,quantity numeric,unit text,amount numeric,vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,reimbursed_at timestamptz,receipt_storage_path text,receipt_original_name text,created_at timestamptz,updated_at timestamptz)
language plpgsql
security definer
set search_path=''
as $$
declare
  issue public.maintenance_issues%rowtype;
begin
  issue:=private.require_maintenance_purchase_issue(actor_user_id,target_issue_id);
  return query
    select p.id,p.branch_id,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    where p.maintenance_issue_id=issue.id
    order by p.purchase_date desc,p.created_at desc;
end;
$$;

create or replace function public.create_maintenance_purchase_log(actor_user_id uuid,target_issue_id uuid,payload jsonb)
returns setof public.maintenance_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
  issue public.maintenance_issues%rowtype;
  item text:=private.clean_purchase_text(payload->>'item_name',null,120);
  vendor text:=private.clean_purchase_text(payload->>'vendor_name','N/A',120);
  notes_value text:=private.clean_purchase_text(payload->>'notes',null,2000);
  path text:=private.clean_purchase_text(payload->>'receipt_storage_path',null,260);
  filename text:=private.clean_purchase_text(payload->>'receipt_original_name',null,180);
  purchase_unit text:=private.clean_purchase_text(payload->>'unit',null,20);
  qty numeric;
  cost numeric;
  day date;
begin
  issue:=private.require_maintenance_purchase_issue(actor_user_id,target_issue_id);
  begin
    qty:=(payload->>'quantity')::numeric;
    cost:=(payload->>'amount')::numeric;
    day:=(payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid maintenance purchase payload' using errcode='22023';
  end;
  if item is null or qty<=0 or cost<0 or day is null or purchase_unit not in ('pcs','meter','kg','box','bag','roll','set','liter','other') then
    raise exception 'invalid maintenance purchase payload' using errcode='22023';
  end if;
  return query
    insert into public.maintenance_purchase_logs(organization_id,branch_id,maintenance_issue_id,maintenance_user_id,item_name,quantity,unit,amount,vendor_name,purchase_date,notes,receipt_storage_path,receipt_original_name)
    values(issue.organization_id,issue.branch_id,issue.id,actor_user_id,item,qty,purchase_unit,cost,vendor,day,notes_value,path,filename)
    returning *;
end;
$$;

create or replace function public.list_managed_maintenance_purchases(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  issue_status_filter text default null, payment_status_filter text default null,
  vendor_filter text default null, date_from_filter date default null, date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, maintenance_issue_id uuid,
  issue_title text, issue_category text, issue_status text, maintenance_user_id uuid,
  maintenance_user_name text, item_name text, quantity numeric, unit text, amount numeric, vendor_name text,
  purchase_date date, notes text, payment_status text, reimbursement_note text, reimbursed_at timestamptz,
  receipt_storage_path text, receipt_original_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or (branch_filter is not null and not exists(select 1 from public.branches b where b.id=branch_filter and b.organization_id=target_organization_id))
    or (issue_status_filter is not null and issue_status_filter not in ('new','in_progress','waiting_parts','resolved','closed'))
    or (payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed'))
    or (date_from_filter is not null and date_to_filter is not null and date_from_filter>date_to_filter) then
    raise exception 'maintenance purchase access denied' using errcode='42501';
  end if;
  return query
    select p.id,p.organization_id,p.branch_id,b.name,p.maintenance_issue_id,i.title,i.category,i.status,p.maintenance_user_id,
      profile.full_name,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,
      p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    join public.branches b on b.id=p.branch_id
    join public.maintenance_issues i on i.id=p.maintenance_issue_id and i.organization_id=target_organization_id
    left join public.profiles profile on profile.id=p.maintenance_user_id
    where p.organization_id=target_organization_id
      and (branch_filter is null or p.branch_id=branch_filter)
      and (issue_status_filter is null or i.status=issue_status_filter)
      and (payment_status_filter is null or p.payment_status=payment_status_filter)
      and (vendor_filter is null or p.vendor_name ilike '%'||vendor_filter||'%')
      and (date_from_filter is null or p.purchase_date>=date_from_filter)
      and (date_to_filter is null or p.purchase_date<=date_to_filter)
    order by p.purchase_date desc,p.created_at desc;
end;
$$;

revoke all on function public.list_maintenance_purchase_logs(uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_maintenance_purchase_log(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date) from public,anon,authenticated;
grant execute on function public.list_maintenance_purchase_logs(uuid,uuid) to service_role;
grant execute on function public.create_maintenance_purchase_log(uuid,uuid,jsonb) to service_role;
grant execute on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date) to service_role;
