begin;
select plan(29);

-- Setup test fixtures
create temp table test_access_fixtures as
select
  '11111111-1111-4111-8111-111111111111'::uuid as org_id,
  '11111111-1111-4111-8111-111111111112'::uuid as other_org_id,
  '22222222-2222-4222-8222-222222222221'::uuid as branch_1,
  '22222222-2222-4222-8222-222222222222'::uuid as branch_2,
  '22222222-2222-4222-8222-222222222223'::uuid as other_org_branch,
  '22222222-2222-4222-8222-222222222224'::uuid as inactive_branch,
  '33333333-3333-4333-8333-333333333331'::uuid as admin_user,
  '33333333-3333-4333-8333-333333333332'::uuid as supervisor_user,
  '33333333-3333-4333-8333-333333333333'::uuid as training_sup_user,
  '33333333-3333-4333-8333-333333333334'::uuid as non_admin_user,
  '33333333-3333-4333-8333-333333333335'::uuid as dual_role_test_user;

insert into public.organizations(id, name, slug, active)
select org_id, 'Access Test Org', 'access-test-org', true from test_access_fixtures;

insert into public.organizations(id, name, slug, active)
select other_org_id, 'Other Test Org', 'other-test-org', true from test_access_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select branch_1, org_id, 'Branch 1', 'BR-01', 'Asia/Riyadh', true from test_access_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select branch_2, org_id, 'Branch 2', 'BR-02', 'Asia/Riyadh', true from test_access_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select other_org_branch, other_org_id, 'Other Branch', 'BR-OTH', 'Asia/Riyadh', true from test_access_fixtures;

insert into public.branches(id, organization_id, name, code, timezone, active)
select inactive_branch, org_id, 'Inactive Branch', 'BR-INACT', 'Asia/Riyadh', false from test_access_fixtures;

-- Users
insert into auth.users(id, email)
select admin_user, 'admin@example.com' from test_access_fixtures;
insert into auth.users(id, email)
select supervisor_user, 'supervisor@example.com' from test_access_fixtures;
insert into auth.users(id, email)
select training_sup_user, 'trainingsup@example.com' from test_access_fixtures;
insert into auth.users(id, email)
select non_admin_user, 'regular@example.com' from test_access_fixtures;
insert into auth.users(id, email)
select dual_role_test_user, 'dualrole@example.com' from test_access_fixtures;

insert into public.profiles(id, full_name, must_change_password)
values
  ('33333333-3333-4333-8333-333333333331', 'Internal Admin User', false),
  ('33333333-3333-4333-8333-333333333332', 'Supervisor User', false),
  ('33333333-3333-4333-8333-333333333333', 'Training Supervisor User', false),
  ('33333333-3333-4333-8333-333333333334', 'Regular User', false),
  ('33333333-3333-4333-8333-333333333335', 'Dual Role User', false)
on conflict (id) do update set
  full_name = excluded.full_name,
  must_change_password = excluded.must_change_password;

-- Internal Admin Membership
insert into public.internal_admin_memberships(user_id, active)
select admin_user, true from test_access_fixtures;

-- Branch Manager (Supervisor) Membership
insert into public.branch_memberships(branch_id, user_id, role, active)
select branch_1, supervisor_user, 'branch_manager', true from test_access_fixtures;

-- Test 1: Non-admin caller is rejected
select throws_ok(
  format('select * from public.list_internal_admin_access_assignments(''%s'', ''%s'')',
    (select non_admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures)
  ),
  '42501',
  'access assignments access denied',
  'Non-admin caller is rejected from list_internal_admin_access_assignments'
);

-- Test 2: Admin can list assignments (contains Supervisor)
select is(
  (select count(*)::integer from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures)
  )),
  1,
  'List returns 1 supervisor assignment initially'
);

-- Test 3: Grant Training Supervisor succeeds
select ok(
  (select (public.grant_internal_admin_training_supervisor(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select training_sup_user from test_access_fixtures),
    array[(select branch_1 from test_access_fixtures)]
  ))->>'success' = 'true'),
  'grant_internal_admin_training_supervisor returns success'
);

-- Test 4: List now contains both assignments
select is(
  (select count(*)::integer from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures)
  )),
  2,
  'List returns 2 total assignments (1 supervisor, 1 training supervisor)'
);

-- Test 5: Filter by access_type = 'supervisor'
select is(
  (select count(*)::integer from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    null,
    'supervisor'
  )),
  1,
  'Filter access_type = supervisor returns exactly 1'
);

-- Test 6: Filter by access_type = 'training_supervisor'
select is(
  (select count(*)::integer from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    null,
    'training_supervisor'
  )),
  1,
  'Filter access_type = training_supervisor returns exactly 1'
);

-- Test 7: Mutual exclusivity prevents active Supervisor from being granted Training Supervisor
select throws_ok(
  format('select public.grant_internal_admin_training_supervisor(''%s'', ''%s'', ''%s'', array[''%s''::uuid])',
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select supervisor_user from test_access_fixtures),
    (select branch_1 from test_access_fixtures)
  ),
  '23514',
  'account holds an active supervisor role; transition must be explicitly demoted or revoked first',
  'Mutual exclusivity prevents active Supervisor from becoming Training Supervisor'
);

-- Test 8: Mutual exclusivity prevents active Training Supervisor from being inserted as Branch Manager (Supervisor)
select throws_ok(
  format('insert into public.branch_memberships(branch_id, user_id, role, active) values (''%s'', ''%s'', ''branch_manager'', true); commit;',
    (select branch_1 from test_access_fixtures),
    (select training_sup_user from test_access_fixtures)
  ),
  '23514',
  'account cannot simultaneously hold active supervisor and training supervisor roles',
  'Mutual exclusivity trigger blocks active Training Supervisor from being inserted as branch_manager'
);

-- Test 9: Suspend Training Supervisor
select ok(
  (select (public.suspend_internal_admin_training_supervisor(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select training_sup_user from test_access_fixtures)
  ))->>'success' = 'true'),
  'suspend_internal_admin_training_supervisor returns success'
);

-- Test 10: Suspended Training Supervisor status in list is 'suspended'
select is(
  (select status from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    null,
    'training_supervisor'
  )),
  'suspended',
  'Training supervisor status is suspended'
);

-- Test 11: establish_training_supervisor_session throws 42501 for suspended user
select throws_ok(
  format('select * from public.establish_training_supervisor_session(''%s'')',
    (select training_sup_user from test_access_fixtures)
  ),
  '42501',
  'training supervisor access denied',
  'Suspended training supervisor is denied in establish_training_supervisor_session'
);

-- Test 12: Reactivate Training Supervisor
select ok(
  (select (public.reactivate_internal_admin_training_supervisor(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select training_sup_user from test_access_fixtures)
  ))->>'success' = 'true'),
  'reactivate_internal_admin_training_supervisor returns success'
);

-- Test 13: Re-activated Training Supervisor status is 'active'
select is(
  (select status from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    null,
    'training_supervisor'
  )),
  'active',
  'Training supervisor status is restored to active'
);

-- Test 14: establish_training_supervisor_session succeeds for active user
select is(
  (select count(*)::integer from public.establish_training_supervisor_session(
    (select training_sup_user from test_access_fixtures)
  )),
  1,
  'Active training supervisor establishes session successfully'
);

-- Test 15: get_training_supervisor_context throws 42501 when credential_version is null (cannot bypass by omitting)
select throws_ok(
  format('select * from public.get_training_supervisor_context(''%s'', null)',
    (select training_sup_user from test_access_fixtures)
  ),
  '42501',
  'credential version is required',
  'get_training_supervisor_context fails closed when credential_version is null'
);

-- Test 16: get_training_supervisor_context throws 42501 when caller provides forged credential_version
select throws_ok(
  format('select * from public.get_training_supervisor_context(''%s'', ''99999999-9999-4999-8999-999999999999''::uuid)',
    (select training_sup_user from test_access_fixtures)
  ),
  '42501',
  'training supervisor session has been revoked',
  'get_training_supervisor_context fails closed when caller provides forged credential_version'
);

-- Test 17: get_training_supervisor_context succeeds when providing exact active credential_version
select is(
  (select count(*)::integer from public.get_training_supervisor_context(
    (select training_sup_user from test_access_fixtures),
    (select credential_version from public.training_memberships where user_id = (select training_sup_user from test_access_fixtures))
  )),
  1,
  'get_training_supervisor_context succeeds with matching credential_version'
);

-- Test 18: Session revocation by rotated credential_version on branch reassignment
do $$
declare
  old_cred uuid;
begin
  select credential_version into old_cred
  from public.training_memberships
  where user_id = '33333333-3333-4333-8333-333333333333';

  -- Reassign branches to rotate credential_version
  perform public.reassign_internal_admin_training_supervisor(
    '33333333-3333-4333-8333-333333333331',
    '11111111-1111-4111-8111-111111111111',
    '33333333-3333-4333-8333-333333333333',
    array['22222222-2222-4222-8222-222222222222'::uuid]
  );

  -- Store old_cred in temp table for assertion
  create temp table _old_cred as select old_cred;
end;
$$;

-- Test 19: Verify old credential version fails closed after branch reassignment
select throws_ok(
  format('select * from public.get_training_supervisor_context(''%s'', ''%s'')',
    (select training_sup_user from test_access_fixtures),
    (select old_cred from _old_cred)
  ),
  '42501',
  'training supervisor session has been revoked',
  'Calling get_training_supervisor_context with rotated credential_version fails closed'
);

-- Test 20: Reassignment updated branch to Branch 2
select is(
  (select branch_name from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    null,
    'training_supervisor'
  )),
  'Branch 2',
  'Branch reassignment changed assigned branch to Branch 2'
);

-- Test 21: Revoke Training Supervisor
select ok(
  (select (public.revoke_internal_admin_training_supervisor(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select training_sup_user from test_access_fixtures)
  ))->>'success' = 'true'),
  'revoke_internal_admin_training_supervisor returns success'
);

-- Test 22: Revoked status is 'suspended' / unassigned
select is(
  (select status from public.list_internal_admin_access_assignments(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    null,
    'training_supervisor'
  )),
  'suspended',
  'Revoked training supervisor status is suspended'
);

-- Test 23: Audit logs were recorded for all operations
select is(
  (select count(*)::integer from public.account_management_audit_logs
   where organization_id = (select org_id from test_access_fixtures)
     and action in (
       'training_supervisor_granted',
       'training_supervisor_suspended',
       'training_supervisor_reactivated',
       'training_supervisor_reassigned',
       'training_supervisor_revoked'
     )),
  5,
  'Recorded exactly 5 audit log entries for the training supervisor operations'
);

-- Test 24: Training Supervisor does NOT have operational branch_manager role
select is(
  (select count(*)::integer from public.branch_memberships
   where user_id = (select training_sup_user from test_access_fixtures)
     and role = 'branch_manager'),
  0,
  'Training supervisor was never granted operational branch_manager role'
);

-- Test 25: Reject cross-organization branch in grant_internal_admin_training_supervisor
select throws_ok(
  format('select public.grant_internal_admin_training_supervisor(''%s'', ''%s'', ''%s'', array[''%s''::uuid])',
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select non_admin_user from test_access_fixtures),
    (select other_org_branch from test_access_fixtures)
  ),
  '22023',
  'one or more target branches are invalid or inactive',
  'Foreign branch from other organization is rejected with 22023'
);

-- Test 26: Reject inactive branch in grant_internal_admin_training_supervisor
select throws_ok(
  format('select public.grant_internal_admin_training_supervisor(''%s'', ''%s'', ''%s'', array[''%s''::uuid])',
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select non_admin_user from test_access_fixtures),
    (select inactive_branch from test_access_fixtures)
  ),
  '22023',
  'one or more target branches are invalid or inactive',
  'Inactive branch is rejected with 22023'
);

-- Test 27: Re-granting on revoked training supervisor succeeds and restores active
select ok(
  (select (public.grant_internal_admin_training_supervisor(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select training_sup_user from test_access_fixtures),
    array[(select branch_1 from test_access_fixtures)]
  ))->>'success' = 'true'),
  'Re-granting training supervisor on revoked account restores active state'
);

-- Test 28: Repeated grant on active training supervisor succeeds idempotently
select ok(
  (select (public.grant_internal_admin_training_supervisor(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select training_sup_user from test_access_fixtures),
    array[(select branch_2 from test_access_fixtures)]
  ))->>'success' = 'true'),
  'Repeated grant on active training supervisor succeeds idempotently'
);

-- Test 29: Trigger blocks branch_memberships branch transfer into an organization where user is active Training Supervisor
select ok(
  (select (public.grant_internal_admin_training_supervisor(
    (select admin_user from test_access_fixtures),
    (select org_id from test_access_fixtures),
    (select dual_role_test_user from test_access_fixtures),
    array[(select branch_1 from test_access_fixtures)]
  ))->>'success' = 'true'),
  'Setup dual_role_test_user as active training supervisor'
);

-- Dual role user is now active Training Supervisor. Attempting to update an existing branch_memberships row to branch_manager must be blocked by trigger!
insert into public.branch_memberships(branch_id, user_id, role, active)
select branch_1, dual_role_test_user, 'staff', true from test_access_fixtures;

-- Test 30: Mutual exclusivity trigger blocks updating existing staff membership to branch_manager when active Training Supervisor
select throws_ok(
  format('update public.branch_memberships set role = ''branch_manager'' where user_id = ''%s'' and branch_id = ''%s''; commit;',
    (select dual_role_test_user from test_access_fixtures),
    (select branch_1 from test_access_fixtures)
  ),
  '23514',
  'account cannot simultaneously hold active supervisor and training supervisor roles',
  'Mutual exclusivity trigger blocks updating existing staff membership to branch_manager when active Training Supervisor'
);

select finish();
rollback;
