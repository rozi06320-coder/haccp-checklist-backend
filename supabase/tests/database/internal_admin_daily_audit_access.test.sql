begin;
select plan(12);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000001'::uuid,
  '1e000000-0000-4000-8000-000000000002',
  '1e000000-0000-4000-8000-000000000003',
  '1e000000-0000-4000-8000-000000000004'
]) id;

update public.profiles set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1e000000-0000-4000-8000-000000000002' then 'Organization Manager'
  when '1e000000-0000-4000-8000-000000000003' then 'Supervisor'
  else 'Other Manager'
end, must_change_password = false
where id::text like '1e000000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1e000000-0000-4000-8000-000000000001', true);

insert into public.organizations(id,name,slug) values
 ('2e000000-0000-4000-8000-000000000001','Internal Audit Org','internal-audit-org'),
 ('2e000000-0000-4000-8000-000000000002','Other Internal Audit Org','other-internal-audit-org');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002','organization_manager'),
 ('2e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Audit Branch','AUDA','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003');

select ok(has_function_privilege('service_role','public.create_internal_admin_daily_audit_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer)','execute'),'service role can execute Internal Admin create RPC');
select ok(not has_function_privilege('authenticated','public.create_internal_admin_daily_audit_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer)','execute'),'authenticated cannot execute Internal Admin create RPC');

select lives_ok($$select * from public.create_internal_admin_daily_audit_access_user(
 '1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001',
 '  Audit Runner  ', decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'internal admin creates manual Daily Audit access user');
select is((select count(*) from public.list_internal_admin_daily_audit_access_users('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001') where display_name='Audit Runner' and active),1::bigint,'internal admin lists manual access users');
select throws_ok($$select * from public.create_internal_admin_daily_audit_access_user(
 '1e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001',
 'Bad Manager', decode(repeat('33',32),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','organization manager cannot use Internal Admin create RPC');
select throws_ok($$select * from public.create_internal_admin_daily_audit_access_user(
 '1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001',
 'Bad Supervisor', decode(repeat('33',32),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','supervisor cannot use Internal Admin create RPC');

select is((select count(*) from public.list_internal_admin_daily_audit_pins('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001') where manager_user_id='1e000000-0000-4000-8000-000000000002'),1::bigint,'internal admin lists organization manager PIN targets');
select lives_ok($$select * from public.store_internal_admin_daily_audit_pin(
 '1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002',
 decode(repeat('55',32),'hex'),decode(repeat('66',16),'hex'),decode(repeat('77',32),'hex'),1::smallint,16384,8,1)$$,'internal admin configures manager Daily Audit PIN');
select throws_ok($$select * from public.store_internal_admin_daily_audit_pin(
 '1e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002',
 decode(repeat('55',32),'hex'),decode(repeat('66',16),'hex'),decode(repeat('77',32),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','organization manager cannot configure manager PIN through Internal Admin RPC');
select ok(not exists(select 1 from private.organization_manager_daily_audit_pins where pin_hash=decode('123456','hex')),'plain PIN is not stored');

select lives_ok($$select * from public.revoke_internal_admin_daily_audit_access_user(
 '1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001',
 (select id from public.daily_audit_access_users where display_name='Audit Runner'))$$,'internal admin revokes manual access user');
select is((select count(*) from public.get_daily_audit_access_user_credentials('1e000000-0000-4000-8000-000000000003','3e000000-0000-4000-8000-000000000001')),0::bigint,'revoked PIN no longer unlocks');

select * from finish();
rollback;
