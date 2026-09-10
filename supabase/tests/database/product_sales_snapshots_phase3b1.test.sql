begin;
select no_plan();

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@product-sales.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1b100000-0000-4000-8000-000000000001'::uuid,
  '1b100000-0000-4000-8000-000000000002'
]) id;

update public.profiles
set full_name = case id
    when '1b100000-0000-4000-8000-000000000001' then 'Product Sales Supervisor A'
    else 'Product Sales Supervisor B'
  end,
  must_change_password = false
where id in ('1b100000-0000-4000-8000-000000000001','1b100000-0000-4000-8000-000000000002');

insert into public.organizations(id,name,slug)
values
  ('2b100000-0000-4000-8000-000000000001','Product Sales Org A','product-sales-org-a'),
  ('2b100000-0000-4000-8000-000000000002','Product Sales Org B','product-sales-org-b');

insert into public.branches(id,organization_id,name,code,timezone)
values
  ('3b100000-0000-4000-8000-000000000001','2b100000-0000-4000-8000-000000000001','Product Sales Branch A','PSA','Asia/Riyadh'),
  ('3b100000-0000-4000-8000-000000000002','2b100000-0000-4000-8000-000000000002','Product Sales Branch B','PSB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role)
values
  ('3b100000-0000-4000-8000-000000000001','1b100000-0000-4000-8000-000000000001','branch_manager'),
  ('3b100000-0000-4000-8000-000000000002','1b100000-0000-4000-8000-000000000002','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values
  ('7b100000-0000-4000-8000-000000000001','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','1b100000-0000-4000-8000-000000000001'),
  ('7b100000-0000-4000-8000-000000000002','2b100000-0000-4000-8000-000000000002','3b100000-0000-4000-8000-000000000002','1b100000-0000-4000-8000-000000000002');

insert into public.branch_inventory_catalog_items(id,organization_id,branch_id,name,unit,kind)
values
  ('4b100000-0000-4000-8000-000000000001','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Bread','pcs','ingredient'),
  ('4b100000-0000-4000-8000-000000000002','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Beef','pcs','ingredient'),
  ('4b100000-0000-4000-8000-000000000003','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Bottled Water','pcs','standalone_stock'),
  ('4b100000-0000-4000-8000-000000000004','2b100000-0000-4000-8000-000000000002','3b100000-0000-4000-8000-000000000002','Other Bread','pcs','ingredient'),
  ('4b100000-0000-4000-8000-000000000005','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Cheese','pcs','ingredient'),
  ('4b100000-0000-4000-8000-000000000006','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Juice Original','pcs','standalone_stock'),
  ('4b100000-0000-4000-8000-000000000007','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Juice New','pcs','standalone_stock');

insert into public.branch_product_catalog_products(id,organization_id,branch_id,name,inventory_behavior,unit,standalone_inventory_item_id,is_active)
values
  ('5b100000-0000-4000-8000-000000000001','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Burger','recipe',null,null,true),
  ('5b100000-0000-4000-8000-000000000002','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Water','standalone_stock','pcs','4b100000-0000-4000-8000-000000000003',true),
  ('5b100000-0000-4000-8000-000000000003','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Delivery Fee','non_stock',null,null,true),
  ('5b100000-0000-4000-8000-000000000004','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Unmapped Recipe','recipe',null,null,true),
  ('5b100000-0000-4000-8000-000000000005','2b100000-0000-4000-8000-000000000002','3b100000-0000-4000-8000-000000000002','Other Burger','recipe',null,null,true),
  ('5b100000-0000-4000-8000-000000000006','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Taco','recipe',null,null,true),
  ('5b100000-0000-4000-8000-000000000007','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Zero Burger','recipe',null,null,true),
  ('5b100000-0000-4000-8000-000000000008','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Juice','standalone_stock','pcs','4b100000-0000-4000-8000-000000000006',true),
  ('5b100000-0000-4000-8000-000000000009','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','Inactive Never Sold','recipe',null,null,false);

insert into public.branch_product_usage_mappings(id,organization_id,branch_id,product_id,inventory_item_id,quantity)
values
  ('6b100000-0000-4000-8000-000000000001','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','5b100000-0000-4000-8000-000000000001','4b100000-0000-4000-8000-000000000001',1),
  ('6b100000-0000-4000-8000-000000000002','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','5b100000-0000-4000-8000-000000000001','4b100000-0000-4000-8000-000000000002',1),
  ('6b100000-0000-4000-8000-000000000003','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','5b100000-0000-4000-8000-000000000006','4b100000-0000-4000-8000-000000000005',1),
  ('6b100000-0000-4000-8000-000000000004','2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001','5b100000-0000-4000-8000-000000000007','4b100000-0000-4000-8000-000000000001',1);

select has_table('public','branch_product_sales_daily_reports','product sales daily report table exists');
select has_table('public','branch_product_sales','product sales source table exists');
select has_table('public','branch_product_sales_usage_snapshots','frozen usage snapshot table exists');
select ok((select relrowsecurity from pg_class where oid='public.branch_product_sales_daily_reports'::regclass)
  and (select relrowsecurity from pg_class where oid='public.branch_product_sales'::regclass)
  and (select relrowsecurity from pg_class where oid='public.branch_product_sales_usage_snapshots'::regclass),'all product sales tables have RLS enabled');
select ok(not has_table_privilege('authenticated','public.branch_product_sales_daily_reports','insert,update,delete')
  and not has_table_privilege('authenticated','public.branch_product_sales','insert,update,delete')
  and not has_table_privilege('authenticated','public.branch_product_sales_usage_snapshots','insert,update,delete'),'authenticated has no direct product sales table mutation privileges');

set local role authenticated;
select throws_ok($$insert into public.branch_product_sales_daily_reports(organization_id,branch_id,business_date,created_by_user_id,updated_by_user_id) values('2b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',current_date,'1b100000-0000-4000-8000-000000000001','1b100000-0000-4000-8000-000000000001')$$,'42501',null,'authenticated direct report insert is denied');
reset role;

select ok(has_function_privilege('service_role','public.save_branch_product_sales(uuid,uuid,date,bigint,jsonb)','execute')
  and not has_function_privilege('authenticated','public.save_branch_product_sales(uuid,uuid,date,bigint,jsonb)','execute'),'save RPC is service-role only');
select ok(has_function_privilege('service_role','public.get_branch_product_sales(uuid,uuid,date)','execute')
  and not has_function_privilege('authenticated','public.get_branch_product_sales(uuid,uuid,date)','execute'),'read RPC is service-role only');

select is(public.get_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh') - 10)->>'revision','0','missing report reads as revision zero');
select is(jsonb_array_length(public.get_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh') - 10)->'sales'),0,'missing report returns empty sales array');
select is(jsonb_array_length(public.get_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh') - 10)->'usage_snapshots'),0,'missing report returns empty usage array');

select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000002','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[]')$$,'42501','product sales access denied','branch B actor cannot write branch A');
select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[{"product_id":"5b100000-0000-4000-8000-000000000005","quantity":1}]')$$,'42501','product sale product unavailable','wrong-branch product is rejected');
select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh') + 1,0,'[]')$$,'22023','product sales future business date denied','future business date is rejected');
select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":-1}]')$$,'22023','invalid product sales quantity','negative quantity is rejected');
select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":1},{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":2}]')$$,'23505','duplicate product sale','duplicate product IDs are rejected');
select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[{"product_id":"5b100000-0000-4000-8000-000000000004","quantity":0}]')$$,'22023','recipe product has no inventory mappings','unmapped recipe rejects even at zero quantity');

select lives_ok($$select public.save_branch_product_sales(
  '1b100000-0000-4000-8000-000000000001',
  '3b100000-0000-4000-8000-000000000001',
  private.phase4a_business_date('Asia/Riyadh'),
  0,
  '[
    {"product_id":"5b100000-0000-4000-8000-000000000001","quantity":2},
    {"product_id":"5b100000-0000-4000-8000-000000000002","quantity":4},
    {"product_id":"5b100000-0000-4000-8000-000000000003","quantity":5},
    {"product_id":"5b100000-0000-4000-8000-000000000006","quantity":7},
    {"product_id":"5b100000-0000-4000-8000-000000000007","quantity":0},
    {"product_id":"5b100000-0000-4000-8000-000000000008","quantity":0}
  ]'
)$$,'first product sales patch creates the daily report');

select is((select revision from public.branch_product_sales_daily_reports where branch_id='3b100000-0000-4000-8000-000000000001'),1::bigint,'first save creates revision one');
select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[]')$$,'40001','product sales changed','stale revision is rejected');
select is((public.save_branch_product_sales(
  '1b100000-0000-4000-8000-000000000001',
  '3b100000-0000-4000-8000-000000000001',
  private.phase4a_business_date('Asia/Riyadh'),
  1,
  '[
    {"product_id":"5b100000-0000-4000-8000-000000000008","quantity":0.0},
    {"product_id":"5b100000-0000-4000-8000-000000000007","quantity":0},
    {"product_id":"5b100000-0000-4000-8000-000000000006","quantity":7.0},
    {"product_id":"5b100000-0000-4000-8000-000000000003","quantity":5.0},
    {"product_id":"5b100000-0000-4000-8000-000000000002","quantity":4.0},
    {"product_id":"5b100000-0000-4000-8000-000000000001","quantity":2.0}
  ]'
)->>'revision'),'1','payload order and numeric scale do not increment revision');

select is((select count(*)::int from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000001'),2,'first recipe save freezes current mappings');
select is((select total_usage_quantity from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000001' and inventory_item_id='4b100000-0000-4000-8000-000000000002'),2::numeric,'first recipe save multiplies quantity by frozen coefficient');
select ok((select sales_quantity_snapshot=0 and total_usage_quantity=0 from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000007'),'zero recipe first save freezes mapping with zero totals');
select ok((select inventory_item_id='4b100000-0000-4000-8000-000000000006' and sales_quantity_snapshot=0 and total_usage_quantity=0 from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000008'),'zero standalone first save freezes original linked item with zero totals');
select is((select count(*)::int from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000003'),0,'non-stock product creates no usage snapshots');

select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),1,'[{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":3}]')->>'revision'),'2','patching one product increments revision');
select is((select quantity from public.branch_product_sales where product_id='5b100000-0000-4000-8000-000000000002'),4::numeric,'omitted existing active standalone product is preserved');
select is((select total_usage_quantity from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000006'),7::numeric,'editing Product A does not modify Product B usage snapshot');

update public.branch_product_catalog_products set is_active=false where id='5b100000-0000-4000-8000-000000000006';
select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),2,'[{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":4}]')->>'revision'),'3','patching Product A after Product B deactivation succeeds');
select is((select quantity from public.branch_product_sales where product_id='5b100000-0000-4000-8000-000000000006'),7::numeric,'omitted inactive historical product is preserved');
select is((select count(*)::int from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000006'),1,'inactive historical product snapshot is preserved');
select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),3,'[{"product_id":"5b100000-0000-4000-8000-000000000006","quantity":8}]')->>'revision'),'4','inactive historical product quantity can be corrected');
select is((select total_usage_quantity from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000006'),8::numeric,'inactive historical correction uses frozen coefficient');
select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),4,'[{"product_id":"5b100000-0000-4000-8000-000000000009","quantity":1}]')$$,'42501','product sale product unavailable','new inactive product cannot be created');

update public.branch_product_catalog_products set name='Burger v2' where id='5b100000-0000-4000-8000-000000000001';
update public.branch_inventory_catalog_items set name='Beef v2' where id='4b100000-0000-4000-8000-000000000002';
update public.branch_product_usage_mappings set quantity=2 where id='6b100000-0000-4000-8000-000000000002';
update public.branch_product_usage_mappings set quantity=3 where id='6b100000-0000-4000-8000-000000000004';

select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),4,'[{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":5}]')->>'revision'),'5','historical quantity correction after recipe edit succeeds');
select ok((select product_name_snapshot='Burger' and inventory_item_name_snapshot='Beef' and quantity_per_sale_snapshot=1 and sales_quantity_snapshot=5 and total_usage_quantity=5 from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000001' and inventory_item_id='4b100000-0000-4000-8000-000000000002'),'historical correction preserves old recipe coefficient and names');
select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),5,'[{"product_id":"5b100000-0000-4000-8000-000000000007","quantity":6}]')->>'revision'),'6','zero to positive after recipe edit succeeds');
select ok((select quantity_per_sale_snapshot=1 and sales_quantity_snapshot=6 and total_usage_quantity=6 from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000007'),'zero to positive uses original frozen recipe coefficient');

update public.branch_product_catalog_products set standalone_inventory_item_id='4b100000-0000-4000-8000-000000000007' where id='5b100000-0000-4000-8000-000000000008';
update public.branch_inventory_catalog_items set name='Juice Original Renamed' where id='4b100000-0000-4000-8000-000000000006';
select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),6,'[{"product_id":"5b100000-0000-4000-8000-000000000008","quantity":2}]')->>'revision'),'7','standalone quantity correction after linked item change succeeds');
select ok((select inventory_item_id='4b100000-0000-4000-8000-000000000006' and inventory_item_name_snapshot='Juice Original' and total_usage_quantity=2 from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000008'),'standalone correction preserves originally frozen linked item');

select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),7,'[{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":0}]')->>'revision'),'8','explicit zero updates Product Sales row');
select is((select quantity from public.branch_product_sales where product_id='5b100000-0000-4000-8000-000000000001'),0::numeric,'explicit zero retains Product Sales row');
select ok((select bool_and(sales_quantity_snapshot=0 and total_usage_quantity=0) from public.branch_product_sales_usage_snapshots where product_id='5b100000-0000-4000-8000-000000000001'),'explicit zero retains frozen recipe coefficient rows with zero totals');
select is((public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),8,'[]')->>'revision'),'8','empty patch is no-op and does not increment revision');
select is((select count(*)::int from public.branch_product_sales),6,'empty patch deletes no Product Sales rows');

select throws_ok($$select public.save_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),8,'[{"product_id":"5b100000-0000-4000-8000-000000000001","quantity":9},{"product_id":"5b100000-0000-4000-8000-000000000005","quantity":1}]')$$,'42501','product sale product unavailable','invalid batch product rejects atomically');
select is((select quantity from public.branch_product_sales where product_id='5b100000-0000-4000-8000-000000000001'),0::numeric,'invalid batch rolls back all submitted changes');
select is((select revision from public.branch_product_sales_daily_reports where branch_id='3b100000-0000-4000-8000-000000000001'),8::bigint,'invalid batch preserves revision');

select is(jsonb_array_length(public.get_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'))->'sales'),6,'read RPC returns inactive historical products');
select ok(public.get_branch_product_sales('1b100000-0000-4000-8000-000000000001','3b100000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'))->'sales' @> '[{"product_id":"5b100000-0000-4000-8000-000000000006","quantity":8}]'::jsonb,'read RPC includes inactive historical product quantity');

select throws_ok($$delete from public.branch_product_catalog_products where id='5b100000-0000-4000-8000-000000000001'$$,'23503',null,'historical product FK is restrictive');
select throws_ok($$delete from public.branch_inventory_catalog_items where id='4b100000-0000-4000-8000-000000000002'$$,'23503',null,'historical inventory item FK is restrictive');

select * from finish();
rollback;
