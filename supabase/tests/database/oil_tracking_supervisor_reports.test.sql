begin;
select plan(29);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1d000000-0000-4000-8000-000000000001'::uuid,
  '1d000000-0000-4000-8000-000000000002',
  '1d000000-0000-4000-8000-000000000003',
  '1d000000-0000-4000-8000-000000000004'
]) id;
update public.profiles set full_name = case id
  when '1d000000-0000-4000-8000-000000000001' then 'Oil Report One'
  when '1d000000-0000-4000-8000-000000000002' then 'Oil Report Two'
  when '1d000000-0000-4000-8000-000000000004' then 'Oil Report Manager'
  else 'Oil Report Staff'
end, must_change_password = false
where id::text like '1d000000-%';
insert into public.organizations(id,name,slug)
values('2d000000-0000-4000-8000-000000000001','Oil Report Org','oil-report-org');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Oil Report Branch','ORP','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','Oil Report Branch Two','ORP2','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager'),
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','branch_manager'),
 ('3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000002','branch_manager'),
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001'),
 ('4d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000002');

select is(has_function_privilege('authenticated','public.list_oil_tracking_supervisor_reports(uuid,uuid,int,int)','execute'),false,'authenticated cannot execute oil supervisor report list RPC');
select is(has_function_privilege('service_role','public.list_oil_tracking_supervisor_reports(uuid,uuid,int,int)','execute'),true,'service role can execute oil supervisor report list RPC');
select is(has_function_privilege('authenticated','public.get_oil_tracking_report_detail(uuid,uuid)','execute'),false,'authenticated cannot execute oil supervisor report detail RPC');
select is(has_function_privilege('service_role','public.get_oil_tracking_report_detail(uuid,uuid)','execute'),true,'service role can execute oil supervisor report detail RPC');

select lives_ok($$
  select public.submit_oil_tracking_opening(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5d000000-0000-4000-8000-000000000001',
    repeat('a',64),
    '[
      {"fryer_id":"partial-active","fryer_label_snapshot":"Partial Active","fryer_short_label_snapshot":"PA","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass"},
      {"fryer_id":"partial-inactive","fryer_label_snapshot":"Partial Inactive","fryer_short_label_snapshot":"PI","in_use_today":false,"oil_status":"pending","opening_status":"fail","opening_note":"","closing_tpm_percent":25}
    ]'::jsonb
  )
$$, 'opening-only oil report fixture is submitted');
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',1,20)->>'total',
  '1',
  'opening-only list contains one own oil report'
);
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'status',
  'in_progress',
  'opening-only report appears as in progress'
);
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'completion',
  '50',
  'opening-only report appears as partial completion'
);
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'issue_count',
  '0',
  'inactive opening fail is ignored for issue count'
);
select is(
  public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000001',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000001')
  )->>'status',
  'in_progress',
  'opening-only detail is in progress'
);
select is(
  jsonb_array_length(public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000001',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000001')
  )->'rows'),
  2,
  'opening-only detail returns fryer rows including inactive fryer'
);
select is(
  jsonb_array_length(public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000001',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000001')
  )->'issues'),
  0,
  'opening-only inactive failure does not create report issues'
);

select lives_ok($$
  select public.submit_oil_tracking_opening(
    '1d000000-0000-4000-8000-000000000002',
    '3d000000-0000-4000-8000-000000000002',
    (public.get_oil_tracking_current_state('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '5d000000-0000-4000-8000-000000000002',
    repeat('b',64),
    '[
      {"fryer_id":"fryer-21","fryer_label_snapshot":"Fryer 21","fryer_short_label_snapshot":"F21","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass"},
      {"fryer_id":"fryer-22","fryer_label_snapshot":"Fryer 22","fryer_short_label_snapshot":"F22","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":176,"opening_status":"pass"},
      {"fryer_id":"fryer-25","fryer_label_snapshot":"Fryer 25","fryer_short_label_snapshot":"F25","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":177,"opening_status":"pass"},
      {"fryer_id":"inactive-25","fryer_label_snapshot":"Inactive 25","fryer_short_label_snapshot":"I25","in_use_today":false,"oil_status":"pending","opening_status":"pending","closing_tpm_percent":25}
    ]'::jsonb
  )
$$, 'complete oil report opening fixture is submitted');
select lives_ok($$
  select public.submit_oil_tracking_closing(
    '1d000000-0000-4000-8000-000000000002',
    '3d000000-0000-4000-8000-000000000002',
    (public.get_oil_tracking_current_state('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '5d000000-0000-4000-8000-000000000003',
    repeat('c',64),
    '[
      {"fryer_id":"fryer-21","fryer_label_snapshot":"Fryer 21","fryer_short_label_snapshot":"F21","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass","closing_tpm_percent":21,"closing_note":"nearing"},
      {"fryer_id":"fryer-22","fryer_label_snapshot":"Fryer 22","fryer_short_label_snapshot":"F22","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":176,"opening_status":"pass","closing_tpm_percent":22,"closing_note":"filter"},
      {"fryer_id":"fryer-25","fryer_label_snapshot":"Fryer 25","fryer_short_label_snapshot":"F25","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":177,"opening_status":"pass","closing_tpm_percent":25,"closing_note":"discard"},
      {"fryer_id":"inactive-25","fryer_label_snapshot":"Inactive 25","fryer_short_label_snapshot":"I25","in_use_today":false,"oil_status":"pending","opening_status":"pending","closing_tpm_percent":25,"closing_note":"ignored"}
    ]'::jsonb
  )
$$, 'complete oil report closing fixture is submitted');
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002',1,20)->>'total',
  '1',
  'complete list contains one own oil report'
);
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002',1,20)->'reports'->0->>'completion',
  '100',
  'opening plus closing appears complete'
);
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002',1,20)->'reports'->0->>'issue_count',
  '3',
  'inactive high TPM is ignored for list issue count'
);
select is(
  public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000002',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000002')
  )->>'completion',
  '100',
  'complete detail has full completion'
);
select is(
  jsonb_array_length(public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000002',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000002')
  )->'rows'),
  4,
  'complete detail returns all fryer rows'
);
select is(
  (select string_agg((elem.value->>'fryer_id') || ':' || (elem.value->>'tpm_classification'), ',' order by elem.value->>'fryer_id')
   from jsonb_array_elements(public.get_oil_tracking_report_detail(
     '1d000000-0000-4000-8000-000000000002',
     (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000002')
   )->'rows') as elem(value)
   where (elem.value->>'in_use_today')::boolean),
  'fryer-21:nearing_end,fryer-22:filtering_required,fryer-25:change_discard',
  'TPM 21, 22, and 25 classifications appear correctly'
);
select is(
  public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000002',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000002')
  )->>'issue_count',
  '3',
  'complete detail issue count ignores inactive fryer'
);
select is(
  (select string_agg(elem.value->>'fryer_id', ',' order by elem.value->>'fryer_id')
   from jsonb_array_elements(public.get_oil_tracking_report_detail(
     '1d000000-0000-4000-8000-000000000002',
     (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000002')
   )->'issues') as elem(value)),
  'fryer-21,fryer-22,fryer-25',
  'inactive high TPM is not present in detail issues'
);

select throws_ok($$
  select public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000002',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000001')
  )
$$, '42501', 'oil report access denied', 'other supervisor cannot read opening-only detail');
select throws_ok($$
  select public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000001',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000002')
  )
$$, '42501', 'oil report access denied', 'cross-branch supervisor cannot read complete detail');
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',1,20)->'reports'->0->>'id',
  (select id::text from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000001'),
  'supervisor list is scoped to own team report'
);
select is(
  public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002',1,20)->'reports'->0->>'id',
  (select id::text from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000002'),
  'other supervisor list is scoped to their branch report'
);
select throws_ok($$
  select public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000004','3d000000-0000-4000-8000-000000000001',1,20)
$$, '42501', 'oil report access denied', 'organization manager cannot use supervisor oil report list RPC');
select throws_ok($$
  select public.get_oil_tracking_report_detail(
    '1d000000-0000-4000-8000-000000000004',
    (select id from public.oil_tracking_submissions where supervisor_team_id = '4d000000-0000-4000-8000-000000000001')
  )
$$, '42501', 'oil report access denied', 'organization manager cannot use supervisor oil report detail RPC');
select throws_ok($$
  select public.list_oil_tracking_supervisor_reports('1d000000-0000-4000-8000-000000000003','3d000000-0000-4000-8000-000000000001',1,20)
$$, '42501', 'oil report access denied', 'staff cannot use supervisor oil report list RPC');

select * from finish();
rollback;
