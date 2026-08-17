-- Manager Sales Tracking reports: read submitted rows across a managed organization.

create function public.list_managed_sales_tracking_reports(
  actor_user_id uuid,
  target_organization_id uuid,
  from_date date default null,
  to_date date default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (from_date is not null and to_date is not null and from_date > to_date) then
    raise exception 'sales tracking report access denied' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'sales_rows',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'report_id', report.id,
        'row_id', row.id,
        'business_date', report.business_date,
        'entry_date', row.entry_date,
        'branch_id', report.branch_id,
        'branch_name', report.branch_name_snapshot,
        'supervisor_user_id', report.supervisor_user_id,
        'submitted_by', report.supervisor_name_snapshot,
        'supervisor_team_id', report.supervisor_team_id,
        'supervisor_team_name', report.supervisor_team_name_snapshot,
        'submitted_at', report.submitted_at,
        'actual_cash', row.actual_cash,
        'actual_credit', row.actual_credit,
        'pos_cash', row.pos_cash,
        'pos_credit', row.pos_credit,
        'online_delivery', row.online_delivery,
        'actual_total', row.actual_cash + row.actual_credit + row.online_delivery,
        'pos_total', row.pos_cash + row.pos_credit + row.online_delivery,
        'variance', (row.actual_cash + row.actual_credit + row.online_delivery)
          - (row.pos_cash + row.pos_credit + row.online_delivery),
        'remarks', row.remarks
      ) order by report.business_date desc, report.branch_name_snapshot, row.entry_date desc, row.id)
      from public.sales_tracking_reports report
      join public.sales_tracking_sales_rows row on row.report_id = report.id
      where report.organization_id = target_organization_id
        and report.state = 'submitted'
        and report.submitted_at is not null
        and (from_date is null or report.business_date >= from_date)
        and (to_date is null or report.business_date <= to_date)
    ), '[]'::jsonb),
    'cash_rows',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'report_id', report.id,
        'row_id', row.id,
        'business_date', report.business_date,
        'entry_date', row.entry_date,
        'branch_id', report.branch_id,
        'branch_name', report.branch_name_snapshot,
        'supervisor_user_id', report.supervisor_user_id,
        'submitted_by', report.supervisor_name_snapshot,
        'supervisor_team_id', report.supervisor_team_id,
        'supervisor_team_name', report.supervisor_team_name_snapshot,
        'submitted_at', report.submitted_at,
        'denom_1', row.denom_1,
        'denom_2', row.denom_2,
        'denom_5', row.denom_5,
        'denom_10', row.denom_10,
        'denom_20', row.denom_20,
        'denom_50', row.denom_50,
        'denom_100', row.denom_100,
        'denom_200', row.denom_200,
        'denom_500', row.denom_500,
        'cash_total', row.denom_1 + row.denom_2 * 2 + row.denom_5 * 5 + row.denom_10 * 10
          + row.denom_20 * 20 + row.denom_50 * 50 + row.denom_100 * 100 + row.denom_200 * 200
          + row.denom_500 * 500,
        'remaining_cash', row.remaining_cash,
        'remarks', row.remarks
      ) order by report.business_date desc, report.branch_name_snapshot, row.entry_date desc, row.id)
      from public.sales_tracking_reports report
      join public.sales_tracking_cash_rows row on row.report_id = report.id
      where report.organization_id = target_organization_id
        and report.state = 'submitted'
        and report.submitted_at is not null
        and (from_date is null or report.business_date >= from_date)
        and (to_date is null or report.business_date <= to_date)
    ), '[]'::jsonb)
  );
end $$;

revoke all on function public.list_managed_sales_tracking_reports(uuid,uuid,date,date)
  from public, anon, authenticated;
grant execute on function public.list_managed_sales_tracking_reports(uuid,uuid,date,date)
  to service_role;
