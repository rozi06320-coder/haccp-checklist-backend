begin;
select plan(24);

-- 1. Apply the updated function definition directly in transaction
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

-- 2. Schema, ownership, and privilege tests
select has_function(
  'private',
  'cold_storage_managed_missed_issue_rows_at',
  array['uuid', 'timestamp with time zone'],
  'private.cold_storage_managed_missed_issue_rows_at exists with correct signature'
);

select is(
  (select prosecdef from pg_proc where oid = 'private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)'::regprocedure),
  true,
  'function is SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where oid = 'private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)'::regprocedure),
  array['search_path=""']::text[],
  'function has safe empty search_path'
);

select is(
  has_function_privilege('public', 'private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)', 'execute'),
  false,
  'public cannot execute private helper'
);

select is(
  has_function_privilege('anon', 'private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)', 'execute'),
  false,
  'anon cannot execute private helper'
);

select is(
  has_function_privilege('authenticated', 'private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)', 'execute'),
  false,
  'authenticated cannot execute private helper'
);

select is(
  has_function_privilege('service_role', 'private.cold_storage_managed_missed_issue_rows_at(uuid, timestamptz)', 'execute'),
  true,
  'service_role can execute private helper'
);

-- 3. Fixtures for functional testing
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values (
  '00000000-0000-0000-0000-000000000000',
  '1c000000-0000-4000-8000-000000000001',
  'authenticated','authenticated','cs-test-supervisor@example.invalid','{}','{}',now(),now()
);

update public.profiles
set full_name='CS Supervisor', must_change_password=false
where id='1c000000-0000-4000-8000-000000000001';

insert into public.organizations(id,name,slug) values
  ('2c000000-0000-4000-8000-000000000001','Cold Storage Org A','cold-storage-org-a'),
  ('2c000000-0000-4000-8000-000000000002','Cold Storage Org B','cold-storage-org-b');

insert into public.branches(id,organization_id,name,code,timezone,created_at,active) values
  ('3c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','Branch Alpha','ALF','Asia/Riyadh','2026-09-01 00:00:00+00',true),
  ('3c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000002','Branch Beta','BET','Asia/Riyadh','2026-09-01 00:00:00+00',true);

-- Insert a submission for Branch Alpha on 2026-10-24
insert into public.cold_storage_submissions(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,
  branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot
) values (
  '9c000000-0000-4000-8000-000000000001',
  '2c000000-0000-4000-8000-000000000001',
  '3c000000-0000-4000-8000-000000000001',
  '1c000000-0000-4000-8000-000000000001',
  null,
  '2026-10-24',
  'draft',
  'Branch Alpha',
  'CS Supervisor',
  'Default Team'
);

-- Insert 3 active equipment items
insert into public.cold_storage_equipment(submission_id,equipment_id,equipment_name,equipment_type,active)
values
  ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000001','Chiller 1','refrigerator',true),
  ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000002','Chiller 2','refrigerator',true),
  ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000003','Freezer 1','freezer',true);

-- Test Case A: No readings submitted -> All 3 slots ('12:00', '20:00', '02:00') are missed
select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00')),
  3::bigint,
  'zero readings submitted generates exactly 3 missed slot issues'
);

-- Test Case B: Slot 12:00 has only 1 reading out of 3 active equipment submitted
insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000001','12:00',3,'pass','2026-10-24 13:00:00+00');

-- Under the old logic, 12:00 would falsely be treated as complete. Under the fix, 12:00 MUST still be reported as missed!
select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '12:00'),
  1::bigint,
  'incomplete slot (1 of 3 equipment submitted) is reported as missed scheduled check'
);

select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00')),
  3::bigint,
  'all 3 slots remain missed when slot 12:00 is only partially submitted'
);

-- Test Case C: 2 out of 3 active equipment submitted (eq-1 and eq-2 submitted, eq-3 missing)
insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000002','12:00',2,'pass','2026-10-24 13:10:00+00');

select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '12:00'),
  1::bigint,
  'partial slot (2 of 3 equipment submitted) remains missed until all 3 are submitted'
);

-- Test Case D: Full completion of slot 12:00 by submitting reading for eq-3
insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000003','12:00',-18,'pass','2026-10-24 13:15:00+00');

-- Now distinct equipment with submitted_at is not null is 3, matching active_count = 3. Slot 12:00 is complete!
select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '12:00'),
  0::bigint,
  'fully submitted slot (3 of 3 equipment submitted) is not reported as missed'
);

select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00')),
  2::bigint,
  'only unsubmitted slots (20:00, 02:00) remain missed'
);

-- Test Case E: Inactive equipment item does not increase threshold
-- Add a 4th equipment item marked active = false
insert into public.cold_storage_equipment(submission_id,equipment_id,equipment_name,equipment_type,active)
values ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000004','Decommissioned Unit','refrigerator',false);

-- Slot 12:00 still has all active equipment (eq-1, eq-2, eq-3) submitted. It should still be complete!
select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '12:00'),
  0::bigint,
  'inactive equipment does not increase active threshold or invalidate completed slot'
);

-- Test Case F: Unsubmitted draft reading (submitted_at is null) does not count towards threshold
-- For slot 20:00, insert draft readings with submitted_at = null for eq-1, eq-2, eq-3
insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values
  ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000001','20:00',3,'pass',null),
  ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000002','20:00',2,'pass',null),
  ('9c000000-0000-4000-8000-000000000001','4c000000-0000-4000-8000-000000000003','20:00',-19,'pass',null);

select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '20:00'),
  1::bigint,
  'unsubmitted draft readings (submitted_at is null) do not satisfy slot completion'
);

-- Test Case G: Issue ID stability and cardinality
-- Exactly one issue row per missed slot, with deterministic ID matching private.cold_storage_missed_issue_id
select is(
  (select id from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '20:00'),
  private.cold_storage_missed_issue_id('9c000000-0000-4000-8000-000000000001'::uuid, '20:00'),
  'missed issue ID matches deterministic private.cold_storage_missed_issue_id'
);

select is(
  (select report_id from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '20:00'),
  '9c000000-0000-4000-8000-000000000001'::uuid,
  'report_id links directly to existing submission'
);

select is(
  (select title from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001', '2026-10-25 01:00:00+00') where slot = '20:00'),
  'Chiller & Freezer missed scheduled check - 20:00',
  'title follows canonical format'
);

-- Test Case H: Cross-organization tenant isolation
select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000002', '2026-10-25 01:00:00+00') where branch_id = '3c000000-0000-4000-8000-000000000001'),
  0::bigint,
  'cross-tenant query returns 0 rows for other org branch'
);

-- Test Case I: Missing submission entirely produces management_missed_issue_id
select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000002', '2026-10-25 01:00:00+00') where branch_id = '3c000000-0000-4000-8000-000000000002'),
  3::bigint,
  'branch with no submission generates 3 missed slot issues'
);

select is(
  (select id from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000002', '2026-10-25 01:00:00+00') where branch_id = '3c000000-0000-4000-8000-000000000002' and slot = '12:00'),
  private.management_missed_issue_id('cold_storage:missed:3c000000-0000-4000-8000-000000000002:2026-10-24:12:00'),
  'missing submission issue ID matches canonical synthetic issue ID'
);

-- 4. Public Manager RPC integration check (caller regression)
select is(
  (select count(*) from private.cold_storage_managed_missed_issue_rows('2c000000-0000-4000-8000-000000000001'::uuid)),
  (select count(*) from private.cold_storage_managed_missed_issue_rows_at('2c000000-0000-4000-8000-000000000001'::uuid, pg_catalog.statement_timestamp())),
  'wrapper function private.cold_storage_managed_missed_issue_rows delegates directly to _at helper'
);

select is(
  has_function_privilege('public', 'private.cold_storage_managed_missed_issue_rows(uuid)', 'execute'),
  false,
  'public cannot execute private.cold_storage_managed_missed_issue_rows'
);

select is(
  has_function_privilege('service_role', 'private.cold_storage_managed_missed_issue_rows(uuid)', 'execute'),
  true,
  'service_role can execute private.cold_storage_managed_missed_issue_rows'
);

select * from finish();
rollback;
