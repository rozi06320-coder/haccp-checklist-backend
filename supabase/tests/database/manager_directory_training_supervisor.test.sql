begin;
select plan(28);

-- Seed Auth Users
insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('18000000-0000-4000-8000-000000000001'::uuid, 'manager@directory.test'),
  ('18000000-0000-4000-8000-000000000002'::uuid, 'unauthorized@directory.test'),
  ('18000000-0000-4000-8000-000000000003'::uuid, 'std-supervisor@directory.test'),
  ('18000000-0000-4000-8000-000000000004'::uuid, 'training-sup-single@directory.test'),
  ('18000000-0000-4000-8000-000000000005'::uuid, 'training-sup-multi@directory.test'),
  ('18000000-0000-4000-8000-000000000006'::uuid, 'training-sup-inactive@directory.test'),
  ('18000000-0000-4000-8000-000000000007'::uuid, 'training-sup-disabled@directory.test'),
  ('18000000-0000-4000-8000-000000000008'::uuid, 'training-sup-cross@directory.test'),
  ('18000000-0000-4000-8000-000000000009'::uuid, 'transition-user@directory.test'),
  ('18000000-0000-4000-8000-000000000010'::uuid, 'admin@directory.test')
) users(id, email);

-- Seed Profiles
update public.profiles
set full_name = case id
    when '18000000-0000-4000-8000-000000000001' then 'Org Manager'
    when '18000000-0000-4000-8000-000000000002' then 'Unauthorized Actor'
    when '18000000-0000-4000-8000-000000000003' then 'Standard Supervisor'
    when '18000000-0000-4000-8000-000000000004' then 'Single Branch Trainer'
    when '18000000-0000-4000-8000-000000000005' then 'Multi Branch Trainer'
    when '18000000-0000-4000-8000-000000000006' then 'Inactive Trainer'
    when '18000000-0000-4000-8000-000000000007' then 'Disabled Trainer'
    when '18000000-0000-4000-8000-000000000008' then 'Cross Org Trainer'
    when '18000000-0000-4000-8000-000000000009' then 'Transitioning Supervisor'
    when '18000000-0000-4000-8000-000000000010' then 'Internal Admin'
    else 'Unknown'
  end,
  full_name_ar = case
    when id = '18000000-0000-4000-8000-000000000004' then 'مدرب فرع واحد'
    when id = '18000000-0000-4000-8000-000000000005' then 'مدرب متعدد الفروع'
    else null
  end,
  person_code = case
    when id = '18000000-0000-4000-8000-000000000003' then 'SUP-STD-01'
    when id = '18000000-0000-4000-8000-000000000004' then 'TS-SINGLE-01'
    when id = '18000000-0000-4000-8000-000000000005' then 'TS-MULTI-02'
    when id = '18000000-0000-4000-8000-000000000009' then 'TRANS-01'
    else null
  end,
  phone_number = case
    when id = '18000000-0000-4000-8000-000000000004' then '+966500000004'
    else null
  end,
  country_code = 'SA',
  disabled_at = case when id = '18000000-0000-4000-8000-000000000007' then now() else null end,
  must_change_password = false
where id::text like '18000000-0000-4000-8000-%';

-- Internal Admin privilege
insert into public.internal_admin_memberships (user_id, active)
values ('18000000-0000-4000-8000-000000000010', true)
on conflict (user_id) do update set active = true;

-- Seed Organizations
insert into public.organizations(id, name, slug, active) values
  ('28000000-0000-4000-8000-000000000001', 'Test Organization 1', 'test-org-1', true),
  ('28000000-0000-4000-8000-000000000002', 'Test Organization 2', 'test-org-2', true);

-- Seed Branches
insert into public.branches(id, organization_id, name, code, timezone, active) values
  ('38000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', 'Branch North', 'NORTH', 'Asia/Riyadh', true),
  ('38000000-0000-4000-8000-000000000002', '28000000-0000-4000-8000-000000000001', 'Branch South', 'SOUTH', 'Asia/Riyadh', true),
  ('38000000-0000-4000-8000-000000000003', '28000000-0000-4000-8000-000000000002', 'Branch East', 'EAST', 'Asia/Riyadh', true);

-- Manager Organization Membership
insert into public.organization_memberships(organization_id, user_id, role, active) values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000001', 'organization_manager', true);

-- Seed Operational Staff
insert into public.operational_staff(id, organization_id, branch_id, staff_code, display_name, employment_status, country_code, created_by, created_at)
values
  ('48000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', '38000000-0000-4000-8000-000000000001', 'EMP-N01', 'North Staff Worker', 'active', 'SA', '18000000-0000-4000-8000-000000000001', now() - interval '10 days');

-- Standard Supervisor: branch_memberships
insert into public.branch_memberships(branch_id, user_id, role, active, created_at)
values
  ('38000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000003', 'branch_manager', true, now() - interval '20 days'),
  ('38000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000009', 'branch_manager', true, now() - interval '30 days');

-- Single Branch Training Supervisor
insert into public.training_memberships(organization_id, user_id, account_name, training_role, active, created_by, created_at)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000004', 'Single Branch Trainer', 'training_supervisor', true, '18000000-0000-4000-8000-000000000010', now() - interval '5 days');
insert into public.training_membership_branches(organization_id, user_id, branch_id)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000004', '38000000-0000-4000-8000-000000000001');

-- Multi Branch Training Supervisor (assigned to North and South)
insert into public.training_memberships(organization_id, user_id, account_name, training_role, active, created_by, created_at)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000005', 'Multi Branch Trainer', 'training_supervisor', true, '18000000-0000-4000-8000-000000000010', now() - interval '15 days');
insert into public.training_membership_branches(organization_id, user_id, branch_id)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000005', '38000000-0000-4000-8000-000000000001'),
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000005', '38000000-0000-4000-8000-000000000002');

-- Inactive / Revoked Training Supervisor
insert into public.training_memberships(organization_id, user_id, account_name, training_role, active, created_by, created_at)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000006', 'Inactive Trainer', 'training_supervisor', false, '18000000-0000-4000-8000-000000000010', now() - interval '25 days');
insert into public.training_membership_branches(organization_id, user_id, branch_id)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000006', '38000000-0000-4000-8000-000000000001');

-- Disabled Profile Training Supervisor
insert into public.training_memberships(organization_id, user_id, account_name, training_role, active, created_by, created_at)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000007', 'Disabled Trainer', 'training_supervisor', true, '18000000-0000-4000-8000-000000000010', now() - interval '3 days');
insert into public.training_membership_branches(organization_id, user_id, branch_id)
values
  ('28000000-0000-4000-8000-000000000001', '18000000-0000-4000-8000-000000000007', '38000000-0000-4000-8000-000000000001');

-- Cross-Organization Training Supervisor (Org 2, Branch East)
insert into public.training_memberships(organization_id, user_id, account_name, training_role, active, created_by, created_at)
values
  ('28000000-0000-4000-8000-000000000002', '18000000-0000-4000-8000-000000000008', 'Cross Org Trainer', 'training_supervisor', true, '18000000-0000-4000-8000-000000000010', now() - interval '2 days');
insert into public.training_membership_branches(organization_id, user_id, branch_id)
values
  ('28000000-0000-4000-8000-000000000002', '18000000-0000-4000-8000-000000000008', '38000000-0000-4000-8000-000000000003');

-- Execute Directory Queries
create temporary table results as
select
  'all' as query_name,
  public.list_managed_people_directory('18000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', null, pg_catalog.date_trunc('month', current_date)::date, null, null) as payload
union all
select
  'north' as query_name,
  public.list_managed_people_directory('18000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', '38000000-0000-4000-8000-000000000001', pg_catalog.date_trunc('month', current_date)::date, null, null) as payload
union all
select
  'south' as query_name,
  public.list_managed_people_directory('18000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', '38000000-0000-4000-8000-000000000002', pg_catalog.date_trunc('month', current_date)::date, null, null) as payload
union all
select
  'search-arabic' as query_name,
  public.list_managed_people_directory('18000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', null, pg_catalog.date_trunc('month', current_date)::date, 'مدرب متعدد', null) as payload
union all
select
  'code-filter' as query_name,
  public.list_managed_people_directory('18000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', null, pg_catalog.date_trunc('month', current_date)::date, null, 'TS-SINGLE') as payload;

create temporary table all_people as
select r.query_name, person
from results r
cross join lateral jsonb_array_elements(r.payload->'people') as person;

-- Assertion 1: Existing Staff appears intact
select ok(
  exists(select 1 from all_people where query_name = 'all' and person->>'person_type' = 'staff' and person->>'person_id' = '48000000-0000-4000-8000-000000000001'),
  'Existing staff appears in people directory'
);

-- Assertion 2: Existing Standard Supervisor appears with supervisor_role = supervisor
select is(
  (select person->>'supervisor_role' from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000003'),
  'supervisor',
  'Standard supervisor has supervisor_role = supervisor'
);

-- Assertion 3: Active Training Supervisor appears with supervisor_role = training_supervisor
select is(
  (select person->>'supervisor_role' from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000004'),
  'training_supervisor',
  'Active training supervisor has supervisor_role = training_supervisor'
);

-- Assertion 4: Active Training Supervisor preserves person_type = supervisor for contract backward-compatibility
select is(
  (select person->>'person_type' from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000004'),
  'supervisor',
  'Training supervisor returns person_type = supervisor'
);

-- Assertion 5: Training Supervisor phone number, email, and display name are populated
select is(
  (select person->>'phone_number' from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000004'),
  '+966500000004',
  'Training supervisor phone number is accurately returned from profile'
);

-- Assertion 6: Multi-branch Training Supervisor appears exactly ONCE
select is(
  (select count(*) from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000005'),
  1::bigint,
  'Multi-branch training supervisor is deduplicated to exactly one record'
);

-- Assertion 7: Multi-branch Training Supervisor contains all assigned branches ordered by name
select is(
  (select jsonb_array_length(person->'branches') from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000005'),
  2,
  'Multi-branch training supervisor row includes all 2 assigned branches'
);

-- Assertion 8: Suspended / Inactive Training Supervisor is EXCLUDED
select ok(
  not exists(select 1 from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000006'),
  'Inactive training supervisor is excluded from directory'
);

-- Assertion 9: Disabled Training Supervisor appears with status = disabled
select is(
  (select person->>'status' from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000007'),
  'disabled',
  'Disabled training supervisor status is disabled'
);

-- Assertion 10: Cross-organization Training Supervisor is NOT leaked
select ok(
  not exists(select 1 from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000008'),
  'Cross-organization training supervisor is excluded'
);

-- Assertion 11: Branch Filter (North) includes single-branch trainer assigned to North
select ok(
  exists(select 1 from all_people where query_name = 'north' and person->>'person_id' = '18000000-0000-4000-8000-000000000004'),
  'North branch filter includes trainer assigned to North'
);

-- Assertion 12: Branch Filter (South) excludes trainer assigned only to North
select ok(
  not exists(select 1 from all_people where query_name = 'south' and person->>'person_id' = '18000000-0000-4000-8000-000000000004'),
  'South branch filter excludes trainer assigned only to North'
);

-- Assertion 13: Branch Filter (South) includes multi-branch trainer assigned to North + South
select ok(
  exists(select 1 from all_people where query_name = 'south' and person->>'person_id' = '18000000-0000-4000-8000-000000000005'),
  'South branch filter includes multi-branch trainer assigned to South'
);

-- Assertion 14: Search by Arabic name matches Training Supervisor
select is(
  (select person->>'person_id' from all_people where query_name = 'search-arabic'),
  '18000000-0000-4000-8000-000000000005',
  'Search by Arabic name finds multi-branch training supervisor'
);

-- Assertion 15: Code filter matches Training Supervisor person_code
select is(
  (select person->>'person_id' from all_people where query_name = 'code-filter'),
  '18000000-0000-4000-8000-000000000004',
  'Code filter matches training supervisor person code'
);

-- Assertion 16: Staff-only keys are omitted from Training Supervisor rows
select ok(
  not ((select person from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000004') ?| array['staff_id', 'assignment_id', 'operational_team_id', 'operational_roles', 'supervisor_training_status']),
  'Training supervisor row omits staff-only operational keys'
);

-- Assertion 17: Pre-transition state for transitioning supervisor is supervisor
select is(
  (select person->>'supervisor_role' from all_people where query_name = 'all' and person->>'person_id' = '18000000-0000-4000-8000-000000000009'),
  'supervisor',
  'Pre-transition user has supervisor_role = supervisor'
);

-- Perform Atomic Transition: Supervisor -> Training Supervisor
select public.transition_internal_admin_access_role(
  actor_user_id => '18000000-0000-4000-8000-000000000010'::uuid,
  target_organization_id => '28000000-0000-4000-8000-000000000001'::uuid,
  target_user_id => '18000000-0000-4000-8000-000000000009'::uuid,
  source_role => 'supervisor'::text,
  target_role => 'training_supervisor'::text,
  target_branch_id => null::uuid,
  target_branch_ids => array['38000000-0000-4000-8000-000000000002']::uuid[],
  target_team_assignments => '[]'::jsonb
);

-- Re-query Directory post-transition
create temporary table post_transition as
select person
from (
  select public.list_managed_people_directory('18000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000001', null, pg_catalog.date_trunc('month', current_date)::date, null, null) as payload
) t
cross join lateral jsonb_array_elements(t.payload->'people') as person;

-- Assertion 18: Post-transition user immediately reflects supervisor_role = training_supervisor
select is(
  (select person->>'supervisor_role' from post_transition where person->>'person_id' = '18000000-0000-4000-8000-000000000009'),
  'training_supervisor',
  'Post-transition user immediately appears with supervisor_role = training_supervisor'
);

-- Assertion 19: Post-transition user is assigned to newly selected branch South
select is(
  (select person->'branches'->0->>'id' from post_transition where person->>'person_id' = '18000000-0000-4000-8000-000000000009'),
  '38000000-0000-4000-8000-000000000002',
  'Post-transition user reflects destination branch South'
);

-- Assertion 20: Post-transition user appears exactly once (no dual roles)
select is(
  (select count(*) from post_transition where person->>'person_id' = '18000000-0000-4000-8000-000000000009'),
  1::bigint,
  'Post-transition user appears exactly once in directory'
);

-- Security Assertion 21: Unauthorized manager cannot call RPC
select throws_ok(
  $$select public.list_managed_people_directory('18000000-0000-4000-8000-000000000002', '28000000-0000-4000-8000-000000000001', null, pg_catalog.date_trunc('month', current_date)::date, null, null)$$,
  '42501',
  'people directory access denied',
  'Unauthorized manager calling directory is rejected with 42501'
);

-- Security Assertion 22: Cross-organization manager calling RPC is rejected
select throws_ok(
  $$select public.list_managed_people_directory('18000000-0000-4000-8000-000000000001', '28000000-0000-4000-8000-000000000002', null, pg_catalog.date_trunc('month', current_date)::date, null, null)$$,
  '42501',
  'people directory access denied',
  'Manager cannot access unauthorized organization directory'
);

-- Security Assertion 23: RPC is SECURITY DEFINER
select ok(
  (select prosecdef from pg_catalog.pg_proc where oid = 'public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)'::regprocedure),
  'list_managed_people_directory RPC is SECURITY DEFINER'
);

-- Security Assertion 24: RPC executes with empty search_path
select alike(
  pg_catalog.pg_get_functiondef('public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)'::regprocedure),
  $$%SET search_path TO ''%$$,
  'list_managed_people_directory RPC enforces empty search_path'
);

-- Security Assertion 25: service_role can execute RPC
select ok(
  has_function_privilege('service_role', 'public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)', 'execute'),
  'service_role has EXECUTE privilege on list_managed_people_directory'
);

-- Security Assertion 26: anon role CANNOT execute RPC
select ok(
  not has_function_privilege('anon', 'public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)', 'execute'),
  'anon role cannot execute list_managed_people_directory'
);

-- Security Assertion 27: authenticated role CANNOT execute RPC
select ok(
  not has_function_privilege('authenticated', 'public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)', 'execute'),
  'authenticated role cannot execute list_managed_people_directory'
);

-- Integrity Assertion 28: Total count matches people array length
select is(
  (select (payload->>'people_total')::int from results where query_name = 'all'),
  (select jsonb_array_length(payload->'people') from results where query_name = 'all'),
  'Response people_total matches length of returned people array'
);

select * from finish();
rollback;
