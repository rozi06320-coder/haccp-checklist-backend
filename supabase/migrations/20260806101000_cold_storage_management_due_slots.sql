do $$
declare definition text;
begin
  select pg_catalog.pg_get_functiondef('public.get_phase4a_management_overview(uuid,uuid)'::regprocedure)
  into definition;

  if definition like '%active_cold_slot%' then
    definition := replace(definition, $old$
      case
        when extract(hour from snapshot_at at time zone branch.timezone) >= 12
          and extract(hour from snapshot_at at time zone branch.timezone) < 16 then '12:00'
        when extract(hour from snapshot_at at time zone branch.timezone) >= 16
          and extract(hour from snapshot_at at time zone branch.timezone) < 20 then '4:00'
        else '8:00'
      end active_cold_slot
$old$, $new$
      case
        when extract(hour from snapshot_at at time zone branch.timezone) < 12 then array[]::text[]
        when extract(hour from snapshot_at at time zone branch.timezone) < 15 then array['12:00']::text[]
        when extract(hour from snapshot_at at time zone branch.timezone) < 20 then array['12:00','3:00']::text[]
        else array['12:00','3:00','8:00']::text[]
      end due_cold_slots
$new$);

    definition := replace(definition, '      branch.active_cold_slot', '      branch.due_cold_slots');

    definition := replace(definition, $old$
  cold_submission_flags as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.state,
      pg_catalog.count(equipment.id) filter (where equipment.active)::int active_count,
      bool_and(
        reading.submitted_at is not null
        and reading.temperature_c is not null
        and reading.status in ('pass','fail')
      ) filter (where equipment.active) slot_valid,
      bool_or(reading.temperature_c >= 5) filter (where equipment.active) slot_issue
    from cold_selected_units unit
    left join public.cold_storage_equipment equipment on equipment.submission_id = unit.submission_id
    left join public.cold_storage_readings reading
      on reading.submission_id = unit.submission_id
      and reading.equipment_id = equipment.equipment_id
      and reading.slot = unit.active_cold_slot
    group by unit.branch_id, unit.team_id, unit.business_date, unit.state
  ),
  cold_metrics as materialized (
    select flags.branch_id, flags.team_id, flags.business_date, 'cold_storage'::text checklist_type, flags.state,
      case when flags.active_count > 0 then 1 else 0 end::bigint expected_checks,
      case when flags.active_count > 0 and coalesce(flags.slot_valid, false) then 1 else 0 end::bigint answered_checks,
      case when flags.active_count > 0 and coalesce(flags.slot_valid, false) and not coalesce(flags.slot_issue, false) then 1 else 0 end::bigint compliant_checks,
      case when flags.active_count > 0 and coalesce(flags.slot_valid, false) and coalesce(flags.slot_issue, false) then 1 else 0 end::bigint issue_checks
    from cold_submission_flags flags
  ),
$old$, $new$
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
    select unit.branch_id, unit.team_id, unit.business_date, 'cold_storage'::text checklist_type, unit.state,
      case when coalesce(equipment.active_count, 0) > 0 then pg_catalog.cardinality(unit.due_cold_slots) else 0 end::bigint expected_checks,
      pg_catalog.count(flags.slot) filter (where flags.active_count > 0 and coalesce(flags.slot_valid, false))::bigint answered_checks,
      pg_catalog.count(flags.slot) filter (where flags.active_count > 0 and coalesce(flags.slot_valid, false) and not coalesce(flags.slot_issue, false))::bigint compliant_checks,
      pg_catalog.count(flags.slot) filter (where flags.active_count > 0 and coalesce(flags.slot_valid, false) and coalesce(flags.slot_issue, false))::bigint issue_checks
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
$new$);

    if definition like '%active_cold_slot%' then
      raise exception 'failed to update cold storage management overview slot logic' using errcode = '22023';
    end if;

    execute definition;
  end if;
end $$;
