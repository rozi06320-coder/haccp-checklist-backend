begin;
select plan(24);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000001'::uuid,
  '1e000000-0000-4000-8000-000000000002',
  '1e000000-0000-4000-8000-000000000003'
]) id;

update public.profiles set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Maintenance Manager'
  when '1e000000-0000-4000-8000-000000000002' then 'Other Manager'
  else 'Branch Supervisor'
end, must_change_password = false
where id::text like '1e000000-%';

insert into public.organizations(id,name,slug) values
 ('2e000000-0000-4000-8000-000000000001','Maintenance Org','maintenance-org'),
 ('2e000000-0000-4000-8000-000000000002','Other Maintenance Org','other-maintenance-org');

insert into public.organization_memberships(organization_id,user_id,role) values
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','organization_manager'),
 ('2e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002','organization_manager');

insert into public.branches(id,organization_id,name,code,timezone) values
 ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Maintenance Branch','MAINT','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003','branch_manager');

select ok(not has_table_privilege('authenticated','public.maintenance_access_users','insert'),'authenticated cannot insert maintenance access users directly');
select ok(not has_table_privilege('authenticated','public.maintenance_access_users','select'),'authenticated cannot select maintenance access users directly');
select ok(not has_function_privilege('authenticated','public.create_maintenance_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer)','execute'),'authenticated cannot execute create RPC');
select ok(not has_function_privilege('authenticated','public.get_maintenance_access_user_credentials(text,text)','execute'),'authenticated cannot execute credential lookup RPC');
select ok(has_function_privilege('service_role','public.create_maintenance_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer)','execute'),'service role can execute create RPC');
select is(
  (select count(*) from information_schema.columns where table_schema='public' and table_name='maintenance_access_users' and column_name='branch_id'),
  0::bigint,
  'maintenance access users are organization-wide and have no branch_id'
);

select lives_ok($$select * from public.create_maintenance_access_user(
 '1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001',
 '  Maintenance Tech  ', decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1::smallint,16384,8,1)$$,'manager creates organization-wide maintenance access user');
select is(
  (select display_name from public.maintenance_access_users where organization_id='2e000000-0000-4000-8000-000000000001'),
  'Maintenance Tech',
  'display name is trimmed and normalized'
);
select is(
  (select count(*) from information_schema.columns where table_schema='public' and table_name='maintenance_access_users' and column_name in ('pin','password','plain_pin','plain_password','credential_plaintext')),
  0::bigint,
  'maintenance access table has no plaintext credential column'
);
select is(
  (select octet_length(pin_hash) from public.maintenance_access_users where organization_id='2e000000-0000-4000-8000-000000000001'),
  32,
  'credential hash is stored as a fixed-length hash'
);
select is(
  (select count(*) from public.list_maintenance_access_users('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001') where display_name='Maintenance Tech' and active),
  1::bigint,
  'manager can list active organization-wide maintenance access users'
);
select is(
  (select count(*) from public.get_maintenance_access_user_credentials('maintenance-org','Maintenance Tech') where organization_id='2e000000-0000-4000-8000-000000000001' and display_name='Maintenance Tech'),
  1::bigint,
  'credential lookup supports active users by organization slug and name'
);
select is(
  (select count(*) from public.get_maintenance_access_user_credentials('Maintenance Org','Maintenance Tech') where organization_id='2e000000-0000-4000-8000-000000000001'),
  1::bigint,
  'credential lookup supports organization name'
);
select is(
  (select count(*) from public.get_maintenance_access_user_credentials('other-maintenance-org','Maintenance Tech')),
  0::bigint,
  'credential lookup does not cross organization boundaries'
);
select is(
  (select count(*) from public.validate_maintenance_access_grant(
    '2e000000-0000-4000-8000-000000000001',
    (select id from public.maintenance_access_users where display_name='Maintenance Tech'),
    (select credential_version from public.maintenance_access_users where display_name='Maintenance Tech')
  )),
  1::bigint,
  'signed grant validation returns active user context'
);
select is(
  (select count(*) from public.validate_maintenance_access_grant(
    '2e000000-0000-4000-8000-000000000001',
    (select id from public.maintenance_access_users where display_name='Maintenance Tech'),
    '4e000000-0000-4000-8000-000000000099'
  )),
  0::bigint,
  'signed grant validation rejects mismatched credential version'
);
select throws_ok($$select * from public.create_maintenance_access_user(
 '1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001',
 'Maintenance Tech', decode(repeat('33',32),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'23505','maintenance access user already exists','duplicate active name is rejected per organization');
select throws_ok($$select * from public.create_maintenance_access_user(
 '1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001',
 'Short Hash', decode(repeat('33',31),'hex'),decode(repeat('44',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','invalid credential material is rejected');
select throws_ok($$select * from public.create_maintenance_access_user(
 '1e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001',
 'Bad Manager', decode(repeat('55',32),'hex'),decode(repeat('66',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','unrelated manager cannot create maintenance access user');
select throws_ok($$select * from public.create_maintenance_access_user(
 '1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001',
 'Supervisor Attempt', decode(repeat('77',32),'hex'),decode(repeat('88',16),'hex'),1::smallint,16384,8,1)$$,'42501','access denied','supervisor cannot create maintenance access user');

select lives_ok($$select * from public.deactivate_maintenance_access_user(
 '1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001',
 (select id from public.maintenance_access_users where display_name='Maintenance Tech'))$$,'manager deactivates maintenance access user');
select is(
  (select count(*) from public.maintenance_access_users where display_name='Maintenance Tech' and active),
  0::bigint,
  'deactivated maintenance access user is inactive'
);
select is(
  (select count(*) from public.get_maintenance_access_user_credentials('maintenance-org','Maintenance Tech')),
  0::bigint,
  'deactivated user is not returned for credential verification'
);
select is(
  (select count(*) from public.validate_maintenance_access_grant(
    '2e000000-0000-4000-8000-000000000001',
    (select id from public.maintenance_access_users where display_name='Maintenance Tech'),
    (select credential_version from public.maintenance_access_users where display_name='Maintenance Tech')
  )),
  0::bigint,
  'deactivated user cannot keep using an existing maintenance session'
);

select * from finish();
rollback;
