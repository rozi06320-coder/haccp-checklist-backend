-- Make modern operational teams canonical for Manager Overview eligibility.
-- Historical legacy checklist attribution remains a bounded read fallback only.

do $management_overview_modern_operational_teams$
declare
  definition text;
  replacement text;
  block_start integer;
  block_end integer;
begin
  select pg_catalog.pg_get_functiondef(
    'public.get_phase4a_management_overview(uuid,uuid)'::regprocedure
  ) into definition;

  block_start := pg_catalog.strpos(definition, '  active_supervisors as materialized (');
  block_end := pg_catalog.strpos(definition, '  unit_metrics as materialized (');

  if block_start = 0 or block_end = 0 or block_end <= block_start then
    raise exception 'management overview work-unit block changed' using errcode = '22023';
  end if;

  replacement := $modern_work_units$  active_supervisors as materialized (
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
    select branch.id branch_id, branch.id team_id, branch.business_date,
      checklist.checklist_type, submission.id submission_id,
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
    select unit.branch_id, unit.team_id, unit.business_date, unit.checklist_type, unit.state,
      case when unit.state = 'submitted'
        then pg_catalog.count(result.id)
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
      unit.checklist_type, unit.state
  ),
  hygiene_unit_keys as materialized (
    select team.branch_id, team.team_id, team.legacy_supervisor_team_id,
      branch.business_date
    from eligible_teams team
    join active_branches branch on branch.id = team.branch_id

    union

    select submission.branch_id,
      coalesce(submission.operational_team_id, mapped_team.id, submission.supervisor_team_id) team_id,
      submission.supervisor_team_id legacy_supervisor_team_id,
      submission.business_date
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
    select unit.branch_id, unit.team_id, unit.business_date,
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
    select branch.id branch_id, branch.id team_id, branch.business_date,
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
    select unit.branch_id, unit.team_id, unit.business_date, unit.state,
      unit.submission_id is null no_submission,
      pg_catalog.count(row.id) filter (where row.in_use_today)::int active_count,
      bool_and(
        row.oil_status in ('new_oil','filtered_oil')
        and row.opening_temperature_c is not null
        and row.opening_status in ('pass','fail')
        and (row.opening_status <> 'fail' or length(pg_catalog.btrim(row.opening_note)) > 0)
      ) filter (where row.in_use_today) opening_valid,
      bool_and(row.closing_tpm_percent is not null) filter (where row.in_use_today) closing_valid,
      bool_or(row.opening_status = 'fail') filter (where row.in_use_today) opening_issue,
      bool_or(row.closing_tpm_percent >= 21) filter (where row.in_use_today) closing_issue,
      unit.opening_submitted_at is not null opening_submitted,
      unit.closing_submitted_at is not null closing_submitted
    from oil_selected_units unit
    left join public.oil_tracking_fryer_results row on row.submission_id = unit.submission_id
    group by unit.branch_id, unit.team_id, unit.business_date, unit.state,
      unit.submission_id, unit.opening_submitted_at, unit.closing_submitted_at
  ),
  oil_metrics as materialized (
    select flags.branch_id, flags.team_id, flags.business_date,
      'oil_tracking'::text checklist_type, flags.state,
      case when flags.no_submission or flags.active_count > 0 then 2 else 0 end::bigint expected_checks,
      (case when flags.active_count > 0 and flags.opening_submitted and coalesce(flags.opening_valid, false) then 1 else 0 end
       + case when flags.active_count > 0 and flags.closing_submitted and coalesce(flags.closing_valid, false) then 1 else 0 end)::bigint answered_checks,
      (case when flags.active_count > 0 and flags.opening_submitted and coalesce(flags.opening_valid, false) and not coalesce(flags.opening_issue, false) then 1 else 0 end
       + case when flags.active_count > 0 and flags.closing_submitted and coalesce(flags.closing_valid, false) and not coalesce(flags.closing_issue, false) then 1 else 0 end)::bigint compliant_checks,
      (case when flags.active_count > 0 and flags.opening_submitted and coalesce(flags.opening_valid, false) and coalesce(flags.opening_issue, false) then 1 else 0 end
       + case when flags.active_count > 0 and flags.closing_submitted and coalesce(flags.closing_valid, false) and coalesce(flags.closing_issue, false) then 1 else 0 end)::bigint issue_checks
    from oil_submission_flags flags
  ),
  cold_selected_units as materialized (
    select branch.id branch_id, branch.id team_id, branch.business_date,
      submission.id submission_id, coalesce(submission.state, 'not_started') state,
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
      bool_and(
        reading.submitted_at is not null
        and reading.temperature_c is not null
        and reading.status in ('pass','fail')
      ) filter (where equipment.id is not null) slot_valid,
      bool_or(reading.temperature_c >= 5) filter (where equipment.id is not null) slot_issue
    from cold_selected_units unit
    cross join lateral pg_catalog.unnest(unit.due_cold_slots) due_slot(slot)
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
    select unit.branch_id, unit.team_id, unit.business_date,
      'cold_storage'::text checklist_type, unit.state,
      pg_catalog.cardinality(unit.due_cold_slots)::bigint expected_checks,
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
    group by unit.branch_id, unit.team_id, unit.business_date, unit.state,
      equipment.active_count, unit.due_cold_slots
  ),
  sales_tracking_selected_units as materialized (
    select branch.id branch_id, branch.id team_id, branch.business_date,
      branch.sales_tracking_closed, report.id report_id,
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
      unit.sales_tracking_closed, unit.state,
      coalesce(pg_catalog.sum(
        coalesce(row.actual_cash,0) + coalesce(row.actual_credit,0) + coalesce(row.online_delivery,0)
        - coalesce(row.pos_cash,0) - coalesce(row.pos_credit,0) - coalesce(row.online_delivery,0)
      ),0) variance
    from sales_tracking_selected_units unit
    left join public.sales_tracking_sales_rows row on row.report_id = unit.report_id
    group by unit.branch_id, unit.team_id, unit.business_date,
      unit.sales_tracking_closed, unit.state
  ),
  sales_tracking_metrics as materialized (
    select row.branch_id, row.team_id, row.business_date,
      'sales_tracking'::text checklist_type,
      case when row.state = 'submitted' then 'submitted'
        when row.sales_tracking_closed then 'not_started'
        else 'draft'
      end state,
      1::bigint expected_checks,
      case when row.state = 'submitted' then 1 else 0 end::bigint answered_checks,
      case when row.state = 'submitted' and pg_catalog.round(row.variance,2) = 0 then 1 else 0 end::bigint compliant_checks,
      case when row.state = 'submitted' and pg_catalog.round(row.variance,2) <> 0 then 1 else 0 end::bigint issue_checks
    from sales_tracking_report_variance row
  ),
$modern_work_units$;

  definition := pg_catalog.substr(definition, 1, block_start - 1)
    || replacement
    || pg_catalog.substr(definition, block_end);

  execute definition;
end
$management_overview_modern_operational_teams$;

revoke all on function public.get_phase4a_management_overview(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.get_phase4a_management_overview(uuid,uuid)
  to service_role;
