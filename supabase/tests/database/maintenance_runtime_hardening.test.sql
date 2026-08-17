begin;
select plan(9);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@maintenance-hardening.invalid','{}','{}',now(),now()
from unnest(array[
 '1d000000-0000-4000-8000-000000000001'::uuid,
 '1d000000-0000-4000-8000-000000000002',
 '1d000000-0000-4000-8000-000000000003',
 '1d000000-0000-4000-8000-000000000004'
]) id;
update public.profiles set full_name=case id when '1d000000-0000-4000-8000-000000000001' then 'Supervisor A' when '1d000000-0000-4000-8000-000000000002' then 'Supervisor B' else 'Outside Supervisor' end,must_change_password=false
where id in('1d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000003','1d000000-0000-4000-8000-000000000004');
insert into public.organizations(id,name,slug)values
 ('2d000000-0000-4000-8000-000000000001','Maintenance Shared Org','maintenance-shared-hardening'),
 ('2d000000-0000-4000-8000-000000000002','Maintenance Foreign Org','maintenance-foreign-hardening');
insert into public.branches(id,organization_id,name,code,timezone)values
 ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Shared Branch','MSA','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','Other Branch','MSB','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000002','Foreign Branch','MSF','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role)values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager'),
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','branch_manager'),
 ('3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000003','branch_manager'),
 ('3d000000-0000-4000-8000-000000000003','1d000000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)values
 ('5d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','Maintenance Shared');

select has_function('private','require_supervisor_maintenance_branch',array['uuid','uuid'],'branch authorization helper exists');
select ok(not has_function_privilege('authenticated','private.require_supervisor_maintenance_branch(uuid,uuid)','execute') and has_function_privilege('service_role','private.require_supervisor_maintenance_branch(uuid,uuid)','execute'),'branch helper is service-role only');
select ok((select bool_and(coalesce(array_to_string(proconfig,','),'') like '%search_path=""%') from pg_proc where oid=any(array[
 'private.require_supervisor_maintenance_team(uuid,uuid)'::regprocedure,
 'private.require_supervisor_maintenance_branch(uuid,uuid)'::regprocedure,
 'public.create_supervisor_maintenance_issue(uuid,uuid,jsonb)'::regprocedure,
 'public.list_supervisor_maintenance_issues(uuid,uuid)'::regprocedure,
 'public.list_maintenance_issues(uuid,uuid,uuid)'::regprocedure,
 'public.update_maintenance_issue(uuid,uuid,uuid,text,text)'::regprocedure,
 'private.require_maintenance_purchase_issue(uuid,uuid)'::regprocedure,
 'public.list_maintenance_purchase_logs(uuid,uuid)'::regprocedure,
 'public.create_maintenance_purchase_log(uuid,uuid,jsonb)'::regprocedure,
 'public.reimburse_maintenance_purchase_log(uuid,uuid,text)'::regprocedure,
 'public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date)'::regprocedure
])),'affected SECURITY DEFINER functions use empty search_path');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',jsonb_build_object('title','Shared freezer issue','category','refrigeration','priority','high'))$$,'Supervisor A creates Branch A issue');
reset role;
create temp table maintenance_shared_issue as select id from public.maintenance_issues where organization_id='2d000000-0000-4000-8000-000000000001' order by created_at desc limit 1;
grant select on maintenance_shared_issue to service_role;
select is((select count(*)::int from public.list_supervisor_maintenance_issues('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000001') where id=(select id from maintenance_shared_issue)),1,'Supervisor B sees Supervisor A issue in same branch');
select is((select reported_by from public.maintenance_issues where id=(select id from maintenance_shared_issue)),'1d000000-0000-4000-8000-000000000001'::uuid,'original reporter attribution remains Supervisor A');
select is((select count(*)::int from public.list_supervisor_maintenance_issues('1d000000-0000-4000-8000-000000000003','3d000000-0000-4000-8000-000000000002')),0,'other branch list does not include Branch A issue');
select throws_ok($$select * from public.list_supervisor_maintenance_issues('1d000000-0000-4000-8000-000000000003','3d000000-0000-4000-8000-000000000001')$$,'42501','maintenance issue access denied','other branch cannot request Branch A issues');
select throws_ok($$select * from public.list_supervisor_maintenance_issues('1d000000-0000-4000-8000-000000000004','3d000000-0000-4000-8000-000000000001')$$,'42501','maintenance issue access denied','other organization cannot request Branch A issues');

select * from finish();
rollback;
