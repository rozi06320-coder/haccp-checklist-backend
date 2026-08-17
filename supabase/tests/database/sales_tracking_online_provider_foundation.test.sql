begin;
select plan(37);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@sales-online.invalid','{}','{}',now(),now()
from unnest(array[
  '1b000000-0000-4000-8000-000000000001'::uuid,
  '1b000000-0000-4000-8000-000000000002',
  '1b000000-0000-4000-8000-000000000003'
]) id;

update public.profiles set full_name=case id
  when '1b000000-0000-4000-8000-000000000001' then 'Online Supervisor'
  when '1b000000-0000-4000-8000-000000000002' then 'Online Manager'
  else 'Other Online Supervisor'
end, must_change_password=false
where id::text like '1b000000-%';

insert into public.organizations(id,name,slug) values
  ('2b000000-0000-4000-8000-000000000001','Sales Online Org','sales-online-org'),
  ('2b000000-0000-4000-8000-000000000002','Other Sales Online Org','other-sales-online-org');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('3b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','Online Branch','ONL','Asia/Riyadh'),
  ('3b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000002','Other Online Branch','OONL','Asia/Riyadh');

insert into public.organization_memberships(organization_id,user_id,role) values
  ('2b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000002','organization_manager');

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001','branch_manager'),
  ('3b000000-0000-4000-8000-000000000002','1b000000-0000-4000-8000-000000000003','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001'),
  ('4b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000002','3b000000-0000-4000-8000-000000000002','1b000000-0000-4000-8000-000000000003');

select has_table('public','sales_tracking_online_order_providers','Sales Tracking online provider table exists');
select has_table('public','sales_tracking_online_amounts','Sales Tracking online amount table exists');
select ok((select relrowsecurity from pg_class where oid='public.sales_tracking_online_order_providers'::regclass),'provider table RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.sales_tracking_online_amounts'::regclass),'amount table RLS enabled');
select ok(not has_table_privilege('authenticated','public.sales_tracking_online_order_providers','insert,update,delete'),'authenticated cannot mutate providers directly');
select ok(not has_table_privilege('authenticated','public.sales_tracking_online_amounts','insert,update,delete'),'authenticated cannot mutate provider amounts directly');
select ok(not has_table_privilege('service_role','public.sales_tracking_online_order_providers','insert,update,delete'),'service role cannot mutate providers directly');
select ok(not has_table_privilege('service_role','public.sales_tracking_online_amounts','insert,update,delete'),'service role cannot mutate amounts directly');
select ok(has_function_privilege('service_role','public.list_sales_tracking_online_order_providers(uuid,uuid)','execute'),'service role can execute provider list RPC');
select ok(has_function_privilege('service_role','public.create_sales_tracking_online_order_provider(uuid,uuid,text)','execute'),'service role can execute provider create RPC');
select ok(not has_function_privilege('authenticated','public.create_sales_tracking_online_order_provider(uuid,uuid,text)','execute'),'authenticated cannot execute provider create RPC directly');

select is((select count(*) from public.sales_tracking_online_order_providers where branch_id='3b000000-0000-4000-8000-000000000001' and is_default),5::bigint,'new branch receives five default providers');
select is(
  (select string_agg(name, ',' order by default_provider_key) from public.sales_tracking_online_order_providers where branch_id='3b000000-0000-4000-8000-000000000001' and is_default),
  'HungerStation,Jahez,Ninja,The Chef,Try Order',
  'default provider names are seeded'
);
select is(jsonb_array_length(public.list_sales_tracking_online_order_providers('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'providers'),5,'Supervisor lists active branch providers');

select lives_ok($$select public.create_sales_tracking_online_order_provider('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','  Quick   Eats  ')$$,'Supervisor creates a branch-scoped custom provider');
select is((select name from public.sales_tracking_online_order_providers where branch_id='3b000000-0000-4000-8000-000000000001' and normalized_name='quick eats'),'Quick Eats','custom provider name is trimmed and whitespace-normalized');
select is((select created_by from public.sales_tracking_online_order_providers where branch_id='3b000000-0000-4000-8000-000000000001' and normalized_name='quick eats')::text,'1b000000-0000-4000-8000-000000000001','custom provider keeps actor attribution');
select throws_ok($$select public.create_sales_tracking_online_order_provider('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','JAHEZ')$$,'23505',null,'case-insensitive duplicate provider is rejected');
select throws_ok($$select public.create_sales_tracking_online_order_provider('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000002','Other Platform')$$,'42501','sales tracking online provider access denied','Supervisor cannot create provider in another branch');
select throws_ok($$select public.create_sales_tracking_online_order_provider('1b000000-0000-4000-8000-000000000002','3b000000-0000-4000-8000-000000000001','Manager Platform')$$,'42501','sales tracking online provider access denied','Manager cannot use Supervisor provider create RPC');

select lives_ok(format($$select public.save_sales_tracking_draft('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001',0,'middle_shift','[{"entry_date":"%s","actual_cash":100,"actual_credit":50,"pos_cash":90,"pos_credit":60,"online_delivery":25}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'existing aggregate Online Delivery draft still saves');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'actual_cash','100','Actual Cash still reads unchanged');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'pos_cash','90','POS Cash still reads unchanged');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'actual_credit','50','Actual Credit still reads unchanged');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'pos_credit','60','POS Credit still reads unchanged');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'online_delivery','25','existing online_delivery aggregate still reads');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'actual_total','175','actualTotal formula remains unchanged');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'pos_total','175','posTotal formula remains unchanged');
select is(public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'variance','0','variance formula remains unchanged');
select is((select count(*) from public.sales_tracking_online_amounts where sales_row_id=(select id from public.sales_tracking_sales_rows where report_id=(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001'))),0::bigint,'historical/new aggregate-only rows remain valid without provider breakdown');

insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)
select row.id, provider.id, amount.value
from public.sales_tracking_sales_rows row
join public.sales_tracking_reports report on report.id=row.report_id
join (values ('jahez',10::numeric),('ninja',15::numeric)) amount(provider_key,value) on true
join public.sales_tracking_online_order_providers provider on provider.branch_id=report.branch_id and provider.default_provider_key=amount.provider_key
where report.branch_id='3b000000-0000-4000-8000-000000000001';
set constraints sales_tracking_online_amounts_total_check immediate;
select is((select count(*) from public.sales_tracking_online_amounts where branch_id='3b000000-0000-4000-8000-000000000001'),2::bigint,'provider amount rows insert when they sum to online_delivery');
select is((select sum(amount)::text from public.sales_tracking_online_amounts where branch_id='3b000000-0000-4000-8000-000000000001'),'25','provider amount rows preserve aggregate online total');
select throws_ok($$update public.sales_tracking_online_amounts set amount=11 where branch_id='3b000000-0000-4000-8000-000000000001' and provider_id=(select id from public.sales_tracking_online_order_providers where branch_id='3b000000-0000-4000-8000-000000000001' and default_provider_key='jahez')$$,'55000','saved sales tracking online provider data is immutable','saved provider amounts cannot be updated');
select throws_ok($$delete from public.sales_tracking_online_amounts where branch_id='3b000000-0000-4000-8000-000000000001'$$,'55000','saved sales tracking online provider data is immutable','saved provider amounts are immutable');
select lives_ok(format($$select public.save_sales_tracking_draft('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001',1,'closing_shift','[{"entry_date":"%s","actual_cash":0,"actual_credit":0,"pos_cash":0,"pos_credit":0,"online_delivery":0}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'closing period saves without changing provider-aware middle period');
select lives_ok($$select public.submit_sales_tracking('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001',2,'5b000000-0000-4000-8000-000000000001',repeat('b',64))$$,'provider-aware aggregate report submits');
select is(
  (select sum((row->>'online_delivery')::numeric)::text from jsonb_array_elements(public.list_managed_sales_tracking_reports('1b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001')->'sales_rows') row),
  '25',
  'Manager read model still consumes aggregate online_delivery'
);

select * from finish();
rollback;
