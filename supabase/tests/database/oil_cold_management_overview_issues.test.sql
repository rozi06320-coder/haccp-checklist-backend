begin;
select plan(29);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1d000000-0000-4000-8000-000000000001'::uuid,
  '1d000000-0000-4000-8000-000000000002',
  '1d000000-0000-4000-8000-000000000003',
  '1d000000-0000-4000-8000-000000000004'
]) id;
update public.profiles set full_name = case id
  when '1d000000-0000-4000-8000-000000000001' then 'Overview Issue Supervisor'
  when '1d000000-0000-4000-8000-000000000002' then 'Overview Issue Manager'
  when '1d000000-0000-4000-8000-000000000003' then 'Other Overview Issue Manager'
  else 'Overview Issue Staff'
end, must_change_password = false
where id::text like '1d000000-%';

insert into public.organizations(id,name,slug) values
 ('2d000000-0000-4000-8000-000000000001','Managed Overview Issue Org','managed-overview-issue-org'),
 ('2d000000-0000-4000-8000-000000000002','Other Overview Issue Org','other-overview-issue-org');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','organization_manager'),
 ('2d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000003','organization_manager');
create temp table oil_cold_issue_tz as
select (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) >= 3 order by name limit 1) closed_tz;
insert into public.branches(id,organization_id,name,code,timezone)
values('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Overview Issue Branch','OIB',(select closed_tz from oil_cold_issue_tz));
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager'),
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000004','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values('4d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001');

select lives_ok($$
  select public.submit_oil_tracking_opening(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5d000000-0000-4000-8000-000000000001',
    repeat('a',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"fail","opening_note":"Failed opening"}]'::jsonb
  )
$$, 'oil opening fail submitted');
select lives_ok($$
  select public.submit_oil_tracking_closing(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5d000000-0000-4000-8000-000000000002',
    repeat('b',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"fail","opening_note":"Failed opening","closing_tpm_percent":22,"closing_note":"Filter oil"}]'::jsonb
  )
$$, 'oil closing TPM submitted');
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    slot_value,
    idempotency_key,
    request_hash,
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true},{"equipment_id":"inactive","equipment_name":"Inactive Freezer","equipment_type":"freezer","active":false}]'::jsonb,
    format('[{"equipment_id":"ref-1","slot":"%s","temperature_c":5,"status":"fail","corrective_action":"Adjusted thermostat"},{"equipment_id":"inactive","slot":"%s","temperature_c":12,"status":"fail","corrective_action":"Ignored inactive"}]', slot_value, slot_value)::jsonb
  )
  from (values
    ('12:00','5d000000-0000-4000-8000-000000000003'::uuid,repeat('c',64)),
    ('20:00','5d000000-0000-4000-8000-000000000004'::uuid,repeat('d',64)),
    ('02:00','5d000000-0000-4000-8000-000000000005'::uuid,repeat('e',64))
  ) slots(slot_value,idempotency_key,request_hash)
$$, 'all cold slots submitted so current active slot is covered');

insert into public.cold_storage_submissions(
  id,
  organization_id,
  branch_id,
  supervisor_user_id,
  supervisor_team_id,
  business_date,
  branch_name_snapshot,
  supervisor_name_snapshot,
  team_name_snapshot
) values (
  '6d000000-0000-4000-8000-000000000001',
  '2d000000-0000-4000-8000-000000000001',
  '3d000000-0000-4000-8000-000000000001',
  '1d000000-0000-4000-8000-000000000001',
  '4d000000-0000-4000-8000-000000000001',
  private.phase4a_business_date((select closed_tz from oil_cold_issue_tz)) - 1,
  'Overview Issue Branch',
  'Overview Issue Supervisor',
  'Overview Issue Team'
);
insert into public.cold_storage_equipment(submission_id,equipment_id,equipment_name,equipment_type,active)
values('6d000000-0000-4000-8000-000000000001','missed-ref','Missed Refrigerator','refrigerator',true);

create temporary table managed_overview(payload jsonb) on commit drop;
insert into managed_overview
select public.get_phase4a_management_overview('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001');
create temporary table cold_due_context(due_count int) on commit drop;
insert into cold_due_context
select cardinality(private.cold_storage_due_slots_for(
  '3d000000-0000-4000-8000-000000000001',
  private.phase4a_business_date((select closed_tz from oil_cold_issue_tz))
));
create temporary table cold_missed_context(missed_count int) on commit drop;
insert into cold_missed_context
select cardinality(private.cold_storage_missed_slots_for(
  '3d000000-0000-4000-8000-000000000001',
  private.phase4a_business_date((select closed_tz from oil_cold_issue_tz)) - 1,
  array[]::text[]
));

select is(pg_catalog.jsonb_array_length(payload->'branches'->0->'checklists'),6,'management overview includes six checklist rows') from managed_overview;
select is((select checklist->>'checklist_type' from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='oil_tracking'),'oil_tracking','overview includes oil tracking row') from managed_overview;
select is((select checklist->>'checklist_type' from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='cold_storage'),'cold_storage','overview includes cold storage row') from managed_overview;
select is((select (checklist->>'expected_checks')::int from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='oil_tracking'),2,'oil expected counts two submitted sections') from managed_overview;
select is((select (checklist->>'answered_checks')::int from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='oil_tracking'),2,'oil opening and closing answer overview') from managed_overview;
select is((select (checklist->>'issue_checks')::int from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='oil_tracking'),2,'oil opening fail and TPM issue count') from managed_overview;
select is((select (checklist->>'expected_checks')::int from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='cold_storage'),(select due_count from cold_due_context),'cold storage expected counts due scheduled slots') from managed_overview;
select is((select (checklist->>'answered_checks')::int from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='cold_storage'),(select due_count from cold_due_context),'cold storage answered due submitted slots') from managed_overview;
select is((select (checklist->>'issue_checks')::int from managed_overview cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist where checklist->>'checklist_type'='cold_storage'),(select due_count from cold_due_context),'cold storage issue count ignores inactive equipment') from managed_overview;
select is((payload->'totals'->>'expected_checks')::int,38 + (select due_count from cold_due_context),'organization expected total includes phase4a, Sales Tracking, oil, and due cold slots') from managed_overview;
select is((payload->'totals'->>'answered_checks')::int,2 + (select due_count from cold_due_context),'organization answered total includes oil and due cold slots') from managed_overview;
select is((payload->'totals'->>'issue_checks')::int,2 + (select due_count from cold_due_context),'organization issue total includes oil and due cold slots') from managed_overview;

select is(public.list_oil_tracking_managed_issues('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,'oil_tracking',null,null)->>'total','2','manager can list oil issues');
select ok(public.list_oil_tracking_managed_issues('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,'oil_tracking',null,null)->'issues'->0->>'title' like '%Fryer 1%','oil issue list includes fryer label');
select is(public.list_cold_storage_managed_issues('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,'cold_storage',null,null)->>'total',(3 + (select missed_count from cold_missed_context))::text,'manager can list temperature and due missed cold storage issues');
select ok(public.list_cold_storage_managed_issues('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,'cold_storage',null,'Adjusted thermostat')->'issues'->0->>'description' like '%5C%','cold issue list includes temperature');
select is(public.list_cold_storage_managed_issues('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,'cold_storage',null,'missed')->>'total',(select missed_count from cold_missed_context)::text,'manager can list derived missed cold storage issues after cutoff');
select ok(case when (select missed_count from cold_missed_context) = 0 then true else public.list_cold_storage_managed_issues('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,'cold_storage',null,'missed')->'issues'->0->>'title' like '%missed scheduled check%' end,'missed issue list names scheduled check after cutoff');
select is(public.get_oil_tracking_managed_issue('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',(select id from public.oil_tracking_issues where section='closing' limit 1))->>'checklist_type','oil_tracking','manager can open oil issue detail');
select ok(public.get_cold_storage_managed_issue('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',(select id from public.cold_storage_issues limit 1))->>'remark' like '%Temperature: 5C%','manager can open cold issue detail');
select ok(case when (select missed_count from cold_missed_context) = 0 then true else public.get_cold_storage_managed_issue('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',private.cold_storage_missed_issue_id('6d000000-0000-4000-8000-000000000001','12:00'))->>'remark' like '%Missed scheduled check%' end,'manager can open derived missed cold issue detail after cutoff');

select throws_ok($$select public.get_phase4a_management_overview('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')$$,'42501','management overview access denied','unrelated manager cannot read overview');
select throws_ok($$select public.list_oil_tracking_managed_issues('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,'oil_tracking',null,null)$$,'42501','oil tracking issue access denied','unrelated manager cannot list oil issues');
select throws_ok($$select public.get_cold_storage_managed_issue('1d000000-0000-4000-8000-000000000004','2d000000-0000-4000-8000-000000000001',(select id from public.cold_storage_issues limit 1))$$,'42501','cold storage issue access denied','staff cannot open cold issue');

select is(has_function_privilege('authenticated','public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot execute managed oil issues RPC');
select is(has_function_privilege('service_role','public.get_cold_storage_managed_issue(uuid,uuid,uuid)','execute'),true,'service role can execute managed cold issue detail RPC');

select * from finish();
rollback;
