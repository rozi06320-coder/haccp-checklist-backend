begin;
select plan(40);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',email,'{}','{}',now(),now()
from (values
  ('1ac00000-0000-4000-8000-000000000001'::uuid,'admin@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000002'::uuid,'source-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000003'::uuid,'destination-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000004'::uuid,'other-branch-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000005'::uuid,'not-admin@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000006'::uuid,'alternate-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000007'::uuid,'other-org-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000008'::uuid,'inactive-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000009'::uuid,'no-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000010'::uuid,'inactive-membership-supervisor@example.invalid')
) users(id,email);

update public.profiles
set full_name = case id
  when '1ac00000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1ac00000-0000-4000-8000-000000000002' then 'Source Supervisor'
  when '1ac00000-0000-4000-8000-000000000003' then 'Destination Supervisor'
  when '1ac00000-0000-4000-8000-000000000004' then 'Other Branch Supervisor'
  when '1ac00000-0000-4000-8000-000000000006' then 'Alternate Supervisor'
  when '1ac00000-0000-4000-8000-000000000007' then 'Other Org Supervisor'
  when '1ac00000-0000-4000-8000-000000000008' then 'Inactive Supervisor'
  when '1ac00000-0000-4000-8000-000000000009' then 'No Supervisor Team Owner'
  when '1ac00000-0000-4000-8000-000000000010' then 'Inactive Membership Supervisor'
  else 'Not Admin'
end,
must_change_password=false
where id::text like '1ac00000-%';

insert into public.internal_admin_memberships(user_id,active)
values('1ac00000-0000-4000-8000-000000000001',true);

insert into public.organizations(id,name,slug) values
  ('2ac00000-0000-4000-8000-000000000001','Internal Reassign Org','internal-reassign-org'),
  ('2ac00000-0000-4000-8000-000000000002','Other Internal Reassign Org','other-internal-reassign-org');
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('3ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001','Main Branch','MAIN','Asia/Riyadh',true),
  ('3ac00000-0000-4000-8000-000000000002','2ac00000-0000-4000-8000-000000000001','Other Branch','OTHER','Asia/Riyadh',true),
  ('3ac00000-0000-4000-8000-000000000003','2ac00000-0000-4000-8000-000000000002','Other Org Branch','OORG','Asia/Riyadh',true);
insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('3ac00000-0000-4000-8000-000000000001','1ac00000-0000-4000-8000-000000000002','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000001','1ac00000-0000-4000-8000-000000000003','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000001','1ac00000-0000-4000-8000-000000000006','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000001','1ac00000-0000-4000-8000-000000000008','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000001','1ac00000-0000-4000-8000-000000000009','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000001','1ac00000-0000-4000-8000-000000000010','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000002','1ac00000-0000-4000-8000-000000000004','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000003','1ac00000-0000-4000-8000-000000000007','branch_manager',true);

create temp table source_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Source Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000002',
  null,
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'display_name','Move Candidate',
    'company_name','Internal Reassign Org',
    'staff_code','MOVE-01',
    'country_code','SA',
    'operational_roles',pg_catalog.jsonb_build_array('kitchen')
  ))
);
create temp table destination_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Destination Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000003',
  null,
  '[]'::jsonb
);
create temp table alternate_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Alternate Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000006',
  null,
  '[]'::jsonb
);
create temp table inactive_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Inactive Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000008',
  null,
  '[]'::jsonb
);
create temp table no_supervisor_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'No Supervisor Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000009',
  null,
  '[]'::jsonb
);
create temp table disabled_profile_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Disabled Profile Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000008',
  null,
  '[]'::jsonb
);
create temp table inactive_membership_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Inactive Membership Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000010',
  null,
  '[]'::jsonb
);
create temp table other_branch_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000002',
  'Other Branch Team',
  'Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000004',
  null,
  '[]'::jsonb
);
create temp table other_org_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000002',
  '3ac00000-0000-4000-8000-000000000003',
  'Other Org Team',
  'Other Internal Reassign Org',
  '1ac00000-0000-4000-8000-000000000007',
  null,
  '[]'::jsonb
);
grant select on source_team,destination_team,alternate_team,inactive_team,no_supervisor_team,disabled_profile_team,inactive_membership_team,other_branch_team,other_org_team to service_role;

update public.branch_operational_teams set active=false where id=(select team_id from inactive_team);
update public.branch_operational_team_supervisors set active=false where operational_team_id=(select team_id from no_supervisor_team);
update public.profiles set disabled_at=now() where id='1ac00000-0000-4000-8000-000000000008';
update public.branch_memberships set active=false
where branch_id='3ac00000-0000-4000-8000-000000000001'
  and user_id='1ac00000-0000-4000-8000-000000000010';
select is((select operational_staff_count from destination_team),0::bigint,'destination team starts with zero staff');

select set_config('test.staff',(select id::text from public.operational_staff where staff_code='MOVE-01'),false);
select set_config('test.assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),false);
insert into public.operational_staff_supervisor_training(organization_id,operational_staff_id,branch_id_at_start,status,started_by_user_id)
values('2ac00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,'3ac00000-0000-4000-8000-000000000001','training','1ac00000-0000-4000-8000-000000000001');

set local role service_role;
create temp table applied_move as
select * from public.reassign_internal_admin_operational_staff_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  current_setting('test.staff')::uuid,
  (select team_id from destination_team),
  current_setting('test.assignment')::uuid
);
reset role;

select is((select move_status from applied_move),'applied','internal admin same-branch reassignment applies immediately');
select is((select destination_operational_team_id from applied_move),(select team_id from destination_team),'applied result points at destination team');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),1::bigint,'applied reassignment leaves exactly one active assignment');
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),(select team_id from destination_team),'new active assignment points to destination');
select is((select closure_reason from public.operational_staff_assignments where id=current_setting('test.assignment')::uuid),'team_move','historical source assignment is closed with team_move');
select is((select count(*) from public.account_management_audit_logs where action='operational_staff_assignment_updated' and details->>'operational_staff_id'=current_setting('test.staff')),1::bigint,'applied move writes one audit row for the employee');
select ok(exists(select 1 from public.account_management_audit_logs where details->>'operational_staff_id'=current_setting('test.staff') and details ? 'source_team_id' and details ? 'destination_team_id' and not (details ? 'new_supervisor_user_id') and not (details ? 'reason')),'audit contains canonical team facts only');
select is((select count(*) from public.operational_staff_supervisor_training where operational_staff_id=current_setting('test.staff')::uuid and status='training'),1::bigint,'supervisor training state is unchanged');
select ok(not exists(select 1 from public.get_supervisor_operational_team('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',current_date) where staff_id=current_setting('test.staff')::uuid and team_id=(select team_id from source_team)),'old supervisor no longer sees staff in source team');
select ok(exists(select 1 from public.get_supervisor_operational_team('1ac00000-0000-4000-8000-000000000003','3ac00000-0000-4000-8000-000000000001',current_date) where staff_id=current_setting('test.staff')::uuid and team_id=(select team_id from destination_team) and can_write),'new supervisor gains current writable team membership');
select set_config('test.current_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),false);

set local role service_role;
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000005','2ac00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,(select team_id from alternate_team),current_setting('test.current_assignment')::uuid)$$,'42501','internal admin access denied','non Internal Admin is denied');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,(select team_id from other_org_team),current_setting('test.current_assignment')::uuid)$$,'22023','invalid destination team','cross-organization destination is rejected');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,(select team_id from other_branch_team),current_setting('test.current_assignment')::uuid)$$,'42501','cross-branch staff reassignment denied','cross-branch destination is rejected');
reset role;

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',(select team_id from source_team),'Inactive Candidate',array['cleaner'],null,'Internal Reassign Org',null,null,null,null,null)$$,'inactive test employee created');
select lives_ok($$select * from public.create_operational_team_staff('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',(select team_id from source_team),'Blocked Candidate',array['cleaner'],null,'Internal Reassign Org',null,null,null,null,null)$$,'blocked test employee created');
reset role;
select set_config('test.inactive_staff',(select id::text from public.operational_staff where display_name='Inactive Candidate'),false);
select set_config('test.inactive_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.inactive_staff')::uuid and active),false);
select set_config('test.blocked_staff',(select id::text from public.operational_staff where display_name='Blocked Candidate'),false);
select set_config('test.blocked_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.blocked_staff')::uuid and active),false);
update public.operational_staff set employment_status='inactive',deactivated_at=now(),deactivated_by='1ac00000-0000-4000-8000-000000000001' where id=current_setting('test.inactive_staff')::uuid;
set local role service_role;
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.inactive_staff')::uuid,(select team_id from alternate_team),current_setting('test.inactive_assignment')::uuid)$$,'23514','staff reassignment conflicts with current team data','inactive staff is rejected');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.blocked_staff')::uuid,(select team_id from inactive_team),current_setting('test.blocked_assignment')::uuid)$$,'23514','staff reassignment conflicts with current team data','inactive destination team is rejected');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.blocked_staff')::uuid,(select team_id from no_supervisor_team),current_setting('test.blocked_assignment')::uuid)$$,'23514','destination team has no active supervisor','destination without active supervisor is rejected');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.blocked_staff')::uuid,(select team_id from disabled_profile_team),current_setting('test.blocked_assignment')::uuid)$$,'23514','destination team has no active supervisor','destination supervisor with disabled profile is rejected');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.blocked_staff')::uuid,(select team_id from inactive_membership_team),current_setting('test.blocked_assignment')::uuid)$$,'23514','destination team has no active supervisor','destination supervisor with inactive branch membership is rejected');
reset role;

set local role service_role;
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,(select team_id from destination_team),current_setting('test.current_assignment')::uuid)$$,'23505','staff already belongs to team','same destination team is rejected');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,(select team_id from alternate_team),current_setting('test.assignment')::uuid)$$,'40001','staff assignment changed','stale expected assignment id is rejected');
reset role;

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',(select team_id from source_team),'Hygiene Candidate',array['kitchen'],null,'Internal Reassign Org',null,null,null,null,null)$$,'hygiene candidate created');
reset role;
select set_config('test.hygiene_staff',(select id::text from public.operational_staff where display_name='Hygiene Candidate'),false);
select set_config('test.hygiene_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.hygiene_staff')::uuid and active),false);
update public.branches set timezone='Etc/GMT+12' where id='3ac00000-0000-4000-8000-000000000001';
set local role service_role;
select lives_ok($$select * from public.submit_operational_team_hygiene('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',(select team_id from source_team),'7ac00000-0000-4000-8000-000000000001',repeat('h',64),jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.blocked_staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark',''),jsonb_build_object('staff_id',current_setting('test.hygiene_staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark','')))$$,'source team submits Hygiene before reassignment');
reset role;
select set_config('test.hygiene_submission',(select id::text from public.checklist_submissions where operational_team_id=(select team_id from source_team) and checklist_type='staff_hygiene' and state='submitted'),false);

set local role service_role;
create temp table scheduled_move as
select * from public.reassign_internal_admin_operational_staff_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  current_setting('test.hygiene_staff')::uuid,
  (select team_id from destination_team),
  current_setting('test.hygiene_assignment')::uuid
);
reset role;

select is((select move_status from scheduled_move),'scheduled','submitted source Hygiene schedules reassignment');
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.hygiene_staff')::uuid and active),(select team_id from source_team),'scheduled employee remains in source team today');
select is((select display_name_snapshot from public.hygiene_staff_snapshots where submission_id=current_setting('test.hygiene_submission')::uuid and operational_staff_id=current_setting('test.hygiene_staff')::uuid),'Hygiene Candidate','submitted Hygiene snapshot is not rewritten');

set local role service_role;
select is((select scheduled_move_id from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.hygiene_staff')::uuid,(select team_id from destination_team),current_setting('test.hygiene_assignment')::uuid)),(select scheduled_move_id from scheduled_move),'same pending destination returns existing scheduled move');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.hygiene_staff')::uuid,(select team_id from alternate_team),current_setting('test.hygiene_assignment')::uuid)$$,'23505','staff pending move already exists','different pending destination is rejected');
reset role;

update public.operational_staff_assignments assignment set valid_from=move.requested_business_date
from public.operational_staff_scheduled_team_moves move
where move.operational_staff_id=current_setting('test.hygiene_staff')::uuid and move.status='pending'
  and assignment.id=move.source_assignment_id;
update public.branches set timezone='Pacific/Kiritimati' where id='3ac00000-0000-4000-8000-000000000001';
set local role service_role;
select is((select move_status from public.apply_due_operational_staff_team_moves('3ac00000-0000-4000-8000-000000000001') where staff_id=current_setting('test.hygiene_staff')::uuid),'applied','due scheduled reassignment applies through canonical job');
reset role;
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.hygiene_staff')::uuid and active),(select team_id from destination_team),'scheduled activation creates destination assignment');
select is((select display_name_snapshot from public.hygiene_staff_snapshots where submission_id=current_setting('test.hygiene_submission')::uuid and operational_staff_id=current_setting('test.hygiene_staff')::uuid),'Hygiene Candidate','historical submitted Hygiene snapshot remains unchanged after activation');

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',(select team_id from source_team),'Destination Submitted Candidate',array['kitchen'],null,'Internal Reassign Org',null,null,null,null,null)$$,'destination-submitted test employee created');
reset role;
select set_config('test.destination_submitted_staff',(select id::text from public.operational_staff where display_name='Destination Submitted Candidate'),false);
select set_config('test.destination_submitted_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.destination_submitted_staff')::uuid and active),false);
select ok(not exists(
  select 1
  from public.hygiene_staff_snapshots snapshot
  join public.checklist_submissions submission on submission.id=snapshot.submission_id
  where snapshot.operational_staff_id=current_setting('test.destination_submitted_staff')::uuid
    and submission.operational_team_id=(select team_id from source_team)
    and submission.business_date=private.phase4a_business_date('Pacific/Kiritimati')
    and submission.checklist_type='staff_hygiene'
    and submission.state='submitted'
),'destination-submitted case starts without source Hygiene for the staff');
create temp table destination_hygiene_answers as
select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
  'staff_id',staff.id::text,
  'uniform','pass',
  'fingernails','pass',
  'hair','pass',
  'facial_hair','pass',
  'remark',''
) order by staff.id),'[]'::jsonb) as answers
from public.operational_staff_assignments assignment
join public.operational_staff staff on staff.id=assignment.operational_staff_id
left join public.operational_staff_duty_statuses duty
  on duty.assignment_id=assignment.id
 and duty.duty_date=private.phase4a_business_date('Pacific/Kiritimati')
where assignment.operational_team_id=(select team_id from destination_team)
  and assignment.active
  and assignment.valid_from<=private.phase4a_business_date('Pacific/Kiritimati')
  and (assignment.valid_to is null or assignment.valid_to>=private.phase4a_business_date('Pacific/Kiritimati'))
  and staff.employment_status='active'
  and coalesce(duty.duty_status,'on_duty')='on_duty';
grant select on destination_hygiene_answers to service_role;
set local role service_role;
select lives_ok($$select * from public.submit_operational_team_hygiene(
  '1ac00000-0000-4000-8000-000000000003',
  '3ac00000-0000-4000-8000-000000000001',
  (select team_id from destination_team),
  '7ac00000-0000-4000-8000-000000000002',
  repeat('d',64),
  (select answers from destination_hygiene_answers)
)$$,'destination team submits Hygiene before independent reassignment');
reset role;
select set_config('test.destination_submission',(select id::text from public.checklist_submissions where operational_team_id=(select team_id from destination_team) and checklist_type='staff_hygiene' and state='submitted' order by submitted_at desc limit 1),false);

set local role service_role;
create temp table destination_scheduled_move as
select * from public.reassign_internal_admin_operational_staff_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  current_setting('test.destination_submitted_staff')::uuid,
  (select team_id from destination_team),
  current_setting('test.destination_submitted_assignment')::uuid
);
reset role;

select is((select move_status from destination_scheduled_move),'scheduled','submitted destination Hygiene schedules reassignment');
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.destination_submitted_staff')::uuid and active),(select team_id from source_team),'destination-submitted scheduled employee remains in source team today');
select is((select state from public.checklist_submissions where id=current_setting('test.destination_submission')::uuid),'submitted','submitted destination Hygiene remains unchanged');
select is((select destination_operational_team_id from public.operational_staff_scheduled_team_moves where id=(select scheduled_move_id from destination_scheduled_move)),(select team_id from destination_team),'destination-submitted scheduled move points to destination team');

select * from finish();
rollback;
