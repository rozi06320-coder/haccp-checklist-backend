begin;
select plan(13);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1b000000-0000-4000-8000-000000000001'::uuid,
 '1b000000-0000-4000-8000-000000000002',
 '1b000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name=case id
 when '1b000000-0000-4000-8000-000000000001' then 'Staff Code Supervisor'
 when '1b000000-0000-4000-8000-000000000002' then 'Other Supervisor'
 else 'Staff Code Manager' end,
 must_change_password=false
where id in (
 '1b000000-0000-4000-8000-000000000001',
 '1b000000-0000-4000-8000-000000000002',
 '1b000000-0000-4000-8000-000000000003'
);
insert into public.organizations(id,name,slug)
values('2b000000-0000-4000-8000-000000000001','Staff Code Org','staff-code-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','Staff Code Branch','SCB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)
values
 ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001','branch_manager'),
 ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values('5b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001');

select has_column('public','operational_staff','staff_code','operational staff stores a real staff code');
select ok(not has_function_privilege('authenticated','public.create_supervisor_operational_staff(uuid,uuid,text,text[],text,text)','execute')
 and has_function_privilege('service_role','public.create_supervisor_operational_staff(uuid,uuid,text,text[],text,text)','execute'),
 'staff-code create RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[],text,text)','execute')
 and has_function_privilege('service_role','public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[],text,text)','execute'),
 'staff-code update RPC is service-role only');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_operational_staff(
 '1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001',
 '  Code   Worker  ',array['kitchen'],'  BH-104  ','Staff Code Company')$$,'supervisor creates staff with code');
reset role;

select is((select staff_code from public.operational_staff where display_name='Code Worker'),'BH-104','create trims and persists staff code');
select is((select staff_code from public.get_supervisor_operational_team(
 '1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','2026-08-06')
 where display_name='Code Worker'),'BH-104','supervisor current team restores staff code');
select is((select staff_code from public.get_supervisor_operational_team(
 '1b000000-0000-4000-8000-000000000002','3b000000-0000-4000-8000-000000000001','2026-08-06')
 where display_name='Code Worker'),'BH-104','same-branch supervisor reads the shared team code');
select is((select staff_code from public.list_managed_operational_staff(
 '1b000000-0000-4000-8000-000000000003','2b000000-0000-4000-8000-000000000001',
 1,20,null,null,null,null,null,'2026-08-06') where display_name='Code Worker'),'BH-104',
 'manager listing displays the same staff code');
select set_config('test.staff_code_worker_id',(select id::text from public.operational_staff where display_name='Code Worker'),false);

set local role service_role;
select lives_ok($$select * from public.update_supervisor_operational_staff(
 '1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001',
 current_setting('test.staff_code_worker_id')::uuid,
 'Code Worker','active',array['kitchen','cleaner'],'  BH-204  ','Staff Code Company')$$,'supervisor edits staff code through staff update');
reset role;
select is((select staff_code from public.operational_staff where display_name='Code Worker'),'BH-204','edit trims and persists staff code');

set local role service_role;
select lives_ok($$select * from public.update_supervisor_operational_staff(
 '1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001',
 current_setting('test.staff_code_worker_id')::uuid,
 'Code Worker','active',array['kitchen'],'   ','Staff Code Company')$$,'blank code clears the persisted value');
reset role;
select is((select staff_code from public.operational_staff where display_name='Code Worker'),null::text,'blank staff code becomes null');

select throws_ok($$insert into public.operational_staff(organization_id,branch_id,display_name,staff_code,created_by)
 values('2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','Bad Code',' untrimmed ','1b000000-0000-4000-8000-000000000001')$$,
 '23514',null,'direct untrimmed staff code is rejected');

select * from finish();
rollback;
