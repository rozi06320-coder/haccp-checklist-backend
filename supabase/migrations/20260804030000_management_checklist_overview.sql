-- Atomic, organization-scoped Phase 4A performance for the Manager Overview.
-- The RPC is read-only and derives every branch business date from one server timestamp.
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
  active_branches as materialized (
    select branch.id, branch.name, branch.code, branch.timezone,
      (snapshot_at at time zone branch.timezone)::date business_date
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  checklist_types(checklist_type, ordinal) as (
    values ('kitchen_opening'::text, 1), ('foh_opening'::text, 2), ('staff_hygiene'::text, 3)
  ),
  active_supervisors as materialized (
    select distinct membership.user_id
    from public.branch_memberships membership
    join active_branches branch on branch.id = membership.branch_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.role = 'branch_manager' and membership.active
      and profile.disabled_at is null and not profile.must_change_password
  ),
  eligible_teams as materialized (
    select team.id team_id, team.branch_id, team.supervisor_user_id
    from public.branch_supervisor_teams team
    join active_branches branch on branch.id = team.branch_id
    join public.profiles profile on profile.id = team.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id = team.branch_id
      and membership.user_id = team.supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
    where team.organization_id = target_organization_id and team.active
      and profile.disabled_at is null and not profile.must_change_password
  ),
  active_work_unit_keys as (
    select branch.id branch_id, team.team_id, branch.business_date, checklist.checklist_type
    from active_branches branch
    join eligible_teams team on team.branch_id = branch.id
    cross join checklist_types checklist
  ),
  current_final_keys as (
    select submission.branch_id, submission.supervisor_team_id team_id,
      submission.business_date, submission.checklist_type
    from public.checklist_submissions submission
    join active_branches branch
      on branch.id = submission.branch_id
      and branch.business_date = submission.business_date
    where submission.organization_id = target_organization_id
      and submission.state = 'submitted'
      and submission.checklist_type in ('kitchen_opening', 'foh_opening', 'staff_hygiene')
  ),
  work_unit_keys as materialized (
    select * from active_work_unit_keys
    union
    select * from current_final_keys
  ),
  selected_units as materialized (
    select work.branch_id, work.team_id, work.business_date, work.checklist_type,
      exists (
        select 1 from eligible_teams team
        where team.team_id = work.team_id and team.branch_id = work.branch_id
      ) eligible_now,
      submission.id submission_id,
      coalesce(submission.state, 'not_started') state
    from work_unit_keys work
    left join lateral (
      select candidate.id, candidate.state
      from public.checklist_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = work.branch_id
        and candidate.supervisor_team_id = work.team_id
        and candidate.business_date = work.business_date
        and candidate.checklist_type = work.checklist_type
        and (
          candidate.state = 'submitted'
          or exists (
            select 1 from eligible_teams team
            where team.team_id = work.team_id and team.branch_id = work.branch_id
          )
        )
      order by case candidate.state when 'submitted' then 0 else 1 end,
        candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
  ),
  opening_metrics as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.checklist_type, unit.state,
      case when unit.state = 'submitted'
        then pg_catalog.count(result.id)
        else pg_catalog.count(definition_item.item_id)
      end::bigint expected_checks,
      pg_catalog.count(result.id) filter (
        where result.answer in ('completed', 'issue_found')
      )::bigint answered_checks,
      pg_catalog.count(result.id) filter (where result.answer = 'completed')::bigint compliant_checks,
      pg_catalog.count(result.id) filter (where result.answer = 'issue_found')::bigint issue_checks
    from selected_units unit
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
    where unit.checklist_type in ('kitchen_opening', 'foh_opening')
    group by unit.branch_id, unit.team_id, unit.business_date, unit.checklist_type, unit.state
  ),
  eligible_hygiene_roster as materialized (
    select distinct assignment.supervisor_team_id team_id, staff.id staff_id
    from public.operational_staff_assignments assignment
    join eligible_teams team on team.team_id = assignment.supervisor_team_id
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
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
  ),
  hygiene_values as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.state, value.result
    from selected_units unit
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
    where unit.checklist_type = 'staff_hygiene' and unit.state <> 'submitted'

    union all

    select unit.branch_id, unit.team_id, unit.business_date, unit.state, value.result
    from selected_units unit
    join public.hygiene_staff_snapshots hygiene on hygiene.submission_id = unit.submission_id
    cross join lateral (
      values (hygiene.uniform_result), (hygiene.fingernails_result),
        (hygiene.hair_result), (hygiene.facial_hair_result)
    ) value(result)
    where unit.checklist_type = 'staff_hygiene' and unit.state = 'submitted'
  ),
  hygiene_metrics as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.checklist_type, unit.state,
      pg_catalog.count(value.result)::bigint expected_checks,
      pg_catalog.count(value.result) filter (where value.result in ('pass', 'issue'))::bigint answered_checks,
      pg_catalog.count(value.result) filter (where value.result = 'pass')::bigint compliant_checks,
      pg_catalog.count(value.result) filter (where value.result = 'issue')::bigint issue_checks
    from selected_units unit
    left join hygiene_values value
      on value.branch_id = unit.branch_id
      and value.team_id = unit.team_id
      and value.business_date = unit.business_date
      and value.state = unit.state
    where unit.checklist_type = 'staff_hygiene'
    group by unit.branch_id, unit.team_id, unit.business_date, unit.checklist_type, unit.state
  ),
  unit_metrics as materialized (
    select * from opening_metrics
    union all
    select * from hygiene_metrics
  ),
  branch_checklist_metrics as materialized (
    select branch.id branch_id, checklist.checklist_type, checklist.ordinal,
      pg_catalog.count(metric.team_id) filter (where metric.state = 'not_started')::bigint not_started_teams,
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
    group by branch.id, checklist.checklist_type, checklist.ordinal
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
  branch_rows as materialized (
    select branch.id branch_id, branch.name branch_name, branch.code branch_code,
      branch.timezone, branch.business_date,
      pg_catalog.count(distinct team.team_id)::bigint active_team_count,
      metric.expected_checks, metric.answered_checks, metric.compliant_checks, metric.issue_checks,
      (metric.expected_checks - metric.answered_checks)::bigint pending_checks,
      case when metric.expected_checks = 0 then null
        else pg_catalog.round(metric.answered_checks * 100.0 / metric.expected_checks)::integer
      end completion_percentage,
      case when metric.answered_checks = 0 then null
        else pg_catalog.round(metric.compliant_checks * 100.0 / metric.answered_checks)::integer
      end compliance_percentage
    from active_branches branch
    join branch_metrics metric on metric.branch_id = branch.id
    left join eligible_teams team on team.branch_id = branch.id
    group by branch.id, branch.name, branch.code, branch.timezone, branch.business_date,
      metric.expected_checks, metric.answered_checks, metric.compliant_checks, metric.issue_checks
  ),
  organization_totals as (
    select coalesce(pg_catalog.sum(branch.expected_checks), 0)::bigint expected_checks,
      coalesce(pg_catalog.sum(branch.answered_checks), 0)::bigint answered_checks,
      coalesce(pg_catalog.sum(branch.compliant_checks), 0)::bigint compliant_checks,
      coalesce(pg_catalog.sum(branch.issue_checks), 0)::bigint issue_checks
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
      'completion_percentage', case when totals.expected_checks = 0 then null
        else pg_catalog.round(totals.answered_checks * 100.0 / totals.expected_checks)::integer end,
      'compliance_percentage', case when totals.answered_checks = 0 then null
        else pg_catalog.round(totals.compliant_checks * 100.0 / totals.answered_checks)::integer end
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
        'status', case when branch.active_team_count = 0 then 'no_active_team' else 'ready' end,
        'active_team_count', branch.active_team_count,
        'totals', pg_catalog.jsonb_build_object(
          'expected_checks', branch.expected_checks,
          'answered_checks', branch.answered_checks,
          'compliant_checks', branch.compliant_checks,
          'issue_checks', branch.issue_checks,
          'pending_checks', branch.pending_checks,
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
            'completion_percentage', case when checklist.expected_checks = 0 then null
              else pg_catalog.round(checklist.answered_checks * 100.0 / checklist.expected_checks)::integer end,
            'compliance_percentage', case when checklist.answered_checks = 0 then null
              else pg_catalog.round(checklist.compliant_checks * 100.0 / checklist.answered_checks)::integer end
          ) order by checklist.ordinal)
          from branch_checklist_metrics checklist
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
  from public, anon, authenticated;
grant execute on function public.get_phase4a_management_overview(uuid, uuid)
  to service_role;
