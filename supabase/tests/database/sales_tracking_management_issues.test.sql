begin;
select plan(34);

select ok(
  position('phase4a_business_date_at' in pg_get_functiondef('private.sales_tracking_managed_issue_rows_at(uuid,timestamptz)'::regprocedure)) > 0,
  'current-day sales issues use each active branch local business date'
);
select ok(
  position('daily_business_report_branch_close_at' in pg_get_functiondef('private.sales_tracking_managed_issue_rows_at(uuid,timestamptz)'::regprocedure)) > 0,
  'missing Sales Tracking is emitted only after the branch-local 04:00 close'
);
select ok(
  position('report.case_id = report_case.id' in pg_get_functiondef('private.sales_tracking_managed_issue_rows_at(uuid,timestamptz)'::regprocedure)) > 0,
  'submitted evidence requires the authoritative case pointer'
);
select ok(
  position('daily_report_module_applicability' in pg_get_functiondef('private.sales_tracking_managed_issue_rows_at(uuid,timestamptz)'::regprocedure)) > 0,
  'Sales Tracking missing status is gated by authoritative applicability'
);
select ok(
  position('daily_report_branch_lifecycle' in pg_get_functiondef('private.sales_tracking_managed_issue_rows_at(uuid,timestamptz)'::regprocedure)) > 0,
  'Sales Tracking missing status respects authoritative branch lifecycle'
);

create temp table sales_tracking_issue_tz as
select
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 3 and 23 order by name limit 1) closed_tz,
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 0 and 2 order by name limit 1) open_tz;

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-4000-8000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000001'::uuid,
  '1e000000-0000-4000-8000-000000000002',
  '1e000000-0000-4000-8000-000000000003',
  '1e000000-0000-4000-8000-000000000004',
  '1e000000-0000-4000-8000-000000000005',
  '1e000000-0000-4000-8000-000000000006'
]) id;
update public.profiles set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Variance Supervisor'
  when '1e000000-0000-4000-8000-000000000002' then 'Balanced Supervisor'
  when '1e000000-0000-4000-8000-000000000003' then 'Missing Closed Supervisor'
  when '1e000000-0000-4000-8000-000000000004' then 'Missing Open Supervisor'
  when '1e000000-0000-4000-8000-000000000005' then 'Sales Issue Manager'
  else 'Other Sales Issue Manager'
end, must_change_password = false
where id::text like '1e000000-%';

insert into public.organizations(id,name,slug) values
  ('2e000000-0000-4000-8000-000000000001','Sales Issues Org','sales-issues-org'),
  ('2e000000-0000-4000-8000-000000000002','Other Sales Issues Org','other-sales-issues-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Variance Branch','VAR',(select closed_tz from sales_tracking_issue_tz)),
  ('3e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','Balanced Branch','BAL',(select closed_tz from sales_tracking_issue_tz)),
  ('3e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','Missing Closed Branch','MIS',(select closed_tz from sales_tracking_issue_tz)),
  ('3e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000001','Missing Open Branch','OPN',(select open_tz from sales_tracking_issue_tz));
update public.branches set created_at=now()-interval '2 days'
where organization_id='2e000000-0000-4000-8000-000000000001';

-- Test-only: make the automatically seeded Sales Tracking requirement
-- and branch lifecycle effective for the historical business dates covered by this fixture.
update public.daily_report_branch_lifecycle lifecycle
set effective_from_business_date =
  private.phase4a_business_date(branch.timezone) - 2
from public.branches branch
where lifecycle.branch_id = branch.id
  and branch.organization_id = '2e000000-0000-4000-8000-000000000001';

update public.daily_report_module_applicability applicability
set effective_from_business_date =
  private.phase4a_business_date(branch.timezone) - 2
from public.branches branch
where applicability.branch_id = branch.id
  and applicability.module_key = 'sales_tracking'
  and branch.organization_id = '2e000000-0000-4000-8000-000000000001';

insert into public.organization_memberships(organization_id,user_id,role) values
  ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000005','organization_manager'),
  ('2e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000006','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager'),
  ('3e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002','branch_manager'),
  ('3e000000-0000-4000-8000-000000000003','1e000000-0000-4000-8000-000000000003','branch_manager'),
  ('3e000000-0000-4000-8000-000000000004','1e000000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001'),
  ('4e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002'),
  ('4e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000003','1e000000-0000-4000-8000-000000000003'),
  ('4e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000004','1e000000-0000-4000-8000-000000000004');

select is(has_function_privilege('authenticated','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot execute managed sales tracking issues RPC');
select is(has_function_privilege('service_role','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),true,'service role can execute managed sales tracking issues RPC');
select is(has_function_privilege('authenticated','public.get_sales_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'authenticated cannot execute managed sales tracking issue detail RPC');

do $setup$
declare d date:=private.phase4a_business_date((select closed_tz from sales_tracking_issue_tz));
begin
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',0,'middle_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',200,'actual_credit',50,'pos_cash',175,'pos_credit',50,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',1,'closing_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',0,'actual_credit',0,'pos_cash',0,'pos_credit',0,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.submit_sales_tracking('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',2,'5e000000-0000-4000-8000-000000000001',repeat('a',64));
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000002',0,'middle_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',100,'actual_credit',50,'pos_cash',100,'pos_credit',50,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000002',1,'closing_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',0,'actual_credit',0,'pos_cash',0,'pos_credit',0,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.submit_sales_tracking('1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000002',2,'5e000000-0000-4000-8000-000000000002',repeat('b',64));
end$setup$;
select pass('variance supervisor submits mismatched two-period Sales Tracking');
select pass('balanced supervisor submits matching two-period Sales Tracking');

create temp table sales_tracking_issue_list as
select public.list_sales_tracking_managed_issues(
  '1e000000-0000-4000-8000-000000000005',
  '2e000000-0000-4000-8000-000000000001',
  1, 20, null, null, null, null, null, 'sales_tracking', null, null
) payload;

select is((select payload->>'total' from sales_tracking_issue_list),'5','manager sees one variance plus prior-day missing issues across branches');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'title' = 'Sales Tracking variance issue'),1,'variance issue appears');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'title' = 'Missing Sales Tracking submission'),4,'one prior-day missing issue appears for each branch');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'branch_name' = 'Balanced Branch'),1,'a report submitted after rollover does not satisfy the prior business date');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'branch_name' = 'Missing Open Branch'),1,'open local business date does not suppress an already closed prior-day issue');
select is(
  public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001',1,20,null,null,'3e000000-0000-4000-8000-000000000001',null,null,'sales_tracking',null,null)->>'total',
  '2',
  'branch filter limits sales tracking issues'
);
select is(
  public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001',1,20,null,null,null,'1e000000-0000-4000-8000-000000000003',null,'sales_tracking',null,null)->>'total',
  '0',
  'supervisor filter does not assign a branch-owned missing issue to one supervisor'
);
select is(
  public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'1e000000-0000-4000-8000-000000000003','sales_tracking',null,null)->>'total',
  '0',
  'affected staff filter returns no Sales Tracking issues without denying the full issue list'
);
select ok(position('Actual and POS totals do not match' in public.get_sales_tracking_managed_issue(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    (select (issue->>'id')::uuid from sales_tracking_issue_list, jsonb_array_elements(payload->'issues') issue where issue->>'title' = 'Sales Tracking variance issue')
  )->>'remark') > 0,
  'variance issue detail explains mismatch'
);
select ok(position('No fake submission was created' in public.get_sales_tracking_managed_issue(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    (select (issue->>'id')::uuid from sales_tracking_issue_list, jsonb_array_elements(payload->'issues') issue where issue->>'title' = 'Missing Sales Tracking submission' limit 1)
  )->>'remark') > 0,
  'missing issue detail explains derived issue'
);
select throws_ok($$
  select public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000006','2e000000-0000-4000-8000-000000000001')
$$, '42501', 'sales tracking issue access denied', 'other manager is denied');
select throws_ok($$
  select public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001')
$$, '42501', 'sales tracking issue access denied', 'supervisor is denied');

-- Behavioral regression: Branch deactivation retains historical issues
update public.branches set active = false where id = '3e000000-0000-4000-8000-000000000003';
update public.branches set active = false where id = '3e000000-0000-4000-8000-000000000001';

select is(
  (select count(*)::int from jsonb_array_elements(public.list_sales_tracking_managed_issues(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    1, 20, null, null, '3e000000-0000-4000-8000-000000000003', null, null, 'sales_tracking', null, null
  )->'issues') issue where issue->>'title' = 'Missing Sales Tracking submission'),
  1,
  'deactivated branch retains historical prior-day missing issue'
);

select is(
  (select count(*)::int from jsonb_array_elements(public.list_sales_tracking_managed_issues(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    1, 20, null, null, '3e000000-0000-4000-8000-000000000001', null, null, 'sales_tracking', null, null
  )->'issues') issue where issue->>'title' = 'Sales Tracking variance issue'),
  1,
  'deactivated branch retains submitted variance issue'
);

-- Behavioral regression: Branch inactive on historical business date produces NO missing issue despite being active today
insert into public.branches(id, organization_id, name, code, timezone, active, created_at) values
  ('3e000000-0000-4000-8000-000000000005', '2e000000-0000-4000-8000-000000000001', 'Historically Inactive Branch', 'HIN', (select closed_tz from sales_tracking_issue_tz), true, now() - interval '2 days');
update public.daily_report_branch_lifecycle
set active = false,
    effective_from_business_date = private.phase4a_business_date((select closed_tz from sales_tracking_issue_tz)) - 2
where branch_id = '3e000000-0000-4000-8000-000000000005';
update public.daily_report_module_applicability
set effective_from_business_date = private.phase4a_business_date((select closed_tz from sales_tracking_issue_tz)) - 2
where branch_id = '3e000000-0000-4000-8000-000000000005';

select is(
  (select count(*)::int from jsonb_array_elements(coalesce(public.list_sales_tracking_managed_issues(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    1, 20, null, null, '3e000000-0000-4000-8000-000000000005', null, null, 'sales_tracking', null, null
  )->'issues', '[]'::jsonb)) issue),
  0,
  'branch inactive on historical business date produces no missing issue despite being active today'
);

-- Behavioral regression: Branch reactivation produces missing issues only for active periods
update public.daily_report_branch_lifecycle
set effective_to_business_date = private.phase4a_business_date((select closed_tz from sales_tracking_issue_tz))
where branch_id = '3e000000-0000-4000-8000-000000000005' and effective_to_business_date is null;

insert into public.daily_report_branch_lifecycle(
  organization_id, branch_id, effective_from_business_date, effective_to_business_date, active, timezone
) values (
  '2e000000-0000-4000-8000-000000000001',
  '3e000000-0000-4000-8000-000000000005',
  private.phase4a_business_date((select closed_tz from sales_tracking_issue_tz)),
  null,
  true,
  (select closed_tz from sales_tracking_issue_tz)
);

select is(
  (select count(*)::int from jsonb_array_elements(coalesce(public.list_sales_tracking_managed_issues(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    1, 20, null, null, '3e000000-0000-4000-8000-000000000005', null, null, 'sales_tracking', null, null
  )->'issues', '[]'::jsonb)) issue),
  0,
  'reactivated branch has no missing issue while current business date remains open'
);

select is(
  (select count(*)::int from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    ((private.phase4a_business_date((select closed_tz from sales_tracking_issue_tz)) + 1)::timestamp + time '04:05') at time zone (select closed_tz from sales_tracking_issue_tz)
  ) where branch_id = '3e000000-0000-4000-8000-000000000005'),
  1,
  'reactivated branch produces missing issue only for active post-reactivation date'
);

-- Behavioral regression: Timezone changes and historical cutoff boundaries
insert into public.branches(id, organization_id, name, code, timezone, active, created_at) values
  ('3e000000-0000-4000-8000-000000000006', '2e000000-0000-4000-8000-000000000001', 'Timezone Transition Branch', 'TZT', 'Asia/Dubai', true, '2026-11-01 00:00:00+00');
delete from public.daily_report_branch_lifecycle where branch_id = '3e000000-0000-4000-8000-000000000006';
insert into public.daily_report_branch_lifecycle(
  organization_id, branch_id, effective_from_business_date, effective_to_business_date, active, timezone
) values
  ('2e000000-0000-4000-8000-000000000001', '3e000000-0000-4000-8000-000000000006', '2026-11-01', '2026-11-09', true, 'Asia/Riyadh'),
  ('2e000000-0000-4000-8000-000000000001', '3e000000-0000-4000-8000-000000000006', '2026-11-09', null, true, 'Asia/Dubai');
update public.daily_report_module_applicability
set effective_from_business_date = '2026-11-01'
where branch_id = '3e000000-0000-4000-8000-000000000006';

-- Historical date 2026-11-08 had timezone Asia/Riyadh (UTC+3), closing at 2026-11-09 01:00 UTC (04:00 Riyadh).
-- At 00:30 UTC, it is 04:30 in Dubai but only 03:30 in Riyadh; historical close has not arrived.
select is(
  (select count(*)::int from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    '2026-11-09 00:30:00+00'::timestamptz
  ) where branch_id = '3e000000-0000-4000-8000-000000000006'),
  0,
  'timezone-transitioned branch uses historical timezone: 03:30 Riyadh has not closed yet'
);

select is(
  (select count(*)::int from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    '2026-11-09 01:05:00+00'::timestamptz
  ) where branch_id = '3e000000-0000-4000-8000-000000000006'),
  1,
  'timezone-transitioned branch emits missing issue after historical 04:00 Riyadh close'
);

select is(
  (select created_at from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    '2026-11-09 01:05:00+00'::timestamptz
  ) where branch_id = '3e000000-0000-4000-8000-000000000006'),
  '2026-11-09 01:00:00+00'::timestamptz,
  'timezone-transitioned branch issue created_at matches historical 04:00 Riyadh timestamp'
);

-- Boundary tests for Riyadh and Dubai 04:00 cutoff:
select is(
  (select count(*)::int from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    '2026-11-09 00:59:59+00'::timestamptz
  ) where branch_id = '3e000000-0000-4000-8000-000000000006' and business_date = '2026-11-08'),
  0,
  'Riyadh branch at 03:59:59 local is not closed'
);

select is(
  (select count(*)::int from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    '2026-11-09 01:00:00+00'::timestamptz
  ) where branch_id = '3e000000-0000-4000-8000-000000000006' and business_date = '2026-11-08'),
  1,
  'Riyadh branch at exactly 04:00:00 local is closed'
);

select is(
  (select count(*)::int from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    '2026-11-09 23:59:59+00'::timestamptz
  ) where branch_id = '3e000000-0000-4000-8000-000000000006' and business_date = '2026-11-09'),
  0,
  'Dubai branch at 03:59:59 local is not closed'
);

select is(
  (select count(*)::int from private.sales_tracking_managed_issue_rows_at(
    '2e000000-0000-4000-8000-000000000001',
    '2026-11-10 00:00:00+00'::timestamptz
  ) where branch_id = '3e000000-0000-4000-8000-000000000006' and business_date = '2026-11-09'),
  1,
  'Dubai branch at exactly 04:00:00 local is closed'
);

select * from finish();
rollback;
