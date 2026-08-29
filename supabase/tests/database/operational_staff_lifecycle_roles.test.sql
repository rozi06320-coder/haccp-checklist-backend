begin;
select plan(50);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '16100000-0000-4000-8000-000000000001'::uuid,
  '16100000-0000-4000-8000-000000000002',
  '16100000-0000-4000-8000-000000000003',
  '16100000-0000-4000-8000-000000000004'
]) id;
update public.profiles set full_name=case id
  when '16100000-0000-4000-8000-000000000001' then 'Supervisor A'
  when '16100000-0000-4000-8000-000000000002' then 'Supervisor B'
  when '16100000-0000-4000-8000-000000000003' then 'Manager A'
  else 'Other Manager' end,must_change_password=false;

insert into public.organizations(id,name,slug) values
  ('26100000-0000-4000-8000-000000000001','Lifecycle Org','lifecycle-org'),
  ('26100000-0000-4000-8000-000000000002','Other Lifecycle Org','other-lifecycle-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('36100000-0000-4000-8000-000000000001','26100000-0000-4000-8000-000000000001','Branch A','LCA','Asia/Riyadh'),
  ('36100000-0000-4000-8000-000000000002','26100000-0000-4000-8000-000000000001','Branch B','LCB','Asia/Riyadh'),
  ('36100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000002','Other Branch','LCO','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('26100000-0000-4000-8000-000000000001','16100000-0000-4000-8000-000000000003','organization_manager'),
  ('26100000-0000-4000-8000-000000000002','16100000-0000-4000-8000-000000000004','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('36100000-0000-4000-8000-000000000001','16100000-0000-4000-8000-000000000001','branch_manager'),
  ('36100000-0000-4000-8000-000000000002','16100000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('46100000-0000-4000-8000-000000000001','26100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001','16100000-0000-4000-8000-000000000001'),
  ('46100000-0000-4000-8000-000000000002','26100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000002','16100000-0000-4000-8000-000000000002');
select set_config('test.lifecycle_team_a',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='46100000-0000-4000-8000-000000000001'),false);
select set_config('test.lifecycle_team_b',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='46100000-0000-4000-8000-000000000002'),false);
select set_config('test.lifecycle_date',private.phase4a_business_date('Asia/Riyadh')::text,false);

select ok(private.operational_roles_are_valid(array['dispatcher']),'dispatcher is canonical');
select ok(private.operational_roles_are_valid(array['production']),'production is canonical');
select ok(private.operational_roles_are_valid(array['cashier']),'cashier is canonical');
select ok(not private.operational_roles_are_valid(array['packaging']),'legacy packaging is rejected for current writes');
select ok(private.operational_roles_are_valid(array['kitchen','production']),'two unique canonical roles remain supported');

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_team_a')::uuid,'Lifecycle Worker',array['dispatcher','production'],'LC-1','Lifecycle Org','id',null,null,null,null)$$,'new roles persist through the staff RPC');
reset role;
select set_config('test.lifecycle_staff',(select id::text from public.operational_staff where display_name='Lifecycle Worker'),false);
select set_config('test.lifecycle_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.lifecycle_staff')::uuid and active),false);
select is((select operational_roles from public.operational_staff_assignments where id=current_setting('test.lifecycle_assignment')::uuid),array['dispatcher','production']::text[],'roles reload canonically');
select is((select country_code from public.operational_staff where id=current_setting('test.lifecycle_staff')::uuid),'ID','country code normalizes');

set local role service_role;
select lives_ok($$select * from public.set_operational_team_staff_duty('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_date')::date,'on_vacation')$$,'On Vacation persists as a duty state');
reset role;
select is((select employment_status from public.operational_staff where id=current_setting('test.lifecycle_staff')::uuid),'active','vacation does not end employment');
select is((select duty_status from public.operational_staff_duty_statuses where assignment_id=current_setting('test.lifecycle_assignment')::uuid order by created_at desc limit 1),'on_vacation','vacation reloads');
select is((public.get_operational_team_hygiene_current_state('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_team_a')::uuid)->'staff')::text,'[]','vacation staff is excluded from today Hygiene expectation');

set local role service_role;
select lives_ok($$select * from public.set_operational_team_staff_duty('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_date')::date,'on_duty')$$,'return from vacation succeeds');
reset role;
select is((select duty_status from public.operational_staff_duty_statuses where assignment_id=current_setting('test.lifecycle_assignment')::uuid order by created_at desc limit 1),'on_duty','return from vacation reloads');

update public.organization_memberships set active=false
 where organization_id='26100000-0000-4000-8000-000000000001'
   and user_id='16100000-0000-4000-8000-000000000003';
set local role service_role;
select throws_ok($$select * from public.transfer_operational_staff_branch('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment')::uuid,current_setting('test.lifecycle_team_b')::uuid)$$,'42501','staff transfer denied','inactive Manager membership cannot transfer staff');
reset role;
update public.organization_memberships set active=true
 where organization_id='26100000-0000-4000-8000-000000000001'
   and user_id='16100000-0000-4000-8000-000000000003';
update public.organizations set active=false where id='26100000-0000-4000-8000-000000000001';
set local role service_role;
select throws_ok($$select * from public.transfer_operational_staff_branch('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment')::uuid,current_setting('test.lifecycle_team_b')::uuid)$$,'42501','staff transfer denied','inactive organization cannot transfer staff');
reset role;
update public.organizations set active=true where id='26100000-0000-4000-8000-000000000001';
set local role service_role;
select throws_ok($$select * from public.transfer_operational_staff_branch('16100000-0000-4000-8000-000000000001','26100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment')::uuid,current_setting('test.lifecycle_team_b')::uuid)$$,'42501','staff transfer denied','Branch Supervisor cannot transfer staff between branches');
select lives_ok($$select * from public.transfer_operational_staff_branch('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment')::uuid,current_setting('test.lifecycle_team_b')::uuid)$$,'Manager transfers staff between managed branches');
reset role;
select is((select branch_id from public.operational_staff where id=current_setting('test.lifecycle_staff')::uuid),'36100000-0000-4000-8000-000000000002'::uuid,'staff current branch changes');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.lifecycle_staff')::uuid and active),1::bigint,'transfer leaves exactly one active assignment');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.lifecycle_staff')::uuid),2::bigint,'transfer preserves old assignment history');
select is((select closure_reason from public.operational_staff_assignments where id=current_setting('test.lifecycle_assignment')::uuid),'branch_transfer','old assignment records transfer closure');
select set_config('test.lifecycle_assignment_b',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.lifecycle_staff')::uuid and active),false);

set local role service_role;
select throws_ok($$select * from public.transfer_operational_staff_branch('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment')::uuid,current_setting('test.lifecycle_team_a')::uuid)$$,'40001','staff assignment changed','stale concurrent transfer is rejected');
select throws_ok($$select * from public.transfer_operational_staff_branch('16100000-0000-4000-8000-000000000004','26100000-0000-4000-8000-000000000002',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment_b')::uuid,current_setting('test.lifecycle_team_a')::uuid)$$,'42501','staff transfer denied','cross-organization transfer is denied');
reset role;

set local role service_role;
select lives_ok($$select * from public.leave_operational_staff_company('16100000-0000-4000-8000-000000000002','36100000-0000-4000-8000-000000000002',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment_b')::uuid)$$,'authorized Team B supervisor completes Leave Company');
reset role;
select is((select employment_status from public.operational_staff where id=current_setting('test.lifecycle_staff')::uuid),'inactive','Leave Company persists inactive employment');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.lifecycle_staff')::uuid and active),0::bigint,'Leave Company closes the active assignment');
select is((select count(*) from public.operational_staff where id=current_setting('test.lifecycle_staff')::uuid),1::bigint,'Leave Company preserves the staff row');
select is((select closure_reason from public.operational_staff_assignments where id=current_setting('test.lifecycle_assignment_b')::uuid),'left_company','Leave Company records closure attribution');
select throws_ok($$select * from public.leave_operational_staff_company('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000002',current_setting('test.lifecycle_staff')::uuid,current_setting('test.lifecycle_assignment_b')::uuid)$$,'42501','staff leave denied','unauthorized actor cannot repeat Leave Company');

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_team_a')::uuid,'Active Manager Directory Worker',array['kitchen'],'LC-ACTIVE','Lifecycle Org','id',null,null,null,null)$$,'active employee control is created');
select lives_ok($$select * from public.create_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_team_a')::uuid,'Removed Duplicate Worker',array['kitchen'],'LC-REM-DUP','Lifecycle Org','id',null,null,null,null)$$,'duplicate removal employee is created');
select lives_ok($$select * from public.create_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_team_a')::uuid,'Removed Mistake Worker',array['dispatcher'],'LC-REM-MISTAKE','Lifecycle Org','id',null,null,null,null)$$,'added-by-mistake removal employee is created');
select lives_ok($$select * from public.create_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_team_a')::uuid,'Removed Wrong Data Worker',array['production'],'LC-REM-WRONG','Lifecycle Org','id',null,null,null,null)$$,'wrong-data removal employee is created');
select lives_ok($$select * from public.create_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.lifecycle_team_a')::uuid,'Removed Other Worker',array['cashier'],'LC-REM-OTHER','Lifecycle Org','id',null,null,null,null)$$,'other removal employee is created');
reset role;

select set_config('test.active_directory_staff',(select id::text from public.operational_staff where display_name='Active Manager Directory Worker'),false);
select set_config('test.removed_duplicate_staff',(select id::text from public.operational_staff where display_name='Removed Duplicate Worker'),false);
select set_config('test.removed_mistake_staff',(select id::text from public.operational_staff where display_name='Removed Mistake Worker'),false);
select set_config('test.removed_wrong_staff',(select id::text from public.operational_staff where display_name='Removed Wrong Data Worker'),false);
select set_config('test.removed_other_staff',(select id::text from public.operational_staff where display_name='Removed Other Worker'),false);
select set_config('test.removed_duplicate_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.removed_duplicate_staff')::uuid and active),false);
select set_config('test.removed_mistake_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.removed_mistake_staff')::uuid and active),false);
select set_config('test.removed_wrong_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.removed_wrong_staff')::uuid and active),false);
select set_config('test.removed_other_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.removed_other_staff')::uuid and active),false);

insert into public.operational_staff_health_cards(organization_id,branch_id,supervisor_team_id,operational_staff_id,status,certificate_number)
values('26100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001','46100000-0000-4000-8000-000000000001',current_setting('test.removed_duplicate_staff')::uuid,'passed','HC-REM-DUP');

set local role service_role;
select lives_ok($$select * from public.remove_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.removed_duplicate_staff')::uuid,current_setting('test.removed_duplicate_assignment')::uuid,'duplicate',null)$$,'duplicate removal succeeds');
select lives_ok($$select * from public.remove_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.removed_mistake_staff')::uuid,current_setting('test.removed_mistake_assignment')::uuid,'added_by_mistake',null)$$,'added-by-mistake removal succeeds');
select lives_ok($$select * from public.remove_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.removed_wrong_staff')::uuid,current_setting('test.removed_wrong_assignment')::uuid,'wrong_employee_data',null)$$,'wrong-data removal succeeds');
select lives_ok($$select * from public.remove_operational_team_staff('16100000-0000-4000-8000-000000000001','36100000-0000-4000-8000-000000000001',current_setting('test.removed_other_staff')::uuid,current_setting('test.removed_other_assignment')::uuid,'other','Wrong temporary row')$$,'other removal succeeds with note');
reset role;

select ok((select public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('staff_id',current_setting('test.active_directory_staff'))),'active employee appears in Manager directory');
select ok((select public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('staff_id',current_setting('test.lifecycle_staff'))),'Left Company inactive employee remains visible to Manager');
select ok(not ((select public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('staff_id',current_setting('test.removed_duplicate_staff')))),'duplicate removed employee is hidden from Manager directory');
select ok(not ((select public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('staff_id',current_setting('test.removed_mistake_staff')))),'added-by-mistake removed employee is hidden from Manager directory');
select ok(not ((select public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('staff_id',current_setting('test.removed_wrong_staff')))),'wrong-data removed employee is hidden from Manager directory');
select ok(not ((select public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('staff_id',current_setting('test.removed_other_staff')))),'other removed employee is hidden from Manager directory');
select is((select count(*) from public.operational_staff where id in(current_setting('test.removed_duplicate_staff')::uuid,current_setting('test.removed_mistake_staff')::uuid,current_setting('test.removed_wrong_staff')::uuid,current_setting('test.removed_other_staff')::uuid)),4::bigint,'removed staff rows are preserved');
select is((select count(*) from public.operational_staff_removal_audits where operational_staff_id in(current_setting('test.removed_duplicate_staff')::uuid,current_setting('test.removed_mistake_staff')::uuid,current_setting('test.removed_wrong_staff')::uuid,current_setting('test.removed_other_staff')::uuid)),4::bigint,'removed staff reason audits are preserved');
select is((select count(*) from public.operational_staff_health_cards where operational_staff_id=current_setting('test.removed_duplicate_staff')::uuid),1::bigint,'historical health card row remains after removal');
select ok((select public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'health_cards') @> pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('operational_staff_id',current_setting('test.removed_duplicate_staff'))),'Manager historical health-card data still includes removed employee');
select ok((select (public.list_managed_employee_team('16100000-0000-4000-8000-000000000003','26100000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees'->0) ? 'employment_status'),'Manager history retains left employees');

select * from finish();
rollback;
