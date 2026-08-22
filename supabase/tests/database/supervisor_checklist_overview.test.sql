begin;
select plan(28);
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array['1a000000-0000-4000-8000-000000000001'::uuid,'1a000000-0000-4000-8000-000000000002','1a000000-0000-4000-8000-000000000003'])id;
update public.profiles set full_name='Overview Supervisor',must_change_password=false where id::text like '1a000000-%';
insert into public.organizations(id,name,slug)values('2a000000-0000-4000-8000-000000000001','Overview Org','overview-org');
insert into public.branches(id,organization_id,name,code,timezone)values('3a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','Overview Branch','OV','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role)values
 ('3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001','branch_manager'),
 ('3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002','branch_manager'),
 ('3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)values
 ('4a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001'),
 ('4a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002');
select set_config('test.overview_team_a',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='4a000000-0000-4000-8000-000000000001'),false);
select set_config('test.overview_team_b',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='4a000000-0000-4000-8000-000000000002'),false);
insert into public.operational_staff(id,organization_id,branch_id,display_name,created_by)values
 ('5a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','On Duty','1a000000-0000-4000-8000-000000000001'),
 ('5a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','Day Off','1a000000-0000-4000-8000-000000000001'),
 ('5a000000-0000-4000-8000-000000000003','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','Vacation','1a000000-0000-4000-8000-000000000001'),
 ('5a000000-0000-4000-8000-000000000004','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','Inactive','1a000000-0000-4000-8000-000000000001');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles)values
 ('6a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','5a000000-0000-4000-8000-000000000001','4a000000-0000-4000-8000-000000000001',current_setting('test.overview_team_a')::uuid,array['kitchen']),
 ('6a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','5a000000-0000-4000-8000-000000000002','4a000000-0000-4000-8000-000000000001',current_setting('test.overview_team_a')::uuid,array['cleaner']),
 ('6a000000-0000-4000-8000-000000000003','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','5a000000-0000-4000-8000-000000000003','4a000000-0000-4000-8000-000000000001',current_setting('test.overview_team_a')::uuid,array['cleaner']),
 ('6a000000-0000-4000-8000-000000000004','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','5a000000-0000-4000-8000-000000000004','4a000000-0000-4000-8000-000000000001',current_setting('test.overview_team_a')::uuid,array['cleaner']);
update public.operational_staff set employment_status='inactive',deactivated_at=now(),deactivated_by='1a000000-0000-4000-8000-000000000001' where id='5a000000-0000-4000-8000-000000000004';
insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
values
 ('2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','5a000000-0000-4000-8000-000000000002','6a000000-0000-4000-8000-000000000002',private.phase4a_business_date('Asia/Riyadh'),'day_off','1a000000-0000-4000-8000-000000000001'),
 ('2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','5a000000-0000-4000-8000-000000000003','6a000000-0000-4000-8000-000000000003',private.phase4a_business_date('Asia/Riyadh'),'on_vacation','1a000000-0000-4000-8000-000000000001');

select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'totals'->>'expected_checks')::int,39,'no state expects 17 + 18 + four hygiene checks');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'totals'->>'answered_checks')::int,0,'no state has no answers');
select is(public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'totals'->>'completion_percentage','0','valid expected zero-answer completion is zero');
select is(public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'totals'->>'compliance_percentage',null,'zero answered compliance is null');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int,4,'day off staff excluded before final');

insert into public.checklist_submissions(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot)
values('7a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001','4a000000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),'kitchen_opening','kitchen_opening_v1','draft','Overview Branch','OV','Overview Supervisor');
insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
select '7a000000-0000-4000-8000-000000000001','kitchen_opening_v1',i.item_id,i.ordinal,i.item_text,case when i.ordinal=1 then 'completed' when i.ordinal=2 then 'issue_found' else 'not_checked' end,case when i.ordinal=2 then 'finding' else '' end from public.checklist_definition_items i where i.definition_id='kitchen_opening_v1';
select pass('partial opening draft saves');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->0->>'answered_checks')::int,2,'completed and issue are answered');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->0->>'compliant_checks')::int,1,'only completed is compliant');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->0->>'issue_checks')::int,1,'issue found is counted as issue');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->0->>'completion_percentage')::int,12,'2/17 rounds to 12');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'totals'->>'completion_percentage')::int,5,'overall is weighted 2/39, not average percentages');
select is(public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000002','3a000000-0000-4000-8000-000000000001')->'checklists'->0->>'state','draft','same-branch Supervisor sees the shared Opening state');

insert into public.checklist_submissions(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,operational_team_id,operational_team_name_snapshot,submitted_by_user_id,hygiene_revision,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at,updated_at)
values
 ('7a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001','4a000000-0000-4000-8000-000000000001',current_setting('test.overview_team_a')::uuid,'Team A','1a000000-0000-4000-8000-000000000001',1,private.phase4a_business_date('Asia/Riyadh'),'staff_hygiene','staff_hygiene_v1','submitted','Overview Branch','OV','Overview Supervisor',now(),now()),
 ('7a000000-0000-4000-8000-000000000003','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000002','4a000000-0000-4000-8000-000000000002',current_setting('test.overview_team_b')::uuid,'Team B','1a000000-0000-4000-8000-000000000002',1,private.phase4a_business_date('Asia/Riyadh'),'staff_hygiene','staff_hygiene_v1','draft','Overview Branch','OV','Overview Supervisor',null,now()+interval '1 minute');
insert into public.hygiene_staff_snapshots(submission_id,operational_staff_id,display_name_snapshot,operational_roles_snapshot,remark,uniform_result,fingernails_result,hair_result,facial_hair_result)
values
 ('7a000000-0000-4000-8000-000000000002','5a000000-0000-4000-8000-000000000001','On Duty',array['kitchen'],'','pass','pass','pass','pass'),
 ('7a000000-0000-4000-8000-000000000002','5a000000-0000-4000-8000-000000000002','Day Off',array['cleaner'],'','pass','pass','pass','pass'),
 ('7a000000-0000-4000-8000-000000000002','5a000000-0000-4000-8000-000000000003','Vacation',array['cleaner'],'','pass','pass','pass','pass'),
 ('7a000000-0000-4000-8000-000000000002','5a000000-0000-4000-8000-000000000004','Inactive',array['cleaner'],'','pass','pass','pass','pass'),
 ('7a000000-0000-4000-8000-000000000003','5a000000-0000-4000-8000-000000000001','On Duty',array['kitchen'],'duplicate draft should lose','issue','issue','issue','issue');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int,4,'Staff Hygiene expects active on-duty staff only');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'answered_checks')::int,4,'Staff Hygiene excludes day-off vacation inactive and duplicate snapshots');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'compliant_checks')::int,4,'Staff Hygiene submitted values win over newer draft duplicates');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'issue_checks')::int,0,'duplicate draft issues do not double-count');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'pending_checks')::int,0,'Staff Hygiene pending is expected minus answered');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'completion_percentage')::int,100,'Staff Hygiene completion never exceeds 100 from real counts');
select ok((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'answered_checks')::int <= (public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int,'Staff Hygiene answered never exceeds expected');
select ok((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'pending_checks')::int = (public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'expected_checks')::int - (public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists'->2->>'answered_checks')::int,'Staff Hygiene pending invariant holds');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'totals'->>'expected_checks')::bigint,(select sum((row->>'expected_checks')::int)from jsonb_array_elements(public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists')row),'Overview totals expected equals component sum');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'totals'->>'answered_checks')::bigint,(select sum((row->>'answered_checks')::int)from jsonb_array_elements(public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists')row),'Overview totals answered equals component sum');
select is((public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')->'checklists')::text,(public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000002','3a000000-0000-4000-8000-000000000001')->'checklists')::text,'same-branch Supervisors see identical Overview after Hygiene aggregate fix');
select throws_ok($$select * from public.save_operational_team_hygiene_draft('1a000000-0000-4000-8000-000000000002','3a000000-0000-4000-8000-000000000001',current_setting('test.overview_team_a')::uuid,0,'[]')$$,'42501',null,'Staff Hygiene write scope remains team scoped');
select throws_ok($$select public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000003','3a000000-0000-4000-8000-000000000001')$$,'42501','overview access denied','legacy Staff denied');
update public.profiles set must_change_password=true where id='1a000000-0000-4000-8000-000000000001';
select throws_ok($$select public.get_phase4a_supervisor_overview('1a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')$$,'42501','overview access denied','forced-password Supervisor denied');
select is(has_function_privilege('authenticated','public.get_phase4a_supervisor_overview(uuid,uuid)','execute'),false,'authenticated cannot call overview RPC');
select is(has_function_privilege('service_role','public.get_phase4a_supervisor_overview(uuid,uuid)','execute'),true,'service role may call overview RPC');
select * from finish();rollback;
