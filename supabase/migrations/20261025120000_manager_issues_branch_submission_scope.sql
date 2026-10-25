-- Manager Issues must derive requirements from the shared ledger identity, not
-- from the supervisor who happened to create or submit the ledger.

create or replace function private.management_closed_business_date_at(branch_timezone text, as_of timestamptz)
returns date
language sql
stable
strict
security definer
set search_path = ''
as $$
  select case
    when private.management_branch_closed(branch_timezone, as_of)
      then private.phase4a_business_date_at(branch_timezone, as_of) - 1
    else null
  end
$$;
revoke all on function private.management_closed_business_date_at(text,timestamptz)
  from public, anon, authenticated;

create or replace function private.management_branch_existed_at_business_day_start(
  branch_timezone text,
  branch_created_at timestamptz,
  target_business_date date
)
returns boolean
language sql
stable
strict
security definer
set search_path = ''
as $$
  select branch_created_at <= (
    target_business_date::timestamp + time '04:00'
  ) at time zone branch_timezone
$$;
revoke all on function private.management_branch_existed_at_business_day_start(text,timestamptz,date)
  from public, anon, authenticated;

create or replace function private.phase4a_managed_missed_issue_rows_at(
  target_organization_id uuid,
  as_of timestamptz
)
returns table(
  id uuid,
  report_id uuid,
  branch_id uuid,
  branch_name text,
  business_date date,
  supervisor_user_id uuid,
  submitted_by text,
  checklist_type text,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text,
  affected_staff_id uuid,
  affected_staff_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  with active_branches as materialized (
    select branch.id, branch.name, branch.timezone, branch.created_at,
      private.management_closed_business_date_at(branch.timezone, as_of) business_date
    from public.branches branch
    where branch.organization_id = target_organization_id
      and branch.active
  ),
  required_opening as (
    select branch.id branch_id, branch.name branch_name, branch.business_date,
      checklist.checklist_type
    from active_branches branch
    cross join (values ('kitchen_opening'::text), ('foh_opening'::text)) checklist(checklist_type)
    where branch.business_date is not null
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.business_date
      )
      and not exists (
        select 1
        from public.checklist_submissions submission
        where submission.organization_id = target_organization_id
          and submission.branch_id = branch.id
          and submission.business_date = branch.business_date
          and submission.checklist_type = checklist.checklist_type
          and submission.state = 'submitted'
      )
  ),
  hygiene_roster as materialized (
    select distinct branch.id branch_id, branch.name branch_name, branch.business_date,
      team.id operational_team_id, team.name operational_team_name
    from active_branches branch
    join public.branch_operational_teams team
      on team.organization_id = target_organization_id
      and team.branch_id = branch.id
      and team.active
      and team.created_at <= (
        branch.business_date::timestamp + interval '1 day' + time '04:00'
      ) at time zone branch.timezone
    join public.operational_staff_assignments assignment
      on assignment.organization_id = target_organization_id
      and assignment.branch_id = branch.id
      and assignment.operational_team_id = team.id
      and assignment.valid_from <= branch.business_date
      and (assignment.valid_to is null or assignment.valid_to >= branch.business_date)
    join public.operational_staff staff
      on staff.id = assignment.operational_staff_id
      and staff.organization_id = target_organization_id
    left join public.operational_staff_duty_statuses duty
      on duty.assignment_id = assignment.id
      and duty.operational_staff_id = staff.id
      and duty.duty_date = branch.business_date
    where branch.business_date is not null
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
  ),
  required_hygiene as (
    select roster.*
    from hygiene_roster roster
    where not exists (
      select 1
      from public.checklist_submissions submission
      where submission.organization_id = target_organization_id
        and submission.branch_id = roster.branch_id
        and submission.operational_team_id = roster.operational_team_id
        and submission.business_date = roster.business_date
        and submission.checklist_type = 'staff_hygiene'
        and submission.state = 'submitted'
    )
  ),
  missed as (
    select opening.branch_id, opening.branch_name, opening.business_date,
      null::uuid operational_team_id, opening.checklist_type
    from required_opening opening
    union all
    select hygiene.branch_id, hygiene.branch_name, hygiene.business_date,
      hygiene.operational_team_id, 'staff_hygiene'::text checklist_type
    from required_hygiene hygiene
  )
  select
    private.management_missed_issue_id(
      'phase4a:missed:' || missed.checklist_type || ':' || missed.branch_id || ':' ||
      coalesce(missed.operational_team_id::text || ':', '') || missed.business_date
    ) id,
    private.management_missed_issue_id(
      'phase4a:missing-report:' || missed.checklist_type || ':' || missed.branch_id || ':' ||
      coalesce(missed.operational_team_id::text || ':', '') || missed.business_date
    ) report_id,
    missed.branch_id,
    missed.branch_name,
    missed.business_date,
    null::uuid supervisor_user_id,
    null::text submitted_by,
    missed.checklist_type,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening not checked'
      when 'foh_opening' then 'FOH Opening not checked'
      else 'Staff Hygiene not checked'
    end title,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening was not submitted before the 04:00 operational close.'
      when 'foh_opening' then 'FOH Opening was not submitted before the 04:00 operational close.'
      else 'Staff Hygiene was not submitted before the 04:00 operational close.'
    end description,
    'new'::text status,
    (missed.business_date::timestamp + interval '1 day' + time '04:00') at time zone branch.timezone created_at,
    'not_checked'::text item_id,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening not checked'
      when 'foh_opening' then 'FOH Opening not checked'
      else 'Staff Hygiene not checked'
    end item_text,
    null::uuid affected_staff_id,
    null::text affected_staff_name
  from missed
  join active_branches branch on branch.id = missed.branch_id
$$;
revoke all on function private.phase4a_managed_missed_issue_rows_at(uuid,timestamptz)
  from public, anon, authenticated;

create or replace function private.phase4a_managed_missed_issue_rows(target_organization_id uuid)
returns table(
  id uuid, report_id uuid, branch_id uuid, branch_name text, business_date date,
  supervisor_user_id uuid, submitted_by text, checklist_type text, title text,
  description text, status text, created_at timestamptz, item_id text, item_text text,
  affected_staff_id uuid, affected_staff_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select *
  from private.phase4a_managed_missed_issue_rows_at(
    target_organization_id,
    pg_catalog.statement_timestamp()
  )
$$;
revoke all on function private.phase4a_managed_missed_issue_rows(uuid)
  from public, anon, authenticated;

create or replace function private.oil_tracking_managed_missed_issue_rows_at(
  target_organization_id uuid,
  as_of timestamptz
)
returns table(
  id uuid, report_id uuid, branch_id uuid, branch_name text, business_date date,
  supervisor_user_id uuid, submitted_by text, section text, title text,
  description text, status text, created_at timestamptz, item_id text, item_text text
)
language sql
stable
security definer
set search_path = ''
as $$
  with active_branches as materialized (
    select branch.id, branch.name, branch.timezone, branch.created_at,
      private.phase4a_business_date_at(branch.timezone, as_of) current_business_date,
      private.management_closed_business_date_at(branch.timezone, as_of) closed_business_date
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  required_sections as (
    select branch.id branch_id, branch.name branch_name, branch.timezone,
      branch.current_business_date business_date, 'opening'::text section,
      (branch.current_business_date::timestamp + time '15:00') at time zone branch.timezone cutoff_at
    from active_branches branch
    where as_of >= (branch.current_business_date::timestamp + time '15:00') at time zone branch.timezone
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.current_business_date
      )
    union all
    select branch.id, branch.name, branch.timezone,
      branch.closed_business_date, 'opening'::text,
      (branch.closed_business_date::timestamp + time '15:00') at time zone branch.timezone
    from active_branches branch
    where branch.closed_business_date is not null
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.closed_business_date
      )
    union all
    select branch.id, branch.name, branch.timezone,
      branch.closed_business_date, 'closing'::text,
      (branch.closed_business_date::timestamp + interval '1 day' + time '04:00') at time zone branch.timezone
    from active_branches branch
    where branch.closed_business_date is not null
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.closed_business_date
      )
  ),
  selected as (
    select required.*, submission.id submission_id, submission.opening_submitted_at,
      submission.closing_submitted_at, coalesce(active_fryers.active_count, 0) active_count
    from required_sections required
    left join lateral (
      select candidate.*
      from public.oil_tracking_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = required.branch_id
        and candidate.business_date = required.business_date
      order by candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
    left join lateral (
      select pg_catalog.count(result.id)::int active_count
      from public.oil_tracking_fryer_results result
      where result.submission_id = submission.id and result.in_use_today
    ) active_fryers on true
  ),
  missed as (
    select *
    from selected unit
    where (unit.submission_id is null or unit.active_count > 0)
      and case unit.section
        when 'opening' then unit.opening_submitted_at is null
        else unit.closing_submitted_at is null
      end
  )
  select
    private.management_missed_issue_id(
      'oil_tracking:missed:' || missed.section || ':' || missed.branch_id || ':' || missed.business_date
    ) id,
    coalesce(missed.submission_id, private.management_missed_issue_id(
      'oil_tracking:missing-report:' || missed.branch_id || ':' || missed.business_date
    )) report_id,
    missed.branch_id, missed.branch_name, missed.business_date,
    null::uuid supervisor_user_id, null::text submitted_by, missed.section,
    'Oil Tracking ' || missed.section || ' not checked' title,
    'Oil Tracking ' || missed.section || ' section was not submitted before its required close.' description,
    'new'::text status,
    missed.cutoff_at created_at,
    'missed:' || missed.section item_id,
    'Missed ' || missed.section || ' section' item_text
  from missed
$$;
revoke all on function private.oil_tracking_managed_missed_issue_rows_at(uuid,timestamptz)
  from public, anon, authenticated;

create or replace function private.oil_tracking_managed_missed_issue_rows(target_organization_id uuid)
returns table(
  id uuid, report_id uuid, branch_id uuid, branch_name text, business_date date,
  supervisor_user_id uuid, submitted_by text, section text, title text,
  description text, status text, created_at timestamptz, item_id text, item_text text
)
language sql
stable
security definer
set search_path = ''
as $$
  select *
  from private.oil_tracking_managed_missed_issue_rows_at(
    target_organization_id,
    pg_catalog.statement_timestamp()
  )
$$;
revoke all on function private.oil_tracking_managed_missed_issue_rows(uuid)
  from public, anon, authenticated;

create or replace function private.cold_storage_managed_missed_issue_rows_at(
  target_organization_id uuid,
  as_of timestamptz
)
returns table(
  id uuid, report_id uuid, branch_id uuid, branch_name text, business_date date,
  supervisor_user_id uuid, submitted_by text, slot text, title text,
  description text, status text, created_at timestamptz, item_id text, item_text text
)
language sql
stable
security definer
set search_path = ''
as $$
  with active_branches as materialized (
    select branch.id, branch.name, branch.timezone, branch.created_at,
      private.phase4a_business_date_at(branch.timezone, as_of) current_business_date,
      private.management_branch_closed(branch.timezone, as_of) operational_closed
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  candidate_dates as materialized (
    select branch.id branch_id, branch.name branch_name, branch.timezone,
      branch.current_business_date business_date
    from active_branches branch
    where private.management_branch_existed_at_business_day_start(
      branch.timezone, branch.created_at, branch.current_business_date
    )
    union
    select branch.id, branch.name, branch.timezone,
      branch.current_business_date - 1
    from active_branches branch
    where branch.operational_closed
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.current_business_date - 1
      )
    union
    select submission.branch_id, branch.name, branch.timezone, submission.business_date
    from public.cold_storage_submissions submission
    join active_branches branch on branch.id = submission.branch_id
    where submission.organization_id = target_organization_id
      and submission.business_date <= branch.current_business_date
  ),
  selected_units as materialized (
    select candidate.*, submission.id submission_id, submission.updated_at,
      coalesce(equipment.active_count, 0) active_count
    from candidate_dates candidate
    left join lateral (
      select ledger.*
      from public.cold_storage_submissions ledger
      where ledger.organization_id = target_organization_id
        and ledger.branch_id = candidate.branch_id
        and ledger.business_date = candidate.business_date
      order by ledger.updated_at desc, ledger.id
      limit 1
    ) submission on true
    left join lateral (
      select pg_catalog.count(e.id)::int active_count
      from public.cold_storage_equipment e
      where e.submission_id = submission.id and e.active
    ) equipment on true
  ),
  submitted_slots as materialized (
    select unit.branch_id, unit.business_date, unit.submission_id,
      coalesce(pg_catalog.array_agg(distinct reading.slot) filter (where reading.slot is not null), array[]::text[]) slots
    from selected_units unit
    left join public.cold_storage_equipment equipment
      on equipment.submission_id = unit.submission_id and equipment.active
    left join public.cold_storage_readings reading
      on reading.submission_id = unit.submission_id
      and reading.equipment_id = equipment.equipment_id
      and reading.submitted_at is not null
    group by unit.branch_id, unit.business_date, unit.submission_id
  ),
  required_units as (
    select unit.*, coalesce(submitted.slots, array[]::text[]) submitted
    from selected_units unit
    left join submitted_slots submitted
      on submitted.branch_id = unit.branch_id
      and submitted.business_date = unit.business_date
      and submitted.submission_id is not distinct from unit.submission_id
    where unit.submission_id is null or unit.active_count > 0
  )
  select
    case when unit.submission_id is null
      then private.management_missed_issue_id(
        'cold_storage:missed:' || unit.branch_id || ':' || unit.business_date || ':' || missed.slot
      )
      else private.cold_storage_missed_issue_id(unit.submission_id, missed.slot)
    end id,
    coalesce(unit.submission_id, private.management_missed_issue_id(
      'cold_storage:missing-report:' || unit.branch_id || ':' || unit.business_date
    )) report_id,
    unit.branch_id, unit.branch_name, unit.business_date,
    null::uuid supervisor_user_id, null::text submitted_by, missed.slot,
    'Chiller & Freezer missed scheduled check - ' || missed.slot title,
    missed.slot || ' scheduled Chiller & Freezer check was not submitted.' description,
    'new'::text status,
    coalesce(unit.updated_at,
      case missed.slot
        when '12:00' then unit.business_date::timestamp + time '20:00'
        when '20:00' then (unit.business_date + 1)::timestamp + time '02:00'
        else (unit.business_date + 1)::timestamp + time '04:00'
      end at time zone unit.timezone
    ) created_at,
    'missed:' || missed.slot item_id,
    'Missed ' || missed.slot || ' scheduled check' item_text
  from required_units unit
  cross join lateral pg_catalog.unnest(
    private.cold_storage_missed_slots_for(
      unit.branch_id, unit.business_date, unit.submitted, as_of
    )
  ) missed(slot)
$$;
revoke all on function private.cold_storage_managed_missed_issue_rows_at(uuid,timestamptz)
  from public, anon, authenticated;

create or replace function private.cold_storage_managed_missed_issue_rows(target_organization_id uuid)
returns table(
  id uuid, report_id uuid, branch_id uuid, branch_name text, business_date date,
  supervisor_user_id uuid, submitted_by text, slot text, title text,
  description text, status text, created_at timestamptz, item_id text, item_text text
)
language sql
stable
security definer
set search_path = ''
as $$
  select *
  from private.cold_storage_managed_missed_issue_rows_at(
    target_organization_id,
    pg_catalog.statement_timestamp()
  )
$$;
revoke all on function private.cold_storage_managed_missed_issue_rows(uuid)
  from public, anon, authenticated;

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
  with active_branches as materialized (
    select branch.id, branch.name, branch.timezone, branch.created_at,
      private.management_closed_business_date_at(branch.timezone, as_of) business_date
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  submitted_reports as materialized (
    select report.id, report.branch_id, report.business_date, report.supervisor_user_id,
      report.branch_name_snapshot, report.supervisor_name_snapshot, report.submitted_at,
      coalesce(pg_catalog.sum(row.actual_cash + row.actual_credit + row.online_delivery), 0) actual_total,
      coalesce(pg_catalog.sum(row.pos_cash + row.pos_credit + row.online_delivery), 0) pos_total
    from public.sales_tracking_report_cases report_case
    join public.sales_tracking_reports report
      on report.id = report_case.authoritative_report_id
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
      (branch.business_date::timestamp + interval '1 day' + time '04:00') at time zone branch.timezone created_at,
      'not_checked'::text item_id, 'Sales Tracking not checked'::text item_text,
      0::numeric actual_total, 0::numeric pos_total, 0::numeric variance
    from active_branches branch
    where branch.business_date is not null
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.business_date
      )
      and not exists (
        select 1
        from public.sales_tracking_report_cases report_case
        join public.sales_tracking_reports report
          on report.id = report_case.authoritative_report_id
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

create or replace function private.sales_tracking_managed_issue_rows(target_organization_id uuid)
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
  select *
  from private.sales_tracking_managed_issue_rows_at(
    target_organization_id,
    pg_catalog.statement_timestamp()
  )
$$;
revoke all on function private.sales_tracking_managed_issue_rows(uuid)
  from public, anon, authenticated;

-- Public Manager Issues RPC signatures and their existing service_role-only grants
-- are intentionally unchanged.
