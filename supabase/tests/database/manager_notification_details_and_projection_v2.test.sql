-- Test suite for migration 20261105010000_manager_notification_details_and_projection_v2.sql
begin;

select plan(28);

-- 1. Verify existence of new functions
select has_function('public', 'get_organization_manager_notification_detail', ARRAY['uuid', 'uuid', 'uuid'], 'get_organization_manager_notification_detail exists');
select has_function('public', 'list_organization_manager_notification_projection_cursor_v2', ARRAY['uuid', 'uuid', 'timestamptz', 'uuid', 'integer'], 'list_organization_manager_notification_projection_cursor_v2 exists');
select has_function('private', 'enrich_organization_manager_notification_context', ARRAY['uuid', 'text', 'uuid', 'date', 'uuid', 'jsonb', 'timestamptz'], 'enrich_organization_manager_notification_context exists');

-- 2. Verify security attributes (SECURITY DEFINER)
select is(
  (select prosecdef from pg_proc where proname = 'get_organization_manager_notification_detail' and pronamespace = 'public'::regnamespace),
  true,
  'get_organization_manager_notification_detail is SECURITY DEFINER'
);
select is(
  (select prosecdef from pg_proc where proname = 'list_organization_manager_notification_projection_cursor_v2' and pronamespace = 'public'::regnamespace),
  true,
  'list_organization_manager_notification_projection_cursor_v2 is SECURITY DEFINER'
);
select is(
  (select prosecdef from pg_proc where proname = 'enrich_organization_manager_notification_context' and pronamespace = 'private'::regnamespace),
  true,
  'enrich_organization_manager_notification_context is SECURITY DEFINER'
);

-- 3. Verify Grants: service_role has EXECUTE, public/anon/authenticated do NOT
select is(
  has_function_privilege('service_role', 'public.get_organization_manager_notification_detail(uuid,uuid,uuid)', 'EXECUTE'),
  true,
  'service_role has EXECUTE on get_organization_manager_notification_detail'
);
select is(
  has_function_privilege('service_role', 'public.list_organization_manager_notification_projection_cursor_v2(uuid,uuid,timestamptz,uuid,int)', 'EXECUTE'),
  true,
  'service_role has EXECUTE on list_organization_manager_notification_projection_cursor_v2'
);
select is(
  has_function_privilege('anon', 'public.get_organization_manager_notification_detail(uuid,uuid,uuid)', 'EXECUTE'),
  false,
  'anon does NOT have EXECUTE on get_organization_manager_notification_detail'
);
select is(
  has_function_privilege('authenticated', 'public.get_organization_manager_notification_detail(uuid,uuid,uuid)', 'EXECUTE'),
  false,
  'authenticated does NOT have EXECUTE on get_organization_manager_notification_detail'
);
select is(
  has_function_privilege('anon', 'public.list_organization_manager_notification_projection_cursor_v2(uuid,uuid,timestamptz,uuid,int)', 'EXECUTE'),
  false,
  'anon does NOT have EXECUTE on list_organization_manager_notification_projection_cursor_v2'
);
select is(
  has_function_privilege('authenticated', 'public.list_organization_manager_notification_projection_cursor_v2(uuid,uuid,timestamptz,uuid,int)', 'EXECUTE'),
  false,
  'authenticated does NOT have EXECUTE on list_organization_manager_notification_projection_cursor_v2'
);

-- Set up test data for tenant isolation, historical notifications, and 3 categories
do $$
declare
  v_org_a uuid := 'e1000000-0000-4000-8000-000000000001';
  v_org_b uuid := 'e1000000-0000-4000-8000-000000000002';
  v_mgr_a uuid := 'e2000000-0000-4000-8000-000000000001';
  v_mgr_b uuid := 'e2000000-0000-4000-8000-000000000002';
  v_other_a uuid := 'e2000000-0000-4000-8000-000000000003';
  v_branch_a uuid := 'e3000000-0000-4000-8000-000000000001';
  v_branch_b uuid := 'e3000000-0000-4000-8000-000000000002';
  v_issue_id uuid := 'e4000000-0000-4000-8000-000000000001';
  v_legacy_issue_id uuid := 'e4000000-0000-4000-8000-000000000002';
  v_notif_incomplete uuid := 'e5000000-0000-4000-8000-000000000001';
  v_notif_sales uuid := 'e5000000-0000-4000-8000-000000000002';
  v_notif_maint uuid := 'e5000000-0000-4000-8000-000000000003';
  v_notif_legacy uuid := 'e5000000-0000-4000-8000-000000000004';
begin
  -- 1. Insert organizations
  insert into public.organizations (id, name, slug) values
    (v_org_a, 'Org A', 'org-a'),
    (v_org_b, 'Org B', 'org-b')
  on conflict (id) do nothing;

  -- 2. Insert branches
  insert into public.branches (id, organization_id, name, name_ar, code, city, timezone, cold_storage_0200_notification_required) values
    (v_branch_a, v_org_a, 'Alpha Branch', 'فرع ألفا', 'ALF', 'Riyadh', 'Asia/Riyadh', true),
    (v_branch_b, v_org_b, 'Beta Branch', 'فرع بيتا', 'BET', 'Dubai', 'Asia/Dubai', true)
  on conflict (id) do nothing;

  update public.daily_report_branch_lifecycle
    set effective_from_business_date = '2026-11-01'
    where branch_id in (v_branch_a, v_branch_b);

  -- 3. Insert users & managers
  insert into auth.users (id, email) values
    (v_mgr_a, 'mgr_a@example.com'),
    (v_mgr_b, 'mgr_b@example.com'),
    (v_other_a, 'other_a@example.com')
  on conflict (id) do nothing;

  insert into public.organization_memberships (organization_id, user_id, role, active) values
    (v_org_a, v_mgr_a, 'organization_manager', true),
    (v_org_b, v_mgr_b, 'organization_manager', true),
    (v_org_a, v_other_a, 'organization_manager', true)
  on conflict do nothing;

  -- 4. Insert maintenance issues for Org A
  insert into public.maintenance_issues (id, organization_id, branch_id, category, title, priority, status, location, description, reported_by) values
    (v_issue_id, v_org_a, v_branch_a, 'equipment', 'Broken Chiller', 'high', 'in_progress', 'Kitchen Area', 'Compressor fan stopped', v_mgr_a),
    (v_legacy_issue_id, v_org_a, v_branch_a, 'equipment', 'Leaking Sink', 'urgent', 'new', 'Kitchen', 'Pipe leak', v_mgr_a)
  on conflict (id) do nothing;

  -- 5. Insert notification: Incomplete Branch Tasks
  insert into public.organization_manager_notifications (
    id, organization_id, recipient_user_id, event_type, branch_id, business_date, occurrence_key, category_context, created_at
  ) values (
    v_notif_incomplete, v_org_a, v_mgr_a, 'incomplete_branch_tasks', v_branch_a, '2026-11-04', 'incomplete:alpha:2026-11-04',
    jsonb_build_object('schema_version', '1', 'category', 'incomplete_branch_tasks', 'incomplete_modules', jsonb_build_array('kitchen_opening', 'cold_storage'), 'incomplete_count', 2),
    '2026-11-05 04:05:00+03'
  ) on conflict (id) do nothing;

  -- 6. Insert notification: Sales Tracking Missing
  insert into public.organization_manager_notifications (
    id, organization_id, recipient_user_id, event_type, branch_id, business_date, occurrence_key, category_context, created_at
  ) values (
    v_notif_sales, v_org_a, v_mgr_a, 'sales_tracking_missing', v_branch_a, '2026-11-04', 'sales:alpha:2026-11-04',
    jsonb_build_object('schema_version', '1', 'category', 'sales_tracking_missing', 'evidence', 'missing'),
    '2026-11-05 04:05:00+03'
  ) on conflict (id) do nothing;

  -- 7. Insert notification: Maintenance Issue (rollup)
  insert into public.organization_manager_notifications (
    id, organization_id, recipient_user_id, event_type, branch_id, business_date, occurrence_key, category_context, created_at
  ) values (
    v_notif_maint, v_org_a, v_mgr_a, 'maintenance_issue', v_branch_a, '2026-11-04', 'maint:alpha:2026-11-04',
    jsonb_build_object('schema_version', '1', 'category', 'maintenance_issue', 'issue_ids', jsonb_build_array(v_issue_id::text), 'issue_count', 1),
    '2026-11-05 04:05:00+03'
  ) on conflict (id) do nothing;

  -- 8. Insert notification: Legacy maintenance issue creation
  insert into public.organization_manager_notifications (
    id, organization_id, recipient_user_id, event_type, source_type, source_id, occurrence_key, created_at
  ) values (
    v_notif_legacy, v_org_a, v_mgr_a, 'maintenance_issue_created', 'maintenance_issue', v_legacy_issue_id, 'legacy:maint:1',
    '2026-11-05 01:00:00+03'
  ) on conflict (id) do nothing;
end;
$$;

-- 4. Test Tenant Isolation: cross-organization access fails closed
select throws_ok(
  $$ select * from public.list_organization_manager_notification_projection_cursor_v2('e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'Manager B cannot access Org A projection cursor v2'
);
select throws_ok(
  $$ select * from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'Manager B cannot access Org A notification detail'
);
select is_empty(
  $$ select * from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001') $$,
  'Manager from same org cannot read notification addressed to another recipient'
);

-- 5. Test Projection Cursor V2 Execution & Branch Names
select is(
  (select branch_name from public.list_organization_manager_notification_projection_cursor_v2('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', null, null, 10) where id = 'e5000000-0000-4000-8000-000000000001'),
  'Alpha Branch',
  'Projection cursor v2 exposes branch_name as top-level column'
);
select is(
  (select branch_name_ar from public.list_organization_manager_notification_projection_cursor_v2('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', null, null, 10) where id = 'e5000000-0000-4000-8000-000000000001'),
  'فرع ألفا',
  'Projection cursor v2 exposes branch_name_ar as top-level column'
);

-- 6. Category 1 Detail Verification: Incomplete Branch Tasks
select is(
  (select category_context->>'branch_name' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001')),
  'Alpha Branch',
  'Incomplete tasks detail contains authoritative branch name'
);
select is(
  (select jsonb_array_length(category_context->'modules_detail') from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001')),
  2,
  'Incomplete tasks detail contains modules_detail array with 2 modules'
);
select is(
  (select category_context->'modules_detail'->0->>'module_name' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001')),
  'Kitchen Opening',
  'Incomplete tasks detail contains English module name'
);
select is(
  (select category_context->'modules_detail'->0->>'module_name_ar' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001')),
  'افتتاح المطبخ',
  'Incomplete tasks detail contains Arabic module name'
);

-- 7. Category 2 Detail Verification: Sales Tracking Missing
select is(
  (select category_context->>'status' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000002')),
  'missing',
  'Sales tracking detail sets status to missing'
);
select is(
  (select category_context->>'evidence' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000002')),
  'missing',
  'Sales tracking detail sets evidence to missing'
);

-- 8. Category 3 Detail Verification: Maintenance Issues
select is(
  (select category_context->>'issue_title' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000003')),
  'Broken Chiller',
  'Maintenance issue detail extracts issue title'
);
select is(
  (select category_context->>'priority' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000003')),
  'high',
  'Maintenance issue detail extracts priority'
);
select is(
  (select category_context->>'issue_status' from public.get_organization_manager_notification_detail('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000003')),
  'in_progress',
  'Maintenance issue detail extracts status'
);

-- 9. Historical Notification Compatibility: Legacy maintenance creation notification
select is(
  (select branch_name from public.list_organization_manager_notification_projection_cursor_v2('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', null, null, 10) where id = 'e5000000-0000-4000-8000-000000000004'),
  'Alpha Branch',
  'Legacy maintenance creation notification projects branch_name cleanly in cursor v2'
);
select is(
  (select category_context->>'issue_title' from public.list_organization_manager_notification_projection_cursor_v2('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', null, null, 10) where id = 'e5000000-0000-4000-8000-000000000004'),
  'Leaking Sink',
  'Legacy maintenance creation notification is enriched with issue details in cursor v2'
);

select finish();

rollback;
