begin;
select plan(29);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1f000000-0000-4000-8000-000000000001'::uuid,
 '1f000000-0000-4000-8000-000000000002',
 '1f000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name=case id
 when '1f000000-0000-4000-8000-000000000001' then 'Purchase Supervisor'
 when '1f000000-0000-4000-8000-000000000002' then 'Other Purchase Supervisor'
 else 'Purchase Manager' end,
 must_change_password=false
where id in (
 '1f000000-0000-4000-8000-000000000001',
 '1f000000-0000-4000-8000-000000000002',
 '1f000000-0000-4000-8000-000000000003'
);
insert into public.organizations(id,name,slug)
values('2f000000-0000-4000-8000-000000000001','Purchase Org','purchase-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Purchase Branch','PB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)
values
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','branch_manager'),
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values
 ('5f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','Purchase Company'),
 ('5f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000002','Purchase Company');

select has_table('public','branch_purchase_logs','branch purchase logs table exists');
select has_column('public','branch_purchase_logs','invoice_storage_path','purchase logs store invoice storage path');
select has_column('public','branch_purchase_logs','payment_status','purchase logs store payment status');
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

select is((select count(*)::int from public.list_branch_purchase_logs(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')),
 0,'purchase log list returns empty before entries exist');

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
  'invoice_storage_path','branches/3f000000-0000-4000-8000-000000000001/purchase-logs/9f000000-0000-4000-8000-000000000001/receipt.pdf',
  'invoice_original_name',' receipt.pdf '
 ))$$,'supervisor creates own branch purchase log');
reset role;

select is((select item_name from public.branch_purchase_logs limit 1),'Receipt Book','item name is trimmed');
select is((select vendor_name from public.branch_purchase_logs limit 1),'N/A','blank vendor defaults to N/A');
select is((select amount from public.branch_purchase_logs limit 1),45.50::numeric,'amount is stored');
select is((select invoice_original_name from public.branch_purchase_logs limit 1),'receipt.pdf','invoice name is stored');
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

select ok(not has_function_privilege('authenticated','public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date)','execute')
 and has_function_privilege('service_role','public.list_managed_purchase_logs(uuid,uuid,uuid,text,text,date,date)','execute'),
 'manager purchase list RPC is service-role only');

select is((select count(*)::int from public.list_managed_purchase_logs(
 '1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001',null,null,'unpaid',null,null)),
 0,'manager list filters out reimbursed purchases without mutation authority');

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
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','stationery','item_name','Pens','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 'stationery category is accepted');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','equipment','item_name','Scale','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 'equipment category is accepted');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','food_item','item_name','Rice','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 'food item category is accepted');
select is((select count(*)::int from public.branch_purchase_logs where category='food_item'),1,'Food Item category is stored canonically');
select is((select count(*)::int from public.list_managed_purchase_logs(
 '1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001',null,'food_item',null,null,null)),
 1,'manager can filter read-only Purchase Logs by Food Item');
select lives_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000002','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 'same-branch supervisor shares Purchase Log write access');
select throws_ok($$select * from public.create_branch_purchase_log(
 '1f000000-0000-4000-8000-000000000003','3f000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','kitchen','item_name','Book','quantity','1','amount','1','purchase_date','2026-08-08'))$$,
 '42501','purchase log access denied','manager denied');

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
