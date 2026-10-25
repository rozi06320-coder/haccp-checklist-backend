begin;
select plan(42);

select has_function('private','phase4a_managed_missed_issue_rows_at',array['uuid','timestamp with time zone'],'deterministic Phase4A missing helper exists');
select has_function('private','oil_tracking_managed_missed_issue_rows_at',array['uuid','timestamp with time zone'],'deterministic Oil missing helper exists');
select has_function('private','cold_storage_managed_missed_issue_rows_at',array['uuid','timestamp with time zone'],'deterministic Cold missing helper exists');
select has_function('private','sales_tracking_managed_issue_rows_at',array['uuid','timestamp with time zone'],'deterministic Sales missing helper exists');
select has_function('private','management_branch_existed_at_business_day_start',array['text','timestamp with time zone','date'],'branch activation boundary helper exists');

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '19000000-0000-4000-8000-000000000001'::uuid,
  '19000000-0000-4000-8000-000000000002',
  '19000000-0000-4000-8000-000000000003',
  '19000000-0000-4000-8000-000000000004'
]) id;
update public.profiles
set full_name=case id
  when '19000000-0000-4000-8000-000000000001' then 'Supervisor A'
  when '19000000-0000-4000-8000-000000000002' then 'Supervisor B'
  when '19000000-0000-4000-8000-000000000003' then 'Manager A'
  else 'Manager B' end,
  must_change_password=false
where id::text like '19000000-%';

insert into public.organizations(id,name,slug) values
  ('29000000-0000-4000-8000-000000000001','Branch Issue Org','branch-issue-org'),
  ('29000000-0000-4000-8000-000000000002','Other Branch Issue Org','other-branch-issue-org');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('29000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000003','organization_manager'),
  ('29000000-0000-4000-8000-000000000002','19000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone,created_at) values
  ('39000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','Shared Branch','SHR','Asia/Riyadh','2026-10-01 00:00:00+00'),
  ('39000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','No Supervisor Branch','NSV','Asia/Riyadh','2026-10-24 00:00:00+00'),
  ('39000000-0000-4000-8000-000000000003','29000000-0000-4000-8000-000000000002','Other Branch','OTH','Asia/Riyadh','2026-10-01 00:00:00+00'),
  ('39000000-0000-4000-8000-000000000004','29000000-0000-4000-8000-000000000001','Created Near Cutoff','NCO','Asia/Riyadh','2026-10-25 00:30:00+00');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000001','branch_manager'),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('49000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000001'),
  ('49000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000002');

select set_config('test.scope_team_a',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='49000000-0000-4000-8000-000000000001'),false);
select set_config('test.scope_team_b',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='49000000-0000-4000-8000-000000000002'),false);
update public.branch_operational_teams
set created_at='2026-10-01 00:00:00+00'
where id in(current_setting('test.scope_team_a')::uuid,current_setting('test.scope_team_b')::uuid);

insert into public.branch_operational_team_supervisors(
  organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
) values(
  '29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',
  current_setting('test.scope_team_a')::uuid,'19000000-0000-4000-8000-000000000002','backup','19000000-0000-4000-8000-000000000003'
);

insert into public.operational_staff(id,organization_id,branch_id,display_name,created_by) values
  ('59000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Team A Staff','19000000-0000-4000-8000-000000000001'),
  ('59000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Team B Staff','19000000-0000-4000-8000-000000000002');
insert into public.operational_staff_assignments(
  id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles,valid_from
) values
  ('69000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','59000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001',current_setting('test.scope_team_a')::uuid,array['kitchen'],'2026-10-01'),
  ('69000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','59000000-0000-4000-8000-000000000002','49000000-0000-4000-8000-000000000002',current_setting('test.scope_team_b')::uuid,array['kitchen'],'2026-10-01');

-- Supervisor A's opening satisfies the branch-owned requirement for both supervisors.
insert into public.checklist_submissions(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,
  checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,
  supervisor_name_snapshot,submitted_at,branch_revision,updated_by_user_id,submitted_by_user_id
) values(
  '79000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',
  '19000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001','2026-10-24',
  'kitchen_opening','kitchen_opening_v1','submitted','Shared Branch','SHR','Supervisor A','2026-10-25 00:59:00+00',1,
  '19000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000001'
);

select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 00:59:59+00') where branch_id='39000000-0000-4000-8000-000000000001'),0::bigint,'03:59:59 has no closed daily requirement');
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and checklist_type='kitchen_opening'),0::bigint,'one supervisor submission satisfies branch Kitchen Opening');
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and checklist_type='foh_opening'),1::bigint,'missing FOH produces exactly one branch issue');
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000002' and checklist_type in('kitchen_opening','foh_opening')),2::bigint,'branch without a supervisor still has one issue per required opening');
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where supervisor_user_id is not null or submitted_by is not null),0::bigint,'derived missing rows have no supervisor attribution');
select is((select min(business_date) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00')),'2026-10-24'::date,'04:00 evaluates the business date that just closed');

select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-24 11:59:00+00') where branch_id='39000000-0000-4000-8000-000000000002'),0::bigint,'Oil Opening remains pending at 14:59 local');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-24 12:00:00+00') where branch_id='39000000-0000-4000-8000-000000000002' and section='opening'),1::bigint,'Oil Opening becomes missing at 15:00 local');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-24 20:59:00+00') where branch_id='39000000-0000-4000-8000-000000000002' and section='opening'),1::bigint,'Oil Opening remains missing at 23:59 local');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 00:59:59+00') where branch_id='39000000-0000-4000-8000-000000000002' and section='opening'),1::bigint,'Oil Opening remains missing at 03:59:59 local');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000002' and section='opening'),1::bigint,'closed business day retains its missing Oil Opening at 04:00');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000002' and section='closing'),1::bigint,'closed business day independently requires Oil Closing at 04:00');
select is((select min(business_date) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000002'),'2026-10-24'::date,'Oil rollover preserves the branch-local calendar boundary');

select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000004'),0::bigint,'03:30-created branch has no Opening obligation for a business day that began before creation');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000004'),0::bigint,'03:30-created branch has no historical Oil obligation at 04:00');
select is((select count(*) from private.cold_storage_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000004'),0::bigint,'03:30-created branch has no historical Cold obligation at 04:00');
select is((select count(*) from private.sales_tracking_managed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000004' and item_id='not_checked'),0::bigint,'03:30-created branch has no Sales obligation for a business day that began before creation');

-- Team A is completed by its authorized backup. Team B remains independently required.
insert into public.checklist_submissions(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,operational_team_id,
  operational_team_name_snapshot,submitted_by_user_id,hygiene_revision,business_date,
  checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,
  supervisor_name_snapshot,submitted_at
) values(
  '79000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',
  '19000000-0000-4000-8000-000000000002','49000000-0000-4000-8000-000000000001',current_setting('test.scope_team_a')::uuid,
  'Team A','19000000-0000-4000-8000-000000000002',1,'2026-10-24','staff_hygiene','staff_hygiene_v1','submitted',
  'Shared Branch','SHR','Supervisor B','2026-10-25 00:59:00+00'
);
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where checklist_type='staff_hygiene' and branch_id='39000000-0000-4000-8000-000000000001'),1::bigint,'backup completion satisfies Team A while Team B remains missing');
select is((select count(distinct id) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where checklist_type='staff_hygiene'),1::bigint,'multiple supervisors do not duplicate a team Hygiene requirement');
update public.operational_staff set employment_status='inactive',deactivated_at='2026-10-25 02:00:00+00',deactivated_by='19000000-0000-4000-8000-000000000003' where id='59000000-0000-4000-8000-000000000002';
update public.operational_staff_assignments set active=false,valid_to='2026-10-24',closed_at='2026-10-25 02:00:00+00',closed_by_user_id='19000000-0000-4000-8000-000000000003',closure_reason='left_company' where id='69000000-0000-4000-8000-000000000002';
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where checklist_type='staff_hygiene'),1::bigint,'post-cutoff employee deactivation does not erase the prior-day Hygiene requirement');
update public.operational_staff set employment_status='active',deactivated_at=null,deactivated_by=null where id='59000000-0000-4000-8000-000000000002';
update public.operational_staff_assignments set active=true,valid_to=null,closed_at=null,closed_by_user_id=null,closure_reason=null where id='69000000-0000-4000-8000-000000000002';
update public.operational_staff_assignments set active=false,valid_to='2026-10-24',closed_at='2026-10-25 02:05:00+00',closed_by_user_id='19000000-0000-4000-8000-000000000003',closure_reason='branch_transfer' where id='69000000-0000-4000-8000-000000000002';
update public.operational_staff set branch_id='39000000-0000-4000-8000-000000000002' where id='59000000-0000-4000-8000-000000000002';
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where checklist_type='staff_hygiene' and branch_id='39000000-0000-4000-8000-000000000001'),1::bigint,'post-cutoff branch transfer preserves the source-team Hygiene requirement');
update public.operational_staff_assignments set valid_to='2026-10-23',active=false where id='69000000-0000-4000-8000-000000000002';
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where checklist_type='staff_hygiene'),0::bigint,'team with no eligible on-duty staff has no Hygiene requirement');

insert into public.oil_tracking_submissions(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,
  branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot,opening_submitted_at
) values(
  '89000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',
  '19000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001','2026-10-24','draft',
  'Shared Branch','Supervisor A','Team A','2026-10-24 12:00:00+00'
);
insert into public.oil_tracking_fryer_results(submission_id,fryer_id,fryer_label_snapshot,fryer_short_label_snapshot,in_use_today,oil_status,opening_temperature_c,opening_status)
values('89000000-0000-4000-8000-000000000001','fryer-1','Fryer 1','Fryer 1',true,'new_oil',170,'pass');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 12:30:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and section='opening'),1::bigint,'current-day Oil Opening remains separately required after its cutoff');
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 12:30:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and section='closing'),1::bigint,'submitted prior-day Oil Opening leaves exactly one Closing issue');
update public.oil_tracking_submissions set closing_submitted_at='2026-10-25 00:59:00+00' where id='89000000-0000-4000-8000-000000000001';
select is((select count(*) from private.oil_tracking_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 12:30:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and business_date='2026-10-24'),0::bigint,'both prior-day Oil sections complete without per-supervisor duplicates');

insert into public.cold_storage_submissions(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,
  branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot
) values(
  '99000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',
  '19000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001','2026-10-24','draft',
  'Shared Branch','Supervisor A','Team A'
);
insert into public.cold_storage_equipment(submission_id,equipment_id,equipment_name,equipment_type,active)
values('99000000-0000-4000-8000-000000000001','cold-1','Cold 1','refrigerator',true);
insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values('99000000-0000-4000-8000-000000000001','cold-1','12:00',2,'pass','2026-10-24 17:00:00+00');
select is((select count(*) from private.cold_storage_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and business_date='2026-10-24'),2::bigint,'submitted Cold slot is satisfied once and only remaining slots are missing');
select is((select count(*) from private.cold_storage_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and slot='12:00'),0::bigint,'another supervisor does not regenerate a completed Cold slot');

insert into public.sales_tracking_report_cases(id,organization_id,branch_id,business_date)
values('a9000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','2026-10-24');
insert into public.sales_tracking_reports(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,submitted_at,
  branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,case_id,version_number,
  supersedes_report_id,correction_created_by_user_id,correction_created_at
) values
  ('b9000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001','2026-10-24','superseded','2026-10-25 00:50:00+00','Shared Branch','Supervisor A','Team A','a9000000-0000-4000-8000-000000000001',1,null,null,null),
  ('b9000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000002','49000000-0000-4000-8000-000000000002','2026-10-24','submitted','2026-10-25 00:55:00+00','Shared Branch','Supervisor B','Team B','a9000000-0000-4000-8000-000000000001',2,'b9000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000002','2026-10-25 00:51:00+00');
update public.sales_tracking_report_cases set authoritative_report_id='b9000000-0000-4000-8000-000000000002' where id='a9000000-0000-4000-8000-000000000001';
select is((select count(*) from private.sales_tracking_managed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000001' and item_id='not_checked'),0::bigint,'authoritative Sales correction satisfies the branch requirement');
select is((select count(*) from private.sales_tracking_managed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where report_id='b9000000-0000-4000-8000-000000000001'),0::bigint,'superseded Sales report is excluded');

select set_config('test.branch_issue_count_before',(select count(*)::text from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000001'),false);
update public.branch_supervisor_teams set active=false where id='49000000-0000-4000-8000-000000000002';
select is((select count(*) from private.phase4a_managed_missed_issue_rows_at('29000000-0000-4000-8000-000000000001','2026-10-25 01:00:00+00') where branch_id='39000000-0000-4000-8000-000000000001'),current_setting('test.branch_issue_count_before')::bigint,'supervisor transfer does not change branch requirement count');

select throws_ok($$select public.list_phase4a_managed_issues('19000000-0000-4000-8000-000000000004','29000000-0000-4000-8000-000000000001')$$,'42501','issue access denied','cross-tenant manager cannot list issues');
select is(public.list_phase4a_managed_issues('19000000-0000-4000-8000-000000000003','29000000-0000-4000-8000-000000000001',1,20,null,null,'39000000-0000-4000-8000-000000000003')->>'total','0','foreign-organization branch filter cannot expose issues');
select is(has_function_privilege('authenticated','public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot execute Manager Issues RPC');
select is(has_function_privilege('service_role','public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),true,'service role retains Manager Issues RPC execution');
select is(has_function_privilege('authenticated','private.phase4a_managed_missed_issue_rows_at(uuid,timestamptz)','execute'),false,'deterministic private helper is not browser executable');
select is(has_function_privilege('authenticated','private.management_branch_existed_at_business_day_start(text,timestamptz,date)','execute'),false,'branch activation helper is not browser executable');
select is((select proconfig from pg_proc where oid='private.phase4a_managed_missed_issue_rows_at(uuid,timestamptz)'::regprocedure),array['search_path=""']::text[],'private helper has empty search_path');

select * from finish();
rollback;
