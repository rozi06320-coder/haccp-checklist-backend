begin;
select no_plan();

-- Setup isolated test actors
insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@mgr-track.invalid', '{}', '{}', now(), now()
from unnest(array[
  'e1000000-0000-4000-8000-000000000001'::uuid, -- Manager Org A
  'e1000000-0000-4000-8000-000000000002'::uuid, -- Supervisor Branch A
  'e1000000-0000-4000-8000-000000000003'::uuid, -- Manager Org B
  'e1000000-0000-4000-8000-000000000004'::uuid  -- Supervisor Branch B
]) id;

update public.profiles
set full_name = case id
    when 'e1000000-0000-4000-8000-000000000001' then 'Manager Org A'
    when 'e1000000-0000-4000-8000-000000000002' then 'Supervisor Branch A'
    when 'e1000000-0000-4000-8000-000000000003' then 'Manager Org B'
    else 'Supervisor Branch B'
  end,
  must_change_password = false
where id in (
  'e1000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000002',
  'e1000000-0000-4000-8000-000000000003',
  'e1000000-0000-4000-8000-000000000004'
);

-- Organizations
insert into public.organizations(id, name, slug)
values
  ('e2000000-0000-4000-8000-000000000001', 'Manager Tracking Org A', 'mgr-track-org-a'),
  ('e2000000-0000-4000-8000-000000000002', 'Manager Tracking Org B', 'mgr-track-org-b');

-- Branches
insert into public.branches(id, organization_id, name, code, timezone)
values
  ('e3000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'Branch Alpha', 'BA1', 'Asia/Riyadh'),
  ('e3000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000002', 'Branch Beta', 'BB1', 'Asia/Riyadh');

-- Memberships
insert into public.organization_memberships(organization_id, user_id, role)
values
  ('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'organization_manager'),
  ('e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000003', 'organization_manager');

insert into public.branch_memberships(branch_id, user_id, role)
values
  ('e3000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000002', 'branch_manager'),
  ('e3000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000004', 'branch_manager');

insert into public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id)
values
  ('e9000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000002'),
  ('e9000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000002', 'e3000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000004');

-- Catalog Items
insert into public.branch_inventory_catalog_items(id, organization_id, branch_id, name, unit, kind, is_active)
values
  ('e4000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'Artisan Brioche Bun', 'pcs', 'ingredient', true),
  ('e4000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'Beef Patty', 'pcs', 'ingredient', true),
  ('e4000000-0000-4000-8000-000000000003', 'e2000000-0000-4000-8000-000000000002', 'e3000000-0000-4000-8000-000000000002', 'Other Bun', 'pcs', 'ingredient', true);

-- Catalog Products
insert into public.branch_product_catalog_products(id, organization_id, branch_id, name, inventory_behavior, unit, standalone_inventory_item_id, is_active)
values
  ('e5000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'Classic Cheeseburger', 'recipe', null, null, true);

-- 1. Inventory Reports: Day 1 (2026-09-01) with manual opening
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('e6000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-01', 1, 'e1000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values
  ('ea000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-01', 'e4000000-0000-4000-8000-000000000001', 'Artisan Brioche Bun', 'pcs', 100, 50, 10, 5, 155);

-- 2. Inventory Reports: Day 2 (2026-09-02)
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('e6000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 1, 'e1000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values
  ('ea000000-0000-4000-8000-000000000002', 'e6000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 'e4000000-0000-4000-8000-000000000001', 'Artisan Brioche Bun', 'pcs', null, 20, 0, 0, 158),
  ('ea000000-0000-4000-8000-000000000003', 'e6000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 'e4000000-0000-4000-8000-000000000002', 'Beef Patty', 'pcs', null, 10, 0, 0, 10);

-- 3. Product Sales on 2026-09-02
insert into public.branch_product_sales_daily_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('e7000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 1, 'e1000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000002');

insert into public.branch_product_sales(id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, product_unit_snapshot, quantity)
values
  ('e7000000-0000-4000-8000-000000000002', 'e7000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 'e5000000-0000-4000-8000-000000000001', 'Classic Cheeseburger', 'recipe', null, 10);

insert into public.branch_product_sales_usage_snapshots(id, product_sale_id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity_per_sale_snapshot, sales_quantity_snapshot, total_usage_quantity)
values
  ('e7000000-0000-4000-8000-000000000003', 'e7000000-0000-4000-8000-000000000002', 'e7000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 'e5000000-0000-4000-8000-000000000001', 'Burger (Snapshot)', 'recipe', 'e4000000-0000-4000-8000-000000000001', 'Artisan Brioche Bun (Usage Snapshot)', 'pcs', 1.5, 10, 15);

-- 4. Daily Waste on 2026-09-02
insert into public.branch_daily_waste_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('e8000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 1, 'e1000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000002');

insert into public.branch_daily_waste_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity, note)
values
  ('e8000000-0000-4000-8000-000000000002', 'e8000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', '2026-09-02', 'e4000000-0000-4000-8000-000000000001', 'Artisan Brioche Bun (Waste Snapshot)', 'pcs', 2, 'Burnt in toaster');


-- =============================================================================
-- A. Function Existence & Signatures
-- =============================================================================
select ok(
  has_function_privilege('service_role', 'public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute'),
  'A. reconciliation function exists with exact signature and callable by service_role'
);
select ok(
  has_function_privilege('service_role', 'public.list_managed_product_sales_usage(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute'),
  'A. sales usage function exists with exact signature and callable by service_role'
);
select ok(
  has_function_privilege('service_role', 'public.list_managed_daily_waste(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute'),
  'A. daily waste function exists with exact signature and callable by service_role'
);

-- =============================================================================
-- B. SECURITY DEFINER Verification
-- =============================================================================
select ok(
  (select prosecdef from pg_catalog.pg_proc where oid = 'public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer)'::regprocedure),
  'B. reconciliation RPC is SECURITY DEFINER'
);
select ok(
  (select prosecdef from pg_catalog.pg_proc where oid = 'public.list_managed_product_sales_usage(uuid,uuid,date,date,uuid,uuid,integer,integer)'::regprocedure),
  'B. usage RPC is SECURITY DEFINER'
);
select ok(
  (select prosecdef from pg_catalog.pg_proc where oid = 'public.list_managed_daily_waste(uuid,uuid,date,date,uuid,uuid,integer,integer)'::regprocedure),
  'B. waste RPC is SECURITY DEFINER'
);

-- =============================================================================
-- C. Hardened Empty search_path Verification
-- =============================================================================
select ok(
  pg_catalog.pg_get_functiondef('public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer)'::regprocedure) like '%SET search_path TO ''''%',
  'C. reconciliation RPC sets search_path = '''''
);
select ok(
  pg_catalog.pg_get_functiondef('public.list_managed_product_sales_usage(uuid,uuid,date,date,uuid,uuid,integer,integer)'::regprocedure) like '%SET search_path TO ''''%',
  'C. usage RPC sets search_path = '''''
);
select ok(
  pg_catalog.pg_get_functiondef('public.list_managed_daily_waste(uuid,uuid,date,date,uuid,uuid,integer,integer)'::regprocedure) like '%SET search_path TO ''''%',
  'C. waste RPC sets search_path = '''''
);

-- =============================================================================
-- D. Execution Grants / Revokes
-- =============================================================================
select ok(
  not has_function_privilege('anon', 'public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute'),
  'D. reconciliation RPC revoked from public/anon/authenticated'
);
select ok(
  not has_function_privilege('anon', 'public.list_managed_product_sales_usage(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.list_managed_product_sales_usage(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute'),
  'D. usage RPC revoked from public/anon/authenticated'
);
select ok(
  not has_function_privilege('anon', 'public.list_managed_daily_waste(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.list_managed_daily_waste(uuid,uuid,date,date,uuid,uuid,integer,integer)', 'execute'),
  'D. waste RPC revoked from public/anon/authenticated'
);

-- =============================================================================
-- E. Manager Org A Can Read Org A
-- =============================================================================
select ok(
  jsonb_array_length(public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02')->'rows') = 3,
  'E. manager Org A reads all reconciliation rows in date range'
);
select ok(
  jsonb_array_length(public.list_managed_product_sales_usage('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02')->'rows') = 1,
  'E. manager Org A reads sales usage rows'
);
select ok(
  jsonb_array_length(public.list_managed_daily_waste('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02')->'rows') = 1,
  'E. manager Org A reads daily waste rows'
);

-- =============================================================================
-- F. Manager Org A Cannot Read Org B (42501)
-- =============================================================================
select throws_ok(
  $$select public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', '2026-09-01', '2026-09-02')$$,
  '42501',
  'daily inventory reconciliation report access denied',
  'F. manager A cannot read Org B inventory'
);
select throws_ok(
  $$select public.list_managed_product_sales_usage('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', '2026-09-01', '2026-09-02')$$,
  '42501',
  'managed product sales usage access denied',
  'F. manager A cannot read Org B usage'
);
select throws_ok(
  $$select public.list_managed_daily_waste('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', '2026-09-01', '2026-09-02')$$,
  '42501',
  'managed daily waste access denied',
  'F. manager A cannot read Org B waste'
);

-- =============================================================================
-- G. Branch Filter From Another Org Rejected (42501)
-- =============================================================================
select throws_ok(
  $$select public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02', 'e3000000-0000-4000-8000-000000000002')$$,
  '42501',
  'daily inventory reconciliation report access denied',
  'G. branch filter from other org rejected'
);

-- =============================================================================
-- H. Inventory Item Filter From Another Org Rejected (42501)
-- =============================================================================
select throws_ok(
  $$select public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02', null, 'e4000000-0000-4000-8000-000000000003')$$,
  '42501',
  'daily inventory reconciliation report access denied',
  'H. inventory item filter from other org rejected'
);

-- =============================================================================
-- I. >90 Day Range Rejected (22023)
-- =============================================================================
select throws_ok(
  $$select public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-01-01', '2026-04-05')$$,
  '22023',
  'date range exceeds maximum of 90 days',
  'I. date range exceeding 90 days rejected'
);

-- =============================================================================
-- J. page_size >100 Rejected (22023)
-- =============================================================================
select throws_ok(
  $$select public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02', null, null, 1, 101)$$,
  '22023',
  'invalid pagination parameters',
  'J. page_size > 100 rejected'
);

-- =============================================================================
-- K. page=0 Rejected (22023)
-- =============================================================================
select throws_ok(
  $$select public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02', null, null, 0, 50)$$,
  '22023',
  'invalid pagination parameters',
  'K. page = 0 rejected'
);

-- =============================================================================
-- L. Null Opening -> Null Expected Closing / Variance
-- =============================================================================
select is(
  (select row->>'opening_quantity'
   from jsonb_array_elements(public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000002'),
  null,
  'L. missing previous closing produces null opening quantity'
);
select is(
  (select row->>'expected_closing_quantity'
   from jsonb_array_elements(public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000002'),
  null,
  'L. null opening produces null expected closing'
);
select is(
  (select row->>'variance_quantity'
   from jsonb_array_elements(public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000002'),
  null,
  'L. null expected closing produces null variance'
);

-- Also verify Item A1 on Day 2 has exact closing and variance math:
-- opening (155 from Day 1 actual closing) + receiving (20) - sales_usage (15) - waste (2) = 158 expected closing.
-- actual_closing = 158, variance = 0.
select is(
  (select row->>'expected_closing_quantity'
   from jsonb_array_elements(public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  '158',
  'L. item with opening computes expected closing = 155 + 20 - 15 - 2 = 158'
);
select is(
  (select row->>'variance_quantity'
   from jsonb_array_elements(public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  '0',
  'L. item variance = 158 - 158 = 0'
);

-- =============================================================================
-- M. Historical Usage Reads Frozen quantity_per_sale_snapshot
-- =============================================================================
select is(
  (select row->>'quantity_per_sale_snapshot'
   from jsonb_array_elements(public.list_managed_product_sales_usage('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  '1.5',
  'M. usage returns frozen quantity_per_sale_snapshot (1.5)'
);
select is(
  (select row->>'product_name_snapshot'
   from jsonb_array_elements(public.list_managed_product_sales_usage('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  'Burger (Snapshot)',
  'M. usage returns frozen product_name_snapshot'
);
select is(
  (select row->>'total_usage_quantity'
   from jsonb_array_elements(public.list_managed_product_sales_usage('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  '15',
  'M. usage returns total_usage_quantity (15)'
);

-- =============================================================================
-- N. Historical Waste Uses Snapshot Name / Unit
-- =============================================================================
select is(
  (select row->>'inventory_item_name_snapshot'
   from jsonb_array_elements(public.list_managed_daily_waste('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  'Artisan Brioche Bun (Waste Snapshot)',
  'N. waste returns frozen item name snapshot'
);
select is(
  (select row->>'inventory_item_unit_snapshot'
   from jsonb_array_elements(public.list_managed_daily_waste('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  'pcs',
  'N. waste returns frozen item unit snapshot'
);
select is(
  (select row->>'quantity'
   from jsonb_array_elements(public.list_managed_daily_waste('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  '2',
  'N. waste returns recorded quantity'
);
select is(
  (select row->>'note'
   from jsonb_array_elements(public.list_managed_daily_waste('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-02', '2026-09-02')->'rows') row
   where row->>'inventory_item_id' = 'e4000000-0000-4000-8000-000000000001'),
  'Burnt in toaster',
  'N. waste returns recorded note'
);

-- =============================================================================
-- O. Out-of-Range Page Preserves total_rows and total_pages
-- =============================================================================
select is(
  jsonb_array_length(public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02', null, null, 10, 50)->'rows'),
  0,
  'O. page beyond last returns empty rows array'
);
select is(
  (public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02', null, null, 10, 50)->>'total_rows')::integer,
  3,
  'O. page beyond last preserves accurate total_rows (3)'
);
select is(
  (public.list_managed_daily_inventory_reconciliation('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-09-01', '2026-09-02', null, null, 10, 50)->>'total_pages')::integer,
  1,
  'O. page beyond last preserves accurate total_pages (1)'
);

select * from finish();
rollback;
