begin;

-- Manager issue aggregation must use the branch-local business date for the
-- observation timestamp and authoritative historical branch lifecycle records
-- for active status and timezone attribution.
create or replace function private.sales_tracking_managed_issue_rows_at(
  target_organization_id uuid,
  as_of timestamptz
)
returns table(
  id uuid, report_id uuid, branch_id uuid, branch_name text, business_date date,
  supervisor_user_id uuid, submitted_by text, submitted_at timestamptz, title text,
  description text, status text, created_at timestamptz, item_id text, item_text text,
  actual_total numeric, pos_total numeric, variance numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  with candidate_branches as materialized (
    select
      branch.id,
      branch.name,
      branch.created_at,
      private.phase4a_business_date_at(branch.timezone, as_of) current_business_date
    from public.branches branch
    where branch.organization_id = target_organization_id
  ),
  branch_candidate_dates as materialized (
    select branch.id, branch.name, branch.created_at, branch.current_business_date business_date
    from candidate_branches branch
    union all
    select branch.id, branch.name, branch.created_at, branch.current_business_date - 1
    from candidate_branches branch
  ),
  branch_dates as materialized (
    select
      bcd.id,
      bcd.name,
      bcd.created_at,
      bcd.business_date,
      lifecycle.timezone
    from branch_candidate_dates bcd
    join public.daily_report_branch_lifecycle lifecycle
      on lifecycle.organization_id = target_organization_id
      and lifecycle.branch_id = bcd.id
      and lifecycle.effective_from_business_date <= bcd.business_date
      and (
        lifecycle.effective_to_business_date is null
        or lifecycle.effective_to_business_date > bcd.business_date
      )
    where lifecycle.active
      and private.daily_business_report_branch_close_at(bcd.business_date, lifecycle.timezone) <= as_of
  ),
  submitted_reports as materialized (
    select report.id, report.branch_id, report.business_date, report.supervisor_user_id,
      report.branch_name_snapshot, report.supervisor_name_snapshot, report.submitted_at,
      coalesce(pg_catalog.sum(row.actual_cash + row.actual_credit + row.online_delivery), 0) actual_total,
      coalesce(pg_catalog.sum(row.pos_cash + row.pos_credit + row.online_delivery), 0) pos_total
    from public.sales_tracking_report_cases report_case
    join public.sales_tracking_reports report
      on report.id = report_case.authoritative_report_id
      and report.case_id = report_case.id
      and report.organization_id = report_case.organization_id
      and report.branch_id = report_case.branch_id
      and report.business_date = report_case.business_date
    left join public.sales_tracking_sales_rows row on row.report_id = report.id
    where report_case.organization_id = target_organization_id
      and report.state = 'submitted'
      and report.submitted_at is not null
    group by report.id
  ),
  variance_issues as (
    select report.id, report.id report_id, report.branch_id,
      report.branch_name_snapshot branch_name, report.business_date,
      report.supervisor_user_id, report.supervisor_name_snapshot submitted_by,
      report.submitted_at, 'Sales Tracking variance issue'::text title,
      'Actual total ' || report.actual_total || ', POS total ' || report.pos_total ||
        ', variance ' || (report.actual_total - report.pos_total) || '.' description,
      'new'::text status, report.submitted_at created_at,
      'variance'::text item_id, 'Variance mismatch'::text item_text,
      report.actual_total, report.pos_total,
      report.actual_total - report.pos_total variance
    from submitted_reports report
    where pg_catalog.round(report.actual_total - report.pos_total, 2) <> 0
  ),
  missed_issues as (
    select
      private.sales_tracking_issue_uuid(
        'sales_tracking:missed:' || branch.id || ':' || branch.business_date
      ) id,
      private.sales_tracking_issue_uuid(
        'sales_tracking:missing-report:' || branch.id || ':' || branch.business_date
      ) report_id,
      branch.id branch_id, branch.name branch_name, branch.business_date,
      null::uuid supervisor_user_id, null::text submitted_by, null::timestamptz submitted_at,
      'Missing Sales Tracking submission'::text title,
      'Sales Tracking was not submitted before the 04:00 operational close.'::text description,
      'new'::text status,
      private.daily_business_report_branch_close_at(branch.business_date, branch.timezone) created_at,
      'not_checked'::text item_id, 'Sales Tracking not checked'::text item_text,
      0::numeric actual_total, 0::numeric pos_total, 0::numeric variance
    from branch_dates branch
    where branch.business_date is not null
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.business_date
      )
      and (
        select pg_catalog.count(*) = 1 and pg_catalog.bool_and(applicability.required)
        from public.daily_report_module_applicability applicability
        where applicability.organization_id = target_organization_id
          and applicability.branch_id = branch.id
          and applicability.module_key = 'sales_tracking'
          and applicability.effective_from_business_date <= branch.business_date
          and (
            applicability.effective_to_business_date is null
            or applicability.effective_to_business_date > branch.business_date
          )
      )
      and private.daily_business_report_branch_close_at(branch.business_date, branch.timezone) <= as_of
      and not exists (
        select 1
        from public.sales_tracking_report_cases report_case
        join public.sales_tracking_reports report
          on report.id = report_case.authoritative_report_id
          and report.case_id = report_case.id
          and report.organization_id = report_case.organization_id
          and report.branch_id = report_case.branch_id
          and report.business_date = report_case.business_date
        where report_case.organization_id = target_organization_id
          and report_case.branch_id = branch.id
          and report_case.business_date = branch.business_date
          and report.state = 'submitted'
          and report.submitted_at is not null
      )
  )
  select * from variance_issues
  union all
  select * from missed_issues
$$;

revoke all on function private.sales_tracking_managed_issue_rows_at(uuid,timestamptz)
  from public, anon, authenticated;

commit;
