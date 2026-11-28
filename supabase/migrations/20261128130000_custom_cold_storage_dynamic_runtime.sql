-- Custom Cold Storage Schedule per Branch — Phase 2B: Dynamic Runtime & 04:00 Boundary Alignment
-- Replaces hardcoded 12:00/20:00/02:00 and 03:00 boundary assumptions while preserving
-- historical schedule_version_id pinning, legacy 3:00/8:00 aliases, Branch Day Off, and existing privileges.

begin;

create or replace function private.cold_storage_slot_order(slot text)
returns integer
language sql
immutable
strict
security definer
set search_path = ''
as $$
  select case
    when slot = '3:00' then 1200
    when slot = '8:00' then 1560
    when slot ~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$' then
      case when slot::time < time '04:00'
        then 1440 + pg_catalog.date_part('hour', slot::time)::integer * 60 + pg_catalog.date_part('minute', slot::time)::integer
        else pg_catalog.date_part('hour', slot::time)::integer * 60 + pg_catalog.date_part('minute', slot::time)::integer
      end
    else null
  end
$$;

create or replace function private.cold_storage_master_first_eligible_slot(
  target_branch_id uuid,
  equipment_created_at timestamp with time zone
)
returns table(first_eligible_business_date date, first_eligible_slot text)
language plpgsql
stable
strict
security definer
set search_path = ''
as $$
declare
  v_branch_timezone text;
  v_local_created timestamp;
  v_created_business_date date;
  v_today_version_id uuid;
  v_next_slot text;
  v_tomorrow_version_id uuid;
  v_tomorrow_slot text;
begin
  select branch.timezone into strict v_branch_timezone
  from public.branches branch
  where branch.id = target_branch_id;

  v_local_created := equipment_created_at at time zone v_branch_timezone;
  v_created_business_date := private.phase4a_business_date_at(v_branch_timezone, equipment_created_at);
  v_today_version_id := private.cold_storage_schedule_version_for(target_branch_id, v_created_business_date);

  select sl.slot_time
  into v_next_slot
  from (
    select s.slot_time, s.operational_ordinal
    from public.cold_storage_schedule_slots s
    where s.schedule_version_id = v_today_version_id
    union all
    select v.slot_time, v.ordinal
    from (values ('12:00', 1), ('20:00', 2), ('02:00', 3)) v(slot_time, ordinal)
    where v_today_version_id is null
  ) sl
  where private.cold_storage_slot_occurrence_local(v_created_business_date, sl.slot_time) > v_local_created
  order by sl.operational_ordinal asc
  limit 1;

  if v_next_slot is not null then
    return query select v_created_business_date, v_next_slot;
    return;
  end if;

  v_tomorrow_version_id := private.cold_storage_schedule_version_for(target_branch_id, v_created_business_date + 1);
  select sl.slot_time
  into v_tomorrow_slot
  from (
    select s.slot_time, s.operational_ordinal
    from public.cold_storage_schedule_slots s
    where s.schedule_version_id = v_tomorrow_version_id
    union all
    select v.slot_time, v.ordinal
    from (values ('12:00', 1), ('20:00', 2), ('02:00', 3)) v(slot_time, ordinal)
    where v_tomorrow_version_id is null
  ) sl
  order by sl.operational_ordinal asc
  limit 1;

  return query select v_created_business_date + 1, coalesce(v_tomorrow_slot, '12:00');
end;
$$;

CREATE OR REPLACE FUNCTION private.cold_storage_managed_missed_issue_rows_at(target_organization_id uuid, as_of timestamp with time zone)
 RETURNS TABLE(id uuid, report_id uuid, branch_id uuid, branch_name text, business_date date, supervisor_user_id uuid, submitted_by text, slot text, title text, description text, status text, created_at timestamp with time zone, item_id text, item_text text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      submission.schedule_version_id,
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
      coalesce(
        (
          select private.cold_storage_slot_occurrence_local(unit.business_date, next_sl.slot_time)
          from public.cold_storage_schedule_slots next_sl
          where next_sl.schedule_version_id = coalesce(
            unit.schedule_version_id,
            private.cold_storage_schedule_version_for(unit.branch_id, unit.business_date)
          )
            and private.cold_storage_slot_order(next_sl.slot_time) > private.cold_storage_slot_order(missed.slot)
          order by private.cold_storage_slot_order(next_sl.slot_time) asc
          limit 1
        ),
        (unit.business_date + 1)::timestamp + time '04:00'
      ) at time zone unit.timezone
    ) as created_at,
    'missed:' || missed.slot as item_id,
    'Missed ' || missed.slot || ' scheduled check' as item_text
  from required_units unit
  cross join lateral pg_catalog.unnest(
    private.cold_storage_missed_slots_for(
      unit.branch_id, unit.business_date, unit.submitted, as_of
    )
  ) missed(slot);
$function$;

CREATE OR REPLACE FUNCTION public.get_phase4a_supervisor_overview(actor_user_id uuid, target_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    cross join lateral (
      select sl.slot_time as slot
      from public.cold_storage_schedule_slots sl
      where sl.schedule_version_id = s.schedule_version_id
      union all
      select v.slot
      from (values ('12:00'), ('20:00'), ('02:00')) v(slot)
      where not exists (
        select 1 from public.cold_storage_schedule_slots sl2
        where sl2.schedule_version_id = s.schedule_version_id
      )
    ) expected
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
$function$;

CREATE OR REPLACE FUNCTION public.get_cold_storage_managed_report_detail(actor_user_id uuid, target_organization_id uuid, target_report_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.cold_storage_submissions%rowtype; submitted_time timestamptz; temperature_issue_total bigint; submitted_slot_array text[]; due_slot_array text[]; missed_slot_array text[];
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
  end if;

  select * into s from public.cold_storage_submissions x
  where x.id = target_report_id
    and x.organization_id = target_organization_id
    and exists (
      select 1
      from public.cold_storage_equipment e
      join public.cold_storage_readings r on r.submission_id = e.submission_id
        and r.equipment_id = e.equipment_id
        and r.submitted_at is not null
      where e.submission_id = x.id
        and e.active
    );

  if found then
    select max(r.submitted_at), coalesce(array_agg(distinct r.slot), array[]::text[]) into submitted_time, submitted_slot_array
    from public.cold_storage_readings r
    join public.cold_storage_equipment e on e.submission_id = r.submission_id
      and e.equipment_id = r.equipment_id
      and e.active
    where r.submission_id = s.id
      and r.submitted_at is not null;
    due_slot_array := private.cold_storage_due_slots_for(s.branch_id, s.business_date);
    missed_slot_array := private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted_slot_array);
    select count(*) into temperature_issue_total from public.cold_storage_issues i where i.submission_id = s.id;
    return pg_catalog.jsonb_build_object(
      'id', s.id,
      'record_kind', 'submission',
      'source_submission_id', s.id,
      'organization_id', s.organization_id,
      'branch_id', s.branch_id,
      'branch_name', s.branch_name_snapshot,
      'supervisor_team_id', s.supervisor_team_id,
      'business_date', s.business_date,
      'checklist_type', 'cold_storage',
      'definition_id', 'cold_storage_v1',
      'submitted_at', submitted_time,
      'submitted_by', s.supervisor_name_snapshot,
      'completion', case when cardinality(due_slot_array) = 0 then 0 else pg_catalog.round((cardinality(submitted_slot_array)::numeric * 100) / cardinality(due_slot_array)) end,
      'issue_count', temperature_issue_total + cardinality(missed_slot_array),
      'missed_check_count', cardinality(missed_slot_array),
      'missed_slots', to_jsonb(missed_slot_array),
      'status',
        case
          when temperature_issue_total > 0 or cardinality(missed_slot_array) > 0 then 'issues_found'
          when cardinality(submitted_slot_array) < cardinality(due_slot_array) then 'in_progress'
          else 'compliant'
        end,
      'submitted_slots', to_jsonb(submitted_slot_array),
      'rows', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
          'equipment_id', e.equipment_id,
          'equipment_code', e.equipment_code,
          'equipment_name', e.equipment_name,
          'equipment_type', e.equipment_type,
          'active', e.active,
          'slot', r.slot,
          'temperature_c', r.temperature_c,
          'status', r.status,
          'corrective_action', r.corrective_action,
          'submitted_at', r.submitted_at
        )) order by r.slot, e.equipment_id)
        from public.cold_storage_readings r
        join public.cold_storage_equipment e on e.submission_id = r.submission_id
          and e.equipment_id = r.equipment_id
        where r.submission_id = s.id
          and r.submitted_at is not null
      ), '[]'::jsonb),
      'issues', coalesce((
        select pg_catalog.jsonb_agg(issue.row_data order by issue.sort_slot, issue.equipment_id)
        from (
          select i.slot sort_slot, i.equipment_id, pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
            'id', i.id,
            'equipment_id', i.equipment_id,
            'equipment_code', e.equipment_code,
            'equipment_name', coalesce(e.equipment_name, i.equipment_id),
            'slot', i.slot,
            'temperature_c', i.temperature_c,
            'title', 'Cold Storage temperature issue',
            'remark', i.corrective_action
          )) row_data
          from public.cold_storage_issues i
          left join public.cold_storage_equipment e on e.submission_id = i.submission_id
            and e.equipment_id = i.equipment_id
          where i.submission_id = s.id
        ) issue
      ), '[]'::jsonb)
    );
  end if;

  select x.* into strict s
  from public.cold_storage_submissions x
  cross join lateral (
    select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots
    from public.cold_storage_equipment e
    left join public.cold_storage_readings r on r.submission_id = e.submission_id
      and r.equipment_id = e.equipment_id
      and r.submitted_at is not null
    where e.submission_id = x.id
      and e.active
  ) submitted
  where x.organization_id = target_organization_id
    and private.cold_storage_missed_report_id(x.id) = target_report_id
    and exists (select 1 from public.cold_storage_equipment e where e.submission_id = x.id and e.active)
    and cardinality(private.cold_storage_missed_slots_for(x.branch_id, x.business_date, submitted.submitted_slots)) > 0;

  select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) into submitted_slot_array
  from public.cold_storage_equipment e
  left join public.cold_storage_readings r on r.submission_id = e.submission_id
    and r.equipment_id = e.equipment_id
    and r.submitted_at is not null
  where e.submission_id = s.id
    and e.active;
  missed_slot_array := private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted_slot_array);
  return pg_catalog.jsonb_build_object(
    'id', private.cold_storage_missed_report_id(s.id),
    'record_kind', 'derived_missing',
    'source_submission_id', s.id,
    'organization_id', s.organization_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'supervisor_team_id', s.supervisor_team_id,
    'business_date', s.business_date,
    'checklist_type', 'cold_storage',
    'definition_id', 'cold_storage_v1',
    'submitted_at', null,
    'submitted_by', null,
    'completion', 0,
    'issue_count', cardinality(missed_slot_array),
    'missed_check_count', cardinality(missed_slot_array),
    'missed_slots', to_jsonb(missed_slot_array),
    'status', 'not_checked',
    'submitted_slots', to_jsonb(submitted_slot_array),
    'items', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_id', 'missed:' || slot,
        'item_text', slot || ' scheduled Chiller & Freezer check',
        'answer', 'not_checked',
        'remark', 'Scheduled temperature check was not submitted.',
        'evidence', null
      ) order by private.cold_storage_slot_order(slot), slot)
      from unnest(missed_slot_array) slot
    ), '[]'::jsonb),
    'rows', '[]'::jsonb,
    'issues', '[]'::jsonb
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
end $function$;

-- Capacity alignment: 100 max equipment * 48 max daily slots = 4800 max readings
create or replace function private.validate_cold_storage_readings(equipment jsonb, readings jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare row_value jsonb;
begin
  if pg_catalog.jsonb_typeof(readings) <> 'array' or pg_catalog.jsonb_array_length(readings) > 4800 then
    raise exception 'invalid cold storage readings' using errcode = '22023';
  end if;
  if (select count(*) <> count(distinct ((value ->> 'equipment_id') || '|' || (value ->> 'slot')))
      from pg_catalog.jsonb_array_elements(readings)) then
    raise exception 'duplicate cold storage reading' using errcode = '22023';
  end if;
  for row_value in select value from pg_catalog.jsonb_array_elements(readings) loop
    if not (row_value ? 'equipment_id' and row_value ? 'slot' and row_value ? 'status')
      or pg_catalog.jsonb_typeof(row_value -> 'equipment_id') <> 'string'
      or not exists (select 1 from pg_catalog.jsonb_array_elements(equipment) eq
        where pg_catalog.btrim(eq ->> 'equipment_id') = pg_catalog.btrim(row_value ->> 'equipment_id'))
      or not (row_value ->> 'slot' in ('3:00','8:00')
        or row_value ->> 'slot' ~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')
      or row_value ->> 'status' not in ('pending','pass','fail')
      or pg_catalog.length(coalesce(row_value ->> 'corrective_action','')) > 2000
    then raise exception 'invalid cold storage reading row' using errcode = '22023'; end if;
    perform private.cold_storage_numeric_field(row_value, 'temperature_c');
  end loop;
end $function$;
revoke all on function private.validate_cold_storage_readings(jsonb,jsonb) from public, anon, authenticated;
revoke all on function private.cold_storage_master_first_eligible_slot(uuid, timestamp with time zone) from public, anon, authenticated;

-- Ensure slot CHECK constraints accept any canonical HH:MM slot plus legacy 3:00 / 8:00 aliases
alter table public.cold_storage_readings
  drop constraint if exists cold_storage_readings_slot_check;
alter table public.cold_storage_readings
  add constraint cold_storage_readings_slot_check
  check (slot in ('3:00', '8:00') or slot ~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$');

alter table public.cold_storage_issues
  drop constraint if exists cold_storage_issues_slot_check;
alter table public.cold_storage_issues
  add constraint cold_storage_issues_slot_check
  check (slot in ('3:00', '8:00') or slot ~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$');

alter table public.cold_storage_submission_idempotency
  drop constraint if exists cold_storage_submission_idempotency_slot_check;
alter table public.cold_storage_submission_idempotency
  add constraint cold_storage_submission_idempotency_slot_check
  check (slot in ('3:00', '8:00') or slot ~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$');

commit;
