create or replace function public.list_managed_maintenance_purchases(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  issue_status_filter text default null, payment_status_filter text default null,
  vendor_filter text default null, date_from_filter date default null, date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, maintenance_issue_id uuid,
  issue_title text, issue_category text, issue_status text, maintenance_user_id uuid,
  maintenance_user_name text, item_name text, quantity numeric, amount numeric, vendor_name text,
  purchase_date date, notes text, payment_status text, reimbursement_note text, reimbursed_at timestamptz,
  receipt_storage_path text, receipt_original_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path=public,private
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
    profile.full_name,p.item_name,p.quantity,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,
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
revoke all on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date) from public,anon,authenticated;
grant execute on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date) to service_role;
