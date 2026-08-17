begin;
select plan(24);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  'a1000000-0000-4000-8000-000000000001'::uuid,
  'a1000000-0000-4000-8000-000000000002',
  'a2000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000002'
]) id;
update public.profiles set full_name='Daily Audit Fixture',must_change_password=false where id::text like 'a1%' or id::text like 'a2%';

insert into public.organizations(id,name,slug) values
 ('a3000000-0000-4000-8000-000000000001','Daily Audit Manager Org','daily-audit-manager-org'),
 ('a3000000-0000-4000-8000-000000000002','Other Daily Audit Org','other-daily-audit-org');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','organization_manager'),
 ('a3000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000002','organization_manager');
insert into public.branches(id,organization_id,name,code,timezone,active) values
 ('a4000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','Submitted Branch','SUB','UTC',true),
 ('a4000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001','Draft Branch','DRF','UTC',true),
 ('a4000000-0000-4000-8000-000000000003','a3000000-0000-4000-8000-000000000001','Missing Branch','MIS','UTC',true),
 ('a4000000-0000-4000-8000-000000000004','a3000000-0000-4000-8000-000000000002','Other Branch','OTH','UTC',true);
insert into public.branch_memberships(branch_id,user_id,role) values
 ('a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','branch_manager'),
 ('a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('a5000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001'),
 ('a5000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000002');

insert into public.checklist_submissions(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at,daily_audit_auditor_kind,daily_audit_auditor_id,daily_audit_auditor_name_snapshot,daily_audit_access_credential_version)
values
 ('a6000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a5000000-0000-4000-8000-000000000001',private.phase4a_business_date('UTC'),'daily_audit','daily_audit_v1','submitted','Submitted Branch','SUB','Supervisor One',now(),'manual_access_user','a7000000-0000-4000-8000-000000000001','Safe Auditor','a8000000-0000-4000-8000-000000000001'),
 ('a6000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000002',private.phase4a_business_date('UTC'),'daily_audit','daily_audit_v1','draft','Draft Branch','DRF','Supervisor Two',null,'manual_access_user','a7000000-0000-4000-8000-000000000002','Draft Auditor','a8000000-0000-4000-8000-000000000002');
insert into public.daily_audit_item_results(submission_id,organization_id,branch_id,item_id,item_number,answer,remark)
select 'a6000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000001',d.item_id,d.item_number,
  case when d.item_number=4 then 'non_compliant' else 'compliant' end,
  case when d.item_number=4 then 'Receiving record mismatch' else '' end
from public.daily_audit_item_definitions d where d.active;
insert into public.daily_audit_item_results(submission_id,organization_id,branch_id,item_id,item_number,answer,remark)
select 'a6000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000002',d.item_id,d.item_number,
  case when d.item_number=1 then 'compliant' else 'not_checked' end,''
from public.daily_audit_item_definitions d where d.active;

select has_function('public','list_managed_daily_audit_reports',array['uuid','uuid','integer','integer','date','date','uuid','uuid','text','text'],'manager list RPC exists');
select has_function('public','get_managed_daily_audit_report_detail',array['uuid','uuid','uuid'],'manager detail RPC exists');
select has_function('public','get_management_overview_with_daily_audit',array['uuid','uuid'],'Daily Audit overview RPC exists');

create temporary table daily_list(payload jsonb) on commit drop;
insert into daily_list select public.list_managed_daily_audit_reports('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001');
select is((payload->>'total')::int,1,'Manager list includes submitted Daily Audits and excludes drafts') from daily_list;
select is(payload->'reports'->0->>'submitted_by','Safe Auditor','list returns safe auditor display snapshot') from daily_list;
select is(payload->'reports'->0->>'auditor_kind','manual_access_user','list returns safe auditor kind') from daily_list;
select is((payload->'reports'->0->>'issue_count')::int,1,'non-compliant answers count as issues') from daily_list;
select ok(payload::text !~ '(credential_version|auditor_id|pin|hash|salt|cookie|grant|token)','list exposes no credential or grant material') from daily_list;

create temporary table daily_detail(payload jsonb) on commit drop;
insert into daily_detail select public.get_managed_daily_audit_report_detail('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a6000000-0000-4000-8000-000000000001');
select is(pg_catalog.jsonb_array_length(payload->'items'),13,'detail returns exactly 13 canonical items') from daily_detail;
select is((payload->>'issue_count')::int,1,'detail issue count is correct') from daily_detail;
select is(payload->'items'->3->>'remark','Receiving record mismatch','detail returns the persisted non-compliant remark') from daily_detail;
select ok(payload::text !~ '(credential_version|auditor_id|pin|hash|salt|cookie|grant|token)','detail exposes no credential or grant material') from daily_detail;

select is((public.list_managed_daily_audit_reports('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001',1,20,null,null,'a4000000-0000-4000-8000-000000000001')->>'total')::int,1,'own-organization branch filter is scoped');
select throws_ok($$select public.list_managed_daily_audit_reports('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001',1,20,null,null,'a4000000-0000-4000-8000-000000000004')$$,'42501','daily audit report access denied','cross-organization branch filter is denied');
select throws_ok($$select public.list_managed_daily_audit_reports('a1000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000001')$$,'42501','daily audit report access denied','cross-organization Manager is denied');

create temporary table daily_overview(payload jsonb) on commit drop;
insert into daily_overview select public.get_management_overview_with_daily_audit('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001');
select is((select pg_catalog.min(pg_catalog.jsonb_array_length(branch->'checklists')) from daily_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch),7,'every active branch has seven checklist categories') from daily_overview;
select is((select checklist->>'answered_checks' from daily_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist where branch->>'branch_id'='a4000000-0000-4000-8000-000000000001' and checklist->>'checklist_type'='daily_audit'),'13','submitted Daily Audit contributes all 13 answers') from daily_overview;
select is((select checklist->>'issue_checks' from daily_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist where branch->>'branch_id'='a4000000-0000-4000-8000-000000000001' and checklist->>'checklist_type'='daily_audit'),'1','submitted Daily Audit contributes non-compliant issues') from daily_overview;
select is((select checklist->>'pending_checks' from daily_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist where branch->>'branch_id'='a4000000-0000-4000-8000-000000000002' and checklist->>'checklist_type'='daily_audit'),'13','draft Daily Audit remains fully pending') from daily_overview;
select is((select checklist->'team_states'->>'draft' from daily_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist where branch->>'branch_id'='a4000000-0000-4000-8000-000000000002' and checklist->>'checklist_type'='daily_audit'),'1','draft state is represented honestly') from daily_overview;
select is((select checklist->>'pending_checks' from daily_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist where branch->>'branch_id'='a4000000-0000-4000-8000-000000000003' and checklist->>'checklist_type'='daily_audit'),'13','missing Daily Audit is pending, not completed') from daily_overview;
select is((select checklist->'team_states'->>'not_started' from daily_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches') branch cross join lateral pg_catalog.jsonb_array_elements(branch->'checklists') checklist where branch->>'branch_id'='a4000000-0000-4000-8000-000000000003' and checklist->>'checklist_type'='daily_audit'),'1','missing Daily Audit is not started') from daily_overview;

select is(has_function_privilege('authenticated','public.list_managed_daily_audit_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'authenticated cannot execute manager Daily Audit list RPC');
select is(has_function_privilege('service_role','public.get_managed_daily_audit_report_detail(uuid,uuid,uuid)','execute'),true,'service role can execute read-only detail RPC');

select * from finish();
rollback;
