begin;
select plan(54);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@maintenance-phase1.invalid','{}','{}',now(),now()
from unnest(array[
  'a1000000-0000-4000-8000-000000000001'::uuid,
  'a1000000-0000-4000-8000-000000000002',
  'a1000000-0000-4000-8000-000000000003',
  'a1000000-0000-4000-8000-000000000004',
  'a1000000-0000-4000-8000-000000000005',
  'a1000000-0000-4000-8000-000000000006'
]) id;

update public.profiles
set full_name = 'Maintenance Phase 1', must_change_password = false
where id::text like 'a1000000-0000-4000-8000-00000000000%';

insert into public.organizations(id,name,slug) values
  ('b1000000-0000-4000-8000-000000000001','Maintenance Integrity Org','maintenance-integrity-org'),
  ('b1000000-0000-4000-8000-000000000002','Maintenance Foreign Org','maintenance-integrity-foreign');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('c1000000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000001','Maintenance Branch A','MIA','Asia/Riyadh'),
  ('c1000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000001','Maintenance Branch B','MIB','Asia/Riyadh'),
  ('c1000000-0000-4000-8000-000000000003','b1000000-0000-4000-8000-000000000002','Maintenance Foreign','MIF','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('c1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','branch_manager'),
  ('c1000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','branch_manager'),
  ('c1000000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000002','branch_manager');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('b1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000005','organization_manager');
insert into public.maintenance_memberships(organization_id,user_id,active,created_by,updated_by) values
  ('b1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000003',true,'a1000000-0000-4000-8000-000000000005','a1000000-0000-4000-8000-000000000005'),
  ('b1000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000004',true,'a1000000-0000-4000-8000-000000000005','a1000000-0000-4000-8000-000000000005');

select ok(
  has_function_privilege('service_role','public.update_maintenance_issue(uuid,uuid,uuid,text,text,text,bigint,date,text)','execute')
  and not has_function_privilege('authenticated','public.update_maintenance_issue(uuid,uuid,uuid,text,text,text,bigint,date,text)','execute'),
  'revision-aware issue mutation remains backend-only'
);

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  'a1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','d1000000-0000-4000-8000-000000000001','idempotency_key','11000000-0000-4000-8000-000000000001','title','Branch A freezer','category','refrigeration','priority','high')
)$$,'branch Supervisor without a team can create a branch-owned issue');
reset role;
select is((select supervisor_team_id from public.maintenance_issues where id='d1000000-0000-4000-8000-000000000001'),null,'new branch issue has no invented supervisor team');
select is((select revision from public.maintenance_issues where id='d1000000-0000-4000-8000-000000000001'),0::bigint,'issue revision starts at zero');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  'a1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','d1000000-0000-4000-8000-000000000099','idempotency_key','11000000-0000-4000-8000-000000000001','title','Replay','category','other','priority','normal')
)$$,'same branch idempotency replay is accepted');
reset role;
select is((select count(*)::integer from public.maintenance_issues where branch_id='c1000000-0000-4000-8000-000000000001' and idempotency_key='11000000-0000-4000-8000-000000000001'),1,'same branch replay creates one issue');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  'a1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000002',
  jsonb_build_object('issue_id','d1000000-0000-4000-8000-000000000002','idempotency_key','11000000-0000-4000-8000-000000000001','title','Branch B freezer','category','refrigeration','priority','normal')
)$$,'same idempotency key is independent in another branch');
select lives_ok($$select * from public.create_manager_office_maintenance_issue_v2(
  'a1000000-0000-4000-8000-000000000005','b1000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','d1000000-0000-4000-8000-000000000003','idempotency_key','11000000-0000-4000-8000-000000000001','title','Office AC','category','equipment','priority','normal')
)$$,'same idempotency key is independent for office scope');
reset role;
select is((select count(*)::integer from public.maintenance_issues where organization_id='b1000000-0000-4000-8000-000000000001' and idempotency_key='11000000-0000-4000-8000-000000000001'),3,'branch and office scopes do not collide');

select throws_ok($$select * from public.list_supervisor_maintenance_issues_v2('a1000000-0000-4000-8000-000000000002','c1000000-0000-4000-8000-000000000001')$$,'42501','maintenance issue access denied','foreign Supervisor cannot list another branch');
select is((select count(*)::integer from public.list_supervisor_maintenance_issues_v2('a1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001')),1,'authorized branch Supervisor lists branch issue without team ownership');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue_with_photo_v2(
  'a1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','d1000000-0000-4000-8000-000000000004','title','Sink','category','plumbing','priority','normal','before_photos',jsonb_build_array(jsonb_build_object('id','e1000000-0000-4000-8000-000000000001','storage_path','maintenance/d1000000-0000-4000-8000-000000000004/issue/before.jpg','original_filename','before.jpg','mime_type','image/jpeg','size_bytes',1000)))
)$$,'branch Supervisor without a team can create an issue with proof');
reset role;
select is((select count(*)::integer from public.list_maintenance_issue_attachments('a1000000-0000-4000-8000-000000000001',null,array['d1000000-0000-4000-8000-000000000004'::uuid])),1,'branch Supervisor can read branch issue attachments');

set local role service_role;
select lives_ok($$select * from public.update_maintenance_issue(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','in_progress','Started','Technician',0,null,null
)$$,'revision-aware status update succeeds');
reset role;
select is((select revision from public.maintenance_issues where id='d1000000-0000-4000-8000-000000000001'),1::bigint,'accepted update increments revision once');
select throws_ok($$select * from public.update_maintenance_issue('a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','waiting_parts',null,'Technician',0,null,null)$$,'40001','maintenance issue changed','stale issue update conflicts');

set local role service_role;
select lives_ok($$select * from public.update_maintenance_issue(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','in_progress',null,'Technician',1,
  ((statement_timestamp() at time zone 'Asia/Riyadh')::date+1),null
)$$,'initial planned repair date succeeds without change reason');
reset role;
select throws_ok($$select * from public.update_maintenance_issue(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','in_progress',null,'Technician',2,null,null
)$$,'22023','planned repair date change reason required','clearing an existing date requires a reason');
set local role service_role;
select lives_ok($$select * from public.update_maintenance_issue(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','in_progress',null,'Technician',2,null,'Parts arrived'
)$$,'planned repair date can be explicitly cleared with a reason');
select lives_ok($$select * from public.update_maintenance_issue(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','in_progress',null,'Technician',3,
  ((statement_timestamp() at time zone 'Asia/Riyadh')::date+2),null
)$$,'planned repair date can be set again');
reset role;
select throws_ok($$select * from public.update_maintenance_issue(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','in_progress',null,'Technician',4,
  ((statement_timestamp() at time zone 'Asia/Riyadh')::date-1),'Invalid past date'
)$$,'22023','planned repair date is in the past','past planned repair date is rejected');
select is((select count(*)::integer from public.maintenance_issue_updates where issue_id='d1000000-0000-4000-8000-000000000001' and update_kind='repair_schedule_change'),3,'every accepted schedule change has structured history');
select ok((select bool_and(old_planned_repair_date is distinct from new_planned_repair_date) from public.maintenance_issue_updates where issue_id='d1000000-0000-4000-8000-000000000001' and update_kind='repair_schedule_change'),'schedule history stores distinct old/new values');
update public.maintenance_issues
set planned_repair_date = (statement_timestamp() at time zone 'Asia/Riyadh')::date-1
where id = 'd1000000-0000-4000-8000-000000000001';
select throws_ok($$select * from public.update_maintenance_issue(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','resolved','Fixed','Technician',4,
  ((statement_timestamp() at time zone 'Asia/Riyadh')::date-1),null
)$$,'22023','repair proof required to resolve maintenance issue','plain issue update cannot resolve');
select throws_ok($$select * from public.update_maintenance_issue_with_repair_photo(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','resolved','Fixed','[]'::jsonb,'Technician',4,
  ((statement_timestamp() at time zone 'Asia/Riyadh')::date-1),null
)$$,'22023','repair proof required to resolve maintenance issue','repair-photo update rejects an empty proof array');
set local role service_role;
select lives_ok($$select * from public.update_maintenance_issue_with_repair_photo(
  'a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','resolved','Fixed',
  jsonb_build_array(jsonb_build_object('id','e1000000-0000-4000-8000-000000000002','storage_path','maintenance/d1000000-0000-4000-8000-000000000001/repair/after.jpg','original_filename','after.jpg','mime_type','image/jpeg','size_bytes',1000)),
  'Technician',4,((statement_timestamp() at time zone 'Asia/Riyadh')::date-1),null
)$$,'valid repair proof resolves an issue whose unchanged planned date has passed');
reset role;
select ok((select status='resolved' and resolved_at is not null and revision=5 and planned_repair_date=((statement_timestamp() at time zone 'Asia/Riyadh')::date-1) from public.maintenance_issues where id='d1000000-0000-4000-8000-000000000001'),'resolution is server-attributed, revisioned, and retains an overdue planned date');
select throws_ok($$select * from public.update_maintenance_issue('a1000000-0000-4000-8000-000000000003',null,'d1000000-0000-4000-8000-000000000001','in_progress','Reopen','Technician',5,((statement_timestamp() at time zone 'Asia/Riyadh')::date-1),null)$$,'22023','invalid maintenance issue transition','resolved issue cannot reopen');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000001',
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000001','idempotency_key','21000000-0000-4000-8000-000000000001','request_hash',repeat('a',64),'category','spare_parts','item_name','Seal','quantity',1,'unit','pcs','amount',10,'vendor_name','Vendor','purchase_date',current_date,'payment_method','cash','receipt_storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000001/receipt.jpg','receipt_original_name','receipt.jpg','attachments',jsonb_build_array(jsonb_build_object('id','e1000000-0000-4000-8000-000000000004','storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000001/receipt.jpg','original_filename','receipt.jpg','mime_type','image/jpeg','size_bytes',1000)))
)$$,'issue purchase is created with idempotency');
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000001',
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000099','idempotency_key','21000000-0000-4000-8000-000000000001','request_hash',repeat('a',64),'category','spare_parts','item_name','Seal','quantity',1,'unit','pcs','amount',10,'vendor_name','Vendor','purchase_date',current_date,'payment_method','cash')
)$$,'same purchase request replays safely');
reset role;
select is((select count(*)::integer from public.maintenance_purchase_logs where maintenance_issue_id='d1000000-0000-4000-8000-000000000001' and idempotency_key='21000000-0000-4000-8000-000000000001'),1,'purchase replay creates one financial row');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000001',
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000098','idempotency_key','21000000-0000-4000-8000-000000000001','request_hash',repeat('b',64),'category','spare_parts','item_name','Changed','quantity',1,'unit','pcs','amount',11,'vendor_name','Vendor','purchase_date',current_date)
)$$,'40001','maintenance purchase idempotency payload changed','same-scope replay with changed payload conflicts');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003',null,
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000002','idempotency_key','21000000-0000-4000-8000-000000000001','request_hash',repeat('c',64),'purchase_type','general','purchase_scope','other','destination','Warehouse','category','general_supplies','item_name','Supplies','quantity',1,'unit','box','amount',20,'vendor_name','Vendor','purchase_date',current_date,'payment_method','credit_card','receipt_storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000002/receipt.pdf','receipt_original_name','receipt.pdf','attachments',jsonb_build_array(
    jsonb_build_object('id','e1000000-0000-4000-8000-000000000003','storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000002/receipt.pdf','original_filename','receipt.pdf','mime_type','application/pdf','size_bytes',1000),
    jsonb_build_object('id','e1000000-0000-4000-8000-000000000005','storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000002/photo.png','original_filename','photo.png','mime_type','image/png','size_bytes',1000),
    jsonb_build_object('id','e1000000-0000-4000-8000-000000000006','storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000002/photo.webp','original_filename','photo.webp','mime_type','image/webp','size_bytes',1000)
  ))
)$$,'manual purchase uses independent idempotency scope and UUID tenant path');
reset role;
select is((select count(*)::integer from public.maintenance_purchase_logs where organization_id='b1000000-0000-4000-8000-000000000001' and idempotency_key='21000000-0000-4000-8000-000000000001'),2,'issue and general purchase keys do not collide');
select is((select payment_method from public.maintenance_purchase_logs where id='f1000000-0000-4000-8000-000000000001'),'cash','cash payment method persists');
select is((select payment_method from public.maintenance_purchase_logs where id='f1000000-0000-4000-8000-000000000002'),'credit_card','credit-card payment method persists');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003',null,
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000003','idempotency_key','21000000-0000-4000-8000-000000000003','request_hash',repeat('d',64),'purchase_type','general','purchase_scope','other','destination','Office store','category','general_supplies','item_name','Deferred supplies','quantity',1,'unit','box','amount',30,'vendor_name','Vendor','purchase_date',current_date,'payment_method','pay_later')
)$$,'pay-later general purchase succeeds');
reset role;
select is((select payment_method from public.maintenance_purchase_logs where id='f1000000-0000-4000-8000-000000000003'),'pay_later','pay-later payment method persists');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000002',
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000004','idempotency_key','21000000-0000-4000-8000-000000000001','request_hash',repeat('e',64),'category','spare_parts','item_name','Branch B part','quantity',1,'unit','pcs','amount',12,'vendor_name','Vendor','purchase_date',current_date)
)$$,'same purchase key is independent for another issue');
reset role;
select is((select count(*)::integer from public.maintenance_purchase_logs where organization_id='b1000000-0000-4000-8000-000000000001' and purchase_type='issue' and idempotency_key='21000000-0000-4000-8000-000000000001'),2,'Issue A and Issue B purchase idempotency scopes do not collide');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  'a1000000-0000-4000-8000-000000000002','c1000000-0000-4000-8000-000000000003',
  jsonb_build_object('issue_id','d1000000-0000-4000-8000-000000000005','title','Foreign issue','category','other','priority','normal')
)$$,'foreign organization fixture issue is created');
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000004','d1000000-0000-4000-8000-000000000005',
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000005','idempotency_key','21000000-0000-4000-8000-000000000001','request_hash',repeat('f',64),'category','other','item_name','Foreign part','quantity',1,'unit','pcs','amount',9,'vendor_name','Vendor','purchase_date',current_date)
)$$,'same purchase key is independent in another organization');
reset role;
select is((select count(*)::integer from public.maintenance_purchase_logs where organization_id='b1000000-0000-4000-8000-000000000002' and idempotency_key='21000000-0000-4000-8000-000000000001'),1,'purchase idempotency is organization-isolated');

select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003',null,
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000006','purchase_type','general','purchase_scope','other','destination','Warehouse','category','general_supplies','item_name','Too many files','quantity',1,'unit','box','amount',1,'purchase_date',current_date,'attachments',jsonb_build_array('{}'::jsonb,'{}'::jsonb,'{}'::jsonb,'{}'::jsonb))
)$$,'22023','too many maintenance purchase attachments','more than three purchase evidence files are rejected');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a1000000-0000-4000-8000-000000000003',null,
  jsonb_build_object('purchase_id','f1000000-0000-4000-8000-000000000007','purchase_type','general','purchase_scope','other','destination','Warehouse','category','general_supplies','item_name','Large file','quantity',1,'unit','box','amount',1,'purchase_date',current_date,'receipt_storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000007/large.pdf','attachments',jsonb_build_array(jsonb_build_object('id','e1000000-0000-4000-8000-000000000007','storage_path','maintenance/b1000000-0000-4000-8000-000000000001/purchases/f1000000-0000-4000-8000-000000000007/large.pdf','original_filename','large.pdf','mime_type','application/pdf','size_bytes',5242881)))
)$$,'22023','invalid maintenance purchase payload','purchase evidence over five MiB is rejected');

set local role service_role;
select lives_ok($$select * from public.reimburse_maintenance_purchase_log_v2('a1000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000001','Paid')$$,'first reimbursement succeeds');
reset role;
select ok((select payment_status='reimbursed' and reimbursed_by='a1000000-0000-4000-8000-000000000003' and reimbursed_at is not null from public.maintenance_purchase_logs where id='f1000000-0000-4000-8000-000000000001'),'reimbursement actor and timestamp are authoritative');
select is((select count(*)::integer from public.maintenance_purchase_events where purchase_id='f1000000-0000-4000-8000-000000000001' and event_type='reimbursed'),1,'one immutable reimbursement event is recorded');
select throws_ok($$select * from public.reimburse_maintenance_purchase_log_v2('a1000000-0000-4000-8000-000000000003','f1000000-0000-4000-8000-000000000001','Again')$$,'40001','maintenance purchase already reimbursed','second reimbursement conflicts');
select throws_ok($$update public.maintenance_purchase_logs set amount=11 where id='f1000000-0000-4000-8000-000000000001'$$,'55000','reimbursed maintenance purchase is immutable','reimbursed amount cannot be rewritten');
select throws_ok($$delete from public.maintenance_purchase_attachments where purchase_id='f1000000-0000-4000-8000-000000000001'$$,'55000','reimbursed maintenance purchase evidence is immutable','reimbursed evidence cannot be removed');

select ok((select (public.get_maintenance_purchase_history_page('a1000000-0000-4000-8000-000000000003','all',1,1)->>'total_count')::integer >= 2),'combined purchase history reports an explicit complete total');
select is((select count(*)::integer from public.get_managed_maintenance_purchase_receipt_metadata('a1000000-0000-4000-8000-000000000005','b1000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000002',null)),1,'authorized Manager resolves scoped receipt metadata');
select throws_ok($$select * from public.get_managed_maintenance_purchase_receipt_metadata('a1000000-0000-4000-8000-000000000005','b1000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002',null)$$,'42501','managed maintenance purchase access denied','Manager cannot resolve receipt metadata for unmanaged organization');

select * from finish();
rollback;
