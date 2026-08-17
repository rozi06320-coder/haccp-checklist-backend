begin;
select plan(37);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1c000000-0000-4000-8000-000000000001'::uuid,
 '1c000000-0000-4000-8000-000000000002',
 '1c000000-0000-4000-8000-000000000003',
 '1c000000-0000-4000-8000-000000000004'
]) id;
update public.profiles set full_name=case id
 when '1c000000-0000-4000-8000-000000000001' then 'Maintenance Supervisor'
 when '1c000000-0000-4000-8000-000000000002' then 'Maintenance Tech'
 when '1c000000-0000-4000-8000-000000000003' then 'Maintenance Manager'
 else 'Other Tech' end,
 must_change_password=false
where id in (
 '1c000000-0000-4000-8000-000000000001',
 '1c000000-0000-4000-8000-000000000002',
 '1c000000-0000-4000-8000-000000000003',
 '1c000000-0000-4000-8000-000000000004'
);
insert into public.organizations(id,name,slug)
values
 ('2c000000-0000-4000-8000-000000000001','Maintenance Org','maintenance-issue-org'),
 ('2c000000-0000-4000-8000-000000000002','Other Maintenance Org','other-maintenance-issue-org');
insert into public.branches(id,organization_id,name,code,timezone)
values
 ('3c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','Maintenance Branch','MB','Asia/Riyadh'),
 ('3c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000002','Other Branch','OB','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role)
values('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001','branch_manager');
insert into public.organization_memberships(organization_id,user_id,role)
values('2c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000003','organization_manager');
insert into public.maintenance_memberships(organization_id,user_id,active,created_by,updated_by)
values
 ('2c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002',true,'1c000000-0000-4000-8000-000000000003','1c000000-0000-4000-8000-000000000003'),
 ('2c000000-0000-4000-8000-000000000002','1c000000-0000-4000-8000-000000000004',true,'1c000000-0000-4000-8000-000000000003','1c000000-0000-4000-8000-000000000003');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values('5c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001','Maintenance Company');

select has_table('public','maintenance_issues','maintenance issues table exists');
select has_table('public','maintenance_issue_updates','maintenance issue updates table exists');
select ok(not has_function_privilege('authenticated','public.create_supervisor_maintenance_issue(uuid,uuid,jsonb)','execute')
 and has_function_privilege('service_role','public.create_supervisor_maintenance_issue(uuid,uuid,jsonb)','execute'),
 'supervisor create maintenance RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.update_maintenance_issue(uuid,uuid,uuid,text,text)','execute')
 and has_function_privilege('service_role','public.update_maintenance_issue(uuid,uuid,uuid,text,text)','execute'),
 'maintenance update RPC is service-role only');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue(
 '1c000000-0000-4000-8000-000000000001',
 '3c000000-0000-4000-8000-000000000001',
 jsonb_build_object('title','  Freezer door  ','category','refrigeration','priority','urgent','description','  Door is loose  ','location','  Kitchen  ')
)$$,'supervisor creates own branch maintenance issue');
reset role;

create temp table maintenance_issue_test_ids as
select id as issue_id from public.maintenance_issues
where organization_id='2c000000-0000-4000-8000-000000000001'
  and reported_by='1c000000-0000-4000-8000-000000000001'
order by created_at desc limit 1;
grant select on maintenance_issue_test_ids to service_role;
select is((select title from public.maintenance_issues where id=(select issue_id from maintenance_issue_test_ids)),'Freezer door','title is trimmed');
select is((select count(*)::int from public.maintenance_issue_updates where issue_id=(select issue_id from maintenance_issue_test_ids)),1,'reported update is created');
select is((select count(*)::int from public.list_supervisor_maintenance_issues('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001') where id=(select issue_id from maintenance_issue_test_ids)),1,'supervisor list restores own issue');
select is((select count(*)::int from public.list_maintenance_issues('1c000000-0000-4000-8000-000000000002',null,null) where id=(select issue_id from maintenance_issue_test_ids)),1,'maintenance user lists scoped organization issues');
select is((select count(*)::int from public.list_maintenance_issues('1c000000-0000-4000-8000-000000000004',null,null) where id=(select issue_id from maintenance_issue_test_ids)),0,'other organization maintenance user does not see issue');

set local role service_role;
select lives_ok($$select * from public.update_maintenance_issue(
 '1c000000-0000-4000-8000-000000000002',
 null,
 (select issue_id from maintenance_issue_test_ids limit 1),
 'in_progress',
 '  Started repair  '
)$$,'maintenance user updates status and note');
reset role;

select is((select status from public.maintenance_issues where id=(select issue_id from maintenance_issue_test_ids)),'in_progress','status is updated');
select is((select note from public.maintenance_issue_updates where issue_id=(select issue_id from maintenance_issue_test_ids) and status = 'in_progress'),'Started repair','update note is trimmed');
select ok(not has_function_privilege('authenticated','public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)','execute')
 and has_function_privilege('service_role','public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)','execute'),
 'managed maintenance list RPC is service-role only');
select is((select count(*)::int from public.list_managed_maintenance_issues(
 '1c000000-0000-4000-8000-000000000003','2c000000-0000-4000-8000-000000000001',null,null,null,null,null,null
 ) where id=(select issue_id from maintenance_issue_test_ids)),1,'manager lists own organization maintenance issue');
select is((select (updates->-1->>'note') from public.list_managed_maintenance_issues(
 '1c000000-0000-4000-8000-000000000003','2c000000-0000-4000-8000-000000000001',null,null,null,null,null,null
) where id=(select issue_id from maintenance_issue_test_ids) limit 1),'Started repair','manager receives scoped read-only update timeline');
select throws_ok($$select * from public.list_managed_maintenance_issues(
 '1c000000-0000-4000-8000-000000000003','2c000000-0000-4000-8000-000000000001',
 '3c000000-0000-4000-8000-000000000002',null,null,null,null,null
)$$,'42501','managed maintenance issue access denied','manager branch filter must belong to organization');
select throws_ok($$select * from public.update_maintenance_issue(
 '1c000000-0000-4000-8000-000000000003',null,(select issue_id from maintenance_issue_test_ids limit 1),'resolved','manager update'
)$$,'42501','maintenance issue access denied','manager denied');
select has_table('public','maintenance_purchase_logs','maintenance purchase logs table exists');
select has_table('public','maintenance_purchase_attachments','maintenance purchase attachments table exists');
select ok(not has_function_privilege('authenticated','public.create_maintenance_purchase_log(uuid,uuid,jsonb)','execute')
 and not has_function_privilege('authenticated','public.list_maintenance_purchase_logs(uuid,uuid)','execute')
 and not has_function_privilege('authenticated','public.reimburse_maintenance_purchase_log(uuid,uuid,text)','execute'),
 'maintenance purchase RPCs are not directly executable by authenticated users');
set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log(
 '1c000000-0000-4000-8000-000000000002',(select issue_id from maintenance_issue_test_ids),
 jsonb_build_object('item_name','  Replacement seal  ','quantity','2','unit','meter','amount','35.50','vendor_name','  Parts Shop  ','purchase_date','2026-08-10','notes','  Urgent  ')
)$$,'maintenance user creates purchase for authorized issue');
reset role;
create temp table maintenance_purchase_test_ids as select id as purchase_id from public.maintenance_purchase_logs where maintenance_issue_id=(select issue_id from maintenance_issue_test_ids) order by created_at desc limit 1;
grant select on maintenance_purchase_test_ids to service_role;
select is((select count(*)::int from public.list_maintenance_purchase_logs('1c000000-0000-4000-8000-000000000002',(select issue_id from maintenance_issue_test_ids))),1,'maintenance user lists authorized issue purchases');
select is((select vendor_name from public.maintenance_purchase_logs where id=(select purchase_id from maintenance_purchase_test_ids)),'Parts Shop','purchase vendor is normalized');
select is((select receipt_storage_path from public.list_maintenance_purchase_logs('1c000000-0000-4000-8000-000000000002',(select issue_id from maintenance_issue_test_ids)) limit 1),null,'purchase list does not require a receipt');
set local role service_role;
select lives_ok($$select * from public.create_maintenance_purchase_log(
 '1c000000-0000-4000-8000-000000000002',(select issue_id from maintenance_issue_test_ids),
 jsonb_build_object(
  'purchase_id','6c000000-0000-4000-8000-000000000001',
  'item_name','Pump','quantity','1','unit','pcs','amount','12','vendor_name','Parts Shop','purchase_date','2026-08-10',
  'attachments',jsonb_build_array(
    jsonb_build_object('id','7c000000-0000-4000-8000-000000000001','storage_path','maintenance/'||(select issue_id from maintenance_issue_test_ids)::text||'/purchases/6c000000-0000-4000-8000-000000000001/receipt-one.pdf','original_filename','إيصال.pdf','mime_type','application/pdf','size_bytes',1024),
    jsonb_build_object('id','7c000000-0000-4000-8000-000000000002','storage_path','maintenance/'||(select issue_id from maintenance_issue_test_ids)::text||'/purchases/6c000000-0000-4000-8000-000000000001/photo-two.png','original_filename','photo two.png','mime_type','image/png','size_bytes',2048),
    jsonb_build_object('id','7c000000-0000-4000-8000-000000000003','storage_path','maintenance/'||(select issue_id from maintenance_issue_test_ids)::text||'/purchases/6c000000-0000-4000-8000-000000000001/photo-three.webp','original_filename','photo three.webp','mime_type','image/webp','size_bytes',4096)
  )
 )
)$$,'maintenance user creates purchase with three attachments');
reset role;
select is((select count(*)::int from public.maintenance_purchase_attachments where purchase_id='6c000000-0000-4000-8000-000000000001'),3,'three purchase attachments are persisted');
select is((select string_agg(position::text,',' order by position) from public.maintenance_purchase_attachments where purchase_id='6c000000-0000-4000-8000-000000000001'),'1,2,3','purchase attachment positions are 1 through 3');
select is((select attachments->0->>'original_filename' from public.list_maintenance_purchase_logs('1c000000-0000-4000-8000-000000000002',(select issue_id from maintenance_issue_test_ids)) where id='6c000000-0000-4000-8000-000000000001'),'إيصال.pdf','attachment read model preserves non-ASCII original filename');
select is((select receipt_storage_path from public.maintenance_purchase_logs where id='6c000000-0000-4000-8000-000000000001'),(select storage_path from public.maintenance_purchase_attachments where purchase_id='6c000000-0000-4000-8000-000000000001' and position=1),'legacy receipt path points at first attachment');
set local role service_role;
select throws_ok($$select * from public.create_maintenance_purchase_log(
 '1c000000-0000-4000-8000-000000000002',(select issue_id from maintenance_issue_test_ids),
 jsonb_build_object('item_name','Too many','quantity','1','unit','pcs','amount','1','purchase_date','2026-08-10','attachments',jsonb_build_array('{}'::jsonb,'{}'::jsonb,'{}'::jsonb,'{}'::jsonb))
)$$,'22023','too many maintenance purchase attachments','four purchase attachments are rejected');
reset role;
set local role service_role;
select lives_ok($$select * from public.reimburse_maintenance_purchase_log(
 '1c000000-0000-4000-8000-000000000002',(select purchase_id from maintenance_purchase_test_ids),'  Paid in cash  '
)$$,'maintenance user reimburses unpaid purchase');
reset role;
select is((select payment_status from public.maintenance_purchase_logs where id=(select purchase_id from maintenance_purchase_test_ids)),'reimbursed','purchase is reimbursed');
select throws_ok($$select * from public.create_maintenance_purchase_log(
 '1c000000-0000-4000-8000-000000000003',(select issue_id from maintenance_issue_test_ids),
 jsonb_build_object('item_name','Manager attempt','quantity','1','unit','pcs','amount','1','purchase_date','2026-08-10')
)$$,'42501','maintenance purchase access denied','manager cannot create maintenance purchase');
set local role authenticated;
select throws_ok($$insert into public.maintenance_purchase_logs(organization_id,branch_id,maintenance_issue_id,maintenance_user_id,item_name,quantity,amount,purchase_date)
values('2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',(select issue_id from maintenance_issue_test_ids),'1c000000-0000-4000-8000-000000000002','Direct write',1,1,'2026-08-10')$$,'42501',null,'direct authenticated purchase writes are denied');
reset role;
select throws_ok($$select * from public.create_supervisor_maintenance_issue(
 '1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',
 jsonb_build_object('title','Door','category','bad','priority','urgent')
)$$,'22023','invalid maintenance issue payload','invalid category rejected');

set local role authenticated;
select throws_ok($$insert into public.maintenance_issues(
 organization_id,branch_id,supervisor_team_id,title,category,priority,reported_by
) values (
 '2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','5c000000-0000-4000-8000-000000000001','Door','refrigeration','urgent','1c000000-0000-4000-8000-000000000001'
)$$,'42501',null,'direct authenticated writes are denied');
reset role;

select * from finish();
rollback;
