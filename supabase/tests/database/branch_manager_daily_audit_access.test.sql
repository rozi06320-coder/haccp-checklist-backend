begin;
select plan(23);
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
'15000000-0000-4000-8000-000000000001'::uuid,'15000000-0000-4000-8000-000000000002',
'15000000-0000-4000-8000-000000000003','15000000-0000-4000-8000-000000000004']) id;
update public.profiles set full_name=case id when '15000000-0000-4000-8000-000000000001' then 'Staff' when '15000000-0000-4000-8000-000000000002' then 'Branch Manager' when '15000000-0000-4000-8000-000000000003' then 'Org Manager' else 'Other Manager' end;
insert into public.organizations(id,name,slug) values
('25000000-0000-4000-8000-000000000001','PIN Org A','pin-org-a'),
('25000000-0000-4000-8000-000000000002','PIN Org B','pin-org-b');
insert into public.branches(id,organization_id,name,code) values
('35000000-0000-4000-8000-000000000001','25000000-0000-4000-8000-000000000001','A One','A1'),
('35000000-0000-4000-8000-000000000002','25000000-0000-4000-8000-000000000001','A Two','A2'),
('35000000-0000-4000-8000-000000000003','25000000-0000-4000-8000-000000000002','B One','B1');
insert into public.branches(id,organization_id,name,code,active) values
('35000000-0000-4000-8000-000000000004','25000000-0000-4000-8000-000000000001','Inactive','AI',false);
insert into public.branch_memberships(branch_id,user_id,role) values
('35000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000001','staff'),
('35000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000002','branch_manager'),
('35000000-0000-4000-8000-000000000003','15000000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
('35000000-0000-4000-8000-000000000004','15000000-0000-4000-8000-000000000001','staff');
insert into public.organization_memberships values
('25000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000003','organization_manager',now(),now());
insert into public.branch_shifts(id,organization_id,branch_id,name,start_time,end_time) values
('45000000-0000-4000-8000-000000000001','25000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001','Supervisor Shift','08:00','16:00');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,shift_id) values
('55000000-0000-4000-8000-000000000001','25000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000002','45000000-0000-4000-8000-000000000001');
select ok(not has_table_privilege('anon','private.daily_audit_pin_credentials','select'),'anon cannot read');
select ok(not has_table_privilege('authenticated','private.daily_audit_pin_credentials','select'),'authenticated cannot read');
select ok(not has_table_privilege('service_role','private.daily_audit_pin_credentials','select'),'service role has no table select');
select ok(not has_function_privilege('authenticated','public.store_daily_audit_pin(uuid,uuid,bytea,bytea,smallint,integer,integer,integer)','execute'),'authenticated cannot call store');
select ok(has_function_privilege('service_role','public.store_daily_audit_pin(uuid,uuid,bytea,bytea,smallint,integer,integer,integer)','execute'),'service role can execute');
set local role service_role;
select throws_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001',decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'42501','branch access denied','staff cannot configure');
select throws_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000002','35000000-0000-4000-8000-000000000002',decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'42501','branch access denied','branch manager denied other same-org branch');
select throws_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000002','35000000-0000-4000-8000-000000000003',decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'42501','branch access denied','cross-org denied');
select throws_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000002','35000000-0000-4000-8000-000000000001',decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'42501','branch access denied','Branch Supervisor cannot configure');
select lives_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000003','35000000-0000-4000-8000-000000000001',decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'organization manager configures');
select lives_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000003','35000000-0000-4000-8000-000000000002',decode(repeat('33',32),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'org manager configures managed branch');
select throws_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000003','35000000-0000-4000-8000-000000000003',decode(repeat('33',32),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'42501','branch access denied','org manager denied other org');
select throws_ok($$select * from public.get_daily_audit_pin_metadata('15000000-0000-4000-8000-000000000002','35000000-0000-4000-8000-000000000001')$$,'42501','branch access denied','Branch Supervisor cannot read configuration metadata');
select ok(pg_get_function_result('public.get_daily_audit_pin_metadata(uuid,uuid)'::regprocedure) !~* 'hash|salt|kdf','metadata has no credential material');
reset role;
select ok(not exists(select 1 from public.account_management_audit_logs l cross join lateral jsonb_object_keys(l.details) k where l.organization_id='25000000-0000-4000-8000-000000000001' and l.action like 'daily_audit_pin_%' and lower(k) ~ 'pin|hash|salt|kdf'),'audit details safe');
select is((select count(*) from public.account_management_audit_logs where organization_id='25000000-0000-4000-8000-000000000001' and action='daily_audit_pin_configured'),2::bigint,'configured audits written');
create temporary table prior_pin_version as select credential_version from private.daily_audit_pin_credentials where branch_id='35000000-0000-4000-8000-000000000001';
set local role service_role;
select lives_ok($$select * from public.store_daily_audit_pin('15000000-0000-4000-8000-000000000003','35000000-0000-4000-8000-000000000001',decode(repeat('55',32),'hex'),decode(repeat('66',16),'hex'),1::smallint,16384,8,1)$$,'manager replacement works');
reset role;
select is((select count(*) from public.account_management_audit_logs where organization_id='25000000-0000-4000-8000-000000000001' and action='daily_audit_pin_replaced'),1::bigint,'replacement audited');
select isnt((select credential_version from private.daily_audit_pin_credentials where branch_id='35000000-0000-4000-8000-000000000001'),(select credential_version from prior_pin_version),'replacement rotates credential version');
set local role service_role;
select throws_ok($$insert into public.account_management_audit_logs(organization_id,action) values('25000000-0000-4000-8000-000000000001','daily_audit_pin_read')$$,'23514',null,'invalid audit action rejected');
select is((select count(*) from public.list_supervised_branch_staff('15000000-0000-4000-8000-000000000002','35000000-0000-4000-8000-000000000001')),2::bigint,'staff listing scoped');
select is((select count(*) from public.get_daily_audit_pin_credential('15000000-0000-4000-8000-000000000002','35000000-0000-4000-8000-000000000001')),1::bigint,'assigned Branch Supervisor may verify');
select throws_ok($$select * from public.get_daily_audit_pin_credential('15000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001')$$,'42501','branch access denied','legacy Staff cannot verify');
reset role;
select * from finish();
rollback;
