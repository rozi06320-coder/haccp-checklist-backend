begin;
select plan(12);

-- Fixtures
create temp table gate_fixtures as
select
  '11111111-aaaa-4aaa-8aaa-111111111111'::uuid as org_id,
  '11111111-bbbb-4bbb-8bbb-111111111112'::uuid as foreign_org_id,
  '22222222-aaaa-4aaa-8aaa-222222222221'::uuid as branch_1,
  '22222222-aaaa-4aaa-8aaa-222222222222'::uuid as branch_2,
  '22222222-bbbb-4bbb-8bbb-222222222223'::uuid as foreign_branch,
  '22222222-aaaa-4aaa-8aaa-222222222224'::uuid as inactive_branch,
  '33333333-aaaa-4aaa-8aaa-333333333331'::uuid as admin_user,
  '33333333-aaaa-4aaa-8aaa-333333333332'::uuid as target_user,
  '44444444-aaaa-4aaa-8aaa-444444444441'::uuid as team_primary,
  '44444444-aaaa-4aaa-8aaa-444444444442'::uuid as team_backup;

insert into public.organizations(id, name, slug, active)
select org_id, 'Gate Test Org', 'gate-test-org', true from gate_fixtures;

insert into public.organizations(id, name, slug, active)
select foreign_org_id, 'Foreign Org', 'foreign-org', true from gate_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select branch_1, org_id, 'Gate Branch 1', 'GB-01', 'Asia/Riyadh', true from gate_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select branch_2, org_id, 'Gate Branch 2', 'GB-02', 'Asia/Riyadh', true from gate_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select foreign_branch, foreign_org_id, 'Foreign Branch', 'GB-FOR', 'Asia/Riyadh', true from gate_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select inactive_branch, org_id, 'Inactive Branch', 'GB-INA', 'Asia/Riyadh', false from gate_fixtures;

insert into auth.users(id, email)
select admin_user, 'gate_admin@example.com' from gate_fixtures;
insert into auth.users(id, email)
select target_user, 'gate_target@example.com' from gate_fixtures;

insert into public.profiles(id, full_name, must_change_password)
values
  ('33333333-aaaa-4aaa-8aaa-333333333331', 'Gate Admin', false),
  ('33333333-aaaa-4aaa-8aaa-333333333332', 'Gate Target User', false)
on conflict (id) do update set
  full_name = excluded.full_name,
  must_change_password = excluded.must_change_password;

insert into public.internal_admin_memberships(user_id, active)
select admin_user, true from gate_fixtures;

-- Target User is active supervisor in branch_1
insert into public.branch_memberships(branch_id, user_id, role, active)
select branch_1, target_user, 'branch_manager', true from gate_fixtures;

-- Target User has primary team ownership on team_primary, backup on team_backup
insert into public.branch_operational_teams(id, branch_id, organization_id, name, active)
select team_primary, branch_1, org_id, 'Team Alpha', true from gate_fixtures;

insert into public.branch_operational_teams(id, branch_id, organization_id, name, active)
select team_backup, branch_1, org_id, 'Team Beta', true from gate_fixtures;

insert into public.branch_operational_team_supervisors(
  operational_team_id, supervisor_user_id, assignment_role, active, valid_from, branch_id, organization_id, created_by
)
select team_primary, target_user, 'primary', true, current_date - 10, branch_1, org_id, admin_user from gate_fixtures;

insert into public.branch_operational_team_supervisors(
  operational_team_id, supervisor_user_id, assignment_role, active, valid_from, branch_id, organization_id, created_by
)
select team_backup, target_user, 'backup', true, current_date - 10, branch_1, org_id, admin_user from gate_fixtures;

-- Test 1: Complete atomic rollback on failure (invalid branch in list)
-- When transition fails, supervisor role and teams must remain completely active
savepoint before_failed_transition;

select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid, ''%s''::uuid])',
    (select admin_user from gate_fixtures),
    (select org_id from gate_fixtures),
    (select target_user from gate_fixtures),
    (select branch_1 from gate_fixtures),
    (select foreign_branch from gate_fixtures)
  ),
  '22023',
  'one or more target branches are invalid or inactive',
  'Cross-organization branch in list fails the transition'
);

rollback to savepoint before_failed_transition;

-- Verify supervisor membership is STILL ACTIVE after rollback
select is(
  (select count(*)::integer from public.branch_memberships bm
   where bm.user_id = (select target_user from gate_fixtures)
     and bm.role = 'branch_manager'
     and bm.active),
  1,
  'Supervisor role remains active after failed transition rollback'
);

-- Verify primary and backup teams are STILL ACTIVE after rollback
select is(
  (select count(*)::integer from public.branch_operational_team_supervisors bots
   where bots.supervisor_user_id = (select target_user from gate_fixtures)
     and bots.active),
  2,
  'Primary and backup team assignments remain active after rollback'
);

-- Test 2: Inactive target branch rejection
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid])',
    (select admin_user from gate_fixtures),
    (select org_id from gate_fixtures),
    (select target_user from gate_fixtures),
    (select inactive_branch from gate_fixtures)
  ),
  '22023',
  'one or more target branches are invalid or inactive',
  'Inactive target branch is rejected'
);

-- Test 3: Wrong expected source role (user is supervisor, not training_supervisor)
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''training_supervisor'', ''supervisor'', null, array[''%s''::uuid])',
    (select admin_user from gate_fixtures),
    (select org_id from gate_fixtures),
    (select target_user from gate_fixtures),
    (select branch_1 from gate_fixtures)
  ),
  '23514',
  'transition conflict: user is not an active training supervisor',
  'Wrong expected source role is rejected'
);

-- Test 4: Successful transition from Supervisor to Training Supervisor
select results_eq(
  format(
    'select previous_role, new_role from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid, ''%s''::uuid])',
    (select admin_user from gate_fixtures),
    (select org_id from gate_fixtures),
    (select target_user from gate_fixtures),
    (select branch_1 from gate_fixtures),
    (select branch_2 from gate_fixtures)
  ),
  $$values ('supervisor'::text, 'training_supervisor'::text)$$,
  'Transition to training_supervisor succeeds'
);

-- Test 5: Historical team preservation (records preserved with valid_to set)
select is(
  (select count(*)::integer from public.branch_operational_team_supervisors bots
   where bots.supervisor_user_id = (select target_user from gate_fixtures)
     and not bots.active
     and bots.valid_to is not null),
  2,
  'Both primary and backup historical team assignments preserved with valid_to'
);

-- Test 6: Duplicate transition request rejected (cannot transition from supervisor again)
select throws_ok(
  format(
    'select * from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''supervisor'', ''training_supervisor'', null, array[''%s''::uuid, ''%s''::uuid])',
    (select admin_user from gate_fixtures),
    (select org_id from gate_fixtures),
    (select target_user from gate_fixtures),
    (select branch_1 from gate_fixtures),
    (select branch_2 from gate_fixtures)
  ),
  '23514',
  'transition conflict: user is not an active supervisor',
  'Duplicate transition request is rejected'
);

-- Test 7: Establish training session and capture credential_version
create temp table training_session_capture as
select * from public.establish_training_supervisor_session(
  (select target_user from gate_fixtures)
);

select ok(
  (select count(*) = 1 from training_session_capture where credential_version is not null),
  'Training Supervisor session established with valid credential_version'
);

-- Verify context RPC succeeds with valid credential_version
select ok(
  (select count(*) = 1 from public.get_training_supervisor_context(
    (select target_user from gate_fixtures),
    (select credential_version from training_session_capture)
  )),
  'get_training_supervisor_context succeeds with active credential_version'
);

-- Test 8: Transition back from Training Supervisor to Supervisor
select results_eq(
  format(
    'select previous_role, new_role from public.transition_internal_admin_access_role(''%s'', ''%s'', ''%s'', ''training_supervisor'', ''supervisor'', null, array[''%s''::uuid])',
    (select admin_user from gate_fixtures),
    (select org_id from gate_fixtures),
    (select target_user from gate_fixtures),
    (select branch_1 from gate_fixtures)
  ),
  $$values ('training_supervisor'::text, 'supervisor'::text)$$,
  'Transition back to supervisor succeeds'
);

-- Test 12: Training session credential-version invalidation
-- Context call with old credential_version must FAIL CLOSED
select throws_ok(
  format(
    'select * from public.get_training_supervisor_context(''%s'', ''%s'')',
    (select target_user from gate_fixtures),
    (select credential_version from training_session_capture)
  ),
  '42501',
  'training supervisor access denied',
  'Inactive training supervisor access is immediately rejected with 42501'
);

rollback;
