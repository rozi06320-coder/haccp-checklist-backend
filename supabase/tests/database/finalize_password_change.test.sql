begin;
select plan(22);

insert into auth.users (instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
       id::text || '@example.invalid', '{"provider":"email","providers":["email"]}', '{}', now(), now()
from pg_catalog.unnest(array[
  '14000000-0000-4000-8000-000000000001'::uuid,
  '14000000-0000-4000-8000-000000000002',
  '14000000-0000-4000-8000-000000000003',
  '14000000-0000-4000-8000-000000000004',
  '14000000-0000-4000-8000-000000000005',
  '14000000-0000-4000-8000-000000000006',
  '14000000-0000-4000-8000-000000000007'
]) id;
update public.profiles set must_change_password = true
where id in (
  '14000000-0000-4000-8000-000000000001',
  '14000000-0000-4000-8000-000000000002',
  '14000000-0000-4000-8000-000000000003',
  '14000000-0000-4000-8000-000000000005',
  '14000000-0000-4000-8000-000000000006',
  '14000000-0000-4000-8000-000000000007'
);
update public.profiles set disabled_at = now()
where id = '14000000-0000-4000-8000-000000000002';

insert into public.organizations(id,name,slug) values
 ('24000000-0000-4000-8000-000000000001','Password Org A','password-org-a'),
 ('24000000-0000-4000-8000-000000000002','Password Org B','password-org-b');
insert into public.branches(id,organization_id,name,code) values
 ('34000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001','A1','PW-A1'),
 ('34000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000001','A2','PW-A2'),
 ('34000000-0000-4000-8000-000000000003','24000000-0000-4000-8000-000000000002','B1','PW-B1');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000003','staff'),
 ('34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000005','staff'),
 ('34000000-0000-4000-8000-000000000002','14000000-0000-4000-8000-000000000005','branch_manager'),
 ('34000000-0000-4000-8000-000000000003','14000000-0000-4000-8000-000000000005','staff'),
 ('34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000006','staff');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('24000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000004','organization_manager');
insert into public.maintenance_memberships(organization_id,user_id,active,created_by) values
 ('24000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000007',true,'14000000-0000-4000-8000-000000000004');

select ok(not has_function_privilege('public','public.finalize_password_change(uuid)','execute'),'PUBLIC denied');
select ok(not has_function_privilege('anon','public.finalize_password_change(uuid)','execute'),'anon denied');
select ok(not has_function_privilege('authenticated','public.finalize_password_change(uuid)','execute'),'authenticated denied');
select ok(has_function_privilege('service_role','public.finalize_password_change(uuid)','execute'),'service_role only execute');

set local role service_role;
select throws_ok($$select public.finalize_password_change('14999999-0000-4000-8000-000000000999')$$,'42501','password change finalization denied','missing profile rejected');
select throws_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000002')$$,'42501','password change finalization denied','disabled profile rejected');
select throws_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000004')$$,'42501','password change finalization denied','false lifecycle flag rejected');
select throws_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000001')$$,'42501','password change finalization denied','user without membership rejected');
select lives_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000003')$$,'branch member succeeds');
reset role;
update public.profiles set must_change_password=true where id='14000000-0000-4000-8000-000000000004';
set local role service_role;
select lives_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000004')$$,'organization manager succeeds');
select lives_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000005')$$,'multiple-organization member succeeds');
select lives_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000007')$$,'maintenance member succeeds');
reset role;

select ok(not (select must_change_password from public.profiles where id='14000000-0000-4000-8000-000000000003'),'flag becomes false');
select is((select count(*) from public.account_management_audit_logs where target_user_id='14000000-0000-4000-8000-000000000003' and action='password_changed'),1::bigint,'branch member gets one audit');
select is((select count(*) from public.account_management_audit_logs where target_user_id='14000000-0000-4000-8000-000000000004' and action='password_changed'),1::bigint,'manager gets one audit');
select is((select count(*) from public.account_management_audit_logs where target_user_id='14000000-0000-4000-8000-000000000005' and organization_id='24000000-0000-4000-8000-000000000001'),1::bigint,'multiple branches do not duplicate organization audit');
select is((select count(*) from public.account_management_audit_logs where target_user_id='14000000-0000-4000-8000-000000000005' and action='password_changed'),2::bigint,'multiple organizations get unique attributed audits');
select ok(not (select must_change_password from public.profiles where id='14000000-0000-4000-8000-000000000007'),'maintenance flag becomes false');
select is((select count(*) from public.account_management_audit_logs where target_user_id='14000000-0000-4000-8000-000000000007' and action='password_changed'),1::bigint,'maintenance member gets one audit');
select ok(not exists(select 1 from public.account_management_audit_logs log cross join lateral pg_catalog.jsonb_object_keys(log.details) key where log.action='password_changed' and pg_catalog.lower(key) ~ 'email|password|token|secret'),'audit has no sensitive keys');

create function pg_temp.reject_password_audit()
returns trigger language plpgsql as $$ begin raise exception 'forced audit failure'; end $$;
create trigger reject_password_audit before insert on public.account_management_audit_logs
for each row when (new.target_user_id = '14000000-0000-4000-8000-000000000006') execute function pg_temp.reject_password_audit();
set local role service_role;
select throws_ok($$select public.finalize_password_change('14000000-0000-4000-8000-000000000006')$$,'P0001','forced audit failure','audit failure aborts RPC');
reset role;
select ok((select must_change_password from public.profiles where id='14000000-0000-4000-8000-000000000006') and not exists(select 1 from public.account_management_audit_logs where target_user_id='14000000-0000-4000-8000-000000000006'),'failure rolls back flag and audit');

select * from finish();
rollback;
