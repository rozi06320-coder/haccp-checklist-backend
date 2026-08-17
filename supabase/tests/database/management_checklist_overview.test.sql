begin;
select plan(56);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '81000000-0000-4000-8000-000000000001'::uuid,
 '81000000-0000-4000-8000-000000000002',
 '82000000-0000-4000-8000-000000000001',
 '82000000-0000-4000-8000-000000000002',
 '82000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name='Manager Overview Fixture',must_change_password=false
where id::text like '81%' or id::text like '82%';

insert into public.organizations(id,name,slug) values
 ('83000000-0000-4000-8000-000000000001','Manager Overview Org','manager-overview-org'),
 ('83000000-0000-4000-8000-000000000002','Other Overview Org','other-overview-org');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('83000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001','organization_manager'),
 ('83000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000002','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone,active) values
 ('84000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001','Alpha Branch','ALPHA','Pacific/Kiritimati',true),
 ('84000000-0000-4000-8000-000000000002','83000000-0000-4000-8000-000000000001','Beta Branch','BETA','Pacific/Pago_Pago',true),
 ('84000000-0000-4000-8000-000000000003','83000000-0000-4000-8000-000000000001','Inactive Branch','INACTIVE','UTC',false);
insert into public.branch_memberships(branch_id,user_id,role) values
 ('84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000001','branch_manager'),
 ('84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000002','branch_manager'),
 ('84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('85000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000001'),
 ('85000000-0000-4000-8000-000000000002','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000002');
insert into public.operational_staff(id,organization_id,branch_id,display_name,created_by) values
 ('86000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','Multi Team Staff','82000000-0000-4000-8000-000000000001'),
 ('86000000-0000-4000-8000-000000000002','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','Day Off Staff','82000000-0000-4000-8000-000000000001'),
 ('86000000-0000-4000-8000-000000000003','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','Second Team Staff','82000000-0000-4000-8000-000000000002');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_roles) values
 ('87000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000001','85000000-0000-4000-8000-000000000001',array['kitchen']),
 ('87000000-0000-4000-8000-000000000002','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000003','85000000-0000-4000-8000-000000000002',array['front_of_house']),
 ('87000000-0000-4000-8000-000000000003','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000002','85000000-0000-4000-8000-000000000001',array['cleaner']);
insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
values('83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000002','87000000-0000-4000-8000-000000000003',private.phase4a_business_date('Pacific/Kiritimati'),'day_off','82000000-0000-4000-8000-000000000001');

create temporary table manager_overview_result(payload jsonb) on commit drop;
create temporary table overview_due_counts(kiritimati int, utc_count int) on commit drop;
insert into overview_due_counts
select
  case
    when extract(hour from statement_timestamp() at time zone 'Pacific/Kiritimati') < 12 then 0
    when extract(hour from statement_timestamp() at time zone 'Pacific/Kiritimati') < 15 then 1
    when extract(hour from statement_timestamp() at time zone 'Pacific/Kiritimati') < 20 then 2
    else 3
  end,
  case
    when extract(hour from statement_timestamp() at time zone 'UTC') < 12 then 0
    when extract(hour from statement_timestamp() at time zone 'UTC') < 15 then 1
    when extract(hour from statement_timestamp() at time zone 'UTC') < 20 then 2
    else 3
  end;
insert into manager_overview_result select public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');

select is((payload->'totals'->>'expected_checks')::int,84 + 2 * due.kiritimati,'two active teams expect opening, hygiene, Oil, due Cold, and Sales Tracking work') from manager_overview_result, overview_due_counts due;
select is((payload->'summary'->>'active_branch_count')::int,2,'multiple active branches are included') from manager_overview_result;
select is((payload->'summary'->>'active_team_count')::int,2,'multiple active teams in one branch are included') from manager_overview_result;
select is((payload->'summary'->>'active_supervisor_account_count')::int,2,'active Supervisor accounts are distinct') from manager_overview_result;
select is((payload->'summary'->>'active_operational_staff_count')::int,3,'active staff summary uses distinct staff IDs') from manager_overview_result;
select is(pg_catalog.jsonb_array_length(payload->'local_dates'),2,'one server snapshot derives two branch-local dates') from manager_overview_result;
select is(payload->'branches'->1->>'status','no_active_team','branch without team remains visible') from manager_overview_result;
select is((payload->'branches'->1->'totals'->>'expected_checks')::int,0,'branch without team gets no fabricated expected work') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->2->>'expected_checks')::int,8,'multi-team staff assignment is counted once per team and not join-multiplied') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->3->>'expected_checks')::int,4,'missing Oil Tracking state still expects opening and closing checks for each active team') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->3->>'pending_checks')::int,4,'missing Oil Tracking state is pending, not removed from the denominator') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->4->>'expected_checks')::int,2 * due.kiritimati,'missing Refrigerator and Freezer state still expects due slot checks for active teams') from manager_overview_result, overview_due_counts due;
select is((payload->'branches'->0->'checklists'->4->>'pending_checks')::int,2 * due.kiritimati,'missing Refrigerator and Freezer state is pending, not removed from the denominator') from manager_overview_result, overview_due_counts due;
select is((payload->'totals'->>'completion_percentage')::int,0,'no submissions never renders fabricated 100 percent completion') from manager_overview_result;

insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by) values
	 ('83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000001','87000000-0000-4000-8000-000000000001',private.phase4a_business_date('Pacific/Kiritimati'),'day_off','82000000-0000-4000-8000-000000000001'),
	 ('83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000003','87000000-0000-4000-8000-000000000002',private.phase4a_business_date('Pacific/Kiritimati'),'day_off','82000000-0000-4000-8000-000000000002');
update manager_overview_result set payload=public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');
select is((payload->'branches'->0->'checklists'->2->>'expected_checks')::int,0,'no On Duty staff is a valid zero hygiene denominator') from manager_overview_result;
delete from public.operational_staff_duty_statuses where assignment_id in('87000000-0000-4000-8000-000000000001','87000000-0000-4000-8000-000000000002');

insert into public.checklist_submissions(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot)
values('88000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000001','85000000-0000-4000-8000-000000000001',private.phase4a_business_date('Pacific/Kiritimati'),'kitchen_opening','kitchen_opening_v1','draft','Alpha Branch','ALPHA','Supervisor One');
insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
select '88000000-0000-4000-8000-000000000001','kitchen_opening_v1',item.item_id,item.ordinal,item.item_text,
 case when item.ordinal=1 then 'completed' when item.ordinal=2 then 'issue_found' else 'not_checked' end,
 case when item.ordinal=2 then 'Fixture issue' else '' end
from public.checklist_definition_items item where item.definition_id='kitchen_opening_v1';
update manager_overview_result set payload=public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');
select is((payload->'branches'->0->'checklists'->0->>'answered_checks')::int,0,'partial draft does not count as answered in Manager Overview') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->0->>'compliant_checks')::int,0,'partial draft does not count as compliant in Manager Overview') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->0->>'issue_checks')::int,0,'partial draft does not count as issue in Manager Overview') from manager_overview_result;
select is((payload->'totals'->>'pending_checks')::int,84 + 2 * due.kiritimati,'missing and draft submissions remain pending') from manager_overview_result, overview_due_counts due;
select is((payload->'branches'->0->'checklists'->1->>'pending_checks')::int,36,'both missing FOH submissions remain pending') from manager_overview_result;

insert into public.checklist_submissions(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at)
values('88000000-0000-4000-8000-000000000002','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000002','85000000-0000-4000-8000-000000000002',private.phase4a_business_date('Pacific/Kiritimati'),'foh_opening','foh_opening_v1','submitted','Alpha Branch','ALPHA','Supervisor Two',now());
insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
select '88000000-0000-4000-8000-000000000002','foh_opening_v1',item.item_id,item.ordinal,item.item_text,'completed',''
from public.checklist_definition_items item where item.definition_id='foh_opening_v1';
update manager_overview_result set payload=public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');
select is((payload->'totals'->>'expected_checks')::int,84 + 2 * due.kiritimati,'immutable final retains its snapshot denominator') from manager_overview_result, overview_due_counts due;
select is((payload->'totals'->>'answered_checks')::int,18,'only submitted final answers aggregate') from manager_overview_result;
select is((payload->'totals'->>'completion_percentage')::int,pg_catalog.round(18 * 100.0 / (84 + 2 * due.kiritimati))::int,'organization completion is weighted from submitted raw counts') from manager_overview_result, overview_due_counts due;
select throws_ok($$update public.opening_item_results set answer='issue_found' where submission_id='88000000-0000-4000-8000-000000000002'$$,'55000','submitted report is immutable','final snapshots remain immutable');

insert into public.sales_tracking_reports(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,submitted_at,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot)
values('88000000-0000-4000-8000-000000000101','83000000-0000-4000-8000-000000000001','84000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000001','85000000-0000-4000-8000-000000000001',private.phase4a_business_date('Pacific/Kiritimati'),'draft',null,'Alpha Branch','Supervisor One','Supervisor One Team');
insert into public.sales_tracking_sales_rows(report_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery)
values('88000000-0000-4000-8000-000000000101',private.phase4a_business_date('Pacific/Kiritimati'),100,50,90,50,25);
update public.sales_tracking_reports set state='submitted',submitted_at=now() where id='88000000-0000-4000-8000-000000000101';
update manager_overview_result set payload=public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');
select is((payload->'branches'->0->'checklists'->5->>'answered_checks')::int,1,'submitted Sales Tracking counts as answered') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->5->>'compliant_checks')::int,0,'Sales Tracking variance is not compliant') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->5->>'issue_checks')::int,1,'Sales Tracking variance counts as an issue') from manager_overview_result;

update manager_overview_result set payload=public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');
select is((payload->'branches'->0->'checklists'->5->>'answered_checks')::int,1,'Sales Tracking submissions count once per branch business day') from manager_overview_result;
select is((payload->'branches'->0->'checklists'->5->>'issue_checks')::int,1,'non-zero Sales Tracking variance counts as an issue') from manager_overview_result;
select is((payload->'totals'->>'issue_checks')::int,1,'organization totals include only submitted Sales Tracking variance issues') from manager_overview_result;

update public.branch_supervisor_teams set active=false where id='85000000-0000-4000-8000-000000000002';
update public.branch_memberships set active=false where branch_id='84000000-0000-4000-8000-000000000001' and user_id='82000000-0000-4000-8000-000000000002';
update public.profiles set disabled_at=now() where id='82000000-0000-4000-8000-000000000002';
update manager_overview_result set payload=public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');
select is((payload->'summary'->>'active_team_count')::int,1,'deactivated team creates no new pending expectation') from manager_overview_result;
select is((payload->'totals'->>'expected_checks')::int,60 + due.kiritimati,'only active team expectations plus inactive team current-day finals remain') from manager_overview_result, overview_due_counts due;
select is((payload->'branches'->0->'checklists'->1->'team_states'->>'submitted')::int,1,'final remains represented after team lifecycle deactivation') from manager_overview_result;
select is((payload->'totals'->>'answered_checks')::int,19,'deactivated team final answers remain in Manager snapshot without draft counts') from manager_overview_result;

insert into public.branches(id,organization_id,name,code,timezone)values('84000000-0000-4000-8000-000000000004','83000000-0000-4000-8000-000000000001','Invalid Timezone Branch','BADTZ','Not/A_Timezone');
select throws_ok($$select public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001')$$,'22023','management overview timezone invalid','invalid active branch timezone fails the entire dataset safely');
delete from public.branches where id='84000000-0000-4000-8000-000000000004';
update manager_overview_result set payload=public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001');
select is(pg_catalog.jsonb_array_length(payload->'branches'),2,'inactive branch is excluded') from manager_overview_result;
select is((select pg_catalog.string_agg(branch->>'branch_name',',' order by ordinal) from manager_overview_result cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') with ordinality row(branch,ordinal)),'Alpha Branch,Beta Branch','branches are deterministically ordered by normalized name') from manager_overview_result;
select throws_ok($$select public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000002','83000000-0000-4000-8000-000000000001')$$,'42501','management overview access denied','cross-organization Manager denied');
select throws_ok($$select public.get_phase4a_management_overview('82000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001')$$,'42501','management overview access denied','Branch Supervisor denied');
select throws_ok($$select public.get_phase4a_management_overview('82000000-0000-4000-8000-000000000003','83000000-0000-4000-8000-000000000001')$$,'42501','management overview access denied','legacy Staff denied');
update public.profiles set must_change_password=true where id='81000000-0000-4000-8000-000000000001';
select throws_ok($$select public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001')$$,'42501','management overview access denied','forced-password Manager denied');
update public.profiles set must_change_password=false,disabled_at=now() where id='81000000-0000-4000-8000-000000000001';
select throws_ok($$select public.get_phase4a_management_overview('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001')$$,'42501','management overview access denied','disabled Manager denied');
update public.profiles set disabled_at=null where id='81000000-0000-4000-8000-000000000001';

select is(has_function_privilege('authenticated','public.get_phase4a_management_overview(uuid,uuid)','execute'),false,'authenticated cannot execute Manager Overview RPC');
select is(has_function_privilege('anon','public.get_phase4a_management_overview(uuid,uuid)','execute'),false,'anonymous cannot execute Manager Overview RPC');
select is(has_function_privilege('service_role','public.get_phase4a_management_overview(uuid,uuid)','execute'),true,'service role may execute narrow Manager Overview RPC');
select ok((select procedure.prosecdef from pg_catalog.pg_proc procedure where procedure.oid='public.get_phase4a_management_overview(uuid,uuid)'::regprocedure),'Manager Overview RPC is SECURITY DEFINER');
select ok((select procedure.proconfig @> array['search_path=""'] from pg_catalog.pg_proc procedure where procedure.oid='public.get_phase4a_management_overview(uuid,uuid)'::regprocedure),'Manager Overview RPC has an empty search_path');
select ok((select payload::text !~ '(email|remark|evidence|photo|token|cookie|signed_url|storage_path)' from manager_overview_result),'DTO contains no sensitive fields');
select is((select pg_catalog.min(pg_catalog.jsonb_array_length(branch->'checklists')) from manager_overview_result cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch),6,'every branch contains exactly six checklist rows') from manager_overview_result;
select is((select pg_catalog.count(*)-pg_catalog.count(distinct branch->>'branch_id') from manager_overview_result cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch),0::bigint,'DTO has no duplicate branch IDs') from manager_overview_result;
select is((select pg_catalog.count(*) from (select branch->>'branch_id' from manager_overview_result cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist group by branch->>'branch_id' having pg_catalog.count(distinct checklist->>'checklist_type')<>6) invalid_branch),0::bigint,'DTO has no duplicate checklist type per branch');
select is((select pg_catalog.count(*) from manager_overview_result cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist where (checklist->>'answered_checks')::int<>(checklist->>'compliant_checks')::int+(checklist->>'issue_checks')::int or (checklist->>'pending_checks')::int<>(checklist->>'expected_checks')::int-(checklist->>'answered_checks')::int),0::bigint,'all count invariants reconcile') from manager_overview_result;

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',('92000000-0000-4000-8000-'||pg_catalog.lpad(value::text,12,'0'))::uuid,'authenticated','authenticated','perf-'||value||'@example.invalid','{}','{}',now(),now() from pg_catalog.generate_series(1,501)value;
update public.profiles set full_name='Performance Fixture',must_change_password=false where id::text like '92000000-%';
insert into public.organizations(id,name,slug)values('93000000-0000-4000-8000-000000000001','Performance Overview Org','performance-overview-org');
insert into public.organization_memberships(organization_id,user_id,role)values('93000000-0000-4000-8000-000000000001','92000000-0000-4000-8000-000000000501','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone)
select ('94000000-0000-4000-8000-'||pg_catalog.lpad(value::text,12,'0'))::uuid,'93000000-0000-4000-8000-000000000001','Performance Branch '||pg_catalog.lpad(value::text,3,'0'),'P'||value,'UTC' from pg_catalog.generate_series(1,200)value;
insert into public.branch_memberships(branch_id,user_id,role)
select ('94000000-0000-4000-8000-'||pg_catalog.lpad((((value-1)%200)+1)::text,12,'0'))::uuid,('92000000-0000-4000-8000-'||pg_catalog.lpad(value::text,12,'0'))::uuid,'branch_manager' from pg_catalog.generate_series(1,500)value;
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
select ('95000000-0000-4000-8000-'||pg_catalog.lpad(value::text,12,'0'))::uuid,'93000000-0000-4000-8000-000000000001',('94000000-0000-4000-8000-'||pg_catalog.lpad((((value-1)%200)+1)::text,12,'0'))::uuid,('92000000-0000-4000-8000-'||pg_catalog.lpad(value::text,12,'0'))::uuid from pg_catalog.generate_series(1,500)value;
create temporary table manager_overview_performance(payload jsonb,elapsed_ms numeric) on commit drop;
do $$declare started timestamptz;overview jsonb;begin started:=pg_catalog.clock_timestamp();overview:=public.get_phase4a_management_overview('92000000-0000-4000-8000-000000000501','93000000-0000-4000-8000-000000000001');insert into manager_overview_performance values(overview,extract(epoch from pg_catalog.clock_timestamp()-started)*1000);end$$;
update manager_overview_result set payload=(select performance.payload from manager_overview_performance performance);
select diag('Manager Overview 200-branch/500-team RPC elapsed ms: '||(select pg_catalog.round(elapsed_ms,2) from manager_overview_performance));
select is(pg_catalog.jsonb_array_length(payload->'branches'),200,'maximum bounded result returns exactly 200 branches') from manager_overview_result;
select is((payload->'summary'->>'active_team_count')::int,500,'representative performance fixture includes 500 teams') from manager_overview_result;
select is((payload->'totals'->>'expected_checks')::int,500 * (37 + due.utc_count),'500 empty teams produce authoritative opening, Oil, due Cold, and Sales Tracking expectations') from manager_overview_result, overview_due_counts due;
select lives_ok($$explain (analyze,buffers,format json) select public.get_phase4a_management_overview('92000000-0000-4000-8000-000000000501','93000000-0000-4000-8000-000000000001')$$,'representative 200-branch/500-team query plan executes successfully');

select * from finish();
rollback;
