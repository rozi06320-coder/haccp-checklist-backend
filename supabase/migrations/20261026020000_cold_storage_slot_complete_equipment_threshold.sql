begin;

-- Correct Cold Storage missed scheduled check logic for Organization Manager Dashboard.
-- Previously, submitted_slots grouped readings across all equipment using `array_agg(distinct reading.slot)`.
-- If even a single active equipment had a submitted reading for a slot, that slot was treated as complete,
-- hiding incomplete slots where one or more required equipment checks were never submitted.
--
-- With this fix, a slot is considered submitted if and only if EVERY active equipment item
-- required for that business date submission has a submitted reading (reading.submitted_at is not null):
-- `having count(distinct reading.equipment_id) >= unit.active_count and unit.active_count > 0`.
-- Exactly one Manager Issue is generated per branch/date/slot.

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
    select
      unit.branch_id,
      unit.business_date,
      unit.submission_id,
      coalesce(
        pg_catalog.array_agg(slot_completion.slot) filter (where slot_completion.slot is not null),
        array[]::text[]
      ) slots
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
grant execute on function private.cold_storage_managed_missed_issue_rows_at(uuid,timestamptz)
  to service_role;

revoke all on function private.cold_storage_managed_missed_issue_rows(uuid)
  from public, anon, authenticated;
grant execute on function private.cold_storage_managed_missed_issue_rows(uuid)
  to service_role;

commit;
