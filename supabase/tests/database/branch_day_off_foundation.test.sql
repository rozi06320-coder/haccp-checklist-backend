begin;
select plan(48);

-- 1-6: Tables and RLS
select has_table('public', 'branch_weekly_day_off_schedules', 'branch_weekly_day_off_schedules exists');
select has_table('public', 'branch_closures', 'branch_closures exists');
select is((select relrowsecurity from pg_class where oid = 'public.branch_weekly_day_off_schedules'::regclass), true, 'RLS enabled on branch_weekly_day_off_schedules');
select is((select relrowsecurity from pg_class where oid = 'public.branch_closures'::regclass), true, 'RLS enabled on branch_closures');
select is(has_table_privilege('anon', 'public.branch_weekly_day_off_schedules', 'select'), false, 'anon cannot select weekly schedules');
select is(has_table_privilege('authenticated', 'public.branch_closures', 'insert'), false, 'authenticated cannot insert closures');

-- 7-14: Function privileges and empty search_path
select is(has_function_privilege('anon', 'public.get_internal_admin_branch_day_off_config(uuid,uuid,uuid)', 'execute'), false, 'anon cannot execute get_internal_admin_branch_day_off_config');
select is(has_function_privilege('authenticated', 'public.get_internal_admin_branch_day_off_config(uuid,uuid,uuid)', 'execute'), false, 'authenticated cannot execute get_internal_admin_branch_day_off_config');
select is(has_function_privilege('service_role', 'public.get_internal_admin_branch_day_off_config(uuid,uuid,uuid)', 'execute'), true, 'service_role can execute get_internal_admin_branch_day_off_config');
select is(has_function_privilege('service_role', 'public.set_internal_admin_branch_weekly_day_off(uuid,uuid,uuid,smallint[],date,text)', 'execute'), true, 'service_role can execute set_internal_admin_branch_weekly_day_off');
select is(has_function_privilege('service_role', 'public.create_internal_admin_branch_closure(uuid,uuid,uuid,date,date,text)', 'execute'), true, 'service_role can execute create_internal_admin_branch_closure');
select is(has_function_privilege('service_role', 'public.reopen_internal_admin_branch_closure(uuid,uuid,uuid,uuid,date)', 'execute'), true, 'service_role can execute reopen_internal_admin_branch_closure');
select is(
  (
    select count(*)::integer
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('private', 'is_branch_day_off'),
      ('private', 'branch_day_off_reason'),
      ('public', 'get_internal_admin_branch_day_off_config'),
      ('public', 'set_internal_admin_branch_weekly_day_off'),
      ('public', 'create_internal_admin_branch_closure'),
      ('public', 'reopen_internal_admin_branch_closure')
    )
    and array_to_string(p.proconfig, ',') not like '%search_path=%'
  ),
  0,
  'all foundation functions enforce empty search_path'
);
select ok(exists(select 1 from pg_constraint where conname = 'account_management_audit_logs_action_check'), 'account_management_audit_logs_action_check preserved');

-- 15-18: 04:00 branch-local business date cutoff across Asia/Riyadh, Asia/Dubai, UTC
select is(
  private.phase4a_business_date_at('Asia/Riyadh', timestamptz '2026-11-27 00:59:59+00'),
  date '2026-11-26',
  'Asia/Riyadh 03:59:59 local maps to previous business date'
);
select is(
  private.phase4a_business_date_at('Asia/Riyadh', timestamptz '2026-11-27 01:00:00+00'),
  date '2026-11-27',
  'Asia/Riyadh 04:00:00 local maps to current business date'
);
select is(
  private.phase4a_business_date_at('Asia/Dubai', timestamptz '2026-11-26 23:59:59+00'),
  date '2026-11-26',
  'Asia/Dubai 03:59:59 local maps to previous business date'
);
select is(
  private.phase4a_business_date_at('UTC', timestamptz '2026-11-27 04:00:00+00'),
  date '2026-11-27',
  'UTC 04:00:00 maps to current business date'
);

-- Seed isolated test org, actor, and 2 branches
do $$
declare
  v_actor uuid := '91000000-0000-4000-8000-000000000001';
  v_non_admin uuid := '91000000-0000-4000-8000-000000000002';
  v_org_a uuid := '92000000-0000-4000-8000-000000000001';
  v_org_b uuid := '92000000-0000-4000-8000-000000000002';
  v_branch_a uuid := '93000000-0000-4000-8000-000000000001';
  v_branch_b uuid := '93000000-0000-4000-8000-000000000002';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (v_actor, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'foundation-admin@example.com', 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
    (v_non_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'foundation-other@example.com', 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now())
  on conflict (id) do nothing;

  insert into public.internal_admin_memberships (user_id, active)
  values (v_actor, true)
  on conflict (user_id) do update set active = true;

  insert into public.organizations (id, name, slug, active)
  values
    (v_org_a, 'Foundation Org A', 'foundation-org-a', true),
    (v_org_b, 'Foundation Org B', 'foundation-org-b', true)
  on conflict (id) do nothing;

  insert into public.organization_memberships (organization_id, user_id, role, active)
  values (v_org_a, v_non_admin, 'organization_manager', true)
  on conflict (organization_id, user_id) do nothing;

  insert into public.branches (id, organization_id, name, code, timezone, country_code, active)
  values
    (v_branch_a, v_org_a, 'Foundation Branch A', 'FND-A', 'Asia/Riyadh', 'SA', true),
    (v_branch_b, v_org_a, 'Foundation Branch B', 'FND-B', 'Asia/Dubai', 'AE', true)
  on conflict (id) do nothing;
end;
$$;

set local role service_role;

-- 19-21: Error handling (42501, P0002, 22023)
select throws_ok(
  $$select public.get_internal_admin_branch_day_off_config('91000000-0000-4000-8000-000000000002'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid)$$,
  '42501',
  null,
  'non-internal-admin rejected with 42501'
);

select throws_ok(
  $$select public.get_internal_admin_branch_day_off_config('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000002'::uuid, '93000000-0000-4000-8000-000000000001'::uuid)$$,
  'P0002',
  null,
  'cross-organization branch lookup rejected with P0002'
);

select throws_ok(
  $$select public.set_internal_admin_branch_weekly_day_off('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid, array[7]::smallint[], date '2026-11-20', 'invalid day')$$,
  '22023',
  null,
  'weekday outside 0..6 rejected with 22023'
);

-- 22-30: Weekly schedule effective-date transitions & per-branch isolation
select is(
  (public.set_internal_admin_branch_weekly_day_off('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid, array[5]::smallint[], date '2026-11-01', 'Friday off') ->> 'effective_from_business_date'),
  '2026-11-01',
  'initial weekly schedule created from 2026-11-01'
);

select is(
  (public.set_internal_admin_branch_weekly_day_off('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid, array[6]::smallint[], date '2026-11-15', 'Saturday off') ->> 'effective_from_business_date'),
  '2026-11-15',
  'subsequent weekly schedule effective from 2026-11-15'
);

select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-11-06'), true, 'historical Friday 2026-11-06 uses first schedule');
select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-11-07'), false, 'historical Saturday 2026-11-07 was on duty');
select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-11-20'), false, 'Friday 2026-11-20 after transition is on duty');
select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-11-21'), true, 'Saturday 2026-11-21 after transition is Day Off');
select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000002'::uuid, date '2026-11-21'), false, 'Branch B remains On Duty (per-branch isolation)');
select is(private.branch_day_off_reason('93000000-0000-4000-8000-000000000001'::uuid, date '2026-11-21'), 'Saturday off', 'branch_day_off_reason returns weekly reason');
reset role;
select is((select active from public.branches where id = '93000000-0000-4000-8000-000000000001'::uuid), true, 'Branch A remains active=true');
set local role service_role;

-- 31-42: Specific closures, 23505 overlap rejection, early reopen, and cancellation
select ok(
  (public.create_internal_admin_branch_closure('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid, date '2026-12-01', date '2026-12-05', 'Renovation') ->> 'id') is not null,
  'closure created for 2026-12-01..2026-12-05'
);

select throws_ok(
  $$select public.create_internal_admin_branch_closure('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid, date '2026-12-03', date '2026-12-07', 'Overlap')$$,
  '23505',
  null,
  'overlapping closure rejected with 23505'
);

select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-12-03'), true, '2026-12-03 is Day Off during closure');
select is(private.branch_day_off_reason('93000000-0000-4000-8000-000000000001'::uuid, date '2026-12-03'), 'Renovation', 'closure reason returned during closure');

-- Early reopen from 2026-12-04
reset role;
select is(
  (
    select (public.reopen_internal_admin_branch_closure(
      '91000000-0000-4000-8000-000000000001'::uuid,
      '92000000-0000-4000-8000-000000000001'::uuid,
      '93000000-0000-4000-8000-000000000001'::uuid,
      id,
      date '2026-12-04'
    ) ->> 'end_business_date')
    from public.branch_closures
    where branch_id = '93000000-0000-4000-8000-000000000001'::uuid and start_business_date = date '2026-12-01'
  ),
  '2026-12-03',
  'early reopen truncates closure end_business_date to 2026-12-03'
);
set local role service_role;

select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-12-04'), false, '2026-12-04 is On Duty after early reopen');
select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-12-03'), true, '2026-12-03 remains Day Off before reopen date');

-- Full cancellation from 2026-12-01
reset role;
select is(
  (
    select (public.reopen_internal_admin_branch_closure(
      '91000000-0000-4000-8000-000000000001'::uuid,
      '92000000-0000-4000-8000-000000000001'::uuid,
      '93000000-0000-4000-8000-000000000001'::uuid,
      id,
      date '2026-12-01'
    ) ->> 'status')
    from public.branch_closures
    where branch_id = '93000000-0000-4000-8000-000000000001'::uuid and start_business_date = date '2026-12-01'
  ),
  'cancelled',
  'reopen on start_business_date cancels closure'
);
set local role service_role;

select is(private.is_branch_day_off('93000000-0000-4000-8000-000000000001'::uuid, date '2026-12-02'), false, '2026-12-02 is On Duty after closure cancellation');

-- 43-48: Config payload & audit logs
select is(
  (public.get_internal_admin_branch_day_off_config('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid) ->> 'timezone'),
  'Asia/Riyadh',
  'get_internal_admin_branch_day_off_config returns branch timezone'
);
select is(
  jsonb_array_length(public.get_internal_admin_branch_day_off_config('91000000-0000-4000-8000-000000000001'::uuid, '92000000-0000-4000-8000-000000000001'::uuid, '93000000-0000-4000-8000-000000000001'::uuid) -> 'weekly_schedule_history'),
  2,
  'weekly_schedule_history contains both schedule transitions'
);
reset role;
select ok(
  exists(select 1 from public.account_management_audit_logs where action = 'branch_weekly_day_off_configured' and branch_id = '93000000-0000-4000-8000-000000000001'::uuid),
  'audit log recorded branch_weekly_day_off_configured'
);
select ok(
  exists(select 1 from public.account_management_audit_logs where action = 'branch_closure_created' and branch_id = '93000000-0000-4000-8000-000000000001'::uuid),
  'audit log recorded branch_closure_created'
);
select ok(
  exists(select 1 from public.account_management_audit_logs where action = 'branch_closure_reopened' and branch_id = '93000000-0000-4000-8000-000000000001'::uuid),
  'audit log recorded branch_closure_reopened'
);
select ok(
  exists(select 1 from public.account_management_audit_logs where action = 'branch_closure_cancelled' and branch_id = '93000000-0000-4000-8000-000000000001'::uuid),
  'audit log recorded branch_closure_cancelled'
);
select ok(
  (select count(*) from public.branch_weekly_day_off_schedules where branch_id = '93000000-0000-4000-8000-000000000001'::uuid) = 2,
  'exactly 2 weekly schedule rows persisted in transaction'
);
select ok(
  (select count(*) from public.branch_closures where branch_id = '93000000-0000-4000-8000-000000000001'::uuid) = 1,
  'exactly 1 closure row persisted in transaction'
);
select is(
  (select active from public.branches where id = '93000000-0000-4000-8000-000000000002'::uuid),
  true,
  'Branch B remains active=true'
);

select * from finish();
rollback;
