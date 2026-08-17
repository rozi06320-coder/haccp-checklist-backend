begin;
select plan(22);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '19000000-0000-4000-8000-000000000001'::uuid,
  '19000000-0000-4000-8000-000000000002',
  '19000000-0000-4000-8000-000000000003',
  '19000000-0000-4000-8000-000000000004',
  '19000000-0000-4000-8000-000000000005'
]) id;
update public.profiles
set full_name = case id
    when '19000000-0000-4000-8000-000000000001' then 'Bootstrap Supervisor A'
    when '19000000-0000-4000-8000-000000000002' then 'Bootstrap Supervisor B'
    when '19000000-0000-4000-8000-000000000003' then 'Bootstrap Manager'
    when '19000000-0000-4000-8000-000000000004' then 'Disabled Supervisor'
    else 'Other Branch Supervisor'
  end,
  must_change_password = false
where id::text like '19000000-%';
update public.profiles set disabled_at = now() where id = '19000000-0000-4000-8000-000000000004';

insert into public.organizations(id,name,slug,active) values
  ('29000000-0000-4000-8000-000000000001','Bootstrap Org A','bootstrap-org-a',true),
  ('29000000-0000-4000-8000-000000000002','Bootstrap Org B','bootstrap-org-b',true),
  ('29000000-0000-4000-8000-000000000003','Bootstrap Inactive Org','bootstrap-inactive-org',false);
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('39000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','Bootstrap Branch A','BTA','Asia/Riyadh',true),
  ('39000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000002','Bootstrap Branch B','BTB','Asia/Riyadh',true),
  ('39000000-0000-4000-8000-000000000003','29000000-0000-4000-8000-000000000001','Inactive Branch','BTI','Asia/Riyadh',false),
  ('39000000-0000-4000-8000-000000000004','29000000-0000-4000-8000-000000000003','Inactive Org Branch','BIO','Asia/Riyadh',true);
insert into public.organization_memberships(organization_id,user_id,role) values
  ('29000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000001','branch_manager'),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000002','branch_manager'),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000004','branch_manager'),
  ('39000000-0000-4000-8000-000000000002','19000000-0000-4000-8000-000000000005','branch_manager');

select is((select count(*) from public.branch_operational_teams where branch_id = '39000000-0000-4000-8000-000000000001'), 0::bigint, 'new branch starts with zero operational teams');
select is((select count(*) from public.get_supervisor_operational_team('19000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',current_date)), 0::bigint, 'zero-team supervisor gets empty team rows for adapter setup-required state');

create temporary table created_supervisor_team on commit drop as
select * from public.create_supervisor_owned_operational_team(
  '19000000-0000-4000-8000-000000000001',
  '39000000-0000-4000-8000-000000000001',
  '  Ahmed   Team  '
);

select is((select team_name from created_supervisor_team), 'Ahmed Team', 'Supervisor-created team name is normalized');
select is((select count(*) from public.branch_operational_teams where id = (select team_id from created_supervisor_team) and branch_id = '39000000-0000-4000-8000-000000000001'), 1::bigint, 'canonical operational team row is created');
select is((select count(*) from public.branch_supervisor_teams where id = (select legacy_supervisor_team_id from created_supervisor_team)), 1::bigint, 'legacy compatibility row is created');
select is((select legacy_supervisor_team_id from public.branch_operational_teams where id = (select team_id from created_supervisor_team)), (select legacy_supervisor_team_id from created_supervisor_team), 'canonical team links to legacy compatibility row');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id = (select team_id from created_supervisor_team) and supervisor_user_id = '19000000-0000-4000-8000-000000000001' and assignment_role = 'primary' and active), 1::bigint, 'creator receives active primary assignment');
select ok((select can_write from created_supervisor_team), 'RPC returns can_write=true for creator');
select ok(private.actor_can_write_operational_team('19000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',(select team_id from created_supervisor_team)), 'creator can write the new team');
select ok(not private.actor_can_write_operational_team('19000000-0000-4000-8000-000000000002','39000000-0000-4000-8000-000000000001',(select team_id from created_supervisor_team)), 'second Supervisor cannot write without assignment');
select is((select count(distinct team_id) from public.get_supervisor_operational_team('19000000-0000-4000-8000-000000000002','39000000-0000-4000-8000-000000000001',current_date)), 1::bigint, 'second Supervisor can still read branch teams');
select set_config('test.created_supervisor_team', (select team_id::text from created_supervisor_team), false);

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('19000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',current_setting('test.created_supervisor_team')::uuid,'Team Employee',array['kitchen'],null,'Bootstrap Org A',null,null,null,null,null)$$, 'existing staff creation works after bootstrap');
reset role;

select throws_ok($$select * from public.create_supervisor_owned_operational_team('19000000-0000-4000-8000-000000000002','39000000-0000-4000-8000-000000000001','ahmed team')$$, '23505', null, 'duplicate active team name in branch is rejected');
select throws_ok($$select * from public.create_supervisor_owned_operational_team('19000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Second A Team')$$, '23505', null, 'already-assigned creator cannot bootstrap another owned team');

create temporary table second_supervisor_team on commit drop as
select * from public.create_supervisor_owned_operational_team(
  '19000000-0000-4000-8000-000000000002',
  '39000000-0000-4000-8000-000000000001',
  'Supervisor B Team'
);
select is((select count(*) from public.branch_operational_teams where branch_id = '39000000-0000-4000-8000-000000000001'), 2::bigint, 'multiple Supervisors can own separate teams in one branch');
select ok(not private.actor_can_write_operational_team('19000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',(select team_id from second_supervisor_team)), 'Supervisor A cannot write Supervisor B team');

select throws_ok($$select * from public.create_supervisor_owned_operational_team('19000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000002','Cross Branch Team')$$, '42501', null, 'cross-branch creation is rejected');
select throws_ok($$select * from public.create_supervisor_owned_operational_team('19000000-0000-4000-8000-000000000003','39000000-0000-4000-8000-000000000001','Manager Team')$$, '42501', null, 'organization manager without supervisor membership is rejected');
select throws_ok($$select * from public.create_supervisor_owned_operational_team('19000000-0000-4000-8000-000000000004','39000000-0000-4000-8000-000000000001','Disabled Team')$$, '42501', null, 'disabled profile is rejected');
select throws_ok($$select * from public.create_supervisor_owned_operational_team('19000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000003','Inactive Branch Team')$$, '42501', null, 'inactive branch is rejected');
select throws_ok($$select * from public.create_supervisor_owned_operational_team('19000000-0000-4000-8000-000000000005','39000000-0000-4000-8000-000000000004','Inactive Org Team')$$, '42501', null, 'inactive organization is rejected');
select ok(not has_function_privilege('authenticated','public.create_supervisor_owned_operational_team(uuid,uuid,text)','execute') and has_function_privilege('service_role','public.create_supervisor_owned_operational_team(uuid,uuid,text)','execute'), 'bootstrap RPC is service-role only');

select * from finish();
rollback;
