begin;
select plan(18);

-- Disposable-only fixture. All rows are rolled back at the end of this suite.
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','f4a00000-0000-4000-8000-000000000001','authenticated','authenticated','cursor-manager@invalid.test','{}','{}',now(),now());
update public.profiles set full_name='Cursor Manager',must_change_password=false,disabled_at=null
where id='f4a00000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug,active) values
  ('f4a00000-0000-4000-8000-000000000002','Cursor Test Org','cursor-test-org',true);
insert into public.organization_memberships(organization_id,user_id,role,active)
values('f4a00000-0000-4000-8000-000000000002','f4a00000-0000-4000-8000-000000000001','organization_manager',true);
insert into public.branches(id,organization_id,name,code,timezone,active)
values('f4a00000-0000-4000-8000-000000000003','f4a00000-0000-4000-8000-000000000002','Cursor Branch','CUR','UTC',true);
-- Branch creation installs the authoritative open lifecycle row through the
-- repository trigger. Reuse that row instead of inserting an overlapping
-- synthetic effective period.
update public.daily_report_branch_lifecycle
set effective_from_business_date='2026-01-01', timezone='UTC'
where organization_id='f4a00000-0000-4000-8000-000000000002'
  and branch_id='f4a00000-0000-4000-8000-000000000003'
  and effective_to_business_date is null;

set local role service_role;
do $$
declare
  business_date date;
begin
  for i in 1..101 loop
    business_date := date '2026-01-01' + (i - 1);
    perform public.create_organization_manager_category_notification(
      'f4a00000-0000-4000-8000-000000000002','f4a00000-0000-4000-8000-000000000001','incomplete_branch_tasks',
      'f4a00000-0000-4000-8000-000000000003',business_date,
      jsonb_build_object('schema_version','1','category','incomplete_branch_tasks','incomplete_modules',jsonb_build_array('kitchen_opening'),'incomplete_count',1),
      'manager:v1:incomplete_branch_tasks:f4a00000-0000-4000-8000-000000000002:f4a00000-0000-4000-8000-000000000003:'||business_date::text);
  end loop;
end;
$$;
reset role;

create temporary table cursor_page_1 on commit drop as
select * from public.list_organization_manager_notification_projection_cursor(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000002',null,null,100);
select is((select count(*)::integer from cursor_page_1),100,'first cursor page is full');
select ok((select coalesce(max(row_count),0)>1 from (select count(*) row_count from cursor_page_1 group by created_at) grouped),'same timestamp rows are retained');
select is((select public.count_organization_manager_notification_projection(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000002'))::integer,101,'unread count is independent of pages');

create temporary table cursor_boundary on commit drop as
select created_at,id from cursor_page_1 order by created_at asc,id asc limit 1;
create temporary table cursor_page_2 on commit drop as
select * from public.list_organization_manager_notification_projection_cursor(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000002',
  (select created_at from cursor_boundary),(select id from cursor_boundary),100);
select is((select count(*)::integer from cursor_page_2),1,'second cursor page contains the remaining row');
select is((select count(*)::integer from cursor_page_1 p join cursor_page_2 n on n.id=p.id),0,'cursor pages do not duplicate IDs');
select ok((select count(*) from cursor_page_2 where (created_at,id) < (select created_at,id from cursor_boundary))=1,'cursor ordering is strictly descending');
select throws_ok($$select * from public.list_organization_manager_notification_projection_cursor(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000002',now(),null,100)$$,
  '22023','invalid manager notification projection cursor','mixed cursor fields are rejected');
select throws_ok($$select * from public.list_organization_manager_notification_projection_cursor(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000009',null,null,100)$$,
  '42501','manager notification access denied','cursor cannot cross organizations');

create temporary table cursor_page_37 on commit drop as
select * from public.list_organization_manager_notification_projection_cursor(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000002',null,null,37);
select is((select count(*)::integer from cursor_page_37),37,'page limits are honored');
create temporary table cursor_page_1_limit on commit drop as
select * from public.list_organization_manager_notification_projection_cursor(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000002',null,null,1);
select is((select count(*)::integer from cursor_page_1_limit),1,'limit one is honored');
select throws_ok($$select * from public.list_organization_manager_notification_projection_cursor(
  'f4a00000-0000-4000-8000-000000000001','f4a00000-0000-4000-8000-000000000002',null,null,0)$$,
  '22023','invalid manager notification projection cursor list','invalid page limit is rejected');
select ok(pg_catalog.to_regprocedure('public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)') is not null,
  'Phase 3A projection RPC remains available');
select ok((select c.relrowsecurity from pg_catalog.pg_class c where c.oid='public.organization_manager_notifications'::regclass),
  'notification RLS remains enabled');
select ok(has_function_privilege('service_role','public.list_organization_manager_notification_projection_cursor(uuid,uuid,timestamptz,uuid,integer)','execute'),
  'service_role can execute cursor RPC');
select ok(not has_function_privilege('anon','public.list_organization_manager_notification_projection_cursor(uuid,uuid,timestamptz,uuid,integer)','execute'),
  'anon cannot execute cursor RPC');
select is((select count(*)::integer from public.organization_manager_push_deliveries where notification_id in (
  select id from public.organization_manager_notifications where organization_id='f4a00000-0000-4000-8000-000000000002')),
  0,'cursor-category fixtures create no push deliveries');
select ok(not private.organization_manager_notification_branch_date_closed(
  'f4a00000-0000-4000-8000-000000000002','f4a00000-0000-4000-8000-000000000003','2026-01-01','2026-01-02 03:59:59+00'::timestamptz),
  'branch date remains hidden at 03:59:59');
select ok(private.organization_manager_notification_branch_date_closed(
  'f4a00000-0000-4000-8000-000000000002','f4a00000-0000-4000-8000-000000000003','2026-01-01','2026-01-02 04:00:00+00'::timestamptz),
  'branch date is visible at 04:00:00');

select * from finish();
rollback;
