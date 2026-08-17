begin;
select plan(33);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000001'::uuid,
  '1e000000-0000-4000-8000-000000000002',
  '1e000000-0000-4000-8000-000000000003',
  '1e000000-0000-4000-8000-000000000004',
  '1e000000-0000-4000-8000-000000000005'
]) id;
update public.profiles set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Branch Creator Manager'
  when '1e000000-0000-4000-8000-000000000002' then 'Other Branch Manager'
  when '1e000000-0000-4000-8000-000000000003' then 'Branch Supervisor'
  when '1e000000-0000-4000-8000-000000000005' then 'Internal Admin'
  else 'Branch Staff'
end, must_change_password = false
where id::text like '1e000000-%';

insert into public.organizations(id,name,slug) values
 ('2e000000-0000-4000-8000-000000000001','Branch Create Org','branch-create-org'),
 ('2e000000-0000-4000-8000-000000000002','Other Branch Create Org','other-branch-create-org'),
 ('2e000000-0000-4000-8000-000000000003','Inactive Branch Create Org','inactive-branch-create-org');
update public.organizations set active = false where id = '2e000000-0000-4000-8000-000000000003';
insert into public.organization_memberships(organization_id,user_id,role) values
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','organization_manager'),
 ('2e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002','organization_manager');
insert into public.internal_admin_memberships(user_id,active)
values ('1e000000-0000-4000-8000-000000000005',true);
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Existing Branch','EXIST','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003','branch_manager'),
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000004','staff');

select is(has_function_privilege('authenticated','public.create_managed_branch(uuid,uuid,text,text,boolean)','execute'),false,'authenticated cannot execute branch creation RPC');
select is(has_function_privilege('service_role','public.create_managed_branch(uuid,uuid,text,text,boolean)','execute'),true,'service role can execute branch creation RPC');
select is(has_function_privilege('authenticated','public.create_internal_admin_branch(uuid,uuid,text,text,boolean,text)','execute'),false,'authenticated cannot execute internal admin branch creation RPC');
select is(has_function_privilege('service_role','public.create_internal_admin_branch(uuid,uuid,text,text,boolean,text)','execute'),true,'service role can execute internal admin branch creation RPC');

select is(
  (select name from public.create_managed_branch('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','  New   Riyadh Branch  ','Asia/Riyadh',true)),
  'New Riyadh Branch',
  'manager can create normalized branch inside managed organization'
);
select is(
  (select count(*) from public.branches where organization_id='2e000000-0000-4000-8000-000000000001' and name='New Riyadh Branch' and timezone='Asia/Riyadh' and active),
  1::bigint,
  'created branch persists active with timezone'
);
select is(
  (select count(*) from public.account_management_audit_logs where action='branch_created' and organization_id='2e000000-0000-4000-8000-000000000001'),
  1::bigint,
  'branch creation is audited'
);
select is(
  (select count(*) from public.branch_supervisor_teams where branch_id = (select id from public.branches where name='New Riyadh Branch')),
  0::bigint,
  'branch creation does not create supervisor teams'
);
select is(
  (select count(*) from public.operational_staff where branch_id = (select id from public.branches where name='New Riyadh Branch')),
  0::bigint,
  'branch creation does not create operational staff'
);
select ok(
  (select code from public.branches where name='New Riyadh Branch') ~ '^NEWR',
  'branch code is generated from branch name'
);
create temporary table internal_admin_created_branch on commit drop as
select *
from public.create_internal_admin_branch(
  '1e000000-0000-4000-8000-000000000005',
  '2e000000-0000-4000-8000-000000000001',
  '  Admin   Created Branch  ',
  'Asia/Riyadh',
  true,
  ' فرع الإدارة '
);
select is(
  (select organization_id::text from internal_admin_created_branch),
  '2e000000-0000-4000-8000-000000000001',
  'internal admin branch creation returns organization identity'
);
select is((select name from internal_admin_created_branch),'Admin Created Branch','internal admin can create normalized branch');
select is((select name_ar from internal_admin_created_branch),'فرع الإدارة','internal admin branch creation returns normalized Arabic branch name');
select is((select timezone from internal_admin_created_branch),'Asia/Riyadh','internal admin branch creation accepts Asia/Riyadh');
select is((select active from internal_admin_created_branch),true,'internal admin branch creation returns active state');
select ok((select code from internal_admin_created_branch) ~ '^ADMI','internal admin branch code is generated from branch name');
select is(
  (select count(*) from public.branches where id = (select id from internal_admin_created_branch)),
  1::bigint,
  'internal admin branch row actually exists'
);
select is(
  (select count(*) from public.branch_supervisor_teams where branch_id = (select id from public.branches where name='Admin Created Branch')),
  0::bigint,
  'internal admin branch creation does not create supervisor teams'
);
select is(
  (select count(*) from public.operational_staff where branch_id = (select id from public.branches where name='Admin Created Branch')),
  0::bigint,
  'internal admin branch creation does not create operational staff'
);
create temporary table internal_admin_utc_branch on commit drop as
select *
from public.create_internal_admin_branch(
  '1e000000-0000-4000-8000-000000000005',
  '2e000000-0000-4000-8000-000000000001',
  'Admin UTC Branch',
  'UTC',
  true,
  null
);
select is((select timezone from internal_admin_utc_branch),'UTC','internal admin branch creation accepts UTC');
select is(
  (select count(*) from public.branches where id = (select id from internal_admin_utc_branch) and timezone = 'UTC'),
  1::bigint,
  'internal admin UTC branch row actually exists'
);

select throws_ok($$select public.create_internal_admin_branch('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001','admin created branch','Asia/Riyadh',true,null)$$,'23505','branch already exists','internal admin duplicate branch name is rejected case-insensitively');
select throws_ok($$select public.create_internal_admin_branch('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001','Bad Timezone','Not/A_Timezone',true,null)$$,'22023','invalid branch creation request','internal admin invalid timezone is rejected');
select throws_ok($$select public.create_internal_admin_branch('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Manager Through Admin RPC','Asia/Riyadh',true,null)$$,'42501','internal admin access required','manager cannot use internal admin branch creation RPC');
select throws_ok($$select public.create_internal_admin_branch('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','Supervisor Through Admin RPC','Asia/Riyadh',true,null)$$,'42501','internal admin access required','supervisor cannot use internal admin branch creation RPC');
select throws_ok($$select public.create_internal_admin_branch('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-999999999999','Missing Organization Branch','Asia/Riyadh',true,null)$$,'P0002','organization unavailable','internal admin cannot create branch for nonexistent organization');
select throws_ok($$select public.create_internal_admin_branch('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000003','Inactive Organization Branch','Asia/Riyadh',true,null)$$,'P0002','organization unavailable','internal admin cannot create branch for inactive organization');

select throws_ok($$select public.create_managed_branch('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','new riyadh branch','Asia/Riyadh',true)$$,'23505','branch already exists','duplicate branch name is rejected case-insensitively');
select throws_ok($$select public.create_managed_branch('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Bad Timezone','Not/A_Timezone',true)$$,'22023','invalid branch creation request','invalid timezone is rejected');
select throws_ok($$select public.create_managed_branch('1e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','Cross Org','Asia/Riyadh',true)$$,'22023','invalid branch creation request','unrelated manager cannot create in another organization');
select throws_ok($$select public.create_managed_branch('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','Supervisor Branch','Asia/Riyadh',true)$$,'22023','invalid branch creation request','supervisor cannot create branch');
select throws_ok($$select public.create_managed_branch('1e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000001','Staff Branch','Asia/Riyadh',true)$$,'22023','invalid branch creation request','staff cannot create branch');
select throws_ok($$select public.create_managed_branch('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','   ','Asia/Riyadh',true)$$,'22023','invalid branch creation request','empty branch name is rejected');

select * from finish();
rollback;
