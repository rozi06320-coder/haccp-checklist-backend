begin;
select plan(26);

insert into auth.users (instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
       id::text || '@example.invalid', '{"provider":"email","providers":["email"]}', '{}', now(), now()
from pg_catalog.unnest(array[
  '12000000-0000-4000-8000-000000000001'::uuid,
  '12000000-0000-4000-8000-000000000002',
  '12000000-0000-4000-8000-000000000003',
  '12000000-0000-4000-8000-000000000004',
  '12000000-0000-4000-8000-000000000005',
  '12000000-0000-4000-8000-000000000006',
  '12000000-0000-4000-8000-000000000007'
]) as id;
insert into public.organizations (id,name,slug) values
 ('22000000-0000-4000-8000-000000000001','RPC Org A','rpc-org-a'),
 ('22000000-0000-4000-8000-000000000002','RPC Org B','rpc-org-b');
insert into public.branches (id,organization_id,name,code,active) values
 ('32000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','A1','RPC-A1',true),
 ('32000000-0000-4000-8000-000000000002','22000000-0000-4000-8000-000000000001','A2','RPC-A2',true),
 ('32000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','Inactive','RPC-I',false),
 ('32000000-0000-4000-8000-000000000004','22000000-0000-4000-8000-000000000002','B1','RPC-B1',true);
insert into public.organization_memberships (organization_id,user_id,role) values
 ('22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000003','organization_manager'),
 ('22000000-0000-4000-8000-000000000002','12000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships (branch_id,user_id,role) values
 ('32000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000001','staff'),
 ('32000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000002','branch_manager');

select ok(not has_function_privilege('public','public.finalize_provisioned_user(uuid,uuid,uuid,text,text,uuid[])','execute'),'PUBLIC denied');
select ok(not has_function_privilege('anon','public.finalize_provisioned_user(uuid,uuid,uuid,text,text,uuid[])','execute'),'anon denied');
select ok(not has_function_privilege('authenticated','public.finalize_provisioned_user(uuid,uuid,uuid,text,text,uuid[])','execute'),'authenticated denied');
select ok(has_function_privilege('service_role','public.finalize_provisioned_user(uuid,uuid,uuid,text,text,uuid[])','execute'),'service_role execute granted');
select ok(not has_table_privilege('service_role','public.branch_memberships','insert'),'service role gets no broad membership insert grant');

set local role service_role;
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Staff target','staff',array['32000000-0000-4000-8000-000000000001']::uuid[])$$,'42501','provisioning denied','staff actor rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000002','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Target','staff',array['32000000-0000-4000-8000-000000000001']::uuid[])$$,'42501','provisioning denied','branch manager rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000002','12000000-0000-4000-8000-000000000005','Target','staff',array['32000000-0000-4000-8000-000000000004']::uuid[])$$,'42501','provisioning denied','manager A rejected in org B');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Target','organization_manager',array['32000000-0000-4000-8000-000000000001']::uuid[])$$,'22023','invalid provisioning input','organization manager target rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Target','owner',array['32000000-0000-4000-8000-000000000001']::uuid[])$$,'22023','invalid provisioning input','invalid role rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Target','staff','{}'::uuid[])$$,'22023','invalid provisioning input','empty branches rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Target','staff',array['32000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001']::uuid[])$$,'22023','invalid provisioning input','duplicate branches rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Target','staff',array['32000000-0000-4000-8000-000000000003']::uuid[])$$,'22023','invalid provisioning input','inactive branch rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Target','staff',array['32000000-0000-4000-8000-000000000004']::uuid[])$$,'22023','invalid provisioning input','cross-org branch rejected');
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12999999-0000-4000-8000-000000000999','Target','staff',array['32000000-0000-4000-8000-000000000001']::uuid[])$$,'23503','target profile missing','missing target profile rejected');

select lives_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000005','Provisioned Staff','staff',array['32000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000002']::uuid[])$$,'manager finalizes staff');
reset role;
select is((select full_name from public.profiles where id='12000000-0000-4000-8000-000000000005'),'Provisioned Staff','profile full name set');
select ok((select must_change_password and disabled_at is null from public.profiles where id='12000000-0000-4000-8000-000000000005'),'lifecycle fields set');
select is((select array_agg(branch_id order by branch_id) from public.branch_memberships where user_id='12000000-0000-4000-8000-000000000005'),array['32000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000002']::uuid[],'exact staff memberships');
select is((select count(*) from public.account_management_audit_logs where target_user_id='12000000-0000-4000-8000-000000000005' and action='user_created'),1::bigint,'one user_created audit');
select is((select count(*) from public.account_management_audit_logs where target_user_id='12000000-0000-4000-8000-000000000005' and action='branch_assignment_added'),2::bigint,'one branch audit per branch');
select ok(not exists(select 1 from public.account_management_audit_logs l cross join lateral jsonb_object_keys(l.details) k where l.target_user_id='12000000-0000-4000-8000-000000000005' and lower(k) ~ 'email|password|token|secret'),'audit allowlist contains no forbidden keys');

set local role service_role;
select lives_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000006','Provisioned Manager','branch_manager',array['32000000-0000-4000-8000-000000000001']::uuid[])$$,'manager finalizes branch manager');
reset role;
select is((select role from public.branch_memberships where user_id='12000000-0000-4000-8000-000000000006'),'branch_manager','branch manager membership created');

insert into public.branch_memberships(branch_id,user_id,role) values ('32000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000007','staff');
set local role service_role;
select throws_ok($$select public.finalize_provisioned_user('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000007','Must Roll Back','staff',array['32000000-0000-4000-8000-000000000001']::uuid[])$$,'23505',null,'membership failure aborts RPC');
reset role;
select ok((select full_name is null and not must_change_password from public.profiles where id='12000000-0000-4000-8000-000000000007') and not exists(select 1 from public.account_management_audit_logs where target_user_id='12000000-0000-4000-8000-000000000007'),'failure rolls back profile and audit changes');

reset role;
select * from finish();
rollback;
