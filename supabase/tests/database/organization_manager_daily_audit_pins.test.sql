begin;
select plan(32);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '1a000000-0000-4000-8000-000000000001'::uuid,
  '1a000000-0000-4000-8000-000000000002',
  '1a000000-0000-4000-8000-000000000003',
  '1a000000-0000-4000-8000-000000000004',
  '1a000000-0000-4000-8000-000000000005'
]) id;
update public.profiles set full_name=case id
  when '1a000000-0000-4000-8000-000000000001' then 'Manager A'
  when '1a000000-0000-4000-8000-000000000002' then 'Manager B'
  when '1a000000-0000-4000-8000-000000000003' then 'Supervisor'
  when '1a000000-0000-4000-8000-000000000004' then 'Other Manager'
  else 'Staff' end;
insert into public.organizations(id,name,slug) values
  ('2a000000-0000-4000-8000-000000000001','Manager PIN Org A','manager-pin-org-a'),
  ('2a000000-0000-4000-8000-000000000002','Manager PIN Org B','manager-pin-org-b');
insert into public.branches(id,organization_id,name,code) values
  ('3a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','A One','MA1'),
  ('3a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','A Two','MA2'),
  ('3a000000-0000-4000-8000-000000000003','2a000000-0000-4000-8000-000000000002','B One','MB1');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001','organization_manager'),
  ('2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002','organization_manager'),
  ('2a000000-0000-4000-8000-000000000002','1a000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000003','branch_manager',true),
  ('3a000000-0000-4000-8000-000000000002','1a000000-0000-4000-8000-000000000003','branch_manager',true),
  ('3a000000-0000-4000-8000-000000000003','1a000000-0000-4000-8000-000000000005','staff',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,active) values
  ('5a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000003',true),
  ('5a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000002','1a000000-0000-4000-8000-000000000003',true);

select ok(not has_table_privilege('anon','private.organization_manager_daily_audit_pins','select'),'anon cannot read PIN credentials');
select ok(not has_table_privilege('authenticated','private.organization_manager_daily_audit_pins','select'),'authenticated cannot read PIN credentials');
select ok(not has_table_privilege('service_role','private.organization_manager_daily_audit_pins','select'),'service role has no direct table access');
select ok(not has_function_privilege('authenticated','public.store_organization_manager_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer)','execute'),'authenticated cannot set a Manager PIN');
select ok(has_function_privilege('service_role','public.store_organization_manager_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer)','execute'),'service role can call constrained PIN RPC');
select ok((select proconfig::text from pg_proc where oid='public.store_organization_manager_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer)'::regprocedure) like '%search_path=%','store RPC has fixed empty search path');
select ok((select relrowsecurity from pg_class where oid='private.organization_manager_daily_audit_pins'::regclass),'credential table has RLS enabled');

set local role service_role;
select lives_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001',
  decode(repeat('11',32),'hex'),decode(repeat('12',16),'hex'),decode(repeat('13',32),'hex'),1::smallint,16384,8,1)$$,'Manager A PIN is configured');
select lives_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002',
  decode(repeat('21',32),'hex'),decode(repeat('22',16),'hex'),decode(repeat('23',32),'hex'),1::smallint,16384,8,1)$$,'Manager B has a distinct PIN');
select throws_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002',
  decode(repeat('31',32),'hex'),decode(repeat('32',16),'hex'),decode(repeat('13',32),'hex'),1::smallint,16384,8,1)$$,'23505',null,'duplicate active PIN fingerprint is rejected within one organization');
select lives_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000004','2a000000-0000-4000-8000-000000000002','1a000000-0000-4000-8000-000000000004',
  decode(repeat('41',32),'hex'),decode(repeat('42',16),'hex'),decode(repeat('13',32),'hex'),1::smallint,16384,8,1)$$,'same PIN fingerprint is allowed in another organization');
select throws_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000004','2a000000-0000-4000-8000-000000000002','1a000000-0000-4000-8000-000000000001',
  decode(repeat('51',32),'hex'),decode(repeat('52',16),'hex'),decode(repeat('53',32),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','cross-organization target is rejected');
select throws_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000003','2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001',
  decode(repeat('51',32),'hex'),decode(repeat('52',16),'hex'),decode(repeat('53',32),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','Branch Supervisor cannot configure a PIN');
select throws_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000005','2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001',
  decode(repeat('51',32),'hex'),decode(repeat('52',16),'hex'),decode(repeat('53',32),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','legacy Staff cannot configure a PIN');
select is((select count(*) from public.list_organization_manager_daily_audit_pins('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001')),2::bigint,'Manager metadata list is organization-scoped');
select is((select count(*) from public.get_organization_manager_daily_audit_credentials('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000001')),2::bigint,'both Manager PINs can authorize branch one');
select is((select display_name from public.get_organization_manager_daily_audit_credentials('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000001') where manager_user_id='1a000000-0000-4000-8000-000000000001'),'Manager A','credential resolver returns the safe Manager display name');
select is((select count(*) from public.get_organization_manager_daily_audit_credentials('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000002')),2::bigint,'the same Manager PINs can authorize branch two');
select throws_ok($$select * from public.get_organization_manager_daily_audit_credentials('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000003')$$,'42501','access denied','PIN cannot be requested across organization or team scope');
reset role;

select is((select count(*) from private.organization_manager_daily_audit_pins where organization_id='2a000000-0000-4000-8000-000000000001'),2::bigint,'one credential row exists per Manager and organization');
select ok(not exists(select 1 from information_schema.columns where table_schema='private' and table_name='organization_manager_daily_audit_pins' and column_name in ('pin','plaintext_pin')),'no plaintext PIN column exists');
select is((select count(*) from public.account_management_audit_logs where organization_id='2a000000-0000-4000-8000-000000000001' and action='daily_audit_pin_configured'),2::bigint,'successful configurations audit exactly once each');
select ok(not exists(select 1 from public.account_management_audit_logs log cross join lateral jsonb_object_keys(log.details) key where log.organization_id='2a000000-0000-4000-8000-000000000001' and lower(key) ~ 'pin|hash|salt|fingerprint'),'audit details contain no PIN material');
create temporary table pin_versions as select manager_user_id,credential_version from private.organization_manager_daily_audit_pins where organization_id='2a000000-0000-4000-8000-000000000001';
grant select on table pin_versions to service_role;
set local role service_role;
select lives_ok($$select * from public.store_organization_manager_daily_audit_pin(
  '1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001',
  decode(repeat('61',32),'hex'),decode(repeat('62',16),'hex'),decode(repeat('63',32),'hex'),1::smallint,16384,8,1)$$,'Manager A PIN can be replaced');
reset role;
select isnt((select credential_version from private.organization_manager_daily_audit_pins where organization_id='2a000000-0000-4000-8000-000000000001' and manager_user_id='1a000000-0000-4000-8000-000000000001'),(select credential_version from pin_versions where manager_user_id='1a000000-0000-4000-8000-000000000001'),'replacement rotates only Manager A credential version');
select is((select credential_version from private.organization_manager_daily_audit_pins where organization_id='2a000000-0000-4000-8000-000000000001' and manager_user_id='1a000000-0000-4000-8000-000000000002'),(select credential_version from pin_versions where manager_user_id='1a000000-0000-4000-8000-000000000002'),'Manager B credential version remains unchanged');
set local role service_role;
select is(public.validate_organization_manager_daily_audit_grant('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001',(select credential_version from pin_versions where manager_user_id='1a000000-0000-4000-8000-000000000001')),false,'old Manager A grant is invalid after rotation');
select is(public.validate_organization_manager_daily_audit_grant('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002',(select credential_version from pin_versions where manager_user_id='1a000000-0000-4000-8000-000000000002')),true,'Manager B grant remains valid');
select lives_ok($$select * from public.record_organization_manager_daily_audit_access_grant('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002',(select credential_version from pin_versions where manager_user_id='1a000000-0000-4000-8000-000000000002'))$$,'authorized access grant is atomically audited');
reset role;
select is((select count(*) from public.account_management_audit_logs where organization_id='2a000000-0000-4000-8000-000000000001' and action='daily_audit_access_granted'),1::bigint,'access grant audit is written exactly once');
select ok(pg_get_functiondef('public.get_organization_manager_daily_audit_credentials(uuid,uuid)'::regprocedure) !~ 'daily_audit_pin_credentials','legacy branch PIN table is not accepted by active credential RPC');
update public.profiles set disabled_at=now() where id='1a000000-0000-4000-8000-000000000002';
set local role service_role;
select is((select count(*) from public.get_organization_manager_daily_audit_credentials('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000001') where manager_user_id='1a000000-0000-4000-8000-000000000002'),0::bigint,'disabled Manager credential is immediately invalid');

select * from finish();
rollback;
