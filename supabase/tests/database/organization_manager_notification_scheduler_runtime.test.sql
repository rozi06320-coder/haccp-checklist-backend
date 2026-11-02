begin;
select plan(31);

-- ----------------------------------------------------------------------------
-- Test Setup: Organizations, Branches, and Lifecycles
-- ----------------------------------------------------------------------------

-- Org 1: Active
insert into public.organizations(id, name, slug, active)
values ('00000001-0000-4000-8000-000000000001', 'Alpha Group', 'alpha-group', true);

-- Org 2: Active
insert into public.organizations(id, name, slug, active)
values ('00000002-0000-4000-8000-000000000002', 'Beta Group', 'beta-group', true);

-- Org 3: Inactive
insert into public.organizations(id, name, slug, active)
values ('00000003-0000-4000-8000-000000000003', 'Inactive Group', 'inactive-group', false);

-- Branch 1A: Alpha Riyadh (Active, Asia/Riyadh = UTC+3)
insert into public.branches(id, organization_id, name, code, timezone, active)
values ('00000001-0001-4000-8000-000000000001', '00000001-0000-4000-8000-000000000001', 'Alpha Riyadh', 'ARY', 'Asia/Riyadh', true);

-- Branch 1B: Alpha Closed (Inactive, Asia/Riyadh)
insert into public.branches(id, organization_id, name, code, timezone, active)
values ('00000001-0002-4000-8000-000000000002', '00000001-0000-4000-8000-000000000001', 'Alpha Inactive Branch', 'AIN', 'Asia/Riyadh', false);

-- Branch 2A: Beta London (Active, UTC)
insert into public.branches(id, organization_id, name, code, timezone, active)
values ('00000002-0001-4000-8000-000000000001', '00000002-0000-4000-8000-000000000002', 'Beta London', 'BLN', 'UTC', true);

-- Branch 3A: Inactive Org Branch
insert into public.branches(id, organization_id, name, code, timezone, active)
values ('00000003-0001-4000-8000-000000000001', '00000003-0000-4000-8000-000000000003', 'Inactive Org Branch', 'IOB', 'Asia/Riyadh', true);

-- Update auto-created daily report branch lifecycles to start from 2026-10-01
update public.daily_report_branch_lifecycle
set effective_from_business_date = '2026-10-01'
where organization_id in (
  '00000001-0000-4000-8000-000000000001',
  '00000002-0000-4000-8000-000000000002',
  '00000003-0000-4000-8000-000000000003'
);

-- ----------------------------------------------------------------------------
-- Test 1: Invalid catch-up parameters rejected
-- ----------------------------------------------------------------------------
select throws_ok(
  $$select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(0)$$,
  '22023', 'invalid catch_up_days: must be between 1 and 7',
  'catchUpDays = 0 is rejected');

select throws_ok(
  $$select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(8)$$,
  '22023', 'invalid catch_up_days: must be between 1 and 7',
  'catchUpDays = 8 is rejected');

select throws_ok(
  $$select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(null)$$,
  '22023', 'invalid catch_up_days: must be between 1 and 7',
  'catchUpDays = null is rejected');

-- ----------------------------------------------------------------------------
-- Test 2: Cutoff Boundary 1 second BEFORE 04:00 in Riyadh
-- As of 2026-11-02 00:59:59+00 (03:59:59 Asia/Riyadh)
-- For date 2026-11-01, 04:00 has NOT arrived yet.
-- ----------------------------------------------------------------------------
select ok(
  not exists (
    select 1 from public.enqueue_due_organization_manager_notification_evaluation_jobs(
      1, '2026-11-02 00:59:59+00'::timestamptz
    ) where business_date = '2026-11-01'
  ),
  '1 second before 04:00 in Riyadh: 2026-11-01 is NOT enqueued'
);

-- Clean up any 2026-10-31 jobs that were enqueued
delete from private.organization_manager_notification_evaluation_jobs;

-- ----------------------------------------------------------------------------
-- Test 3: Cutoff Boundary EXACTLY AT 04:00:00 in Riyadh
-- As of 2026-11-02 01:00:00+00 (04:00:00 Asia/Riyadh)
-- In Riyadh: 2026-11-01 cutoff has arrived!
-- In UTC: it is only 01:00:00, 2026-11-01 cutoff has NOT arrived!
-- ----------------------------------------------------------------------------
create temp table boundary_test_jobs on commit drop as
select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(
  1, '2026-11-02 01:00:00+00'::timestamptz
);

select is(
  (select count(*)::integer from boundary_test_jobs
   where branch_id = '00000001-0001-4000-8000-000000000001' and business_date = '2026-11-01'),
  3,
  'exactly at 04:00:00 Riyadh: 3 categories enqueued for Alpha Riyadh on 2026-11-01'
);

select is(
  (select count(*)::integer from boundary_test_jobs
   where branch_id = '00000002-0001-4000-8000-000000000001' and business_date = '2026-11-01'),
  0,
  'at 01:00:00 UTC: Beta London has NOT reached 04:00; 2026-11-01 is NOT enqueued (timezone isolation)'
);

-- Inactive branches and inactive org branches are excluded
select is(
  (select count(*)::integer from boundary_test_jobs
   where branch_id = '00000001-0002-4000-8000-000000000002'),
  0,
  'inactive branch Alpha Closed is excluded'
);

select is(
  (select count(*)::integer from boundary_test_jobs
   where branch_id = '00000003-0001-4000-8000-000000000001'),
  0,
  'inactive organization Inactive Group branch is excluded'
);

-- Verify the three exact categories
select set_eq(
  $$select notification_category from boundary_test_jobs where branch_id = '00000001-0001-4000-8000-000000000001'$$,
  array['sales_tracking_missing', 'maintenance_issue', 'incomplete_branch_tasks'],
  'evaluates exactly the three approved notification categories'
);

-- ----------------------------------------------------------------------------
-- Test 4: Idempotency & Duplicate Execution Prevention
-- Calling the scheduler a second time for the exact same timestamp
-- ----------------------------------------------------------------------------
create temp table duplicate_test_jobs on commit drop as
select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(
  1, '2026-11-02 01:00:00+00'::timestamptz
);

select is(
  (select count(*)::integer from duplicate_test_jobs where enqueued = true),
  0,
  'duplicate scheduler run: enqueued is false for all previously enqueued jobs'
);

select is(
  (select count(*)::integer from private.organization_manager_notification_evaluation_jobs
   where branch_id = '00000001-0001-4000-8000-000000000001' and business_date = '2026-11-01'),
  3,
  'duplicate scheduler run: total job count remains exactly 3 (no duplicate jobs)'
);

-- Clean up
delete from private.organization_manager_notification_evaluation_jobs;

-- ----------------------------------------------------------------------------
-- Test 5: Bounded Catch-Up Windows (1, 3, 7 days)
-- As of 2026-11-02 05:24:00+03 (production incident reference time)
-- ----------------------------------------------------------------------------
-- 5A: Catch-up 1 day -> evaluates 2026-11-01
create temp table catchup_1 on commit drop as
select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(
  1, '2026-11-02 05:24:00+03'::timestamptz
);
select set_eq(
  $$select distinct business_date from catchup_1 where branch_id = '00000001-0001-4000-8000-000000000001'$$,
  array['2026-11-01'::date],
  'catch_up_days = 1 evaluates only the single closed business date 2026-11-01'
);

delete from private.organization_manager_notification_evaluation_jobs;

-- 5B: Catch-up 3 days -> evaluates 2026-10-30, 2026-10-31, 2026-11-01
create temp table catchup_3 on commit drop as
select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(
  3, '2026-11-02 05:24:00+03'::timestamptz
);
select set_eq(
  $$select distinct business_date from catchup_3 where branch_id = '00000001-0001-4000-8000-000000000001'$$,
  array['2026-10-30'::date, '2026-10-31'::date, '2026-11-01'::date],
  'catch_up_days = 3 evaluates exactly 3 closed dates'
);
select is(
  (select count(*)::integer from catchup_3 where branch_id = '00000001-0001-4000-8000-000000000001'),
  9, -- 3 dates * 3 categories
  'catch_up_days = 3 enqueues exactly 9 jobs (3 dates * 3 categories)'
);

delete from private.organization_manager_notification_evaluation_jobs;

-- 5C: Catch-up 7 days -> evaluates 7 closed dates
create temp table catchup_7 on commit drop as
select * from public.enqueue_due_organization_manager_notification_evaluation_jobs(
  7, '2026-11-02 05:24:00+03'::timestamptz
);
select is(
  (select count(distinct business_date)::integer from catchup_7 where branch_id = '00000001-0001-4000-8000-000000000001'),
  7,
  'catch_up_days = 7 evaluates exactly 7 closed dates'
);

-- ----------------------------------------------------------------------------
-- Test 6: End-to-End Producer Lifecycle, Dedup & Safety
-- ----------------------------------------------------------------------------
-- Enqueue jobs for 2026-11-01 for Alpha Riyadh
delete from private.organization_manager_notification_evaluation_jobs;

do $$
begin
  perform public.enqueue_due_organization_manager_notification_evaluation_jobs(
    1, '2026-11-02 05:24:00+03'::timestamptz
  );
end
$$;

-- Set up manager profile and membership for recipient delivery
insert into auth.users(id, email)
values ('10000000-0000-4000-8000-000000000001', 'manager@alpha.example.com')
on conflict (id) do nothing;

insert into public.profiles(id, full_name, must_change_password)
values ('10000000-0000-4000-8000-000000000001', 'Manager Alpha', false)
on conflict (id) do update set must_change_password = false, disabled_at = null, full_name = 'Manager Alpha';

insert into public.organization_memberships(organization_id, user_id, role, active)
values ('00000001-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'organization_manager', true)
on conflict do nothing;

-- Configure module applicability for all active branches
delete from public.daily_report_module_applicability;

insert into public.daily_report_module_applicability(
  organization_id, branch_id, module_key, requirement_basis, effective_from_business_date, required
) select
  b.organization_id,
  b.id,
  m,
  case m
    when 'staff_hygiene' then 'eligible_operational_staff'
    when 'cold_storage' then 'eligible_cold_storage_equipment'
    when 'oil_tracking' then 'eligible_oil_tracking_fryers'
    else 'static'
  end,
  '2026-10-01'::date,
  true
from public.branches b
cross join unnest(array['kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking','sales_tracking']::text[]) m;

-- 6A: Claim incomplete_branch_tasks job and verify fail-closed retryable_unknown when equipment/fryers missing
create temp table claimed_incomplete_job on commit drop as
select * from public.claim_organization_manager_notification_evaluation_jobs(
  '99999999-9999-4999-8999-999999999991'::uuid,
  'incomplete_branch_tasks',
  1,
  120
);

select is(
  (select count(*)::integer from claimed_incomplete_job),
  1,
  'claim_organization_manager_notification_evaluation_jobs successfully claimed 1 job'
);

select is(
  (select state from private.organization_manager_notification_evaluation_jobs where id = (select job_id from claimed_incomplete_job)),
  'running',
  'claimed job transitioned to running state'
);

create temp table produced_incomplete_result on commit drop as
select * from public.produce_organization_manager_notification_evaluation_job(
  (select job_id from claimed_incomplete_job),
  (select lease_token from claimed_incomplete_job)
);

select is(
  (select result from produced_incomplete_result),
  'retryable_unknown',
  'incomplete_branch_tasks fails closed as retryable_unknown when equipment/fryer evidence is missing'
);

select is(
  (select error_code from produced_incomplete_result),
  'incomplete_source_unknown',
  'incomplete_branch_tasks reports incomplete_source_unknown error code'
);

select is(
  (select created_count from produced_incomplete_result),
  0,
  'creates 0 notifications when module source completeness is unknown'
);

-- Complete with retryable_unknown
do $$
begin
  perform public.complete_organization_manager_notification_evaluation_job(
    (select job_id from claimed_incomplete_job),
    (select lease_token from claimed_incomplete_job),
    'retryable_unknown',
    'incomplete_source_unknown'
  );
end
$$;

select is(
  (select state from private.organization_manager_notification_evaluation_jobs where id = (select job_id from claimed_incomplete_job)),
  'retry',
  'job with retryable_unknown transitioned to retry state'
);

-- 6B: Claim sales_tracking_missing job (report is missing -> creates 1 notification)
create temp table claimed_sales_job on commit drop as
select * from public.claim_organization_manager_notification_evaluation_jobs(
  '99999999-9999-4999-8999-999999999992'::uuid,
  'sales_tracking_missing',
  1,
  120
);

create temp table produced_sales_missing on commit drop as
select * from public.produce_organization_manager_notification_evaluation_job(
  (select job_id from claimed_sales_job),
  (select lease_token from claimed_sales_job)
);

select is(
  (select result from produced_sales_missing),
  'completed',
  'sales_tracking missing evaluation returned completed'
);

select is(
  (select created_count from produced_sales_missing),
  1,
  'created exactly 1 missing sales tracking notification for manager recipient'
);

-- Complete sales missing job
do $$
begin
  perform public.complete_organization_manager_notification_evaluation_job(
    (select job_id from claimed_sales_job),
    (select lease_token from claimed_sales_job),
    'completed',
    null
  );
end
$$;

select is(
  (select state from private.organization_manager_notification_evaluation_jobs where id = (select job_id from claimed_sales_job)),
  'completed',
  'sales tracking missing job completed successfully'
);

-- 6C: Verify notification record in public.organization_manager_notifications
select is(
  (select count(*)::integer from public.organization_manager_notifications
   where organization_id = '00000001-0000-4000-8000-000000000001'
     and event_type = 'sales_tracking_missing'
     and business_date = '2026-11-01'),
  1,
  'sales_tracking_missing notification recorded in public table'
);

-- 6D: Test Notification Deduplication on re-production
-- Even if an evaluation job is re-run with fresh lease, it MUST NOT duplicate notifications
update private.organization_manager_notification_evaluation_jobs
set state = 'running',
    lease_token = '22222222-2222-4222-8222-222222222222',
    leased_by = '99999999-9999-4999-8999-999999999992'::uuid,
    lease_expires_at = now() + interval '5 minutes',
    completed_at = null
where id = (select job_id from claimed_sales_job);

select is(
  (select created_count from public.produce_organization_manager_notification_evaluation_job(
    (select job_id from claimed_sales_job),
    '22222222-2222-4222-8222-222222222222'::uuid
  )),
  0,
  're-evaluating job creates 0 new notifications (idempotent ON CONFLICT occurrence_key)'
);

select is(
  (select count(*)::integer from public.organization_manager_notifications
   where organization_id = '00000001-0000-4000-8000-000000000001'
     and event_type = 'sales_tracking_missing'
     and business_date = '2026-11-01'),
  1,
  'total notification count remains exactly 1 after re-evaluation'
);

-- 6E: Web Push Independence
-- Verify that 0 rows were inserted into organization_manager_push_deliveries
select is(
  (select count(*)::integer from public.organization_manager_push_deliveries),
  0,
  'zero rows in organization_manager_push_deliveries (Web Push remains independent)'
);

-- 6F: Sales Tracking Need Review Preservation
-- Insert submitted report with report_review_status = 'needs_review' on 2026-10-31
insert into public.sales_tracking_report_cases(
  id, organization_id, branch_id, business_date
) values (
  '55555555-5555-4555-8555-555555555555',
  '00000001-0000-4000-8000-000000000001',
  '00000001-0001-4000-8000-000000000001',
  '2026-10-31'
);

insert into public.sales_tracking_reports(
  id, case_id, organization_id, branch_id, business_date, state,
  version_number,
  supervisor_user_id, branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot,
  review_status, reviewed_at, reviewed_by_user_id
) values (
  '66666666-6666-4666-8666-666666666666',
  '55555555-5555-4555-8555-555555555555',
  '00000001-0000-4000-8000-000000000001',
  '00000001-0001-4000-8000-000000000001',
  '2026-10-31',
  'submitted',
  1,
  '10000000-0000-4000-8000-000000000001',
  'Alpha Riyadh',
  'Supervisor Alpha',
  'Team Alpha',
  'needs_review',
  now(),
  '10000000-0000-4000-8000-000000000001'
);

update public.sales_tracking_report_cases
set authoritative_report_id = '66666666-6666-4666-8666-666666666666'
where id = '55555555-5555-4555-8555-555555555555';

-- Enqueue catch-up job for 2026-10-31
do $$
begin
  perform public.enqueue_due_organization_manager_notification_evaluation_jobs(
    2, '2026-11-02 05:24:00+03'::timestamptz
  );
end
$$;

-- Claim sales_tracking_missing job for 2026-10-31
create temp table sales_needs_review_job on commit drop as
select * from public.claim_organization_manager_notification_evaluation_jobs(
  '99999999-9999-4999-8999-999999999993'::uuid,
  'sales_tracking_missing',
  1,
  120
);

create temp table sales_needs_review_produced on commit drop as
select * from public.produce_organization_manager_notification_evaluation_job(
  (select job_id from sales_needs_review_job),
  (select lease_token from sales_needs_review_job)
);

select is(
  (select result from sales_needs_review_produced),
  'completed',
  'sales_tracking producer evaluation returns completed'
);

select is(
  (select created_count from sales_needs_review_produced),
  0,
  'sales_tracking with needs_review is satisfied; creates 0 missing notifications (Need Review preserved)'
);

select is(
  (select count(*)::integer from public.organization_manager_notifications
   where event_type = 'sales_tracking_missing' and business_date = '2026-10-31'),
  0,
  'zero sales_tracking_missing notifications created for submitted needs_review report'
);

select * from finish();
rollback;
