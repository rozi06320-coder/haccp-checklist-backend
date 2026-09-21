begin;
select plan(88);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1f000000-0000-4000-8000-000000000001'::uuid,
 '1f000000-0000-4000-8000-000000000002',
 '1f000000-0000-4000-8000-000000000003',
 '1f000000-0000-4000-8000-000000000004',
 '1f000000-0000-4000-8000-000000000005',
 '1f000000-0000-4000-8000-000000000006'
]) id;
update public.profiles set full_name=case id
 when '1f000000-0000-4000-8000-000000000001' then 'Purchase Supervisor'
 when '1f000000-0000-4000-8000-000000000002' then 'Other Purchase Supervisor'
 when '1f000000-0000-4000-8000-000000000004' then 'Modern Purchase Supervisor'
 when '1f000000-0000-4000-8000-000000000005' then 'Purchasing Only'
 when '1f000000-0000-4000-8000-000000000006' then 'Maintenance Only'
 else 'Purchase Manager' end,
 must_change_password=false
where id in (
 '1f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000002',
 '1f000000-0000-4000-8000-000000000003',
 '1f000000-0000-4000-8000-000000000004',
 '1f000000-0000-4000-8000-000000000005',
 '1f000000-0000-4000-8000-000000000006'
);
insert into public.organizations(id,name,slug)
values('2f000000-0000-4000-8000-000000000001','Purchase Org','purchase-org');
insert into public.branches(id,organization_id,name,code,timezone)
values
 ('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Purchase Branch','PB','Asia/Riyadh'),
 ('3f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','Other Purchase Branch','OPB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003','organization_manager');
insert into public.purchasing_memberships(organization_id,user_id,active,created_by,updated_by)
values('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000005',true,'1f000000-0000-4000-8000-000000000003','1f000000-0000-4000-8000-000000000003');
insert into public.maintenance_memberships(organization_id,user_id,active,created_by)
values('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000006',true,'1f000000-0000-4000-8000-000000000003');
insert into public.branch_memberships(branch_id,user_id,role)
values
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','branch_manager'),
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000002','branch_manager'),
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values
 ('5f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','Purchase Company'),
 ('5f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000002','Purchase Company');
insert into public.branch_operational_teams(id,organization_id,branch_id,name,active)
values('6f000000-0000-4000-8000-000000000004','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','Modern Purchase Team',true);
insert into public.branch_operational_team_supervisors(organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by)
values('2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','6f000000-0000-4000-8000-000000000004','1f000000-0000-4000-8000-000000000004','primary','1f000000-0000-4000-8000-000000000004');

select has_table('public','branch_purchase_logs','branch purchase logs table exists');
select has_column('public','branch_purchase_logs','invoice_storage_path','purchase logs store invoice storage path');
select has_column('public','branch_purchase_logs','invoice_number','purchase logs store optional vendor invoice number');
select has_column('public','branch_purchase_logs','payment_status','purchase logs store payment status');
select has_column('public','branch_purchase_logs','before_tax_amount','purchase logs store before tax amount');
select has_column('public','branch_purchase_logs','tax_amount','purchase logs store tax amount');
select has_column('public','branch_purchase_logs','revision','purchase logs carry optimistic concurrency revision');
select has_column('public','branch_purchase_logs','deleted_at','purchase logs support soft delete timestamp');
select has_column('public','branch_purchase_logs','delete_reason','purchase logs store soft delete reason');
select has_table('public','branch_purchase_log_events','purchase log audit event table exists');
select hasnt_column('public','branch_purchase_logs','total_amount','purchase logs do not store a duplicate total amount');
select ok((select not public and file_size_limit=5242880 and allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf'] from storage.buckets where id='branch-purchase-invoices'),'purchase invoice bucket is private and bounded');
select ok(not has_function_privilege('authenticated','public.list_branch_purchase_logs(uuid,uuid)','execute')
 and has_function_privilege('service_role','public.list_branch_purchase_logs(uuid,uuid)','execute'),
 'purchase log list RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.create_branch_purchase_log(uuid,uuid,jsonb)','execute')
 and has_function_privilege('service_role','public.create_branch_purchase_log(uuid,uuid,jsonb)','execute'),
 'purchase log create RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text)','execute')
 and has_function_privilege('service_role','public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text)','execute'),
 'purchase log payment RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb)','execute')
 and has_function_privilege('service_role','public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb)','execute'),
 'purchase log edit RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text)','execute')
 and has_function_privilege('service_role','public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text)','execute'),
 'purchase log soft delete RPC is service-role only');

select is((select count(*)::int from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')),
 0,'purchase log list returns empty before entries exist');
select lives_ok($$insert into public.branch_purchase_logs(
 organization_id,branch_id,supervisor_team_id,category,item_name,quantity,amount,purchase_date,created_by
) values (
 '2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 '5f000000-0000-4000-8000-000000000001','kitchen','Historical Amount Only',1,150,'2026-08-07','1f000000-0000-4000-8000-000000000001'
)$$,'historical amount-only rows with null new monetary fields remain valid');
delete from public.branch_purchase_logs where item_name='Historical Amount Only';

set local role service_role;
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 jsonb_build_object(
  'category','kitchen',
  'item_name','  Receipt Book  ',
  'quantity','2',
  'amount','45.50',
  'vendor_name','   ',
  'purchase_date','2026-08-08',
  'notes','  Needed today  ',
  'payment_status','unpaid',
  'invoice_number',' INV-2026-001 ',
  'invoice_storage_path','branches/3f000000-0000-4000-8000-000000000001/purchase-logs/9f000000-0000-4000-8000-000000000001/receipt.pdf',
  'invoice_original_name',' receipt.pdf '
 ))$$,'supervisor creates own branch purchase log');
reset role;

select is((select item_name from public.branch_purchase_logs limit 1),'Receipt Book','item name is trimmed');
select is((select vendor_name from public.branch_purchase_logs limit 1),'N/A','blank vendor defaults to N/A');
select is((select amount from public.branch_purchase_logs limit 1),45.50::numeric,'amount is stored');
select ok((select before_tax_amount is null and tax_amount is null from public.branch_purchase_logs limit 1),'legacy amount-only payload does not fabricate tax breakdown');
select is((select invoice_original_name from public.branch_purchase_logs limit 1),'receipt.pdf','invoice name is stored');
select is((select invoice_number from public.branch_purchase_logs limit 1),'INV-2026-001','invoice number is trimmed and stored');
select is((select invoice_number from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001') limit 1),'INV-2026-001','supervisor list returns invoice number');
select is((select revision from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001') limit 1),1::bigint,'supervisor list returns revision');
select is((select count(*)::int from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')),
 1,'purchase log list restores saved entries');

create temp table purchase_log_test_ids as
select id as purchase_log_id from public.branch_purchase_logs limit 1;
grant select on purchase_log_test_ids to service_role;

set local role service_role;
select lives_ok($$select * from public.update_branch_purchase_log_payment_status(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 (select purchase_log_id from purchase_log_test_ids limit 1),
 'reimbursed',
 '  Paid from petty cash  '
)$$,'supervisor marks purchase reimbursed');
reset role;

select ok((select payment_status='reimbursed' and reimbursement_note='Paid from petty cash' and reimbursed_at is not null and reimbursed_by='1f000000-0000-4000-8000-000000000001'
 from public.branch_purchase_logs limit 1),'reimbursement state is persisted');
select is((select invoice_number from public.branch_purchase_logs where id=(select purchase_log_id from purchase_log_test_ids limit 1)),'INV-2026-001','payment update preserves invoice number');
select is((select reason_note from public.branch_purchase_log_events where event_type='payment_status_changed' and purchase_log_id=(select purchase_log_id from purchase_log_test_ids limit 1) order by created_at desc limit 1),null,'payment status audit event does not require reimbursement note as reason');

set local role service_role;
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Short Note Purchase','quantity','1','amount','5','purchase_date','2026-08-08')
)$$,'supervisor creates purchase for short reimbursement note regression');
reset role;
create temp table purchase_log_short_note_ids as
select id as purchase_log_id from public.branch_purchase_logs where item_name='Short Note Purchase' limit 1;
grant select on purchase_log_short_note_ids to service_role;
set local role service_role;
select lives_ok($$select * from public.update_branch_purchase_log_payment_status(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 (select purchase_log_id from purchase_log_short_note_ids limit 1),
 'reimbursed',
 'Paid'
)$$,'payment update with short reimbursement note succeeds');
reset role;
select is((select reimbursement_note from public.branch_purchase_logs where id=(select purchase_log_id from purchase_log_short_note_ids limit 1)),'Paid','short reimbursement note remains on purchase row');
select ok((select reason_note is null and new_values->>'reimbursement_note'='Paid' from public.branch_purchase_log_events where event_type='payment_status_changed' and purchase_log_id=(select purchase_log_id from purchase_log_short_note_ids limit 1) order by created_at desc limit 1),'payment audit snapshot preserves short reimbursement note while event reason note stays null');

select ok(not has_function_privilege('authenticated','public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date)','execute')
 and has_function_privilege('service_role','public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date)','execute'),
 'manager purchase list RPC is service-role only');

select is((select count(*)::int from public.list_managed_purchase_logs(
 '1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001',null,null,'unpaid',null,null)),
 0,'manager list filters out reimbursed purchases without mutation authority');
select is((select invoice_number from public.list_managed_purchase_logs(
 '1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001',null,null,'reimbursed',null,null) where item_name='Receipt Book' limit 1),'INV-2026-001','manager list returns invoice number');

select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','bad','item_name','Book','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 '22023','invalid purchase log payload','invalid category is rejected');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','0','amount','1','purchase_date','2026-08-08'))$$,
 '22023','invalid purchase log payload','quantity must be positive');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','1','amount','-1','purchase_date','2026-08-08'))$$,
 '22023','invalid purchase log payload','negative amount is rejected');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','1','before_tax_amount','1.001','tax_amount','0','purchase_date','2026-08-08'))$$,
 '22023','invalid purchase log payload','excessive decimal places are rejected');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','1','before_tax_amount','10.00','tax_amount','1.50','amount','10.00','purchase_date','2026-08-08'))$$,
 '22023','invalid purchase log payload','client amount cannot contradict calculated total');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Taxed Purchase','quantity','1','before_tax_amount','10.00','tax_amount','1.50','purchase_date','2026-08-08'))$$,
 'before tax and tax payload is accepted');
select ok((select amount=11.50::numeric and before_tax_amount=10.00::numeric and tax_amount=1.50::numeric from public.branch_purchase_logs where item_name='Taxed Purchase'),'calculated total is stored as amount');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Zero Tax Purchase','quantity','1','before_tax_amount','25.00','tax_amount','0','purchase_date','2026-08-08'))$$,
 'explicit zero tax breakdown is accepted');
select ok((select amount=25.00::numeric and before_tax_amount=25.00::numeric and tax_amount=0::numeric from public.branch_purchase_logs where item_name='Zero Tax Purchase'),'zero tax breakdown stores amount as before tax plus tax');
select throws_ok($$insert into public.branch_purchase_logs(
 organization_id,branch_id,supervisor_team_id,category,item_name,quantity,amount,before_tax_amount,tax_amount,purchase_date,created_by
) values (
 '2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 '5f000000-0000-4000-8000-000000000001','kitchen','Bad Direct Precision',1,1.001,1.001,0,'2026-08-08','1f000000-0000-4000-8000-000000000001'
)$$,'23514',null,'database constraint rejects direct overprecision monetary values');
select throws_ok($$insert into public.branch_purchase_logs(
 organization_id,branch_id,supervisor_team_id,category,item_name,quantity,amount,before_tax_amount,tax_amount,purchase_date,created_by
) values (
 '2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 '5f000000-0000-4000-8000-000000000001','kitchen','Bad Direct Total',1,12,10,1,'2026-08-08','1f000000-0000-4000-8000-000000000001'
)$$,'23514',null,'database constraint rejects inconsistent direct monetary totals');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','stationery','item_name','Pens','quantity','1','amount','1','purchase_date','2026-08-08','invoice_number','   '))$$,
 'stationery category is accepted with blank invoice number');
select ok((select invoice_number is null from public.branch_purchase_logs where item_name='Pens'),'blank invoice number normalizes to null');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','equipment','item_name','Scale','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 'equipment category is accepted');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','food_item','item_name','Rice','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 'food item category is accepted');
select is((select count(*)::int from public.branch_purchase_logs where category='food_item'),1,'Food Item category is stored canonically');
select ok((select invoice_number is null from public.branch_purchase_logs where item_name='Scale'),'missing invoice number remains null for old clients');
select is((select count(*)::int from public.list_managed_purchase_logs(
 '1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001',null,'food_item',null,null,null)),
 1,'manager can filter read-only Purchase Logs by Food Item');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000004','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Modern Supervisor Purchase','quantity','1','amount','12.00','purchase_date','2026-08-08'))$$,
 'modern branch supervisor without legacy team can create purchase log');
select ok((select supervisor_team_id is null from public.branch_purchase_logs where item_name='Modern Supervisor Purchase'),'modern purchase log stores null legacy supervisor team attribution');
select is((select count(*)::int from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000004','3f000000-0000-4000-8000-000000000001') where item_name='Modern Supervisor Purchase'),
 1,'modern branch supervisor can list their branch purchase log');
select is((select count(*) from public.branch_supervisor_teams where supervisor_user_id='1f000000-0000-4000-8000-000000000004'),0::bigint,'purchase log compatibility does not create a legacy supervisor team');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1f000000-0000-4000-8000-000000000004' and operational_team_id='6f000000-0000-4000-8000-000000000004' and active),1::bigint,'canonical supervisor assignment remains intact');
select throws_ok($$select * from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000004','3f000000-0000-4000-8000-000000000002')$$,'42501','purchase log access denied','modern supervisor cannot list another branch');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000005','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Purchasing Bypass','quantity','1','amount','1','purchase_date','2026-08-08'))$$,'42501','purchase log access denied','purchasing-only user cannot create Purchase Log');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000006','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Maintenance Bypass','quantity','1','amount','1','purchase_date','2026-08-08'))$$,'42501','purchase log access denied','maintenance-only user cannot create Purchase Log');
create temp table modern_purchase_log_ids as
select id as purchase_log_id, revision as purchase_revision
from public.branch_purchase_logs
where item_name='Modern Supervisor Purchase'
limit 1;
grant select on modern_purchase_log_ids to service_role;
set local role service_role;
select lives_ok($$select * from public.update_branch_purchase_log_payment_status(
 '1f000000-0000-4000-8000-000000000004',
 '3f000000-0000-4000-8000-000000000001',
 (select purchase_log_id from modern_purchase_log_ids limit 1),
 'reimbursed',
 'Modern supervisor paid'
)$$,'modern null-attribution purchase log can be reimbursed');
reset role;
select ok((select supervisor_team_id is null and payment_status='reimbursed' and reimbursed_by='1f000000-0000-4000-8000-000000000004' from public.branch_purchase_logs where id=(select purchase_log_id from modern_purchase_log_ids limit 1)),'modern reimbursement preserves null legacy team and records actor');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000004','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Modern Editable Purchase','quantity','1','amount','14.00','purchase_date','2026-08-08'))$$,
 'modern branch supervisor creates second editable purchase log');
create temp table modern_editable_purchase_log_ids as
select id as purchase_log_id, revision as purchase_revision
from public.branch_purchase_logs
where item_name='Modern Editable Purchase'
limit 1;
grant select on modern_editable_purchase_log_ids to service_role;
set local role service_role;
select lives_ok($$select * from public.update_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000004',
 '3f000000-0000-4000-8000-000000000001',
 (select purchase_log_id from modern_editable_purchase_log_ids limit 1),
 (select purchase_revision from modern_editable_purchase_log_ids limit 1),
 'Correcting modern purchase amount',
 jsonb_build_object('category','kitchen','item_name','Modern Editable Purchase Edited','quantity','2','before_tax_amount','20.00','tax_amount','3.00','amount','23.00','purchase_date','2026-08-09')
)$$,'modern null-attribution unpaid purchase log can be edited');
reset role;
select ok((select supervisor_team_id is null and revision=2 and amount=23.00::numeric from public.branch_purchase_logs where item_name='Modern Editable Purchase Edited'),'modern edit keeps null legacy team and increments revision');
select ok((select exists(select 1 from public.branch_purchase_log_events where purchase_log_id=(select purchase_log_id from modern_editable_purchase_log_ids limit 1) and event_type='edited')),'modern edit writes an audit event');
set local role service_role;
select lives_ok($$select * from public.soft_delete_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000004',
 '3f000000-0000-4000-8000-000000000001',
 (select purchase_log_id from modern_editable_purchase_log_ids limit 1),
 2,
 'wrong_entry',
 'Wrong modern branch purchase entry'
)$$,'modern null-attribution unpaid purchase log can be soft deleted');
reset role;
select is((select count(*)::int from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000004','3f000000-0000-4000-8000-000000000001') where item_name='Modern Editable Purchase Edited'),0,'soft-deleted modern purchase is excluded from active supervisor list');

create temp table purchase_log_edit_ids as
select
 (select id from public.branch_purchase_logs where item_name='Taxed Purchase' limit 1) as edit_purchase_log_id,
 (select revision from public.branch_purchase_logs where item_name='Taxed Purchase' limit 1) as edit_revision,
 (select id from public.branch_purchase_logs where item_name='Zero Tax Purchase' limit 1) as delete_purchase_log_id,
 (select revision from public.branch_purchase_logs where item_name='Zero Tax Purchase' limit 1) as delete_revision;
grant select on purchase_log_edit_ids to service_role;

set local role service_role;
select lives_ok($$select * from public.update_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 (select edit_purchase_log_id from purchase_log_edit_ids limit 1),
 (select edit_revision from purchase_log_edit_ids limit 1),
 'Correcting the supplier invoice amount',
 jsonb_build_object('category','kitchen','item_name','Taxed Purchase Edited','quantity','2','before_tax_amount','20.00','tax_amount','3.00','amount','23.00','vendor_name','Edited Vendor','purchase_date','2026-08-09','invoice_number','INV-EDIT-001','notes','Corrected record')
)$$,'unpaid purchase log can be edited with a correction reason');
reset role;
select ok((select item_name='Taxed Purchase Edited' and amount=23.00::numeric and revision=2 from public.branch_purchase_logs where item_name='Taxed Purchase Edited'),'edit updates monetary fields and increments revision');
select ok((select old_values->>'item_name'='Taxed Purchase' and new_values->>'item_name'='Taxed Purchase Edited' from public.branch_purchase_log_events where purchase_log_id=(select edit_purchase_log_id from purchase_log_edit_ids limit 1) and event_type='edited' and reason_code='correction' limit 1),'edit audit event records old and new values');
select throws_ok($$select * from public.update_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 (select id from public.branch_purchase_logs where item_name='Taxed Purchase Edited' limit 1),
 1,
 'Trying to reuse a stale revision',
 jsonb_build_object('category','kitchen','item_name','Stale','quantity','1','before_tax_amount','1.00','tax_amount','0.00','amount','1.00','purchase_date','2026-08-09')
)$$,'40001','purchase log changed','stale edit revision is rejected');

set local role service_role;
select lives_ok($$select * from public.soft_delete_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 (select delete_purchase_log_id from purchase_log_edit_ids limit 1),
 (select delete_revision from purchase_log_edit_ids limit 1),
 'wrong_entry',
 'Wrong branch purchase entry'
)$$,'unpaid purchase log can be soft deleted with a reason');
reset role;
select is((select count(*)::int from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001') where item_name='Zero Tax Purchase'),0,'soft-deleted purchase is excluded from active supervisor list');
select ok((select deleted_at is not null and delete_reason='wrong_entry' and revision=2 from public.branch_purchase_logs where item_name='Zero Tax Purchase'),'soft-deleted purchase row remains preserved with deletion metadata');
select ok((select old_values->>'deleted_at' is null and new_values->>'delete_reason'='wrong_entry' from public.branch_purchase_log_events where event_type='soft_deleted' limit 1),'soft delete audit event records deletion metadata');

select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Long Invoice','quantity','1','amount','1','purchase_date','2026-08-08','invoice_number',repeat('A',121)))$$,
 '22023','invalid maintenance purchase payload','overlong invoice number is rejected');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000002','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 'same-branch supervisor shares Purchase Log write access');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000003','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 '42501','purchase log access denied','manager denied');

select throws_ok($$select * from public.update_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 (select purchase_log_id from purchase_log_test_ids limit 1),
 (select revision from public.branch_purchase_logs where id=(select purchase_log_id from purchase_log_test_ids limit 1)),
 'Trying to edit a reimbursed purchase',
 jsonb_build_object('category','kitchen','item_name','Readonly','quantity','1','before_tax_amount','1.00','tax_amount','0.00','amount','1.00','purchase_date','2026-08-08')
)$$,'55000','reimbursed purchase logs are read only','reimbursed purchase edit is rejected');
select throws_ok($$select * from public.soft_delete_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001',
 '3f000000-0000-4000-8000-000000000001',
 (select purchase_log_id from purchase_log_test_ids limit 1),
 (select revision from public.branch_purchase_logs where id=(select purchase_log_id from purchase_log_test_ids limit 1)),
 'duplicate',
 null
)$$,'55000','reimbursed purchase logs are read only','reimbursed purchase soft delete is rejected');

set local role authenticated;
select throws_ok($$insert into public.branch_purchase_logs(
 organization_id,branch_id,supervisor_team_id,category,item_name,quantity,amount,purchase_date,created_by
) values (
 '2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 '5f000000-0000-4000-8000-000000000001','kitchen','Book',1,1,'2026-08-08','1f000000-0000-4000-8000-000000000001'
)$$,'42501',null,'direct authenticated writes are denied');
reset role;

select * from finish();
rollback;
