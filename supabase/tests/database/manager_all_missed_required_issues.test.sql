begin;
select plan(18);

create temp table missed_issue_tz as
select
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 3 and 23 order by name limit 1) closed_tz,
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 0 and 2 order by name limit 1) open_tz,
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 15 and 23 order by name limit 1) oil_tz,
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 15 and 19 order by name limit 1) cold_12_tz,
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 20 and 23 order by name limit 1) cold_3_tz;

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1f000000-0000-4000-8000-000000000001'::uuid,
  '1f000000-0000-4000-8000-000000000002',
  '1f000000-0000-4000-8000-000000000003',
  '1f000000-0000-4000-8000-000000000004',
  '1f000000-0000-4000-8000-000000000005',
  '1f000000-0000-4000-8000-000000000006',
  '1f000000-0000-4000-8000-000000000007',
  '1f000000-0000-4000-8000-000000000008',
  '1f000000-0000-4000-8000-000000000009'
]) id;
update public.profiles set full_name = 'Missed Issue User ' || right(id::text, 1), must_change_password = false
where id::text like '1f000000-%';

insert into public.organizations(id,name,slug) values
  ('2f000000-0000-4000-8000-000000000001','All Missed Issues Org','all-missed-issues-org'),
  ('2f000000-0000-4000-8000-000000000002','Other All Missed Issues Org','other-all-missed-issues-org');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','organization_manager'),
  ('2f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000009','organization_manager');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Closed Daily Branch','CDB',(select closed_tz from missed_issue_tz)),
  ('3f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','Open Daily Branch','ODB',(select open_tz from missed_issue_tz)),
  ('3f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001','No Staff Branch','NSB',(select closed_tz from missed_issue_tz)),
  ('3f000000-0000-4000-8000-000000000004','2f000000-0000-4000-8000-000000000001','Oil Missed Branch','OMB',(select oil_tz from missed_issue_tz)),
  ('3f000000-0000-4000-8000-000000000005','2f000000-0000-4000-8000-000000000001','Cold Noon Branch','CNB',(select cold_12_tz from missed_issue_tz)),
  ('3f000000-0000-4000-8000-000000000006','2f000000-0000-4000-8000-000000000001','Cold Evening Branch','CEB',(select cold_3_tz from missed_issue_tz)),
  ('3f000000-0000-4000-8000-000000000007','2f000000-0000-4000-8000-000000000001','Cold Yesterday Branch','CYB',(select closed_tz from missed_issue_tz)),
  ('3f000000-0000-4000-8000-000000000008','2f000000-0000-4000-8000-000000000001','Sales Missed Branch','SMB',(select closed_tz from missed_issue_tz));

insert into public.branch_memberships(branch_id,user_id,role)
select ('3f000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid,
  ('1f000000-0000-4000-8000-' || lpad((value + 1)::text, 12, '0'))::uuid,
  'branch_manager'
from generate_series(1,8) value;

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
select ('4f000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid,
  '2f000000-0000-4000-8000-000000000001',
  ('3f000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid,
  ('1f000000-0000-4000-8000-' || lpad((value + 1)::text, 12, '0'))::uuid
from generate_series(1,8) value;

insert into public.operational_staff(id,organization_id,branch_id,display_name,created_by)
values('5f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','On Duty Staff','1f000000-0000-4000-8000-000000000002');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_roles)
values('6f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','5f000000-0000-4000-8000-000000000001','4f000000-0000-4000-8000-000000000001',array['kitchen']);

insert into public.cold_storage_submissions(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot)
values(
  '7f000000-0000-4000-8000-000000000001',
  '2f000000-0000-4000-8000-000000000001',
  '3f000000-0000-4000-8000-000000000007',
  '1f000000-0000-4000-8000-000000000008',
  '4f000000-0000-4000-8000-000000000007',
  private.phase4a_business_date((select closed_tz from missed_issue_tz)) - 1,
  'Cold Yesterday Branch',
  'Missed Issue User 8',
  'Missed Issue User 8 Team'
);
insert into public.cold_storage_equipment(submission_id,equipment_id,equipment_name,equipment_type,active)
values('7f000000-0000-4000-8000-000000000001','cold-yesterday','Cold Yesterday Unit','refrigerator',true);

select is(public.list_phase4a_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000001',null,null,'kitchen_opening',null,null)->>'total','1','Kitchen Opening not submitted after 03:00 becomes not checked');
select is(public.list_phase4a_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000001',null,null,'foh_opening',null,null)->>'total','1','FOH Opening not submitted after 03:00 becomes not checked');
select is(public.list_phase4a_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000001',null,null,'staff_hygiene',null,null)->>'total','1','Staff Hygiene not submitted with on-duty staff becomes not checked');
select is(public.list_phase4a_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000003',null,null,'staff_hygiene',null,null)->>'total','0','Staff Hygiene has no false missed issue when no on-duty staff exists');
select is(public.list_phase4a_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000002',null,null,'kitchen_opening',null,null)->>'total','0','Daily missing before 03:00 remains pending, not an issue');

select is(public.list_oil_tracking_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000004',null,null,'oil_tracking',null,'opening')->>'total','1','Oil opening missing after due window becomes not checked');
select is(public.list_oil_tracking_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000004',null,null,'oil_tracking',null,'closing')->>'total','1','Oil closing missing after 03:00 becomes not checked');

select is(public.list_cold_storage_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000005',null,null,'cold_storage',null,'12:00')->>'total','0','Cold 12:00 remains pending before 20:00');
select is(public.list_cold_storage_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000006',null,null,'cold_storage',null,'12:00')->>'total','1','Cold 12:00 missing after 20:00 becomes not checked');
select is(public.list_cold_storage_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000007',null,null,'cold_storage',null,'02:00')->>'total','1','Cold 02:00 missing after operational close becomes not checked');

select is(public.list_sales_tracking_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000008',null,null,'sales_tracking',null,null)->>'total','1','Sales Tracking missing after 03:00 becomes not checked');

create temp table missed_phase4a_detail as
select (issue->>'id')::uuid id
from jsonb_array_elements(public.list_phase4a_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000001',null,null,'kitchen_opening',null,null)->'issues') issue
limit 1;
select ok(public.get_phase4a_managed_issue('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',(select id from missed_phase4a_detail))->>'remark' like '%No fake submission was created%','derived Phase4A issue detail opens safely');

create temp table missed_oil_detail as
select (issue->>'id')::uuid id
from jsonb_array_elements(public.list_oil_tracking_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000004',null,null,'oil_tracking',null,'opening')->'issues') issue
limit 1;
select ok(public.get_oil_tracking_managed_issue('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',(select id from missed_oil_detail))->>'remark' like '%No fake submission was created%','derived Oil issue detail opens safely');

create temp table missed_cold_detail as
select (issue->>'id')::uuid id
from jsonb_array_elements(public.list_cold_storage_managed_issues('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',1,20,null,null,'3f000000-0000-4000-8000-000000000006',null,null,'cold_storage',null,'12:00')->'issues') issue
limit 1;
select ok(public.get_cold_storage_managed_issue('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001',(select id from missed_cold_detail))->>'remark' like '%No fake submission was created%','derived Cold issue detail opens safely');

select throws_ok($$select public.list_phase4a_managed_issues('1f000000-0000-4000-8000-000000000009','2f000000-0000-4000-8000-000000000001')$$,'42501','issue access denied','other manager cannot list Phase4A missed issues');
select throws_ok($$select public.list_oil_tracking_managed_issues('1f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001')$$,'42501','oil tracking issue access denied','supervisor cannot list Oil missed issues');
select is(has_function_privilege('authenticated','public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot execute managed Phase4A issues RPC');
select is(has_function_privilege('service_role','public.get_oil_tracking_managed_issue(uuid,uuid,uuid)','execute'),true,'service role can execute managed Oil issue detail RPC');

select * from finish();
rollback;
