begin;

select plan(26);

-- Disposable fixture: one manager-owned organization, one foreign organization,
-- an authoritative reviewed report, and an open correction draft.
insert into public.organizations(id, name, slug, active)
values
  ('11111111-1111-4111-8111-111111111111', 'DBR RPC Test Org', 'dbr-rpc-test-org', true),
  ('33333333-3333-4333-8333-333333333333', 'DBR RPC Foreign Org', 'dbr-rpc-foreign-org', true);

insert into public.branches(id, organization_id, name, code, timezone, active)
values
  ('22222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'DBR Branch', 'DBR1', 'Asia/Riyadh', true),
  ('44444444-4444-4444-8444-444444444444', '33333333-3333-4333-8333-333333333333', 'Foreign Branch', 'FOR1', 'Asia/Riyadh', true);

insert into auth.users(id, email, aud, role)
values
  ('55555555-5555-4555-8555-555555555555', 'dbr-manager@example.invalid', 'authenticated', 'authenticated'),
  ('66666666-6666-4666-8666-666666666666', 'dbr-outsider@example.invalid', 'authenticated', 'authenticated');

insert into public.organization_memberships(organization_id, user_id, role, active)
values ('11111111-1111-4111-8111-111111111111', '55555555-5555-4555-8555-555555555555', 'organization_manager', true);

insert into public.sales_tracking_report_cases(id, organization_id, branch_id, business_date)
values ('77777777-7777-4777-8777-777777777777', '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', '2026-10-28');

insert into public.sales_tracking_reports(
  id, organization_id, branch_id, supervisor_user_id, business_date, state,
  branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot,
  case_id, version_number, currency_code, submitted_at,
  review_status, reviewed_at, reviewed_by_user_id
)
values (
  '88888888-8888-4888-8888-888888888888', '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555',
  '2026-10-28', 'submitted', 'DBR Branch', 'Manager', 'Team',
  '77777777-7777-4777-8777-777777777777', 1, 'SAR', '2026-10-28 05:00:00+00',
  'needs_review', '2026-10-28 06:00:00+00', '55555555-5555-4555-8555-555555555555'
);

insert into public.sales_tracking_reports(
  id, organization_id, branch_id, supervisor_user_id, business_date, state,
  branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot,
  case_id, version_number, currency_code, supersedes_report_id,
  correction_created_by_user_id, correction_created_at
)
values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222', '55555555-5555-4555-8555-555555555555',
  '2026-10-28', 'draft', 'DBR Branch', 'Manager', 'Team',
  '77777777-7777-4777-8777-777777777777', 2, 'SAR',
  '88888888-8888-4888-8888-888888888888',
  '55555555-5555-4555-8555-555555555555', '2026-10-28 07:00:00+00'
);

update public.sales_tracking_report_cases
set authoritative_report_id = '88888888-8888-4888-8888-888888888888',
    open_correction_report_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
where id = '77777777-7777-4777-8777-777777777777';

insert into private.daily_business_report_generation_jobs(
  id, organization_id, business_date, due_at, next_attempt_at, state,
  attempt_count, max_attempts, source_watermark, lease_token, leased_by, lease_expires_at
)
values (
  '99999999-9999-4999-8999-999999999999', '11111111-1111-4111-8111-111111111111',
  '2026-10-28', now(), now(), 'running', 1, 8, 'fixture-watermark',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  '55555555-5555-4555-8555-555555555555', now() + interval '10 minutes'
);

-- ACL and SECURITY DEFINER hardening.
select is(has_table_privilege('service_role', 'public.sales_tracking_report_cases', 'SELECT'), false, 'service_role direct table SELECT denied');
select is(has_table_privilege('anon', 'public.sales_tracking_report_cases', 'SELECT'), false, 'anon direct table SELECT denied');
select is(has_table_privilege('authenticated', 'public.sales_tracking_report_cases', 'SELECT'), false, 'authenticated direct table SELECT denied');
select is(has_function_privilege('service_role', 'public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)', 'EXECUTE'), true, 'service_role RPC EXECUTE allowed');
select is(has_function_privilege('anon', 'public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)', 'EXECUTE'), false, 'anon RPC EXECUTE denied');
select is(has_function_privilege('authenticated', 'public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)', 'EXECUTE'), false, 'authenticated RPC EXECUTE denied');
select is((select proacl from pg_proc where oid = 'public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)'::regprocedure)::text !~ 'PUBLIC=X', true, 'PUBLIC RPC EXECUTE denied');
select is((select prosecdef from pg_proc where oid = 'public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)'::regprocedure), true, 'RPC is SECURITY DEFINER');
select is((select proconfig @> array['search_path=""']::text[] from pg_proc where oid = 'public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)'::regprocedure), true, 'RPC has empty search_path');
select is(has_table_privilege(pg_get_userbyid((select proowner from pg_proc where oid = 'public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)'::regprocedure)), 'public.sales_tracking_report_cases', 'SELECT'), true, 'RPC owner can read protected cases');

set role service_role;

select is((select count(*)::integer from public.get_daily_business_report_sales_cases(
  '55555555-5555-4555-8555-555555555555', '11111111-1111-4111-8111-111111111111',
  '2026-10-28', array['22222222-2222-4222-8222-222222222222'::uuid]
)), 1, 'authorized Organization Manager can read cases');
select is((select authoritative_report_id from public.get_daily_business_report_sales_cases(
  '55555555-5555-4555-8555-555555555555', '11111111-1111-4111-8111-111111111111',
  '2026-10-28', array['22222222-2222-4222-8222-222222222222'::uuid]
)), '88888888-8888-4888-8888-888888888888'::uuid, 'authoritative report linkage is returned');
select is((select report_state from public.get_daily_business_report_sales_cases(
  '55555555-5555-4555-8555-555555555555', '11111111-1111-4111-8111-111111111111',
  '2026-10-28', array['22222222-2222-4222-8222-222222222222'::uuid]
)), 'submitted', 'only submitted authoritative report is returned');
select is((select count(*)::integer from public.get_daily_business_report_sales_cases(
  null, '11111111-1111-4111-8111-111111111111', '2026-10-28',
  array['22222222-2222-4222-8222-222222222222'::uuid],
  '99999999-9999-4999-8999-999999999999', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
)), 1, 'valid generation lease can read cases');

select throws_ok($$select * from public.get_daily_business_report_sales_cases('66666666-6666-4666-8666-666666666666','11111111-1111-4111-8111-111111111111','2026-10-28',array['22222222-2222-4222-8222-222222222222'::uuid])$$, '42501', 'daily business report sales cases access denied', 'unauthorized actor denied');
select throws_ok($$select * from public.get_daily_business_report_sales_cases('55555555-5555-4555-8555-555555555555','11111111-1111-4111-8111-111111111111','2026-10-28',array['44444444-4444-4444-8444-444444444444'::uuid])$$, '42501', 'daily business report sales cases branch scope denied', 'cross-organization branch denied');
select throws_ok($$select * from public.get_daily_business_report_sales_cases('55555555-5555-4555-8555-555555555555','11111111-1111-4111-8111-111111111111','2026-10-28',null)$$, '42501', 'daily business report sales cases access denied', 'null branch scope denied');
select throws_ok($$select * from public.get_daily_business_report_sales_cases('55555555-5555-4555-8555-555555555555','11111111-1111-4111-8111-111111111111','2026-10-28',array[]::uuid[])$$, '42501', 'daily business report sales cases access denied', 'empty branch scope denied');
select throws_ok($$select * from public.get_daily_business_report_sales_cases('55555555-5555-4555-8555-555555555555','11111111-1111-4111-8111-111111111111',null,array['22222222-2222-4222-8222-222222222222'::uuid])$$, '42501', 'daily business report sales cases access denied', 'null business date denied');
select throws_ok($$select * from public.get_daily_business_report_sales_cases(null,'11111111-1111-4111-8111-111111111111','2026-10-28',array['22222222-2222-4222-8222-222222222222'::uuid],'99999999-9999-4999-8999-999999999999','cccccccc-cccc-4ccc-8ccc-cccccccccccc')$$, '42501', 'daily business report sales cases access denied', 'forged lease denied');

reset role;
update private.daily_business_report_generation_jobs
set lease_token = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
where id = '99999999-9999-4999-8999-999999999999';
set role service_role;
select throws_ok($$select * from public.get_daily_business_report_sales_cases(null,'11111111-1111-4111-8111-111111111111','2026-10-28',array['22222222-2222-4222-8222-222222222222'::uuid],'99999999-9999-4999-8999-999999999999','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$$, '42501', 'daily business report sales cases access denied', 'replaced lease denied');
reset role;
update private.daily_business_report_generation_jobs
set lease_token = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', lease_expires_at = now() - interval '1 second'
where id = '99999999-9999-4999-8999-999999999999';
set role service_role;
select throws_ok($$select * from public.get_daily_business_report_sales_cases(null,'11111111-1111-4111-8111-111111111111','2026-10-28',array['22222222-2222-4222-8222-222222222222'::uuid],'99999999-9999-4999-8999-999999999999','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$$, '42501', 'daily business report sales cases access denied', 'expired lease denied');
select throws_ok($$select * from public.get_daily_business_report_sales_cases(null,'11111111-1111-4111-8111-111111111111','2026-10-27',array['22222222-2222-4222-8222-222222222222'::uuid],'99999999-9999-4999-8999-999999999999','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$$, '42501', 'daily business report sales cases access denied', 'wrong-date lease denied');

reset role;
select is((select review_status from public.sales_tracking_reports where id = '88888888-8888-4888-8888-888888888888'), 'needs_review', 'Need Review status unchanged');
select is((select authoritative_report_id from public.sales_tracking_report_cases where id = '77777777-7777-4777-8777-777777777777'), '88888888-8888-4888-8888-888888888888'::uuid, 'authoritative report selection unchanged');
select is((select open_correction_report_id from public.sales_tracking_report_cases where id = '77777777-7777-4777-8777-777777777777'), 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid, 'correction linkage unchanged');

select * from finish();
rollback;
