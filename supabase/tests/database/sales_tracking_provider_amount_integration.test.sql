begin;
select plan(26);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@sales-provider.invalid','{}','{}',now(),now()
from unnest(array[
  '1c000000-0000-4000-8000-000000000001'::uuid,
  '1c000000-0000-4000-8000-000000000002'
]) id;

update public.profiles set full_name=case id
  when '1c000000-0000-4000-8000-000000000001' then 'Provider Supervisor'
  else 'Provider Manager'
end, must_change_password=false
where id::text like '1c000000-%';

insert into public.organizations(id,name,slug) values
  ('2c000000-0000-4000-8000-000000000001','Sales Provider Org','sales-provider-org');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('3c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','Provider Branch','PRV','Asia/Riyadh'),
  ('3c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000001','Legacy Branch','LGY','Asia/Riyadh');

insert into public.organization_memberships(organization_id,user_id,role) values
  ('2c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002','organization_manager');

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001','branch_manager'),
  ('3c000000-0000-4000-8000-000000000002','1c000000-0000-4000-8000-000000000001','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001'),
  ('4c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002','1c000000-0000-4000-8000-000000000001');

select is(
  (select string_agg(provider->>'name', ',' order by ordinality)
   from jsonb_array_elements(public.list_sales_tracking_online_order_providers('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'providers') with ordinality provider(provider,ordinality)),
  'Jahez,Ninja,HungerStation,The Chef,Try Order',
  'default providers list in product order'
);

select lives_ok($$select public.create_sales_tracking_online_order_provider('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','  Quick   Eats  ')$$,'Supervisor creates a custom provider');
select is(
  (select (public.list_sales_tracking_online_order_providers('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'providers'->5->>'name')),
  'Quick Eats',
  'custom providers appear after defaults'
);

select lives_ok(format($$select public.save_sales_tracking_draft(
  '1c000000-0000-4000-8000-000000000001',
  '3c000000-0000-4000-8000-000000000001',
  0,
  'middle_shift',
  '[{"entry_date":"%s","actual_cash":100,"actual_credit":50,"pos_cash":90,"pos_credit":60,"online_delivery":999,"online_amounts":[{"provider_id":"%s","amount":100},{"provider_id":"%s","amount":50}]}]',
  '[{"entry_date":"%s","remaining_cash":0}]'
)$$,
private.phase4a_business_date('Asia/Riyadh'),
(select id from public.sales_tracking_online_order_providers where branch_id='3c000000-0000-4000-8000-000000000001' and default_provider_key='jahez'),
(select id from public.sales_tracking_online_order_providers where branch_id='3c000000-0000-4000-8000-000000000001' and default_provider_key='ninja'),
private.phase4a_business_date('Asia/Riyadh')),'provider-aware Middle Shift saves');

select is((select online_delivery::text from public.sales_tracking_sales_rows row join public.sales_tracking_reports report on report.id=row.report_id where report.branch_id='3c000000-0000-4000-8000-000000000001'),'150','DB derives online_delivery from provider amount sum');
select is((select count(*) from public.sales_tracking_online_amounts where branch_id='3c000000-0000-4000-8000-000000000001'),2::bigint,'provider amount rows created');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'actual_cash','100','Actual Cash unchanged');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'pos_cash','90','POS Cash unchanged');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'actual_credit','50','Actual Credit unchanged');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'pos_credit','60','POS Credit unchanged');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'actual_total','300','Actual Total formula unchanged');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'pos_total','300','POS Total formula unchanged');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'variance','0','variance formula unchanged');
select is(jsonb_array_length(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->'online_amounts'),2,'current state restores provider breakdown');

select lives_ok(format($$select public.save_sales_tracking_draft(
  '1c000000-0000-4000-8000-000000000001',
  '3c000000-0000-4000-8000-000000000001',
  1,
  'closing_shift',
  '[{"entry_date":"%s","actual_cash":0,"actual_credit":0,"pos_cash":0,"pos_credit":0,"online_delivery":0,"online_amounts":[{"provider_id":"%s","amount":250}]}]',
  '[{"entry_date":"%s","remaining_cash":0}]'
)$$,
private.phase4a_business_date('Asia/Riyadh'),
(select id from public.sales_tracking_online_order_providers where branch_id='3c000000-0000-4000-8000-000000000001' and default_provider_key='jahez'),
private.phase4a_business_date('Asia/Riyadh')),'provider-aware Closing Shift saves separately');

select is((select sum(amount)::text from public.sales_tracking_online_amounts amount join public.sales_tracking_period_entries period on period.id=(select row.period_entry_id from public.sales_tracking_sales_rows row where row.id=amount.sales_row_id) where period.entry_period='middle_shift'),'150','Middle Shift provider amounts remain separate');
select is((select sum(amount)::text from public.sales_tracking_online_amounts amount join public.sales_tracking_period_entries period on period.id=(select row.period_entry_id from public.sales_tracking_sales_rows row where row.id=amount.sales_row_id) where period.entry_period='closing_shift'),'250','Closing Shift provider amounts remain separate');
select lives_ok($$select public.submit_sales_tracking('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',2,'5c000000-0000-4000-8000-000000000001',repeat('c',64))$$,'submitted report preserves provider breakdown');
select is(jsonb_array_length(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->'online_amounts'),2,'submitted current state returns provider breakdown');
select is(
  (select sum((row->>'online_delivery')::numeric)::text from jsonb_array_elements(public.list_managed_sales_tracking_reports('1c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000001')->'sales_rows') row),
  '400',
  'Manager reports consume aggregate online_delivery exactly once'
);

select lives_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002',0,'middle_shift','[{"entry_date":"%s","actual_cash":0,"actual_credit":0,"pos_cash":0,"pos_credit":0,"online_delivery":300}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'legacy aggregate-only row still saves');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002')->'sales_rows'->0->>'online_delivery','300','legacy aggregate remains readable');
select is(jsonb_array_length(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002')->'sales_rows'->0->'online_amounts'),0,'legacy aggregate does not fabricate provider rows');

select throws_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002',1,'closing_shift','[{"entry_date":"%s","actual_cash":0,"actual_credit":0,"pos_cash":0,"pos_credit":0,"online_delivery":0,"online_amounts":[{"provider_id":"%s","amount":1},{"provider_id":"%s","amount":2}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),(select id from public.sales_tracking_online_order_providers where branch_id='3c000000-0000-4000-8000-000000000002' and default_provider_key='jahez'),(select id from public.sales_tracking_online_order_providers where branch_id='3c000000-0000-4000-8000-000000000002' and default_provider_key='jahez'),private.phase4a_business_date('Asia/Riyadh')),'22023','duplicate sales tracking online provider','duplicate provider IDs are rejected');
select throws_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002',1,'closing_shift','[{"entry_date":"%s","actual_cash":0,"actual_credit":0,"pos_cash":0,"pos_credit":0,"online_delivery":0,"online_amounts":[{"provider_id":"%s","amount":1}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),(select id from public.sales_tracking_online_order_providers where branch_id='3c000000-0000-4000-8000-000000000001' and default_provider_key='jahez'),private.phase4a_business_date('Asia/Riyadh')),'22023','invalid sales tracking online provider scope','cross-branch provider ID rejected');
select throws_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000002',1,'closing_shift','[{"entry_date":"%s","actual_cash":0,"actual_credit":0,"pos_cash":0,"pos_credit":0,"online_delivery":0,"online_amounts":[{"provider_id":"%s","amount":-1}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),(select id from public.sales_tracking_online_order_providers where branch_id='3c000000-0000-4000-8000-000000000002' and default_provider_key='jahez'),private.phase4a_business_date('Asia/Riyadh')),'22023','invalid sales tracking numeric field','negative provider amount rejected');

select * from finish();
rollback;
