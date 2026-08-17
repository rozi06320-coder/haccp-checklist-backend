-- Read-only Manager monthly Sales Tracking aggregates from submitted reports.

create or replace function public.get_managed_sales_tracking_monthly_summary(
  actor_user_id uuid,
  target_organization_id uuid,
  target_month date,
  branch_filter uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  if target_month is null
    or target_month <> pg_catalog.date_trunc('month', target_month)::date
  then
    raise exception 'invalid sales tracking month' using errcode = '22023';
  end if;

  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'sales tracking monthly summary access denied' using errcode = '42501';
  end if;

  if branch_filter is not null and not exists (
    select 1
    from public.branches branch
    where branch.id = branch_filter
      and branch.organization_id = target_organization_id
  ) then
    raise exception 'sales tracking monthly summary branch denied' using errcode = '42501';
  end if;

  with
  scoped_reports as materialized (
    select report.id, report.branch_id, report.business_date,
      branch.name branch_name, branch.name_ar branch_name_ar, branch.code branch_code
    from public.sales_tracking_reports report
    join public.branches branch
      on branch.id = report.branch_id
      and branch.organization_id = report.organization_id
    where report.organization_id = target_organization_id
      and report.state = 'submitted'
      and report.submitted_at is not null
      and report.business_date >= target_month
      and report.business_date < (target_month + interval '1 month')::date
      and (branch_filter is null or report.branch_id = branch_filter)
  ),
  sales_by_report as materialized (
    select report.id report_id,
      pg_catalog.count(row.id)::bigint sales_entry_count,
      coalesce(pg_catalog.sum(row.actual_cash), 0::numeric) actual_cash,
      coalesce(pg_catalog.sum(row.actual_credit), 0::numeric) actual_credit,
      coalesce(pg_catalog.sum(row.online_delivery), 0::numeric) online_delivery,
      coalesce(pg_catalog.sum(row.pos_cash), 0::numeric) pos_cash,
      coalesce(pg_catalog.sum(row.pos_credit), 0::numeric) pos_credit
    from scoped_reports report
    left join public.sales_tracking_sales_rows row on row.report_id = report.id
    group by report.id
  ),
  cash_by_report as materialized (
    select report.id report_id,
      pg_catalog.count(row.id)::bigint cash_entry_count,
      coalesce(pg_catalog.sum(
        row.denom_1 + row.denom_2 * 2 + row.denom_5 * 5 + row.denom_10 * 10
        + row.denom_20 * 20 + row.denom_50 * 50 + row.denom_100 * 100
        + row.denom_200 * 200 + row.denom_500 * 500
      ), 0::bigint)::numeric total_cash_collected
    from scoped_reports report
    left join public.sales_tracking_cash_rows row on row.report_id = report.id
    group by report.id
  ),
  report_metrics as materialized (
    select report.id, report.branch_id, report.business_date,
      report.branch_name, report.branch_name_ar, report.branch_code,
      sales.sales_entry_count, cash.cash_entry_count,
      sales.actual_cash, sales.actual_credit, sales.online_delivery,
      sales.pos_cash, sales.pos_credit,
      sales.actual_cash + sales.actual_credit + sales.online_delivery total_sales,
      sales.actual_cash + sales.actual_credit - sales.pos_cash - sales.pos_credit total_variance,
      cash.total_cash_collected
    from scoped_reports report
    join sales_by_report sales on sales.report_id = report.id
    join cash_by_report cash on cash.report_id = report.id
  ),
  totals as materialized (
    select
      pg_catalog.count(*)::bigint submitted_report_count,
      pg_catalog.count(distinct (branch_id, business_date))::bigint submitted_branch_day_count,
      pg_catalog.count(distinct branch_id)::bigint reporting_branch_count,
      coalesce(pg_catalog.sum(sales_entry_count), 0::numeric)::bigint sales_entry_count,
      coalesce(pg_catalog.sum(cash_entry_count), 0::numeric)::bigint cash_entry_count,
      coalesce(pg_catalog.sum(total_sales), 0::numeric) total_sales,
      coalesce(pg_catalog.sum(total_cash_collected), 0::numeric) total_cash_collected,
      coalesce(pg_catalog.sum(total_variance), 0::numeric) total_variance,
      pg_catalog.count(*) filter (
        where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) = 0
      )::bigint balanced_sales_report_count,
      pg_catalog.count(*) filter (
        where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) <> 0
      )::bigint variance_sales_report_count,
      coalesce(pg_catalog.sum(actual_cash), 0::numeric) actual_cash,
      coalesce(pg_catalog.sum(actual_credit), 0::numeric) actual_credit,
      coalesce(pg_catalog.sum(online_delivery), 0::numeric) online_delivery,
      coalesce(pg_catalog.sum(pos_cash), 0::numeric) pos_cash,
      coalesce(pg_catalog.sum(pos_credit), 0::numeric) pos_credit
    from report_metrics
  ),
  branch_totals as materialized (
    select branch_id, branch_name, branch_name_ar, branch_code,
      pg_catalog.count(*)::bigint submitted_report_count,
      pg_catalog.count(distinct business_date)::bigint submitted_day_count,
      coalesce(pg_catalog.sum(sales_entry_count), 0::numeric)::bigint sales_entry_count,
      coalesce(pg_catalog.sum(cash_entry_count), 0::numeric)::bigint cash_entry_count,
      coalesce(pg_catalog.sum(total_sales), 0::numeric) total_sales,
      coalesce(pg_catalog.sum(total_cash_collected), 0::numeric) total_cash_collected,
      coalesce(pg_catalog.sum(total_variance), 0::numeric) total_variance,
      pg_catalog.count(*) filter (
        where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) = 0
      )::bigint balanced_sales_report_count,
      pg_catalog.count(*) filter (
        where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) <> 0
      )::bigint variance_sales_report_count,
      coalesce(pg_catalog.sum(actual_cash), 0::numeric) actual_cash,
      coalesce(pg_catalog.sum(actual_credit), 0::numeric) actual_credit,
      coalesce(pg_catalog.sum(online_delivery), 0::numeric) online_delivery,
      coalesce(pg_catalog.sum(pos_cash), 0::numeric) pos_cash,
      coalesce(pg_catalog.sum(pos_credit), 0::numeric) pos_credit
    from report_metrics
    group by branch_id, branch_name, branch_name_ar, branch_code
  )
  select pg_catalog.jsonb_build_object(
    'generated_at', pg_catalog.statement_timestamp(),
    'scope', pg_catalog.jsonb_build_object(
      'organization_id', target_organization_id,
      'branch_id', branch_filter,
      'month', pg_catalog.to_char(target_month, 'YYYY-MM'),
      'date_from', target_month,
      'date_to', (target_month + interval '1 month - 1 day')::date
    ),
    'totals', pg_catalog.jsonb_build_object(
      'submitted_report_count', totals.submitted_report_count,
      'submitted_branch_day_count', totals.submitted_branch_day_count,
      'reporting_branch_count', totals.reporting_branch_count,
      'sales_entry_count', totals.sales_entry_count,
      'cash_entry_count', totals.cash_entry_count,
      'total_sales', totals.total_sales::text,
      'total_cash_collected', totals.total_cash_collected::text,
      'total_variance', totals.total_variance::text,
      'balanced_sales_report_count', totals.balanced_sales_report_count,
      'variance_sales_report_count', totals.variance_sales_report_count,
      'payment_breakdown', pg_catalog.jsonb_build_object(
        'actual_cash', totals.actual_cash::text,
        'actual_credit', totals.actual_credit::text,
        'online_delivery', totals.online_delivery::text,
        'pos_cash', totals.pos_cash::text,
        'pos_credit', totals.pos_credit::text
      )
    ),
    'branches', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'branch_id', branch.branch_id,
        'branch_name', branch.branch_name,
        'branch_name_ar', branch.branch_name_ar,
        'branch_code', branch.branch_code,
        'submitted_report_count', branch.submitted_report_count,
        'submitted_day_count', branch.submitted_day_count,
        'sales_entry_count', branch.sales_entry_count,
        'cash_entry_count', branch.cash_entry_count,
        'total_sales', branch.total_sales::text,
        'total_cash_collected', branch.total_cash_collected::text,
        'total_variance', branch.total_variance::text,
        'balanced_sales_report_count', branch.balanced_sales_report_count,
        'variance_sales_report_count', branch.variance_sales_report_count,
        'payment_breakdown', pg_catalog.jsonb_build_object(
          'actual_cash', branch.actual_cash::text,
          'actual_credit', branch.actual_credit::text,
          'online_delivery', branch.online_delivery::text,
          'pos_cash', branch.pos_cash::text,
          'pos_credit', branch.pos_credit::text
        )
      ) order by branch.branch_name, branch.branch_id)
      from branch_totals branch
    ), '[]'::jsonb)
  ) into result
  from totals;

  return result;
end $$;

revoke all on function public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)
  from public, anon, authenticated;
grant execute on function public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)
  to service_role;
