begin;
select no_plan();

-- Setup isolated test actors
insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@mgr-track-overview.invalid', '{}', '{}', now(), now()
from unnest(array[
  'f1000000-0000-4000-8000-000000000001'::uuid, -- Manager Org A
  'f1000000-0000-4000-8000-000000000002'::uuid, -- Supervisor Branch A1
  'f1000000-0000-4000-8000-000000000003'::uuid, -- Manager Org B
  'f1000000-0000-4000-8000-000000000004'::uuid  -- Supervisor Org B
]) id;

update public.profiles
set full_name = case id
    when 'f1000000-0000-4000-8000-000000000001' then 'Manager Org A'
    when 'f1000000-0000-4000-8000-000000000002' then 'Supervisor Branch A1'
    when 'f1000000-0000-4000-8000-000000000003' then 'Manager Org B'
    else 'Supervisor Org B'
  end,
  must_change_password = false
where id in (
  'f1000000-0000-4000-8000-000000000001',
  'f1000000-0000-4000-8000-000000000002',
  'f1000000-0000-4000-8000-000000000003',
  'f1000000-0000-4000-8000-000000000004'
);

-- Organizations
insert into public.organizations(id, name, slug)
values
  ('f2000000-0000-4000-8000-000000000001', 'Overview Test Org A', 'ov-test-org-a'),
  ('f2000000-0000-4000-8000-000000000002', 'Overview Test Org B', 'ov-test-org-b');

-- Branches for Org A:
-- Branch 1: Clear (has submission, 1 entry, closing entered, 0 variance)
-- Branch 2: Needs Attention via Variance (has submission, 1 entry, non-zero variance)
-- Branch 3: Needs Attention via Missing Closing (has submission, 1 entry, closing NULL)
-- Branch 4: Needs Attention via Zero Entries (has submission root report, but 0 entries)
-- Branch 5: No Submission (no root report)
-- Branch 6: Inactive branch in Org A (must NOT appear!)
-- Branch B1: Org B branch (must NOT appear!)
insert into public.branches(id, organization_id, name, code, active, timezone)
values
  ('f3000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'Branch 1 Clear', 'B1C', true, 'Asia/Riyadh'),
  ('f3000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', 'Branch 2 Variance', 'B2V', true, 'Asia/Riyadh'),
  ('f3000000-0000-4000-8000-000000000003', 'f2000000-0000-4000-8000-000000000001', 'Branch 3 Missing Closing', 'B3M', true, 'Asia/Riyadh'),
  ('f3000000-0000-4000-8000-000000000004', 'f2000000-0000-4000-8000-000000000001', 'Branch 4 Zero Entries', 'B4Z', true, 'Asia/Riyadh'),
  ('f3000000-0000-4000-8000-000000000005', 'f2000000-0000-4000-8000-000000000001', 'Branch 5 No Submission', 'B5N', true, 'Asia/Riyadh'),
  ('f3000000-0000-4000-8000-000000000006', 'f2000000-0000-4000-8000-000000000001', 'Branch 6 Inactive', 'B6I', false, 'Asia/Riyadh'),
  ('f3000000-0000-4000-8000-000000000007', 'f2000000-0000-4000-8000-000000000002', 'Branch B1', 'BB1', true, 'Asia/Riyadh');

-- Memberships
insert into public.organization_memberships(organization_id, user_id, role)
values
  ('f2000000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', 'organization_manager'),
  ('f2000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000003', 'organization_manager');

insert into public.branch_memberships(branch_id, user_id, role)
values
  ('f3000000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000002', 'branch_manager'),
  ('f3000000-0000-4000-8000-000000000007', 'f1000000-0000-4000-8000-000000000004', 'branch_manager');

-- Catalog Items
insert into public.branch_inventory_catalog_items(id, organization_id, branch_id, name, unit, kind, is_active)
values
  ('f4000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', 'Item Alpha', 'kg', 'ingredient', true),
  ('f4000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000002', 'Item Beta', 'kg', 'ingredient', true),
  ('f4000000-0000-4000-8000-000000000003', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000003', 'Item Gamma', 'kg', 'ingredient', true);

-- Target business date: 2026-09-02 (Day 2)

-- Day 1 closing for Branch 1 and Branch 2 to test non-day-1 previous closing opening quantity:
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('f6000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-01', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002'),
  ('f6000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000002', '2026-09-01', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values
  ('fa000000-0000-4000-8000-000000000001', 'f6000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-01', 'f4000000-0000-4000-8000-000000000001', 'Item Alpha', 'kg', 50, 0, 0, 0, 50),
  ('fa000000-0000-4000-8000-000000000002', 'f6000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000002', '2026-09-01', 'f4000000-0000-4000-8000-000000000002', 'Item Beta', 'kg', 50, 0, 0, 0, 50);

-- Day 2 Reports (2026-09-02):
-- Branch 1: report exists, entry with opening=50, receiving=10, usage=5, waste=2 => expected = 50 + 10 - 5 - 2 = 53. Actual = 53 => variance = 0 (CLEAR)
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('f6000000-0000-4000-8000-000000000011', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-02', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values
  ('fa000000-0000-4000-8000-000000000011', 'f6000000-0000-4000-8000-000000000011', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-02', 'f4000000-0000-4000-8000-000000000001', 'Item Alpha', 'kg', null, 10, 0, 0, 53);

-- Catalog Products
insert into public.branch_product_catalog_products(id, organization_id, branch_id, name, inventory_behavior, unit, standalone_inventory_item_id, is_active)
values
  ('f5000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', 'Product Alpha', 'recipe', null, null, true);

-- Add sales usage snapshot for Branch 1 Day 2 (usage = 5)
insert into public.branch_product_sales_daily_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('f7000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-02', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_product_sales(id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, product_unit_snapshot, quantity)
values
  ('f7000000-0000-4000-8000-000000000002', 'f7000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-02', 'f5000000-0000-4000-8000-000000000001', 'Product Alpha', 'recipe', null, 5);

insert into public.branch_product_sales_usage_snapshots(id, product_sale_id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity_per_sale_snapshot, sales_quantity_snapshot, total_usage_quantity)
values
  ('f7000000-0000-4000-8000-000000000003', 'f7000000-0000-4000-8000-000000000002', 'f7000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-02', 'f5000000-0000-4000-8000-000000000001', 'Product Alpha', 'recipe', 'f4000000-0000-4000-8000-000000000001', 'Item Alpha', 'kg', 1, 5, 5);

-- Add waste entry for Branch 1 Day 2 (waste = 2)
insert into public.branch_daily_waste_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('f8000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-02', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_waste_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity, note)
values
  ('f8000000-0000-4000-8000-000000000002', 'f8000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001', '2026-09-02', 'f4000000-0000-4000-8000-000000000001', 'Item Alpha', 'kg', 2, 'Spoiled');

-- Branch 2: report exists, entry opening=50, receiving=10, usage=0, waste=0 => expected=60. Actual=58 => variance = -2 (NEEDS_ATTENTION via variance)
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('f6000000-0000-4000-8000-000000000012', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000002', '2026-09-02', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values
  ('fa000000-0000-4000-8000-000000000012', 'f6000000-0000-4000-8000-000000000012', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000002', '2026-09-02', 'f4000000-0000-4000-8000-000000000002', 'Item Beta', 'kg', null, 10, 0, 0, 58);

-- Branch 3: report exists, entry with actual_closing_quantity IS NULL => (NEEDS_ATTENTION via missing closing)
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('f6000000-0000-4000-8000-000000000013', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000003', '2026-09-02', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values
  ('fa000000-0000-4000-8000-000000000013', 'f6000000-0000-4000-8000-000000000013', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000003', '2026-09-02', 'f4000000-0000-4000-8000-000000000003', 'Item Gamma', 'kg', null, 0, 0, 0, null);

-- Branch 4: report exists, but 0 entries! => (NEEDS_ATTENTION via total_entries = 0)
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('f6000000-0000-4000-8000-000000000014', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000004', '2026-09-02', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

-- Branch 5: No report at all => (NO_SUBMISSION)

-- Day 1 test data for Branch 1 to verify Day 1 manual opening usage:
-- On 2026-09-01, entry manual_opening_quantity = 50, receiving = 0, closing = 50 => expected = 50, variance = 0.
-- This was already inserted above.

-- =============================================================================
-- 1. Security Hardening & Permissions
-- =============================================================================
select ok(
  has_function_privilege('service_role', 'public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)', 'execute'),
  '1. branch overview function callable by service_role'
);

select ok(
  (select prosecdef from pg_catalog.pg_proc where oid = 'public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)'::regprocedure),
  '1. branch overview RPC is SECURITY DEFINER'
);

select ok(
  pg_catalog.pg_get_functiondef('public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)'::regprocedure) like '%SET search_path TO ''''%',
  '1. branch overview RPC sets search_path = '''''
);

select ok(
  not has_function_privilege('anon', 'public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)', 'execute'),
  '1. branch overview RPC revoked from anon'
);

select ok(
  not has_function_privilege('authenticated', 'public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)', 'execute'),
  '1. branch overview RPC revoked from authenticated'
);

select ok(
  pg_catalog.pg_get_functiondef('public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)'::regprocedure) like '%private.actor_manages_active_organization(actor_user_id, target_organization_id)%',
  '1. branch overview RPC reuses canonical private.actor_manages_active_organization guard'
);

select ok(
  pg_catalog.pg_get_functiondef('public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)'::regprocedure) not like '%organization_memberships%',
  '1. branch overview RPC does not query organization_memberships directly'
);

select is(
  (select proargnames from pg_catalog.pg_proc where oid = 'public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text)'::regprocedure),
  '{"actor_user_id","target_organization_id","target_business_date","target_branch_id","attention_filter"}'::text[],
  '1. canonical parameter names match exact persistence RPC payload'
);

-- =============================================================================
-- 2. Authorization & Input Validation
-- =============================================================================
select ok(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02') is not null),
  '2. manager in same active organization succeeds'
);

select ok(
  (public.list_managed_daily_inventory_branch_overview(
    actor_user_id => 'f1000000-0000-4000-8000-000000000001'::uuid,
    target_organization_id => 'f2000000-0000-4000-8000-000000000001'::uuid,
    target_business_date => '2026-09-02'::date,
    target_branch_id => null::uuid,
    attention_filter => null::text
  ) is not null),
  '2. branch overview callable using exact named arguments'
);

select throws_ok(
  $$ select public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', '2026-09-02') $$,
  '42501',
  'daily inventory branch overview access denied',
  '2. non-manager rejected'
);

select throws_ok(
  $$ select public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000002', '2026-09-02') $$,
  '42501',
  'daily inventory branch overview access denied',
  '2. manager from another organization rejected'
);

-- Prove lifecycle dependency on private.actor_manages_active_organization:
-- Inactive organization must be rejected by the guard
update public.organizations set active = false where id = 'f2000000-0000-4000-8000-000000000001';

select throws_ok(
  $$ select public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02') $$,
  '42501',
  'daily inventory branch overview access denied',
  '2. inactive organization rejected by actor_manages_active_organization'
);

update public.organizations set active = true where id = 'f2000000-0000-4000-8000-000000000001';

select throws_ok(
  $$ select public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', 'f3000000-0000-4000-8000-000000000006') $$,
  '42501',
  'daily inventory branch overview access denied',
  '2. inactive target branch rejected'
);

select throws_ok(
  $$ select public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', 'f3000000-0000-4000-8000-000000000007') $$,
  '42501',
  'daily inventory branch overview access denied',
  '2. target branch from other organization rejected'
);

select throws_ok(
  $$ select public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', null) $$,
  '22004',
  'business date required',
  '2. null business date rejected'
);

select throws_ok(
  $$ select public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', null, 'invalid_filter') $$,
  '22023',
  'invalid attention filter',
  '2. invalid attention filter rejected'
);

-- =============================================================================
-- 3. Semantics & Aggregations Verification
-- =============================================================================

-- Full overview on 2026-09-02 without attention filter
-- Authorized active branches in Org A: Branch 1, Branch 2, Branch 3, Branch 4, Branch 5 (Total 5 branches. Branch 6 is inactive, Branch 7 is Org B).
select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->>'total_branches')::integer,
  5,
  '3. total_branches is 5 (excludes inactive Branch 6 and cross-org Branch 7)'
);

select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->>'clear_count')::integer,
  1,
  '3. clear_count is 1 (Branch 1)'
);

select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->>'needs_attention_count')::integer,
  3,
  '3. needs_attention_count is 3 (Branch 2 variance, Branch 3 missing closing, Branch 4 zero entries)'
);

select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->>'no_submission_count')::integer,
  1,
  '3. no_submission_count is 1 (Branch 5)'
);

-- Branch 1 Clear Details
select is(
  (select row->>'has_submission'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  'true',
  '3. Branch 1 has_submission is true'
);
select is(
  (select row->>'total_entries_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  '1',
  '3. Branch 1 total_entries_count is 1'
);
select is(
  (select row->>'items_checked_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  '1',
  '3. Branch 1 items_checked_count is 1'
);
select is(
  (select row->>'missing_closing_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  '0',
  '3. Branch 1 missing_closing_count is 0'
);
select is(
  (select row->>'variance_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  '0',
  '3. Branch 1 variance_items_count is 0 (expected closing 53, actual 53)'
);
select is(
  (select row->>'unreconciled_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  '0',
  '3. Branch 1 unreconciled_items_count is 0'
);
select is(
  (select row->>'attention_status'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  'clear',
  '3. Branch 1 attention_status is clear'
);

-- Branch 2 Variance Details
select is(
  (select row->>'variance_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000002'),
  '1',
  '3. Branch 2 variance_items_count is 1 (expected 60, actual 58, variance = -2 <> 0)'
);
select is(
  (select row->>'unreconciled_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000002'),
  '0',
  '3. Branch 2 unreconciled_items_count is 0'
);
select is(
  (select row->>'attention_status'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000002'),
  'needs_attention',
  '3. Branch 2 attention_status is needs_attention'
);

-- Branch 3 Missing Closing Details
select is(
  (select row->>'items_checked_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000003'),
  '0',
  '3. Branch 3 items_checked_count is 0'
);
select is(
  (select row->>'missing_closing_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000003'),
  '1',
  '3. Branch 3 missing_closing_count is 1'
);
select is(
  (select row->>'variance_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000003'),
  '0',
  '3. Branch 3 NULL variance does not increment variance_items_count'
);
select is(
  (select row->>'unreconciled_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000003'),
  '1',
  '3. Branch 3 missing previous closing produces unreconciled_items_count = 1'
);
select is(
  (select row->>'attention_status'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000003'),
  'needs_attention',
  '3. Branch 3 attention_status is needs_attention'
);

-- Branch 4 Zero Entries Details
select is(
  (select row->>'has_submission'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000004'),
  'true',
  '3. Branch 4 has_submission is true'
);
select is(
  (select row->>'total_entries_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000004'),
  '0',
  '3. Branch 4 total_entries_count is 0'
);
select is(
  (select row->>'attention_status'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000004'),
  'needs_attention',
  '3. Branch 4 root report with zero entries is needs_attention'
);

-- Branch 5 No Submission Details
select is(
  (select row->>'has_submission'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000005'),
  'false',
  '3. Branch 5 has_submission is false'
);
select is(
  (select row->>'attention_status'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000005'),
  'no_submission',
  '3. Branch 5 attention_status is no_submission'
);

-- Day 1 Opening Semantics on 2026-09-01
select is(
  (select row->>'variance_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-01')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  '0',
  '3. Day 1 uses manual_opening_quantity (50) producing 0 variance'
);
select is(
  (select row->>'unreconciled_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-01')->'rows') row
   where row->>'branch_id' = 'f3000000-0000-4000-8000-000000000001'),
  '0',
  '3. Day 1 with manual_opening produces unreconciled_items_count = 0'
);

-- =============================================================================
-- 3b. Critical Unreconciled Edge Cases (A, B, C, D)
-- =============================================================================

-- Setup dedicated branch for edge cases: Branch Unreconciled
insert into public.branches(id, organization_id, name, code, active, timezone)
values ('f3000000-0000-4000-8000-000000000009', 'f2000000-0000-4000-8000-000000000001', 'Branch Unreconciled Test', 'BUT', true, 'Asia/Riyadh');

insert into public.branch_inventory_catalog_items(id, organization_id, branch_id, name, unit, kind, is_active)
values ('f4000000-0000-4000-8000-000000000009', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000009', 'Item BUT', 'kg', 'ingredient', true);

-- A & D: Day > 1 (2026-09-03) with actual closing entered (25), but previous day's closing is missing!
-- Result: opening is NULL, expected closing is NULL, variance is NULL, unreconciled increments, variance_items_count does NOT increment, status is needs_attention (NOT clear)
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values ('f6000000-0000-4000-8000-000000000021', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000009', '2026-09-03', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values ('fa000000-0000-4000-8000-000000000021', 'f6000000-0000-4000-8000-000000000021', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000009', '2026-09-03', 'f4000000-0000-4000-8000-000000000009', 'Item BUT', 'kg', null, 0, 0, 0, 25);

select is(
  (select row->>'unreconciled_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-03', 'f3000000-0000-4000-8000-000000000009')->'rows') row),
  '1',
  '3b. Case A: Day > 1 missing previous closing increments unreconciled_items_count to 1'
);

select is(
  (select row->>'missing_closing_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-03', 'f3000000-0000-4000-8000-000000000009')->'rows') row),
  '0',
  '3b. Case A: actual closing entered means missing_closing_count is 0'
);

select is(
  (select row->>'variance_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-03', 'f3000000-0000-4000-8000-000000000009')->'rows') row),
  '0',
  '3b. Case D: NULL expected closing must NOT increment variance_items_count'
);

select is(
  (select row->>'attention_status'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-03', 'f3000000-0000-4000-8000-000000000009')->'rows') row),
  'needs_attention',
  '3b. Case A: branch with unreconciled entry is needs_attention (NEVER clear)'
);

-- Case B: Day 1 (2026-09-01) with manual_opening_quantity NULL
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values ('f6000000-0000-4000-8000-000000000022', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000009', '2026-09-01', 1, 'f1000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values ('fa000000-0000-4000-8000-000000000022', 'f6000000-0000-4000-8000-000000000022', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000009', '2026-09-01', 'f4000000-0000-4000-8000-000000000009', 'Item BUT', 'kg', null, 0, 0, 0, 10);

select is(
  (select row->>'unreconciled_items_count'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-01', 'f3000000-0000-4000-8000-000000000009')->'rows') row),
  '1',
  '3b. Case B: Day 1 manual_opening_quantity NULL increments unreconciled_items_count'
);

select is(
  (select row->>'attention_status'
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-01', 'f3000000-0000-4000-8000-000000000009')->'rows') row),
  'needs_attention',
  '3b. Case B: Day 1 manual_opening_quantity NULL branch is needs_attention'
);

-- Clean up test branch 9 to restore 5 authorized branches on 2026-09-02
delete from public.branch_daily_inventory_entries where branch_id = 'f3000000-0000-4000-8000-000000000009';
delete from public.branch_daily_inventory_reports where branch_id = 'f3000000-0000-4000-8000-000000000009';
delete from public.branch_inventory_catalog_items where branch_id = 'f3000000-0000-4000-8000-000000000009';
delete from public.branches where id = 'f3000000-0000-4000-8000-000000000009';

-- =============================================================================
-- 4. Attention Filter & Summary Counter Invariance
-- =============================================================================

-- Filter: 'needs_attention'
select is(
  jsonb_array_length(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', null, 'needs_attention')->'rows'),
  3,
  '4. needs_attention filter returns exactly 3 rows'
);

select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', null, 'needs_attention')->>'total_branches')::integer,
  5,
  '4. summary counter total_branches unaffected by needs_attention filter'
);

select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', null, 'needs_attention')->>'needs_attention_count')::integer,
  3,
  '4. summary counter needs_attention_count unaffected by needs_attention filter'
);

-- Filter: 'no_submission'
select is(
  jsonb_array_length(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', null, 'no_submission')->'rows'),
  1,
  '4. no_submission filter returns exactly 1 row'
);

select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', null, 'no_submission')->>'total_branches')::integer,
  5,
  '4. summary counter total_branches unaffected by no_submission filter'
);

-- =============================================================================
-- 5. Branch Filter & Deterministic Ordering
-- =============================================================================
select is(
  jsonb_array_length(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', 'f3000000-0000-4000-8000-000000000001')->'rows'),
  1,
  '5. branch filter returns only specified branch'
);

select is(
  (public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02', 'f3000000-0000-4000-8000-000000000001')->>'total_branches')::integer,
  1,
  '5. summary counter total_branches scoped to branch filter'
);

-- Deterministic ordering check: Branch 1, Branch 2, Branch 3, Branch 4, Branch 5
select is(
  (select string_agg(elem->>'branch_name', ', ' order by ord)
   from jsonb_array_elements(public.list_managed_daily_inventory_branch_overview('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-09-02')->'rows') with ordinality as t(elem, ord)),
  'Branch 1 Clear, Branch 2 Variance, Branch 3 Missing Closing, Branch 4 Zero Entries, Branch 5 No Submission',
  '5. deterministic alphabetical ordering by branch_name'
);

select * from finish();
rollback;
