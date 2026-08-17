begin;

select plan(38);

insert into auth.users (
  instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  ('00000000-0000-0000-0000-000000000000', '11000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'phase2c-staff-a@example.invalid', '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '11000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'phase2c-branch-manager-a@example.invalid', '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '11000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'phase2c-organization-manager-a@example.invalid', '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '11000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'phase2c-organization-manager-b@example.invalid', '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '11000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'phase2c-target@example.invalid', '{"provider":"email","providers":["email"]}', '{}', now(), now());

insert into public.organizations (id, name, slug)
values
  ('21000000-0000-4000-8000-000000000001', 'Phase 2C Organization A', 'phase-2c-organization-a'),
  ('21000000-0000-4000-8000-000000000002', 'Phase 2C Organization B', 'phase-2c-organization-b');

insert into public.branches (id, organization_id, name, code)
values
  ('31000000-0000-4000-8000-000000000001', '21000000-0000-4000-8000-000000000001', 'Phase 2C Branch A', 'P2C-A'),
  ('31000000-0000-4000-8000-000000000002', '21000000-0000-4000-8000-000000000002', 'Phase 2C Branch B', 'P2C-B');

insert into public.organization_memberships (organization_id, user_id, role)
values
  ('21000000-0000-4000-8000-000000000001', '11000000-0000-4000-8000-000000000003', 'organization_manager'),
  ('21000000-0000-4000-8000-000000000002', '11000000-0000-4000-8000-000000000004', 'organization_manager');

insert into public.branch_memberships (branch_id, user_id, role)
values
  ('31000000-0000-4000-8000-000000000001', '11000000-0000-4000-8000-000000000001', 'staff'),
  ('31000000-0000-4000-8000-000000000001', '11000000-0000-4000-8000-000000000002', 'branch_manager');

select lives_ok(
  $$
    insert into public.account_management_audit_logs (
      id, organization_id, actor_user_id, target_user_id, branch_id, action, details
    ) values
      ('41000000-0000-4000-8000-000000000001', '21000000-0000-4000-8000-000000000001', '11000000-0000-4000-8000-000000000003', '11000000-0000-4000-8000-000000000005', '31000000-0000-4000-8000-000000000001', 'user_created', '{"role":"staff","source":{"channel":"management_api"}}'),
      ('41000000-0000-4000-8000-000000000002', '21000000-0000-4000-8000-000000000002', '11000000-0000-4000-8000-000000000004', '11000000-0000-4000-8000-000000000005', '31000000-0000-4000-8000-000000000002', 'user_disabled', '{"reason":"employment ended"}')
  $$,
  'Administrative fixture accepts valid non-sensitive structured details'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, branch_id, action) values ('21000000-0000-4000-8000-000000000001', '31000000-0000-4000-8000-000000000002', 'user_created')$$,
  '23503',
  null,
  'Cross-organization branch and audit association is rejected'
);
select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action) values ('21000000-0000-4000-8000-000000000001', 'arbitrary_action')$$,
  '23514',
  null,
  'Invalid audit action is rejected'
);
select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('21000000-0000-4000-8000-000000000001', 'user_created', '{"password":"forbidden"}')$$,
  '23514', null, 'password detail key is rejected'
);
select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('21000000-0000-4000-8000-000000000001', 'user_created', '{"temporary-password":"forbidden"}')$$,
  '23514', null, 'temporary_password detail key is rejected across separators'
);
select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('21000000-0000-4000-8000-000000000001', 'user_created', '{"nested":{"ACCESS_TOKEN":"forbidden"}}')$$,
  '23514', null, 'nested access_token detail key is rejected case-insensitively'
);
select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('21000000-0000-4000-8000-000000000001', 'user_created', '{"refresh_token":"forbidden"}')$$,
  '23514', null, 'refresh_token detail key is rejected'
);
select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('21000000-0000-4000-8000-000000000001', 'user_created', '{"service_role":"forbidden"}')$$,
  '23514', null, 'service_role detail key is rejected'
);
select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('21000000-0000-4000-8000-000000000001', 'user_created', '{"items":[{"Secret":"forbidden"}]}')$$,
  '23514', null, 'secret detail key nested in an array is rejected'
);

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000001', true);

select lives_ok(
  $$update public.profiles set full_name = 'Phase 2C Updated Staff' where id = auth.uid()$$,
  'Profile owner can still update their own full_name'
);
select is(
  (select full_name from public.profiles where id = auth.uid()),
  'Phase 2C Updated Staff',
  'Owner full_name update persists'
);
select throws_ok(
  $$update public.profiles set must_change_password = true where id = auth.uid()$$,
  '42501', 'permission denied for table profiles',
  'Profile owner cannot change must_change_password'
);
select throws_ok(
  $$update public.profiles set disabled_at = now() where id = auth.uid()$$,
  '42501', 'permission denied for table profiles',
  'Profile owner cannot change disabled_at'
);
select throws_ok(
  $$update public.profiles set must_change_password = true where id = '11000000-0000-4000-8000-000000000005'$$,
  '42501', 'permission denied for table profiles',
  'Another authenticated user cannot change must_change_password'
);
select throws_ok(
  $$update public.profiles set disabled_at = now() where id = '11000000-0000-4000-8000-000000000005'$$,
  '42501', 'permission denied for table profiles',
  'Another authenticated user cannot change disabled_at'
);
select is(
  (select count(*) from public.account_management_audit_logs),
  0::bigint,
  'Staff cannot read audit logs'
);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000002', true);
select is(
  (select count(*) from public.account_management_audit_logs),
  0::bigint,
  'Branch manager cannot read audit logs'
);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000003', true);
select is(
  coalesce((select array_agg(id order by id) from public.account_management_audit_logs), '{}'::uuid[]),
  array['41000000-0000-4000-8000-000000000001'::uuid],
  'Organization Manager A reads exactly Organization A audit logs'
);
select is(
  (select count(*) from public.account_management_audit_logs where organization_id = '21000000-0000-4000-8000-000000000002'),
  0::bigint,
  'Organization Manager A cannot read Organization B audit logs'
);

select set_config('request.jwt.claim.sub', '11000000-0000-4000-8000-000000000004', true);
select is(
  coalesce((select array_agg(id order by id) from public.account_management_audit_logs), '{}'::uuid[]),
  array['41000000-0000-4000-8000-000000000002'::uuid],
  'Organization Manager B reads exactly Organization B audit logs'
);
select is(
  (select count(*) from public.account_management_audit_logs where organization_id = '21000000-0000-4000-8000-000000000001'),
  0::bigint,
  'Organization Manager B cannot read Organization A audit logs'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action) values ('21000000-0000-4000-8000-000000000002', 'user_created')$$,
  '42501', 'permission denied for table account_management_audit_logs',
  'Authenticated organization manager cannot insert audit logs'
);
select throws_ok(
  $$update public.account_management_audit_logs set details = '{}' where id = '41000000-0000-4000-8000-000000000002'$$,
  '42501', 'permission denied for table account_management_audit_logs',
  'Authenticated organization manager cannot update audit logs'
);
select throws_ok(
  $$delete from public.account_management_audit_logs where id = '41000000-0000-4000-8000-000000000002'$$,
  '42501', 'permission denied for table account_management_audit_logs',
  'Authenticated organization manager cannot delete audit logs'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $$select must_change_password, disabled_at from public.profiles$$,
  '42501', 'permission denied for table profiles',
  'Anonymous cannot read lifecycle fields or profile rows'
);
select throws_ok(
  $$select * from public.account_management_audit_logs$$,
  '42501', 'permission denied for table account_management_audit_logs',
  'Anonymous cannot read audit logs'
);

reset role;

delete from auth.users where id = '11000000-0000-4000-8000-000000000005';
select is(
  (select count(*) from public.account_management_audit_logs where id in ('41000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000002')),
  2::bigint,
  'Deleting a target user preserves audit rows'
);
select is(
  (select count(*) from public.account_management_audit_logs where id in ('41000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000002') and target_user_id is null),
  2::bigint,
  'Deleting a target user nulls target references'
);

delete from auth.users where id = '11000000-0000-4000-8000-000000000003';
select is(
  (select actor_user_id from public.account_management_audit_logs where id = '41000000-0000-4000-8000-000000000001'),
  null::uuid,
  'Deleting an actor user preserves the log and nulls its actor reference'
);

select throws_ok(
  $$delete from public.organizations where id = '21000000-0000-4000-8000-000000000001'$$,
  '23503',
  null,
  'Organization deletion is restricted so audit tenant attribution is retained'
);

delete from public.branches where id = '31000000-0000-4000-8000-000000000002';
select is(
  (select branch_id from public.account_management_audit_logs where id = '41000000-0000-4000-8000-000000000002'),
  null::uuid,
  'Branch deletion preserves the audit row and clears only branch_id'
);
select is(
  (select organization_id from public.account_management_audit_logs where id = '41000000-0000-4000-8000-000000000002'),
  '21000000-0000-4000-8000-000000000002'::uuid,
  'Branch deletion retains audit organization attribution'
);

select ok(
  not has_table_privilege('authenticated', 'public.account_management_audit_logs', 'insert')
  and not has_table_privilege('authenticated', 'public.account_management_audit_logs', 'update')
  and not has_table_privilege('authenticated', 'public.account_management_audit_logs', 'delete'),
  'Authenticated has no audit mutation table privileges'
);
select ok(
  has_column_privilege('authenticated', 'public.profiles', 'full_name', 'update')
  and not has_column_privilege('authenticated', 'public.profiles', 'must_change_password', 'update')
  and not has_column_privilege('authenticated', 'public.profiles', 'disabled_at', 'update'),
  'Profile UPDATE privilege remains limited to full_name'
);
select ok(
  not has_function_privilege('authenticated', 'private.account_audit_details_are_safe(jsonb)', 'execute'),
  'Authenticated cannot call the audit detail constraint helper'
);
select ok(
  has_table_privilege('service_role', 'public.account_management_audit_logs', 'insert')
  and not has_table_privilege('service_role', 'public.account_management_audit_logs', 'update')
  and not has_table_privilege('service_role', 'public.account_management_audit_logs', 'delete')
  and not has_table_privilege('service_role', 'public.account_management_audit_logs', 'truncate'),
  'Future trusted service boundary can only append audit rows'
);
select ok(
  has_column_privilege('service_role', 'public.profiles', 'must_change_password', 'update')
  and has_column_privilege('service_role', 'public.profiles', 'disabled_at', 'update'),
  'Future trusted service boundary can control lifecycle columns'
);
select ok(
  not exists (
    select 1
    from pg_proc
    join pg_namespace on pg_namespace.oid = pg_proc.pronamespace
    where pg_namespace.nspname = 'public'
      and pg_proc.proname like '%password%'
      and (
        has_function_privilege('public', pg_proc.oid, 'execute')
        or has_function_privilege('anon', pg_proc.oid, 'execute')
        or has_function_privilege('authenticated', pg_proc.oid, 'execute')
      )
  ),
  'No public client-callable password or temporary-flag RPC exists'
);

select * from finish();

rollback;
