-- 20261124120000_branch_day_off_applicability_reports_notifications.sql
-- HACCP Branch Day Off — Phase 3: Checklist Applicability, Reports & Notifications
--
-- Enforces per-branch Day Off rules across:
--   A. Daily report & Staff Hygiene authoritative applicability + Supervisor Day Off read status
--   B. Organization Manager Overview, Financial Closing Operations Summary, and Supervisor Overview
--   C. Derived-missing issues and reports (Phase 4A, Oil Tracking, Cold Storage, Sales Tracking)
--   D. Organization Manager & Supervisor missing/overdue notification producers and non-destructive projections
--
-- Preserves:
--   - All submission RPCs (voluntary draft & submit allowed during Branch Day Off)
--   - Sales Tracking Need Review workflow, statuses, UI, and correction logic
--   - 04:00 branch-local business-day rollover
--   - Branch-specific exemptions (sales_tracking_percentage_included, oil_tracking_percentage_included,
--     foh_opening_included, cold_storage_0200_notification_required, daily_report_module_applicability)
--   - Maintenance notifications and append-only notification audit history

begin;

-- =============================================================================
-- A. Applicability & Supervisor Branch Day Off Read RPC
-- =============================================================================

create or replace function public.get_daily_report_authoritative_applicability(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_business_date date,
  p_job_id uuid default null,
  p_lease_token uuid default null
)
returns table(
  branch_id uuid,
  timezone text,
  close_at timestamptz,
  module_key text,
  required boolean,
  requirement_basis text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_organization_id is null or p_business_date is null
    or not exists(
      select 1 from public.organizations organization
      where organization.id = p_organization_id and organization.active
    )
  then
    raise exception 'invalid daily business report organization or date' using errcode = '22023';
  end if;

  if p_actor_user_id is not null then
    if not private.actor_manages_active_organization(p_actor_user_id, p_organization_id)
      and not private.is_internal_admin(p_actor_user_id)
    then
      raise exception 'daily business report applicability access denied' using errcode = '42501';
    end if;
  elsif p_job_id is not null and p_lease_token is not null then
    if not exists (
      select 1 from private.daily_business_report_generation_jobs job
      where job.id = p_job_id
        and job.lease_token = p_lease_token
        and job.organization_id = p_organization_id
        and job.business_date = p_business_date
        and job.state = 'running'
        and job.lease_expires_at > pg_catalog.statement_timestamp()
    ) then
      raise exception 'daily business report generation lease invalid or expired' using errcode = '42501';
    end if;
  else
    raise exception 'daily business report applicability requires authenticated actor or authorized server lease'
      using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.daily_report_branch_lifecycle lifecycle
    join public.daily_report_module_applicability applicability
      on applicability.organization_id = lifecycle.organization_id
      and applicability.branch_id = lifecycle.branch_id
      and applicability.effective_from_business_date <= p_business_date
      and (applicability.effective_to_business_date is null
        or applicability.effective_to_business_date > p_business_date)
    where lifecycle.organization_id = p_organization_id
      and lifecycle.active
      and lifecycle.effective_from_business_date <= p_business_date
      and (lifecycle.effective_to_business_date is null
        or lifecycle.effective_to_business_date > p_business_date)
    group by lifecycle.branch_id, applicability.module_key
    having pg_catalog.count(*) > 1
  ) then
    raise exception 'daily business report module applicability duplicate records detected' using errcode = '22023';
  end if;

  if exists (
    with expected_modules as (
      select pg_catalog.unnest(array[
        'kitchen_opening',
        'foh_opening',
        'staff_hygiene',
        'daily_audit',
        'cold_storage',
        'oil_tracking',
        'sales_tracking'
      ]::text[]) as module_key
    ),
    active_branches as (
      select lifecycle.branch_id
      from public.daily_report_branch_lifecycle lifecycle
      where lifecycle.organization_id = p_organization_id
        and lifecycle.active
        and lifecycle.effective_from_business_date <= p_business_date
        and (lifecycle.effective_to_business_date is null
          or lifecycle.effective_to_business_date > p_business_date)
    ),
    expected_combinations as (
      select b.branch_id, m.module_key
      from active_branches b
      cross join expected_modules m
    ),
    actual_records as (
      select applicability.branch_id, applicability.module_key
      from active_branches b
      join public.daily_report_module_applicability applicability
        on applicability.organization_id = p_organization_id
        and applicability.branch_id = b.branch_id
        and applicability.effective_from_business_date <= p_business_date
        and (applicability.effective_to_business_date is null
          or applicability.effective_to_business_date > p_business_date)
    )
    select 1
    from expected_combinations ec
    left join actual_records ar
      on ar.branch_id = ec.branch_id
      and ar.module_key = ec.module_key
    where ar.module_key is null
  ) then
    raise exception 'daily business report module applicability missing' using errcode = '22023';
  end if;

  return query
  with active_lifecycle as materialized (
    select
      lifecycle.organization_id,
      lifecycle.branch_id,
      lifecycle.timezone,
      private.daily_business_report_branch_close_at(p_business_date, lifecycle.timezone) as close_at,
      private.is_branch_day_off(lifecycle.branch_id, p_business_date) as is_day_off
    from public.daily_report_branch_lifecycle lifecycle
    where lifecycle.organization_id = p_organization_id
      and lifecycle.active
      and lifecycle.effective_from_business_date <= p_business_date
      and (lifecycle.effective_to_business_date is null
        or lifecycle.effective_to_business_date > p_business_date)
  )
  select
    lifecycle.branch_id,
    lifecycle.timezone,
    lifecycle.close_at,
    applicability.module_key,
    case
      when lifecycle.is_day_off then false
      when applicability.module_key = 'staff_hygiene' then
        applicability.required
        and private.staff_hygiene_branch_has_eligible_staff(
          lifecycle.organization_id,
          lifecycle.branch_id,
          p_business_date
        )
      else applicability.required
    end,
    applicability.requirement_basis
  from active_lifecycle lifecycle
  join public.daily_report_module_applicability applicability
    on applicability.organization_id = lifecycle.organization_id
    and applicability.branch_id = lifecycle.branch_id
    and applicability.effective_from_business_date <= p_business_date
    and (applicability.effective_to_business_date is null
      or applicability.effective_to_business_date > p_business_date)
  order by lifecycle.branch_id, applicability.module_key;
end;
$$;

revoke all on function public.get_daily_report_authoritative_applicability(uuid, uuid, date, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_daily_report_authoritative_applicability(uuid, uuid, date, uuid, uuid)
  to service_role;

create or replace function public.get_daily_report_staff_hygiene_applicability(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_business_date date,
  p_job_id uuid default null,
  p_lease_token uuid default null
)
returns table(
  branch_id uuid,
  operational_team_id uuid,
  eligible_staff_count bigint,
  required boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_organization_id is null or p_business_date is null
    or not exists (
      select 1 from public.organizations organization
      where organization.id = p_organization_id and organization.active
    ) then
    raise exception 'invalid staff hygiene applicability scope' using errcode = '22023';
  end if;

  if p_actor_user_id is not null then
    if not private.actor_manages_active_organization(p_actor_user_id, p_organization_id)
      and not private.is_internal_admin(p_actor_user_id) then
      raise exception 'staff hygiene applicability access denied' using errcode = '42501';
    end if;
  elsif p_job_id is not null and p_lease_token is not null then
    if not exists (
      select 1 from private.daily_business_report_generation_jobs job
      where job.id = p_job_id
        and job.lease_token = p_lease_token
        and job.organization_id = p_organization_id
        and job.business_date = p_business_date
        and job.state = 'running'
        and job.lease_expires_at > pg_catalog.statement_timestamp()
    ) then
      raise exception 'daily business report generation lease invalid or expired' using errcode = '42501';
    end if;
  else
    raise exception 'staff hygiene applicability requires authenticated actor or authorized server lease'
      using errcode = '42501';
  end if;

  return query
  with eligible_branches as materialized (
    select
      branch.organization_id,
      branch.id as branch_id,
      private.is_branch_day_off(branch.id, p_business_date) as is_day_off
    from public.branches branch
    join public.daily_report_branch_lifecycle lifecycle
      on lifecycle.organization_id = branch.organization_id
      and lifecycle.branch_id = branch.id
      and lifecycle.active
      and lifecycle.effective_from_business_date <= p_business_date
      and (lifecycle.effective_to_business_date is null or lifecycle.effective_to_business_date > p_business_date)
    where branch.organization_id = p_organization_id
  )
  select
    eb.branch_id,
    team.id,
    pg_catalog.count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty')::bigint,
    (not eb.is_day_off)
      and pg_catalog.count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0
  from eligible_branches eb
  join public.branch_operational_teams team
    on team.organization_id = eb.organization_id
    and team.branch_id = eb.branch_id
    and team.active
  left join public.operational_staff_assignments assignment
    on assignment.organization_id = team.organization_id
    and assignment.branch_id = team.branch_id
    and assignment.operational_team_id = team.id
    and assignment.active
    and assignment.valid_from <= p_business_date
    and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
  left join public.operational_staff staff
    on staff.id = assignment.operational_staff_id
    and staff.organization_id = assignment.organization_id
    and staff.branch_id = assignment.branch_id
    and staff.employment_status = 'active'
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id = assignment.id
    and duty.operational_staff_id = assignment.operational_staff_id
    and duty.organization_id = assignment.organization_id
    and duty.branch_id = assignment.branch_id
    and duty.duty_date = p_business_date
  group by eb.branch_id, eb.is_day_off, team.id
  order by eb.branch_id, team.id;
end;
$$;

revoke all on function public.get_daily_report_staff_hygiene_applicability(uuid, uuid, date, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_daily_report_staff_hygiene_applicability(uuid, uuid, date, uuid, uuid)
  to service_role;

create or replace function public.get_manager_staff_hygiene_applicability_range(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_date_from date,
  p_date_to date
)
returns table(
  branch_id uuid,
  business_date date,
  operational_team_id uuid,
  eligible_staff_count bigint,
  required boolean,
  applicability text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_actor_user_id is null or p_organization_id is null
     or p_date_from is null or p_date_to is null
     or p_date_from > p_date_to
     or p_date_to - p_date_from >= 31 then
    raise exception 'invalid Staff Hygiene applicability date range' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id and organization.active
  ) or (not private.actor_manages_active_organization(p_actor_user_id, p_organization_id)
        and not private.is_internal_admin(p_actor_user_id)) then
    raise exception 'Staff Hygiene applicability access denied' using errcode = '42501';
  end if;

  return query
  with dates as (
    select pg_catalog.generate_series(p_date_from, p_date_to, interval '1 day')::date as business_date
  ),
  eligible_branches as materialized (
    select
      lifecycle.organization_id,
      lifecycle.branch_id,
      dates.business_date,
      private.is_branch_day_off(lifecycle.branch_id, dates.business_date) as is_day_off
    from dates
    join public.daily_report_branch_lifecycle lifecycle
      on lifecycle.organization_id = p_organization_id
     and lifecycle.active
     and lifecycle.effective_from_business_date <= dates.business_date
     and (lifecycle.effective_to_business_date is null or lifecycle.effective_to_business_date > dates.business_date)
  ),
  team_scope as (
    select
      branches.branch_id,
      branches.business_date,
      branches.is_day_off,
      team.id as operational_team_id
    from eligible_branches branches
    left join public.branch_operational_teams team
      on team.organization_id = branches.organization_id
     and team.branch_id = branches.branch_id
     and team.active
  )
  select
    scope.branch_id,
    scope.business_date,
    scope.operational_team_id,
    pg_catalog.count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty')::bigint,
    (not scope.is_day_off)
      and pg_catalog.count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0,
    case
      when (not scope.is_day_off)
        and pg_catalog.count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0
      then 'required'
      else 'not_applicable'
    end
  from team_scope scope
  left join public.operational_staff_assignments assignment
    on assignment.organization_id = p_organization_id
   and assignment.branch_id = scope.branch_id
   and assignment.operational_team_id = scope.operational_team_id
   and assignment.active
   and assignment.valid_from <= scope.business_date
   and (assignment.valid_to is null or assignment.valid_to >= scope.business_date)
  left join public.operational_staff staff
    on staff.id = assignment.operational_staff_id
   and staff.organization_id = p_organization_id
   and staff.branch_id = scope.branch_id
   and staff.employment_status = 'active'
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id = assignment.id
   and duty.operational_staff_id = assignment.operational_staff_id
   and duty.organization_id = p_organization_id
   and duty.branch_id = scope.branch_id
   and duty.duty_date = scope.business_date
  group by scope.branch_id, scope.business_date, scope.is_day_off, scope.operational_team_id
  order by scope.business_date, scope.branch_id, scope.operational_team_id;
end;
$$;

revoke all on function public.get_manager_staff_hygiene_applicability_range(uuid, uuid, date, date)
  from public, anon, authenticated, service_role;
grant execute on function public.get_manager_staff_hygiene_applicability_range(uuid, uuid, date, date)
  to service_role;

create or replace function public.get_supervisor_branch_day_off_status(
  p_actor_user_id uuid,
  p_branch_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_timezone text;
  v_business_date date;
begin
  if p_actor_user_id is null
    or p_branch_id is null
    or not private.actor_can_read_operational_branch(p_actor_user_id, p_branch_id)
  then
    raise exception 'branch day off status access denied' using errcode = '42501';
  end if;

  select b.timezone
  into strict v_timezone
  from public.branches b
  join public.organizations o on o.id = b.organization_id and o.active
  join public.profiles p on p.id = p_actor_user_id and p.disabled_at is null and not p.must_change_password
  where b.id = p_branch_id and b.active;

  v_business_date := private.phase4a_business_date(v_timezone);

  return pg_catalog.jsonb_build_object(
    'branch_id', p_branch_id,
    'business_date', v_business_date,
    'timezone', v_timezone,
    'is_day_off', private.is_branch_day_off(p_branch_id, v_business_date),
    'day_off_reason', private.branch_day_off_reason(p_branch_id, v_business_date)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'branch day off status access denied' using errcode = '42501';
end;
$$;

revoke all on function public.get_supervisor_branch_day_off_status(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_supervisor_branch_day_off_status(uuid, uuid)
  to service_role;

-- =============================================================================
-- B. Manager Overview, Financial Closing Operations Summary & Supervisor Overview
-- =============================================================================

create or replace function public.get_phase4a_management_overview(
  actor_user_id uuid,
  target_organization_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  snapshot_at timestamptz := pg_catalog.statement_timestamp();
  organization_row public.organizations%rowtype;
  result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'management overview access denied' using errcode = '42501';
  end if;

  select organization.* into strict organization_row
  from public.organizations organization
  where organization.id = target_organization_id and organization.active;

  if (
    select pg_catalog.count(*)
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ) > 200 then
    raise exception 'management overview branch limit exceeded' using errcode = '54000';
  end if;

  if exists (
    select 1
    from public.branches branch
    where branch.organization_id = target_organization_id
      and branch.active
      and not exists (
        select 1 from pg_catalog.pg_timezone_names timezone
        where timezone.name = branch.timezone
      )
  ) then
    raise exception 'management overview timezone invalid' using errcode = '22023';
  end if;

  with
  active_branches_raw as materialized (
    select
      branch.id,
      branch.name,
      branch.code,
      branch.timezone,
      branch.sales_tracking_percentage_included,
      branch.oil_tracking_percentage_included,
      private.phase4a_business_date(branch.timezone) as business_date
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  active_branches as materialized (
    select
      branch.id,
      branch.name,
      branch.code,
      branch.timezone,
      branch.sales_tracking_percentage_included,
      branch.oil_tracking_percentage_included,
      branch.business_date,
      private.is_branch_day_off(branch.id, branch.business_date) as is_day_off,
      private.branch_day_off_reason(branch.id, branch.business_date) as day_off_reason,
      extract(hour from snapshot_at at time zone branch.timezone) >= 4 as sales_tracking_closed,
      private.cold_storage_due_slots_for(
        branch.id,
        branch.business_date,
        snapshot_at
      ) as due_cold_slots
    from active_branches_raw branch
  ),
  checklist_types(checklist_type, ordinal) as (
    values
      ('kitchen_opening'::text, 1),
      ('foh_opening'::text, 2),
      ('staff_hygiene'::text, 3),
      ('oil_tracking'::text, 4),
      ('cold_storage'::text, 5),
      ('sales_tracking'::text, 6)
  ),
  active_supervisors as materialized (
    select distinct membership.user_id
    from public.branch_memberships membership
    join active_branches branch on branch.id = membership.branch_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.role = 'branch_manager'
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
  ),
  eligible_teams as materialized (
    select team.id team_id, team.branch_id, team.legacy_supervisor_team_id
    from public.branch_operational_teams team
    join active_branches branch on branch.id = team.branch_id
    where team.organization_id = target_organization_id
      and team.active
      and exists (
        select 1
        from public.branch_operational_team_supervisors assignment
        join public.profiles profile on profile.id = assignment.supervisor_user_id
        join public.branch_memberships membership
          on membership.branch_id = team.branch_id
          and membership.user_id = assignment.supervisor_user_id
          and membership.role = 'branch_manager'
          and membership.active
        where assignment.operational_team_id = team.id
          and assignment.branch_id = team.branch_id
          and assignment.organization_id = team.organization_id
          and assignment.active
          and assignment.valid_from <= branch.business_date
          and (assignment.valid_to is null or assignment.valid_to >= branch.business_date)
          and profile.disabled_at is null
          and not profile.must_change_password
      )
  ),
  opening_units as materialized (
    select
      branch.id branch_id,
      branch.id team_id,
      branch.business_date,
      branch.is_day_off,
      checklist.checklist_type,
      submission.id submission_id,
      coalesce(submission.state, 'not_started') state
    from active_branches branch
    cross join lateral (
      values ('kitchen_opening'::text), ('foh_opening'::text)
    ) checklist(checklist_type)
    left join lateral (
      select candidate.id, candidate.state
      from public.checklist_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = branch.id
        and candidate.business_date = branch.business_date
        and candidate.checklist_type = checklist.checklist_type
      order by case candidate.state when 'submitted' then 0 else 1 end,
        candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
  ),
  opening_metrics as materialized (
    select
      unit.branch_id,
      unit.team_id,
      unit.business_date,
      unit.checklist_type,
      unit.state,
      case
        when unit.state = 'submitted' then pg_catalog.count(result.id)
        when unit.is_day_off then 0
        else pg_catalog.count(definition_item.item_id)
      end::bigint expected_checks,
      pg_catalog.count(result.id) filter (
        where unit.state = 'submitted' and result.answer in ('completed', 'issue_found')
      )::bigint answered_checks,
      pg_catalog.count(result.id) filter (
        where unit.state = 'submitted' and result.answer = 'completed'
      )::bigint compliant_checks,
      pg_catalog.count(result.id) filter (
        where unit.state = 'submitted' and result.answer = 'issue_found'
      )::bigint issue_checks
    from opening_units unit
    join public.checklist_definitions definition
      on definition.checklist_type = unit.checklist_type and definition.active
    left join public.checklist_definition_items definition_item
      on definition_item.definition_id = definition.id
      and unit.state <> 'submitted'
    left join public.opening_item_results result
      on result.submission_id = unit.submission_id
      and (
        unit.state = 'submitted'
        or (
          result.definition_id = definition.id
          and result.item_id = definition_item.item_id
        )
      )
    group by unit.branch_id, unit.team_id, unit.business_date,
      unit.is_day_off, unit.checklist_type, unit.state
  ),
  hygiene_unit_keys as materialized (
    select team.branch_id, team.team_id, team.legacy_supervisor_team_id,
      branch.business_date, branch.is_day_off
    from eligible_teams team
    join active_branches branch on branch.id = team.branch_id

    union

    select submission.branch_id,
      coalesce(submission.operational_team_id, mapped_team.id, submission.supervisor_team_id) team_id,
      submission.supervisor_team_id legacy_supervisor_team_id,
      submission.business_date,
      branch.is_day_off
    from public.checklist_submissions submission
    join active_branches branch
      on branch.id = submission.branch_id
      and branch.business_date = submission.business_date
    left join public.branch_operational_teams mapped_team
      on mapped_team.legacy_supervisor_team_id = submission.supervisor_team_id
      and mapped_team.branch_id = submission.branch_id
      and mapped_team.organization_id = submission.organization_id
    where submission.organization_id = target_organization_id
      and submission.checklist_type = 'staff_hygiene'
      and submission.state = 'submitted'
  ),
  hygiene_units as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.is_day_off,
      submission.id submission_id,
      coalesce(submission.state, 'not_started') state
    from hygiene_unit_keys unit
    left join lateral (
      select candidate.id, candidate.state
      from public.checklist_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = unit.branch_id
        and candidate.business_date = unit.business_date
        and candidate.checklist_type = 'staff_hygiene'
        and (
          candidate.operational_team_id = unit.team_id
          or (
            candidate.operational_team_id is null
            and candidate.supervisor_team_id = unit.legacy_supervisor_team_id
          )
        )
        and (
          candidate.state = 'submitted'
          or exists (
            select 1 from eligible_teams team
            where team.team_id = unit.team_id and team.branch_id = unit.branch_id
          )
        )
      order by case candidate.state when 'submitted' then 0 else 1 end,
        candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
  ),
  eligible_hygiene_roster as materialized (
    select distinct assignment.operational_team_id team_id, staff.id staff_id
    from public.operational_staff_assignments assignment
    join eligible_teams team on team.team_id = assignment.operational_team_id
    join public.operational_staff staff
      on staff.id = assignment.operational_staff_id
      and staff.organization_id = target_organization_id
      and staff.employment_status = 'active'
    join active_branches branch on branch.id = assignment.branch_id
    left join public.operational_staff_duty_statuses duty
      on duty.assignment_id = assignment.id
      and duty.operational_staff_id = staff.id
      and duty.duty_date = branch.business_date
    where assignment.active
      and assignment.valid_from <= branch.business_date
      and (assignment.valid_to is null or assignment.valid_to >= branch.business_date)
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
  ),
  hygiene_values as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.state, value.result
    from hygiene_units unit
    join eligible_hygiene_roster roster on roster.team_id = unit.team_id
    left join public.hygiene_staff_snapshots hygiene
      on hygiene.submission_id = unit.submission_id
      and hygiene.operational_staff_id = roster.staff_id
    cross join lateral (
      values
        (coalesce(hygiene.uniform_result, 'pending')),
        (coalesce(hygiene.fingernails_result, 'pending')),
        (coalesce(hygiene.hair_result, 'pending')),
        (coalesce(hygiene.facial_hair_result, 'pending'))
    ) value(result)
    where unit.state <> 'submitted'
      and not unit.is_day_off

    union all

    select unit.branch_id, unit.team_id, unit.business_date, unit.state, value.result
    from hygiene_units unit
    join public.hygiene_staff_snapshots hygiene on hygiene.submission_id = unit.submission_id
    cross join lateral (
      values (hygiene.uniform_result), (hygiene.fingernails_result),
        (hygiene.hair_result), (hygiene.facial_hair_result)
    ) value(result)
    where unit.state = 'submitted'
  ),
  hygiene_metrics as materialized (
    select unit.branch_id, unit.team_id, unit.business_date,
      'staff_hygiene'::text checklist_type, unit.state,
      pg_catalog.count(value.result)::bigint expected_checks,
      pg_catalog.count(value.result) filter (
        where unit.state = 'submitted' and value.result in ('pass', 'issue')
      )::bigint answered_checks,
      pg_catalog.count(value.result) filter (
        where unit.state = 'submitted' and value.result = 'pass'
      )::bigint compliant_checks,
      pg_catalog.count(value.result) filter (
        where unit.state = 'submitted' and value.result = 'issue'
      )::bigint issue_checks
    from hygiene_units unit
    left join hygiene_values value
      on value.branch_id = unit.branch_id
      and value.team_id = unit.team_id
      and value.business_date = unit.business_date
      and value.state = unit.state
    group by unit.branch_id, unit.team_id, unit.business_date, unit.state
  ),
  oil_selected_units as materialized (
    select branch.id branch_id, branch.id team_id, branch.business_date, branch.is_day_off,
      submission.id submission_id, coalesce(submission.state, 'not_started') state,
      submission.opening_submitted_at, submission.closing_submitted_at
    from active_branches branch
    left join lateral (
      select candidate.*
      from public.oil_tracking_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = branch.id
        and candidate.business_date = branch.business_date
      order by candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
  ),
  oil_submission_flags as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.is_day_off, unit.state,
      unit.submission_id is null no_submission,
      pg_catalog.count(row.id) filter (where row.in_use_today)::int active_count,
      pg_catalog.bool_and(
        row.oil_status in ('new_oil','filtered_oil')
        and row.opening_temperature_c is not null
        and row.opening_status in ('pass','fail')
        and (row.opening_status <> 'fail' or pg_catalog.length(pg_catalog.btrim(row.opening_note)) > 0)
      ) filter (where row.in_use_today) opening_valid,
      pg_catalog.bool_and(row.closing_tpm_percent is not null) filter (where row.in_use_today) closing_valid,
      pg_catalog.bool_or(row.opening_status = 'fail') filter (where row.in_use_today) opening_issue,
      pg_catalog.bool_or(row.closing_tpm_percent >= 21) filter (where row.in_use_today) closing_issue,
      unit.opening_submitted_at is not null opening_submitted,
      unit.closing_submitted_at is not null closing_submitted
    from oil_selected_units unit
    left join public.oil_tracking_fryer_results row on row.submission_id = unit.submission_id
    group by unit.branch_id, unit.team_id, unit.business_date, unit.is_day_off, unit.state,
      unit.submission_id, unit.opening_submitted_at, unit.closing_submitted_at
  ),
  oil_metrics as materialized (
    select
      flags.branch_id,
      flags.team_id,
      flags.business_date,
      'oil_tracking'::text checklist_type,
      flags.state,
      case
        when flags.is_day_off then
          (case when flags.active_count > 0 and flags.opening_submitted and coalesce(flags.opening_valid, false) then 1 else 0 end
           + case when flags.active_count > 0 and flags.closing_submitted and coalesce(flags.closing_valid, false) then 1 else 0 end)
        when flags.no_submission or flags.active_count > 0 then 2
        else 0
      end::bigint expected_checks,
      (case when flags.active_count > 0 and flags.opening_submitted and coalesce(flags.opening_valid, false) then 1 else 0 end
       + case when flags.active_count > 0 and flags.closing_submitted and coalesce(flags.closing_valid, false) then 1 else 0 end)::bigint answered_checks,
      (case when flags.active_count > 0 and flags.opening_submitted and coalesce(flags.opening_valid, false) and not coalesce(flags.opening_issue, false) then 1 else 0 end
       + case when flags.active_count > 0 and flags.closing_submitted and coalesce(flags.closing_valid, false) and not coalesce(flags.closing_issue, false) then 1 else 0 end)::bigint compliant_checks,
      (case when flags.active_count > 0 and flags.opening_submitted and coalesce(flags.opening_valid, false) and coalesce(flags.opening_issue, false) then 1 else 0 end
       + case when flags.active_count > 0 and flags.closing_submitted and coalesce(flags.closing_valid, false) and coalesce(flags.closing_issue, false) then 1 else 0 end)::bigint issue_checks
    from oil_submission_flags flags
  ),
  cold_selected_units as materialized (
    select branch.id branch_id, branch.id team_id, branch.business_date, branch.is_day_off,
      submission.id submission_id, coalesce(submission.state, 'not_started') state,
      case
        when branch.is_day_off then coalesce(
          (
            select pg_catalog.array_agg(distinct slot_row.slot_time order by slot_row.slot_time)
            from (
              select slot.slot_time
              from public.cold_storage_schedule_slots slot
              where slot.schedule_version_id = coalesce(
                submission.schedule_version_id,
                private.cold_storage_schedule_version_for(branch.id, branch.business_date)
              )
              union
              select reading.slot as slot_time
              from public.cold_storage_readings reading
              where reading.submission_id = submission.id
                and reading.submitted_at is not null
            ) slot_row
          ),
          branch.due_cold_slots
        )
        else branch.due_cold_slots
      end as candidate_slots,
      branch.due_cold_slots
    from active_branches branch
    left join lateral (
      select candidate.*
      from public.cold_storage_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = branch.id
        and candidate.business_date = branch.business_date
      order by candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
  ),
  cold_active_equipment_counts as materialized (
    select unit.branch_id, unit.team_id, unit.business_date,
      pg_catalog.count(equipment.id)::int active_count
    from cold_selected_units unit
    left join public.cold_storage_equipment equipment
      on equipment.submission_id = unit.submission_id
      and equipment.active
    group by unit.branch_id, unit.team_id, unit.business_date
  ),
  cold_due_slot_flags as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, due_slot.slot,
      pg_catalog.count(equipment.id)::int active_count,
      pg_catalog.bool_and(
        reading.submitted_at is not null
        and reading.temperature_c is not null
        and reading.status in ('pass','fail')
      ) filter (where equipment.id is not null) slot_valid,
      pg_catalog.bool_or(reading.temperature_c >= 5) filter (where equipment.id is not null) slot_issue
    from cold_selected_units unit
    cross join lateral pg_catalog.unnest(unit.candidate_slots) due_slot(slot)
    left join public.cold_storage_equipment equipment
      on equipment.submission_id = unit.submission_id
      and equipment.active
    left join public.cold_storage_readings reading
      on reading.submission_id = unit.submission_id
      and reading.equipment_id = equipment.equipment_id
      and reading.slot = due_slot.slot
    group by unit.branch_id, unit.team_id, unit.business_date, due_slot.slot
  ),
  cold_metrics as materialized (
    select
      unit.branch_id,
      unit.team_id,
      unit.business_date,
      'cold_storage'::text checklist_type,
      unit.state,
      case
        when unit.is_day_off then
          pg_catalog.count(flags.slot) filter (
            where flags.active_count > 0 and coalesce(flags.slot_valid, false)
          )
        else pg_catalog.cardinality(unit.due_cold_slots)
      end::bigint expected_checks,
      pg_catalog.count(flags.slot) filter (
        where flags.active_count > 0 and coalesce(flags.slot_valid, false)
      )::bigint answered_checks,
      pg_catalog.count(flags.slot) filter (
        where flags.active_count > 0 and coalesce(flags.slot_valid, false)
          and not coalesce(flags.slot_issue, false)
      )::bigint compliant_checks,
      pg_catalog.count(flags.slot) filter (
        where flags.active_count > 0 and coalesce(flags.slot_valid, false)
          and coalesce(flags.slot_issue, false)
      )::bigint issue_checks
    from cold_selected_units unit
    left join cold_active_equipment_counts equipment
      on equipment.branch_id = unit.branch_id
      and equipment.team_id = unit.team_id
      and equipment.business_date = unit.business_date
    left join cold_due_slot_flags flags
      on flags.branch_id = unit.branch_id
      and flags.team_id = unit.team_id
      and flags.business_date = unit.business_date
    group by unit.branch_id, unit.team_id, unit.business_date, unit.is_day_off, unit.state,
      equipment.active_count, unit.due_cold_slots
  ),
  sales_tracking_selected_units as materialized (
    select branch.id branch_id, branch.id team_id, branch.business_date,
      branch.is_day_off, branch.sales_tracking_closed, report.id report_id,
      coalesce(report.state, 'not_started') state
    from active_branches branch
    left join lateral (
      select candidate.*
      from public.sales_tracking_reports candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = branch.id
        and candidate.business_date = branch.business_date
        and candidate.state = 'submitted'
      order by candidate.submitted_at desc, candidate.id
      limit 1
    ) report on true
  ),
  sales_tracking_report_variance as materialized (
    select unit.branch_id, unit.team_id, unit.business_date,
      unit.is_day_off, unit.sales_tracking_closed, unit.state,
      coalesce(pg_catalog.sum(
        coalesce(row.actual_cash,0) + coalesce(row.actual_credit,0) + coalesce(row.online_delivery,0)
        - coalesce(row.pos_cash,0) - coalesce(row.pos_credit,0) - coalesce(row.online_delivery,0)
      ),0) variance
    from sales_tracking_selected_units unit
    left join public.sales_tracking_sales_rows row on row.report_id = unit.report_id
    group by unit.branch_id, unit.team_id, unit.business_date,
      unit.is_day_off, unit.sales_tracking_closed, unit.state
  ),
  sales_tracking_metrics as materialized (
    select row.branch_id, row.team_id, row.business_date,
      'sales_tracking'::text checklist_type,
      case
        when row.state = 'submitted' then 'submitted'
        when row.is_day_off or row.sales_tracking_closed then 'not_started'
        else 'draft'
      end state,
      case when row.is_day_off and row.state <> 'submitted' then 0 else 1 end::bigint expected_checks,
      case when row.state = 'submitted' then 1 else 0 end::bigint answered_checks,
      case when row.state = 'submitted' and pg_catalog.round(row.variance,2) = 0 then 1 else 0 end::bigint compliant_checks,
      case when row.state = 'submitted' and pg_catalog.round(row.variance,2) <> 0 then 1 else 0 end::bigint issue_checks
    from sales_tracking_report_variance row
  ),
  unit_metrics as materialized (
    select * from opening_metrics
    union all
    select * from hygiene_metrics
    union all
    select * from oil_metrics
    union all
    select * from cold_metrics
    union all
    select * from sales_tracking_metrics
  ),
  branch_checklist_metrics as materialized (
    select branch.id branch_id, checklist.checklist_type, checklist.ordinal,
      pg_catalog.count(metric.team_id) filter (
        where metric.state = 'not_started' and not branch.is_day_off
      )::bigint not_started_teams,
      pg_catalog.count(metric.team_id) filter (where metric.state = 'draft')::bigint draft_teams,
      pg_catalog.count(metric.team_id) filter (where metric.state = 'submitted')::bigint submitted_teams,
      coalesce(pg_catalog.sum(metric.expected_checks), 0)::bigint expected_checks,
      coalesce(pg_catalog.sum(metric.answered_checks), 0)::bigint answered_checks,
      coalesce(pg_catalog.sum(metric.compliant_checks), 0)::bigint compliant_checks,
      coalesce(pg_catalog.sum(metric.issue_checks), 0)::bigint issue_checks
    from active_branches branch
    cross join checklist_types checklist
    left join unit_metrics metric
      on metric.branch_id = branch.id and metric.checklist_type = checklist.checklist_type
    group by branch.id, branch.is_day_off, checklist.checklist_type, checklist.ordinal
  ),
  branch_metrics as materialized (
    select branch.id branch_id,
      coalesce(pg_catalog.sum(metric.expected_checks), 0)::bigint expected_checks,
      coalesce(pg_catalog.sum(metric.answered_checks), 0)::bigint answered_checks,
      coalesce(pg_catalog.sum(metric.compliant_checks), 0)::bigint compliant_checks,
      coalesce(pg_catalog.sum(metric.issue_checks), 0)::bigint issue_checks
    from active_branches branch
    left join branch_checklist_metrics metric on metric.branch_id = branch.id
    group by branch.id
  ),
  branch_percentage_candidates as materialized (
    select metric.*,
      case
        when metric.checklist_type = 'oil_tracking' then branch.oil_tracking_percentage_included
        when metric.checklist_type = 'sales_tracking' then branch.sales_tracking_percentage_included
        else true
      end percentage_included
    from branch_checklist_metrics metric
    join active_branches branch on branch.id = metric.branch_id
  ),
  branch_percentage_metrics as materialized (
    select branch.id branch_id,
      coalesce(pg_catalog.sum(metric.expected_checks) filter (where metric.percentage_included), 0)::bigint expected_checks,
      coalesce(pg_catalog.sum(metric.answered_checks) filter (where metric.percentage_included), 0)::bigint answered_checks,
      coalesce(pg_catalog.sum(metric.compliant_checks) filter (where metric.percentage_included), 0)::bigint compliant_checks
    from active_branches branch
    left join branch_percentage_candidates metric on metric.branch_id = branch.id
    group by branch.id
  ),
  branch_rows as materialized (
    select branch.id branch_id, branch.name branch_name, branch.code branch_code,
      branch.timezone, branch.business_date, branch.is_day_off, branch.day_off_reason,
      pg_catalog.count(distinct team.team_id)::bigint active_team_count,
      metric.expected_checks, metric.answered_checks, metric.compliant_checks, metric.issue_checks,
      (metric.expected_checks - metric.answered_checks)::bigint pending_checks,
      pg_catalog.max(percentage_metric.expected_checks) percentage_expected_checks,
      pg_catalog.max(percentage_metric.answered_checks) percentage_answered_checks,
      pg_catalog.max(percentage_metric.compliant_checks) percentage_compliant_checks,
      case when pg_catalog.max(percentage_metric.expected_checks) = 0 then null
        else pg_catalog.round(pg_catalog.max(percentage_metric.answered_checks) * 100.0 / pg_catalog.max(percentage_metric.expected_checks))::integer
      end completion_percentage,
      case when pg_catalog.max(percentage_metric.answered_checks) = 0 then null
        else pg_catalog.round(pg_catalog.max(percentage_metric.compliant_checks) * 100.0 / pg_catalog.max(percentage_metric.answered_checks))::integer
      end compliance_percentage
    from active_branches branch
    join branch_metrics metric on metric.branch_id = branch.id
    join branch_percentage_metrics percentage_metric on percentage_metric.branch_id = branch.id
    left join eligible_teams team on team.branch_id = branch.id
    group by branch.id, branch.name, branch.code, branch.timezone, branch.business_date,
      branch.is_day_off, branch.day_off_reason,
      metric.expected_checks, metric.answered_checks, metric.compliant_checks, metric.issue_checks
  ),
  organization_totals as (
    select coalesce(pg_catalog.sum(branch.expected_checks), 0)::bigint expected_checks,
      coalesce(pg_catalog.sum(branch.answered_checks), 0)::bigint answered_checks,
      coalesce(pg_catalog.sum(branch.compliant_checks), 0)::bigint compliant_checks,
      coalesce(pg_catalog.sum(branch.issue_checks), 0)::bigint issue_checks,
      coalesce(pg_catalog.sum(branch.percentage_expected_checks), 0)::bigint percentage_expected_checks,
      coalesce(pg_catalog.sum(branch.percentage_answered_checks), 0)::bigint percentage_answered_checks,
      coalesce(pg_catalog.sum(branch.percentage_compliant_checks), 0)::bigint percentage_compliant_checks
    from branch_rows branch
  )
  select pg_catalog.jsonb_build_object(
    'organization', pg_catalog.jsonb_build_object(
      'id', organization_row.id,
      'name', organization_row.name
    ),
    'generated_at', snapshot_at,
    'date_context', 'current_branch_local_business_day',
    'summary', pg_catalog.jsonb_build_object(
      'active_branch_count', (select pg_catalog.count(*) from active_branches),
      'active_team_count', (select pg_catalog.count(*) from eligible_teams),
      'active_supervisor_account_count', (select pg_catalog.count(*) from active_supervisors),
      'active_operational_staff_count', (
        select pg_catalog.count(distinct staff.id)
        from public.operational_staff staff
        join active_branches branch on branch.id = staff.branch_id
        where staff.organization_id = target_organization_id
          and staff.employment_status = 'active'
      )
    ),
    'totals', pg_catalog.jsonb_build_object(
      'expected_checks', totals.expected_checks,
      'answered_checks', totals.answered_checks,
      'compliant_checks', totals.compliant_checks,
      'issue_checks', totals.issue_checks,
      'pending_checks', totals.expected_checks - totals.answered_checks,
      'percentage_expected_checks', totals.percentage_expected_checks,
      'percentage_answered_checks', totals.percentage_answered_checks,
      'percentage_compliant_checks', totals.percentage_compliant_checks,
      'completion_percentage', case when totals.percentage_expected_checks = 0 then null
        else pg_catalog.round(totals.percentage_answered_checks * 100.0 / totals.percentage_expected_checks)::integer end,
      'compliance_percentage', case when totals.percentage_answered_checks = 0 then null
        else pg_catalog.round(totals.percentage_compliant_checks * 100.0 / totals.percentage_answered_checks)::integer end
    ),
    'local_dates', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'business_date', date_row.business_date,
        'branch_count', date_row.branch_count
      ) order by date_row.business_date)
      from (
        select branch.business_date, pg_catalog.count(*)::bigint branch_count
        from active_branches branch group by branch.business_date
      ) date_row
    ), '[]'::jsonb),
    'branches', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'branch_id', branch.branch_id,
        'branch_name', branch.branch_name,
        'branch_code', branch.branch_code,
        'timezone', branch.timezone,
        'business_date', branch.business_date,
        'is_day_off', branch.is_day_off,
        'day_off_reason', branch.day_off_reason,
        'status', case when branch.active_team_count = 0 then 'no_active_team' else 'ready' end,
        'active_team_count', branch.active_team_count,
        'totals', pg_catalog.jsonb_build_object(
          'expected_checks', branch.expected_checks,
          'answered_checks', branch.answered_checks,
          'compliant_checks', branch.compliant_checks,
          'issue_checks', branch.issue_checks,
          'pending_checks', branch.pending_checks,
          'percentage_expected_checks', branch.percentage_expected_checks,
          'percentage_answered_checks', branch.percentage_answered_checks,
          'percentage_compliant_checks', branch.percentage_compliant_checks,
          'completion_percentage', branch.completion_percentage,
          'compliance_percentage', branch.compliance_percentage
        ),
        'checklists', (
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'checklist_type', checklist.checklist_type,
            'team_states', pg_catalog.jsonb_build_object(
              'not_started', checklist.not_started_teams,
              'draft', checklist.draft_teams,
              'submitted', checklist.submitted_teams
            ),
            'expected_checks', checklist.expected_checks,
            'answered_checks', checklist.answered_checks,
            'compliant_checks', checklist.compliant_checks,
            'issue_checks', checklist.issue_checks,
            'pending_checks', checklist.expected_checks - checklist.answered_checks,
            'percentage_expected_checks', case when checklist.percentage_included then checklist.expected_checks else 0 end,
            'percentage_answered_checks', case when checklist.percentage_included then checklist.answered_checks else 0 end,
            'percentage_compliant_checks', case when checklist.percentage_included then checklist.compliant_checks else 0 end,
            'completion_percentage', case when not checklist.percentage_included or checklist.expected_checks = 0 then null
              else pg_catalog.round(checklist.answered_checks * 100.0 / checklist.expected_checks)::integer end,
            'compliance_percentage', case when not checklist.percentage_included or checklist.answered_checks = 0 then null
              else pg_catalog.round(checklist.compliant_checks * 100.0 / checklist.answered_checks)::integer end
          ) order by checklist.ordinal)
          from branch_percentage_candidates checklist
          where checklist.branch_id = branch.branch_id
        )
      ) order by pg_catalog.lower(pg_catalog.btrim(branch.branch_name)), branch.branch_id)
      from branch_rows branch
    ), '[]'::jsonb)
  ) into result
  from organization_totals totals;

  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'management overview access denied' using errcode = '42501';
end;
$$;

revoke all on function public.get_phase4a_management_overview(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_phase4a_management_overview(uuid, uuid)
  to service_role;

create or replace function public.get_management_overview_with_daily_audit(
  actor_user_id uuid,
  target_organization_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  base jsonb;
  branch_data jsonb;
  branches jsonb := '[]'::jsonb;
  submission public.checklist_submissions%rowtype;
  is_branch_day_off boolean;
  daily_state text;
  daily_expected integer;
  answered integer;
  compliant integer;
  issues integer;
  total_daily_expected integer := 0;
  total_answered integer := 0;
  total_compliant integer := 0;
  total_issues integer := 0;
  daily_counts jsonb;
  branch_totals jsonb;
  base_totals jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'management overview access denied' using errcode = '42501';
  end if;

  base := public.get_phase4a_management_overview(actor_user_id, target_organization_id);

  for branch_data in select value from pg_catalog.jsonb_array_elements(base -> 'branches') loop
    is_branch_day_off := coalesce((branch_data ->> 'is_day_off')::boolean, false);
    submission := null;
    select s.* into submission
    from public.checklist_submissions s
    where s.organization_id = target_organization_id
      and s.branch_id = (branch_data ->> 'branch_id')::uuid
      and s.business_date = (branch_data ->> 'business_date')::date
      and s.checklist_type = 'daily_audit'
    order by case s.state when 'submitted' then 0 else 1 end, s.updated_at desc, s.id desc
    limit 1;

    if submission.id is null then
      daily_state := 'not_started'; answered := 0; compliant := 0; issues := 0;
    elsif submission.state = 'draft' then
      daily_state := 'draft'; answered := 0; compliant := 0; issues := 0;
    else
      daily_state := 'submitted';
      select pg_catalog.count(*) filter (where r.answer in ('compliant', 'non_compliant')),
             pg_catalog.count(*) filter (where r.answer = 'compliant'),
             pg_catalog.count(*) filter (where r.answer = 'non_compliant')
        into answered, compliant, issues
      from public.daily_audit_item_results r where r.submission_id = submission.id;
    end if;

    daily_expected := case when is_branch_day_off and daily_state <> 'submitted' then 0 else 13 end;

    daily_counts := pg_catalog.jsonb_build_object(
      'checklist_type', 'daily_audit',
      'expected_checks', daily_expected,
      'answered_checks', answered,
      'compliant_checks', compliant,
      'issue_checks', issues,
      'pending_checks', daily_expected - answered,
      'percentage_expected_checks', daily_expected,
      'percentage_answered_checks', answered,
      'percentage_compliant_checks', compliant,
      'completion_percentage', case when daily_expected = 0 then null else pg_catalog.round(answered * 100.0 / daily_expected)::integer end,
      'compliance_percentage', case when answered = 0 then null else pg_catalog.round(compliant * 100.0 / answered)::integer end,
      'team_states', pg_catalog.jsonb_build_object(
        'not_started', case when daily_state = 'not_started' and not is_branch_day_off then 1 else 0 end,
        'draft', case when daily_state = 'draft' then 1 else 0 end,
        'submitted', case when daily_state = 'submitted' then 1 else 0 end
      )
    );

    branch_totals := branch_data -> 'totals';
    branch_totals := branch_totals || pg_catalog.jsonb_build_object(
      'expected_checks', (branch_totals ->> 'expected_checks')::integer + daily_expected,
      'answered_checks', (branch_totals ->> 'answered_checks')::integer + answered,
      'compliant_checks', (branch_totals ->> 'compliant_checks')::integer + compliant,
      'issue_checks', (branch_totals ->> 'issue_checks')::integer + issues,
      'pending_checks', (branch_totals ->> 'pending_checks')::integer + daily_expected - answered,
      'percentage_expected_checks', (branch_totals ->> 'percentage_expected_checks')::integer + daily_expected,
      'percentage_answered_checks', (branch_totals ->> 'percentage_answered_checks')::integer + answered,
      'percentage_compliant_checks', (branch_totals ->> 'percentage_compliant_checks')::integer + compliant,
      'completion_percentage', case
        when ((branch_totals ->> 'percentage_expected_checks')::integer + daily_expected) = 0 then null
        else pg_catalog.round(((branch_totals ->> 'percentage_answered_checks')::integer + answered) * 100.0 / ((branch_totals ->> 'percentage_expected_checks')::integer + daily_expected))::integer
      end,
      'compliance_percentage', case
        when (branch_totals ->> 'percentage_answered_checks')::integer + answered = 0 then null
        else pg_catalog.round(((branch_totals ->> 'percentage_compliant_checks')::integer + compliant) * 100.0 / ((branch_totals ->> 'percentage_answered_checks')::integer + answered))::integer
      end
    );

    branches := branches || pg_catalog.jsonb_build_array(branch_data || pg_catalog.jsonb_build_object(
      'totals', branch_totals,
      'checklists', (branch_data -> 'checklists') || pg_catalog.jsonb_build_array(daily_counts)
    ));
    total_daily_expected := total_daily_expected + daily_expected;
    total_answered := total_answered + answered;
    total_compliant := total_compliant + compliant;
    total_issues := total_issues + issues;
  end loop;

  base_totals := base -> 'totals';
  base_totals := base_totals || pg_catalog.jsonb_build_object(
    'expected_checks', (base_totals ->> 'expected_checks')::integer + total_daily_expected,
    'answered_checks', (base_totals ->> 'answered_checks')::integer + total_answered,
    'compliant_checks', (base_totals ->> 'compliant_checks')::integer + total_compliant,
    'issue_checks', (base_totals ->> 'issue_checks')::integer + total_issues,
    'pending_checks', (base_totals ->> 'pending_checks')::integer + total_daily_expected - total_answered,
    'percentage_expected_checks', (base_totals ->> 'percentage_expected_checks')::integer + total_daily_expected,
    'percentage_answered_checks', (base_totals ->> 'percentage_answered_checks')::integer + total_answered,
    'percentage_compliant_checks', (base_totals ->> 'percentage_compliant_checks')::integer + total_compliant,
    'completion_percentage', case
      when (base_totals ->> 'percentage_expected_checks')::integer + total_daily_expected = 0 then null
      else pg_catalog.round(((base_totals ->> 'percentage_answered_checks')::integer + total_answered) * 100.0 / ((base_totals ->> 'percentage_expected_checks')::integer + total_daily_expected))::integer
    end,
    'compliance_percentage', case
      when (base_totals ->> 'percentage_answered_checks')::integer + total_answered = 0 then null
      else pg_catalog.round(((base_totals ->> 'percentage_compliant_checks')::integer + total_compliant) * 100.0 / ((base_totals ->> 'percentage_answered_checks')::integer + total_answered))::integer
    end
  );

  return base || pg_catalog.jsonb_build_object('branches', branches, 'totals', base_totals);
end;
$$;

revoke all on function public.get_management_overview_with_daily_audit(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_management_overview_with_daily_audit(uuid, uuid)
  to service_role;

create or replace function private.managed_financial_closing_operations_summary(
  target_organization_id uuid,
  branch_filter uuid default null,
  as_of timestamptz default pg_catalog.now()
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with active_branches as materialized (
    select
      branch.id,
      branch.timezone,
      private.phase4a_business_date_at(branch.timezone, as_of) as business_date,
      (as_of at time zone branch.timezone)::time as local_clock
    from public.branches branch
    where branch.organization_id = target_organization_id
      and branch.active
      and (branch_filter is null or branch.id = branch_filter)
  ),
  branch_dates as materialized (
    select
      branch.id,
      branch.business_date,
      branch.local_clock,
      private.is_branch_day_off(branch.id, branch.business_date) as is_day_off_current_day,
      case
        when branch.local_clock < time '04:00' then branch.business_date
        else branch.business_date - 1
      end as overdue_business_date
    from active_branches branch
  ),
  branch_status as materialized (
    select
      branch.id,
      branch.business_date,
      branch.is_day_off_current_day,
      exists (
        select 1
        from public.financial_closing_reports report
        where report.organization_id = target_organization_id
          and report.branch_id = branch.id
          and report.business_date = branch.business_date
          and report.state = 'submitted'
      ) as completed_current_day,
      branch.local_clock >= time '02:00'
        and not private.is_branch_day_off(branch.id, branch.overdue_business_date)
        and not exists (
          select 1
          from public.financial_closing_reports report
          where report.organization_id = target_organization_id
            and report.branch_id = branch.id
            and report.business_date = branch.overdue_business_date
            and report.state = 'submitted'
        ) as overdue_current_business_day
    from branch_dates branch
  ),
  date_rows as (
    select branch.business_date, pg_catalog.count(*)::integer as branch_count
    from branch_status branch
    where branch.completed_current_day or not branch.is_day_off_current_day
    group by branch.business_date
  )
  select pg_catalog.jsonb_build_object(
    'total_branches', pg_catalog.count(*) filter (where status.completed_current_day or not status.is_day_off_current_day)::integer,
    'completed_today', pg_catalog.count(*) filter (where status.completed_current_day)::integer,
    'pending_today', pg_catalog.count(*) filter (where not status.completed_current_day and not status.is_day_off_current_day)::integer,
    'overdue_prior_day', pg_catalog.count(*) filter (where status.overdue_current_business_day)::integer,
    'business_dates', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'business_date', date_row.business_date,
        'branch_count', date_row.branch_count
      ) order by date_row.business_date)
      from date_rows date_row
    ), '[]'::jsonb)
  )
  from branch_status status;
$$;

revoke all on function private.managed_financial_closing_operations_summary(uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function private.managed_financial_closing_operations_summary(uuid, uuid, timestamptz)
  to service_role;

create or replace function public.get_phase4a_supervisor_overview(
  actor_user_id uuid,
  target_branch_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  v_is_day_off boolean;
  v_day_off_reason text;
  result jsonb;
begin
  if not private.actor_can_read_operational_branch(actor_user_id, target_branch_id) then
    raise exception 'overview access denied' using errcode = '42501';
  end if;

  select
    b.organization_id,
    b.id as branch_id,
    private.phase4a_business_date(b.timezone) as business_date,
    b.name as branch_name,
    b.code as branch_code,
    p.full_name as actor_name
  into strict c
  from public.branches b
  join public.organizations o on o.id = b.organization_id and o.active
  join public.profiles p on p.id = actor_user_id and p.disabled_at is null and not p.must_change_password
  where b.id = target_branch_id and b.active;

  v_is_day_off := private.is_branch_day_off(c.branch_id, c.business_date);
  v_day_off_reason := private.branch_day_off_reason(c.branch_id, c.business_date);

  with opening_metrics as (
    select
      d.checklist_type,
      coalesce(s.state, 'not_started') as state,
      pg_catalog.count(i.item_id)::bigint as expected_checks,
      pg_catalog.count(r.id) filter (where r.answer in ('completed', 'issue_found'))::bigint as answered_checks,
      pg_catalog.count(r.id) filter (where r.answer = 'completed')::bigint as compliant_checks,
      pg_catalog.count(r.id) filter (where r.answer = 'issue_found')::bigint as issue_checks
    from public.checklist_definitions d
    left join public.checklist_definition_items i on i.definition_id = d.id
    left join public.checklist_submissions s
      on s.organization_id = c.organization_id
      and s.branch_id = c.branch_id
      and s.business_date = c.business_date
      and s.checklist_type = d.checklist_type
    left join public.opening_item_results r on r.submission_id = s.id and r.item_id = i.item_id
    where d.active and d.checklist_type in ('kitchen_opening', 'foh_opening')
    group by d.checklist_type, s.state
  ),
  eligible_staff as (
    select distinct a.operational_team_id, a.operational_staff_id
    from public.operational_staff_assignments a
    join public.branch_operational_team_supervisors team_assignment
      on team_assignment.operational_team_id = a.operational_team_id
      and team_assignment.organization_id = a.organization_id
      and team_assignment.branch_id = a.branch_id
      and team_assignment.supervisor_user_id = actor_user_id
      and team_assignment.active
      and team_assignment.valid_from <= c.business_date
      and (team_assignment.valid_to is null or team_assignment.valid_to >= c.business_date)
    join public.branch_operational_teams team
      on team.id = a.operational_team_id
      and team.organization_id = a.organization_id
      and team.branch_id = a.branch_id
      and team.active
    join public.operational_staff staff
      on staff.id = a.operational_staff_id
      and staff.organization_id = a.organization_id
      and staff.branch_id = a.branch_id
      and staff.employment_status = 'active'
    left join public.operational_staff_duty_statuses duty
      on duty.assignment_id = a.id
      and duty.operational_staff_id = a.operational_staff_id
      and duty.duty_date = c.business_date
    where a.organization_id = c.organization_id
      and a.branch_id = c.branch_id
      and a.active
      and a.valid_from <= c.business_date
      and (a.valid_to is null or a.valid_to >= c.business_date)
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
  ),
  hygiene_submissions as (
    select distinct on (s.operational_team_id) s.id, s.operational_team_id, s.state, s.updated_at
    from public.checklist_submissions s
    where s.organization_id = c.organization_id
      and s.branch_id = c.branch_id
      and s.business_date = c.business_date
      and s.checklist_type = 'staff_hygiene'
      and exists (
        select 1
        from public.branch_operational_team_supervisors team_assignment
        where team_assignment.operational_team_id = s.operational_team_id
          and team_assignment.organization_id = s.organization_id
          and team_assignment.branch_id = s.branch_id
          and team_assignment.supervisor_user_id = actor_user_id
          and team_assignment.active
          and team_assignment.valid_from <= c.business_date
          and (team_assignment.valid_to is null or team_assignment.valid_to >= c.business_date)
      )
    order by s.operational_team_id, case s.state when 'submitted' then 0 else 1 end, s.updated_at desc, s.id
  ),
  hygiene_candidate_values as (
    select h.operational_staff_id, v.check_key, v.value, s.state, s.updated_at, s.id submission_id, h.id snapshot_id
    from hygiene_submissions s
    join public.hygiene_staff_snapshots h on h.submission_id = s.id
    join eligible_staff e on e.operational_team_id = s.operational_team_id and e.operational_staff_id = h.operational_staff_id
    cross join lateral (
      values
        ('uniform', h.uniform_result),
        ('fingernails', h.fingernails_result),
        ('hair', h.hair_result),
        ('facial_hair', h.facial_hair_result)
    ) v(check_key, value)
  ),
  hygiene_values as (
    select distinct on (operational_staff_id, check_key) operational_staff_id, check_key, value
    from hygiene_candidate_values
    order by operational_staff_id, check_key, case state when 'submitted' then 0 else 1 end, updated_at desc, submission_id, snapshot_id
  ),
  hygiene_metrics as (
    select
      'staff_hygiene'::text checklist_type,
      case
        when not exists (select 1 from hygiene_submissions) then 'not_started'
        when not exists (select 1 from hygiene_submissions where state <> 'submitted') then 'submitted'
        else 'draft'
      end state,
      ((select pg_catalog.count(distinct operational_staff_id) from eligible_staff) * 4)::bigint expected_checks,
      pg_catalog.count(*) filter (where value in ('pass', 'issue'))::bigint answered_checks,
      pg_catalog.count(*) filter (where value = 'pass')::bigint compliant_checks,
      pg_catalog.count(*) filter (where value = 'issue')::bigint issue_checks
    from hygiene_values
  ),
  oil_metrics as (
    select
      'oil_tracking'::text checklist_type,
      case
        when s.id is null then 'not_started'
        when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 'submitted'
        else 'draft'
      end state,
      (pg_catalog.count(r.id) filter (where r.in_use_today) * 2)::bigint expected_checks,
      (pg_catalog.count(r.id) filter (where r.in_use_today and r.opening_status <> 'pending')
       + pg_catalog.count(r.id) filter (where r.in_use_today and r.closing_tpm_percent is not null))::bigint answered_checks,
      (pg_catalog.count(r.id) filter (where r.in_use_today and r.opening_status = 'pass')
       + pg_catalog.count(r.id) filter (where r.in_use_today and r.closing_tpm_percent is not null and private.oil_tracking_tpm_status(r.closing_tpm_percent) <> 'critical'))::bigint compliant_checks,
      (pg_catalog.count(r.id) filter (where r.in_use_today and r.opening_status = 'fail')
       + pg_catalog.count(r.id) filter (where r.in_use_today and r.closing_tpm_percent is not null and private.oil_tracking_tpm_status(r.closing_tpm_percent) = 'critical'))::bigint issue_checks
    from public.oil_tracking_submissions s
    left join public.oil_tracking_fryer_results r on r.submission_id = s.id
    where s.organization_id = c.organization_id
      and s.branch_id = c.branch_id
      and s.business_date = c.business_date
    group by s.id, s.opening_submitted_at, s.closing_submitted_at
  ),
  cold_stage_flags as (
    select
      s.id submission_id,
      s.state,
      expected.slot,
      pg_catalog.count(distinct e.equipment_id)::bigint active_equipment_count,
      pg_catalog.count(distinct r.equipment_id) filter (
        where r.submitted_at is not null
          and r.temperature_c is not null
          and r.status in ('pass', 'fail')
      )::bigint valid_reading_count,
      pg_catalog.count(distinct r.equipment_id) filter (where r.status = 'fail')::bigint failed_reading_count
    from public.cold_storage_submissions s
    cross join (values ('12:00'), ('20:00'), ('02:00')) expected(slot)
    left join public.cold_storage_equipment e on e.submission_id = s.id and e.active
    left join public.cold_storage_readings r
      on r.submission_id = s.id
      and r.equipment_id = e.equipment_id
      and r.slot = expected.slot
    where s.organization_id = c.organization_id
      and s.branch_id = c.branch_id
      and s.business_date = c.business_date
    group by s.id, s.state, expected.slot
  ),
  cold_metrics as (
    select
      'cold_storage'::text checklist_type,
      case
        when pg_catalog.count(*) filter (
          where active_equipment_count > 0
            and valid_reading_count = active_equipment_count
        ) = 3 then 'submitted'
        else 'draft'
      end state,
      case when pg_catalog.max(active_equipment_count) > 0 then 3 else 0 end::bigint expected_checks,
      pg_catalog.count(*) filter (
        where active_equipment_count > 0
          and valid_reading_count = active_equipment_count
      )::bigint answered_checks,
      pg_catalog.count(*) filter (
        where active_equipment_count > 0
          and valid_reading_count = active_equipment_count
          and failed_reading_count = 0
      )::bigint compliant_checks,
      pg_catalog.count(*) filter (
        where active_equipment_count > 0
          and valid_reading_count = active_equipment_count
          and failed_reading_count > 0
      )::bigint issue_checks
    from cold_stage_flags
    group by submission_id
  ),
  raw as (
    select * from opening_metrics
    union all select * from hygiene_metrics
    union all select * from oil_metrics
    union all select * from cold_metrics
  ),
  required as (
    select * from raw
    union all
    select 'oil_tracking', 'not_started', 2::bigint, 0::bigint, 0::bigint, 0::bigint
    where not exists (select 1 from raw where checklist_type = 'oil_tracking')
    union all
    select 'cold_storage', 'not_started', 0::bigint, 0::bigint, 0::bigint, 0::bigint
    where not exists (select 1 from raw where checklist_type = 'cold_storage')
  ),
  day_off_adjusted as (
    select
      checklist_type,
      state,
      case
        when v_is_day_off and state = 'not_started' then 0::bigint
        else greatest(expected_checks, answered_checks)
      end as expected_checks,
      answered_checks,
      compliant_checks,
      issue_checks
    from required
  ),
  completion_basis as (
    select
      day_off_adjusted.*,
      case
        when checklist_type not in ('oil_tracking', 'cold_storage') or state = 'submitted' or expected_checks = 0
          then answered_checks
        else least(answered_checks, greatest(expected_checks - 1, 0))
      end::bigint as completion_answered_checks
    from day_off_adjusted
  ),
  metrics as (
    select
      checklist_type,
      state,
      expected_checks,
      answered_checks,
      compliant_checks,
      issue_checks,
      completion_answered_checks,
      (expected_checks - answered_checks)::bigint as pending_checks,
      case
        when expected_checks = 0 then null
        when completion_answered_checks >= expected_checks then 100
        else least(99, pg_catalog.round(completion_answered_checks * 100.0 / expected_checks)::int)
      end as completion_percentage,
      case
        when answered_checks = 0 then null
        else pg_catalog.round(compliant_checks * 100.0 / answered_checks)::int
      end as compliance_percentage
    from completion_basis
  ),
  totals as (
    select
      pg_catalog.sum(expected_checks)::bigint as expected_checks,
      pg_catalog.sum(answered_checks)::bigint as answered_checks,
      pg_catalog.sum(compliant_checks)::bigint as compliant_checks,
      pg_catalog.sum(issue_checks)::bigint as issue_checks,
      pg_catalog.sum(pending_checks)::bigint as pending_checks,
      pg_catalog.sum(completion_answered_checks)::bigint as completion_answered_checks
    from metrics
  )
  select pg_catalog.jsonb_build_object(
    'business_date', c.business_date,
    'is_day_off', v_is_day_off,
    'day_off_reason', v_day_off_reason,
    'totals', pg_catalog.jsonb_build_object(
      'expected_checks', t.expected_checks,
      'answered_checks', t.answered_checks,
      'compliant_checks', t.compliant_checks,
      'issue_checks', t.issue_checks,
      'pending_checks', t.pending_checks,
      'completion_percentage', case
        when t.expected_checks = 0 then null
        when t.completion_answered_checks >= t.expected_checks then 100
        else least(99, pg_catalog.round(t.completion_answered_checks * 100.0 / t.expected_checks)::int)
      end,
      'compliance_percentage', case
        when t.answered_checks = 0 then null
        else pg_catalog.round(t.compliant_checks * 100.0 / t.answered_checks)::int
      end
    ),
    'checklists', (
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'checklist_type', m.checklist_type,
          'state', m.state,
          'expected_checks', m.expected_checks,
          'answered_checks', m.answered_checks,
          'compliant_checks', m.compliant_checks,
          'issue_checks', m.issue_checks,
          'pending_checks', m.pending_checks,
          'completion_percentage', m.completion_percentage,
          'compliance_percentage', m.compliance_percentage
        )
        order by case m.checklist_type
          when 'kitchen_opening' then 1
          when 'foh_opening' then 2
          when 'staff_hygiene' then 3
          when 'oil_tracking' then 4
          else 5
        end
      )
      from metrics m
    )
  ) into result
  from totals t;

  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'overview access denied' using errcode = '42501';
end;
$$;

revoke all on function public.get_phase4a_supervisor_overview(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_phase4a_supervisor_overview(uuid, uuid)
  to service_role;

-- =============================================================================
-- C. Missing Issues & Derived-Missing Reports Suppression on Day Off
-- =============================================================================

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
  with active_branches_raw as materialized (
    select
      branch.id,
      branch.name,
      branch.timezone,
      branch.created_at,
      private.management_closed_business_date_at(branch.timezone, as_of) as business_date
    from public.branches branch
    where branch.organization_id = target_organization_id
      and branch.active
  ),
  active_branches as materialized (
    select
      branch.id,
      branch.name,
      branch.timezone,
      branch.created_at,
      branch.business_date,
      case
        when branch.business_date is null then false
        else private.is_branch_day_off(branch.id, branch.business_date)
      end as is_day_off
    from active_branches_raw branch
  ),
  required_opening as (
    select
      branch.id as branch_id,
      branch.name as branch_name,
      branch.business_date,
      checklist.checklist_type
    from active_branches branch
    cross join (values ('kitchen_opening'::text), ('foh_opening'::text)) checklist(checklist_type)
    where branch.business_date is not null
      and not branch.is_day_off
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
    select distinct
      branch.id as branch_id,
      branch.name as branch_name,
      branch.business_date,
      team.id as operational_team_id,
      team.name as operational_team_name
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
      and not branch.is_day_off
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
      null::uuid as operational_team_id, opening.checklist_type
    from required_opening opening
    union all
    select hygiene.branch_id, hygiene.branch_name, hygiene.business_date,
      hygiene.operational_team_id, 'staff_hygiene'::text as checklist_type
    from required_hygiene hygiene
  )
  select
    private.management_missed_issue_id(
      'phase4a:missed:' || missed.checklist_type || ':' || missed.branch_id || ':' ||
      coalesce(missed.operational_team_id::text || ':', '') || missed.business_date
    ) as id,
    private.management_missed_issue_id(
      'phase4a:missing-report:' || missed.checklist_type || ':' || missed.branch_id || ':' ||
      coalesce(missed.operational_team_id::text || ':', '') || missed.business_date
    ) as report_id,
    missed.branch_id,
    missed.branch_name,
    missed.business_date,
    null::uuid as supervisor_user_id,
    null::text as submitted_by,
    missed.checklist_type,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening not checked'
      when 'foh_opening' then 'FOH Opening not checked'
      else 'Staff Hygiene not checked'
    end as title,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening was not submitted before the 04:00 operational close.'
      when 'foh_opening' then 'FOH Opening was not submitted before the 04:00 operational close.'
      else 'Staff Hygiene was not submitted before the 04:00 operational close.'
    end as description,
    'new'::text as status,
    (missed.business_date::timestamp + interval '1 day' + time '04:00') at time zone branch.timezone as created_at,
    'not_checked'::text as item_id,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening not checked'
      when 'foh_opening' then 'FOH Opening not checked'
      else 'Staff Hygiene not checked'
    end as item_text,
    null::uuid as affected_staff_id,
    null::text as affected_staff_name
  from missed
  join active_branches branch on branch.id = missed.branch_id;
$$;

revoke all on function private.phase4a_managed_missed_issue_rows_at(uuid, timestamptz)
  from public, anon, authenticated;

create or replace function private.oil_tracking_managed_missed_issue_rows_at(
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
  section text,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text
)
language sql
stable
security definer
set search_path = ''
as $$
  with active_branches_raw as materialized (
    select
      branch.id,
      branch.name,
      branch.timezone,
      branch.created_at,
      private.phase4a_business_date_at(branch.timezone, as_of) as current_business_date,
      private.management_closed_business_date_at(branch.timezone, as_of) as closed_business_date
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  active_branches as materialized (
    select
      branch.*,
      private.is_branch_day_off(branch.id, branch.current_business_date) as current_is_day_off,
      case
        when branch.closed_business_date is null then false
        else private.is_branch_day_off(branch.id, branch.closed_business_date)
      end as closed_is_day_off
    from active_branches_raw branch
  ),
  required_sections as (
    select
      branch.id as branch_id,
      branch.name as branch_name,
      branch.timezone,
      branch.current_business_date as business_date,
      'opening'::text as section,
      (branch.current_business_date::timestamp + time '15:00') at time zone branch.timezone as cutoff_at
    from active_branches branch
    where not branch.current_is_day_off
      and as_of >= (branch.current_business_date::timestamp + time '15:00') at time zone branch.timezone
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.current_business_date
      )
    union all
    select
      branch.id,
      branch.name,
      branch.timezone,
      branch.closed_business_date,
      'opening'::text,
      (branch.closed_business_date::timestamp + time '15:00') at time zone branch.timezone
    from active_branches branch
    where branch.closed_business_date is not null
      and not branch.closed_is_day_off
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.closed_business_date
      )
    union all
    select
      branch.id,
      branch.name,
      branch.timezone,
      branch.closed_business_date,
      'closing'::text,
      (branch.closed_business_date::timestamp + interval '1 day' + time '04:00') at time zone branch.timezone
    from active_branches branch
    where branch.closed_business_date is not null
      and not branch.closed_is_day_off
      and private.management_branch_existed_at_business_day_start(
        branch.timezone, branch.created_at, branch.closed_business_date
      )
  ),
  selected as (
    select
      required.*,
      submission.id as submission_id,
      submission.opening_submitted_at,
      submission.closing_submitted_at,
      coalesce(active_fryers.active_count, 0) as active_count
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
      select pg_catalog.count(result.id)::int as active_count
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
    ) as id,
    coalesce(missed.submission_id, private.management_missed_issue_id(
      'oil_tracking:missing-report:' || missed.branch_id || ':' || missed.business_date
    )) as report_id,
    missed.branch_id,
    missed.branch_name,
    missed.business_date,
    null::uuid as supervisor_user_id,
    null::text as submitted_by,
    missed.section,
    'Oil Tracking ' || missed.section || ' not checked' as title,
    'Oil Tracking ' || missed.section || ' section was not submitted before its required close.' as description,
    'new'::text as status,
    missed.cutoff_at as created_at,
    'missed:' || missed.section as item_id,
    'Missed ' || missed.section || ' section' as item_text
  from missed;
$$;

revoke all on function private.oil_tracking_managed_missed_issue_rows_at(uuid, timestamptz)
  from public, anon, authenticated;

create or replace function private.cold_storage_missed_slots_for(
  target_branch_id uuid,
  target_business_date date,
  submitted_slots text[],
  as_of timestamptz default pg_catalog.statement_timestamp()
)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    pg_catalog.array_agg(slot order by private.cold_storage_slot_order(slot)),
    array[]::text[]
  )
  from pg_catalog.unnest(private.cold_storage_closed_slots_for(target_branch_id, target_business_date, as_of)) slot
  where not private.is_branch_day_off(target_branch_id, target_business_date)
    and not (
      slot = any(coalesce(submitted_slots, array[]::text[]))
      or (slot = '20:00' and '3:00' = any(coalesce(submitted_slots, array[]::text[])))
      or (slot = '02:00' and '8:00' = any(coalesce(submitted_slots, array[]::text[])))
    );
$$;

revoke all on function private.cold_storage_missed_slots_for(uuid, date, text[], timestamptz)
  from public, anon, authenticated;

create or replace function private.cold_storage_managed_missed_issue_rows_at(
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
  slot text,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text
)
language sql
stable
security definer
set search_path = ''
as $$
  with active_branches as materialized (
    select
      branch.id,
      branch.name,
      branch.timezone,
      branch.created_at,
      private.phase4a_business_date_at(branch.timezone, as_of) as current_business_date,
      private.management_branch_closed(branch.timezone, as_of) as operational_closed
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  candidate_dates as materialized (
    select
      branch.id as branch_id,
      branch.name as branch_name,
      branch.timezone,
      branch.current_business_date as business_date
    from active_branches branch
    where private.management_branch_existed_at_business_day_start(
      branch.timezone, branch.created_at, branch.current_business_date
    )
    union
    select
      branch.id,
      branch.name,
      branch.timezone,
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
  eligible_dates as materialized (
    select candidate.*
    from candidate_dates candidate
    where not private.is_branch_day_off(candidate.branch_id, candidate.business_date)
  ),
  selected_units as materialized (
    select
      candidate.*,
      submission.id as submission_id,
      submission.updated_at,
      coalesce(equipment.active_count, 0) as active_count
    from eligible_dates candidate
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
      select pg_catalog.count(e.id)::int as active_count
      from public.cold_storage_equipment e
      where e.submission_id = submission.id and e.active
    ) equipment on true
  ),
  submitted_slots as materialized (
    select
      unit.branch_id,
      unit.business_date,
      unit.submission_id,
      coalesce(
        pg_catalog.array_agg(slot_completion.slot) filter (where slot_completion.slot is not null),
        array[]::text[]
      ) as slots
    from selected_units unit
    left join lateral (
      select reading.slot
      from public.cold_storage_readings reading
      join public.cold_storage_equipment equipment
        on equipment.submission_id = unit.submission_id
        and equipment.equipment_id = reading.equipment_id
        and equipment.active
      where reading.submission_id = unit.submission_id
        and reading.submitted_at is not null
      group by reading.slot
      having pg_catalog.count(distinct reading.equipment_id) >= unit.active_count
         and unit.active_count > 0
    ) slot_completion on true
    group by unit.branch_id, unit.business_date, unit.submission_id
  ),
  required_units as (
    select unit.*, coalesce(submitted.slots, array[]::text[]) as submitted
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
    end as id,
    coalesce(unit.submission_id, private.management_missed_issue_id(
      'cold_storage:missing-report:' || unit.branch_id || ':' || unit.business_date
    )) as report_id,
    unit.branch_id,
    unit.branch_name,
    unit.business_date,
    null::uuid as supervisor_user_id,
    null::text as submitted_by,
    missed.slot,
    'Chiller & Freezer missed scheduled check - ' || missed.slot as title,
    missed.slot || ' scheduled Chiller & Freezer check was not submitted.' as description,
    'new'::text as status,
    coalesce(unit.updated_at,
      case missed.slot
        when '12:00' then unit.business_date::timestamp + time '20:00'
        when '20:00' then (unit.business_date + 1)::timestamp + time '02:00'
        else (unit.business_date + 1)::timestamp + time '04:00'
      end at time zone unit.timezone
    ) as created_at,
    'missed:' || missed.slot as item_id,
    'Missed ' || missed.slot || ' scheduled check' as item_text
  from required_units unit
  cross join lateral pg_catalog.unnest(
    private.cold_storage_missed_slots_for(
      unit.branch_id, unit.business_date, unit.submitted, as_of
    )
  ) missed(slot);
$$;

revoke all on function private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)
  to service_role;

create or replace function private.sales_tracking_managed_issue_rows_at(
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
  submitted_at timestamptz,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text,
  actual_total numeric,
  pos_total numeric,
  variance numeric
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
      private.phase4a_business_date_at(branch.timezone, as_of) as current_business_date
    from public.branches branch
    where branch.organization_id = target_organization_id
  ),
  branch_candidate_dates as materialized (
    select branch.id, branch.name, branch.created_at, branch.current_business_date as business_date
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
      lifecycle.timezone,
      private.is_branch_day_off(bcd.id, bcd.business_date) as is_day_off
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
    select
      report.id,
      report.branch_id,
      report.business_date,
      report.supervisor_user_id,
      report.branch_name_snapshot,
      report.supervisor_name_snapshot,
      report.submitted_at,
      coalesce(pg_catalog.sum(row.actual_cash + row.actual_credit + row.online_delivery), 0) as actual_total,
      coalesce(pg_catalog.sum(row.pos_cash + row.pos_credit + row.online_delivery), 0) as pos_total
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
    select
      report.id,
      report.id as report_id,
      report.branch_id,
      report.branch_name_snapshot as branch_name,
      report.business_date,
      report.supervisor_user_id,
      report.supervisor_name_snapshot as submitted_by,
      report.submitted_at,
      'Sales Tracking variance issue'::text as title,
      'Actual total ' || report.actual_total || ', POS total ' || report.pos_total ||
        ', variance ' || (report.actual_total - report.pos_total) || '.' as description,
      'new'::text as status,
      report.submitted_at as created_at,
      'variance'::text as item_id,
      'Variance mismatch'::text as item_text,
      report.actual_total,
      report.pos_total,
      report.actual_total - report.pos_total as variance
    from submitted_reports report
    where pg_catalog.round(report.actual_total - report.pos_total, 2) <> 0
  ),
  missed_issues as (
    select
      private.sales_tracking_issue_uuid(
        'sales_tracking:missed:' || branch.id || ':' || branch.business_date
      ) as id,
      private.sales_tracking_issue_uuid(
        'sales_tracking:missing-report:' || branch.id || ':' || branch.business_date
      ) as report_id,
      branch.id as branch_id,
      branch.name as branch_name,
      branch.business_date,
      null::uuid as supervisor_user_id,
      null::text as submitted_by,
      null::timestamptz as submitted_at,
      'Missing Sales Tracking submission'::text as title,
      'Sales Tracking was not submitted before the 04:00 operational close.'::text as description,
      'new'::text as status,
      private.daily_business_report_branch_close_at(branch.business_date, branch.timezone) as created_at,
      'not_checked'::text as item_id,
      'Sales Tracking not checked'::text as item_text,
      0::numeric as actual_total,
      0::numeric as pos_total,
      0::numeric as variance
    from branch_dates branch
    where branch.business_date is not null
      and not branch.is_day_off
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
  select * from missed_issues;
$$;

revoke all on function private.sales_tracking_managed_issue_rows_at(uuid, timestamptz)
  from public, anon, authenticated;

-- =============================================================================
-- D. Manager & Supervisor Notifications (Producers + Non-Destructive Projections)
-- =============================================================================

create or replace function private.incomplete_branch_tasks_completion_at(
  p_organization_id uuid,
  p_branch_id uuid,
  p_business_date date,
  p_as_of timestamptz
)
returns table(module_key text, module_state text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  lifecycle_count bigint;
  lifecycle_timezone text;
  lifecycle_active boolean;
  branch_close_at timestamptz;
  v_is_day_off boolean;
  module_record record;
  team_record record;
  target_submission_id uuid;
  target_state text;
  target_submitted_at timestamptz;
  target_definition_id text;
  target_opening_submitted_at timestamptz;
  target_closing_submitted_at timestamptz;
  evidence_count bigint;
  expected_count bigint;
  actual_count bigint;
  valid_count bigint;
  eligible_count bigint;
  required_pair_count bigint;
  missing_pair_count bigint;
  closed_slots text[];
  required_closed_slots text[];
  branch_0200_required boolean;
  calculated_state text;
  staff_unknown boolean;
begin
  if p_organization_id is null or p_branch_id is null or p_business_date is null or p_as_of is null then
    raise exception 'invalid incomplete branch task evaluation scope' using errcode = '22023';
  end if;

  select pg_catalog.count(*),
    pg_catalog.min(lifecycle.timezone),
    pg_catalog.bool_or(lifecycle.active)
  into lifecycle_count, lifecycle_timezone, lifecycle_active
  from public.daily_report_branch_lifecycle lifecycle
  where lifecycle.organization_id = p_organization_id
    and lifecycle.branch_id = p_branch_id
    and lifecycle.effective_from_business_date <= p_business_date
    and (lifecycle.effective_to_business_date is null
      or lifecycle.effective_to_business_date > p_business_date);
  if lifecycle_count <> 1 then
    raise exception 'incomplete branch task lifecycle is missing or ambiguous' using errcode = '22023';
  end if;
  branch_close_at := private.daily_business_report_branch_close_at(
    p_business_date, lifecycle_timezone);
  if p_as_of < branch_close_at then
    raise exception 'branch business date is not complete' using errcode = '55000';
  end if;

  if not lifecycle_active then
    return query
    select requested.module_key, 'not_required'::text
    from pg_catalog.unnest(array[
      'kitchen_opening', 'foh_opening', 'staff_hygiene', 'daily_audit', 'cold_storage', 'oil_tracking'
    ]::text[]) with ordinality requested(module_key, ordinal)
    order by requested.ordinal;
    return;
  end if;

  if exists(
    select requested.module_key
    from pg_catalog.unnest(array[
      'kitchen_opening', 'foh_opening', 'staff_hygiene', 'daily_audit', 'cold_storage', 'oil_tracking'
    ]::text[]) requested(module_key)
    left join public.daily_report_module_applicability applicability
      on applicability.organization_id = p_organization_id
      and applicability.branch_id = p_branch_id
      and applicability.module_key = requested.module_key
      and applicability.effective_from_business_date <= p_business_date
      and (applicability.effective_to_business_date is null
        or applicability.effective_to_business_date > p_business_date)
    group by requested.module_key
    having pg_catalog.count(applicability.id) <> 1
  ) then
    raise exception 'incomplete branch task applicability is missing or ambiguous' using errcode = '22023';
  end if;

  v_is_day_off := private.is_branch_day_off(p_branch_id, p_business_date);

  for module_record in
    select requested.module_key, applicability.required, requested.ordinal
    from pg_catalog.unnest(array[
      'kitchen_opening', 'foh_opening', 'staff_hygiene', 'daily_audit', 'cold_storage', 'oil_tracking'
    ]::text[]) with ordinality requested(module_key, ordinal)
    join public.daily_report_module_applicability applicability
      on applicability.organization_id = p_organization_id
      and applicability.branch_id = p_branch_id
      and applicability.module_key = requested.module_key
      and applicability.effective_from_business_date <= p_business_date
      and (applicability.effective_to_business_date is null
        or applicability.effective_to_business_date > p_business_date)
    order by requested.ordinal
  loop
    calculated_state := 'unknown';
    if not module_record.required or v_is_day_off then
      calculated_state := 'not_required';

    elsif module_record.module_key in ('kitchen_opening', 'foh_opening') then
      select pg_catalog.count(*) into evidence_count
      from public.checklist_submissions submission
      where submission.organization_id = p_organization_id
        and submission.branch_id = p_branch_id
        and submission.business_date = p_business_date
        and submission.checklist_type = module_record.module_key;
      if evidence_count = 0 then
        calculated_state := 'incomplete';
      elsif evidence_count > 1 then
        calculated_state := 'unknown';
      else
        select submission.id, submission.state, submission.submitted_at, submission.definition_id
        into target_submission_id, target_state, target_submitted_at, target_definition_id
        from public.checklist_submissions submission
        where submission.organization_id = p_organization_id
          and submission.branch_id = p_branch_id
          and submission.business_date = p_business_date
          and submission.checklist_type = module_record.module_key;
        if target_state = 'draft' and target_submitted_at is null then
          calculated_state := 'incomplete';
        elsif target_state <> 'submitted' or target_submitted_at is null
          or target_submitted_at > p_as_of
          or not exists(
            select 1 from public.checklist_definitions definition
            where definition.id = target_definition_id
              and definition.checklist_type = module_record.module_key
          ) then
          calculated_state := 'unknown';
        else
          select pg_catalog.count(*) into expected_count
          from public.checklist_definition_items definition_item
          where definition_item.definition_id = target_definition_id;
          select pg_catalog.count(*),
            pg_catalog.count(*) filter(where result.answer in ('completed', 'issue_found'))
          into actual_count, valid_count
          from public.opening_item_results result
          join public.checklist_definition_items definition_item
            on definition_item.definition_id = result.definition_id
            and definition_item.item_id = result.item_id
            and definition_item.ordinal = result.ordinal
          where result.submission_id = target_submission_id
            and result.definition_id = target_definition_id;
          if expected_count > 0 and actual_count = expected_count and valid_count = expected_count
            and not exists(
              select result.item_id from public.opening_item_results result
              where result.submission_id = target_submission_id
              group by result.item_id having pg_catalog.count(*) > 1
            )
            and not exists(
              select 1 from public.opening_item_results result
              where result.submission_id = target_submission_id
              and (result.definition_id <> target_definition_id
                or not exists(
                  select 1 from public.checklist_definition_items definition_item
                  where definition_item.definition_id = result.definition_id
                    and definition_item.item_id = result.item_id
                    and definition_item.ordinal = result.ordinal
                ))
            ) then calculated_state := 'completed';
          else calculated_state := 'unknown'; end if;
        end if;
      end if;

    elsif module_record.module_key = 'daily_audit' then
      select pg_catalog.count(*) into evidence_count
      from public.checklist_submissions submission
      where submission.organization_id = p_organization_id
        and submission.branch_id = p_branch_id
        and submission.business_date = p_business_date
        and submission.checklist_type = 'daily_audit';
      if evidence_count = 0 then calculated_state := 'incomplete';
      elsif evidence_count > 1 then calculated_state := 'unknown';
      else
        select submission.id, submission.state, submission.submitted_at, submission.definition_id
        into target_submission_id, target_state, target_submitted_at, target_definition_id
        from public.checklist_submissions submission
        where submission.organization_id = p_organization_id
          and submission.branch_id = p_branch_id
          and submission.business_date = p_business_date
          and submission.checklist_type = 'daily_audit';
        if target_state = 'draft' and target_submitted_at is null then
          calculated_state := 'incomplete';
        elsif target_state <> 'submitted' or target_submitted_at is null
          or target_submitted_at > p_as_of then
          calculated_state := 'unknown';
        else
          select pg_catalog.count(*) into expected_count
          from public.daily_audit_item_definitions definition where definition.active;
          select pg_catalog.count(*),
            pg_catalog.count(*) filter(where result.answer in ('compliant', 'non_compliant'))
          into actual_count, valid_count
          from public.daily_audit_item_results result
          join public.daily_audit_item_definitions definition
            on definition.item_id = result.item_id and definition.item_number = result.item_number
          where result.submission_id = target_submission_id
            and result.organization_id = p_organization_id
            and result.branch_id = p_branch_id and definition.active;
          if expected_count = 13 and actual_count = expected_count and valid_count = expected_count
            and not exists(
              select result.item_id from public.daily_audit_item_results result
              where result.submission_id = target_submission_id
              group by result.item_id having pg_catalog.count(*) > 1
            )
            and not exists(
              select 1 from public.daily_audit_item_results result
              where result.submission_id = target_submission_id
              and (result.organization_id <> p_organization_id or result.branch_id <> p_branch_id
                or not exists(
                  select 1 from public.daily_audit_item_definitions definition
                  where definition.item_id = result.item_id
                    and definition.item_number = result.item_number and definition.active
                ))
            ) then calculated_state := 'completed';
          else calculated_state := 'unknown'; end if;
        end if;
      end if;

    elsif module_record.module_key = 'staff_hygiene' then
      staff_unknown := false;
      if exists(
        select assignment.operational_staff_id
        from public.operational_staff_assignments assignment
        where assignment.organization_id = p_organization_id
          and assignment.valid_from <= p_business_date
          and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
        group by assignment.operational_staff_id
        having pg_catalog.count(*) > 1
      ) or exists(
        select 1 from public.operational_staff_assignments assignment
        join public.branch_operational_teams team
          on team.id = assignment.operational_team_id
        join public.operational_staff staff
          on staff.id = assignment.operational_staff_id
          and staff.organization_id = assignment.organization_id
        where assignment.organization_id = p_organization_id
          and assignment.branch_id = p_branch_id
          and assignment.valid_from <= p_business_date
          and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
          and (team.organization_id <> p_organization_id or team.branch_id <> p_branch_id
            or assignment.created_at > branch_close_at
            or team.created_at > branch_close_at
            or staff.created_at > branch_close_at)
      ) then
        staff_unknown := true;
      end if;

      with eligible as(
        select assignment.operational_team_id, assignment.operational_staff_id
        from public.operational_staff_assignments assignment
        join public.branch_operational_teams team
          on team.id = assignment.operational_team_id
          and team.organization_id = assignment.organization_id
          and team.branch_id = assignment.branch_id
        join public.operational_staff staff
          on staff.id = assignment.operational_staff_id
          and staff.organization_id = assignment.organization_id
        left join public.operational_staff_duty_statuses duty
          on duty.assignment_id = assignment.id
          and duty.operational_staff_id = assignment.operational_staff_id
          and duty.organization_id = assignment.organization_id
          and duty.branch_id = assignment.branch_id
          and duty.duty_date = p_business_date
        where assignment.organization_id = p_organization_id
          and assignment.branch_id = p_branch_id
          and assignment.valid_from <= p_business_date
          and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
          and assignment.created_at <= branch_close_at
          and team.created_at <= branch_close_at
          and staff.created_at <= branch_close_at
          and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
      ) select pg_catalog.count(*) into eligible_count from eligible;

      if staff_unknown then calculated_state := 'unknown';
      elsif eligible_count = 0 then calculated_state := 'not_required';
      elsif exists(
        with eligible_teams as(
          select distinct assignment.operational_team_id
          from public.operational_staff_assignments assignment
          join public.branch_operational_teams team
            on team.id = assignment.operational_team_id
            and team.organization_id = assignment.organization_id
            and team.branch_id = assignment.branch_id
          join public.operational_staff staff
            on staff.id = assignment.operational_staff_id
            and staff.organization_id = assignment.organization_id
          left join public.operational_staff_duty_statuses duty
            on duty.assignment_id = assignment.id
            and duty.operational_staff_id = assignment.operational_staff_id
            and duty.organization_id = assignment.organization_id
            and duty.branch_id = assignment.branch_id
            and duty.duty_date = p_business_date
          where assignment.organization_id = p_organization_id
            and assignment.branch_id = p_branch_id
            and assignment.valid_from <= p_business_date
            and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
            and assignment.created_at <= branch_close_at
            and team.created_at <= branch_close_at
            and staff.created_at <= branch_close_at
            and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
        )
        select 1 from public.checklist_submissions submission
        where submission.organization_id = p_organization_id
          and submission.branch_id = p_branch_id
          and submission.business_date = p_business_date
          and submission.checklist_type = 'staff_hygiene'
          and (submission.operational_team_id is null
            or not exists(select 1 from eligible_teams team
              where team.operational_team_id = submission.operational_team_id))
      ) then calculated_state := 'unknown';
      else
        calculated_state := 'completed';
        for team_record in
          with eligible as(
            select assignment.operational_team_id, assignment.operational_staff_id
            from public.operational_staff_assignments assignment
            join public.branch_operational_teams team
              on team.id = assignment.operational_team_id
              and team.organization_id = assignment.organization_id
              and team.branch_id = assignment.branch_id
            join public.operational_staff staff
              on staff.id = assignment.operational_staff_id
              and staff.organization_id = assignment.organization_id
            left join public.operational_staff_duty_statuses duty
              on duty.assignment_id = assignment.id
              and duty.operational_staff_id = assignment.operational_staff_id
              and duty.organization_id = assignment.organization_id
              and duty.branch_id = assignment.branch_id
              and duty.duty_date = p_business_date
            where assignment.organization_id = p_organization_id
              and assignment.branch_id = p_branch_id
              and assignment.valid_from <= p_business_date
              and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
              and assignment.created_at <= branch_close_at
              and team.created_at <= branch_close_at
              and staff.created_at <= branch_close_at
              and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
          ) select eligible.operational_team_id, pg_catalog.count(*) eligible_staff_count
            from eligible group by eligible.operational_team_id
        loop
          select pg_catalog.count(*) into evidence_count
          from public.checklist_submissions submission
          where submission.organization_id = p_organization_id
            and submission.branch_id = p_branch_id
            and submission.business_date = p_business_date
            and submission.checklist_type = 'staff_hygiene'
            and submission.operational_team_id = team_record.operational_team_id;
          if evidence_count = 0 then calculated_state := 'incomplete';
          elsif evidence_count > 1 then calculated_state := 'unknown'; exit;
          else
            select submission.id, submission.state, submission.submitted_at
            into target_submission_id, target_state, target_submitted_at
            from public.checklist_submissions submission
            where submission.organization_id = p_organization_id
              and submission.branch_id = p_branch_id
              and submission.business_date = p_business_date
              and submission.checklist_type = 'staff_hygiene'
              and submission.operational_team_id = team_record.operational_team_id;
            if target_state = 'draft' and target_submitted_at is null then
              calculated_state := 'incomplete';
            elsif target_state <> 'submitted' or target_submitted_at is null
              or target_submitted_at > p_as_of then
              calculated_state := 'unknown'; exit;
            else
              with eligible as(
                select assignment.operational_staff_id
                from public.operational_staff_assignments assignment
                join public.branch_operational_teams team
                  on team.id = assignment.operational_team_id
                  and team.organization_id = assignment.organization_id
                  and team.branch_id = assignment.branch_id
                join public.operational_staff staff
                  on staff.id = assignment.operational_staff_id
                  and staff.organization_id = assignment.organization_id
                left join public.operational_staff_duty_statuses duty
                  on duty.assignment_id = assignment.id
                  and duty.operational_staff_id = assignment.operational_staff_id
                  and duty.organization_id = assignment.organization_id
                  and duty.branch_id = assignment.branch_id
                  and duty.duty_date = p_business_date
                where assignment.organization_id = p_organization_id
                  and assignment.branch_id = p_branch_id
                  and assignment.operational_team_id = team_record.operational_team_id
                  and assignment.valid_from <= p_business_date
                  and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
                  and assignment.created_at <= branch_close_at
                  and team.created_at <= branch_close_at
                  and staff.created_at <= branch_close_at
                  and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
              ), snapshots as(
                select snapshot.operational_staff_id, snapshot.uniform_result,
                  snapshot.fingernails_result, snapshot.hair_result, snapshot.facial_hair_result
                from public.hygiene_staff_snapshots snapshot
                where snapshot.submission_id = target_submission_id
              )
              select pg_catalog.count(*),
                pg_catalog.count(*) filter(where snapshots.uniform_result in ('pass', 'issue')
                  and snapshots.fingernails_result in ('pass', 'issue')
                  and snapshots.hair_result in ('pass', 'issue')
                  and snapshots.facial_hair_result in ('pass', 'issue'))
              into actual_count, valid_count from snapshots;
              if actual_count <> team_record.eligible_staff_count
                or valid_count <> team_record.eligible_staff_count
                or exists(
                  select snapshot.operational_staff_id
                  from public.hygiene_staff_snapshots snapshot
                  where snapshot.submission_id = target_submission_id
                  group by snapshot.operational_staff_id having pg_catalog.count(*) > 1
                )
                or exists(
                  with eligible as(
                    select assignment.operational_staff_id
                    from public.operational_staff_assignments assignment
                    join public.branch_operational_teams team
                      on team.id = assignment.operational_team_id
                      and team.organization_id = assignment.organization_id
                      and team.branch_id = assignment.branch_id
                    join public.operational_staff staff
                      on staff.id = assignment.operational_staff_id
                      and staff.organization_id = assignment.organization_id
                    left join public.operational_staff_duty_statuses duty
                      on duty.assignment_id = assignment.id
                      and duty.operational_staff_id = assignment.operational_staff_id
                      and duty.organization_id = assignment.organization_id
                      and duty.branch_id = assignment.branch_id
                      and duty.duty_date = p_business_date
                    where assignment.organization_id = p_organization_id
                      and assignment.branch_id = p_branch_id
                      and assignment.operational_team_id = team_record.operational_team_id
                      and assignment.valid_from <= p_business_date
                      and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
                      and assignment.created_at <= branch_close_at
                      and team.created_at <= branch_close_at
                      and staff.created_at <= branch_close_at
                      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
                  ), snapshots as(
                    select snapshot.operational_staff_id
                    from public.hygiene_staff_snapshots snapshot
                    where snapshot.submission_id = target_submission_id
                  )
                  select 1 from eligible
                  full join snapshots
                    on snapshots.operational_staff_id = eligible.operational_staff_id
                  where eligible.operational_staff_id is null or snapshots.operational_staff_id is null
                ) then calculated_state := 'unknown'; exit; end if;
            end if;
          end if;
        end loop;
      end if;

    elsif module_record.module_key = 'cold_storage' then
      select pg_catalog.count(*) into evidence_count
      from public.cold_storage_submissions submission
      where submission.organization_id = p_organization_id
        and submission.branch_id = p_branch_id and submission.business_date = p_business_date;

      select coalesce(b.cold_storage_0200_notification_required, true)
      into branch_0200_required
      from public.branches b
      where b.id = p_branch_id and b.organization_id = p_organization_id;

      select private.cold_storage_closed_slots_for(p_branch_id, p_business_date, p_as_of)
        into closed_slots;

      if not branch_0200_required then
        required_closed_slots := pg_catalog.array_remove(closed_slots, '02:00');
      else
        required_closed_slots := closed_slots;
      end if;

      if closed_slots is null or pg_catalog.cardinality(closed_slots) = 0
        or pg_catalog.cardinality(closed_slots) <> (select pg_catalog.count(distinct slot_value.slot)
          from pg_catalog.unnest(closed_slots) slot_value(slot))
        or not (closed_slots <@ array['12:00', '20:00', '02:00']::text[]) then
        calculated_state := 'unknown';
      elsif evidence_count = 0 then
        with required_pairs as(
          select master.id, slot.slot
          from public.branch_cold_storage_equipment master
          cross join pg_catalog.unnest(required_closed_slots) slot(slot)
          left join lateral private.cold_storage_master_first_eligible_slot(
            lifecycle_timezone, master.created_at) eligibility on true
          where master.organization_id = p_organization_id
            and master.branch_id = p_branch_id
            and master.active
            and master.created_at <= branch_close_at
            and private.cold_storage_equipment_slot_eligible(
              eligibility.first_eligible_business_date, eligibility.first_eligible_slot,
              p_business_date, slot.slot)
        ) select pg_catalog.count(*) into required_pair_count from required_pairs;

        if required_pair_count > 0 then
          calculated_state := 'incomplete';
        else
          calculated_state := 'unknown';
        end if;
      elsif evidence_count > 1 then
        calculated_state := 'unknown';
      else
        select submission.id, submission.state into target_submission_id, target_state
        from public.cold_storage_submissions submission
        where submission.organization_id = p_organization_id
          and submission.branch_id = p_branch_id and submission.business_date = p_business_date;

        if not exists(select 1 from public.cold_storage_equipment equipment
          where equipment.submission_id = target_submission_id)
          or exists(
            select 1 from public.cold_storage_equipment equipment
            left join public.branch_cold_storage_equipment master
              on master.id = equipment.master_equipment_id
              and master.organization_id = p_organization_id and master.branch_id = p_branch_id
            where equipment.submission_id = target_submission_id
              and (equipment.master_equipment_id is null or equipment.organization_id <> p_organization_id
                or equipment.branch_id <> p_branch_id or master.id is null)
          ) or exists(
            select equipment.master_equipment_id from public.cold_storage_equipment equipment
            where equipment.submission_id = target_submission_id
            group by equipment.master_equipment_id having pg_catalog.count(*) > 1
          ) or exists(
            select equipment.equipment_id from public.cold_storage_equipment equipment
            where equipment.submission_id = target_submission_id
            group by equipment.equipment_id having pg_catalog.count(*) > 1
          ) or exists(
            select reading.equipment_id, reading.slot from public.cold_storage_readings reading
            where reading.submission_id = target_submission_id
            group by reading.equipment_id, reading.slot having pg_catalog.count(*) > 1
          ) then calculated_state := 'unknown';
        else
          with required_pairs as(
            select equipment.equipment_id, slot.slot
            from public.cold_storage_equipment equipment
            join public.branch_cold_storage_equipment master
              on master.id = equipment.master_equipment_id
              and master.organization_id = p_organization_id and master.branch_id = p_branch_id
            cross join pg_catalog.unnest(required_closed_slots) slot(slot)
            left join lateral private.cold_storage_master_first_eligible_slot(
              lifecycle_timezone, master.created_at) eligibility on true
            where equipment.submission_id = target_submission_id and equipment.active
              and private.cold_storage_equipment_slot_eligible(
                eligibility.first_eligible_business_date, eligibility.first_eligible_slot,
                p_business_date, slot.slot)
          ) select pg_catalog.count(*), pg_catalog.count(*) filter(where reading.id is null
              or reading.submitted_at is null or reading.submitted_at > p_as_of
              or reading.temperature_c is null or reading.status not in ('pass', 'fail'))
            into required_pair_count, missing_pair_count
            from required_pairs pair
            left join public.cold_storage_readings reading
              on reading.submission_id = target_submission_id
              and reading.equipment_id = pair.equipment_id and reading.slot = pair.slot;

          if required_pair_count = 0 then calculated_state := 'unknown';
          elsif exists(
            with allowed_pairs as(
              select equipment.equipment_id, slot.slot
              from public.cold_storage_equipment equipment
              join public.branch_cold_storage_equipment master
                on master.id = equipment.master_equipment_id
                and master.organization_id = p_organization_id and master.branch_id = p_branch_id
              cross join pg_catalog.unnest(closed_slots) slot(slot)
              left join lateral private.cold_storage_master_first_eligible_slot(
                lifecycle_timezone, master.created_at) eligibility on true
              where equipment.submission_id = target_submission_id and equipment.active
                and private.cold_storage_equipment_slot_eligible(
                  eligibility.first_eligible_business_date, eligibility.first_eligible_slot,
                  p_business_date, slot.slot)
            ) select 1 from public.cold_storage_readings reading
              where reading.submission_id = target_submission_id and reading.submitted_at is not null
                and not exists(select 1 from allowed_pairs pair
                  where pair.equipment_id = reading.equipment_id and pair.slot = reading.slot)
          ) then calculated_state := 'unknown';
          elsif missing_pair_count > 0 then
            calculated_state := case when target_state = 'submitted' then 'unknown' else 'incomplete' end;
          elsif target_state <> 'submitted' then
            if not branch_0200_required and target_state = 'draft' then
              calculated_state := 'completed';
            else
              calculated_state := 'unknown';
            end if;
          else calculated_state := 'completed'; end if;
        end if;
      end if;

    elsif module_record.module_key = 'oil_tracking' then
      select pg_catalog.count(*) into evidence_count
      from public.oil_tracking_submissions submission
      where submission.organization_id = p_organization_id
        and submission.branch_id = p_branch_id and submission.business_date = p_business_date;

      if evidence_count = 0 then
        calculated_state := 'incomplete';
      elsif evidence_count > 1 then
        calculated_state := 'unknown';
      else
        select submission.id, submission.state, submission.opening_submitted_at,
          submission.closing_submitted_at
        into target_submission_id, target_state, target_opening_submitted_at, target_closing_submitted_at
        from public.oil_tracking_submissions submission
        where submission.organization_id = p_organization_id
          and submission.branch_id = p_branch_id and submission.business_date = p_business_date;

        select pg_catalog.count(*),
          pg_catalog.count(*) filter(where result.in_use_today)
        into actual_count, eligible_count
        from public.oil_tracking_fryer_results result
        where result.submission_id = target_submission_id;

        if exists(
          select result.fryer_id from public.oil_tracking_fryer_results result
          where result.submission_id = target_submission_id
          group by result.fryer_id having pg_catalog.count(*) > 1
        ) then
          calculated_state := 'unknown';
        elsif target_opening_submitted_at is not null
          and (target_opening_submitted_at > p_as_of or exists(
            select 1 from public.oil_tracking_fryer_results result
            where result.submission_id = target_submission_id and result.in_use_today
              and (result.oil_status not in ('new_oil', 'filtered_oil')
                or result.opening_temperature_c is null
                or result.opening_status not in ('pass', 'fail')
                or (result.opening_status = 'fail' and pg_catalog.length(pg_catalog.btrim(result.opening_note)) = 0))
          )) then
          calculated_state := 'unknown';
        elsif target_closing_submitted_at is not null
          and (target_closing_submitted_at > p_as_of or exists(
            select 1 from public.oil_tracking_fryer_results result
            where result.submission_id = target_submission_id and result.in_use_today
              and (result.closing_tpm_percent is null
                or (result.closing_tpm_percent >= 21
                  and pg_catalog.length(pg_catalog.btrim(result.closing_note)) = 0))
          )) then
          calculated_state := 'unknown';
        elsif eligible_count = 0 then
          calculated_state := 'incomplete';
        elsif target_opening_submitted_at is null
          or target_closing_submitted_at is null then
          calculated_state := case when target_state = 'submitted' then 'unknown' else 'incomplete' end;
        elsif target_state <> 'submitted' then
          calculated_state := 'unknown';
        else
          calculated_state := 'completed';
        end if;
      end if;
    end if;

    if calculated_state not in ('completed', 'incomplete', 'not_required', 'unknown') then
      raise exception 'invalid incomplete branch task module state' using errcode = '22023';
    end if;
    module_key := module_record.module_key;
    module_state := calculated_state;
    return next;
  end loop;
end
$$;

revoke all on function private.incomplete_branch_tasks_completion_at(uuid, uuid, date, timestamptz)
  from public, anon, authenticated, service_role;

create or replace function private.organization_manager_sales_tracking_status(
  p_organization_id uuid,
  p_branch_id uuid,
  p_business_date date,
  p_as_of timestamptz
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  applicability_count integer;
  applicability_required boolean;
  case_count integer;
  authoritative_id uuid;
  open_correction_id uuid;
  report_count integer;
  report_case_id uuid;
  report_org_id uuid;
  report_branch_id uuid;
  report_date date;
  report_state text;
  report_review_status text;
  report_submitted_at timestamptz;
  correction_case_id uuid;
  correction_org_id uuid;
  correction_branch_id uuid;
  correction_date date;
  correction_state text;
begin
  if p_organization_id is null or p_branch_id is null or p_business_date is null or p_as_of is null
    or not private.organization_manager_notification_branch_date_closed(
      p_organization_id, p_branch_id, p_business_date, p_as_of) then
    return 'unknown';
  end if;

  select pg_catalog.count(*)::integer, pg_catalog.bool_and(applicability.required)
    into applicability_count, applicability_required
  from public.daily_report_module_applicability applicability
  where applicability.organization_id = p_organization_id
    and applicability.branch_id = p_branch_id
    and applicability.module_key = 'sales_tracking'
    and applicability.effective_from_business_date <= p_business_date
    and (applicability.effective_to_business_date is null
      or applicability.effective_to_business_date > p_business_date);
  if applicability_count <> 1 then return 'unknown'; end if;
  if not coalesce(applicability_required, false)
    or private.is_branch_day_off(p_branch_id, p_business_date)
  then
    return 'satisfied';
  end if;

  select pg_catalog.count(*)::integer into case_count
  from public.sales_tracking_report_cases c
  where c.organization_id = p_organization_id and c.branch_id = p_branch_id
    and c.business_date = p_business_date;
  if case_count > 1 then return 'unknown'; end if;
  if case_count = 0 then return 'missing'; end if;
  select c.authoritative_report_id, c.open_correction_report_id into authoritative_id, open_correction_id
  from public.sales_tracking_report_cases c
  where c.organization_id = p_organization_id and c.branch_id = p_branch_id
    and c.business_date = p_business_date;
  if open_correction_id is not null then
    select pg_catalog.count(*)::integer into report_count
    from public.sales_tracking_reports r where r.id = open_correction_id;
    if report_count <> 1 then return 'unknown'; end if;
    select r.case_id, r.organization_id, r.branch_id, r.business_date, r.state
      into correction_case_id, correction_org_id, correction_branch_id, correction_date, correction_state
    from public.sales_tracking_reports r where r.id = open_correction_id;
    if correction_case_id is distinct from (select c.id from public.sales_tracking_report_cases c
      where c.organization_id = p_organization_id and c.branch_id = p_branch_id and c.business_date = p_business_date)
      or correction_org_id is distinct from p_organization_id
      or correction_branch_id is distinct from p_branch_id
      or correction_date is distinct from p_business_date
      or correction_state is distinct from 'draft' then
      return 'unknown';
    end if;
  end if;
  if authoritative_id is null then return 'missing'; end if;

  select pg_catalog.count(*)::integer into report_count
  from public.sales_tracking_reports r where r.id = authoritative_id;
  if report_count = 1 then
    select r.case_id, r.organization_id, r.branch_id, r.business_date, r.state, r.review_status, r.submitted_at
      into report_case_id, report_org_id, report_branch_id, report_date, report_state,
        report_review_status, report_submitted_at
    from public.sales_tracking_reports r where r.id = authoritative_id;
  end if;
  if report_count <> 1
    or report_case_id is distinct from (select c.id from public.sales_tracking_report_cases c
      where c.organization_id = p_organization_id and c.branch_id = p_branch_id and c.business_date = p_business_date)
    or report_org_id is distinct from p_organization_id
    or report_branch_id is distinct from p_branch_id
    or report_date is distinct from p_business_date
    or report_state is distinct from 'submitted' or report_submitted_at is null
    or report_submitted_at > p_as_of then
    return 'unknown';
  end if;
  if report_review_status is null or report_review_status not in ('none', 'reviewed', 'needs_review') then return 'unknown'; end if;
  return 'satisfied';
end
$$;

revoke all on function private.organization_manager_sales_tracking_status(uuid, uuid, date, timestamptz)
  from public, anon, authenticated, service_role;

create or replace function public.list_organization_manager_notification_projection(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id, p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection list' using errcode = '22023';
  end if;

  return query
  with projected as (
    select
      n.id,
      n.organization_id,
      n.event_type as category,
      n.branch_id,
      n.business_date,
      n.source_type,
      n.source_id,
      null::uuid as legacy_notification_id,
      n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, n.event_type, n.branch_id, n.business_date, n.source_id, n.category_context, pg_catalog.statement_timestamp()
      ) as category_context,
      n.read_at,
      n.created_at
    from public.organization_manager_notifications n
    where n.organization_id = p_organization_id
      and n.recipient_user_id = p_actor_user_id
      and n.event_type in ('sales_tracking_missing', 'maintenance_issue', 'incomplete_branch_tasks')
      and private.organization_manager_category_context_valid(n.event_type, n.category_context)
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id, n.branch_id, n.business_date, pg_catalog.statement_timestamp())
      and (
        n.event_type = 'maintenance_issue'
        or not private.is_branch_day_off(n.branch_id, n.business_date)
      )

    union all

    select
      n.id,
      n.organization_id,
      'maintenance_issue'::text,
      issue.branch_id,
      private.phase4a_business_date_at(branch.timezone, n.created_at),
      'maintenance_issue'::text,
      issue.id,
      n.id,
      n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, 'maintenance_issue', issue.branch_id,
        private.phase4a_business_date_at(branch.timezone, n.created_at), issue.id,
        pg_catalog.jsonb_build_object('schema_version', '1', 'category', 'maintenance_issue', 'scope', 'branch', 'legacy', true, 'issue_id', issue.id),
        pg_catalog.statement_timestamp()
      ) as category_context,
      n.read_at,
      n.created_at
    from public.organization_manager_notifications n
    join public.maintenance_issues issue
      on issue.id = n.source_id and issue.organization_id = n.organization_id
    join public.branches branch
      on branch.id = issue.branch_id and branch.organization_id = issue.organization_id
    where n.organization_id = p_organization_id
      and n.recipient_user_id = p_actor_user_id
      and n.event_type = 'maintenance_issue_created'
      and n.source_type = 'maintenance_issue'
      and not exists(
        select 1
        from public.organization_manager_notifications category_notification
        where category_notification.organization_id = n.organization_id
          and category_notification.recipient_user_id = n.recipient_user_id
          and category_notification.event_type = 'maintenance_issue'
          and private.organization_manager_category_context_valid(
            category_notification.event_type, category_notification.category_context)
          and category_notification.category_context->'issue_ids' ? issue.id::text
      )

    union all

    select
      n.id,
      n.organization_id,
      'maintenance_issue'::text,
      null::uuid,
      null::date,
      n.source_type,
      n.source_id,
      n.id,
      n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version', '1', 'category', 'maintenance_issue', 'scope', 'office', 'legacy', true),
      n.read_at,
      n.created_at
    from public.organization_manager_notifications n
    where n.organization_id = p_organization_id
      and n.recipient_user_id = p_actor_user_id
      and n.event_type = 'maintenance_issue_created'
      and (n.source_type is null or n.source_type <> 'maintenance_issue'
        or not exists(
          select 1 from public.maintenance_issues issue
          where issue.id = n.source_id and issue.organization_id = n.organization_id
        ))
  )
  select
    projected.id,
    projected.organization_id,
    projected.category,
    projected.branch_id,
    projected.business_date,
    projected.source_type,
    projected.source_id,
    projected.legacy_notification_id,
    projected.occurrence_key,
    projected.category_context,
    projected.read_at,
    projected.created_at
  from projected
  where p_before is null
    or projected.created_at < p_before
  order by projected.created_at desc, projected.id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_organization_manager_notification_projection(uuid, uuid, timestamptz, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.list_organization_manager_notification_projection(uuid, uuid, timestamptz, integer)
  to service_role;

create or replace function public.list_organization_manager_notification_projection_cursor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id, p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection cursor list' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid manager notification projection cursor' using errcode = '22023';
  end if;

  return query
  with projected as (
    select
      n.id,
      n.organization_id,
      n.event_type as category,
      n.branch_id,
      n.business_date,
      n.source_type,
      n.source_id,
      null::uuid as legacy_notification_id,
      n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, n.event_type, n.branch_id, n.business_date, n.source_id, n.category_context, pg_catalog.statement_timestamp()
      ) as category_context,
      n.read_at,
      n.created_at
    from public.organization_manager_notifications n
    where n.organization_id = p_organization_id
      and n.recipient_user_id = p_actor_user_id
      and n.event_type in ('sales_tracking_missing', 'maintenance_issue', 'incomplete_branch_tasks')
      and private.organization_manager_category_context_valid(n.event_type, n.category_context)
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id, n.branch_id, n.business_date, pg_catalog.statement_timestamp())
      and (
        n.event_type = 'maintenance_issue'
        or not private.is_branch_day_off(n.branch_id, n.business_date)
      )

    union all

    select
      n.id,
      n.organization_id,
      'maintenance_issue'::text,
      issue.branch_id,
      private.phase4a_business_date_at(branch.timezone, n.created_at),
      'maintenance_issue'::text,
      issue.id,
      n.id,
      n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, 'maintenance_issue', issue.branch_id,
        private.phase4a_business_date_at(branch.timezone, n.created_at), issue.id,
        pg_catalog.jsonb_build_object('schema_version', '1', 'category', 'maintenance_issue', 'scope', 'branch', 'legacy', true, 'issue_id', issue.id),
        pg_catalog.statement_timestamp()
      ) as category_context,
      n.read_at,
      n.created_at
    from public.organization_manager_notifications n
    join public.maintenance_issues issue on issue.id = n.source_id and issue.organization_id = n.organization_id
    join public.branches branch on branch.id = issue.branch_id and branch.organization_id = issue.organization_id
    where n.organization_id = p_organization_id
      and n.recipient_user_id = p_actor_user_id
      and n.event_type = 'maintenance_issue_created'
      and n.source_type = 'maintenance_issue'
      and not exists(
        select 1 from public.organization_manager_notifications category_notification
        where category_notification.organization_id = n.organization_id
          and category_notification.recipient_user_id = n.recipient_user_id
          and category_notification.event_type = 'maintenance_issue'
          and private.organization_manager_category_context_valid(category_notification.event_type, category_notification.category_context)
          and category_notification.category_context->'issue_ids' ? issue.id::text
      )

    union all

    select
      n.id,
      n.organization_id,
      'maintenance_issue'::text,
      null::uuid,
      null::date,
      n.source_type,
      n.source_id,
      n.id,
      n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version', '1', 'category', 'maintenance_issue', 'scope', 'office', 'legacy', true),
      n.read_at,
      n.created_at
    from public.organization_manager_notifications n
    where n.organization_id = p_organization_id
      and n.recipient_user_id = p_actor_user_id
      and n.event_type = 'maintenance_issue_created'
      and (n.source_type is null or n.source_type <> 'maintenance_issue' or not exists(
        select 1 from public.maintenance_issues issue
        where issue.id = n.source_id and issue.organization_id = n.organization_id
      ))
  )
  select
    projected.id,
    projected.organization_id,
    projected.category,
    projected.branch_id,
    projected.business_date,
    projected.source_type,
    projected.source_id,
    projected.legacy_notification_id,
    projected.occurrence_key,
    projected.category_context,
    projected.read_at,
    projected.created_at
  from projected
  where p_before_created_at is null
    or (projected.created_at, projected.id) < (p_before_created_at, p_before_id)
  order by projected.created_at desc, projected.id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_organization_manager_notification_projection_cursor(uuid, uuid, timestamptz, uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.list_organization_manager_notification_projection_cursor(uuid, uuid, timestamptz, uuid, integer)
  to service_role;

create or replace function public.count_organization_manager_notification_projection(
  p_actor_user_id uuid,
  p_organization_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id, p_organization_id);
  return (
    with counts as (
      select pg_catalog.count(*)::bigint as item_count
      from public.organization_manager_notifications n
      where n.organization_id = p_organization_id
        and n.recipient_user_id = p_actor_user_id
        and n.read_at is null
        and n.event_type in ('sales_tracking_missing', 'maintenance_issue', 'incomplete_branch_tasks')
        and private.organization_manager_category_context_valid(n.event_type, n.category_context)
        and private.organization_manager_notification_branch_date_closed(
          n.organization_id, n.branch_id, n.business_date, pg_catalog.statement_timestamp())
        and (
          n.event_type = 'maintenance_issue'
          or not private.is_branch_day_off(n.branch_id, n.business_date)
        )
      union all
      select pg_catalog.count(*)::bigint
      from public.organization_manager_notifications n
      join public.maintenance_issues issue
        on issue.id = n.source_id and issue.organization_id = n.organization_id
      join public.branches branch
        on branch.id = issue.branch_id and branch.organization_id = issue.organization_id
      where n.organization_id = p_organization_id
        and n.recipient_user_id = p_actor_user_id
        and n.read_at is null
        and n.event_type = 'maintenance_issue_created'
        and n.source_type = 'maintenance_issue'
        and not exists(
          select 1 from public.organization_manager_notifications category_notification
          where category_notification.organization_id = n.organization_id
            and category_notification.recipient_user_id = n.recipient_user_id
            and category_notification.event_type = 'maintenance_issue'
            and private.organization_manager_category_context_valid(
              category_notification.event_type, category_notification.category_context)
            and category_notification.category_context->'issue_ids' ? issue.id::text
        )
      union all
      select pg_catalog.count(*)::bigint
      from public.organization_manager_notifications n
      where n.organization_id = p_organization_id
        and n.recipient_user_id = p_actor_user_id
        and n.read_at is null
        and n.event_type = 'maintenance_issue_created'
        and (n.source_type is null or n.source_type <> 'maintenance_issue'
          or not exists(
            select 1 from public.maintenance_issues issue
            where issue.id = n.source_id and issue.organization_id = n.organization_id
          ))
    )
    select coalesce(pg_catalog.sum(item_count), 0)::bigint from counts
  );
end;
$$;

revoke all on function public.count_organization_manager_notification_projection(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.count_organization_manager_notification_projection(uuid, uuid)
  to service_role;

create or replace function public.get_organization_manager_notification_detail(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_notification_id uuid
)
returns table (
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_notif record;
  v_enriched jsonb;
begin
  perform private.assert_active_organization_manager(p_actor_user_id, p_organization_id);

  select * into v_notif
  from public.organization_manager_notifications n
  where n.id = p_notification_id
    and n.organization_id = p_organization_id
    and n.recipient_user_id = p_actor_user_id;

  if v_notif.id is null
    or (
      v_notif.event_type in ('sales_tracking_missing', 'incomplete_branch_tasks')
      and v_notif.branch_id is not null
      and v_notif.business_date is not null
      and private.is_branch_day_off(v_notif.branch_id, v_notif.business_date)
    )
  then
    return;
  end if;

  v_enriched := private.enrich_organization_manager_notification_context(
    v_notif.organization_id, v_notif.event_type, v_notif.branch_id, v_notif.business_date,
    v_notif.source_id, v_notif.category_context, pg_catalog.statement_timestamp()
  );

  return query
  select
    v_notif.id, v_notif.organization_id, v_notif.event_type, v_notif.branch_id,
    v_enriched->>'branch_name', v_enriched->>'branch_name_ar',
    v_notif.business_date, v_notif.source_type, v_notif.source_id,
    null::uuid, v_notif.occurrence_key, v_enriched,
    v_notif.read_at, v_notif.created_at;
end;
$$;

revoke all on function public.get_organization_manager_notification_detail(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_organization_manager_notification_detail(uuid, uuid, uuid)
  to service_role;

create or replace function public.list_organization_manager_notifications(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns table(
  id uuid,
  organization_id uuid,
  event_type text,
  source_type text,
  source_id uuid,
  occurrence_key text,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id, p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification list' using errcode = '22023';
  end if;
  return query
  select
    notification.id,
    notification.organization_id,
    notification.event_type,
    notification.source_type,
    notification.source_id,
    notification.occurrence_key,
    notification.read_at,
    notification.created_at
  from public.organization_manager_notifications notification
  where notification.organization_id = p_organization_id
    and notification.recipient_user_id = p_actor_user_id
    and (p_before is null or notification.created_at < p_before)
    and (
      notification.event_type not in ('sales_tracking_missing', 'maintenance_issue', 'incomplete_branch_tasks')
      or private.organization_manager_notification_branch_date_closed(
        notification.organization_id, notification.branch_id, notification.business_date, pg_catalog.statement_timestamp())
    )
    and (
      notification.event_type not in ('sales_tracking_missing', 'incomplete_branch_tasks')
      or notification.branch_id is null
      or notification.business_date is null
      or not private.is_branch_day_off(notification.branch_id, notification.business_date)
    )
  order by notification.created_at desc, notification.id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_organization_manager_notifications(uuid, uuid, timestamptz, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.list_organization_manager_notifications(uuid, uuid, timestamptz, integer)
  to service_role;

create or replace function private.supervisor_notification_condition_unresolved(
  target_rule_key text,
  target_organization_id uuid,
  target_branch_id uuid,
  target_business_date date,
  as_of timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when private.is_branch_day_off(target_branch_id, target_business_date)
      then false
    when target_rule_key = 'oil_tracking_1800'
      then private.supervisor_notification_oil_unresolved(target_organization_id, target_branch_id, target_business_date)
    when target_rule_key = 'cold_storage_2000'
      then private.supervisor_notification_cold_unresolved(target_organization_id, target_branch_id, target_business_date, as_of)
    when target_rule_key in ('financial_closing_2200', 'financial_closing_2300', 'financial_closing_0200_overdue')
      then private.supervisor_notification_financial_closing_unresolved(target_organization_id, target_branch_id, target_business_date)
    else false
  end;
$$;

revoke all on function private.supervisor_notification_condition_unresolved(text, uuid, uuid, date, timestamptz)
  from public, anon, authenticated;

commit;
