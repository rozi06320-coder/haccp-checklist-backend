begin;
select plan(39);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '18200000-0000-4000-8000-000000000001'::uuid,
  '18200000-0000-4000-8000-000000000002',
  '18200000-0000-4000-8000-000000000003',
  '18200000-0000-4000-8000-000000000004'
]) id;

update public.profiles set full_name=case id
  when '18200000-0000-4000-8000-000000000001' then 'Source Supervisor'
  when '18200000-0000-4000-8000-000000000002' then 'Destination Supervisor'
  when '18200000-0000-4000-8000-000000000003' then 'Inactive Team Supervisor'
  else 'Other Branch Supervisor' end,must_change_password=false;

insert into public.organizations(id,name,slug)
values('28200000-0000-4000-8000-000000000001','Source Move Org','source-move-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('38200000-0000-4000-8000-000000000001','28200000-0000-4000-8000-000000000001','Source Branch','SMA','Asia/Riyadh'),
  ('38200000-0000-4000-8000-000000000002','28200000-0000-4000-8000-000000000001','Other Branch','SMB','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('38200000-0000-4000-8000-000000000001','18200000-0000-4000-8000-000000000001','branch_manager'),
  ('38200000-0000-4000-8000-000000000001','18200000-0000-4000-8000-000000000002','branch_manager'),
  ('38200000-0000-4000-8000-000000000001','18200000-0000-4000-8000-000000000003','branch_manager'),
  ('38200000-0000-4000-8000-000000000002','18200000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('48200000-0000-4000-8000-000000000001','28200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001','18200000-0000-4000-8000-000000000001'),
  ('48200000-0000-4000-8000-000000000002','28200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001','18200000-0000-4000-8000-000000000002'),
  ('48200000-0000-4000-8000-000000000003','28200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001','18200000-0000-4000-8000-000000000003'),
  ('48200000-0000-4000-8000-000000000004','28200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000002','18200000-0000-4000-8000-000000000004');

select set_config('test.source_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='48200000-0000-4000-8000-000000000001'),false);
select set_config('test.destination_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='48200000-0000-4000-8000-000000000002'),false);
select set_config('test.inactive_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='48200000-0000-4000-8000-000000000003'),false);
select set_config('test.cross_branch_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='48200000-0000-4000-8000-000000000004'),false);

select is((select count(distinct team_id) from public.get_supervisor_operational_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_date)),3::bigint,'Source Supervisor reads all same-branch teams');
select is((select count(distinct team_id) from public.get_supervisor_operational_team('18200000-0000-4000-8000-000000000002','38200000-0000-4000-8000-000000000001',current_date)),3::bigint,'Destination Supervisor reads all same-branch teams');
select ok(private.actor_can_write_operational_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid),'Source Supervisor writes source team');
select ok(not private.actor_can_write_operational_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.destination_team')::uuid),'Source Supervisor does not write destination team');
select ok(private.actor_can_write_operational_team('18200000-0000-4000-8000-000000000002','38200000-0000-4000-8000-000000000001',current_setting('test.destination_team')::uuid),'Destination Supervisor writes destination team');
select ok(not private.actor_can_write_operational_team('18200000-0000-4000-8000-000000000002','38200000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid),'Destination Supervisor does not write source team');

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'Move Candidate',array['kitchen'],null,'Source Move Org',null,null,null,null,null)$$,'Source Supervisor creates source employee');
reset role;
select set_config('test.move_staff',(select id::text from public.operational_staff where display_name='Move Candidate'),false);
select set_config('test.move_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid and active),false);

set local role service_role;
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000002','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment')::uuid,current_setting('test.destination_team')::uuid)$$,'42501','staff move denied','Destination Supervisor cannot pull from source team');
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment')::uuid,current_setting('test.source_team')::uuid)$$,'23505','staff already belongs to team','same-team destination is rejected');
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment')::uuid,current_setting('test.cross_branch_team')::uuid)$$,'42501','staff move denied','cross-branch destination is rejected');
reset role;

update public.branch_operational_teams set active=false where id=current_setting('test.inactive_team')::uuid;
set local role service_role;
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment')::uuid,current_setting('test.inactive_team')::uuid)$$,'23514','staff move conflicts with current team data','inactive destination is rejected as a conflict');
reset role;

set local role service_role;
select lives_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment')::uuid,current_setting('test.destination_team')::uuid)$$,'source-team Supervisor moves to destination without destination write access');
reset role;
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid and active),1::bigint,'move leaves one active assignment');
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid and active),current_setting('test.destination_team')::uuid,'new active assignment points to destination team');
select is((select closure_reason from public.operational_staff_assignments where id=current_setting('test.move_assignment')::uuid),'team_move','old assignment records team_move history');

select set_config('test.move_assignment_after_source',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid and active),false);
set local role service_role;
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment_after_source')::uuid,current_setting('test.source_team')::uuid)$$,'42501','staff move denied','former source Supervisor cannot move again without new source write access');
select lives_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000002','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment_after_source')::uuid,current_setting('test.source_team')::uuid)$$,'new source Supervisor can move employee after ownership transfers');
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000002','38200000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment_after_source')::uuid,current_setting('test.destination_team')::uuid)$$,'40001','staff assignment changed','stale expected assignment is rejected');
reset role;

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'Inactive Candidate',array['cleaner'],null,'Source Move Org',null,null,null,null,null)$$,'inactive test employee is created');
reset role;
select set_config('test.inactive_staff',(select id::text from public.operational_staff where display_name='Inactive Candidate'),false);
select set_config('test.inactive_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.inactive_staff')::uuid and active),false);
update public.operational_staff set employment_status='inactive',deactivated_at=now(),deactivated_by='18200000-0000-4000-8000-000000000001' where id=current_setting('test.inactive_staff')::uuid;
set local role service_role;
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.inactive_staff')::uuid,current_setting('test.inactive_assignment')::uuid,current_setting('test.destination_team')::uuid)$$,'23514','staff move conflicts with current team data','inactive employee is rejected as a conflict');
reset role;

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'Hygiene Candidate',array['cleaner'],null,'Source Move Org',null,null,null,null,null)$$,'Hygiene move employee is created');
reset role;
select set_config('test.hygiene_staff',(select id::text from public.operational_staff where display_name='Hygiene Candidate'),false);
select set_config('test.hygiene_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.hygiene_staff')::uuid and active),false);
set local role service_role;
select lives_ok($$select * from public.upsert_operational_staff_health_card('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',jsonb_build_object('operational_staff_id',current_setting('test.hygiene_staff'),'status','passed','certificate_number','HC-SOURCE'))$$,'Health Card is saved before move');
select lives_ok($$select * from public.save_operational_staff_monthly_evaluation('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.hygiene_staff')::uuid,date_trunc('month',current_date)::date,'Source Supervisor',jsonb_build_array(jsonb_build_object('section','Performance','factor_key','performance','factor_label','Performance','rating',5,'comment','Good')), 'completed')$$,'Monthly Evaluation is saved before move');
update public.branches set timezone='Etc/GMT+12' where id='38200000-0000-4000-8000-000000000001';
select lives_ok($$select * from public.submit_operational_team_hygiene('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'78200000-0000-4000-8000-000000000001',repeat('c',64),jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.move_staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark',''),jsonb_build_object('staff_id',current_setting('test.hygiene_staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark','')))$$,'Source team submits Hygiene before move');
reset role;
select set_config('test.hygiene_submission',(select id::text from public.checklist_submissions where operational_team_id=current_setting('test.source_team')::uuid and checklist_type='staff_hygiene' and state='submitted'),false);
set local role service_role;
select throws_ok($$select * from public.move_operational_staff_team('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.hygiene_staff')::uuid,current_setting('test.hygiene_assignment')::uuid,current_setting('test.destination_team')::uuid)$$,'40001','scheduled team move requires a compatible client','legacy caller fails closed instead of hiding a scheduled result');
select lives_ok($$select * from public.request_operational_staff_team_move('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.hygiene_staff')::uuid,current_setting('test.hygiene_assignment')::uuid,current_setting('test.destination_team')::uuid)$$,'submitted Hygiene schedules a source-owned move');
reset role;
select is((select operational_team_id from public.checklist_submissions where id=current_setting('test.hygiene_submission')::uuid),current_setting('test.source_team')::uuid,'submitted Hygiene stays on original source team');
select is((select display_name_snapshot from public.hygiene_staff_snapshots where submission_id=current_setting('test.hygiene_submission')::uuid and operational_staff_id=current_setting('test.hygiene_staff')::uuid),'Hygiene Candidate','submitted Hygiene snapshot remains unchanged');
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.hygiene_staff')::uuid and active),current_setting('test.source_team')::uuid,'Hygiene employee remains active in the source team today');
select ok((public.get_operational_team_hygiene_current_state('18200000-0000-4000-8000-000000000001','38200000-0000-4000-8000-000000000001',current_setting('test.destination_team')::uuid)->'staff')::text not like '%'||current_setting('test.hygiene_staff')||'%','scheduled employee is absent from the destination Hygiene roster');
select ok(not exists(select 1 from public.get_supervisor_operational_team('18200000-0000-4000-8000-000000000002','38200000-0000-4000-8000-000000000001',current_date) where staff_id=current_setting('test.hygiene_staff')::uuid and team_id=current_setting('test.destination_team')::uuid),'Destination Supervisor does not see scheduled employee before activation');
select is((select count(*) from public.operational_staff_health_cards where operational_staff_id=current_setting('test.hygiene_staff')::uuid),1::bigint,'Health Card remains one employee-scoped row');
select is((select count(*) from public.operational_staff_monthly_evaluations where operational_staff_id=current_setting('test.hygiene_staff')::uuid and evaluation_month=date_trunc('month',current_date)::date),1::bigint,'Monthly Evaluation remains one employee-month row');
select is((select count(*) from public.operational_staff_assignments where branch_id='38200000-0000-4000-8000-000000000002' and active),0::bigint,'other branch assignments remain unaffected');

update public.operational_staff_assignments assignment set valid_from=move.requested_business_date
from public.operational_staff_scheduled_team_moves move
where move.operational_staff_id=current_setting('test.hygiene_staff')::uuid and move.status='pending'
  and assignment.id=move.source_assignment_id;
insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
select move.organization_id,move.branch_id,move.operational_staff_id,move.source_assignment_id,
  move.requested_business_date,'day_off','18200000-0000-4000-8000-000000000001'
from public.operational_staff_scheduled_team_moves move
where move.operational_staff_id=current_setting('test.hygiene_staff')::uuid and move.status='pending';
update public.branches set timezone='Pacific/Kiritimati' where id='38200000-0000-4000-8000-000000000001';
set local role service_role;
select is((select move_status from public.apply_due_operational_staff_team_moves('38200000-0000-4000-8000-000000000001')
  where staff_id=current_setting('test.hygiene_staff')::uuid),'applied','due scheduled move applies after branch business-day rollover');
reset role;
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.hygiene_staff')::uuid and active),current_setting('test.destination_team')::uuid,'activation creates the destination assignment');
select is((select source.valid_to from public.operational_staff_scheduled_team_moves move join public.operational_staff_assignments source on source.id=move.source_assignment_id where move.operational_staff_id=current_setting('test.hygiene_staff')::uuid),(select effective_business_date-1 from public.operational_staff_scheduled_team_moves where operational_staff_id=current_setting('test.hygiene_staff')::uuid),'source assignment closes on the requested business day');
select is((select count(*) from public.operational_staff_duty_statuses duty join public.operational_staff_assignments assignment on assignment.id=duty.assignment_id where assignment.operational_staff_id=current_setting('test.hygiene_staff')::uuid and assignment.active),0::bigint,'activation does not copy prior-day duty state');
set local role service_role;
select is((select count(*) from public.apply_due_operational_staff_team_moves('38200000-0000-4000-8000-000000000001') where staff_id=current_setting('test.hygiene_staff')::uuid),0::bigint,'activation replay is idempotent');
reset role;

select * from finish();
rollback;
