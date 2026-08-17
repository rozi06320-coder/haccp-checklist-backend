create or replace function public.get_managed_operations_summary(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  requested_month date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_month date;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'operations summary access denied' using errcode = '42501';
  end if;

  selected_month := coalesce(requested_month, pg_catalog.date_trunc('month', pg_catalog.statement_timestamp())::date);
  if selected_month <> pg_catalog.date_trunc('month', selected_month)::date then
    raise exception 'invalid operations summary month' using errcode = '22023';
  end if;

  if branch_filter is not null and not exists (
    select 1
    from public.branches branch
    where branch.id = branch_filter
      and branch.organization_id = target_organization_id
      and branch.active
  ) then
    raise exception 'operations summary access denied' using errcode = '42501';
  end if;

  return (
    with active_branches as (
      select branch.id
      from public.branches branch
      where branch.organization_id = target_organization_id
        and branch.active
        and (branch_filter is null or branch.id = branch_filter)
    ),
    purchase_logs as (
      select
        count(*)::integer as unpaid_count,
        coalesce(sum(log.amount), 0)::text as unpaid_amount,
        coalesce((select sum(total_log.amount) from public.branch_purchase_logs total_log where total_log.organization_id = target_organization_id and (branch_filter is null or total_log.branch_id = branch_filter)), 0)::text as total_amount
      from public.branch_purchase_logs log
      where log.organization_id = target_organization_id
        and (branch_filter is null or log.branch_id = branch_filter)
        and log.payment_status = 'unpaid'
    ),
    supplier_receivings as (
      select count(*)::integer as entry_count, count(distinct receiving.branch_id)::integer as branch_count
      from public.branch_supplier_receivings receiving
      where receiving.organization_id = target_organization_id
        and (branch_filter is null or receiving.branch_id = branch_filter)
    ),
    maintenance_issues as (
      select
        (count(*) filter (where issue.status in ('new', 'in_progress', 'waiting_parts')))::integer as open_count,
        (count(*) filter (where issue.status in ('new', 'in_progress', 'waiting_parts') and issue.priority in ('urgent', 'high')))::integer as urgent_high_count
      from public.maintenance_issues issue
      where issue.organization_id = target_organization_id
        and (branch_filter is null or issue.branch_id = branch_filter)
    ),
    maintenance_purchases as (
      select
        count(*)::integer as purchase_count,
        coalesce(sum(purchase.amount), 0)::text as total_amount,
        (count(*) filter (where purchase.payment_status = 'unpaid'))::integer as unpaid_count,
        coalesce(sum(purchase.amount) filter (where purchase.payment_status = 'unpaid'), 0)::text as unpaid_amount
      from public.maintenance_purchase_logs purchase
      where purchase.organization_id = target_organization_id
        and (branch_filter is null or purchase.branch_id = branch_filter)
    ),
    inventory_reports as (
      select report.id, report.branch_id, report.state
      from public.inventory_items_reports report
      join active_branches branch on branch.id = report.branch_id
      where report.organization_id = target_organization_id
        and report.inventory_month = selected_month
    ),
    inventory as (
      select
        (select count(*)::integer from active_branches) as active_branch_count,
        count(distinct report.branch_id)::integer as reported_branch_count,
        count(distinct report.branch_id) filter (where report.state = 'submitted')::integer as submitted_branch_count,
        coalesce((select count(*)::integer from public.inventory_beef_production_rows beef join inventory_reports report on report.id = beef.report_id), 0) as beef_row_count,
        coalesce((select count(*)::integer from public.inventory_item_usage_items item join inventory_reports report on report.id = item.report_id), 0) as item_usage_row_count
      from inventory_reports report
    ),
    staff as (
      select
        (count(*) filter (where member.employment_status = 'active'))::integer as active_count,
        (count(*) filter (where member.employment_status = 'inactive'))::integer as inactive_count
      from public.operational_staff member
      where member.organization_id = target_organization_id
        and (branch_filter is null or member.branch_id = branch_filter)
    )
    select pg_catalog.jsonb_build_object(
      'generated_at', pg_catalog.statement_timestamp(),
      'scope', pg_catalog.jsonb_build_object(
        'organization_id', target_organization_id,
        'branch_id', branch_filter,
        'month', pg_catalog.to_char(selected_month, 'YYYY-MM')
      ),
      'purchase_logs', pg_catalog.jsonb_build_object('unpaid_count', purchase_logs.unpaid_count, 'unpaid_amount', purchase_logs.unpaid_amount, 'total_amount', purchase_logs.total_amount),
      'supplier_receivings', pg_catalog.jsonb_build_object('entry_count', supplier_receivings.entry_count, 'branch_count', supplier_receivings.branch_count),
      'maintenance_issues', pg_catalog.jsonb_build_object('open_count', maintenance_issues.open_count, 'urgent_high_count', maintenance_issues.urgent_high_count),
      'maintenance_purchases', pg_catalog.jsonb_build_object('purchase_count', maintenance_purchases.purchase_count, 'total_amount', maintenance_purchases.total_amount, 'unpaid_count', maintenance_purchases.unpaid_count, 'unpaid_amount', maintenance_purchases.unpaid_amount),
      'inventory', pg_catalog.jsonb_build_object('active_branch_count', inventory.active_branch_count, 'reported_branch_count', inventory.reported_branch_count, 'submitted_branch_count', inventory.submitted_branch_count, 'beef_row_count', inventory.beef_row_count, 'item_usage_row_count', inventory.item_usage_row_count),
      'staff', pg_catalog.jsonb_build_object('active_count', staff.active_count, 'inactive_count', staff.inactive_count),
      'availability', pg_catalog.jsonb_build_object('purchase_logs', 'ready', 'supplier_receivings', 'ready', 'maintenance_issues', 'ready', 'maintenance_purchases', 'ready', 'inventory', 'ready', 'staff', 'ready')
    )
    from purchase_logs, supplier_receivings, maintenance_issues, maintenance_purchases, inventory, staff
  );
end;
$$;

revoke all on function public.get_managed_operations_summary(uuid,uuid,uuid,date) from public, anon, authenticated;
grant execute on function public.get_managed_operations_summary(uuid,uuid,uuid,date) to service_role;
