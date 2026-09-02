begin;
select plan(37);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@maintenance-vendor-service.invalid','{}','{}',now(),now()
from unnest(array[
  'a2000000-0000-4000-8000-000000000001'::uuid,
  'a2000000-0000-4000-8000-000000000002'
]) id;

update public.profiles
set full_name = 'Maintenance Vendor Service', must_change_password = false
where id::text like 'a2000000-0000-4000-8000-00000000000%';

insert into public.organizations(id,name,slug) values
  ('b2000000-0000-4000-8000-000000000001','Vendor Service Org','vendor-service-org'),
  ('b2000000-0000-4000-8000-000000000002','Vendor Service Foreign Org','vendor-service-foreign-org');

insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('c2000000-0000-4000-8000-000000000001','b2000000-0000-4000-8000-000000000001','Burger Hunch Al Takhassusi','VSA','Asia/Riyadh',true),
  ('c2000000-0000-4000-8000-000000000002','b2000000-0000-4000-8000-000000000001','Inactive Branch','VSI','Asia/Riyadh',false),
  ('c2000000-0000-4000-8000-000000000003','b2000000-0000-4000-8000-000000000002','Foreign Branch','VSF','Asia/Riyadh',true);

insert into public.branch_memberships(branch_id,user_id,role) values
  ('c2000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','branch_manager');

insert into public.maintenance_memberships(organization_id,user_id,active,created_by,updated_by) values
  ('b2000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000002',true,'a2000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001');

select ok(
  to_regprocedure('public.create_maintenance_purchase_log_v2(uuid,uuid,jsonb)') is not null
  and (select prosecdef and coalesce(array_to_string(proconfig,','),'') = 'search_path=""'
       from pg_proc where oid = 'public.create_maintenance_purchase_log_v2(uuid,uuid,jsonb)'::regprocedure)
  and has_function_privilege('service_role','public.create_maintenance_purchase_log_v2(uuid,uuid,jsonb)','execute')
  and not has_function_privilege('anon','public.create_maintenance_purchase_log_v2(uuid,uuid,jsonb)','execute')
  and not has_function_privilege('authenticated','public.create_maintenance_purchase_log_v2(uuid,uuid,jsonb)','execute')
  and not exists (
    select 1
    from pg_proc procedure
    cross join lateral aclexplode(procedure.proacl) privilege
    where procedure.oid = 'public.create_maintenance_purchase_log_v2(uuid,uuid,jsonb)'::regprocedure
      and privilege.grantee = 0
      and privilege.privilege_type = 'EXECUTE'
  ),
  'v2 purchase RPC remains SECURITY DEFINER with empty search_path and service-role-only execution'
);

select ok(
  (select count(*) = 5
   from pg_constraint
   where conrelid = 'public.maintenance_purchase_logs'::regclass
     and conname in (
       'maintenance_purchase_type_check',
       'maintenance_purchase_unit_check',
       'maintenance_purchase_category_check',
       'maintenance_purchase_general_scope_canonical_check',
       'maintenance_purchase_service_shape_check'
     )
     and convalidated)
  and position('service' in pg_get_constraintdef((select oid from pg_constraint where conrelid='public.maintenance_purchase_logs'::regclass and conname='maintenance_purchase_unit_check'))) > 0
  and position('service' in pg_get_constraintdef((select oid from pg_constraint where conrelid='public.maintenance_purchase_logs'::regclass and conname='maintenance_purchase_category_check'))) > 0,
  'replacement enum and shape constraints are installed and validated'
);

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  'a2000000-0000-4000-8000-000000000001','c2000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','d2000000-0000-4000-8000-000000000001','title','Existing issue purchase','category','other','priority','normal')
)$$,'issue fixture creation remains valid');
reset role;

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000001','purchase_type','general','purchase_scope','other','destination','  Warehouse   Store  ','category','general_supplies','item_name','Existing supplies','quantity',2,'unit','box','amount',40,'vendor_name','Existing Vendor','purchase_date',current_date,'payment_method','cash')
)$$,'existing general-other purchase remains valid');
reset role;
select is((select purchase_scope||':'||destination from public.maintenance_purchase_logs where id='f2000000-0000-4000-8000-000000000001'),'other:Warehouse Store','existing general-other destination remains normalized');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000001',
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000002','category','spare_parts','item_name','Existing part','quantity',1,'unit','pcs','amount',15,'vendor_name','Parts Vendor','purchase_date',current_date,'payment_method','credit_card')
)$$,'existing issue-origin purchase remains valid');
reset role;
select ok((select purchase_type='issue' and maintenance_issue_id='d2000000-0000-4000-8000-000000000001' and branch_id='c2000000-0000-4000-8000-000000000001' and destination is null from public.maintenance_purchase_logs where id='f2000000-0000-4000-8000-000000000002'),'issue-origin routing remains unchanged');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000003','purchase_type','general','purchase_scope','other','destination','Operations','category','service','item_name','Monthly deep cleaning','quantity',1,'unit','service','amount',350,'vendor_name','Dr. Clean','purchase_date','2026-09-02','payment_method','cash')
)$$,'service category and unit are accepted together');
reset role;
select ok((select category='service' and unit='service' and quantity=1 and vendor_name='Dr. Clean' from public.maintenance_purchase_logs where id='f2000000-0000-4000-8000-000000000003'),'service row persists its canonical shape');

select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','other','destination','Operations','category','service','item_name','Bad pair','quantity',1,'unit','pcs','amount',1,'vendor_name','Provider','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','service category without service unit is rejected');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','other','destination','Operations','category','other','item_name','Bad pair','quantity',1,'unit','service','amount',1,'vendor_name','Provider','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','service unit without service category is rejected');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','other','destination','Operations','category','service','item_name','Two visits','quantity',2,'unit','service','amount',1,'vendor_name','Provider','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','service quantity other than one is rejected');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','other','destination','Operations','category','service','item_name','Blank provider','quantity',1,'unit','service','amount',1,'vendor_name','   ','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','service without a nonblank provider is rejected');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','other','destination','Operations','category','service','item_name','Placeholder provider','quantity',1,'unit','service','amount',1,'vendor_name','n/a','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','service N/A provider is rejected case-insensitively');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000001',
  jsonb_build_object('category','service','item_name','Issue service','quantity',1,'unit','service','amount',1,'vendor_name','Provider','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','service mode is rejected for issue-origin purchases');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000004','purchase_type','general','purchase_scope','branch','branch_id','c2000000-0000-4000-8000-000000000001','category','service','item_name','Branch deep cleaning','quantity',1,'unit','service','amount',350,'vendor_name','Dr. Clean','purchase_date','2026-09-02','payment_method','cash')
)$$,'active same-organization branch scope succeeds');
reset role;
select ok((select branch_id='c2000000-0000-4000-8000-000000000001' and destination is null from public.maintenance_purchase_logs where id='f2000000-0000-4000-8000-000000000004'),'branch scope stores relational branch and null destination');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','branch','category','other','item_name','Missing branch','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','branch scope requires branch_id');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','branch','branch_id','c2000000-0000-4000-8000-000000000002','category','other','item_name','Inactive branch','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'42501','maintenance purchase access denied','inactive branch is rejected without branch disclosure');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','branch','branch_id','c2000000-0000-4000-8000-000000000003','category','other','item_name','Foreign branch','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'42501','maintenance purchase access denied','cross-organization branch is rejected without branch disclosure');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','branch','branch_id','c2000000-0000-4000-8000-000000000001','destination','Browser Branch Name','category','other','item_name','Untrusted destination','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','branch scope rejects browser-supplied destination');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000005','purchase_type','general','purchase_scope','office','category','service','item_name','Office service','quantity',1,'unit','service','amount',100,'vendor_name','Office Provider','purchase_date',current_date,'payment_method','pay_later')
)$$,'office scope succeeds without branch or browser destination');
reset role;
select ok((select branch_id is null and destination='Office' from public.maintenance_purchase_logs where id='f2000000-0000-4000-8000-000000000005'),'office scope stores canonical Office destination');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','office','branch_id','c2000000-0000-4000-8000-000000000001','category','other','item_name','Office branch','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','office scope rejects branch_id');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','office','destination','Headquarters','category','other','item_name','Office alias','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','office scope rejects arbitrary destination');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','other','category','other','item_name','No destination','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','other scope requires destination');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_type','general','purchase_scope','other','branch_id','c2000000-0000-4000-8000-000000000001','destination','Warehouse','category','other','item_name','Other branch','quantity',1,'unit','pcs','amount',1,'vendor_name','Vendor','purchase_date',current_date)
)$$,'22023','invalid maintenance purchase payload','other scope rejects branch_id');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000006','purchase_type','general','destination','Legacy Destination','category','other','item_name','Legacy no scope','quantity',1,'unit','other','amount',25,'vendor_name','Legacy Vendor','purchase_date',current_date)
)$$,'omitted purchase_scope preserves legacy general-other behavior');
reset role;
select ok((select purchase_scope='other' and branch_id is null and destination='Legacy Destination' from public.maintenance_purchase_logs where id='f2000000-0000-4000-8000-000000000006'),'omitted purchase_scope is stored canonically as other');

select lives_ok($$insert into public.maintenance_purchase_logs(
  organization_id,branch_id,maintenance_issue_id,purchase_type,purchase_scope,destination,category,
  maintenance_user_id,item_name,quantity,unit,amount,vendor_name,purchase_date
)
select 'b2000000-0000-4000-8000-000000000001',null,null,'general','other','Historical units','other',
  'a2000000-0000-4000-8000-000000000002','Historical unit '||value,1,value,1,'Vendor',current_date
from unnest(array['pcs','meter','kg','box','bag','roll','set','liter','other']::text[]) value$$,
'all historical units remain accepted');
select lives_ok($$insert into public.maintenance_purchase_logs(
  organization_id,branch_id,maintenance_issue_id,purchase_type,purchase_scope,destination,category,
  maintenance_user_id,item_name,quantity,unit,amount,vendor_name,purchase_date
)
select 'b2000000-0000-4000-8000-000000000001',null,null,'general','other','Historical categories',value,
  'a2000000-0000-4000-8000-000000000002','Historical category '||value,1,'pcs',1,'Vendor',current_date
from unnest(array['spare_parts','tools_equipment','electrical','plumbing','hvac_refrigeration','kitchen_equipment','fuel_petrol','transportation','technician_contractor','building_facility','safety_equipment','it_network','general_supplies','other']::text[]) value$$,
'all historical categories remain accepted');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000020','idempotency_key','22000000-0000-4000-8000-000000000001','request_hash',repeat('a',64),'purchase_type','general','purchase_scope','other','destination','Idempotency','category','service','item_name','Idempotent service','quantity',1,'unit','service','amount',50,'vendor_name','Provider','purchase_date',current_date)
)$$,'service purchase idempotency first request succeeds');
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000021','idempotency_key','22000000-0000-4000-8000-000000000001','request_hash',repeat('a',64),'purchase_type','general','purchase_scope','other','destination','Idempotency','category','service','item_name','Idempotent service','quantity',1,'unit','service','amount',50,'vendor_name','Provider','purchase_date',current_date)
)$$,'unchanged idempotent service replay succeeds');
reset role;
select is((select count(*)::integer from public.maintenance_purchase_logs where organization_id='b2000000-0000-4000-8000-000000000001' and idempotency_key='22000000-0000-4000-8000-000000000001'),1,'idempotent replay creates one purchase row');
select throws_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000022','idempotency_key','22000000-0000-4000-8000-000000000001','request_hash',repeat('b',64),'purchase_type','general','purchase_scope','other','destination','Changed','category','service','item_name','Changed service','quantity',1,'unit','service','amount',55,'vendor_name','Provider','purchase_date',current_date)
)$$,'40001','maintenance purchase idempotency payload changed','changed-payload idempotency conflict remains unchanged');

set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log_v2(
  'a2000000-0000-4000-8000-000000000002',null,
  jsonb_build_object('purchase_id','f2000000-0000-4000-8000-000000000030','purchase_type','general','purchase_scope','branch','branch_id','c2000000-0000-4000-8000-000000000001','category','service','item_name','Documented service','quantity',1,'unit','service','amount',75,'vendor_name','Provider','purchase_date',current_date,'receipt_storage_path','maintenance/b2000000-0000-4000-8000-000000000001/purchases/f2000000-0000-4000-8000-000000000030/evidence.pdf','receipt_original_name','evidence.pdf','attachments',jsonb_build_array(jsonb_build_object('id','e2000000-0000-4000-8000-000000000001','storage_path','maintenance/b2000000-0000-4000-8000-000000000001/purchases/f2000000-0000-4000-8000-000000000030/evidence.pdf','original_filename','evidence.pdf','mime_type','application/pdf','size_bytes',1000)))
)$$,'existing service evidence flow succeeds unchanged');
reset role;
select ok((select count(*)=1 and bool_and(branch_id='c2000000-0000-4000-8000-000000000001') from public.maintenance_purchase_attachments where purchase_id='f2000000-0000-4000-8000-000000000030'),'evidence attachment keeps the purchase branch scope');

select * from finish();
rollback;
