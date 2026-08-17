begin;
select plan(47);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@training.invalid','{}','{}',now(),now()
from unnest(array[
  '17100000-0000-4000-8000-000000000001'::uuid,
  '17100000-0000-4000-8000-000000000002',
  '17100000-0000-4000-8000-000000000003',
  '17100000-0000-4000-8000-000000000004',
  '17100000-0000-4000-8000-000000000005'
]) id;
update public.profiles set full_name=case id
  when '17100000-0000-4000-8000-000000000001' then 'Training Manager'
  when '17100000-0000-4000-8000-000000000002' then 'Training Supervisor A'
  when '17100000-0000-4000-8000-000000000003' then 'Training Supervisor B'
  when '17100000-0000-4000-8000-000000000005' then 'Promoted Supervisor Candidate'
  else 'Other Training Manager' end,must_change_password=false
where id in('17100000-0000-4000-8000-000000000001','17100000-0000-4000-8000-000000000002','17100000-0000-4000-8000-000000000003','17100000-0000-4000-8000-000000000004','17100000-0000-4000-8000-000000000005');

insert into public.organizations(id,name,slug) values
  ('27100000-0000-4000-8000-000000000001','Training Org','training-org'),
  ('27100000-0000-4000-8000-000000000002','Other Training Org','other-training-org');
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('37100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','Training Branch A','TRA','Asia/Riyadh',true),
  ('37100000-0000-4000-8000-000000000002','27100000-0000-4000-8000-000000000001','Training Branch B','TRB','Asia/Riyadh',true),
  ('37100000-0000-4000-8000-000000000003','27100000-0000-4000-8000-000000000001','Inactive Training Branch','TRI','Asia/Riyadh',true),
  ('37100000-0000-4000-8000-000000000004','27100000-0000-4000-8000-000000000002','Other Training Branch','TRO','Asia/Riyadh',true);
insert into public.organization_memberships(organization_id,user_id,role) values
  ('27100000-0000-4000-8000-000000000001','17100000-0000-4000-8000-000000000001','organization_manager'),
  ('27100000-0000-4000-8000-000000000002','17100000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('37100000-0000-4000-8000-000000000001','17100000-0000-4000-8000-000000000002','branch_manager'),
  ('37100000-0000-4000-8000-000000000002','17100000-0000-4000-8000-000000000003','branch_manager'),
  ('37100000-0000-4000-8000-000000000003','17100000-0000-4000-8000-000000000002','branch_manager'),
  ('37100000-0000-4000-8000-000000000004','17100000-0000-4000-8000-000000000003','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('47100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','17100000-0000-4000-8000-000000000002'),
  ('47100000-0000-4000-8000-000000000002','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000002','17100000-0000-4000-8000-000000000003'),
  ('47100000-0000-4000-8000-000000000003','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000003','17100000-0000-4000-8000-000000000002'),
  ('47100000-0000-4000-8000-000000000004','27100000-0000-4000-8000-000000000002','37100000-0000-4000-8000-000000000004','17100000-0000-4000-8000-000000000003');
select set_config('test.training_team_a',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='47100000-0000-4000-8000-000000000001'),false);
select set_config('test.training_team_b',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='47100000-0000-4000-8000-000000000002'),false);
select set_config('test.training_team_inactive',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='47100000-0000-4000-8000-000000000003'),false);
select set_config('test.training_team_other',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='47100000-0000-4000-8000-000000000004'),false);

insert into public.operational_staff(id,organization_id,branch_id,display_name,employment_status,created_by,staff_code) values
  ('57100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','Training Worker','active','17100000-0000-4000-8000-000000000001','TR-1'),
  ('57100000-0000-4000-8000-000000000002','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','Cashier Worker','active','17100000-0000-4000-8000-000000000001','TR-2'),
  ('57100000-0000-4000-8000-000000000003','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','Vacation Worker','active','17100000-0000-4000-8000-000000000001','TR-3'),
  ('57100000-0000-4000-8000-000000000004','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','Day Off Worker','active','17100000-0000-4000-8000-000000000001','TR-4'),
  ('57100000-0000-4000-8000-000000000005','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','Inactive Worker','active','17100000-0000-4000-8000-000000000001','TR-5'),
  ('57100000-0000-4000-8000-000000000006','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000003','Inactive Branch Worker','active','17100000-0000-4000-8000-000000000001','TR-6'),
  ('57100000-0000-4000-8000-000000000007','27100000-0000-4000-8000-000000000002','37100000-0000-4000-8000-000000000004','Other Org Worker','active','17100000-0000-4000-8000-000000000004','TR-7');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles) values
  ('67100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001',current_setting('test.training_team_a')::uuid,array['kitchen']),
  ('67100000-0000-4000-8000-000000000002','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000001',current_setting('test.training_team_a')::uuid,array['cashier']),
  ('67100000-0000-4000-8000-000000000003','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000003','47100000-0000-4000-8000-000000000001',current_setting('test.training_team_a')::uuid,array['dispatcher']),
  ('67100000-0000-4000-8000-000000000004','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000004','47100000-0000-4000-8000-000000000001',current_setting('test.training_team_a')::uuid,array['cleaner']),
  ('67100000-0000-4000-8000-000000000005','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000005','47100000-0000-4000-8000-000000000001',current_setting('test.training_team_a')::uuid,array['production']),
  ('67100000-0000-4000-8000-000000000006','27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000003','57100000-0000-4000-8000-000000000006','47100000-0000-4000-8000-000000000003',current_setting('test.training_team_inactive')::uuid,array['kitchen']),
  ('67100000-0000-4000-8000-000000000007','27100000-0000-4000-8000-000000000002','37100000-0000-4000-8000-000000000004','57100000-0000-4000-8000-000000000007','47100000-0000-4000-8000-000000000004',current_setting('test.training_team_other')::uuid,array['kitchen']);
select public.leave_operational_staff_company('17100000-0000-4000-8000-000000000002','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000005','67100000-0000-4000-8000-000000000005');
insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by) values
  ('27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000003','67100000-0000-4000-8000-000000000003',private.phase4a_business_date('Asia/Riyadh'),'on_vacation','17100000-0000-4000-8000-000000000002'),
  ('27100000-0000-4000-8000-000000000001','37100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000004','67100000-0000-4000-8000-000000000004',private.phase4a_business_date('Asia/Riyadh'),'day_off','17100000-0000-4000-8000-000000000002');
update public.branches set active=false where id='37100000-0000-4000-8000-000000000003';

select has_table('public','operational_staff_supervisor_training','Training Supervisor table exists');
select ok(not has_table_privilege('anon','public.operational_staff_supervisor_training','select,insert,update,delete,truncate')
  and not has_table_privilege('authenticated','public.operational_staff_supervisor_training','select,insert,update,delete,truncate')
  and not has_table_privilege('service_role','public.operational_staff_supervisor_training','insert,update,delete,truncate'),
  'browser roles have no direct Training Supervisor table access and service role mutates through RPC only');

set local role service_role;
select lives_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000001')$$,'Manager starts training for active employee');
reset role;
select is((select operational_roles from public.operational_staff_assignments where operational_staff_id='57100000-0000-4000-8000-000000000001' and active),array['kitchen']::text[],'employee keeps current operational role');
select is((select started_by_user_id from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000001' and status='training'),'17100000-0000-4000-8000-000000000001'::uuid,'started_by is DB actor attribution');

set local role service_role;
select lives_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000002')$$,'cashier employee can become Training Supervisor');
select lives_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000003')$$,'on-vacation employee can become Training Supervisor');
select lives_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000004')$$,'day-off employee can become Training Supervisor');
select throws_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000005')$$,'42501','supervisor training access denied','inactive employee rejected');
select throws_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000006')$$,'42501','supervisor training access denied','inactive branch employee rejected');
select throws_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000007')$$,'42501','supervisor training access denied','cross-organization employee rejected');
select throws_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000001')$$,'23505','active supervisor training already exists','duplicate active training rejected');
reset role;

set local role service_role;
select lives_ok($$select public.cancel_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000001')$$,'Manager cancels active Training Supervisor');
reset role;
select is((select employment_status from public.operational_staff where id='57100000-0000-4000-8000-000000000001'),'active','cancel preserves employee active status');
select is((select status from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000001' order by started_at desc limit 1),'cancelled','cancel preserves historical row');
select is((select cancelled_by_user_id from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000001' order by started_at desc limit 1),'17100000-0000-4000-8000-000000000001'::uuid,'cancelled_by is DB actor attribution');

set local role service_role;
select lives_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000001')$$,'employee can start a new training cycle after cancellation');
select lives_ok($$select * from public.transfer_operational_staff_branch('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000001','67100000-0000-4000-8000-000000000001',current_setting('test.training_team_b')::uuid)$$,'Change Store succeeds with active training designation');
reset role;
select is((select count(*) from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000001'),2::bigint,'historical cancelled row is preserved with new active row');
select is((select count(*) from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000001' and status='training'),1::bigint,'active training remains attached to employee after transfer');
select is((select branch_id from public.operational_staff where id='57100000-0000-4000-8000-000000000001'),'37100000-0000-4000-8000-000000000002'::uuid,'employee current branch changes after transfer');
select is((select branch_id_at_start from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000001' and status='training'),'37100000-0000-4000-8000-000000000001'::uuid,'branch-at-start remains unchanged after transfer');
select is((public.list_managed_employee_team('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees'->0->>'supervisor_training_status'),'training','Manager Employee Directory returns training status');

set local role service_role;
select lives_ok($$select public.promote_managed_operational_staff_supervisor_training(
  '17100000-0000-4000-8000-000000000001',
  '27100000-0000-4000-8000-000000000001',
  '57100000-0000-4000-8000-000000000002',
  '17100000-0000-4000-8000-000000000005',
  'Promoted Cashier Supervisor',
  null
)$$,'Manager promotes active cashier Training Supervisor');
reset role;
select is((select status from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000002' order by updated_at desc limit 1),'promoted','training row becomes promoted');
select is((select promoted_by_user_id from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000002' order by updated_at desc limit 1),'17100000-0000-4000-8000-000000000001'::uuid,'promoted_by is Manager actor');
select is((select promoted_supervisor_user_id from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000002' order by updated_at desc limit 1),'17100000-0000-4000-8000-000000000005'::uuid,'promoted Supervisor user is stored');
select is((select employment_status from public.operational_staff where id='57100000-0000-4000-8000-000000000002'),'inactive','promotion closes operational employee lifecycle');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id='57100000-0000-4000-8000-000000000002' and active),0::bigint,'promotion closes active operational assignment');
select is((select closure_reason from public.operational_staff_assignments where id='67100000-0000-4000-8000-000000000002'),'promoted_to_supervisor','promotion records closure reason');
select is((select operational_roles from public.operational_staff_assignments where id='67100000-0000-4000-8000-000000000002'),array['cashier']::text[],'promotion preserves historical cashier role');
select is((select count(*) from public.branch_memberships where branch_id='37100000-0000-4000-8000-000000000001' and user_id='17100000-0000-4000-8000-000000000005' and role='branch_manager' and active),1::bigint,'promotion grants branch Supervisor membership');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='17100000-0000-4000-8000-000000000005' and active),0::bigint,'promotion creates no Employee Team assignment');
select is((select count(*) from public.branch_supervisor_teams where supervisor_user_id='17100000-0000-4000-8000-000000000005' and active),0::bigint,'promotion creates no legacy compatibility team');
select is((select count(*) from public.branch_operational_teams where branch_id='37100000-0000-4000-8000-000000000001'),1::bigint,'promotion creates no fake operational team');
select ok(not private.actor_can_write_operational_team('17100000-0000-4000-8000-000000000005','37100000-0000-4000-8000-000000000001',current_setting('test.training_team_a')::uuid),'promoted zero-team Supervisor cannot write existing team');
select ok((public.get_managed_annual_evaluation_workspace('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001',2026,null,null,null,null)->'subjects')@>'[{"subject_type":"supervisor","subject_id":"17100000-0000-4000-8000-000000000005"}]'::jsonb,'promoted Supervisor appears as future Supervisor Annual Evaluation subject');
select ok((select must_change_password from public.profiles where id='17100000-0000-4000-8000-000000000005'),'promoted Supervisor must change temporary password on first login');
update public.profiles set must_change_password=false where id='17100000-0000-4000-8000-000000000005';
create temporary table promoted_supervisor_team on commit drop as
select * from public.create_supervisor_owned_operational_team(
  '17100000-0000-4000-8000-000000000005',
  '37100000-0000-4000-8000-000000000001',
  'Promoted Supervisor Team'
);
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=(select team_id from promoted_supervisor_team) and supervisor_user_id='17100000-0000-4000-8000-000000000005' and assignment_role='primary' and active),1::bigint,'promoted Supervisor becomes primary after creating own team');
select ok(private.actor_can_write_operational_team('17100000-0000-4000-8000-000000000005','37100000-0000-4000-8000-000000000001',(select team_id from promoted_supervisor_team)),'promoted Supervisor can write only their own newly created team');
select is((public.get_managed_supervisor_training_promotion_state('17100000-0000-4000-8000-000000000001','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000002')->>'status'),'promoted','promotion preflight returns promoted state for retry');
set local role service_role;
select lives_ok($$select public.promote_managed_operational_staff_supervisor_training(
  '17100000-0000-4000-8000-000000000001',
  '27100000-0000-4000-8000-000000000001',
  '57100000-0000-4000-8000-000000000002',
  '17100000-0000-4000-8000-000000000005',
  'Promoted Cashier Supervisor',
  null
)$$,'same DB promotion finalize is idempotent after success');
reset role;
select is((select count(*) from public.operational_staff_supervisor_training where operational_staff_id='57100000-0000-4000-8000-000000000002' and status='promoted'),1::bigint,'promotion retry does not duplicate training rows');

set local role service_role;
select throws_ok($$select public.start_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000002','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000002')$$,'42501','supervisor training access denied','Supervisor cannot grant training');
select throws_ok($$select public.cancel_managed_operational_staff_supervisor_training('17100000-0000-4000-8000-000000000002','27100000-0000-4000-8000-000000000001','57100000-0000-4000-8000-000000000002')$$,'42501','supervisor training access denied','Supervisor cannot cancel training');
reset role;
set local role service_role;
select throws_ok($$select public.promote_managed_operational_staff_supervisor_training(
  '17100000-0000-4000-8000-000000000002',
  '27100000-0000-4000-8000-000000000001',
  '57100000-0000-4000-8000-000000000003',
  '17100000-0000-4000-8000-000000000005',
  'Denied',
  null
)$$,'42501','supervisor promotion denied','Supervisor cannot promote training employee');
reset role;
select is((select count(*) from public.annual_evaluations where organization_id='27100000-0000-4000-8000-000000000001'),0::bigint,'Annual Evaluation remains untouched');

select * from finish();
rollback;
