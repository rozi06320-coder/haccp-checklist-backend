create extension if not exists pgtap;
begin;
select plan(34);

-- This test deliberately creates two supervisors and two operational teams in
-- one branch, plus a branch with no team and a separate organization.  All
-- assertions execute the installed RPCs and overview functions.
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  'a1000000-0000-4000-8000-000000000001'::uuid,
  'a1000000-0000-4000-8000-000000000002'::uuid,
  'a1000000-0000-4000-8000-000000000003'::uuid
]) id;
update public.profiles set full_name='Staff Hygiene Runtime Fixture',must_change_password=false
where id::text like 'a1000000%';

insert into public.organizations(id,name,slug) values
  ('a2000000-0000-4000-8000-000000000001','Staff Hygiene Runtime Org','staff-hygiene-runtime-org'),
  ('a2000000-0000-4000-8000-000000000002','Staff Hygiene Other Org','staff-hygiene-other-org');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('a2000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('a3000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','Runtime Branch','RT','Asia/Riyadh',true),
  ('a3000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','No Team Branch','NT','Asia/Riyadh',true),
  ('a3000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000002','Other Org Branch','OT','Asia/Riyadh',true);
insert into public.branch_memberships(branch_id,user_id,role) values
 ('a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','branch_manager'),
 ('a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002','branch_manager'),
 ('a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000003','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001'),
 ('a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002');
select set_config('test.team_a',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='a4000000-0000-4000-8000-000000000001'),false);
select set_config('test.team_b',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='a4000000-0000-4000-8000-000000000002'),false);
update public.daily_report_branch_lifecycle
set effective_from_business_date='2026-10-29'
where organization_id='a2000000-0000-4000-8000-000000000001'
  and branch_id in ('a3000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000002');
update public.branch_operational_team_supervisors
set valid_from='2026-10-29'
  where operational_team_id in (current_setting('test.team_a')::uuid,current_setting('test.team_b')::uuid);
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-10-29 00:59:00+00'::timestamptz),'2026-10-28'::date,'03:59 branch-local time uses the prior business date');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-10-29 01:00:00+00'::timestamptz),'2026-10-29'::date,'04:00 branch-local time rolls to the new business date');

insert into public.operational_staff(id,organization_id,branch_id,display_name,employment_status,created_by)
values ('a5000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','Eligible B','active','a1000000-0000-4000-8000-000000000002');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_roles,valid_from)
values ('a6000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a5000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000002',array['kitchen'],'2026-10-01');

-- Supervisor A has an empty team; Supervisor B has one eligible member.
select is((select required from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29') where operational_team_id=current_setting('test.team_a')::uuid),false,'empty Team A is not applicable');
select is((select eligible_staff_count from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29') where operational_team_id=current_setting('test.team_b')::uuid),1::bigint,'Team B counts its eligible staff only');
select is((select required from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29') where operational_team_id=current_setting('test.team_b')::uuid),true,'Team B is required independently of Team A');
select is((select (branch->'checklists'->2->>'expected_checks')::int from jsonb_array_elements(public.get_phase4a_management_overview('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001')->'branches') branch where branch->>'branch_id'='a3000000-0000-4000-8000-000000000001'),4,'Manager overview counts eligible Team B but not N/A Team A');
select is((public.get_phase4a_supervisor_overview('a1000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int,4,'Supervisor B sees the eligible team before duty changes');
select is((select count(*) from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29') where branch_id='a3000000-0000-4000-8000-000000000002'),0::bigint,'branch with no operational team has no required Hygiene row');
select is((select count(*) from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29') where branch_id='a3000000-0000-4000-8000-000000000003'),0::bigint,'other organization rows are never returned');
select throws_ok($$select * from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000002','2026-10-29')$$,'42501',null,'manager from Org A cannot read Org B');

-- Effective dates and duty status are evaluated for the requested business date.
update public.operational_staff_assignments set valid_from='2026-11-01' where id='a6000000-0000-4000-8000-000000000001';
select is((select eligible_staff_count from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29') where operational_team_id=current_setting('test.team_b')::uuid),0::bigint,'future assignment is not eligible');
select is((select eligible_staff_count from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-11-01') where operational_team_id=current_setting('test.team_b')::uuid),1::bigint,'assignment becomes eligible on its effective date');
update public.operational_staff_assignments set valid_from='2026-10-01' where id='a6000000-0000-4000-8000-000000000001';
insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
values('a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a5000000-0000-4000-8000-000000000001','a6000000-0000-4000-8000-000000000001','2026-10-29','day_off','a1000000-0000-4000-8000-000000000002');
select is((select eligible_staff_count from public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29') where operational_team_id=current_setting('test.team_b')::uuid),0::bigint,'all off-duty staff are not eligible');

-- Existing draft and submitted snapshots remain byte-for-byte unchanged.
insert into public.checklist_submissions(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at,operational_team_id,operational_team_name_snapshot,submitted_by_user_id,hygiene_revision)
values('a7000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002','a4000000-0000-4000-8000-000000000002','2026-10-30','staff_hygiene','staff_hygiene_v1','draft','Runtime Branch','RT','Supervisor B',null,current_setting('test.team_b')::uuid,'Team B','a1000000-0000-4000-8000-000000000002',1),
       ('a7000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002','a4000000-0000-4000-8000-000000000002','2026-10-28','staff_hygiene','staff_hygiene_v1','submitted','Runtime Branch','RT','Supervisor B','2026-10-29 01:00:00+00',current_setting('test.team_b')::uuid,'Team B','a1000000-0000-4000-8000-000000000002',1);
insert into public.hygiene_staff_snapshots(submission_id,operational_staff_id,display_name_snapshot,operational_roles_snapshot,uniform_result,fingernails_result,hair_result,facial_hair_result)
values('a7000000-0000-4000-8000-000000000001','a5000000-0000-4000-8000-000000000001','Eligible B',array['kitchen'],'pass','pass','pass','pass'),
      ('a7000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000001','Eligible B',array['kitchen'],'issue','pass','pass','pass');
select is((select state from public.checklist_submissions where id='a7000000-0000-4000-8000-000000000001'),'draft','existing draft remains readable');
select is((select uniform_result from public.hygiene_staff_snapshots where submission_id='a7000000-0000-4000-8000-000000000002'),'issue','submitted snapshot starts with its stored value');
select public.get_daily_report_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29');
select is((select state from public.checklist_submissions where id='a7000000-0000-4000-8000-000000000001'),'draft','applicability read does not delete or rewrite drafts');
select is((select uniform_result from public.hygiene_staff_snapshots where submission_id='a7000000-0000-4000-8000-000000000002'),'issue','applicability read does not mutate submitted snapshots');

-- Overview consumers use the same team-specific applicability.
select is((public.get_phase4a_supervisor_overview('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int,0,'Supervisor A sees N/A for the empty team');
select is((public.get_phase4a_supervisor_overview('a1000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int,0,'Supervisor B becomes N/A when all staff are off duty');
select is((public.get_phase4a_supervisor_overview('a1000000-0000-4000-8000-000000000003','a3000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int,0,'Supervisor with no operational-team assignment is N/A');
select is((select (branch->'checklists'->2->>'expected_checks')::int from jsonb_array_elements(public.get_phase4a_management_overview('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001')->'branches') branch where branch->>'branch_id'='a3000000-0000-4000-8000-000000000001'),0,'Manager overview becomes N/A when all staff are off duty');
select is((public.list_phase4a_managed_issues('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001',1,50,null,null,null,null,null,'staff_hygiene',null,null)->>'total')::int,0,'N/A Staff Hygiene does not create missing issues');

-- Phase A.2 supervisor-scoped contract: authorization is checked before the
-- explicit no-team N/A result, and team rows never cross branch/org scope.
select is((select applicability from public.get_supervisor_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','2026-10-29') where operational_team_id=current_setting('test.team_a')::uuid),'not_applicable','authorized empty supervisor team is N/A');
select is((select count(*) from public.get_supervisor_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a3000000-0000-4000-8000-000000000001','2026-10-29')),1::bigint,'authorized supervisor without an assigned team receives one explicit N/A row');
select throws_ok($$select * from public.get_supervisor_staff_hygiene_applicability('a9000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','2026-10-29')$$,'42501',null,'unauthorized actor is rejected, never treated as N/A');
select throws_ok($$select * from public.get_supervisor_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a3000000-0000-4000-8000-000000000002','2026-10-29')$$,'42501',null,'cross-branch supervisor read is denied');
select throws_ok($$select * from public.get_supervisor_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000003','a3000000-0000-4000-8000-000000000003','2026-10-29')$$,'42501',null,'cross-organization supervisor read is denied');
update public.branch_operational_team_supervisors set active=false,valid_from='2026-10-01',valid_to='2026-10-28' where supervisor_user_id='a1000000-0000-4000-8000-000000000002' and operational_team_id=current_setting('test.team_b')::uuid;
select is((select applicability from public.get_supervisor_staff_hygiene_applicability('a1000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001','2026-10-29') where operational_team_id is null),'not_applicable','expired supervisor assignment cannot expose a team');
select is((select count(*) from information_schema.routine_privileges where routine_schema='public' and routine_name='get_supervisor_staff_hygiene_applicability' and grantee='service_role' and privilege_type='EXECUTE'),1::bigint,'supervisor read RPC is executable by service_role');
select is((select count(*) from public.get_manager_staff_hygiene_applicability_range('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29','2026-10-30') where branch_id='a3000000-0000-4000-8000-000000000002' and operational_team_id is null),2::bigint,'manager range includes historical no-team branch rows');
select is((select count(distinct business_date) from public.get_manager_staff_hygiene_applicability_range('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-29','2026-10-30')),2::bigint,'manager range returns every requested eligible date');
select throws_ok($$select * from public.get_manager_staff_hygiene_applicability_range('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','2026-10-01','2026-11-01')$$,'22023',null,'manager range rejects more than 31 dates');
select throws_ok($$select * from public.get_manager_staff_hygiene_applicability_range('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000002','2026-10-29','2026-10-30')$$,'42501',null,'manager range denies cross-organization access');
select is((select count(*) from information_schema.routine_privileges where routine_schema='public' and routine_name='get_manager_staff_hygiene_applicability_range' and grantee='service_role' and privilege_type='EXECUTE'),1::bigint,'manager range RPC is executable by service_role');

select * from finish();
rollback;
