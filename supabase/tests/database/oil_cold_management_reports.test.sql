begin;
select plan(44);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1b000000-0000-4000-8000-000000000001'::uuid,
  '1b000000-0000-4000-8000-000000000002',
  '1b000000-0000-4000-8000-000000000003',
  '1b000000-0000-4000-8000-000000000004',
  '1b000000-0000-4000-8000-000000000005'
]) id;
update public.profiles set full_name = case id
  when '1b000000-0000-4000-8000-000000000001' then 'Managed Report Supervisor'
  when '1b000000-0000-4000-8000-000000000002' then 'Managed Report Manager'
  when '1b000000-0000-4000-8000-000000000003' then 'Unrelated Manager'
  when '1b000000-0000-4000-8000-000000000005' then 'Three Slot Supervisor'
  else 'Managed Report Staff'
end, must_change_password = false
where id::text like '1b000000-%';
insert into public.organizations(id,name,slug) values
 ('2b000000-0000-4000-8000-000000000001','Managed Report Org','managed-report-org'),
 ('2b000000-0000-4000-8000-000000000002','Unrelated Report Org','unrelated-report-org');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','Managed Report Branch','MRB','Asia/Riyadh'),
 ('3b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001','Three Slot Branch','TSB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('2b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000002','organization_manager'),
 ('2b000000-0000-4000-8000-000000000002','1b000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001','branch_manager'),
 ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000004','staff'),
 ('3b000000-0000-4000-8000-000000000002','1b000000-0000-4000-8000-000000000005','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values
 ('4b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001'),
 ('4b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000002','1b000000-0000-4000-8000-000000000005');

select is(has_function_privilege('authenticated','public.list_oil_tracking_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text)','execute'),false,'authenticated cannot execute managed oil reports RPC');
select is(has_function_privilege('service_role','public.list_oil_tracking_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text)','execute'),true,'service role can execute managed oil reports RPC');
select is(has_function_privilege('authenticated','public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)','execute'),false,'authenticated cannot execute managed cold detail RPC');
select is(has_function_privilege('service_role','public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)','execute'),true,'service role can execute managed cold detail RPC');
select is(to_jsonb(private.cold_storage_missed_slots_for('3b000000-0000-4000-8000-000000000001','2026-08-01',array[]::text[],'2026-08-01 15:00:00+03'::timestamptz))::text,'[]','15:00 keeps missing 12:00 pending, not not checked');
select is(to_jsonb(private.cold_storage_missed_slots_for('3b000000-0000-4000-8000-000000000001','2026-08-01',array[]::text[],'2026-08-01 20:00:00+03'::timestamptz))::text,'["12:00"]','20:00 closes the missing 12:00 check');
select is(to_jsonb(private.cold_storage_missed_slots_for('3b000000-0000-4000-8000-000000000001','2026-08-01',array[]::text[],'2026-08-02 02:59:00+03'::timestamptz))::text,'["12:00", "20:00"]','02:59 next day keeps only the 02:00 slot open');
select is(to_jsonb(private.cold_storage_missed_slots_for('3b000000-0000-4000-8000-000000000001','2026-08-01',array[]::text[],'2026-08-02 03:00:00+03'::timestamptz))::text,'["12:00", "20:00", "02:00"]','03:00 next day marks missing operational day slots not checked');
select is(to_jsonb(private.cold_storage_missed_slots_for('3b000000-0000-4000-8000-000000000001','2026-08-01',array[]::text[],'2026-08-03 12:00:00+03'::timestamptz))::text,'["12:00", "20:00", "02:00"]','past business dates produce not checked missed slots');
select is(to_jsonb(private.cold_storage_missed_slots_for('3b000000-0000-4000-8000-000000000001','2026-08-01',array['12:00','3:00','8:00']::text[],'2026-08-03 12:00:00+03'::timestamptz))::text,'[]','legacy submitted slots satisfy their canonical report equivalents');

select lives_ok($$
  select public.submit_oil_tracking_opening(
    '1b000000-0000-4000-8000-000000000001',
    '3b000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5b000000-0000-4000-8000-000000000001',
    repeat('a',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass"}]'::jsonb
  )
$$, 'managed oil opening is submitted');
select lives_ok($$
  select public.submit_oil_tracking_closing(
    '1b000000-0000-4000-8000-000000000001',
    '3b000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5b000000-0000-4000-8000-000000000002',
    repeat('b',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass","closing_tpm_percent":22,"closing_note":"Filter oil"}]'::jsonb
  )
$$, 'managed oil closing is submitted');
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1b000000-0000-4000-8000-000000000001',
    '3b000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5b000000-0000-4000-8000-000000000003',
    repeat('c',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"12:00","temperature_c":5,"status":"fail","corrective_action":"Adjusted thermostat"}]'::jsonb
  )
$$, 'managed cold slot is submitted');

update public.cold_storage_submissions
set business_date = (pg_catalog.statement_timestamp() at time zone 'Asia/Riyadh')::date - 1
where branch_id = '3b000000-0000-4000-8000-000000000001';

select is(
  public.list_oil_tracking_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,null)->>'total',
  '1',
  'manager can list managed oil reports'
);
select is(
  public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,null)->>'total',
  '2',
  'manager can list managed cold submission and derived not checked reports'
);
select is(
  public.list_oil_tracking_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'issues_found',null)->'reports'->0->>'issue_count',
  '1',
  'managed oil issue filter returns TPM issue report'
);
select is(
  public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'issues_found',null)->'reports'->0->>'checklist_type',
  'cold_storage',
  'managed cold issue filter returns cold report'
);
select is(
  public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'not_checked',null)->>'total',
  '1',
  'managed cold not checked filter returns derived missed report'
);
select is(
  public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'not_checked',null)->'reports'->0->>'record_kind',
  'derived_missing',
  'managed cold not checked report is derived'
);
select is(
  public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'not_checked',null)->'reports'->0->>'submitted_at',
  null,
  'managed cold not checked report has no submitted timestamp'
);
select is(
  public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'not_checked',null)->'reports'->0->>'submitted_by',
  null,
  'managed cold not checked report has no submitted by'
);
select is(
  public.get_oil_tracking_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.oil_tracking_submissions where organization_id = '2b000000-0000-4000-8000-000000000001')
  )->'rows'->0->>'tpm_classification',
  'filtering_required',
  'manager can open oil detail with TPM classification'
);
select is(
  public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where organization_id = '2b000000-0000-4000-8000-000000000001')
  )->'rows'->0->>'corrective_action',
  'Adjusted thermostat',
  'manager can open cold detail with corrective action'
);
select is(
  public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where organization_id = '2b000000-0000-4000-8000-000000000001')
  )->>'issue_count',
  '3',
  'manager cold detail includes temperature and missed issue count'
);
select is(
  public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'issues_found',null)->'reports'->0->>'missed_check_count',
  '2',
  'managed cold list exposes missed check count'
);
select is(
  public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    private.cold_storage_missed_report_id((select id from public.cold_storage_submissions where organization_id = '2b000000-0000-4000-8000-000000000001'))
  )->>'status',
  'not_checked',
  'manager can open derived cold not checked detail'
);
select is(
  public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    private.cold_storage_missed_report_id((select id from public.cold_storage_submissions where organization_id = '2b000000-0000-4000-8000-000000000001'))
  )->'items'->0->>'answer',
  'not_checked',
  'derived cold detail explains missed scheduled check'
);
select is(
  public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where organization_id = '2b000000-0000-4000-8000-000000000001')
  )->>'missed_slots',
  '["20:00", "02:00"]',
  'managed cold detail exposes missed slots'
);

select throws_ok($$
  select public.list_oil_tracking_managed_reports('1b000000-0000-4000-8000-000000000003','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,null)
$$, '42501', 'oil managed report access denied', 'unrelated manager cannot list oil reports');
select throws_ok($$
  select public.get_oil_tracking_managed_report_detail(
    '1b000000-0000-4000-8000-000000000003',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.oil_tracking_submissions where organization_id = '2b000000-0000-4000-8000-000000000001')
  )
$$, '42501', 'oil managed report access denied', 'unrelated manager cannot open oil detail');
select throws_ok($$
  select public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001',1,20,null,null,null,null,null,null)
$$, '42501', 'cold storage managed report access denied', 'supervisor cannot use managed cold report list');
select throws_ok($$
  select public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000004',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where organization_id = '2b000000-0000-4000-8000-000000000001')
  )
$$, '42501', 'cold storage managed report access denied', 'staff cannot use managed cold detail');
select throws_ok($$
  select public.list_oil_tracking_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',0,20,null,null,null,null,null,null)
$$, '42501', 'oil managed report access denied', 'invalid managed oil paging is rejected');
select throws_ok($$
  select public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001',1,20,'2026-08-02','2026-08-01',null,null,null,null)
$$, '42501', 'cold storage managed report access denied', 'invalid managed cold date range is rejected');
select throws_ok($$
  select public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000002',
    (select id from public.cold_storage_submissions where organization_id = '2b000000-0000-4000-8000-000000000001')
  )
$$, '42501', 'cold storage managed report access denied', 'manager cannot cross organization in detail');

select lives_ok($$
  select public.submit_cold_storage_slot(
    '1b000000-0000-4000-8000-000000000005',
    '3b000000-0000-4000-8000-000000000002',
    (public.get_cold_storage_current_state('1b000000-0000-4000-8000-000000000005','3b000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '12:00',
    '5b000000-0000-4000-8000-000000000004',
    repeat('d',64),
    '[{"equipment_id":"ref-all","equipment_name":"All Slot Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-all","slot":"12:00","temperature_c":3,"status":"pass","corrective_action":""}]'::jsonb
  )
$$, 'Supervisor submits the canonical 12:00 slot');
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1b000000-0000-4000-8000-000000000005',
    '3b000000-0000-4000-8000-000000000002',
    (public.get_cold_storage_current_state('1b000000-0000-4000-8000-000000000005','3b000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '20:00',
    '5b000000-0000-4000-8000-000000000005',
    repeat('e',64),
    '[{"equipment_id":"ref-all","equipment_name":"All Slot Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-all","slot":"20:00","temperature_c":3,"status":"pass","corrective_action":""}]'::jsonb
  )
$$, 'Supervisor submits the canonical 20:00 slot');
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1b000000-0000-4000-8000-000000000005',
    '3b000000-0000-4000-8000-000000000002',
    (public.get_cold_storage_current_state('1b000000-0000-4000-8000-000000000005','3b000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '02:00',
    '5b000000-0000-4000-8000-000000000006',
    repeat('f',64),
    '[{"equipment_id":"ref-all","equipment_name":"All Slot Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-all","slot":"02:00","temperature_c":3,"status":"pass","corrective_action":""}]'::jsonb
  )
$$, 'Supervisor submits the canonical 02:00 slot');
select is(
  (select state from public.cold_storage_submissions where branch_id = '3b000000-0000-4000-8000-000000000002'),
  'submitted',
  'all three canonical slots lock the Cold Storage parent as submitted'
);
select is(
  (select count(*)::int from public.cold_storage_readings where submission_id = (select id from public.cold_storage_submissions where branch_id = '3b000000-0000-4000-8000-000000000002') and submitted_at is not null),
  3,
  'all three canonical child readings are persisted as submitted'
);
select is(
  public.list_cold_storage_managed_reports(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    1,20,
    (pg_catalog.statement_timestamp() at time zone 'Asia/Riyadh')::date,
    (pg_catalog.statement_timestamp() at time zone 'Asia/Riyadh')::date,
    '3b000000-0000-4000-8000-000000000002',null,null,null
  )->>'total',
  '1',
  'Manager date and branch filters return the submitted Refrigerator and Freezer report'
);
select ok(
  public.list_cold_storage_managed_reports(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    1,20,null,null,'3b000000-0000-4000-8000-000000000002',null,null,null
  )->'reports'->0->'submitted_slots' @> '["12:00","20:00","02:00"]'::jsonb,
  'Manager list returns the three canonical slot IDs'
);
select is(
  jsonb_array_length(public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where branch_id = '3b000000-0000-4000-8000-000000000002')
  )->'rows'),
  3,
  'Manager detail returns all three submitted slot rows'
);
select ok(
  public.get_cold_storage_managed_report_detail(
    '1b000000-0000-4000-8000-000000000002',
    '2b000000-0000-4000-8000-000000000001',
    (select id from public.cold_storage_submissions where branch_id = '3b000000-0000-4000-8000-000000000002')
  )->'submitted_slots' @> '["12:00","20:00","02:00"]'::jsonb,
  'Manager detail returns the three canonical slot IDs'
);

select * from finish();
rollback;
