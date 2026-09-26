begin;
select plan(46);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',email,'{}','{}',now(),now()
from (values
  ('1ac00000-0000-4000-8000-000000000001'::uuid,'admin@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000002'::uuid,'source-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000003'::uuid,'destination-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000004'::uuid,'other-branch-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000005'::uuid,'not-admin@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000006'::uuid,'backup-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000007'::uuid,'other-org-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000008'::uuid,'disabled-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000009'::uuid,'password-change-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000010'::uuid,'inactive-membership-supervisor@example.invalid'),
  ('1ac00000-0000-4000-8000-000000000011'::uuid,'backup-c-supervisor@example.invalid')
) users(id,email);

update public.profiles
set full_name = case id
  when '1ac00000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1ac00000-0000-4000-8000-000000000002' then 'Source Supervisor'
  when '1ac00000-0000-4000-8000-000000000003' then 'Destination Supervisor'
  when '1ac00000-0000-4000-8000-000000000004' then 'Other Branch Supervisor'
  when '1ac00000-0000-4000-8000-000000000006' then 'Backup Supervisor'
  when '1ac00000-0000-4000-8000-000000000007' then 'Other Org Supervisor'
  when '1ac00000-0000-4000-8000-000000000008' then 'Disabled Supervisor'
  when '1ac00000-0000-4000-8000-000000000009' then 'Password Change Supervisor'
  when '1ac00000-0000-4000-8000-000000000010' then 'Inactive Membership Supervisor'
  when '1ac00000-0000-4000-8000-000000000011' then 'Backup C Supervisor'
  else 'Not Admin'
end,
must_change_password=false
where id::text like '1ac00000-%';

insert into public.internal_admin_memberships(user_id,active)
values('1ac00000-0000-4000-8000-000000000001',true);

insert into public.organizations(id,name,slug) values
  ('2ac00000-0000-4000-8000-000000000001','Team Change Org','team-change-org'),
  ('2ac00000-0000-4000-8000-000000000002','Other Team Change Org','other-team-change-org');

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
  ('3ac00000-0000-4000-8000-000000000001','1ac00000-0000-4000-8000-000000000011','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000002','1ac00000-0000-4000-8000-000000000004','branch_manager',true),
  ('3ac00000-0000-4000-8000-000000000003','1ac00000-0000-4000-8000-000000000007','branch_manager',true);

create temp table source_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Source Team',
  'Team Change Org',
  '1ac00000-0000-4000-8000-000000000002',
  null,
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'display_name','Team Member',
    'company_name','Team Change Org',
    'staff_code','TEAM-01',
    'country_code','SA',
    'operational_roles',pg_catalog.jsonb_build_array('kitchen')
  ))
);

create temp table other_source_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Other Source Team',
  'Team Change Org',
  '1ac00000-0000-4000-8000-000000000002',
  '1ac00000-0000-4000-8000-000000000006',
  '[]'::jsonb
);

create temp table unaffected_source_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Unaffected Source Team',
  'Team Change Org',
  '1ac00000-0000-4000-8000-000000000002',
  null,
  '[]'::jsonb
);

create temp table inactive_team as
select * from public.create_internal_admin_operational_team(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  'Inactive Team',
  'Team Change Org',
  '1ac00000-0000-4000-8000-000000000002',
  null,
  '[]'::jsonb
);

select set_config('test.staff',(select id::text from public.operational_staff where staff_code='TEAM-01'),false);
select set_config('test.assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),false);
select set_config('test.source_team',(select team_id::text from source_team),false);
select set_config('test.source_primary',(select current_primary_assignment_id::text from public.list_internal_admin_branch_teams('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001') where team_id=(select team_id from source_team)),false);
select set_config('test.other_source_team',(select team_id::text from other_source_team),false);
select set_config('test.other_source_primary',(select current_primary_assignment_id::text from public.list_internal_admin_branch_teams('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001') where team_id=(select team_id from other_source_team)),false);
select set_config('test.unaffected_source_team',(select team_id::text from unaffected_source_team),false);

insert into public.branch_operational_team_supervisors(
  organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
)
values(
  '2ac00000-0000-4000-8000-000000000001',
  '3ac00000-0000-4000-8000-000000000001',
  current_setting('test.other_source_team')::uuid,
  '1ac00000-0000-4000-8000-000000000011',
  'backup',
  '1ac00000-0000-4000-8000-000000000001'
);

create temp table assignment_before as
select id, organization_id, branch_id, operational_staff_id, supervisor_team_id, operational_team_id, active, valid_from, valid_to, operational_roles::text as operational_roles
from public.operational_staff_assignments
where operational_staff_id=current_setting('test.staff')::uuid;

set local role service_role;
select lives_ok($$select * from public.submit_operational_team_hygiene(
  '1ac00000-0000-4000-8000-000000000002',
  '3ac00000-0000-4000-8000-000000000001',
  current_setting('test.source_team')::uuid,
  '9ac00000-0000-4000-8000-000000000001',
  repeat('h',64),
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'staff_id',current_setting('test.staff'),
    'uniform','pass',
    'fingernails','pass',
    'hair','pass',
    'facial_hair','pass',
    'remark','historical snapshot'
  ))
)$$,'submitted Hygiene history is created before primary Supervisor change');
select lives_ok($$select * from public.save_operational_staff_monthly_evaluation(
  '1ac00000-0000-4000-8000-000000000002',
  '3ac00000-0000-4000-8000-000000000001',
  current_setting('test.staff')::uuid,
  pg_catalog.date_trunc('month',current_date)::date,
  'Source Supervisor',
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'section','Performance',
    'factor_key','performance',
    'factor_label','Performance',
    'rating',5,
    'comment','Historical evaluation'
  )),
  'draft'
)$$,'monthly evaluation history is created before primary Supervisor change');
reset role;

select set_config('test.history_submission',(select id::text from public.checklist_submissions where operational_team_id=current_setting('test.source_team')::uuid and checklist_type='staff_hygiene' and state='submitted'),false);
select set_config('test.history_snapshot',(select id::text from public.hygiene_staff_snapshots where submission_id=current_setting('test.history_submission')::uuid and operational_staff_id=current_setting('test.staff')::uuid),false);
select set_config('test.monthly_evaluation',(select id::text from public.operational_staff_monthly_evaluations where operational_staff_id=current_setting('test.staff')::uuid and evaluation_month=pg_catalog.date_trunc('month',current_date)::date),false);

create temp table history_submission_before as
select id, organization_id, branch_id, supervisor_user_id, supervisor_team_id, operational_team_id,
  operational_team_name_snapshot, submitted_by_user_id, hygiene_revision, business_date,
  checklist_type, definition_id, state, branch_name_snapshot, branch_code_snapshot,
  supervisor_name_snapshot, submitted_at
from public.checklist_submissions
where id=current_setting('test.history_submission')::uuid;

create temp table hygiene_snapshot_before as
select id, submission_id, operational_staff_id, display_name_snapshot, operational_roles_snapshot::text as operational_roles_snapshot,
  remark, uniform_result, fingernails_result, hair_result, facial_hair_result
from public.hygiene_staff_snapshots
where id=current_setting('test.history_snapshot')::uuid;

create temp table monthly_evaluation_before as
select id, organization_id, branch_id, supervisor_team_id, operational_staff_id, evaluation_month,
  evaluator_name, status, average_score, evaluated_by_user_id
from public.operational_staff_monthly_evaluations
where id=current_setting('test.monthly_evaluation')::uuid;

select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1ac00000-0000-4000-8000-000000000003' and active),0::bigint,'destination Supervisor starts with zero team assignments');
select is((select count(*) from public.operational_staff_assignments assignment join public.branch_operational_team_supervisors supervisor_assignment on supervisor_assignment.operational_team_id=assignment.operational_team_id where supervisor_assignment.supervisor_user_id='1ac00000-0000-4000-8000-000000000003' and supervisor_assignment.active and assignment.active),0::bigint,'destination Supervisor starts with zero current staff');
select ok(private.actor_can_write_operational_team('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid),'old primary can write source team before change');
select ok(not private.actor_can_write_operational_team('1ac00000-0000-4000-8000-000000000003','3ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid),'new Supervisor cannot write source team before change');

set local role service_role;
create temp table primary_change as
select * from public.change_internal_admin_operational_team_primary_supervisor(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  current_setting('test.source_team')::uuid,
  '1ac00000-0000-4000-8000-000000000003',
  current_setting('test.source_primary')::uuid
);
reset role;

select is((select operational_team_id from primary_change),current_setting('test.source_team')::uuid,'Internal Admin changes primary A to B');
select is((select previous_supervisor_user_id from primary_change),'1ac00000-0000-4000-8000-000000000002'::uuid,'response identifies old primary');
select is((select new_supervisor_user_id from primary_change),'1ac00000-0000-4000-8000-000000000003'::uuid,'response identifies new primary');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.source_team')::uuid and assignment_role='primary' and active),1::bigint,'exactly one active primary remains');
select is((select supervisor_user_id from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.source_team')::uuid and assignment_role='primary' and active),'1ac00000-0000-4000-8000-000000000003'::uuid,'destination Supervisor is active primary');
select ok(not private.actor_can_write_operational_team('1ac00000-0000-4000-8000-000000000002','3ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid),'old primary loses current Team access');
select ok(private.actor_can_write_operational_team('1ac00000-0000-4000-8000-000000000003','3ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid),'new primary gains current Team access');
select is((select count(*) from ((select * from assignment_before) except (select id, organization_id, branch_id, operational_staff_id, supervisor_team_id, operational_team_id, active, valid_from, valid_to, operational_roles::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid)) diff),0::bigint,'staff assignment rows are unchanged');
select is((select id from public.operational_staff_assignments where operational_staff_id=current_setting('test.staff')::uuid and active),current_setting('test.assignment')::uuid,'staff active assignment id remains unchanged');
select is((select count(*) from public.account_management_audit_logs where action in ('supervisor_team_deactivated','supervisor_team_assigned') and details->>'team_id'=current_setting('test.source_team') and details->>'assignment_id' in (current_setting('test.source_primary'), (select new_primary_assignment_id::text from primary_change))),2::bigint,'audit records exactly once for deactivation and assignment');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1ac00000-0000-4000-8000-000000000002' and operational_team_id=current_setting('test.other_source_team')::uuid and assignment_role='primary' and active),1::bigint,'old Supervisor assignments on other teams remain active');
select is((select count(*) from ((select * from history_submission_before) except (select id, organization_id, branch_id, supervisor_user_id, supervisor_team_id, operational_team_id, operational_team_name_snapshot, submitted_by_user_id, hygiene_revision, business_date, checklist_type, definition_id, state, branch_name_snapshot, branch_code_snapshot, supervisor_name_snapshot, submitted_at from public.checklist_submissions where id=current_setting('test.history_submission')::uuid)) diff),0::bigint,'historical checklist submission row is unchanged');
select is((select count(*) from ((select * from hygiene_snapshot_before) except (select id, submission_id, operational_staff_id, display_name_snapshot, operational_roles_snapshot::text, remark, uniform_result, fingernails_result, hair_result, facial_hair_result from public.hygiene_staff_snapshots where id=current_setting('test.history_snapshot')::uuid)) diff),0::bigint,'historical Hygiene staff snapshot row is unchanged');
select is((select operational_team_id from public.checklist_submissions where id=current_setting('test.history_submission')::uuid),current_setting('test.source_team')::uuid,'historical submission remains tied to Team A');
select is((select supervisor_user_id from public.checklist_submissions where id=current_setting('test.history_submission')::uuid),'1ac00000-0000-4000-8000-000000000002'::uuid,'historical submission is not rewritten to the new primary Supervisor');
select is((select display_name_snapshot from public.hygiene_staff_snapshots where id=current_setting('test.history_snapshot')::uuid),'Team Member','historical snapshot display fields remain unchanged');
select is((select count(*) from ((select * from monthly_evaluation_before) except (select id, organization_id, branch_id, supervisor_team_id, operational_staff_id, evaluation_month, evaluator_name, status, average_score, evaluated_by_user_id from public.operational_staff_monthly_evaluations where id=current_setting('test.monthly_evaluation')::uuid)) diff),0::bigint,'monthly evaluation row is unchanged');
select is((select supervisor_team_id from public.operational_staff_monthly_evaluations where id=current_setting('test.monthly_evaluation')::uuid),(select supervisor_team_id from monthly_evaluation_before),'monthly evaluation remains tied to the original legacy supervisor team');

set local role service_role;
create temp table backup_promotion as
select * from public.change_internal_admin_operational_team_primary_supervisor(
  '1ac00000-0000-4000-8000-000000000001',
  '2ac00000-0000-4000-8000-000000000001',
  current_setting('test.other_source_team')::uuid,
  '1ac00000-0000-4000-8000-000000000006',
  current_setting('test.other_source_primary')::uuid
);
reset role;

select is((select new_supervisor_user_id from backup_promotion),'1ac00000-0000-4000-8000-000000000006'::uuid,'backup Supervisor promotes safely to primary');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and supervisor_user_id='1ac00000-0000-4000-8000-000000000006' and active),1::bigint,'promoted Supervisor has one active assignment on the team');
select is((select assignment_role from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and supervisor_user_id='1ac00000-0000-4000-8000-000000000006' and active),'primary','promoted backup is now primary');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and assignment_role='primary' and active),1::bigint,'backup promotion leaves exactly one active primary');
select is((select supervisor_user_id from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and assignment_role='primary' and active),'1ac00000-0000-4000-8000-000000000006'::uuid,'promoted backup is the active primary');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and supervisor_user_id='1ac00000-0000-4000-8000-000000000006' and assignment_role='backup' and active),0::bigint,'promoted Supervisor no longer has an active backup row');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and supervisor_user_id='1ac00000-0000-4000-8000-000000000011' and assignment_role='backup' and active),1::bigint,'other backup Supervisor C remains active backup');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and supervisor_user_id='1ac00000-0000-4000-8000-000000000002' and assignment_role='primary' and active),0::bigint,'old primary row is closed on promoted team');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.unaffected_source_team')::uuid and supervisor_user_id='1ac00000-0000-4000-8000-000000000002' and assignment_role='primary' and active),1::bigint,'old Supervisor assignments on unrelated teams remain unchanged');
select is((select count(*) from (select operational_team_id, supervisor_user_id from public.branch_operational_team_supervisors where operational_team_id=current_setting('test.other_source_team')::uuid and active group by operational_team_id, supervisor_user_id having count(*)>1) duplicates),0::bigint,'backup promotion leaves no duplicate active supervisor/team pair');

update public.branch_operational_teams set active=false where id=(select team_id from inactive_team);
update public.profiles set disabled_at=now() where id='1ac00000-0000-4000-8000-000000000008';
update public.profiles set must_change_password=true where id='1ac00000-0000-4000-8000-000000000009';
update public.branch_memberships set active=false where branch_id='3ac00000-0000-4000-8000-000000000001' and user_id='1ac00000-0000-4000-8000-000000000010';

select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000005','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000006',(select new_primary_assignment_id from primary_change))$$,'42501','internal admin access denied','non Internal Admin denied');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000004',(select new_primary_assignment_id from primary_change))$$,'23514','destination supervisor unavailable','cross-branch Supervisor rejected');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000007',(select new_primary_assignment_id from primary_change))$$,'23514','destination supervisor unavailable','cross-org Supervisor rejected');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',(select team_id from inactive_team),'1ac00000-0000-4000-8000-000000000006',(select current_primary_assignment_id from public.list_internal_admin_branch_teams('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001') where team_id=(select team_id from inactive_team)))$$,'23514','operational team is inactive','inactive team rejected');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000008',(select new_primary_assignment_id from primary_change))$$,'23514','destination supervisor unavailable','disabled profile rejected');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000009',(select new_primary_assignment_id from primary_change))$$,'23514','destination supervisor unavailable','must-change-password Supervisor rejected');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000010',(select new_primary_assignment_id from primary_change))$$,'23514','destination supervisor unavailable','inactive branch membership rejected');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000003',(select new_primary_assignment_id from primary_change))$$,'23505','destination supervisor is already primary','same current primary rejected');
select throws_ok($$select * from public.change_internal_admin_operational_team_primary_supervisor('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.source_team')::uuid,'1ac00000-0000-4000-8000-000000000006',current_setting('test.source_primary')::uuid)$$,'40001','operational team primary supervisor changed','stale expected primary rejected');
select throws_ok($$select * from public.reassign_internal_admin_operational_staff_team('1ac00000-0000-4000-8000-000000000001','2ac00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,current_setting('test.source_team')::uuid,current_setting('test.assignment')::uuid)$$,'0A000','staff reassignment endpoint has been retired','retired staff-level RPC fails closed');

select is((select count(*) from public.operational_staff_scheduled_team_moves),0::bigint,'scheduled-move infrastructure untouched by team primary change');
select is((select count(*) from public.operational_staff_supervisor_training),0::bigint,'Supervisor Training state remains unchanged');

select * from finish();
rollback;
