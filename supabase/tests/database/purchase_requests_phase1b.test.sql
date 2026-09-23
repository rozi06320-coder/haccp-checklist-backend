begin;
select plan(67);

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
select has_column('public','purchase_request_items','invoice_number','items store Purchasing invoice number');
select has_column('public','purchase_request_items','before_tax_amount','items store Purchasing before-tax amount');
select has_column('public','purchase_request_items','tax_amount','items store Purchasing tax amount');
select has_column('public','purchase_request_items','total_amount','items store Purchasing total amount');
select has_column('public','purchase_request_items','purchasing_notes','items store Purchasing notes');
select has_table('public','purchase_request_item_attachments','purchase request item attachments table exists');
select ok((select exists(select 1 from storage.buckets where id='purchase-request-attachments' and public is false and file_size_limit=5242880)),'purchase request attachment storage bucket exists with private 5MB limit');
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
select ok(not has_table_privilege('authenticated','public.purchase_request_item_attachments','insert'),'authenticated cannot insert request attachments directly');
select ok(has_function_privilege('service_role','public.create_supervisor_purchase_request(uuid,uuid,text,text,jsonb)','execute'),'service_role can execute supervisor create RPC');
select ok(not has_function_privilege('authenticated','public.create_supervisor_purchase_request(uuid,uuid,text,text,jsonb)','execute'),'authenticated cannot execute supervisor create RPC');
select ok(has_function_privilege('service_role','public.list_purchasing_purchase_requests(uuid,uuid,text)','execute'),'service_role can execute purchasing list RPC');
select ok(not has_function_privilege('authenticated','public.list_purchasing_purchase_requests(uuid,uuid,text)','execute'),'authenticated cannot execute purchasing list RPC');
select ok(has_function_privilege('service_role','public.set_purchasing_purchase_request_status(uuid,uuid,uuid,text)','execute'),'service_role can execute purchasing status RPC');
select ok(not has_function_privilege('authenticated','public.set_purchasing_purchase_request_status(uuid,uuid,uuid,text)','execute'),'authenticated cannot execute purchasing status RPC');
select ok(has_function_privilege('service_role','public.save_purchasing_purchase_request_details(uuid,uuid,uuid,jsonb)','execute'),'service_role can execute purchasing detail save RPC');
select ok(not has_function_privilege('authenticated','public.save_purchasing_purchase_request_details(uuid,uuid,uuid,jsonb)','execute'),'authenticated cannot execute purchasing detail save RPC');

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
)$$,'22023','purchase details incomplete','Purchasing cannot mark purchased before item purchase details are saved');
select lives_ok($$select public.save_purchasing_purchase_request_details(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 (select jsonb_agg(jsonb_build_object(
   'item_id', item.id,
   'vendor_name', 'Saved Vendor',
   'invoice_number', 'INV-SAVE',
   'purchased_quantity', item.quantity,
   'actual_unit_cost', '10.00',
   'before_tax_amount', (item.quantity * 10)::text,
   'tax_amount', '0.00',
   'total_amount', (item.quantity * 10)::text,
   'purchasing_notes', 'Saved while processing',
   'attachments', case when item.sort_order = 1 then jsonb_build_array(jsonb_build_object('id','8e000000-0000-4000-8000-000000000001','storage_path','purchasing/org/request/item/receipt.pdf','original_filename','receipt.pdf','mime_type','application/pdf','size_bytes',120,'position',1)) else '[]'::jsonb end
  ))
  from public.purchase_request_items item
  where item.purchase_request_id = (select request_id from purchase_request_test_ids limit 1))
)$$,'Purchasing can save item details while request remains processing');
select is((select status from public.purchase_requests where id=(select request_id from purchase_request_test_ids limit 1)),'processing','saving financial item details does not change request status');
select is((select count(*)::integer from public.purchase_request_items where invoice_number='INV-SAVE'),2,'invoice numbers are saved on request items');
select is((select sum(before_tax_amount) from public.purchase_request_items where vendor_name='Saved Vendor'),50.00::numeric,'before-tax amounts are saved on request items');
select is((select count(*)::integer from public.purchase_request_item_attachments),1,'receipt attachment metadata is saved for the request item');
select throws_ok($$select public.save_purchasing_purchase_request_details(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 (select jsonb_build_array(jsonb_build_object(
   'item_id', item.id,
   'vendor_name', 'Broken Vendor',
   'before_tax_amount', '10.00',
   'tax_amount', '2.00',
   'total_amount', '11.00'
  ))
  from public.purchase_request_items item
  where item.purchase_request_id = (select request_id from purchase_request_test_ids limit 1)
  order by item.sort_order
  limit 1)
)$$,'22023','invalid purchase detail tax breakdown','before-tax plus tax must equal total');
select throws_ok($$select public.save_purchasing_purchase_request_details(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 (select jsonb_build_array(jsonb_build_object(
   'item_id', item.id,
   'vendor_name', 'Broken Vendor',
   'purchased_quantity', '2',
   'actual_unit_cost', '9.00',
   'before_tax_amount', '10.00',
   'tax_amount', '0.00',
   'total_amount', '10.00'
  ))
  from public.purchase_request_items item
  where item.purchase_request_id = (select request_id from purchase_request_test_ids limit 1)
  order by item.sort_order
  limit 1)
)$$,'22023','invalid purchase detail before tax','quantity times unit cost must equal before tax when both are supplied');
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
   'before_tax_amount', (item.quantity * 10)::text,
   'tax_amount', '1.00',
   'total_amount', '1.00'
  ))
  from public.purchase_request_items item
  where item.purchase_request_id = (select request_id from purchase_request_test_ids limit 1))
)$$,'22023','invalid purchase detail tax breakdown','Purchasing cannot mark purchased with an inconsistent tax breakdown');
select lives_ok($$select public.set_purchasing_purchase_request_status(
 '1e000000-0000-4000-8000-000000000003',
 '2e000000-0000-4000-8000-000000000001',
 (select request_id from purchase_request_test_ids limit 1),
 'purchased',
 (select jsonb_agg(jsonb_build_object(
   'item_id', item.id,
   'vendor_name', 'Office Vendor',
   'invoice_number', 'INV-PURCHASED',
   'purchased_quantity', item.quantity,
   'actual_unit_cost', '10.00',
   'before_tax_amount', (item.quantity * 10)::text,
   'tax_amount', '0.00',
   'total_amount', (item.quantity * 10)::text,
   'purchasing_notes', 'Purchased by Central Purchasing'
  ))
  from public.purchase_request_items item
  where item.purchase_request_id = (select request_id from purchase_request_test_ids limit 1))
)$$,'Purchasing can move processing request to purchased');
select is((select count(*)::integer from public.purchase_request_items where vendor_name='Office Vendor'),2,'purchase details are written onto each item');
select is((select sum(actual_total_cost) from public.purchase_request_items where vendor_name='Office Vendor'),50.00::numeric,'actual total cost is stored per item');
select is((select sum(total_amount) from public.purchase_request_items where vendor_name='Office Vendor'),50.00::numeric,'total amount is the user-facing final total per item');
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
