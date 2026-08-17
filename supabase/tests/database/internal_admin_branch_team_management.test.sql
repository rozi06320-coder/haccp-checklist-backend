begin;
select plan(39);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1e400000-0000-4000-8000-000000000001'::uuid, 'internal-admin@example.invalid'),
  ('1e400000-0000-4000-8000-000000000002'::uuid, 'primary-supervisor@example.invalid'),
  ('1e400000-0000-4000-8000-000000000003'::uuid, 'backup-supervisor@example.invalid'),
  ('1e400000-0000-4000-8000-000000000004'::uuid, 'other-org-supervisor@example.invalid'),
  ('1e400000-0000-4000-8000-000000000005'::uuid, 'not-admin@example.invalid'),
  ('1e400000-0000-4000-8000-000000000006'::uuid, 'manager@example.invalid'),
  ('1e400000-0000-4000-8000-000000000007'::uuid, 'readonly-supervisor@example.invalid')
) users(id, email);

update public.profiles
set full_name = case id
  when '1e400000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1e400000-0000-4000-8000-000000000002' then 'Primary Supervisor'
  when '1e400000-0000-4000-8000-000000000003' then 'Backup Supervisor'
  when '1e400000-0000-4000-8000-000000000004' then 'Other Org Supervisor'
  when '1e400000-0000-4000-8000-000000000006' then 'Organization Manager'
  when '1e400000-0000-4000-8000-000000000007' then 'Readonly Supervisor'
  else 'Not Admin'
end,
must_change_password = false
where id::text like '1e400000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1e400000-0000-4000-8000-000000000001', true);

insert into public.organizations(id,name,slug) values
  ('2e400000-0000-4000-8000-000000000001','Team Org','team-org'),
  ('2e400000-0000-4000-8000-000000000002','Other Team Org','other-team-org');

insert into public.organization_memberships(organization_id,user_id,role,active)
values ('2e400000-0000-4000-8000-000000000001','1e400000-0000-4000-8000-000000000006','organization_manager',true);

insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('3e400000-0000-4000-8000-000000000001','2e400000-0000-4000-8000-000000000001','Main Branch','MAIN','Asia/Riyadh',true),
  ('3e400000-0000-4000-8000-000000000002','2e400000-0000-4000-8000-000000000001','Second Branch','SECOND','Asia/Riyadh',true),
  ('3e400000-0000-4000-8000-000000000003','2e400000-0000-4000-8000-000000000002','Other Branch','OTHER','Asia/Riyadh',true),
  ('3e400000-0000-4000-8000-000000000004','2e400000-0000-4000-8000-000000000001','Inactive Branch','INACTIVE','Asia/Riyadh',false);

insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('3e400000-0000-4000-8000-000000000001','1e400000-0000-4000-8000-000000000002','branch_manager',true),
  ('3e400000-0000-4000-8000-000000000001','1e400000-0000-4000-8000-000000000003','branch_manager',true),
  ('3e400000-0000-4000-8000-000000000001','1e400000-0000-4000-8000-000000000007','branch_manager',true),
  ('3e400000-0000-4000-8000-000000000002','1e400000-0000-4000-8000-000000000002','branch_manager',true),
  ('3e400000-0000-4000-8000-000000000003','1e400000-0000-4000-8000-000000000004','branch_manager',true);

create temp table created_team as
select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000001',
  ' Kitchen Team ',
  ' Manual Company ',
  '1e400000-0000-4000-8000-000000000002',
  '1e400000-0000-4000-8000-000000000003',
  pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'display_name',' Kitchen   Staff ',
      'company_name',' Manual Company ',
      'staff_code',' KS-01 ',
      'country_code',' id ',
      'operational_roles',pg_catalog.jsonb_build_array('kitchen','dispatcher')
    ),
    pg_catalog.jsonb_build_object(
      'display_name',' Cashier Staff ',
      'company_name',' Manual Company ',
      'staff_code',' CS-01 ',
      'country_code','SA',
      'operational_roles',pg_catalog.jsonb_build_array('cashier')
    )
  )
);

select is((select count(*) from created_team),1::bigint,'internal admin creates one canonical operational team result');
select is((select team_name from created_team),'Kitchen Team','canonical team name is trimmed');
select is((select company_name from created_team),'Manual Company','company name is trimmed');
select is((select branch_code from created_team),'MAIN','returned row includes branch code');
select is((select supervisor_email from created_team),'primary-supervisor@example.invalid','returned row includes primary supervisor');
select is((select backup_supervisors->0->>'supervisor_email' from created_team),'backup-supervisor@example.invalid','returned row includes backup supervisor');
select is((select operational_staff_count from created_team),2::bigint,'initial staff rows are included in atomic create');

select is(
  (select count(*) from public.branch_operational_teams team join created_team result on result.team_id=team.id where team.organization_id=result.organization_id and team.branch_id=result.branch_id and team.name='Kitchen Team' and team.active),
  1::bigint,
  'canonical operational team row belongs to the requested org and branch'
);

select ok(
  (select legacy_supervisor_team_id is not null from public.branch_operational_teams where id=(select team_id from created_team)),
  'legacy compatibility mapping exists for assignment validator'
);

select is(
  (select active from public.branch_supervisor_teams where id=(select legacy_supervisor_team_id from public.branch_operational_teams where id=(select team_id from created_team))),
  false,
  'legacy compatibility row is not the authoritative active team'
);

select is(
  (select count(*) from public.branch_operational_team_supervisors where operational_team_id=(select team_id from created_team) and assignment_role='primary' and active),
  1::bigint,
  'primary canonical supervisor assignment exists'
);
select is(
  (select count(*) from public.branch_operational_team_supervisors where operational_team_id=(select team_id from created_team) and assignment_role='backup' and active),
  1::bigint,
  'backup canonical supervisor assignment exists'
);

select is(
  (select count(*) from public.operational_staff_assignments where operational_team_id=(select team_id from created_team) and operational_team_id is not null and active),
  2::bigint,
  'initial staff assignments store canonical operational_team_id'
);

select ok(
  exists(select 1 from public.operational_staff where staff_code='CS-01' and display_name='Cashier Staff'),
  'cashier staff row exists'
);

select is(
  (select staff.country_code from public.operational_staff staff where staff.staff_code='KS-01'),
  'ID',
  'country code is normalized and persisted'
);

select is(
  (select assignment.operational_roles from public.operational_staff_assignments assignment join public.operational_staff staff on staff.id=assignment.operational_staff_id where staff.staff_code='CS-01'),
  array['cashier']::text[],
  'cashier operational role persists'
);

select is(
  (select count(*) from public.list_internal_admin_branch_teams('1e400000-0000-4000-8000-000000000001','2e400000-0000-4000-8000-000000000001') where team_id=(select team_id from created_team) and team_name='Kitchen Team' and operational_staff_count=2),
  1::bigint,
  'internal admin list reads canonical operational teams'
);

select is(
  (select staff->0->>'display_name' from public.list_internal_admin_branch_teams('1e400000-0000-4000-8000-000000000001','2e400000-0000-4000-8000-000000000001') where team_id=(select team_id from created_team)),
  'Cashier Staff',
  'internal admin list returns staff rows from canonical assignments'
);

insert into public.branch_operational_teams(id,organization_id,branch_id,name,active)
values('4e400000-0000-4000-8000-000000000099','2e400000-0000-4000-8000-000000000001','3e400000-0000-4000-8000-000000000001','Unassigned Team',true);

select is(
  (select count(*) from public.list_internal_admin_branch_teams('1e400000-0000-4000-8000-000000000001','2e400000-0000-4000-8000-000000000001') where team_id='4e400000-0000-4000-8000-000000000099' and supervisor_user_id is null and supervisor_email is null and supervisor_role is null),
  1::bigint,
  'internal admin list shows canonical operational teams without active primary supervisor'
);

select is(
  (select count(distinct team_id) from public.get_supervisor_operational_team('1e400000-0000-4000-8000-000000000002','3e400000-0000-4000-8000-000000000001',current_date) where team_id=(select team_id from created_team) and can_write),
  1::bigint,
  'primary supervisor can read and write newly created canonical team'
);

select is(
  (select count(distinct team_id) from public.get_supervisor_operational_team('1e400000-0000-4000-8000-000000000003','3e400000-0000-4000-8000-000000000001',current_date) where team_id=(select team_id from created_team) and can_write),
  1::bigint,
  'backup supervisor can read and write newly created canonical team'
);

select is(
  (select count(distinct team_id) from public.get_supervisor_operational_team('1e400000-0000-4000-8000-000000000007','3e400000-0000-4000-8000-000000000001',current_date) where team_id=(select team_id from created_team) and not can_write),
  1::bigint,
  'same-branch unassigned supervisor can read without write access'
);

select is(
  pg_catalog.jsonb_array_length(public.get_operational_team_hygiene_current_state('1e400000-0000-4000-8000-000000000002','3e400000-0000-4000-8000-000000000001',(select team_id from created_team))->'staff'),
  2,
  'Daily Hygiene roster sees newly created staff'
);

select is(
  (select public.list_managed_employee_team('1e400000-0000-4000-8000-000000000006','2e400000-0000-4000-8000-000000000001',null,date_trunc('month',current_date)::date)->'employees'->0->>'operational_team_name'),
  'Kitchen Team',
  'Manager Employee Directory sees canonical team name'
);

select throws_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000001',
  'Kitchen Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000002',
  null,
  '[]'::jsonb
)$$,'23505','branch team already exists','duplicate team in same branch rejected');

select lives_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000002',
  'Kitchen Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000002',
  null,
  '[]'::jsonb
)$$,'same team name is allowed in another branch');

select throws_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000004',
  'Inactive Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000002',
  null,
  '[]'::jsonb
)$$,'22023','invalid branch team request','inactive branch rejected');

select throws_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000003',
  'Other Branch Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000002',
  null,
  '[]'::jsonb
)$$,'22023','invalid branch team request','cross-org branch rejected');

select throws_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000001',
  'Invalid Supervisor Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000004',
  null,
  '[]'::jsonb
)$$,'23514','invalid supervisor assignment','cross-org supervisor rejected');

select throws_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000001',
  'Duplicate Staff Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000002',
  null,
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'display_name','Duplicate Staff',
    'company_name','Manual Company',
    'staff_code','KS-01',
    'country_code','SA',
    'operational_roles',pg_catalog.jsonb_build_array('kitchen')
  ))
)$$,'23505','employee code already exists','duplicate staff code rejected safely');

select throws_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000001',
  'Rollback Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000002',
  null,
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'display_name','Bad Role',
    'company_name','Manual Company',
    'staff_code','BAD-01',
    'country_code','SA',
    'operational_roles',pg_catalog.jsonb_build_array('packaging')
  ))
)$$,'22023','invalid branch team staff request','invalid staff row rejects atomic create');

select is(
  (select count(*) from public.branch_operational_teams where branch_id='3e400000-0000-4000-8000-000000000001' and normalized_name=private.normalize_operational_team_name('Rollback Team')),
  0::bigint,
  'failed atomic create leaves no orphan canonical team'
);

select lives_ok($$select * from public.create_internal_admin_branch_team_staff(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  (select team_id from created_team),
  ' Cleaner Staff ',
  ' Manual Company ',
  ' CL-01 ',
  ' PH ',
  array['cleaner']
)$$,'standalone staff create accepts canonical operational team id');

select is(
  (select count(*) from public.operational_staff_assignments where operational_team_id=(select team_id from created_team) and operational_team_id is not null and active),
  3::bigint,
  'standalone staff assignment also stores canonical operational_team_id'
);

select throws_ok($$select * from public.create_internal_admin_operational_team(
  '1e400000-0000-4000-8000-000000000005',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000001',
  'Denied Team',
  'Manual Company',
  '1e400000-0000-4000-8000-000000000002',
  null,
  '[]'::jsonb
)$$,'42501','internal admin access denied','non-admin cannot create canonical team');

select throws_ok($$select * from public.list_internal_admin_branch_teams(
  '1e400000-0000-4000-8000-000000000005',
  '2e400000-0000-4000-8000-000000000001'
)$$,'42501','internal admin access denied','non-admin cannot list branch teams');

select throws_ok($$select * from public.get_operational_team_hygiene_current_state(
  '1e400000-0000-4000-8000-000000000004',
  '3e400000-0000-4000-8000-000000000001',
  (select team_id from created_team)
)$$,'42501','hygiene access denied','other organization supervisor cannot read hygiene roster');

select ok(
  not has_function_privilege('authenticated','public.create_internal_admin_operational_team(uuid,uuid,uuid,text,text,uuid,uuid,jsonb)','execute')
  and not has_function_privilege('authenticated','public.create_internal_admin_branch_team(uuid,uuid,uuid,uuid,text)','execute')
  and not has_function_privilege('authenticated','public.list_internal_admin_branch_teams(uuid,uuid)','execute')
  and not has_function_privilege('authenticated','public.create_internal_admin_branch_team_staff(uuid,uuid,uuid,text,text,text,text,text[])','execute'),
  'authenticated role cannot execute branch team RPCs directly'
);

select throws_ok($$select * from public.create_internal_admin_branch_team(
  '1e400000-0000-4000-8000-000000000001',
  '2e400000-0000-4000-8000-000000000001',
  '3e400000-0000-4000-8000-000000000001',
  '1e400000-0000-4000-8000-000000000002',
  'Kitchen Team'
)$$,'23505','branch team already exists','legacy compatibility wrapper writes canonical teams');

select * from finish();
rollback;
