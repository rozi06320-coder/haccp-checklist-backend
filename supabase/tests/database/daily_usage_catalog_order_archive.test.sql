begin;
select no_plan();

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@daily-usage-catalog.invalid', '{}', '{}', now(), now()
from unnest(array[
  'c1500000-0000-4000-8000-000000000001'::uuid,
  'c1500000-0000-4000-8000-000000000002'::uuid
]) id;

update public.profiles
set full_name = case id
    when 'c1500000-0000-4000-8000-000000000001' then 'Catalog Supervisor A'
    else 'Catalog Supervisor B'
  end,
  must_change_password = false
where id in ('c1500000-0000-4000-8000-000000000001','c1500000-0000-4000-8000-000000000002');

insert into public.organizations(id,name,slug)
values
  ('c2500000-0000-4000-8000-000000000001','Daily Usage Catalog Org A','daily-usage-catalog-org-a'),
  ('c2500000-0000-4000-8000-000000000002','Daily Usage Catalog Org B','daily-usage-catalog-org-b');

insert into public.branches(id,organization_id,name,code,timezone)
values
  ('c3500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','Daily Usage Catalog Branch A','DUA','Asia/Riyadh'),
  ('c3500000-0000-4000-8000-000000000002','c2500000-0000-4000-8000-000000000002','Daily Usage Catalog Branch B','DUB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role)
values
  ('c3500000-0000-4000-8000-000000000001','c1500000-0000-4000-8000-000000000001','branch_manager'),
  ('c3500000-0000-4000-8000-000000000002','c1500000-0000-4000-8000-000000000002','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values
  ('c7500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','c1500000-0000-4000-8000-000000000001'),
  ('c7500000-0000-4000-8000-000000000002','c2500000-0000-4000-8000-000000000002','c3500000-0000-4000-8000-000000000002','c1500000-0000-4000-8000-000000000002');

insert into public.branch_inventory_catalog_items(id,organization_id,branch_id,name,unit,kind,is_active)
values
  ('c4500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Mapped Active Ingredient','pcs','ingredient',true),
  ('c4500000-0000-4000-8000-000000000002','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Mapped Inactive Product Ingredient','pcs','ingredient',true),
  ('c4500000-0000-4000-8000-000000000003','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Historical Ingredient','pcs','ingredient',true),
  ('c4500000-0000-4000-8000-000000000004','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Other Ingredient','pcs','ingredient',true),
  ('c4500000-0000-4000-8000-000000000005','c2500000-0000-4000-8000-000000000002','c3500000-0000-4000-8000-000000000002','Cross Branch Ingredient','pcs','ingredient',true);

insert into public.branch_product_catalog_products(id,organization_id,branch_id,name,inventory_behavior,unit,standalone_inventory_item_id,is_active,display_order)
values
  ('c5500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Product A','recipe',null,null,true,1),
  ('c5500000-0000-4000-8000-000000000002','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Product B','recipe',null,null,true,2),
  ('c5500000-0000-4000-8000-000000000003','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Product C','recipe',null,null,true,3),
  ('c5500000-0000-4000-8000-000000000004','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','Inactive Product','recipe',null,null,false,null),
  ('c5500000-0000-4000-8000-000000000005','c2500000-0000-4000-8000-000000000002','c3500000-0000-4000-8000-000000000002','Cross Branch Product','recipe',null,null,true,1);

insert into public.branch_product_usage_mappings(id,organization_id,branch_id,product_id,inventory_item_id,quantity)
values
  ('c6500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','c5500000-0000-4000-8000-000000000001','c4500000-0000-4000-8000-000000000001',1),
  ('c6500000-0000-4000-8000-000000000002','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','c5500000-0000-4000-8000-000000000004','c4500000-0000-4000-8000-000000000002',1);

insert into public.branch_product_sales_daily_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values ('c8500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','2026-09-19',1,'c1500000-0000-4000-8000-000000000001','c1500000-0000-4000-8000-000000000001');

insert into public.branch_product_sales(id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, product_unit_snapshot, quantity)
values ('c8500000-0000-4000-8000-000000000002','c8500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','2026-09-19','c5500000-0000-4000-8000-000000000003','Product C','recipe',null,4);

insert into public.branch_product_sales_usage_snapshots(id, product_sale_id, report_id, organization_id, branch_id, business_date, product_id, product_name_snapshot, inventory_behavior_snapshot, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity_per_sale_snapshot, sales_quantity_snapshot, total_usage_quantity)
values ('c8500000-0000-4000-8000-000000000003','c8500000-0000-4000-8000-000000000002','c8500000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','2026-09-19','c5500000-0000-4000-8000-000000000003','Product C Snapshot','recipe','c4500000-0000-4000-8000-000000000003','Historical Ingredient Snapshot','pcs',2,4,8);

insert into public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values ('c8600000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','2026-09-19',1,'c1500000-0000-4000-8000-000000000001','c1500000-0000-4000-8000-000000000001');

insert into public.branch_daily_inventory_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity)
values ('c8600000-0000-4000-8000-000000000002','c8600000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','2026-09-19','c4500000-0000-4000-8000-000000000003','Historical Ingredient Inventory','pcs',null,5,0,0,12);

insert into public.branch_daily_waste_reports(id, organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id)
values ('c8700000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','2026-09-19',1,'c1500000-0000-4000-8000-000000000001','c1500000-0000-4000-8000-000000000001');

insert into public.branch_daily_waste_entries(id, report_id, organization_id, branch_id, business_date, inventory_item_id, inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity, note)
values ('c8700000-0000-4000-8000-000000000002','c8700000-0000-4000-8000-000000000001','c2500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','2026-09-19','c4500000-0000-4000-8000-000000000003','Historical Ingredient Waste','pcs',1,'Historical waste row');

create temporary table daily_usage_catalog_history_before as
select 'usage_snapshot' as source, id, inventory_item_name_snapshot as item_name, total_usage_quantity as qty
from public.branch_product_sales_usage_snapshots
where id = 'c8500000-0000-4000-8000-000000000003'
union all
select 'inventory', id, inventory_item_name_snapshot, actual_closing_quantity
from public.branch_daily_inventory_entries
where id = 'c8600000-0000-4000-8000-000000000002'
union all
select 'waste', id, inventory_item_name_snapshot, quantity
from public.branch_daily_waste_entries
where id = 'c8700000-0000-4000-8000-000000000002';

select throws_ok(
  $$select public.archive_branch_catalog_inventory_item('c1500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','c4500000-0000-4000-8000-000000000001')$$,
  '23505',
  'ingredient is used by active products',
  'active mapped product blocks ingredient archive'
);

select lives_ok(
  $$select public.archive_branch_catalog_inventory_item('c1500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','c4500000-0000-4000-8000-000000000002')$$,
  'inactive product mapping does not block ingredient archive'
);
select is((select is_active from public.branch_inventory_catalog_items where id='c4500000-0000-4000-8000-000000000002'), false, 'inactive-product-only ingredient is archived');

select throws_ok(
  $$select public.save_branch_product_usage_mappings(
    'c1500000-0000-4000-8000-000000000001',
    'c3500000-0000-4000-8000-000000000001',
    'c5500000-0000-4000-8000-000000000002',
    '[{"inventory_item_id":"c4500000-0000-4000-8000-000000000002","quantity":1}]'::jsonb
  )$$,
  '22023',
  'inventory item unavailable',
  'archived ingredient cannot be newly added to active recipe'
);

select lives_ok(
  $$select public.archive_branch_catalog_inventory_item('c1500000-0000-4000-8000-000000000001','c3500000-0000-4000-8000-000000000001','c4500000-0000-4000-8000-000000000003')$$,
  'unmapped historical ingredient archives successfully'
);

select results_eq(
  $$select source, id, item_name, qty from daily_usage_catalog_history_before order by source$$,
  $$select source, id, item_name, qty
    from (
      select 'usage_snapshot' as source, id, inventory_item_name_snapshot as item_name, total_usage_quantity as qty
      from public.branch_product_sales_usage_snapshots
      where id = 'c8500000-0000-4000-8000-000000000003'
      union all
      select 'inventory', id, inventory_item_name_snapshot, actual_closing_quantity
      from public.branch_daily_inventory_entries
      where id = 'c8600000-0000-4000-8000-000000000002'
      union all
      select 'waste', id, inventory_item_name_snapshot, quantity
      from public.branch_daily_waste_entries
      where id = 'c8700000-0000-4000-8000-000000000002'
    ) rows order by source$$,
  'successful archive leaves historical usage, inventory, and waste rows unchanged'
);

select lives_ok(
  $$select public.reorder_branch_catalog_products(
    'c1500000-0000-4000-8000-000000000001',
    'c3500000-0000-4000-8000-000000000001',
    array[
      'c5500000-0000-4000-8000-000000000003'::uuid,
      'c5500000-0000-4000-8000-000000000001'::uuid,
      'c5500000-0000-4000-8000-000000000002'::uuid
    ]
  )$$,
  'A/C/B reorder persists atomically'
);

select results_eq(
  $$select name, display_order from public.branch_product_catalog_products where branch_id='c3500000-0000-4000-8000-000000000001' and is_active order by display_order$$,
  $$values ('Product C'::text, 1), ('Product A'::text, 2), ('Product B'::text, 3)$$,
  'A/C/B becomes display_order 1/2/3'
);

select results_eq(
  $$select display_order from public.branch_product_catalog_products where branch_id='c3500000-0000-4000-8000-000000000001' and is_active order by display_order$$,
  $$values (1), (2), (3)$$,
  'all active products remain dense 1..N'
);

select throws_ok(
  $$select public.reorder_branch_catalog_products(
    'c1500000-0000-4000-8000-000000000001',
    'c3500000-0000-4000-8000-000000000001',
    array['c5500000-0000-4000-8000-000000000001'::uuid,'c5500000-0000-4000-8000-000000000002'::uuid]
  )$$,
  '22023',
  'product order must include every active product',
  'incomplete active Product set rejected'
);

select throws_ok(
  $$select public.reorder_branch_catalog_products(
    'c1500000-0000-4000-8000-000000000001',
    'c3500000-0000-4000-8000-000000000001',
    array['c5500000-0000-4000-8000-000000000001'::uuid,'c5500000-0000-4000-8000-000000000001'::uuid,'c5500000-0000-4000-8000-000000000002'::uuid]
  )$$,
  '23505',
  null,
  'duplicate Product IDs rejected'
);

select throws_ok(
  $$select public.reorder_branch_catalog_products(
    'c1500000-0000-4000-8000-000000000001',
    'c3500000-0000-4000-8000-000000000001',
    array['c5500000-0000-4000-8000-000000000001'::uuid,'c5500000-0000-4000-8000-000000000002'::uuid,'c5500000-0000-4000-8000-000000000005'::uuid]
  )$$,
  '42501',
  'product order contains unavailable product',
  'cross-branch Product ID rejected'
);

select throws_ok(
  $$select public.reorder_branch_catalog_products(
    'c1500000-0000-4000-8000-000000000001',
    'c3500000-0000-4000-8000-000000000001',
    array['c5500000-0000-4000-8000-000000000001'::uuid,'c5500000-0000-4000-8000-000000000002'::uuid,'c5500000-0000-4000-8000-000000000004'::uuid]
  )$$,
  '42501',
  'product order contains unavailable product',
  'inactive Product ID rejected'
);

select is((select display_order from public.branch_product_catalog_products where id='c5500000-0000-4000-8000-000000000004'), null, 'inactive products keep null display_order in catalog state');

select ok(
  (select pg_get_functiondef('public.archive_branch_catalog_inventory_item(uuid,uuid,uuid)'::regprocedure) like '%private.lock_branch_catalog(target_branch.organization_id, target_branch.id)%')
  and
  (select pg_get_functiondef('public.save_branch_product_usage_mappings(uuid,uuid,uuid,jsonb)'::regprocedure) like '%private.lock_branch_catalog(target_branch.organization_id, target_branch.id)%'),
  'archive and recipe save use the same branch catalog advisory lock helper'
);

select * from finish();
rollback;
