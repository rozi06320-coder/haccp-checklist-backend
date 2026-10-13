begin;
select plan(22);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values(
  '00000000-0000-0000-0000-000000000000',
  '7a100000-0000-4000-8000-000000000001',
  'authenticated','authenticated','training-validity@example.invalid','{}','{}',now(),now()
);
update public.profiles
set full_name='Training Validity Supervisor', must_change_password=false
where id='7a100000-0000-4000-8000-000000000001';

insert into public.organizations(id,name,slug)
values('7a200000-0000-4000-8000-000000000001','Training Validity Org','training-validity-org');
insert into public.branches(id,organization_id,name,code,timezone,active)
values('7a300000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','Training Validity Branch','TVB','Asia/Riyadh',true);
insert into public.branch_memberships(branch_id,user_id,role,active)
values('7a300000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001','branch_manager',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,active)
values('7a400000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001',true);
select set_config('test.training_validity_team',(
  select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='7a400000-0000-4000-8000-000000000001'
),false);
insert into public.branch_training_access(
  organization_id,branch_id,enabled,pin_hash,salt,kdf_version,cost,block_size,parallelization,credential_version,updated_by
)
values(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001',true,
  decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1,16384,8,1,
  '7a600000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001'
);

insert into public.operational_staff(
  id,organization_id,branch_id,display_name,employment_status,created_by,staff_code,deactivated_at,deactivated_by
)
values
  ('7a700000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','Current Training Employee','active','7a100000-0000-4000-8000-000000000001','TV-1',null,null),
  ('7a700000-0000-4000-8000-000000000002','7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','Inactive Training Employee','inactive','7a100000-0000-4000-8000-000000000001','TV-2',now(),'7a100000-0000-4000-8000-000000000001');

insert into public.operational_staff_assignments(
  id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,
  operational_roles,active,valid_from,valid_to
)
values
  ('7a800000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001',current_setting('test.training_validity_team')::uuid,array['kitchen'],true,private.phase4a_business_date('Asia/Riyadh'),null),
  ('7a800000-0000-4000-8000-000000000002','7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000002','7a400000-0000-4000-8000-000000000001',current_setting('test.training_validity_team')::uuid,array['kitchen'],false,private.phase4a_business_date('Asia/Riyadh')-1,private.phase4a_business_date('Asia/Riyadh')-1);

-- Production integrity requires active assignments to have valid_to NULL. Drop
-- that check only inside this rolled-back test transaction to exercise the RPC's
-- defensive inclusive valid_to boundary and expired-row behavior directly.
alter table public.operational_staff_assignments
  drop constraint operational_staff_assignments_active_dates_check;

select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),1::bigint,
  'current valid assignment is listed');
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),1::bigint,
  'valid_to NULL is accepted');
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),1::bigint,
  'valid_from equal to branch business date is accepted');

update public.operational_staff_assignments
set valid_from=private.phase4a_business_date('Asia/Riyadh')+1
where id='7a800000-0000-4000-8000-000000000001';
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),0::bigint,
  'future assignment is excluded');
select is((select count(*) from public.validate_training_branch_employee(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001'
)),0::bigint,'employee selection validation rejects a future assignment');

update public.operational_staff_assignments
set valid_from=private.phase4a_business_date('Asia/Riyadh'),
    valid_to=private.phase4a_business_date('Asia/Riyadh')
where id='7a800000-0000-4000-8000-000000000001';
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),1::bigint,
  'valid_to equal to branch business date is accepted');

update public.operational_staff_assignments
set valid_from=private.phase4a_business_date('Asia/Riyadh')-2,
    valid_to=private.phase4a_business_date('Asia/Riyadh')-1
where id='7a800000-0000-4000-8000-000000000001';
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),0::bigint,
  'expired assignment is excluded');
select is((select count(*) from public.validate_training_branch_employee(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001'
)),0::bigint,'employee selection validation rejects an expired assignment');
select is((select count(*) from public.validate_training_branch_employee(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001'
)),0::bigint,'employee-bound session revalidation invalidates an expired assignment');

update public.operational_staff_assignments
set active=false,valid_to=null
where id='7a800000-0000-4000-8000-000000000001';
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
)),0::bigint,'inactive assignment is excluded');

update public.operational_staff_assignments
set active=true,valid_from=private.phase4a_business_date('Asia/Riyadh'),valid_to=null
where id='7a800000-0000-4000-8000-000000000001';
update public.branch_operational_teams set active=false
where id=current_setting('test.training_validity_team')::uuid;
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
)),0::bigint,'inactive operational team is excluded');
update public.branch_operational_teams set active=true
where id=current_setting('test.training_validity_team')::uuid;

select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000002'),0::bigint,
  'inactive employee is excluded');

update public.operational_staff_assignments
set active=false,valid_from=private.phase4a_business_date('Asia/Riyadh')-2,
    valid_to=private.phase4a_business_date('Asia/Riyadh')-1
where id='7a800000-0000-4000-8000-000000000001';
insert into public.operational_staff_assignments(
  id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,
  operational_roles,active,valid_from,valid_to
)
values(
  '7a800000-0000-4000-8000-000000000003','7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001',current_setting('test.training_validity_team')::uuid,array['kitchen'],true,private.phase4a_business_date('Asia/Riyadh'),null
);
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),1::bigint,
  'one invalid historical assignment does not override another current valid assignment');

update public.branch_supervisor_teams set active=false
where id='7a400000-0000-4000-8000-000000000001';
select is((select count(*) from public.list_training_branch_employees(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001'
) where employee_id='7a700000-0000-4000-8000-000000000001'),1::bigint,
  'Training learner eligibility does not require an active legacy Supervisor team');

select is((select count(*) from public.validate_training_branch_session(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001'
)),1::bigint,'existing branch PIN credential session remains valid');
select is((select count(*) from public.validate_training_branch_session(
  '7a200000-0000-4000-8000-000000000001','7a300000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000099'
)),0::bigint,'credential-version mismatch still invalidates the branch session');

select ok((select procedure.prosecdef from pg_catalog.pg_proc procedure
  where procedure.oid='public.list_training_branch_employees(uuid,uuid)'::regprocedure),
  'employee list remains SECURITY DEFINER');
select ok((select procedure.proconfig @> array['search_path=""'] from pg_catalog.pg_proc procedure
  where procedure.oid='public.list_training_branch_employees(uuid,uuid)'::regprocedure),
  'employee list retains an empty search_path');
select ok(has_function_privilege('service_role','public.list_training_branch_employees(uuid,uuid)','execute'),
  'service_role can execute employee list');
select ok(not has_function_privilege('anon','public.list_training_branch_employees(uuid,uuid)','execute'),
  'anon cannot execute employee list');
select ok(not has_function_privilege('authenticated','public.list_training_branch_employees(uuid,uuid)','execute'),
  'authenticated cannot execute employee list');
select ok(
  not has_function_privilege('anon','public.validate_training_branch_employee(uuid,uuid,uuid)','execute')
  and not has_function_privilege('authenticated','public.validate_training_branch_employee(uuid,uuid,uuid)','execute')
  and has_function_privilege('service_role','public.validate_training_branch_employee(uuid,uuid,uuid)','execute'),
  'employee validation remains service-role-only');

select * from finish();
rollback;
