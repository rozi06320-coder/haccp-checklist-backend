begin;
select plan(39);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1e000000-0000-4000-8000-000000000001'::uuid,
 '1e000000-0000-4000-8000-000000000002',
 '1e000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name=case id
 when '1e000000-0000-4000-8000-000000000001' then 'Receiving Supervisor'
 when '1e000000-0000-4000-8000-000000000002' then 'Other Receiving Supervisor'
 else 'Receiving Manager' end,
 must_change_password=false
where id in (
 '1e000000-0000-4000-8000-000000000001',
 '1e000000-0000-4000-8000-000000000002',
 '1e000000-0000-4000-8000-000000000003'
);
insert into public.organizations(id,name,slug)
values('2e000000-0000-4000-8000-000000000001','Receiving Org','receiving-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Receiving Branch','RB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)
values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager'),
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values
 ('5e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','Receiving Company'),
 ('5e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002','Receiving Company');

select has_table('public','branch_supplier_receivings','branch supplier receivings table exists');
select has_table('public','branch_suppliers','branch suppliers table exists');
select has_column('public','branch_supplier_receivings','supplier_id','supplier receiving can link to supplier');
select has_column('public','branch_supplier_receivings','supplier_name_en','supplier English name is stored');
select has_column('public','branch_supplier_receivings','supplier_name_ar','supplier Arabic name is stored');
select ok((select not public and file_size_limit=5242880 and allowed_mime_types=array['image/jpeg','image/png','image/webp'] from storage.buckets where id='branch-supplier-receiving-photos'),'supplier receiving photo bucket is private and bounded');
select ok(not has_function_privilege('authenticated','public.list_branch_supplier_receivings(uuid,uuid)','execute')
 and has_function_privilege('service_role','public.list_branch_supplier_receivings(uuid,uuid)','execute'),
 'supplier receiving list RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.create_branch_supplier_receiving(uuid,uuid,jsonb)','execute')
 and has_function_privilege('service_role','public.create_branch_supplier_receiving(uuid,uuid,jsonb)','execute'),
 'supplier receiving create RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.list_branch_suppliers(uuid,uuid)','execute')
 and has_function_privilege('service_role','public.list_branch_suppliers(uuid,uuid)','execute'),
 'supplier list RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.create_branch_supplier(uuid,uuid,jsonb)','execute')
 and has_function_privilege('service_role','public.create_branch_supplier(uuid,uuid,jsonb)','execute'),
 'supplier create RPC is service-role only');

select is((select count(*)::int from public.list_branch_supplier_receivings(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')),
 0,'supplier receiving list returns empty before entries exist');
select is((select count(*)::int from public.list_branch_suppliers(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')),
 0,'supplier list returns empty before suppliers exist');

set local role service_role;
select lives_ok($$select * from public.create_branch_supplier(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 jsonb_build_object('supplier_name_en','  Riyadh Supplier  ','supplier_name_ar','   ')
)$$,'supervisor creates own branch supplier');
reset role;

select is((select supplier_name_en from public.branch_suppliers limit 1),'Riyadh Supplier','supplier English name is trimmed');
select is((select supplier_name_ar from public.branch_suppliers limit 1),null,'supplier Arabic name is optional');

set local role service_role;
select lives_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 jsonb_build_object(
  'category','raw',
  'supplier_name_en','  Riyadh Supplier  ',
  'supplier_name_ar','   ',
  'quantity','12.5',
  'unit',' kg ',
  'notes','  Checked at dock  ',
  'photo_storage_path','branches/3e000000-0000-4000-8000-000000000001/supplier-receivings/9e000000-0000-4000-8000-000000000001/photo.jpg',
  'photo_original_name',' photo.jpg '
))$$,'supervisor creates own branch supplier receiving');
reset role;

select is((select count(*)::int from public.branch_suppliers),1,'duplicate receiving supplier reuses existing supplier');
select ok((select supplier_id is not null from public.branch_supplier_receivings limit 1),'receiving stores supplier_id');
select is((select supplier_name_en from public.branch_supplier_receivings limit 1),'Riyadh Supplier','English supplier name is trimmed');
select is((select supplier_name_ar from public.branch_supplier_receivings limit 1),null,'blank Arabic supplier name becomes null');
select is((select quantity from public.branch_supplier_receivings limit 1),12.5::numeric,'quantity is stored');
select is((select photo_original_name from public.branch_supplier_receivings limit 1),'photo.jpg','photo name is stored');
select is((select count(*)::int from public.list_branch_supplier_receivings(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')),
 1,'supplier receiving list restores saved entries');

set local role service_role;
select lives_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 jsonb_build_object(
  'category','juice',
  'supplier_id',(select id from public.branch_suppliers limit 1),
  'supplier_name_ar','مورد الرياض',
  'quantity','2',
  'unit','box'
 ))$$,'receiving can reuse existing supplier id and fill Arabic');
reset role;

select is((select count(*)::int from public.branch_suppliers),1,'existing supplier id does not create duplicate supplier');
select is((select supplier_name_ar from public.branch_suppliers limit 1),'مورد الرياض','Arabic supplier name is filled when existing supplier had none');

select ok(not has_function_privilege('authenticated','public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)','execute')
 and has_function_privilege('service_role','public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)','execute'),
 'manager supplier receiving list RPC is service-role only');
select is((select count(*)::int from public.list_managed_supplier_receivings(
 '1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001',null,null,null,null,null)),
 2,'manager lists organization supplier receiving records');
select is((select count(*)::int from public.list_managed_supplier_receivings(
 '1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001',null,'raw',null,null,null)),
 1,'manager category filter is scoped server-side');
select throws_ok($$select * from public.list_managed_supplier_receivings(
 '1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000099',null,null,null,null)$$,
 '42501','managed supplier receiving access denied','manager cross-organization branch filter is denied');
select throws_ok($$select * from public.list_managed_supplier_receivings(
 '1e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001',
 null,null,'9e000000-0000-4000-8000-000000000099',null,null)$$,
 '42501','managed supplier receiving access denied','manager cross-organization supplier filter is denied');

select throws_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','bad','supplier_name_en','Supplier','quantity','1','unit','kg'))$$,
 '22023','invalid supplier receiving payload','invalid category is rejected');
select throws_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','raw','supplier_name_en',' ','quantity','1','unit','kg'))$$,
 '22023','invalid supplier receiving payload','supplierNameEn required');
select throws_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','raw','supplier_name_en','Supplier','quantity','0','unit','kg'))$$,
 '22023','invalid supplier receiving payload','quantity must be positive');
select lives_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','raw','supplier_name_en','Supplier','quantity','1','unit','kg'))$$,
 'same-branch supervisor shares Supplier Receiving write access');
select throws_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000003','3e000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','raw','supplier_name_en','Supplier','quantity','1','unit','kg'))$$,
 '42501','supplier receiving access denied','manager denied');
select throws_ok($$select * from public.create_branch_supplier_receiving(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 jsonb_build_object('category','raw','supplier_id','9e000000-0000-4000-8000-000000000099','quantity','1','unit','kg'))$$,
 '42501','supplier receiving access denied','invalid supplier id is denied');

set local role authenticated;
select throws_ok($$insert into public.branch_supplier_receivings(
 organization_id,branch_id,supervisor_team_id,category,supplier_name_en,quantity,unit,created_by
) values (
 '2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 '5e000000-0000-4000-8000-000000000001','raw','Supplier',1,'kg','1e000000-0000-4000-8000-000000000001'
)$$,'42501',null,'direct authenticated writes are denied');
select throws_ok($$insert into public.branch_suppliers(
 organization_id,branch_id,supervisor_team_id,supplier_name_en,created_by
) values (
 '2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 '5e000000-0000-4000-8000-000000000001','Direct Supplier','1e000000-0000-4000-8000-000000000001'
)$$,'42501',null,'direct authenticated supplier writes are denied');
reset role;

select * from finish();
rollback;
