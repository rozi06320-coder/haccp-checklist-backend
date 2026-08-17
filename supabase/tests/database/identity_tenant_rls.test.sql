begin;

select plan(68);

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    '10000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'staff-a1@example.invalid',
    '{"provider":"email","providers":["email"]}',
    '{}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '10000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'branch-manager-a1@example.invalid',
    '{"provider":"email","providers":["email"]}',
    '{}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '10000000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'organization-manager-a@example.invalid',
    '{"provider":"email","providers":["email"]}',
    '{}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '10000000-0000-4000-8000-000000000004',
    'authenticated',
    'authenticated',
    'staff-b1@example.invalid',
    '{"provider":"email","providers":["email"]}',
    '{}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '10000000-0000-4000-8000-000000000005',
    'authenticated',
    'authenticated',
    'no-memberships@example.invalid',
    '{"provider":"email","providers":["email"]}',
    '{}',
    now(),
    now()
  );

insert into public.organizations (id, name, slug)
values
  ('20000000-0000-4000-8000-000000000001', 'RLS Test Organization A', 'rls-test-organization-a'),
  ('20000000-0000-4000-8000-000000000002', 'RLS Test Organization B', 'rls-test-organization-b');

insert into public.branches (id, organization_id, name, code)
values
  (
    '30000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'RLS Test Branch A1',
    'RLS-A1'
  ),
  (
    '30000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000001',
    'RLS Test Branch A2',
    'RLS-A2'
  ),
  (
    '30000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000002',
    'RLS Test Branch B1',
    'RLS-B1'
  );

insert into public.organization_memberships (organization_id, user_id, role)
values (
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000003',
  'organization_manager'
);

insert into public.branch_memberships (branch_id, user_id, role)
values
  (
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'staff'
  ),
  (
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002',
    'branch_manager'
  ),
  (
    '30000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000004',
    'staff'
  );

select is(
  (select count(*) from auth.users where id::text like '10000000-%'),
  5::bigint,
  'fixture setup created all five fake users'
);
select is(
  (select count(*) from public.profiles where id::text like '10000000-%'),
  5::bigint,
  'new-user trigger created all five profiles'
);
select is(
  (select count(*) from public.organizations where id::text like '20000000-%'),
  2::bigint,
  'fixture setup created both organizations'
);
select is(
  (select count(*) from public.branches where id::text like '30000000-%'),
  3::bigint,
  'fixture setup created all three branches'
);
select is(
  (
    select
      (select count(*) from public.organization_memberships where user_id::text like '10000000-%')
      + (select count(*) from public.branch_memberships where user_id::text like '10000000-%')
  ),
  4::bigint,
  'fixture setup created every membership'
);

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);

select is(
  coalesce((select array_agg(id order by id) from public.organizations), '{}'::uuid[]),
  array['20000000-0000-4000-8000-000000000001'::uuid],
  'Staff A1 sees exactly Organization A'
);
select is(
  coalesce((select array_agg(id order by id) from public.branches), '{}'::uuid[]),
  array['30000000-0000-4000-8000-000000000001'::uuid],
  'Staff A1 sees exactly Branch A1'
);
select is(
  coalesce((select array_agg(id order by id) from public.profiles), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000001'::uuid],
  'Staff A1 sees exactly their own profile'
);
select is(
  (select count(*) from public.organization_memberships),
  0::bigint,
  'Staff A1 sees no organization memberships'
);
select is(
  coalesce((select array_agg(user_id order by user_id) from public.branch_memberships), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000001'::uuid],
  'Staff A1 sees exactly their own branch membership'
);

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);

select is(
  coalesce((select array_agg(id order by id) from public.organizations), '{}'::uuid[]),
  array['20000000-0000-4000-8000-000000000001'::uuid],
  'Branch Manager A1 sees exactly Organization A'
);
select is(
  coalesce((select array_agg(id order by id) from public.branches), '{}'::uuid[]),
  array['30000000-0000-4000-8000-000000000001'::uuid],
  'Branch Manager A1 sees exactly Branch A1'
);
select is(
  coalesce((select array_agg(id order by id) from public.profiles), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000002'::uuid],
  'Branch Manager A1 sees exactly their own profile'
);
select is(
  (select count(*) from public.organization_memberships),
  0::bigint,
  'Branch Manager A1 sees no organization memberships'
);
select is(
  coalesce((select array_agg(user_id order by user_id) from public.branch_memberships), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000002'::uuid],
  'Branch Manager A1 sees exactly their own branch membership'
);

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);

select is(
  coalesce((select array_agg(id order by id) from public.organizations), '{}'::uuid[]),
  array['20000000-0000-4000-8000-000000000001'::uuid],
  'Organization Manager A sees exactly Organization A'
);
select is(
  coalesce((select array_agg(id order by id) from public.branches), '{}'::uuid[]),
  array[
    '30000000-0000-4000-8000-000000000001'::uuid,
    '30000000-0000-4000-8000-000000000002'::uuid
  ],
  'Organization Manager A sees exactly Branch A1 and Branch A2'
);
select is(
  coalesce((select array_agg(id order by id) from public.profiles), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000003'::uuid],
  'Organization Manager A sees exactly their own profile'
);
select is(
  coalesce(
    (select array_agg(user_id order by user_id) from public.organization_memberships),
    '{}'::uuid[]
  ),
  array['10000000-0000-4000-8000-000000000003'::uuid],
  'Organization Manager A sees exactly Organization A memberships'
);
select is(
  coalesce((select array_agg(user_id order by user_id) from public.branch_memberships), '{}'::uuid[]),
  array[
    '10000000-0000-4000-8000-000000000001'::uuid,
    '10000000-0000-4000-8000-000000000002'::uuid
  ],
  'Organization Manager A sees exactly branch memberships in Organization A'
);

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);

select is(
  coalesce((select array_agg(id order by id) from public.organizations), '{}'::uuid[]),
  array['20000000-0000-4000-8000-000000000002'::uuid],
  'Staff B1 sees exactly Organization B'
);
select is(
  coalesce((select array_agg(id order by id) from public.branches), '{}'::uuid[]),
  array['30000000-0000-4000-8000-000000000003'::uuid],
  'Staff B1 sees exactly Branch B1'
);
select is(
  coalesce((select array_agg(id order by id) from public.profiles), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000004'::uuid],
  'Staff B1 sees exactly their own profile'
);
select is(
  (select count(*) from public.organization_memberships),
  0::bigint,
  'Staff B1 sees no organization memberships'
);
select is(
  coalesce((select array_agg(user_id order by user_id) from public.branch_memberships), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000004'::uuid],
  'Staff B1 sees exactly their own branch membership'
);

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);

select is((select count(*) from public.organizations), 0::bigint, 'No-membership user sees no organizations');
select is((select count(*) from public.branches), 0::bigint, 'No-membership user sees no branches');
select is(
  coalesce((select array_agg(id order by id) from public.profiles), '{}'::uuid[]),
  array['10000000-0000-4000-8000-000000000005'::uuid],
  'No-membership user sees exactly their own profile'
);
select is(
  (select count(*) from public.organization_memberships),
  0::bigint,
  'No-membership user sees no organization memberships'
);
select is(
  (select count(*) from public.branch_memberships),
  0::bigint,
  'No-membership user sees no branch memberships'
);

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select lives_ok(
  $$update public.profiles set full_name = 'Updated Staff A1' where id = auth.uid()$$,
  'Staff A1 can update their own full_name'
);
select is(
  (select full_name from public.profiles where id = auth.uid()),
  'Updated Staff A1',
  'Staff A1 own full_name update persisted'
);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
select lives_ok(
  $$update public.profiles set full_name = 'Updated Branch Manager A1' where id = auth.uid()$$,
  'Branch Manager A1 can update their own full_name'
);
select is(
  (select full_name from public.profiles where id = auth.uid()),
  'Updated Branch Manager A1',
  'Branch Manager A1 own full_name update persisted'
);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
select lives_ok(
  $$update public.profiles set full_name = 'Updated Organization Manager A' where id = auth.uid()$$,
  'Organization Manager A can update their own full_name'
);
select is(
  (select full_name from public.profiles where id = auth.uid()),
  'Updated Organization Manager A',
  'Organization Manager A own full_name update persisted'
);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
select lives_ok(
  $$update public.profiles set full_name = 'Updated Staff B1' where id = auth.uid()$$,
  'Staff B1 can update their own full_name'
);
select is(
  (select full_name from public.profiles where id = auth.uid()),
  'Updated Staff B1',
  'Staff B1 own full_name update persisted'
);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
select lives_ok(
  $$update public.profiles set full_name = 'Updated No Membership' where id = auth.uid()$$,
  'No-membership user can update their own full_name'
);
select is(
  (select full_name from public.profiles where id = auth.uid()),
  'Updated No Membership',
  'No-membership user own full_name update persisted'
);
select is_empty(
  $$
    update public.profiles
    set full_name = 'Forbidden Other Update'
    where id = '10000000-0000-4000-8000-000000000001'
    returning 1
  $$,
  'A user cannot update another profile'
);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select is_empty(
  $$
    update public.profiles
    set full_name = 'Forbidden Cross Profile Update'
    where id = '10000000-0000-4000-8000-000000000002'
    returning 1
  $$,
  'Staff A1 cannot update Branch Manager A1 profile'
);
select is(
  (select count(*) from public.profiles where id <> auth.uid()),
  0::bigint,
  'Staff A1 cannot read another profile after update attempts'
);
select throws_ok(
  $$update public.profiles set updated_at = now() where id = auth.uid()$$,
  '42501',
  'permission denied for table profiles',
  'A user cannot update protected profile timestamps'
);
select throws_ok(
  $$update public.profiles set id = '10000000-0000-4000-8000-000000000099' where id = auth.uid()$$,
  '42501',
  'permission denied for table profiles',
  'A user cannot change their profile ID'
);

select throws_ok(
  $$insert into public.organizations (name, slug) values ('Forbidden', 'forbidden')$$,
  '42501',
  'permission denied for table organizations',
  'Authenticated users cannot insert organizations'
);
select throws_ok(
  $$update public.organizations set name = 'Forbidden' where id = '20000000-0000-4000-8000-000000000001'$$,
  '42501',
  'permission denied for table organizations',
  'Authenticated users cannot update organizations'
);
select throws_ok(
  $$delete from public.organizations where id = '20000000-0000-4000-8000-000000000001'$$,
  '42501',
  'permission denied for table organizations',
  'Authenticated users cannot delete organizations'
);
select throws_ok(
  $$insert into public.branches (organization_id, name, code) values ('20000000-0000-4000-8000-000000000001', 'Forbidden', 'FORBIDDEN')$$,
  '42501',
  'permission denied for table branches',
  'Authenticated users cannot insert branches'
);
select throws_ok(
  $$update public.branches set name = 'Forbidden' where id = '30000000-0000-4000-8000-000000000001'$$,
  '42501',
  'permission denied for table branches',
  'Authenticated users cannot update branches'
);
select throws_ok(
  $$delete from public.branches where id = '30000000-0000-4000-8000-000000000001'$$,
  '42501',
  'permission denied for table branches',
  'Authenticated users cannot delete branches'
);
select throws_ok(
  $$insert into public.organization_memberships (organization_id, user_id, role) values ('20000000-0000-4000-8000-000000000001', auth.uid(), 'organization_manager')$$,
  '42501',
  'permission denied for table organization_memberships',
  'A user cannot promote themselves to organization_manager'
);
select throws_ok(
  $$update public.organization_memberships set role = 'organization_manager' where user_id = auth.uid()$$,
  '42501',
  'permission denied for table organization_memberships',
  'Authenticated users cannot change organization memberships'
);
select throws_ok(
  $$delete from public.organization_memberships where user_id = auth.uid()$$,
  '42501',
  'permission denied for table organization_memberships',
  'Authenticated users cannot delete organization memberships'
);
select throws_ok(
  $$insert into public.branch_memberships (branch_id, user_id, role) values ('30000000-0000-4000-8000-000000000002', auth.uid(), 'branch_manager')$$,
  '42501',
  'permission denied for table branch_memberships',
  'A user cannot promote themselves to branch_manager'
);
select throws_ok(
  $$update public.branch_memberships set role = 'branch_manager' where user_id = auth.uid()$$,
  '42501',
  'permission denied for table branch_memberships',
  'Authenticated users cannot change branch memberships'
);
select throws_ok(
  $$delete from public.branch_memberships where user_id = auth.uid()$$,
  '42501',
  'permission denied for table branch_memberships',
  'Authenticated users cannot delete branch memberships'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select set_config('request.jwt.claim.sub', '', true);

select throws_ok(
  $$select * from public.organizations$$,
  '42501',
  'permission denied for table organizations',
  'Anonymous cannot read organizations'
);
select throws_ok(
  $$select * from public.branches$$,
  '42501',
  'permission denied for table branches',
  'Anonymous cannot read branches'
);
select throws_ok(
  $$select * from public.profiles$$,
  '42501',
  'permission denied for table profiles',
  'Anonymous cannot read profiles'
);
select throws_ok(
  $$select * from public.organization_memberships$$,
  '42501',
  'permission denied for table organization_memberships',
  'Anonymous cannot read organization memberships'
);
select throws_ok(
  $$select * from public.branch_memberships$$,
  '42501',
  'permission denied for table branch_memberships',
  'Anonymous cannot read branch memberships'
);
select throws_ok(
  $$select private.is_organization_manager('20000000-0000-4000-8000-000000000001')$$,
  '42501',
  'permission denied for schema private',
  'Anonymous cannot execute is_organization_manager'
);
select throws_ok(
  $$select private.has_branch_access('30000000-0000-4000-8000-000000000001')$$,
  '42501',
  'permission denied for schema private',
  'Anonymous cannot execute has_branch_access'
);
select throws_ok(
  $$select private.has_organization_access('20000000-0000-4000-8000-000000000001')$$,
  '42501',
  'permission denied for schema private',
  'Anonymous cannot execute has_organization_access'
);

reset role;

select ok(
  not has_function_privilege('public', 'private.is_organization_manager(uuid)', 'execute'),
  'PUBLIC cannot execute is_organization_manager'
);
select ok(
  not has_function_privilege('public', 'private.has_branch_access(uuid)', 'execute'),
  'PUBLIC cannot execute has_branch_access'
);
select ok(
  not has_function_privilege('public', 'private.has_organization_access(uuid)', 'execute'),
  'PUBLIC cannot execute has_organization_access'
);

select * from finish();

rollback;
