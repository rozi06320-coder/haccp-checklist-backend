begin;
select plan(16);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1c000000-0000-4000-8000-000000000001'::uuid,
 '1c000000-0000-4000-8000-000000000002',
 '1c000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name=case id
 when '1c000000-0000-4000-8000-000000000001' then 'Employee Detail Supervisor'
 when '1c000000-0000-4000-8000-000000000002' then 'Other Supervisor'
 else 'Employee Detail Manager' end,
 must_change_password=false
where id in (
 '1c000000-0000-4000-8000-000000000001',
 '1c000000-0000-4000-8000-000000000002',
 '1c000000-0000-4000-8000-000000000003'
);
insert into public.organizations(id,name,slug)
values('2c000000-0000-4000-8000-000000000001','Employee Detail Org','employee-detail-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','Employee Detail Branch','EDB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)
values
 ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001','branch_manager'),
 ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values('5c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001','Manual Company');

select has_column('public','operational_staff','iqama_number','operational staff stores iqama number');
select has_column('public','operational_staff','iqama_expiry_date','operational staff stores iqama expiry date');
select has_column('public','operational_staff','phone_number','operational staff stores phone number');
select has_column('public','operational_staff','email','operational staff stores staff email');
select ok(not has_function_privilege('authenticated','public.create_supervisor_operational_staff(uuid,uuid,text,text[],text,text,text,date,text,text)','execute')
 and has_function_privilege('service_role','public.create_supervisor_operational_staff(uuid,uuid,text,text[],text,text,text,date,text,text)','execute'),
 'employee-detail create RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text)','execute')
 and has_function_privilege('service_role','public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text)','execute'),
 'employee-detail update RPC is service-role only');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_operational_staff(
 '1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',
 '  Detail   Worker  ',array['kitchen'],'  ED-01  ',' Manual Company ',
 ' IQ-7788 ','2026-12-31',' +966555000111 ',' worker@example.invalid ')$$,'supervisor creates staff with employee detail fields');
reset role;

select is((select iqama_number from public.operational_staff where display_name='Detail Worker'),'IQ-7788','create trims and persists iqama number');
select is((select iqama_expiry_date from public.operational_staff where display_name='Detail Worker'),'2026-12-31'::date,'create persists iqama expiry date');
select is((select phone_number from public.operational_staff where display_name='Detail Worker'),'+966555000111','create trims and persists phone number');
select is((select email from public.operational_staff where display_name='Detail Worker'),'worker@example.invalid','create trims and persists email');
select is((select email from public.get_supervisor_operational_team(
 '1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','2026-08-09')
 where display_name='Detail Worker'),'worker@example.invalid','supervisor current team restores staff email');
select is((select email from public.get_supervisor_operational_team(
 '1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001','2026-08-09')
 where display_name='Detail Worker'),'worker@example.invalid','same-branch supervisor reads shared employee details');
select set_config('test.employee_detail_worker_id',(select id::text from public.operational_staff where display_name='Detail Worker'),false);

set local role service_role;
select lives_ok($$select * from public.update_supervisor_operational_staff(
 '1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',
 current_setting('test.employee_detail_worker_id')::uuid,
 'Detail Worker','active',array['cleaner'],'ED-02','Manual Company',
 '   ',null,'   ','   ')$$,'blank employee detail fields clear persisted values');
reset role;
select ok((select iqama_number is null and iqama_expiry_date is null and phone_number is null and email is null
 from public.operational_staff where display_name='Detail Worker'),'blank employee detail values become null');

select throws_ok($$insert into public.operational_staff(organization_id,branch_id,display_name,email,created_by)
 values('2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','Bad Email','bad-email','1c000000-0000-4000-8000-000000000001')$$,
 '23514',null,'direct invalid email is rejected');
select * from finish();
rollback;
