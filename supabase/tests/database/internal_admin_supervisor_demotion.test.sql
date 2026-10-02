begin;
select plan(17);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',email,'{}','{}',now(),now()
from (values
 ('1e500000-0000-4000-8000-000000000001'::uuid,'demotion-admin@example.invalid'),
 ('1e500000-0000-4000-8000-000000000002'::uuid,'demotion-target@example.invalid'),
 ('1e500000-0000-4000-8000-000000000003'::uuid,'demotion-replacement@example.invalid')
) users(id,email);
update public.profiles set full_name=case when id='1e500000-0000-4000-8000-000000000002' then 'Demotion Target' else 'Demotion User' end,
  must_change_password=false where id::text like '1e500000-%';
insert into public.internal_admin_memberships(user_id,active) values ('1e500000-0000-4000-8000-000000000001',true);
insert into public.organizations(id,name,slug) values ('2e500000-0000-4000-8000-000000000001','Demotion Org','demotion-org');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','Demotion Branch','DEM','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role,active) values
 ('3e500000-0000-4000-8000-000000000001','1e500000-0000-4000-8000-000000000002','branch_manager',true),
 ('3e500000-0000-4000-8000-000000000001','1e500000-0000-4000-8000-000000000003','branch_manager',true);
insert into public.branch_shifts(id,organization_id,branch_id,name,start_time,end_time) values
 ('4e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','3e500000-0000-4000-8000-000000000001','Demotion Shift','08:00','16:00');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,shift_id,active,company_name) values
 ('5e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','3e500000-0000-4000-8000-000000000001','1e500000-0000-4000-8000-000000000002','4e500000-0000-4000-8000-000000000001',true,'Demotion Team');
create temporary table demotion_ids as
select team.id team_id, assignment.id target_assignment_id
from public.branch_operational_teams team
join public.branch_operational_team_supervisors assignment
  on assignment.operational_team_id=team.id
 and assignment.supervisor_user_id='1e500000-0000-4000-8000-000000000002'
 and assignment.active
where team.legacy_supervisor_team_id='5e500000-0000-4000-8000-000000000001';
insert into public.operational_staff(id,organization_id,branch_id,display_name,employment_status,created_by,deactivated_at,deactivated_by,account_user_id)
values ('7e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','3e500000-0000-4000-8000-000000000001',
 'Demotion Target','inactive','1e500000-0000-4000-8000-000000000001',now(),'1e500000-0000-4000-8000-000000000001','1e500000-0000-4000-8000-000000000002'),
 ('7e500000-0000-4000-8000-000000000002','2e500000-0000-4000-8000-000000000001','3e500000-0000-4000-8000-000000000001',
 'Existing Staff','active','1e500000-0000-4000-8000-000000000001',null,null,null);
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles,created_by_user_id)
select '8e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','3e500000-0000-4000-8000-000000000001',
 '7e500000-0000-4000-8000-000000000002','5e500000-0000-4000-8000-000000000001',team_id,array['kitchen'],'1e500000-0000-4000-8000-000000000001' from demotion_ids;

select throws_ok($$select public.demote_internal_admin_supervisor_to_staff(
 '1e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','1e500000-0000-4000-8000-000000000002',
 '3e500000-0000-4000-8000-000000000001',(select team_id from demotion_ids),array['cashier'],
 array['3e500000-0000-4000-8000-000000000001']::uuid[],array[(select target_assignment_id from demotion_ids)]::uuid[],null
)$$,'23514','replacement primary supervisor required','staffed primary team requires explicit replacement');
select ok((select active from public.branch_memberships where user_id='1e500000-0000-4000-8000-000000000002'),'failed demotion rolls membership back');

select lives_ok($$select public.demote_internal_admin_supervisor_to_staff(
 '1e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','1e500000-0000-4000-8000-000000000002',
 '3e500000-0000-4000-8000-000000000001',(select team_id from demotion_ids),array['cashier','front_of_house'],
 array['3e500000-0000-4000-8000-000000000001']::uuid[],array[(select target_assignment_id from demotion_ids)]::uuid[],
 '1e500000-0000-4000-8000-000000000003'
)$$,'valid replacement and demotion succeed atomically');
select ok(not (select active from public.branch_memberships where user_id='1e500000-0000-4000-8000-000000000002'),'Supervisor access is removed');
select is((select employment_status from public.operational_staff where id='7e500000-0000-4000-8000-000000000001'),'active','linked Staff identity is reactivated');
select is((select count(*) from public.operational_staff where account_user_id='1e500000-0000-4000-8000-000000000002'),1::bigint,'one canonical Staff identity remains');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id='7e500000-0000-4000-8000-000000000001' and active),1::bigint,'one destination assignment is created');
select is((select operational_roles from public.operational_staff_assignments where operational_staff_id='7e500000-0000-4000-8000-000000000001' and active),array['cashier','front_of_house']::text[],'selected roles are preserved');
select ok(not (select active from public.branch_operational_team_supervisors where id=(select target_assignment_id from demotion_ids)),'historical primary assignment remains closed');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1e500000-0000-4000-8000-000000000003' and assignment_role='primary' and active),1::bigint,'replacement becomes primary');
select is((select count(*) from public.operational_staff_assignments where id='8e500000-0000-4000-8000-000000000001' and active),1::bigint,'existing team Staff assignment is unchanged');
select ok(exists(select 1 from public.account_management_audit_logs where action='supervisor_demoted_to_staff' and target_user_id='1e500000-0000-4000-8000-000000000002'),'demotion audit is recorded');
select throws_ok($$select public.demote_internal_admin_supervisor_to_staff(
 '1e500000-0000-4000-8000-000000000001','2e500000-0000-4000-8000-000000000001','1e500000-0000-4000-8000-000000000002',
 '3e500000-0000-4000-8000-000000000001',(select team_id from demotion_ids),array['cashier'],
 '{}'::uuid[],'{}'::uuid[],null
)$$,'40001','supervisor lifecycle changed','repeated demotion fails safely');
select is((select count(*) from public.operational_staff where account_user_id='1e500000-0000-4000-8000-000000000002'),1::bigint,'repeat creates no duplicate Staff identity');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id='7e500000-0000-4000-8000-000000000001' and active),1::bigint,'repeat creates no duplicate assignment');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1e500000-0000-4000-8000-000000000003' and assignment_role='primary' and active),1::bigint,'repeat creates no duplicate primary');
select is((select count(*) from public.branch_memberships where user_id='1e500000-0000-4000-8000-000000000002' and role='staff'),0::bigint,'demotion creates no Staff login membership');

select * from finish();
rollback;
