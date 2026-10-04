begin;
select plan(21);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '1bc00000-0000-4000-8000-000000000001'::uuid,
  '1bc00000-0000-4000-8000-000000000002',
  '1bc00000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name='Scheduled transfer supervisor',must_change_password=false
where id in('1bc00000-0000-4000-8000-000000000001','1bc00000-0000-4000-8000-000000000002');

insert into public.organizations(id,name,slug)
values('2bc00000-0000-4000-8000-000000000001','Scheduled Branch Transfer Org','scheduled-branch-transfer-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3bc00000-0000-4000-8000-000000000001','2bc00000-0000-4000-8000-000000000001','Source Branch','SBT-A','Asia/Riyadh'),
  ('3bc00000-0000-4000-8000-000000000002','2bc00000-0000-4000-8000-000000000001','Destination Branch','SBT-B','Pacific/Kiritimati');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('3bc00000-0000-4000-8000-000000000001','1bc00000-0000-4000-8000-000000000001','branch_manager'),
  ('3bc00000-0000-4000-8000-000000000001','1bc00000-0000-4000-8000-000000000003','branch_manager'),
  ('3bc00000-0000-4000-8000-000000000002','1bc00000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4bc00000-0000-4000-8000-000000000001','2bc00000-0000-4000-8000-000000000001','3bc00000-0000-4000-8000-000000000001','1bc00000-0000-4000-8000-000000000001'),
  ('4bc00000-0000-4000-8000-000000000002','2bc00000-0000-4000-8000-000000000001','3bc00000-0000-4000-8000-000000000002','1bc00000-0000-4000-8000-000000000002'),
  ('4bc00000-0000-4000-8000-000000000003','2bc00000-0000-4000-8000-000000000001','3bc00000-0000-4000-8000-000000000001','1bc00000-0000-4000-8000-000000000003');
select set_config('test.source_team',(select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='4bc00000-0000-4000-8000-000000000001'),false);
select set_config('test.destination_team',(select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='4bc00000-0000-4000-8000-000000000002'),false);
select set_config('test.alternate_source_team',(select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='4bc00000-0000-4000-8000-000000000003'),false);

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff(
  '1bc00000-0000-4000-8000-000000000001','3bc00000-0000-4000-8000-000000000001',
  current_setting('test.source_team')::uuid,'Scheduled Branch Candidate',array['kitchen'],null,
  'Scheduled Branch Transfer Org',null,null,null,null,null)$$,'source supervisor creates employee');
reset role;
select set_config('test.staff',(select id::text from public.operational_staff
  where display_name='Scheduled Branch Candidate'),false);
select set_config('test.assignment',(select id::text from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.staff')::uuid and active),false);

set local role service_role;
select lives_ok($$select * from public.submit_operational_team_hygiene(
  '1bc00000-0000-4000-8000-000000000001','3bc00000-0000-4000-8000-000000000001',
  current_setting('test.source_team')::uuid,'7bc00000-0000-4000-8000-000000000001',repeat('d',64),
  jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.staff'),'uniform','pass',
    'fingernails','pass','hair','pass','facial_hair','pass','remark','')))$$,
  'source Hygiene is submitted');
select lives_ok($$select * from public.request_operational_staff_branch_transfer(
  '1bc00000-0000-4000-8000-000000000001','2bc00000-0000-4000-8000-000000000001',
  '3bc00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,
  current_setting('test.assignment')::uuid,'3bc00000-0000-4000-8000-000000000002',
  current_setting('test.destination_team')::uuid,true)$$,'submitted source Hygiene schedules transfer');
reset role;

select is((select status from public.operational_staff_scheduled_branch_transfers
  where operational_staff_id=current_setting('test.staff')::uuid),'pending','transfer is pending');
select is((select source_branch_id from public.operational_staff_scheduled_branch_transfers
  where operational_staff_id=current_setting('test.staff')::uuid),'3bc00000-0000-4000-8000-000000000001'::uuid,'source branch is frozen');
select is((select destination_branch_id from public.operational_staff_scheduled_branch_transfers
  where operational_staff_id=current_setting('test.staff')::uuid),'3bc00000-0000-4000-8000-000000000002'::uuid,'destination branch is frozen');
select is((select effective_source_business_date-requested_source_business_date
  from public.operational_staff_scheduled_branch_transfers where operational_staff_id=current_setting('test.staff')::uuid),1,'effective date is next source business day');
select is((select extract(hour from effective_at at time zone 'Asia/Riyadh')::integer
  from public.operational_staff_scheduled_branch_transfers where operational_staff_id=current_setting('test.staff')::uuid),4,'activation is source-local 04:00');
select is((select branch_id from public.operational_staff where id=current_setting('test.staff')::uuid),
  '3bc00000-0000-4000-8000-000000000001'::uuid,'staff remains in source branch before activation');
select is((select operational_team_id from public.operational_staff_assignments
  where id=current_setting('test.assignment')::uuid),current_setting('test.source_team')::uuid,'source assignment remains unchanged');
select is((select count(*) from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.staff')::uuid and active),1::bigint,'only one assignment remains active');
select is((select count(*) from public.hygiene_staff_snapshots
  where operational_staff_id=current_setting('test.staff')::uuid),1::bigint,'historical Hygiene snapshot remains');
select set_config('test.scheduled_transfer',(select id::text from public.operational_staff_scheduled_branch_transfers
  where operational_staff_id=current_setting('test.staff')::uuid),false);

set local role service_role;
select is((select move_status from public.request_operational_staff_branch_transfer(
  '1bc00000-0000-4000-8000-000000000001','2bc00000-0000-4000-8000-000000000001',
  '3bc00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,
  current_setting('test.assignment')::uuid,'3bc00000-0000-4000-8000-000000000002',
  current_setting('test.destination_team')::uuid,true)),'scheduled','identical retry is deterministic');
select throws_ok($$select * from public.request_operational_staff_team_move(
  '1bc00000-0000-4000-8000-000000000001','3bc00000-0000-4000-8000-000000000001',
  current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,
  current_setting('test.alternate_source_team')::uuid)$$,'23505','staff pending movement already exists',
  'pending branch transfer blocks same-branch scheduling');
select throws_ok($$select * from public.request_operational_staff_branch_transfer(
  '1bc00000-0000-4000-8000-000000000001','2bc00000-0000-4000-8000-000000000001',
  '3bc00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,
  current_setting('test.assignment')::uuid,'3bc00000-0000-4000-8000-000000000002',
  gen_random_uuid(),true)$$,'42501','staff transfer denied','wrong destination team is denied');
select lives_ok($$select * from public.cancel_operational_staff_scheduled_branch_transfer(
  '1bc00000-0000-4000-8000-000000000001','3bc00000-0000-4000-8000-000000000001',
  current_setting('test.staff')::uuid,current_setting('test.scheduled_transfer')::uuid,
  current_setting('test.assignment')::uuid)$$,
  'pending transfer can be cancelled');
reset role;
select is((select status from public.operational_staff_scheduled_branch_transfers
  where operational_staff_id=current_setting('test.staff')::uuid),'cancelled','cancel records lifecycle state');
select is((select count(*) from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.staff')::uuid and active),1::bigint,'cancellation does not change assignment');
select is((select branch_id from public.operational_staff where id=current_setting('test.staff')::uuid),
  '3bc00000-0000-4000-8000-000000000001'::uuid,'cancellation does not change staff branch');
select ok(has_function_privilege('service_role','public.request_operational_staff_branch_transfer(uuid,uuid,uuid,uuid,uuid,uuid,uuid,boolean)','EXECUTE'),
  'service role can request transfers');
select ok(not has_function_privilege('authenticated','public.request_operational_staff_branch_transfer(uuid,uuid,uuid,uuid,uuid,uuid,uuid,boolean)','EXECUTE'),
  'authenticated clients cannot execute transfer RPC directly');

select * from finish();
rollback;
