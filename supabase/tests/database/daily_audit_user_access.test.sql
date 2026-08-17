begin;
select plan(23);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1d000000-0000-4000-8000-000000000001'::uuid,
  '1d000000-0000-4000-8000-000000000002',
  '1d000000-0000-4000-8000-000000000003',
  '1d000000-0000-4000-8000-000000000004',
  '1d000000-0000-4000-8000-000000000005'
]) id;

update public.profiles set full_name = case id
  when '1d000000-0000-4000-8000-000000000001' then 'Audit Manager'
  when '1d000000-0000-4000-8000-000000000002' then 'Branch A Supervisor'
  when '1d000000-0000-4000-8000-000000000003' then 'Other Supervisor'
  when '1d000000-0000-4000-8000-000000000004' then 'Other Manager'
  else 'Branch B Supervisor'
end, must_change_password = false
where id::text like '1d000000-%';

insert into public.organizations(id,name,slug) values
 ('2d000000-0000-4000-8000-000000000001','Audit Access Org','audit-access-org'),
 ('2d000000-0000-4000-8000-000000000002','Other Audit Org','other-audit-org');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','organization_manager'),
 ('2d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Audit Branch A','AUDA','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000002','Other Audit Branch','OAUD','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001','Audit Branch B','AUDB','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','branch_manager'),
 ('3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000003','branch_manager'),
 ('3d000000-0000-4000-8000-000000000003','1d000000-0000-4000-8000-000000000005','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002'),
 ('4d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000003'),
 ('4d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000003','1d000000-0000-4000-8000-000000000005');

select ok(not has_table_privilege('authenticated','public.daily_audit_access_users','insert'),'authenticated cannot insert manual access users directly');
select ok(not has_table_privilege('authenticated','public.daily_audit_access_users','select'),'authenticated cannot select manual access users directly');
select ok(not has_function_privilege('authenticated','public.create_daily_audit_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer)','execute'),'authenticated cannot execute create RPC');
select ok(has_function_privilege('service_role','public.create_daily_audit_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer)','execute'),'service role can execute create RPC');
select is(
  (select count(*) from information_schema.columns where table_schema='public' and table_name='daily_audit_access_users' and column_name='branch_id'),
  0::bigint,
  'manual access users are organization-wide and have no branch_id'
);

select lives_ok($$select * from public.create_daily_audit_access_user(
 '1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001',
 '  Audit Runner  ', decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'manager creates organization-wide manual Daily Audit access user');
select is(
  (select display_name from public.daily_audit_access_users where organization_id='2d000000-0000-4000-8000-000000000001'),
  'Audit Runner',
  'display name is trimmed and normalized'
);
select is(
  (select count(*) from information_schema.columns where table_schema='public' and table_name='daily_audit_access_users' and column_name in ('pin','plain_pin','pin_plaintext')),
  0::bigint,
  'manual access table has no plaintext PIN column'
);
select is(
  (select octet_length(pin_hash) from public.daily_audit_access_users where organization_id='2d000000-0000-4000-8000-000000000001'),
  32,
  'PIN hash is stored as a fixed-length hash'
);
select is(
  (select count(*) from public.list_daily_audit_access_users('1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001') where display_name='Audit Runner' and active),
  1::bigint,
  'manager can list active organization-wide manual access users'
);
select is(
  pg_get_functiondef('public.list_daily_audit_access_users(uuid,uuid)'::regprocedure) ~ 'branch_id',
  false,
  'list result exposes no branch scope'
);
select is(
  (select count(*) from public.get_daily_audit_access_user_credentials('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000001') where display_name='Audit Runner'),
  1::bigint,
  'branch A supervisor can retrieve organization-wide access credentials'
);
select is(
  (select count(*) from public.get_daily_audit_access_user_credentials('1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000003') where display_name='Audit Runner'),
  1::bigint,
  'branch B supervisor in same organization can retrieve the same access credentials'
);
select is(
  (select count(*) from public.get_daily_audit_access_user_credentials('1d000000-0000-4000-8000-000000000003','3d000000-0000-4000-8000-000000000002')),
  0::bigint,
  'unrelated organization branch does not receive the access credential'
);
select throws_ok($$select * from public.create_daily_audit_access_user(
 '1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001',
 'Audit Runner', decode(repeat('33',32),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'23505','daily audit access user already exists','duplicate active name is rejected per organization');
select throws_ok($$select * from public.create_daily_audit_access_user(
 '1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001',
 'Short Hash', decode(repeat('33',31),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','invalid credential material is rejected');
select throws_ok($$select * from public.create_daily_audit_access_user(
 '1d000000-0000-4000-8000-000000000004','2d000000-0000-4000-8000-000000000001',
 'Bad Manager', decode(repeat('55',32),'hex'),decode(repeat('66',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','unrelated manager cannot create manual access user');
select throws_ok($$select * from public.create_daily_audit_access_user(
 '1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',
 'Supervisor Attempt', decode(repeat('77',32),'hex'),decode(repeat('88',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','supervisor cannot create manual access user');
select throws_ok($$select * from public.get_daily_audit_access_user_credentials('1d000000-0000-4000-8000-000000000003','3d000000-0000-4000-8000-000000000001')$$,'42501','access denied','other supervisor/team cannot read same-org manual credentials');
select throws_ok($$select * from public.get_daily_audit_access_user_credentials('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')$$,'42501','access denied','manager cannot use supervisor unlock credential RPC');

select lives_ok($$select * from public.revoke_daily_audit_access_user(
 '1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001',
 (select id from public.daily_audit_access_users where display_name='Audit Runner'))$$,'manager revokes manual access user');
select is(
  (select count(*) from public.daily_audit_access_users where display_name='Audit Runner' and active),
  0::bigint,
  'revoked manual access user is inactive'
);
select is(
  (select count(*) from public.get_daily_audit_access_user_credentials('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000001')),
  0::bigint,
  'revoked manual access PIN no longer participates in unlock verification'
);

select * from finish();
rollback;
