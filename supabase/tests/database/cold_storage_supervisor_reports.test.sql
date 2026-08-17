begin;
select plan(26);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1c000000-0000-4000-8000-000000000001'::uuid,
  '1c000000-0000-4000-8000-000000000002',
  '1c000000-0000-4000-8000-000000000003',
  '1c000000-0000-4000-8000-000000000004'
]) id;
update public.profiles set full_name = case id
  when '1c000000-0000-4000-8000-000000000001' then 'Cold Report One'
  when '1c000000-0000-4000-8000-000000000002' then 'Cold Report Two'
  when '1c000000-0000-4000-8000-000000000004' then 'Cold Report Manager'
  else 'Cold Report Staff'
end, must_change_password = false
where id::text like '1c000000-%';
insert into public.organizations(id,name,slug)
values('2c000000-0000-4000-8000-000000000001','Cold Report Org','cold-report-org');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','Cold Report Branch','CRP','Asia/Riyadh'),
 ('3c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000001','Cold Report Branch Two','CRP2','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3c000000-0000-4000-8000-000000000002','1c000000-0000-4000-8000-000000000001','branch_manager'),
 ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002','branch_manager'),
 ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002','1c000000-0000-4000-8000-000000000001'),
 ('4c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002');

select is(has_function_privilege('authenticated','public.list_cold_storage_supervisor_reports(uuid,uuid,int,int)','execute'),false,'authenticated cannot execute cold storage supervisor report list RPC');
select is(has_function_privilege('service_role','public.list_cold_storage_supervisor_reports(uuid,uuid,int,int)','execute'),true,'service role can execute cold storage supervisor report list RPC');
select is(has_function_privilege('authenticated','public.get_cold_storage_report_detail(uuid,uuid)','execute'),false,'authenticated cannot execute cold storage supervisor report detail RPC');
select is(has_function_privilege('service_role','public.get_cold_storage_report_detail(uuid,uuid)','execute'),true,'service role can execute cold storage supervisor report detail RPC');

select lives_ok($$
  select public.submit_cold_storage_slot(
    '1c000000-0000-4000-8000-000000000002',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5c000000-0000-4000-8000-000000000001',
    repeat('a',64),
    '[
      {"equipment_id":"partial-ref","equipment_name":"Partial Refrigerator","equipment_type":"refrigerator","active":true},
      {"equipment_id":"partial-inactive","equipment_name":"Partial Inactive","equipment_type":"freezer","active":false}
    ]'::jsonb,
    '[
      {"equipment_id":"partial-ref","slot":"12:00","temperature_c":4.9,"status":"pass"},
      {"equipment_id":"partial-inactive","slot":"12:00","temperature_c":9,"status":"fail","corrective_action":"ignored"}
    ]'::jsonb
  )
$$, 'opening slot cold storage report fixture is submitted');
update public.cold_storage_submissions
set business_date = (pg_catalog.statement_timestamp() at time zone 'Asia/Riyadh')::date - 1
where supervisor_team_id = '4c000000-0000-4000-8000-000000000002';
select is(
  public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,20)->>'total',
  '1',
  '12:00 list contains one own cold storage report'
);
select is(
  public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'status',
  'issues_found',
  'past day single submitted slot warns about missed scheduled checks'
);
select is(
  public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'issue_count',
  '2',
  'missed 20:00 and 02:00 count as report issues'
);
select is(
  public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'missed_check_count',
  '2',
  'list exposes missed check count'
);
select is(
  public.get_cold_storage_report_detail(
    '1c000000-0000-4000-8000-000000000002',
    (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000002')
  )->>'missed_slots',
  '["20:00", "02:00"]',
  'detail exposes missed slot metadata'
);

select lives_ok($$
  select public.submit_cold_storage_slot(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000002',
    (public.get_cold_storage_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '12:00',
    '5c000000-0000-4000-8000-000000000002',
    repeat('b',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"12:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"inactive","slot":"12:00","temperature_c":12,"status":"fail","corrective_action":"ignored"},
      {"equipment_id":"ref-1","slot":"12:00","temperature_c":5,"status":"fail","corrective_action":"Adjusted thermostat"}
    ]'::jsonb
  )
$$, '12:00 issue fixture is submitted');
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000002',
    (public.get_cold_storage_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '20:00',
    '5c000000-0000-4000-8000-000000000003',
    repeat('c',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"20:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"ref-1","slot":"20:00","temperature_c":4.9,"status":"pass"}
    ]'::jsonb
  )
$$, '20:00 safe fixture is submitted');
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000002',
    (public.get_cold_storage_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '02:00',
    '5c000000-0000-4000-8000-000000000004',
    repeat('d',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"02:00","temperature_c":-19,"status":"pass"},
      {"equipment_id":"ref-1","slot":"02:00","temperature_c":4.8,"status":"pass"}
    ]'::jsonb
  )
$$, '02:00 safe fixture is submitted');
update public.cold_storage_submissions
set business_date = (pg_catalog.statement_timestamp() at time zone 'Asia/Riyadh')::date - 1
where supervisor_team_id = '4c000000-0000-4000-8000-000000000001';
select is(
  public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002',1,20)->'reports'->0->>'completion',
  '100',
  '12:00 plus 20:00 plus 02:00 appears complete'
);
select is(
  public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002',1,20)->'reports'->0->>'issue_count',
  '1',
  '5C creates one list issue and inactive high temperature is ignored'
);
select is(
  jsonb_array_length(public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002',1,20)->'reports'->0->'submitted_slots'),
  3,
  'submitted 12:00, 20:00, and 02:00 slots appear in list metadata'
);
select is(
  jsonb_array_length(public.get_cold_storage_report_detail(
    '1c000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')
  )->'rows'),
  6,
  'report detail returns active equipment rows for submitted slots'
);
select is(
  (select string_agg(elem.value->>'slot', ',' order by elem.value->>'slot')
   from jsonb_array_elements(public.get_cold_storage_report_detail(
     '1c000000-0000-4000-8000-000000000001',
     (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')
   )->'rows') as elem(value)
   where elem.value->>'equipment_id' = 'ref-1'),
  '02:00,12:00,20:00',
  'report detail returns all submitted slots for an equipment row'
);
select is(
  public.get_cold_storage_report_detail(
    '1c000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')
  )->>'issue_count',
  '1',
  'detail issue count ignores inactive equipment'
);
select is(
  (select elem.value->>'equipment_id'
   from jsonb_array_elements(public.get_cold_storage_report_detail(
     '1c000000-0000-4000-8000-000000000001',
     (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')
   )->'issues') as elem(value)),
  'ref-1',
  'detail issue row names only the active 5C equipment'
);
select is(
  (select elem.value->>'corrective_action'
   from jsonb_array_elements(public.get_cold_storage_report_detail(
     '1c000000-0000-4000-8000-000000000001',
     (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')
   )->'rows') as elem(value)
   where elem.value->>'equipment_id' = 'ref-1' and elem.value->>'slot' = '12:00'),
  'Adjusted thermostat',
  'detail preserves corrective action'
);

select throws_ok($$
  select public.get_cold_storage_report_detail(
    '1c000000-0000-4000-8000-000000000002',
    (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')
  )
$$, '42501', 'cold storage report access denied', 'cross-branch supervisor cannot read detail');
select is(
  public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'id',
  (select id::text from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000002'),
  'other supervisor list is scoped to their own team report'
);
select throws_ok($$
  select public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000004','3c000000-0000-4000-8000-000000000001',1,20)
$$, '42501', 'cold storage report access denied', 'organization manager cannot use supervisor cold storage report list RPC');
select throws_ok($$
  select public.get_cold_storage_report_detail(
    '1c000000-0000-4000-8000-000000000004',
    (select id from public.cold_storage_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')
  )
$$, '42501', 'cold storage report access denied', 'organization manager cannot use supervisor cold storage report detail RPC');
select throws_ok($$
  select public.list_cold_storage_supervisor_reports('1c000000-0000-4000-8000-000000000003','3c000000-0000-4000-8000-000000000001',1,20)
$$, '42501', 'cold storage report access denied', 'staff cannot use supervisor cold storage report list RPC');

select * from finish();
rollback;
