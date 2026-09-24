begin;
select plan(37);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('91000000-0000-4000-8000-000000000001'::uuid, 'settlement-supervisor@example.invalid'),
  ('91000000-0000-4000-8000-000000000002'::uuid, 'settlement-buyer@example.invalid'),
  ('91000000-0000-4000-8000-000000000003'::uuid, 'settlement-inactive-buyer@example.invalid'),
  ('91000000-0000-4000-8000-000000000004'::uuid, 'settlement-manager@example.invalid'),
  ('91000000-0000-4000-8000-000000000005'::uuid, 'settlement-foreign-buyer@example.invalid')
) user_data(id,email);

update public.profiles
set full_name = case id
  when '91000000-0000-4000-8000-000000000001' then 'Settlement Supervisor'
  when '91000000-0000-4000-8000-000000000002' then 'Settlement Buyer'
  when '91000000-0000-4000-8000-000000000003' then 'Inactive Settlement Buyer'
  when '91000000-0000-4000-8000-000000000004' then 'Settlement Manager'
  else 'Foreign Buyer'
end,
must_change_password = false
where id::text like '91000000-%';

insert into public.organizations(id,name,slug) values
 ('92000000-0000-4000-8000-000000000001','Settlement Org A','settlement-org-a'),
 ('92000000-0000-4000-8000-000000000002','Settlement Org B','settlement-org-b');

insert into public.branches(id,organization_id,name,code,timezone) values
 ('93000000-0000-4000-8000-000000000001','92000000-0000-4000-8000-000000000001','Settlement Branch A','SBA','Asia/Riyadh'),
 ('93000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000002','Settlement Branch B','SBB','Asia/Riyadh');

insert into public.organization_memberships(organization_id,user_id,role) values
 ('92000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000004','organization_manager');

insert into public.branch_memberships(branch_id,user_id,role) values
 ('93000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','branch_manager');

insert into public.purchasing_memberships(organization_id,user_id,active,created_by,updated_by) values
 ('92000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000002',true,'91000000-0000-4000-8000-000000000004','91000000-0000-4000-8000-000000000004'),
 ('92000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000003',false,'91000000-0000-4000-8000-000000000004','91000000-0000-4000-8000-000000000004'),
 ('92000000-0000-4000-8000-000000000002','91000000-0000-4000-8000-000000000005',true,'91000000-0000-4000-8000-000000000004','91000000-0000-4000-8000-000000000004');

select has_column('public','purchase_request_items','payment_source','purchase request items store payment source only');
select has_column('public','branch_purchase_logs','source_type','purchase logs store source type');
select has_column('public','branch_purchase_logs','source_purchase_request_id','purchase logs link source request');
select has_column('public','branch_purchase_logs','source_purchase_request_item_id','purchase logs link source item');
select is((select count(*)::int from information_schema.columns where table_schema='public' and table_name='purchase_request_items' and column_name like '%settlement%'),0,'purchase request items do not store independent settlement status');
select ok(to_regclass('public.branch_purchase_logs_central_purchasing_item_key') is not null,'central purchasing source item unique index exists');

insert into public.purchase_requests(id,organization_id,branch_id,requested_by,category,status,notes)
values
 ('94000000-0000-4000-8000-000000000001','92000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','kitchen','processing','settlement request'),
 ('94000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','kitchen','processing','missing source request'),
 ('94000000-0000-4000-8000-000000000003','92000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','kitchen','processing','conflict request'),
 ('94000000-0000-4000-8000-000000000004','92000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','kitchen','processing','other source request'),
 ('94000000-0000-4000-8000-000000000005','92000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','other','purchased','historical request');

insert into public.purchase_request_items(id,purchase_request_id,item_name,quantity,unit,sort_order)
values
 ('95000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000001','Company item',2,'box',1),
 ('95000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000001','Personal item',1,'pcs',2),
 ('95000000-0000-4000-8000-000000000003','94000000-0000-4000-8000-000000000002','Missing source item',1,'pcs',1),
 ('95000000-0000-4000-8000-000000000004','94000000-0000-4000-8000-000000000003','Conflict item',1,'pcs',1),
 ('95000000-0000-4000-8000-000000000005','94000000-0000-4000-8000-000000000004','Other item',1,'pcs',1),
 ('95000000-0000-4000-8000-000000000006','94000000-0000-4000-8000-000000000005','Historical null item',1,'pcs',1);

select lives_ok($$select public.save_purchasing_purchase_request_details(
 '91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000001',
 jsonb_build_array(
  jsonb_build_object('item_id','95000000-0000-4000-8000-000000000001','vendor_name','Company Vendor','invoice_number','INV-COMP','purchased_quantity','2','actual_unit_cost','50.00','before_tax_amount','100.00','tax_amount','15.00','total_amount','115.00','payment_source','company','purchasing_notes','company note'),
  jsonb_build_object('item_id','95000000-0000-4000-8000-000000000002','vendor_name','Personal Vendor','invoice_number','INV-PERS','purchased_quantity','1','actual_unit_cost','20.00','before_tax_amount','20.00','tax_amount','3.00','total_amount','23.00','payment_source','personal','purchasing_notes','personal note')
 )
)$$,'saving company and personal payment sources succeeds');
select is((select count(*)::int from public.purchase_request_items where payment_source='company'),1,'company payment source saved');
select is((select count(*)::int from public.purchase_request_items where payment_source='personal'),1,'personal payment source saved');
select throws_ok($$select public.save_purchasing_purchase_request_details(
 '91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000001',
 jsonb_build_array(jsonb_build_object('item_id','95000000-0000-4000-8000-000000000001','vendor_name','Bad Vendor','total_amount','1.00','payment_source','cash'))
)$$,'22023','invalid purchase detail payment source','invalid payment source is rejected');

select throws_ok($$select public.set_purchasing_purchase_request_status(
 '91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000002','purchased',
 jsonb_build_array(jsonb_build_object('item_id','95000000-0000-4000-8000-000000000003','vendor_name','Missing Vendor','before_tax_amount','10.00','tax_amount','0.00','total_amount','10.00'))
)$$,'22023','invalid purchase detail payment source','mark purchased requires payment source');

select lives_ok($$select public.set_purchasing_purchase_request_status(
 '91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000001','purchased'
)$$,'mark purchased creates linked accounting logs atomically');
select is((select status from public.purchase_requests where id='94000000-0000-4000-8000-000000000001'),'purchased','request status becomes purchased');
select is((select count(*)::int from public.branch_purchase_logs where source_type='central_purchasing' and source_purchase_request_id='94000000-0000-4000-8000-000000000001'),2,'one purchase log is created per request item');
select ok((select branch_id='93000000-0000-4000-8000-000000000001' and organization_id='92000000-0000-4000-8000-000000000001' from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000001'),'company log has correct branch and organization');
select ok((select vendor_name='Company Vendor' and invoice_number='INV-COMP' and before_tax_amount=100.00::numeric and tax_amount=15.00::numeric and amount=115.00::numeric from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000001'),'company log copies exact financial values');
select ok((select payment_status='company_paid' from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000001'),'company source becomes company_paid, not reimbursed');
select ok((select vendor_name='Personal Vendor' and invoice_number='INV-PERS' and before_tax_amount=20.00::numeric and tax_amount=3.00::numeric and amount=23.00::numeric and payment_status='unpaid' from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000002'),'personal log copies values and starts unpaid');

select throws_ok($$insert into public.branch_purchase_logs(organization_id,branch_id,category,item_name,quantity,amount,vendor_name,purchase_date,payment_status,source_type,source_purchase_request_id,source_purchase_request_item_id,created_by)
values('92000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001','kitchen','Duplicate item',1,1,'Vendor',current_date,'unpaid','central_purchasing','94000000-0000-4000-8000-000000000001','95000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000002')$$,'23505',null,'duplicate central purchasing source item is blocked by unique index');

insert into public.branch_purchase_logs(organization_id,branch_id,category,item_name,quantity,amount,vendor_name,purchase_date,payment_status,source_type,source_purchase_request_id,source_purchase_request_item_id,created_by)
values('92000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001','kitchen','Conflicting item',1,1,'Vendor',current_date,'unpaid','central_purchasing','94000000-0000-4000-8000-000000000004','95000000-0000-4000-8000-000000000004','91000000-0000-4000-8000-000000000002');
select throws_ok($$select public.set_purchasing_purchase_request_status(
 '91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000003','purchased',
 jsonb_build_array(jsonb_build_object('item_id','95000000-0000-4000-8000-000000000004','vendor_name','Conflict Vendor','before_tax_amount','10.00','tax_amount','0.00','total_amount','10.00','payment_source','personal'))
)$$,'40001','purchase log conflicts with current workflow state','source conflict aborts purchased transition');
select is((select status from public.purchase_requests where id='94000000-0000-4000-8000-000000000003'),'processing','conflict leaves request processing');

select throws_ok($$select public.update_branch_purchase_log(
 '91000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001',
 (select id from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000002'),1,'Trying to edit central log',
 jsonb_build_object('category','kitchen','item_name','Changed','quantity','1','before_tax_amount','1.00','tax_amount','0.00','purchase_date',current_date,'vendor_name','Vendor')
)$$,'55000','central purchasing purchase logs are source managed','generic edit of central log is denied');
select throws_ok($$select public.soft_delete_branch_purchase_log(
 '91000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001',
 (select id from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000002'),1,'wrong_entry','Central logs are source managed'
)$$,'55000','central purchasing purchase logs are source managed','generic delete of central log is denied');
select throws_ok($$select public.update_branch_purchase_log_payment_status(
 '91000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001',
 (select id from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000002'),'reimbursed','Paid'
)$$,'55000','central purchasing purchase logs are source managed','generic payment mutation of central log is denied');

select throws_ok($$select public.reimburse_purchasing_purchase_request_item('91000000-0000-4000-8000-000000000003','92000000-0000-4000-8000-000000000001','95000000-0000-4000-8000-000000000002','Inactive')$$,'42501','purchasing access denied','inactive Purchasing cannot reimburse');
select throws_ok($$select public.reimburse_purchasing_purchase_request_item('91000000-0000-4000-8000-000000000005','92000000-0000-4000-8000-000000000001','95000000-0000-4000-8000-000000000002','Foreign')$$,'42501','purchasing access denied','cross-org Purchasing cannot reimburse');
select throws_ok($$select public.reimburse_purchasing_purchase_request_item('91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','95000000-0000-4000-8000-000000000001','Company')$$,'22023','purchase request item cannot be reimbursed','company paid item cannot be reimbursed');
select lives_ok($$select public.reimburse_purchasing_purchase_request_item('91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','95000000-0000-4000-8000-000000000002','Paid personally')$$,'authorized Purchasing reimburses personal central item');
select ok((select payment_status='reimbursed' and reimbursement_note='Paid personally' and reimbursed_at is not null and reimbursed_by='91000000-0000-4000-8000-000000000002' from public.branch_purchase_logs where source_purchase_request_item_id='95000000-0000-4000-8000-000000000002'),'personal central log records reimbursement state');
select lives_ok($$select public.reimburse_purchasing_purchase_request_item('91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','95000000-0000-4000-8000-000000000002','Again')$$,'already reimbursed central item is idempotently readable');

with purchased_payload as (
  select public.list_purchasing_purchase_requests('91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','purchased') as payload
)
select is(
  (
    select jsonb_path_query_first(
      payload,
      '$.purchase_requests[*].items[*] ? (@.id == "95000000-0000-4000-8000-000000000002").purchase_log_payment_status'
    ) #>> '{}'
    from purchased_payload
  ),
  'reimbursed',
  'purchase history read model reflects linked log reimbursement status'
);
select is((select count(*)::int from public.list_purchasing_purchase_logs('91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001',null,'company_paid',null,null,null)),1,'Purchasing log filter includes company_paid');
select is((select count(*)::int from public.list_managed_purchase_logs('91000000-0000-4000-8000-000000000004','92000000-0000-4000-8000-000000000001',null,null,'company_paid',null,null)),1,'manager Purchase Log filter includes company_paid source-managed log');

set local role service_role;
select lives_ok($$select * from public.create_branch_purchase_log(
 '91000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Manual editable','quantity','1','before_tax_amount','10.00','tax_amount','0.00','purchase_date',current_date,'payment_status','unpaid')
)$$,'manual Purchase Log creation still works');
reset role;
select lives_ok($$select * from public.update_branch_purchase_log(
 '91000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001',
 (select id from public.branch_purchase_logs where item_name='Manual editable'),1,'Correcting manual row',
 jsonb_build_object('category','kitchen','item_name','Manual edited','quantity','1','before_tax_amount','11.00','tax_amount','0.00','purchase_date',current_date,'vendor_name','Manual Vendor')
)$$,'manual Purchase Log edit still works');
select lives_ok($$select * from public.soft_delete_branch_purchase_log(
 '91000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001',
 (select id from public.branch_purchase_logs where item_name='Manual edited'),2,'wrong_entry','Manual wrong entry'
)$$,'manual Purchase Log delete still works');

with purchased_payload as (
  select public.list_purchasing_purchase_requests('91000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000001','purchased') as payload
)
select is(
  (
    select jsonb_path_query_first(
      payload,
      '$.purchase_requests[*] ? (@.id == "94000000-0000-4000-8000-000000000005").items[0].payment_source'
    ) #>> '{}'
    from purchased_payload
  ),
  null,
  'historical purchased item with null payment_source remains readable'
);

select * from finish();
rollback;
