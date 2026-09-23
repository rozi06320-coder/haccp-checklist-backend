begin;
select plan(50);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1e000000-0000-4000-8000-000000000001'::uuid, 'purchase-supervisor@example.invalid'),
  ('1e000000-0000-4000-8000-000000000002'::uuid, 'purchase-foreign-supervisor@example.invalid'),
  ('1e000000-0000-4000-8000-000000000003'::uuid, 'purchase-buyer@example.invalid'),
  ('1e000000-0000-4000-8000-000000000004'::uuid, 'purchase-inactive-buyer@example.invalid'),
  ('1e000000-0000-4000-8000-000000000005'::uuid, 'purchase-manager@example.invalid')
) user_data(id,email);

update public.profiles
set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Purchase Supervisor'
  when '1e000000-0000-4000-8000-000000000002' then 'Foreign Supervisor'
  when '1e000000-0000-4000-8000-000000000003' then 'Buyer'
  when '1e000000-0000-4000-8000-000000000004' then 'Inactive Buyer'
  else 'Manager'
end,
must_change_password = false
where id::text like '1e000000-%';

insert into public.organizations(id,name,slug) values
 ('2e000000-0000-4000-8000-000000000001','Purchase Request Org A','purchase-request-org-a'),
 ('2e000000-0000-4000-8000-000000000002','Purchase Request Org B','purchase-request-org-b');

insert into public.branches(id,organization_id,name,code,timezone) values
 ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Purchase Request Branch A','PRA','Asia/Riyadh'),
 ('3e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000002','Purchase Request Branch B','PRB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role) values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager'),
 ('3e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002','branch_manager');

insert into public.organization_memberships(organization_id,user_id,role) values
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000005','organization_manager');

insert into public.purchasing_memberships(organization_id,user_id,active,created_by,updated_by) values
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003',true,'1e000000-0000-4000-8000-000000000005','1e000000-0000-4000-8000-000000000005'),
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000004',false,'1e000000-0000-4000-8000-000000000005','1e000000-0000-4000-8000-000000000005');

select has_table('public','purchase_requests','purchase request parent table exists');
select has_table('public','purchase_request_items','purchase request item table exists');
select has_column('public','purchase_request_items','vendor_name','items store Purchasing vendor');
select has_column('public','purchase_request_items','purchased_quantity','items store actual purchased quantity');
select has_column('public','purchase_request_items','actual_unit_cost','items store actual unit cost');
select has_column('public','purchase_request_items','actual_total_cost','items store actual total cost');
select has_column('public','purchase_request_items','purchasing_notes','items store Purchasing notes');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.purchase_requests'::regclass),'purchase_requests has RLS enabled');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.purchase_request_items'::regclass),'purchase_request_items has RLS enabled');

select is((select confdeltype from pg_catalog.pg_constraint where conrelid='public.purchase_requests'::regclass and conname='purchase_requests_organization_id_fkey'),'c','organization FK cascades only with organization deletion');
select is((select confdeltype from pg_catalog.pg_constraint where conrelid='public.purchase_requests'::regclass and conname='purchase_requests_branch_id_fkey'),'r','branch FK restricts deletion while requests exist');
select is((select confdeltype from pg_catalog.pg_constraint where conrelid='public.purchase_requests'::regclass and conname='purchase_requests_requested_by_fkey'),'r','requester FK restricts deletion while requests exist');
select is((select confdeltype from pg_catalog.pg_constraint where conrelid='public.purchase_request_items'::regclass and conname='purchase_request_items_purchase_request_id_fkey'),'c','items cascade only with parent request deletion');

select ok(not has_table_privilege('authenticated','public.purchase_requests','insert'),'authenticated cannot insert requests directly');
select ok(not has_table_privilege('authenticated','public.purchase_requests','update'),'authenticated cannot update requests directly');
select ok(not has_table_privilege('authenticated','public.purchase_requests','delete'),'authenticated cannot delete requests directly');
select ok(not has_table_privilege('authenticated','public.purchase_request_items','insert'),'authenticated cannot insert request items directly');
select ok(has_function_privilege('service_role','public.create_supervisor_purchase_request(uuid,uuid,text,text,jsonb)','execute'),'service_role can execute supervisor create RPC');
select ok(not has_function_privilege('authenticated','public.create_supervisor_purchase_request(uuid,uuid,text,text,jsonb)','execute'),'authenticated cannot execute supervisor create RPC');
select ok(has_function_privilege('service_role','public.list_purchasing_purchase_requests(uuid,uuid,text)','execute'),'service_role can execute purchasing list RPC');
select ok(not has_function_privilege('authenticated','public.list_purchasing_purchase_requests(uuid,uuid,text)','execute'),'authenticated cannot execute purchasing list RPC');
select ok(has_function_privilege('service_role','public.set_purchasing_purchase_request_status(uuid,uuid,uuid,text)','execute'),'service_role can execute purchasing status RPC');
select ok(not has_function_privilege('authenticated','public.set_purchasing_purchase_request_status(uuid,uuid,uuid,text)','execute'),'authenticated cannot execute purchasing status RPC');

set local role service_role;
select lives_ok($$select public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 'kitchen',
 'Initial request',
 jsonb_build_array(
  jsonb_build_object('name','Gloves','quantity',2,'unit','box'),
  jsonb_build_object('name','Wipes','quantity','3','notes','Food safe')
 )
)$$,'authorized supervisor creates parent and multiple items atomically');
reset role;

select is((select count(*)::integer from public.purchase_requests where requested_by='1e000000-0000-4000-8000-000000000001'),1,'one purchase request parent is persisted');
select is((select count(*)::integer from public.purchase_request_items),2,'all request items are persisted');
select is((select organization_id from public.purchase_requests limit 1),'2e000000-0000-4000-8000-000000000001'::uuid,'organization is derived from authorized branch scope');
select is((select status from public.purchase_requests limit 1),'submitted','supervisor-created request starts submitted');

select throws_ok($$select public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000002',
 'kitchen',
 'Unauthorized branch',
 jsonb_build_array(jsonb_build_object('name','Gloves','quantity',1))
)$$,'42501','purchase request branch access denied','supervisor cannot create for unauthorized branch');
select throws_ok($$select public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 'equipment',
 'Bad category',
 jsonb_build_array(jsonb_build_object('name','Gloves','quantity',1))
)$$,'22023','invalid purchase request category','invalid category is rejected');
select throws_ok($$select public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 'kitchen',
 'No items',
 '[]'::jsonb
)$$,'22023','purchase request requires items','empty item array is rejected');
select throws_ok($$select public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 'kitchen',
 'Rollback request',
 jsonb_build_array(
  jsonb_build_object('name','Valid item','quantity',1),
  jsonb_build_object('name','Invalid item','quantity',-1)
 )
)$$,'22023','invalid purchase request item','invalid item aborts atomic create');
select is((select count(*)::integer from public.purchase_requests where notes='Rollback request'),0,'invalid child leaves no parent request');
select is((select count(*)::integer from public.purchase_request_items where item_name in ('Valid item','Invalid item')),0,'invalid child leaves no partial item set');

select is((select count(*)::integer from (select jsonb_array_elements((public.list_purchasing_purchase_requests('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001',null)->'purchase_requests'))) rows),1,'active Purchasing member lists own organization requests');
select throws_ok($$select public.list_purchasing_purchase_requests('1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000002',null)$$,'42501','purchasing access denied','Purchasing org A cannot list org B');
select throws_ok($$select public.list_purchasing_purchase_requests('1e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000001',null)$$,'42501','purchasing access denied','inactive Purchasing member cannot list requests');
select throws_ok($$select public.list_purchasing_purchase_requests('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001',null)$$,'42501','purchasing access denied','organization manager without Purchasing membership cannot list requests');
select throws_ok($$select public.list_purchasing_purchase_requests('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001',null)$$,'42501','purchasing access denied','supervisor without Purchasing membership cannot list requests');

create temp table purchase_request_test_ids as
select id as request_id from public.purchase_requests where requested_by='1e000000-0000-4000-8000-000000000001' limit 1;
grant select on purchase_request_test_ids to service_role;

select lives_ok($$select public.set_purchasing_purchase_request_status(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 'processing'
)$$,'Purchasing can move submitted request to processing');
select throws_ok($$select public.set_purchasing_purchase_request_status(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 'purchased'
)$$,'22023','purchase details required','Purchasing cannot mark purchased without item purchase details');
select throws_ok($$select public.set_purchasing_purchase_request_status(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 'purchased',
 (select jsonb_agg(jsonb_build_object(
   'item_id', item.id,
   'vendor_name', 'Office Vendor',
   'purchased_quantity', item.quantity,
   'actual_unit_cost', '10.00',
   'actual_total_cost', '1.00'
  ))
  from public.purchase_request_items item
  where item.purchase_request_id = (select request_id from purchase_request_test_ids limit 1))
)$$,'22023','invalid purchase detail total','Purchasing cannot mark purchased with an inconsistent item cost total');
select lives_ok($$select public.set_purchasing_purchase_request_status(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 'purchased',
 (select jsonb_agg(jsonb_build_object(
   'item_id', item.id,
   'vendor_name', 'Office Vendor',
   'purchased_quantity', item.quantity,
   'actual_unit_cost', '10.00',
   'actual_total_cost', (item.quantity * 10)::text,
   'purchasing_notes', 'Purchased by Central Purchasing'
  ))
  from public.purchase_request_items item
  where item.purchase_request_id = (select request_id from purchase_request_test_ids limit 1))
)$$,'Purchasing can move processing request to purchased');
select is((select count(*)::integer from public.purchase_request_items where vendor_name='Office Vendor'),2,'purchase details are written onto each item');
select is((select sum(actual_total_cost) from public.purchase_request_items where vendor_name='Office Vendor'),50.00::numeric,'actual total cost is stored per item');
select is((select count(*)::integer from public.purchase_request_items where purchasing_notes='Purchased by Central Purchasing'),2,'purchasing notes are stored per item');
select throws_ok($$select public.set_purchasing_purchase_request_status(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 'processing'
)$$,'22023','invalid purchase request status transition','purchased request cannot move back to processing');
select throws_ok($$select public.set_purchasing_purchase_request_status(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 'received'
)$$,'22023','invalid purchase request status transition','received is not available through Phase 1B status RPC');

select is((select count(*)::integer from public.branch_purchase_logs),0,'marking purchased creates no branch Purchase Log row');
select is((select count(*)::integer from public.maintenance_purchase_logs),0,'marking purchased creates no maintenance purchase/expense row');

select * from finish();
rollback;
