begin;
select plan(18);

-- Setup test fixtures
create temp table test_transition_fixtures as
select
  'aaaaaaaa-1111-4111-8111-111111111111'::uuid as org_id,
  'aaaaaaaa-1111-4111-8111-111111111112'::uuid as other_org_id,
  'bbbbbbbb-2222-4222-8222-222222222221'::uuid as branch_1,
  'bbbbbbbb-2222-4222-8222-222222222222'::uuid as branch_2,
  'bbbbbbbb-2222-4222-8222-222222222223'::uuid as other_org_branch,
  'bbbbbbbb-2222-4222-8222-222222222224'::uuid as inactive_branch,
  'cccccccc-3333-4333-8333-333333333331'::uuid as admin_user,
  'cccccccc-3333-4333-8333-333333333332'::uuid as non_admin_user,
  'cccccccc-3333-4333-8333-333333333333'::uuid as target_user,
  'dddddddd-4444-4444-8444-444444444441'::uuid as team_1;

insert into public.organizations(id, name, slug, active)
select org_id, 'Transition Test Org', 'transition-test-org', true from test_transition_fixtures;

insert into public.organizations(id, name, slug, active)
select other_org_id, 'Other Org', 'other-org', true from test_transition_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select branch_1, org_id, 'Branch 1', 'TR-01', 'Asia/Riyadh', true from test_transition_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select branch_2, org_id, 'Branch 2', 'TR-02', 'Asia/Riyadh', true from test_transition_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select other_org_branch, other_org_id, 'Other Branch', 'TR-OTH', 'Asia/Riyadh', true from test_transition_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select inactive_branch, org_id, 'Inactive Branch', 'TR-INACT', 'Asia/Riyadh', false from test_transition_fixtures;

insert into auth.users(id, email)
select admin_user, 'admin@example.com' from test_transition_fixtures;
insert into auth.users(id, email)
select non_admin_user, 'regular@example.com' from test_transition_fixtures;
insert into auth.users(id, email)
select target_user, 'target@example.com' from test_transition_fixtures;

insert into public.profiles(id, full_name, must_change_password)
values
  ('cccccccc-3333-4333-8333-333333333331', 'Internal Admin User', false),
  ('cccccccc-3333-4333-8333-333333333332', 'Regular User', false),
  ('cccccccc-3333-4333-8333-333333333333', 'Target User', false)
on conflict (id) do update set
  full_name = excluded.full_name,
  must_change_password = excluded.must_change_password;

-- Internal Admin Membership
insert into public.internal_admin_memberships(user_id, active)
select admin_user, true from test_transition_fixtures;

-- Target User starts as active Supervisor in Branch 1
insert into public.branch_memberships(branch_id, user_id, role, active)
select branch_1, target_user, 'branch_manager', true from test_transition_fixtures;

-- Operational team setup
insert into public.branch_operational_teams(id, branch_id, organization_id, name, active)
select team_1, branch_1, org_id, 'Morning Team', true from test_transition_fixtures;

insert into public.branch_operational_team_supervisors(
  operational_team_id,
  supervisor_user_id,
  assignment_role,
  active,
  valid_from,
  branch_id,
  organization_id,
  created_by
)
select team_1, target_user, 'primary', true, current_date - 5, branch_1, org_id, admin_user from test_transition_fixtures;

-- Test 1: Non-admin caller rejected with 42501
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid])',
    (select non_admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  '42501',
  'internal admin access denied',
  'Non-admin caller is rejected from transition RPC'
);

-- Test 2: Foreign organization rejected with 42501
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''00000000-0000-0000-0000-000000000000'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  '42501',
  'internal admin access denied',
  'Inactive or foreign organization rejected'
);

-- Test 3: Same source and target role rejected with 22023
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''supervisor'', null, array[''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  '22023',
  'invalid role transition pair',
  'Same source and destination role rejected'
);

-- Test 4: Inactive target branch rejected with 22023
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select inactive_branch from test_transition_fixtures)
  ),
  '22023',
  'one or more target branches are invalid or inactive',
  'Inactive target branch is rejected'
);

-- Test 5: Foreign branch in other organization rejected with 22023
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select other_org_branch from test_transition_fixtures)
  ),
  '22023',
  'one or more target branches are invalid or inactive',
  'Foreign branch from different organization is rejected'
);

-- Test 6: Stale source role rejected with 23514
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''training_supervisor'', ''supervisor'', null, array[''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  '23514',
  'transition conflict: user is not an active training supervisor',
  'Mismatch with current database role is rejected'
);

-- Test 7: Successful Supervisor -> Training Supervisor transition
select results_eq(
  format(
    'select previous_role, new_role from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid, ''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures),
    (select branch_2 from test_transition_fixtures)
  ),
  $$values ('supervisor'::text, 'training_supervisor'::text)$$,
  'Transition supervisor -> training_supervisor returns expected roles'
);

-- Test 8: Verify previous branch_memberships are deactivated
select is(
  (select count(*)::integer from public.branch_memberships bm
   where bm.user_id = (select target_user from test_transition_fixtures)
     and bm.role = 'branch_manager'
     and bm.active),
  0,
  'Previous supervisor branch_memberships are inactive'
);

-- Test 9: Verify previous branch_operational_team_supervisors are closed
select is(
  (select count(*)::integer from public.branch_operational_team_supervisors bots
   where bots.supervisor_user_id = (select target_user from test_transition_fixtures)
     and bots.active),
  0,
  'Previous team supervisor assignments are inactive'
);

-- Test 10: Verify public.training_memberships is active
select is(
  (select count(*)::integer from public.training_memberships tm
   where tm.user_id = (select target_user from test_transition_fixtures)
     and tm.training_role = 'training_supervisor'
     and tm.active),
  1,
  'Training membership is active'
);

-- Test 11: Verify public.training_membership_branches has both branches
select is(
  (select count(*)::integer from public.training_membership_branches tmb
   where tmb.user_id = (select target_user from test_transition_fixtures)),
  2,
  'Training membership has 2 assigned branches'
);

-- Test 12: list_internal_admin_access_assignments shows training_supervisor immediately as active
select results_eq(
  format(
    'select access_type, status from public.list_internal_admin_access_assignments(''%s'', ''%s'', ''%s'') where status = ''active''',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  $$values ('training_supervisor'::text, 'active'::text)$$,
  'List access assignments immediately reflects training_supervisor access'
);

-- Test 13: establish_training_supervisor_session succeeds
select ok(
  (select count(*) = 1 from public.establish_training_supervisor_session(
    (select target_user from test_transition_fixtures)
  )),
  'establish_training_supervisor_session succeeds for newly transitioned user'
);

-- Test 14: Stale source role rejected (now supervisor->training fails because user is training_supervisor)
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  '23514',
  'transition conflict: user is not an active supervisor',
  'Cannot transition from supervisor when user is already training_supervisor'
);

-- Test 15: Successful Training Supervisor -> Supervisor transition
select results_eq(
  format(
    'select previous_role, new_role from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''training_supervisor'', ''supervisor'', null, array[''%s''::uuid])',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select target_user from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  $$values ('training_supervisor'::text, 'supervisor'::text)$$,
  'Transition training_supervisor -> supervisor returns expected roles'
);

-- Test 16: Verify public.training_memberships is deactivated
select is(
  (select count(*)::integer from public.training_memberships tm
   where tm.user_id = (select target_user from test_transition_fixtures)
     and tm.active),
  0,
  'Training membership is now inactive'
);

-- Test 17: Verify public.training_membership_branches are removed
select is(
  (select count(*)::integer from public.training_membership_branches tmb
   where tmb.user_id = (select target_user from test_transition_fixtures)),
  0,
  'Training membership branch mappings are removed'
);

-- Test 18: list_internal_admin_access_assignments shows supervisor immediately
select results_eq(
  format(
    'select access_type, status from public.list_internal_admin_access_assignments(''%s'', ''%s'', ''%s'')',
    (select admin_user from test_transition_fixtures),
    (select org_id from test_transition_fixtures),
    (select branch_1 from test_transition_fixtures)
  ),
  $$values ('supervisor'::text, 'active'::text)$$,
  'List access assignments immediately reflects restored supervisor access'
);

rollback;
