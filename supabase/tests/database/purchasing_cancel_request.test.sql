begin;
select plan(34);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('a1000000-0000-4000-8000-000000000001'::uuid, 'cancel-supervisor@example.invalid'),
  ('a1000000-0000-4000-8000-000000000002'::uuid, 'cancel-buyer@example.invalid'),
  ('a1000000-0000-4000-8000-000000000003'::uuid, 'cancel-manager@example.invalid'),
  ('a1000000-0000-4000-8000-000000000004'::uuid, 'cancel-foreign-buyer@example.invalid'),
  ('a1000000-0000-4000-8000-000000000005'::uuid, 'cancel-inactive-buyer@example.invalid')
) user_data(id,email);

update public.profiles
set full_name = 'Cancellation Test User', must_change_password = false
where id::text like 'a1000000-%';

insert into public.organizations(id,name,slug) values
 ('a2000000-0000-4000-8000-000000000001','Cancellation Org A','cancellation-org-a'),
 ('a2000000-0000-4000-8000-000000000002','Cancellation Org B','cancellation-org-b');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('a3000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','Cancellation Branch A','CBA','Asia/Riyadh'),
 ('a3000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000002','Cancellation Branch B','CBB','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','branch_manager');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('a2000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000003','organization_manager');
insert into public.purchasing_memberships(organization_id,user_id,active,created_by,updated_by) values
 ('a2000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002',true,'a1000000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000003'),
 ('a2000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000005',false,'a1000000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000003'),
 ('a2000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000004',true,'a1000000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000003');

insert into public.purchase_requests(id,organization_id,branch_id,requested_by,category,status,notes) values
 ('a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','kitchen','submitted','submitted request'),
 ('a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','kitchen','processing','processing request'),
 ('a4000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','kitchen','purchased','purchased request'),
 ('a4000000-0000-4000-8000-000000000004','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','kitchen','received','received request'),
 ('a4000000-0000-4000-8000-000000000005','a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','kitchen','processing','accounting conflict'),
 ('a4000000-0000-4000-8000-000000000006','a2000000-0000-4000-8000-000000000002','a3000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','kitchen','submitted','other org request');

insert into public.purchase_request_items(id,purchase_request_id,item_name,quantity,unit,sort_order,product_photo_storage_path,product_photo_original_name,product_photo_mime_type,product_photo_size_bytes,product_photo_uploaded_at,product_photo_uploaded_by) values
 ('a5000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000001','Submitted item',2,'box',1,'branches/a3000000-0000-4000-8000-000000000001/purchase-requests/a4000000-0000-4000-8000-000000000001/items/a5000000-0000-4000-8000-000000000001/product-photo.jpg','product.jpg','image/jpeg',100,now(),'a1000000-0000-4000-8000-000000000001'),
 ('a5000000-0000-4000-8000-000000000002','a4000000-0000-4000-8000-000000000002','Processing item',1,'pcs',1,null,null,null,null,null,null),
 ('a5000000-0000-4000-8000-000000000003','a4000000-0000-4000-8000-000000000005','Conflict item',1,'pcs',1,null,null,null,null,null,null);
insert into public.purchase_request_item_attachments(id,purchase_request_item_id,storage_path,original_filename,mime_type,size_bytes,position)
values('a6000000-0000-4000-8000-000000000001','a5000000-0000-4000-8000-000000000001','organizations/a2000000-0000-4000-8000-000000000001/purchase-requests/a4000000-0000-4000-8000-000000000001/items/a5000000-0000-4000-8000-000000000001/receipt.pdf','receipt.pdf','application/pdf',100,1);
insert into public.purchase_request_creation_idempotency(actor_user_id,idempotency_key,request_hash,purchase_request_id,response_json)
values('a1000000-0000-4000-8000-000000000001','a7000000-0000-4000-8000-000000000001',repeat('a',64),'a4000000-0000-4000-8000-000000000001','{}');
insert into public.branch_purchase_logs(organization_id,branch_id,category,item_name,quantity,amount,vendor_name,purchase_date,payment_status,source_type,source_purchase_request_id,source_purchase_request_item_id,created_by)
values('a2000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','kitchen','Conflict item',1,10,'Vendor',current_date,'unpaid','central_purchasing','a4000000-0000-4000-8000-000000000005','a5000000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000002');

select has_column('public','purchase_requests','cancelled_at','request stores cancellation time');
select has_column('public','purchase_requests','cancelled_by','request stores cancellation actor');
select ok((select pg_get_constraintdef(oid) like '%REFERENCES profiles(id) ON DELETE RESTRICT%' from pg_constraint where conrelid='public.purchase_requests'::regclass and contype='f' and pg_get_constraintdef(oid) like 'FOREIGN KEY (cancelled_by)%'),'cancellation actor uses a restrictive profile FK');
select is((select prosecdef from pg_proc where oid='public.cancel_purchasing_purchase_request(uuid,uuid,uuid)'::regprocedure),true,'cancel RPC is SECURITY DEFINER');
select is((select proconfig from pg_proc where oid='public.cancel_purchasing_purchase_request(uuid,uuid,uuid)'::regprocedure),array['search_path=""'],'cancel RPC has empty search_path');
select ok(has_function_privilege('service_role','public.cancel_purchasing_purchase_request(uuid,uuid,uuid)','execute'),'service role can execute cancel RPC');
select ok(not has_function_privilege('authenticated','public.cancel_purchasing_purchase_request(uuid,uuid,uuid)','execute'),'authenticated cannot execute cancel RPC');
select ok(not has_function_privilege('anon','public.cancel_purchasing_purchase_request(uuid,uuid,uuid)','execute'),'anon cannot execute cancel RPC');
select ok(not has_function_privilege('public','public.cancel_purchasing_purchase_request(uuid,uuid,uuid)','execute'),'PUBLIC cannot execute cancel RPC');

select lives_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000001')$$,'submitted request can be cancelled');
select is((select status from public.purchase_requests where id='a4000000-0000-4000-8000-000000000001'),'cancelled','submitted becomes cancelled');
select ok((select cancelled_at is not null and cancelled_by='a1000000-0000-4000-8000-000000000002' from public.purchase_requests where id='a4000000-0000-4000-8000-000000000001'),'cancellation attribution is recorded');
select is((select count(*)::int from public.purchase_requests where id='a4000000-0000-4000-8000-000000000001'),1,'request row remains');
select is((select count(*)::int from public.purchase_request_items where purchase_request_id='a4000000-0000-4000-8000-000000000001'),1,'item row remains');
select ok((select product_photo_storage_path is not null from public.purchase_request_items where id='a5000000-0000-4000-8000-000000000001'),'product photo metadata remains');
select is((select count(*)::int from public.purchase_request_item_attachments where purchase_request_item_id='a5000000-0000-4000-8000-000000000001'),1,'attachment metadata remains');
select is((select count(*)::int from public.purchase_request_creation_idempotency where purchase_request_id='a4000000-0000-4000-8000-000000000001'),1,'idempotency row remains');
select is((select count(*)::int from public.branch_purchase_logs where source_purchase_request_id='a4000000-0000-4000-8000-000000000001'),0,'cancellation creates no Purchase Log');

select lives_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000002')$$,'processing request can be cancelled');
select is((select status from public.purchase_requests where id='a4000000-0000-4000-8000-000000000002'),'cancelled','processing becomes cancelled');
select lives_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000002')$$,'already-cancelled retry is idempotent');
select is((select cancelled_by from public.purchase_requests where id='a4000000-0000-4000-8000-000000000002'),'a1000000-0000-4000-8000-000000000002'::uuid,'idempotent retry preserves attribution');
select throws_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000003')$$,'55000','purchase request cannot be cancelled','purchased cannot be cancelled');
select throws_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000004')$$,'55000','purchase request cannot be cancelled','received cannot be cancelled');
select throws_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000005')$$,'55000','purchase request has accounting history','linked accounting history blocks cancellation');
select is((select status from public.purchase_requests where id='a4000000-0000-4000-8000-000000000005'),'processing','accounting conflict leaves request unchanged');
select is((select count(*)::int from public.branch_purchase_logs where source_purchase_request_id='a4000000-0000-4000-8000-000000000005'),1,'existing Purchase Log remains unchanged');

select throws_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000002','a4000000-0000-4000-8000-000000000006')$$,'42501','purchasing access denied','cross-organization buyer is denied');
select throws_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000003','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000005')$$,'42501','purchasing access denied','Manager without Purchasing membership is denied');
select throws_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000005')$$,'42501','purchasing access denied','Supervisor without Purchasing membership is denied');
select throws_ok($$select public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000005','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000005')$$,'42501','purchasing access denied','inactive Purchasing membership is denied');
select ok((select (public.cancel_purchasing_purchase_request('a1000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000001')->'purchase_request'->>'status')='cancelled'),'canonical response accepts cancelled status');
select ok((select cancelled_at is null and cancelled_by is null from public.purchase_requests where id='a4000000-0000-4000-8000-000000000003'),'historical purchased rows remain unattributed and unchanged');
select is((select count(*)::int from public.purchase_requests),6,'soft cancellation deletes no request rows');

select * from finish();
rollback;
