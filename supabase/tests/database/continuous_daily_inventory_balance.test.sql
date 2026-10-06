begin;
select no_plan();

insert into public.organizations(id, name, slug)
values ('d1000000-0000-4000-8000-000000000001', 'Continuous Inventory Org', 'continuous-inventory-org');

insert into public.branches(id, organization_id, name, code, timezone)
values ('d2000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Continuous Branch', 'CIB', 'Asia/Riyadh');

insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', 'd3000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'continuous-inventory@test.invalid', '{}', '{}', now(), now());

update public.profiles set full_name = 'Continuous Inventory Supervisor', must_change_password = false
where id = 'd3000000-0000-4000-8000-000000000001';

insert into public.branch_inventory_catalog_items(id, organization_id, branch_id, name, unit, kind, is_active)
values ('d4000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', 'Ingredient A', 'pcs', 'ingredient', true);

insert into public.branch_product_catalog_products(id, organization_id, branch_id, name, inventory_behavior, unit, standalone_inventory_item_id, is_active)
values ('d5000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', 'Product A', 'recipe', null, null, true);

-- Day 1 establishes the only initial baseline. Actual Closing is deliberately NULL.
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values ('d6000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-01', 1, 'd3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-000000000001');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values ('d7000000-0000-4000-8000-000000000001', 'd6000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-01', 'd4000000-0000-4000-8000-000000000001', 'Ingredient A', 'pcs', 100, 0, 0, 0, null);

-- Product Sales usage exists on three consecutive dates; days 2 and 3 have no
-- Daily Inventory row at all.
insert into public.branch_product_sales_daily_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values
  ('d8000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-01', 1, 'd3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-000000000001'),
  ('d8000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-02', 1, 'd3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-000000000001'),
  ('d8000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-03', 1, 'd3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-000000000001');

insert into public.branch_product_sales(id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, product_unit_snapshot, quantity)
values
  ('d8100000-0000-4000-8000-000000000001', 'd8000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-01', 'd5000000-0000-4000-8000-000000000001', 'Product A', 'recipe', null, 5),
  ('d8100000-0000-4000-8000-000000000002', 'd8000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-02', 'd5000000-0000-4000-8000-000000000001', 'Product A', 'recipe', null, 6),
  ('d8100000-0000-4000-8000-000000000003', 'd8000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-03', 'd5000000-0000-4000-8000-000000000001', 'Product A', 'recipe', null, 4);

insert into public.branch_product_sales_usage_snapshots(id, product_sale_id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity_per_sale_snapshot, sales_quantity_snapshot, total_usage_quantity)
values
  ('d8200000-0000-4000-8000-000000000001', 'd8100000-0000-4000-8000-000000000001', 'd8000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-01', 'd5000000-0000-4000-8000-000000000001', 'Product A', 'recipe', 'd4000000-0000-4000-8000-000000000001', 'Ingredient A', 'pcs', 1, 5, 5),
  ('d8200000-0000-4000-8000-000000000002', 'd8100000-0000-4000-8000-000000000002', 'd8000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-02', 'd5000000-0000-4000-8000-000000000001', 'Product A', 'recipe', 'd4000000-0000-4000-8000-000000000001', 'Ingredient A', 'pcs', 1, 6, 6),
  ('d8200000-0000-4000-8000-000000000003', 'd8100000-0000-4000-8000-000000000003', 'd8000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-03', 'd5000000-0000-4000-8000-000000000001', 'Product A', 'recipe', 'd4000000-0000-4000-8000-000000000001', 'Ingredient A', 'pcs', 1, 4, 4);

-- Day 4 is the first later physical count and becomes an absolute checkpoint.
insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values ('d6000000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-04', 1, 'd3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-000000000001');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values ('d7000000-0000-4000-8000-000000000004', 'd6000000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', '2026-09-04', 'd4000000-0000-4000-8000-000000000001', 'Ingredient A', 'pcs', null, 0, 0, 0, 80);

select is((select calculated_closing_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-09-04') where business_date='2026-09-01'), 95::numeric, 'NULL Actual Closing does not skip Product Sales');
select is((select opening_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-09-04') where business_date='2026-09-03'), 89::numeric, 'gap day opening accumulates prior Product Sales without inventory rows');
select is((select opening_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-09-04') where business_date='2026-09-04'), 85::numeric, 'Day 4 opening includes all three Product Sales dates');
select is((select variance_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-09-04') where business_date='2026-09-04'), -5::numeric, 'physical checkpoint variance compares actual with accumulated expected balance');
select is((select opening_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-10-05') where business_date='2026-10-01'), 80::numeric, 'month boundary does not reset continuous balance');
select is((select opening_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-10-05') where business_date='2026-10-05'), 80::numeric, '30-day no-count gap carries the checkpoint balance');

update public.branch_product_sales_usage_snapshots set total_usage_quantity = 7, sales_quantity_snapshot = 7
where id = 'd8200000-0000-4000-8000-000000000002';
select is((select calculated_closing_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-09-05') where business_date='2026-09-04'), 84::numeric, 'backdated sales before checkpoint recalculates pre-checkpoint expected closing');
select is((select opening_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-09-05') where business_date='2026-09-05'), 80::numeric, 'backdated movement does not propagate past later physical checkpoint');

update public.branch_daily_inventory_entries set actual_closing_quantity = 0
where id = 'd7000000-0000-4000-8000-000000000004';
select is((select opening_quantity from private.branch_daily_inventory_balance_rows('d1000000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','2026-09-05') where business_date='2026-09-05'), 0::numeric, 'physical zero remains a real checkpoint distinct from NULL');

select * from finish();
rollback;
