begin;
select plan(21);

select has_column('public','branch_supervisor_teams','shift_id','legacy team shift column retained');
select col_is_null('public','branch_supervisor_teams','shift_id','team shift is nullable');
select has_column('public','operational_staff_assignments','shift_id','legacy assignment shift retained');
select col_is_null('public','operational_staff_assignments','shift_id','assignment shift is nullable');
select has_index('public','branch_supervisor_teams','branch_supervisor_teams_active_supervisor_branch_key',
  'one active team per supervisor and branch is enforced');

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','14000000-0000-4000-8000-000000000001',
 'authenticated','authenticated','manager@example.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','14000000-0000-4000-8000-000000000002',
 'authenticated','authenticated','supervisor@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Manager',must_change_password=false
 where id='14000000-0000-4000-8000-000000000001';
update public.profiles set full_name='Supervisor',must_change_password=false
 where id='14000000-0000-4000-8000-000000000002';
insert into public.organizations(id,name,slug)
 values('24000000-0000-4000-8000-000000000001','Shift Free Org','shift-free-org');
insert into public.branches(id,organization_id,name,code,timezone)
 values('34000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001',
 'Branch','SFB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
 values('24000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000001','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)
 values('34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000002','branch_manager');

select lives_ok($$select * from public.create_managed_supervisor_team(
 '14000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001',
 '34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000002')$$,
 'manager ensures a team without a shift');
select is((select count(*) from public.branch_supervisor_teams
 where organization_id='24000000-0000-4000-8000-000000000001'
 and branch_id='34000000-0000-4000-8000-000000000001'
 and supervisor_user_id='14000000-0000-4000-8000-000000000002' and active),1::bigint,
 'one active team exists');
select is((select shift_id from public.branch_supervisor_teams
 where organization_id='24000000-0000-4000-8000-000000000001'
 and branch_id='34000000-0000-4000-8000-000000000001'
 and supervisor_user_id='14000000-0000-4000-8000-000000000002' and active),null::uuid,
 'new team has no shift');
select lives_ok($$select * from public.create_managed_supervisor_team(
 '14000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001',
 '34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000002')$$,
 'ensure operation is idempotent');
select is((select count(*) from public.branch_supervisor_teams
 where organization_id='24000000-0000-4000-8000-000000000001'
 and branch_id='34000000-0000-4000-8000-000000000001'
 and supervisor_user_id='14000000-0000-4000-8000-000000000002' and active),1::bigint,
 'ensure does not duplicate the active team');
select lives_ok($$select * from public.create_supervisor_operational_staff(
 '14000000-0000-4000-8000-000000000002','34000000-0000-4000-8000-000000000001',
 'Worker',array['kitchen'])$$,'supervisor creates staff without a shift');
select is((select assignment.shift_id from public.operational_staff_assignments assignment
 join public.operational_staff staff on staff.id=assignment.operational_staff_id
 where assignment.organization_id='24000000-0000-4000-8000-000000000001'
 and assignment.branch_id='34000000-0000-4000-8000-000000000001'
 and staff.created_by='14000000-0000-4000-8000-000000000002' and assignment.active),null::uuid,
 'new assignment has no shift');
select is((select count(*) from public.get_supervisor_operational_team(
 '14000000-0000-4000-8000-000000000002','34000000-0000-4000-8000-000000000001',
 '2026-07-31')),1::bigint,'valid supervisor access remains');
select throws_ok($$insert into public.branch_supervisor_teams(
 organization_id,branch_id,supervisor_user_id) values(
 '24000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',
 '14000000-0000-4000-8000-000000000002')$$,'23505',null,
 'duplicate active supervisor team is rejected');
select throws_ok($$select * from public.update_managed_supervisor_team(
 '14000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001',
 '34000000-0000-4000-8000-000000000001',
 (select id from public.branch_supervisor_teams
  where organization_id='24000000-0000-4000-8000-000000000001'
  and branch_id='34000000-0000-4000-8000-000000000001'
  and supervisor_user_id='14000000-0000-4000-8000-000000000002' and active),false)$$,
 '23514','team has active dependencies','active assignments prevent team deactivation');
update public.operational_staff set employment_status='inactive',deactivated_at=now(),
 deactivated_by='14000000-0000-4000-8000-000000000002'
 where organization_id='24000000-0000-4000-8000-000000000001'
 and branch_id='34000000-0000-4000-8000-000000000001'
 and created_by='14000000-0000-4000-8000-000000000002';
update public.operational_staff_assignments set active=false
 where organization_id='24000000-0000-4000-8000-000000000001'
 and branch_id='34000000-0000-4000-8000-000000000001';
select lives_ok($$select * from public.update_managed_supervisor_team(
 '14000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001',
 '34000000-0000-4000-8000-000000000001',
 (select id from public.branch_supervisor_teams
  where organization_id='24000000-0000-4000-8000-000000000001'
  and branch_id='34000000-0000-4000-8000-000000000001'
  and supervisor_user_id='14000000-0000-4000-8000-000000000002' and active),false)$$,
 'team can be deactivated after assignments are handled');
select is((select count(*) from public.get_supervisor_operational_team(
 '14000000-0000-4000-8000-000000000002','34000000-0000-4000-8000-000000000001',
 '2026-07-31')),1::bigint,'inactive legacy supervisor assignment leaves branch team visible for read');
select ok(not private.actor_can_write_operational_team(
 '14000000-0000-4000-8000-000000000002','34000000-0000-4000-8000-000000000001',
 (select id from public.branch_operational_teams
  where legacy_supervisor_team_id=(select id from public.branch_supervisor_teams
   where organization_id='24000000-0000-4000-8000-000000000001'
   and branch_id='34000000-0000-4000-8000-000000000001'
   and supervisor_user_id='14000000-0000-4000-8000-000000000002'
   order by created_at desc,id limit 1))),
 'inactive team write helper is false');
select throws_ok($$select * from public.create_operational_team_staff(
 '14000000-0000-4000-8000-000000000002','34000000-0000-4000-8000-000000000001',
 (select id from public.branch_operational_teams
  where legacy_supervisor_team_id=(select id from public.branch_supervisor_teams
   where organization_id='24000000-0000-4000-8000-000000000001'
   and branch_id='34000000-0000-4000-8000-000000000001'
   and supervisor_user_id='14000000-0000-4000-8000-000000000002'
   order by created_at desc,id limit 1)),
 'Inactive Worker',array['kitchen'],'INACTIVE-TEAM-1','Shift Free Org','SA',null,null,null,null)$$,
 '42501','staff operation denied','inactive team write mutation is denied');
select is((select count(*) from public.branch_shifts
 where organization_id='24000000-0000-4000-8000-000000000001'),0::bigint,
 'deprecated shift compatibility rows are preserved without being required');
select ok(obj_description('public.branch_shifts'::regclass) like 'Deprecated%',
 'legacy shift table is documented as deprecated');
select * from finish();
rollback;
