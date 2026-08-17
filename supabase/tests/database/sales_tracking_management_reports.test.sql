begin;
select plan(14);

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
  when '1d000000-0000-4000-8000-000000000001' then 'Submitted Sales Supervisor'
  when '1d000000-0000-4000-8000-000000000002' then 'Draft Sales Supervisor'
  when '1d000000-0000-4000-8000-000000000003' then 'Sales Manager One'
  else 'Sales Manager Two'
end, must_change_password = false
where id::text like '1d000000-%';

insert into public.organizations(id,name,slug) values
  ('2d000000-0000-4000-8000-000000000001','Managed Sales Org','managed-sales-org'),
  ('2d000000-0000-4000-8000-000000000002','Other Sales Org','other-sales-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Alpha Branch','ALPHA','Asia/Riyadh'),
  ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000002','Other Branch','OTHER','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000003','organization_manager'),
  ('2d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager'),
  ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001'),
  ('4d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002');

select is(has_function_privilege('authenticated','public.list_managed_sales_tracking_reports(uuid,uuid,date,date)','execute'),false,'authenticated cannot execute managed sales tracking report RPC');
select is(has_function_privilege('service_role','public.list_managed_sales_tracking_reports(uuid,uuid,date,date)','execute'),true,'service role can execute managed sales tracking report RPC');

select lives_ok(format($$
  select public.save_sales_tracking_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    0,
    'middle_shift',
    '[{"entry_date":"%s","actual_cash":"100","actual_credit":"50","pos_cash":"80","pos_credit":"60","online_delivery":"10","online_amounts":[{"provider_id":"%s","amount":"7"},{"provider_id":"%s","amount":"3"}],"remarks":"submitted"}]'::jsonb,
    '[{"entry_date":"%s","denom_1":2,"denom_2":1,"denom_5":1,"denom_10":1,"denom_20":0,"denom_50":0,"denom_100":1,"denom_200":0,"denom_500":0,"remaining_cash":"33","remarks":"counted"}]'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'),
  (select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000001' and default_provider_key='jahez'),
  (select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000001' and default_provider_key='hungerstation'),
  private.phase4a_business_date('Asia/Riyadh')), 'first supervisor saves Middle Shift');
select lives_ok(format($$
  select public.save_sales_tracking_draft(
    '1d000000-0000-4000-8000-000000000002',
    '3d000000-0000-4000-8000-000000000001',
    1,
    'closing_shift',
    '[{"entry_date":"%s","actual_cash":"0","actual_credit":"0","pos_cash":"0","pos_credit":"0","online_delivery":"0"}]'::jsonb,
    '[{"entry_date":"%s","remaining_cash":"0"}]'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')), 'second supervisor saves Closing Shift');
select lives_ok($$select public.submit_sales_tracking('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',2,'5d000000-0000-4000-8000-000000000001',repeat('a',64))$$,'supervisor submits complete branch/day report');

select is(
  jsonb_array_length(public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')->'sales_rows'),
  2,
  'manager sees both submitted Sales periods for managed organization'
);
select is(
  jsonb_array_length(public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')->'cash_rows'),
  2,
  'manager sees both submitted Cash periods for managed organization'
);
select is(
  (select row->>'actual_total'from jsonb_array_elements(public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')->'sales_rows')row where row->>'entry_period'='middle_shift'),
  '160',
  'managed sales report computes actual total'
);
select is(
  (select row->>'variance'from jsonb_array_elements(public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')->'sales_rows')row where row->>'entry_period'='middle_shift'),
  '10',
  'managed sales report computes variance'
);
select is(
  (select amount->>'amount' from jsonb_array_elements(public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')->'sales_rows') row, jsonb_array_elements(row->'online_provider_breakdown') amount where row->>'entry_period'='middle_shift' and amount->>'provider_key'='jahez'),
  '7',
  'managed sales report returns Jahez provider amount'
);
select is(
  (select amount->>'amount' from jsonb_array_elements(public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')->'sales_rows') row, jsonb_array_elements(row->'online_provider_breakdown') amount where row->>'entry_period'='middle_shift' and amount->>'provider_key'='hungerstation'),
  '3',
  'managed sales report returns HungerStation provider amount'
);
select is(
  (select row->>'cash_total'from jsonb_array_elements(public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001')->'cash_rows')row where row->>'entry_period'='middle_shift'),
  '119',
  'managed cash report computes denomination total'
);
select throws_ok($$
  select public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000004','2d000000-0000-4000-8000-000000000001')
$$, '42501', 'sales tracking report access denied', 'other manager is denied');
select throws_ok($$
  select public.list_managed_sales_tracking_reports('1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001')
$$, '42501', 'sales tracking report access denied', 'supervisor is denied');

select * from finish();
rollback;
