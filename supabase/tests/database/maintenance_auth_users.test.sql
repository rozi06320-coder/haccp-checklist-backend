begin;
select plan(21);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1f000000-0000-4000-8000-000000000001'::uuid, 'manager@example.invalid'),
  ('1f000000-0000-4000-8000-000000000002'::uuid, 'other-manager@example.invalid'),
  ('1f000000-0000-4000-8000-000000000003'::uuid, 'supervisor@example.invalid'),
  ('1f000000-0000-4000-8000-000000000004'::uuid, 'maintenance@example.invalid'),
  ('1f000000-0000-4000-8000-000000000005'::uuid, 'internal-admin@example.invalid')
) users(id, email);

update public.profiles set full_name = case id
  when '1f000000-0000-4000-8000-000000000001' then 'Maintenance Manager'
  when '1f000000-0000-4000-8000-000000000002' then 'Other Manager'
  when '1f000000-0000-4000-8000-000000000003' then 'Supervisor'
  when '1f000000-0000-4000-8000-000000000005' then 'Internal Admin'
  else 'Pending Maintenance'
end, must_change_password = false
where id::text like '1f000000-%';

insert into public.organizations(id,name,slug) values
 ('2f000000-0000-4000-8000-000000000001','Maintenance Auth Org','maintenance-auth-org'),
 ('2f000000-0000-4000-8000-000000000002','Other Auth Org','other-auth-org');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','organization_manager'),
 ('2f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000002','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Maintenance Branch','MAUTH','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003','branch_manager');
insert into public.internal_admin_memberships(user_id,active)
values ('1f000000-0000-4000-8000-000000000005', true);

select ok(not has_table_privilege('authenticated','public.maintenance_memberships','insert'),'authenticated cannot insert maintenance memberships directly');
select ok(has_table_privilege('authenticated','public.maintenance_memberships','select'),'authenticated can select maintenance memberships through RLS');
select ok(not has_function_privilege('authenticated','public.finalize_provisioned_maintenance_user(uuid,uuid,uuid,text)','execute'),'authenticated cannot execute maintenance finalize RPC');
select ok(has_function_privilege('service_role','public.finalize_provisioned_maintenance_user(uuid,uuid,uuid,text)','execute'),'service role can execute maintenance finalize RPC');

select lives_ok($$select public.finalize_provisioned_maintenance_user(
 '1f000000-0000-4000-8000-000000000005','2f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000004','  Maintenance Tech  ')$$,'internal admin finalizes maintenance auth user');
select is(
  (select full_name from public.profiles where id='1f000000-0000-4000-8000-000000000004'),
  'Maintenance Tech',
  'profile name is normalized'
);
select ok(
  (select must_change_password from public.profiles where id='1f000000-0000-4000-8000-000000000004'),
  'maintenance auth user must change temporary password'
);
select is(
  (select count(*) from public.maintenance_memberships where organization_id='2f000000-0000-4000-8000-000000000001' and user_id='1f000000-0000-4000-8000-000000000004' and active),
  1::bigint,
  'active maintenance membership is created'
);
select is(
  (select count(*) from public.list_managed_maintenance_users('1f000000-0000-4000-8000-000000000005','2f000000-0000-4000-8000-000000000001') where email='maintenance@example.invalid' and active),
  1::bigint,
  'internal admin can list maintenance auth users'
);

set role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','1f000000-0000-4000-8000-000000000004',true);
select is(
  (select count(*) from public.maintenance_memberships membership
   join public.organizations organization on organization.id = membership.organization_id
   where membership.user_id = '1f000000-0000-4000-8000-000000000004'
     and membership.active
     and organization.active),
  0::bigint,
  'temporary-password maintenance user cannot read joined organization access yet'
);
reset role;

update public.profiles set must_change_password = false where id = '1f000000-0000-4000-8000-000000000004';

set role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','1f000000-0000-4000-8000-000000000004',true);
select is(
  (select count(*) from public.maintenance_memberships membership
   join public.organizations organization on organization.id = membership.organization_id
   where membership.user_id = '1f000000-0000-4000-8000-000000000004'
     and membership.active
     and organization.active
     and organization.name = 'Maintenance Auth Org'),
  1::bigint,
  'active maintenance user can read joined organization access for /maintenance'
);
reset role;

select throws_ok($$select public.finalize_provisioned_maintenance_user(
 '1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000004','Manager Attempt')$$,'42501','provisioning denied','manager cannot finalize maintenance user');
select throws_ok($$select public.finalize_provisioned_maintenance_user(
 '1f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000004','Bad Manager')$$,'42501','provisioning denied','unrelated manager cannot finalize maintenance user');
select throws_ok($$select public.finalize_provisioned_maintenance_user(
 '1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000004','Supervisor Attempt')$$,'42501','provisioning denied','supervisor cannot finalize maintenance user');
select throws_ok($$select * from public.list_managed_maintenance_users(
 '1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001')$$,'42501','maintenance user access denied','manager cannot list maintenance users');
select throws_ok($$select * from public.list_managed_maintenance_users(
 '1f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001')$$,'42501','maintenance user access denied','unrelated manager cannot list target organization maintenance users');
select throws_ok($$select * from public.deactivate_maintenance_user(
 '1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000004')$$,'42501','maintenance user access denied','manager cannot deactivate maintenance user');
select throws_ok($$select * from public.deactivate_maintenance_user(
 '1f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000004')$$,'42501','maintenance user access denied','unrelated manager cannot deactivate maintenance user');

select lives_ok($$select * from public.deactivate_maintenance_user(
 '1f000000-0000-4000-8000-000000000005','2f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000004')$$,'internal admin deactivates maintenance auth user');
select is(
  (select count(*) from public.maintenance_memberships where user_id='1f000000-0000-4000-8000-000000000004' and active),
  0::bigint,
  'maintenance membership is inactive after deactivation'
);

set role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','1f000000-0000-4000-8000-000000000004',true);
select is(
  (select count(*) from public.maintenance_memberships membership
   join public.organizations organization on organization.id = membership.organization_id
   where membership.user_id = '1f000000-0000-4000-8000-000000000004'
     and membership.active
     and organization.active),
  0::bigint,
  'deactivated maintenance user cannot read joined organization access'
);
reset role;

select * from finish();
rollback;
