begin;
select plan(23);

-- Disposable fixture IDs. This suite must run in a disposable database and is
-- rolled back; it is never a Production data setup script.
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000',
  'fa400000-0000-4000-8000-000000000001','authenticated','authenticated',
  'notification-category-manager@invalid.test','{}','{}',now(),now());
update public.profiles set full_name='Category Manager',must_change_password=false,disabled_at=null
where id='fa400000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug,active)
values
  ('fb400000-0000-4000-8000-000000000001','Category Org','category-org',true),
  ('fb400000-0000-4000-8000-000000000002','Other Category Org','other-category-org',true);
insert into public.branches(id,organization_id,name,code,timezone)
values
  ('fc400000-0000-4000-8000-000000000001','fb400000-0000-4000-8000-000000000001','Category Branch','CAT','Asia/Riyadh'),
  ('fc400000-0000-4000-8000-000000000002','fb400000-0000-4000-8000-000000000002','Other Category Branch','OCAT','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role,active)
values('fb400000-0000-4000-8000-000000000001','fa400000-0000-4000-8000-000000000001','organization_manager',true);
insert into public.daily_report_branch_lifecycle(
  organization_id,branch_id,effective_from_business_date,active,timezone
) values('fb400000-0000-4000-8000-000000000001','fc400000-0000-4000-8000-000000000001',
  '2020-01-01',true,'Asia/Riyadh');

select has_column('public','organization_manager_notifications','branch_id','category branch context column exists');
select has_column('public','organization_manager_notifications','business_date','category business date column exists');
select has_column('public','organization_manager_notifications','category_context','typed category context column exists');
select has_function('public','create_organization_manager_category_notification',array['uuid','uuid','text','uuid','date','jsonb','text'],'dedicated category insertion RPC exists');
select ok((select prosecdef from pg_catalog.pg_proc where oid='public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)'::regprocedure),'category insertion is SECURITY DEFINER');
select ok((select coalesce(array_to_string(proconfig,','),'') like '%search_path=""%' from pg_catalog.pg_proc where oid='public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)'::regprocedure),'category insertion has empty search_path');
select ok(has_function_privilege('service_role','public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)','execute'),'service_role can execute category insertion');
select ok(not has_function_privilege('public','public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)','execute'),'PUBLIC cannot execute category insertion');
select ok(not has_function_privilege('anon','public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)','execute'),'anon cannot execute category insertion');
select ok(not has_function_privilege('authenticated','public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)','execute'),'authenticated cannot execute category insertion');
select ok(not has_table_privilege('service_role','public.organization_manager_notifications','insert'),'service_role cannot directly insert notification history');
select has_trigger('public','organization_manager_push_deliveries','organization_manager_category_no_push_guard','category push guard exists');
select ok(not exists(select 1 from pg_catalog.pg_proc where proname='produce_staff_hygiene_missing_notifications'),'standalone Staff Hygiene producer is absent');

set local role service_role;
select throws_ok($$select * from public.create_organization_manager_category_notification(
  null,'fa400000-0000-4000-8000-000000000001','sales_tracking_missing',
  'fc400000-0000-4000-8000-000000000001',current_date - 1,
  '{"schema_version":"1","category":"sales_tracking_missing","evidence":"missing"}'::jsonb,
  'bad')$$,'42501','manager notification access denied','null organization/actor scope is denied');
select throws_ok($$select * from public.create_organization_manager_category_notification(
  'fb400000-0000-4000-8000-000000000001','fa400000-0000-4000-8000-000000000001','sales_tracking_missing',
  'fc400000-0000-4000-8000-000000000001',current_date - 1,
  '{"schema_version":"1","category":"sales_tracking_missing","evidence":"not_missing"}'::jsonb,
  'bad')$$,'22023','invalid manager notification category scope','malformed category context is rejected');
select throws_ok($$select * from public.create_organization_manager_category_notification(
  'fb400000-0000-4000-8000-000000000002','fa400000-0000-4000-8000-000000000001','sales_tracking_missing',
  'fc400000-0000-4000-8000-000000000002',current_date - 1,
  '{"schema_version":"1","category":"sales_tracking_missing","evidence":"missing"}'::jsonb,
  'manager:v1:sales_tracking_missing:fb400000-0000-4000-8000-000000000002:fc400000-0000-4000-8000-000000000002:'|| (current_date - 1)::text)$$,
  '42501','manager notification access denied','cross-organization recipient scope is denied');
select lives_ok($$select * from public.create_organization_manager_category_notification(
  'fb400000-0000-4000-8000-000000000001','fa400000-0000-4000-8000-000000000001','sales_tracking_missing',
  'fc400000-0000-4000-8000-000000000001',current_date - 1,
  '{"schema_version":"1","category":"sales_tracking_missing","evidence":"missing"}'::jsonb,
  'manager:v1:sales_tracking_missing:fb400000-0000-4000-8000-000000000001:fc400000-0000-4000-8000-000000000001:'|| (current_date - 1)::text)$$,
  'authorized category notification is created after the completed date');
reset role;
select is((select count(*)::integer from public.organization_manager_notifications where organization_id='fb400000-0000-4000-8000-000000000001' and event_type='sales_tracking_missing'),1,'one category notification is stored');
select is((select count(*)::integer from public.organization_manager_push_deliveries delivery join public.organization_manager_notifications notification on notification.id=delivery.notification_id where notification.event_type='sales_tracking_missing'),0,'category notification creates no push delivery');
set local role service_role;
select lives_ok($$select * from public.create_organization_manager_category_notification(
  'fb400000-0000-4000-8000-000000000001','fa400000-0000-4000-8000-000000000001','sales_tracking_missing',
  'fc400000-0000-4000-8000-000000000001',current_date - 1,
  '{"schema_version":"1","category":"sales_tracking_missing","evidence":"missing"}'::jsonb,
  'manager:v1:sales_tracking_missing:fb400000-0000-4000-8000-000000000001:fc400000-0000-4000-8000-000000000001:'|| (current_date - 1)::text)$$,
  'duplicate category notification is idempotent');
reset role;
select is((select count(*)::integer from public.organization_manager_notifications where organization_id='fb400000-0000-4000-8000-000000000001' and event_type='sales_tracking_missing'),1,'duplicate category notification is not inserted');
select is((select read_at from public.organization_manager_notifications where event_type='sales_tracking_missing' limit 1),null::timestamptz,'new category notification starts unread');
select throws_ok($$update public.organization_manager_notifications set category_context='{}'::jsonb where event_type='sales_tracking_missing'$$,'42501','manager notification history is immutable','category context cannot be mutated');

select * from finish();
rollback;
