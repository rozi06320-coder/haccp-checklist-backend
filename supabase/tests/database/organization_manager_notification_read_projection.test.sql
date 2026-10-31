begin;
select plan(22);

-- Disposable-only fixtures. This suite is always rolled back.
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','f3a00000-0000-4000-8000-000000000001','authenticated','authenticated','projection-manager@invalid.test','{}','{}',now(),now());
update public.profiles set full_name='Projection Manager',must_change_password=false,disabled_at=null
where id='f3a00000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug,active) values
  ('f3a00000-0000-4000-8000-000000000002','Projection Test Org','projection-test-org',true),
  ('f3a00000-0000-4000-8000-000000000009','Projection Other Org','projection-other-org',true);
insert into public.organization_memberships(organization_id,user_id,role,active)
values('f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000001','organization_manager',true);
insert into public.branches(id,organization_id,name,code,timezone,active)
values('f3a00000-0000-4000-8000-000000000003','f3a00000-0000-4000-8000-000000000002','Projection Branch','P3A','America/Adak',true);
insert into public.daily_report_branch_lifecycle(organization_id,branch_id,effective_from_business_date,effective_to_business_date,active,timezone)
values('f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000003','2026-10-29','2026-10-30',true,'America/Adak');

select ok((select prosecdef from pg_proc where oid='public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)'::regprocedure),'projection list is SECURITY DEFINER');
select ok((select 'search_path=""'=any(coalesce(proconfig,'{}'::text[])) from pg_proc where oid='public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)'::regprocedure),'projection list has empty search_path');
select ok(has_function_privilege('service_role','public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)','execute'),'service_role can execute projection list');
select ok(not has_function_privilege('anon','public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)','execute'),'anon cannot execute projection list');
select ok(not has_function_privilege('authenticated','public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)','execute'),'authenticated cannot execute projection list');

set local role service_role;
select lives_ok($$select * from public.create_organization_manager_category_notification(
  'f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000001','sales_tracking_missing',
  'f3a00000-0000-4000-8000-000000000003','2026-10-29',
  '{"schema_version":"1","category":"sales_tracking_missing","evidence":"missing"}'::jsonb,
  'manager:v1:sales_tracking_missing:f3a00000-0000-4000-8000-000000000002:f3a00000-0000-4000-8000-000000000003:2026-10-29')$$,
  'valid category fixture is accepted');
select lives_ok($$select * from public.create_organization_manager_category_notification(
  'f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000001','incomplete_branch_tasks',
  'f3a00000-0000-4000-8000-000000000003','2026-10-29',
  '{"schema_version":"1","category":"incomplete_branch_tasks","incomplete_modules":["kitchen_opening"],"incomplete_count":1}'::jsonb,
  'manager:v1:incomplete_branch_tasks:f3a00000-0000-4000-8000-000000000002:f3a00000-0000-4000-8000-000000000003:2026-10-29')$$,
  'second category fixture is accepted');
reset role;

select is((select count(*)::integer from public.list_organization_manager_notification_projection(
  'f3a00000-0000-4000-8000-000000000001','f3a00000-0000-4000-8000-000000000002',null,1)),1,'pagination limit is deterministic');
select is((select public.count_organization_manager_notification_projection('f3a00000-0000-4000-8000-000000000001','f3a00000-0000-4000-8000-000000000002'))::integer,2,'unread count is independent of page limit');
select is((select count(*)::integer from public.organization_manager_push_deliveries delivery join public.organization_manager_notifications n on n.id=delivery.notification_id where n.organization_id='f3a00000-0000-4000-8000-000000000002'),0,'category rows create no push deliveries');
select ok(private.organization_manager_notification_branch_date_closed('f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000003','2026-10-29','2026-10-30 14:00+00'::timestamptz),'branch date is closed after 04:00');
select ok(not private.organization_manager_notification_branch_date_closed('f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000003','2026-10-29','2026-10-30 12:59+00'::timestamptz),'branch date remains open before 04:00');
select throws_ok($$select * from public.create_organization_manager_category_notification(
  'f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000001','sales_tracking_missing',
  'f3a00000-0000-4000-8000-000000000003','2026-10-29',
  '{"schema_version":"1","category":"sales_tracking_missing","evidence":"invalid"}'::jsonb,
  'manager:v1:sales_tracking_missing:f3a00000-0000-4000-8000-000000000002:f3a00000-0000-4000-8000-000000000003:2026-10-29')$$,
  '22023','invalid manager notification category scope','malformed category context is rejected');
select throws_ok($$select * from public.list_organization_manager_notification_projection(
  'f3a00000-0000-4000-8000-000000000001','f3a00000-0000-4000-8000-000000000009',null,10)$$,
  '42501','manager notification access denied','cross-organization projection is denied');

insert into public.organization_manager_notifications(id,organization_id,recipient_user_id,event_type,source_type,source_id,occurrence_key,read_at,created_at,updated_at)
values('f3a00000-0000-4000-8000-000000000010','f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000001','maintenance_issue_created',null,null,'legacy:office:f3',now(),now(),now());
select is((select count(*)::integer from public.list_organization_manager_notification_projection(
  'f3a00000-0000-4000-8000-000000000001','f3a00000-0000-4000-8000-000000000002',null,100) where branch_id is null and business_date is null),1,'office legacy maintenance is retained without fabricated scope');
insert into public.maintenance_issues(id,organization_id,branch_id,title,category,priority,description,reported_by,location_scope,created_at,updated_at)
values('f3a00000-0000-4000-8000-000000000011','f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000003','Projection maintenance','equipment','normal','synthetic','f3a00000-0000-4000-8000-000000000001','branch','2026-10-30 12:00+00','2026-10-30 12:00+00');
insert into public.organization_manager_notifications(id,organization_id,recipient_user_id,event_type,source_type,source_id,occurrence_key,created_at,updated_at)
values('f3a00000-0000-4000-8000-000000000012','f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000001','maintenance_issue_created','maintenance_issue','f3a00000-0000-4000-8000-000000000011','legacy:branch:f3', '2026-10-30 12:00+00','2026-10-30 12:00+00');
insert into public.organization_manager_notifications(id,organization_id,recipient_user_id,event_type,branch_id,business_date,category_context,occurrence_key,created_at,updated_at)
values('f3a00000-0000-4000-8000-000000000013','f3a00000-0000-4000-8000-000000000002','f3a00000-0000-4000-8000-000000000001','maintenance_issue','f3a00000-0000-4000-8000-000000000003','2026-10-29','{"schema_version":"1","category":"maintenance_issue","issue_ids":["f3a00000-0000-4000-8000-000000000011"],"issue_count":1}'::jsonb,'manager:v1:maintenance_issue:f3a00000-0000-4000-8000-000000000002:f3a00000-0000-4000-8000-000000000003:2026-10-29','2026-10-30 12:00+00','2026-10-30 12:00+00');
select is((select count(*)::integer from public.list_organization_manager_notification_projection(
  'f3a00000-0000-4000-8000-000000000001','f3a00000-0000-4000-8000-000000000002',null,100) where legacy_notification_id='f3a00000-0000-4000-8000-000000000012'),0,'legacy branch maintenance duplicate is suppressed by authoritative issue identity');
select is((select count(*)::integer from public.list_organization_manager_notification_projection(
  'f3a00000-0000-4000-8000-000000000001','f3a00000-0000-4000-8000-000000000002',null,100) where category='maintenance_issue' and legacy_notification_id is null and category_context->'issue_ids' ? 'f3a00000-0000-4000-8000-000000000011'),1,'category row wins over legacy branch row');
select is((select count(*)::integer from public.list_organization_manager_notification_projection(
  'f3a00000-0000-4000-8000-000000000001','f3a00000-0000-4000-8000-000000000002',null,100) where category in('sales_tracking_missing','incomplete_branch_tasks')),2,'new categories are normalized');
select ok((select count(*)=5 from public.organization_manager_notifications where organization_id='f3a00000-0000-4000-8000-000000000002'),'notification history is unchanged by reads');
select is((select count(*)::integer from public.organization_manager_notifications where read_at is not null),1,'existing read_at is preserved');
select ok(not has_table_privilege('service_role','public.organization_manager_notifications','insert'),'direct service_role table insert remains denied');
select is((select count(*)::integer from public.organization_manager_notifications
  where organization_id='f3a00000-0000-4000-8000-000000000002' and read_at is not null),1,'read state remains recipient-specific');
select * from finish();
rollback;
