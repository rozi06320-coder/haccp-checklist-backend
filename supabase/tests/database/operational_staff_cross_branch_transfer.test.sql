begin;
select plan(39);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '19300000-0000-4000-8000-000000000001'::uuid,
  '19300000-0000-4000-8000-000000000002',
  '19300000-0000-4000-8000-000000000003',
  '19300000-0000-4000-8000-000000000004'
]) id;

update public.profiles set full_name=case id
  when '19300000-0000-4000-8000-000000000001' then 'Source Supervisor'
  when '19300000-0000-4000-8000-000000000002' then 'Destination Supervisor'
  when '19300000-0000-4000-8000-000000000004' then 'Inactive Team Supervisor'
  else 'Other Organization Supervisor' end,must_change_password=false;

insert into public.organizations(id,name,slug) values
  ('29300000-0000-4000-8000-000000000001','Cross Branch Org','cross-branch-org'),
  ('29300000-0000-4000-8000-000000000002','Other Cross Org','other-cross-org');
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('39300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','Source Branch','CBA','Asia/Riyadh',true),
  ('39300000-0000-4000-8000-000000000002','29300000-0000-4000-8000-000000000001','Destination Branch','CBB','Asia/Riyadh',true),
  ('39300000-0000-4000-8000-000000000003','29300000-0000-4000-8000-000000000001','Inactive Destination Branch','CBI','Asia/Riyadh',false),
  ('39300000-0000-4000-8000-000000000004','29300000-0000-4000-8000-000000000002','Other Org Branch','CBO','Asia/Riyadh',true);
insert into public.branch_memberships(branch_id,user_id,role) values
  ('39300000-0000-4000-8000-000000000001','19300000-0000-4000-8000-000000000001','branch_manager'),
  ('39300000-0000-4000-8000-000000000002','19300000-0000-4000-8000-000000000002','branch_manager'),
  ('39300000-0000-4000-8000-000000000002','19300000-0000-4000-8000-000000000004','branch_manager'),
  ('39300000-0000-4000-8000-000000000004','19300000-0000-4000-8000-000000000003','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('49300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001','19300000-0000-4000-8000-000000000001'),
  ('49300000-0000-4000-8000-000000000002','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000002','19300000-0000-4000-8000-000000000002'),
  ('49300000-0000-4000-8000-000000000003','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000002','19300000-0000-4000-8000-000000000004'),
  ('49300000-0000-4000-8000-000000000004','29300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000004','19300000-0000-4000-8000-000000000003');
select set_config('test.source_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='49300000-0000-4000-8000-000000000001'),false);
select set_config('test.destination_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='49300000-0000-4000-8000-000000000002'),false);
select set_config('test.inactive_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='49300000-0000-4000-8000-000000000003'),false);
select set_config('test.other_org_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='49300000-0000-4000-8000-000000000004'),false);
update public.branch_operational_teams set active=false where id=current_setting('test.inactive_team')::uuid;

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'Cross Branch Candidate',array['kitchen'],null,'Cross Branch Org',null,null,null,null,null)$$,'source employee created');
select lives_ok($$select * from public.create_operational_team_staff('19300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid,'Destination Existing',array['cleaner'],null,'Cross Branch Org',null,null,null,null,null)$$,'destination employee created');
reset role;
select set_config('test.staff',(select id::text from public.operational_staff where display_name='Cross Branch Candidate'),false);
select set_config('test.assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),false);
select set_config('test.destination_staff',(select id::text from public.operational_staff where display_name='Destination Existing'),false);

select is((select count(*) from public.list_operational_staff_transfer_destinations('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid)),1::bigint,'source supervisor lists active same-org destination teams only');
select ok(not exists(select 1 from public.list_operational_staff_transfer_destinations('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid) where branch_id='39300000-0000-4000-8000-000000000004'),'destination lookup excludes other organization branches');
select ok(private.actor_can_write_operational_team('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid),'source supervisor writes source team');
select ok(not private.actor_can_write_operational_team('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid),'source supervisor does not write destination team');
select ok(private.actor_can_write_operational_team('19300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid),'destination supervisor writes destination team');

set local role service_role;
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000002','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,'39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid)$$,'42501','staff transfer denied','destination supervisor cannot pull before transfer');
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,'39300000-0000-4000-8000-000000000004',current_setting('test.other_org_team')::uuid)$$,'42501','staff transfer denied','cross-org destination rejected');
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,'39300000-0000-4000-8000-000000000003',current_setting('test.destination_team')::uuid)$$,'42501','staff transfer denied','inactive destination branch rejected');
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,'39300000-0000-4000-8000-000000000002',current_setting('test.inactive_team')::uuid)$$,'42501','staff transfer denied','inactive destination team rejected');
reset role;

set local role service_role;
select lives_ok($$select * from public.submit_operational_team_hygiene('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'79300000-0000-4000-8000-000000000001',repeat('a',64),jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark','')))$$,'source submitted Hygiene history exists before transfer');
select lives_ok($$select * from public.upsert_operational_staff_health_card('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',jsonb_build_object('operational_staff_id',current_setting('test.staff'),'status','passed','certificate_number','HC-CROSS'))$$,'Health Card saved before transfer');
select lives_ok($$select * from public.save_operational_staff_monthly_evaluation('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,date_trunc('month',current_date)::date,'Source Supervisor',jsonb_build_array(jsonb_build_object('section','Performance','factor_key','performance','factor_label','Performance','rating',5,'comment','Good')), 'completed')$$,'Monthly Evaluation saved before transfer');
reset role;
select set_config('test.source_hygiene_submission',(select id::text from public.checklist_submissions where operational_team_id=current_setting('test.source_team')::uuid and checklist_type='staff_hygiene' and state='submitted'),false);

set local role service_role;
select lives_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,'39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid)$$,'source supervisor sends employee across branches without destination write');
reset role;
select set_config('test.new_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),false);
select is((select id from public.operational_staff where id=current_setting('test.staff')::uuid),current_setting('test.staff')::uuid,'same operational staff identity is preserved');
select is((select branch_id from public.operational_staff where id=current_setting('test.staff')::uuid),'39300000-0000-4000-8000-000000000002'::uuid,'staff current branch becomes destination');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),1::bigint,'transfer leaves exactly one active assignment');
select is((select branch_id from public.operational_staff_assignments where id=current_setting('test.new_assignment')::uuid),'39300000-0000-4000-8000-000000000002'::uuid,'new assignment is in destination branch');
select is((select operational_team_id from public.operational_staff_assignments where id=current_setting('test.new_assignment')::uuid),current_setting('test.destination_team')::uuid,'new assignment points to destination team');
select is((select closure_reason from public.operational_staff_assignments where id=current_setting('test.assignment')::uuid),'branch_transfer','old assignment records branch_transfer');
select is((select operational_team_id from public.checklist_submissions where id=current_setting('test.source_hygiene_submission')::uuid),current_setting('test.source_team')::uuid,'source Hygiene submission stays on original team');
select is((select display_name_snapshot from public.hygiene_staff_snapshots where submission_id=current_setting('test.source_hygiene_submission')::uuid and operational_staff_id=current_setting('test.staff')::uuid),'Cross Branch Candidate','source Hygiene snapshot remains unchanged');
select ok((public.get_operational_team_hygiene_current_state('19300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid)->'staff')::text like '%'||current_setting('test.staff')||'%','destination current Hygiene roster includes transferred employee when not submitted');
select ok(exists(select 1 from public.get_supervisor_operational_team('19300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000002',current_date) where staff_id=current_setting('test.staff')::uuid and team_id=current_setting('test.destination_team')::uuid),'destination supervisor sees transferred employee');

set local role service_role;
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000002',current_setting('test.staff')::uuid,current_setting('test.new_assignment')::uuid,'39300000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid)$$,'42501','staff transfer denied','source supervisor loses permission after transfer');
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000002','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000002',current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,'39300000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid)$$,'40001','staff assignment changed','stale expected assignment is rejected');
select lives_ok($$select * from public.upsert_operational_staff_health_card('19300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000002',jsonb_build_object('operational_staff_id',current_setting('test.staff'),'status','passed','certificate_number','HC-CROSS-DEST'))$$,'destination supervisor gains Health Card access');
select throws_ok($$select * from public.upsert_operational_staff_health_card('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',jsonb_build_object('operational_staff_id',current_setting('test.staff'),'status','passed'))$$,'42501','health card access denied','source supervisor loses Health Card write access');
select lives_ok($$select * from public.save_operational_staff_monthly_evaluation('19300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000002',current_setting('test.staff')::uuid,date_trunc('month',current_date)::date,'Destination Supervisor',jsonb_build_array(jsonb_build_object('section','Performance','factor_key','performance','factor_label','Performance','rating',4,'comment','Transferred')), 'completed')$$,'destination supervisor updates same monthly evaluation');
reset role;
select is((select count(*) from public.operational_staff_health_cards where operational_staff_id=current_setting('test.staff')::uuid),1::bigint,'Health Card remains one employee-scoped row');
select is((select count(*) from public.operational_staff_monthly_evaluations where operational_staff_id=current_setting('test.staff')::uuid and evaluation_month=date_trunc('month',current_date)::date),1::bigint,'Monthly Evaluation remains one employee-month row');
select ok(exists(select 1 from public.account_management_audit_logs log where log.action='operational_staff_assignment_updated' and log.details->>'closure_reason'='branch_transfer' and log.details->>'source_branch_id'='39300000-0000-4000-8000-000000000001' and log.details->>'destination_branch_id'='39300000-0000-4000-8000-000000000002'),'branch transfer audit includes source and destination context');

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'Blocked Transfer Candidate',array['cashier'],null,'Cross Branch Org',null,null,null,null,null)$$,'blocked transfer employee created');
reset role;
select set_config('test.blocked_staff',(select id::text from public.operational_staff where display_name='Blocked Transfer Candidate'),false);
select set_config('test.blocked_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.blocked_staff')::uuid and active),false);
set local role service_role;
select lives_ok($$select * from public.submit_operational_team_hygiene('19300000-0000-4000-8000-000000000002','39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid,'79300000-0000-4000-8000-000000000002',repeat('b',64),jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.destination_staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark',''),jsonb_build_object('staff_id',current_setting('test.staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark','')))$$,'destination Hygiene submitted after successful transfer');
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.blocked_staff')::uuid,current_setting('test.blocked_assignment')::uuid,'39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid)$$,'23514','destination team hygiene already submitted','destination submitted Hygiene blocks same-day transfer');
select lives_ok($$select * from public.create_operational_team_staff('19300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'Inactive Transfer Candidate',array['cashier'],null,'Cross Branch Org',null,null,null,null,null)$$,'inactive transfer employee created');
reset role;
select set_config('test.inactive_staff',(select id::text from public.operational_staff where display_name='Inactive Transfer Candidate'),false);
select set_config('test.inactive_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.inactive_staff')::uuid and active),false);
update public.operational_staff set employment_status='inactive',deactivated_at=now(),deactivated_by='19300000-0000-4000-8000-000000000001' where id=current_setting('test.inactive_staff')::uuid;
set local role service_role;
select throws_ok($$select * from public.transfer_operational_staff_branch('19300000-0000-4000-8000-000000000001','29300000-0000-4000-8000-000000000001','39300000-0000-4000-8000-000000000001',current_setting('test.inactive_staff')::uuid,current_setting('test.inactive_assignment')::uuid,'39300000-0000-4000-8000-000000000002',current_setting('test.destination_team')::uuid)$$,'42501','staff transfer denied','inactive employee rejected');
reset role;
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),1::bigint,'concurrency invariant still leaves one active assignment after stale attempt');

select * from finish();
rollback;
