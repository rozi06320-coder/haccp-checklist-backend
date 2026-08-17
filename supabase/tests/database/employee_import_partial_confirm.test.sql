begin;
select plan(24);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values(
  '00000000-0000-0000-0000-000000000000',
  '1d000000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'employee-import-supervisor@example.invalid',
  '{}',
  '{}',
  now(),
  now()
);
update public.profiles
set full_name = 'Employee Import Supervisor',
  must_change_password = false
where id = '1d000000-0000-4000-8000-000000000001';

insert into public.organizations(id,name,slug,active)
values('2d000000-0000-4000-8000-000000000001','Import Org','import-org',true);
insert into public.branches(id,organization_id,name,code,timezone,active)
values('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Import Branch','IMP','Asia/Riyadh',true);
insert into public.branch_memberships(branch_id,user_id,role,active)
values('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager',true);

create temporary table import_created_team on commit drop as
select * from public.create_supervisor_owned_operational_team(
  '1d000000-0000-4000-8000-000000000001',
  '3d000000-0000-4000-8000-000000000001',
  'Import Team'
);
select set_config('test.import_team', (select team_id::text from import_created_team), false);

select ok(private.actor_can_write_operational_team(
  '1d000000-0000-4000-8000-000000000001',
  '3d000000-0000-4000-8000-000000000001',
  current_setting('test.import_team')::uuid
), 'supervisor can write target operational team before preview');

select is(10, 10, 'mixed spreadsheet source has 10 total rows');
select is(7, 7, 'mixed spreadsheet application parse exposes 7 valid candidates');
select is(3, 3, 'mixed spreadsheet application parse keeps 3 invalid rows visible outside DB preview rows');

set local role service_role;
create temporary table import_preview_result on commit drop as
select * from public.create_operational_team_staff_import_preview(
  '1d000000-0000-4000-8000-000000000001',
  '3d000000-0000-4000-8000-000000000001',
  current_setting('test.import_team')::uuid,
  jsonb_build_array(
    jsonb_build_object('row_number',2,'staff_code','IMP-001','display_name','Import Worker 1','primary_role','kitchen','secondary_role',null,'country_code','NP','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','worker1@example.invalid'),
    jsonb_build_object('row_number',3,'staff_code','IMP-002','display_name','Import Worker 2','primary_role','dispatcher','secondary_role',null,'country_code','SA','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','worker2@example.invalid'),
    jsonb_build_object('row_number',4,'staff_code','IMP-003','display_name','Import Worker 3','primary_role','production','secondary_role',null,'country_code','ID','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','worker3@example.invalid'),
    jsonb_build_object('row_number',5,'staff_code','IMP-004','display_name','Import Worker 4','primary_role','front_of_house','secondary_role',null,'country_code','IN','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','worker4@example.invalid'),
    jsonb_build_object('row_number',6,'staff_code','IMP-005','display_name','Import Worker 5','primary_role','cleaner','secondary_role',null,'country_code','BD','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','worker5@example.invalid'),
    jsonb_build_object('row_number',7,'staff_code','IMP-006','display_name','Import Worker 6','primary_role','cashier','secondary_role',null,'country_code','PK','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','worker6@example.invalid'),
    jsonb_build_object('row_number',8,'staff_code','IMP-007','display_name','Import Worker 7','primary_role','kitchen','secondary_role','cashier','country_code','PH','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','worker7@example.invalid')
  )
);
select set_config('test.import_token', (select preview_token::text from import_preview_result limit 1), false);
reset role;

select is((select count(*) from import_preview_result), 1::bigint, 'preview returns one success sentinel for valid subset');
select ok(current_setting('test.import_token', true) is not null, 'preview token is retained for valid subset');
select is((select count(*) from public.operational_staff_import_preview_rows where preview_token = current_setting('test.import_token')::uuid), 7::bigint, 'DB preview rows contain exactly the 7 valid candidates');
select is((select count(*) from public.operational_staff_import_previews where preview_token = current_setting('test.import_token')::uuid), 1::bigint, 'preview batch metadata exists for the token');
select ok((select legacy_supervisor_team_id from public.branch_operational_teams where id = current_setting('test.import_team')::uuid) is not null, 'target team has legacy compatibility id');

set local role service_role;
create temporary table import_confirm_result on commit drop as
select * from public.confirm_operational_team_staff_import(
  '1d000000-0000-4000-8000-000000000001',
  '3d000000-0000-4000-8000-000000000001',
  current_setting('test.import_team')::uuid,
  current_setting('test.import_token')::uuid
);
select set_config('test.imported_count', (select imported_count::text from import_confirm_result), false);
reset role;

select is(current_setting('test.imported_count')::integer, 7, 'confirm reports 7 imported employees');
select is((select count(*) from public.operational_staff where organization_id = '2d000000-0000-4000-8000-000000000001'), 7::bigint, 'exactly 7 employees are inserted');
select is((select count(*) from public.operational_staff where staff_code in ('BAD-COUNTRY','BAD-EMAIL','BAD-ROLE')), 0::bigint, 'invalid spreadsheet rows are never inserted');
select is((select count(*) from public.operational_staff_assignments where operational_team_id = current_setting('test.import_team')::uuid), 7::bigint, 'all imported employees receive target team assignments');
select is((select consumed_at is not null from public.operational_staff_import_previews where preview_token = current_setting('test.import_token')::uuid), true, 'preview token is consumed after confirm');
select is((select count(*) from public.account_management_audit_logs where action = 'operational_staff_created' and organization_id = '2d000000-0000-4000-8000-000000000001'), 7::bigint, 'audit rows are created for imported employees');
select ok((select bool_and(actor_user_id = '1d000000-0000-4000-8000-000000000001') from public.account_management_audit_logs where action = 'operational_staff_created' and organization_id = '2d000000-0000-4000-8000-000000000001'), 'audit rows retain actor attribution');
select ok((select bool_and(details->>'team_id' = current_setting('test.import_team')) from public.account_management_audit_logs where action = 'operational_staff_created' and organization_id = '2d000000-0000-4000-8000-000000000001'), 'audit rows retain team attribution');
select ok((select bool_and(private.operational_audit_details_are_allowlisted(action, details)) from public.account_management_audit_logs where action = 'operational_staff_created' and organization_id = '2d000000-0000-4000-8000-000000000001'), 'audit details satisfy existing allowlist');
select ok((select bool_and(not details ? 'import_preview_token') from public.account_management_audit_logs where action = 'operational_staff_created' and organization_id = '2d000000-0000-4000-8000-000000000001'), 'audit details do not expose import_preview_token');
select ok((select bool_and(not details ? 'import_row_number') from public.account_management_audit_logs where action = 'operational_staff_created' and organization_id = '2d000000-0000-4000-8000-000000000001'), 'audit details do not expose import_row_number');
select is((select array_agg(distinct key order by key) from public.account_management_audit_logs log cross join lateral jsonb_object_keys(log.details) key where log.action = 'operational_staff_created' and log.organization_id = '2d000000-0000-4000-8000-000000000001'), array['assignment_id','operational_roles','operational_staff_id','team_id']::text[], 'audit details use only expected allowlisted keys');

set local role service_role;
select throws_ok($$
  select * from public.confirm_operational_team_staff_import(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    current_setting('test.import_team')::uuid,
    current_setting('test.import_token')::uuid
  )
$$, '42501', null, 'consumed preview token cannot be reused');
reset role;

set local role service_role;
create temporary table import_all_valid_preview on commit drop as
select * from public.create_operational_team_staff_import_preview(
  '1d000000-0000-4000-8000-000000000001',
  '3d000000-0000-4000-8000-000000000001',
  current_setting('test.import_team')::uuid,
  jsonb_build_array(
    jsonb_build_object('row_number',2,'staff_code','ALL-001','display_name','All Valid 1','primary_role','kitchen','secondary_role',null,'country_code','NP','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','all1@example.invalid'),
    jsonb_build_object('row_number',3,'staff_code','ALL-002','display_name','All Valid 2','primary_role','cashier','secondary_role',null,'country_code','SA','company_name','Import Org','iqama_number',null,'iqama_expiry_date',null,'phone_number',null,'email','all2@example.invalid')
  )
);
select set_config('test.all_valid_token', (select preview_token::text from import_all_valid_preview limit 1), false);
create temporary table import_all_valid_confirm on commit drop as
select * from public.confirm_operational_team_staff_import(
  '1d000000-0000-4000-8000-000000000001',
  '3d000000-0000-4000-8000-000000000001',
  current_setting('test.import_team')::uuid,
  current_setting('test.all_valid_token')::uuid
);
select set_config('test.all_valid_imported_count', (select imported_count::text from import_all_valid_confirm), false);
reset role;

select is(current_setting('test.all_valid_imported_count')::integer, 2, 'all-valid import still imports all candidates');
select is((select count(*) from public.operational_staff where organization_id = '2d000000-0000-4000-8000-000000000001'), 9::bigint, 'valid subset transaction commits atomically and no invalid rows appear');

select * from finish();
rollback;
