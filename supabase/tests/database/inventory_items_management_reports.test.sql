begin;
select plan(13);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000001'::uuid,
  '1e000000-0000-4000-8000-000000000002',
  '1e000000-0000-4000-8000-000000000003',
  '1e000000-0000-4000-8000-000000000004',
  '1e000000-0000-4000-8000-000000000005'
]) id;

update public.profiles set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Inventory Submitted Supervisor'
  when '1e000000-0000-4000-8000-000000000002' then 'Inventory Draft Supervisor'
  when '1e000000-0000-4000-8000-000000000003' then 'Inventory Manager'
  when '1e000000-0000-4000-8000-000000000004' then 'Other Inventory Manager'
  else 'Inventory Submitting Branch Peer'
end, must_change_password = false
where id::text like '1e000000-%';

insert into public.organizations(id,name,slug) values
  ('2e000000-0000-4000-8000-000000000001','Managed Inventory Org','managed-inventory-org'),
  ('2e000000-0000-4000-8000-000000000002','Other Inventory Org','other-inventory-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Submitted Branch','SUB','Asia/Riyadh'),
  ('3e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','Draft Branch','DRF','Asia/Riyadh'),
  ('3e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','Empty Branch','EMP','Asia/Riyadh'),
  ('3e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000002','Other Branch','OTH','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003','organization_manager'),
  ('2e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager'),
  ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000005','branch_manager'),
  ('3e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001'),
  ('4e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000005'),
  ('4e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002');

select is(has_function_privilege('authenticated','public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)','execute'),false,'authenticated cannot execute managed inventory report RPC');
select is(has_function_privilege('service_role','public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)','execute'),true,'service role can execute managed inventory report RPC');

select lives_ok($$
  select public.save_inventory_items_draft(
    '1e000000-0000-4000-8000-000000000001',
    '3e000000-0000-4000-8000-000000000001',
    '[{"production_date":"2026-08-08","russian_kg":"10","australian_kg":"4","fat_kg":"1","ready_patty":"100","hunch_sauce_kg":"2","wastage_grams":"50"}]'::jsonb,
    '{"usage_month":"2026-08-01","items":[{"group_name":"Submitted Branch","item_name":"Smokey Beef Burger","usage":{"1":"2","8":"3"}}]}'::jsonb
  )
$$, 'first supervisor creates the shared branch inventory month');
select lives_ok($$
  select public.submit_inventory_items(
    '1e000000-0000-4000-8000-000000000005',
    '3e000000-0000-4000-8000-000000000001',
    '5e000000-0000-4000-8000-000000000001',
    'managed-inventory-submitted-hash',
    '[{"production_date":"2026-08-08","russian_kg":"10","australian_kg":"4","fat_kg":"1","ready_patty":"100","hunch_sauce_kg":"2","wastage_grams":"50"}]'::jsonb,
    '{"usage_month":"2026-08-01","items":[{"group_name":"Submitted Branch","item_name":"Smokey Beef Burger","usage":{"1":"2","8":"3"}}]}'::jsonb
  )
$$, 'submitted branch inventory month closes');
select lives_ok($$
  select public.save_inventory_items_draft(
    '1e000000-0000-4000-8000-000000000002',
    '3e000000-0000-4000-8000-000000000002',
    '[{"production_date":"2026-08-09","russian_kg":"2","australian_kg":"1","fat_kg":"1","ready_patty":"20","hunch_sauce_kg":"1","wastage_grams":"5"}]'::jsonb,
    '{"usage_month":"2026-08-01","items":[{"group_name":"Draft Branch","item_name":"Texas Sauce","usage":{"2":"7"}}]}'::jsonb
  )
$$, 'draft branch inventory month saves');

select is(
  jsonb_array_length(public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','2026-08-01',null)->'reports'),
  3,
  'manager sees one row per active branch'
);
select is(
  public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','2026-08-01',null)->'reports'->0->>'status',
  'draft',
  'draft branch status is returned'
);
select is(
  (select report->>'status' from jsonb_array_elements(public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','2026-08-01',null)->'reports') report where report->>'branch_code'='EMP'),
  'not_submitted',
  'active branch with no report is derived as not submitted'
);
select is(
  (select report->'summary'->>'total_kg' from jsonb_array_elements(public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','2026-08-01',null)->'reports') report where report->>'branch_code'='SUB'),
  '15',
  'submitted branch beef total is computed'
);
select is(
  (select report->>'submitted_by' from jsonb_array_elements(public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','2026-08-01',null)->'reports') report where report->>'branch_code'='SUB'),
  'Inventory Submitting Branch Peer',
  'manager report identifies the supervisor who submitted the shared ledger'
);
select is(
  jsonb_array_length(public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','2026-08-01','3e000000-0000-4000-8000-000000000001')->'reports'),
  1,
  'branch filter returns one authorized branch'
);
select throws_ok($$
  select public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000001','2026-08-01',null)
$$, '42501', 'inventory management report access denied', 'other manager is denied');
select throws_ok($$
  select public.list_managed_inventory_items_reports('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','2026-08-01',null)
$$, '42501', 'inventory management report access denied', 'supervisor is denied');

select * from finish();
rollback;
