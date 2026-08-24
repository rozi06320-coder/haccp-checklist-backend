begin;
select plan(42);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1f400000-0000-4000-8000-000000000001'::uuid, 'phase4-internal-admin@example.invalid'),
  ('1f400000-0000-4000-8000-000000000002'::uuid, 'phase4-manager@example.invalid'),
  ('1f400000-0000-4000-8000-000000000003'::uuid, 'phase4-supervisor@example.invalid'),
  ('1f400000-0000-4000-8000-000000000004'::uuid, 'phase4-disabled@example.invalid'),
  ('1f400000-0000-4000-8000-000000000005'::uuid, 'phase4-not-admin@example.invalid')
) users(id, email);

update public.profiles
set full_name = case id
    when '1f400000-0000-4000-8000-000000000001' then 'Phase 4 Internal Admin'
    when '1f400000-0000-4000-8000-000000000002' then 'Phase 4 Manager'
    when '1f400000-0000-4000-8000-000000000003' then 'Phase 4 Supervisor'
    when '1f400000-0000-4000-8000-000000000004' then 'Phase 4 Disabled Manager'
    else 'Phase 4 Not Admin'
  end,
  must_change_password = false
where id::text like '1f400000-%';
update public.profiles
set disabled_at = now()
where id = '1f400000-0000-4000-8000-000000000004';

insert into public.internal_admin_memberships(user_id, active)
values ('1f400000-0000-4000-8000-000000000001', true);

insert into public.organizations(id, name, name_ar, slug, active) values
  ('2f400000-0000-4000-8000-000000000001', 'Lifecycle Org', 'منظمة قديمة', 'lifecycle-org', true),
  ('2f400000-0000-4000-8000-000000000002', 'Duplicate Lifecycle Org', null, 'duplicate-lifecycle-org', true),
  ('2f400000-0000-4000-8000-000000000003', 'Inactive Parent Org', null, 'inactive-parent-org', false);

insert into public.organization_memberships(organization_id, user_id, role) values
  ('2f400000-0000-4000-8000-000000000001', '1f400000-0000-4000-8000-000000000002', 'organization_manager'),
  ('2f400000-0000-4000-8000-000000000001', '1f400000-0000-4000-8000-000000000004', 'organization_manager');

insert into public.branches(id, organization_id, name, name_ar, code, timezone, active) values
  ('3f400000-0000-4000-8000-000000000001', '2f400000-0000-4000-8000-000000000001', 'Lifecycle Branch', 'فرع قديم', 'LIFE', 'Asia/Riyadh', true),
  ('3f400000-0000-4000-8000-000000000002', '2f400000-0000-4000-8000-000000000001', 'Duplicate Branch', null, 'DUPB', 'Asia/Riyadh', true),
  ('3f400000-0000-4000-8000-000000000003', '2f400000-0000-4000-8000-000000000003', 'Inactive Parent Branch', null, 'INPB', 'UTC', false);

insert into public.branch_memberships(branch_id, user_id, role) values
  ('3f400000-0000-4000-8000-000000000001', '1f400000-0000-4000-8000-000000000003', 'branch_manager');

insert into public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id, active) values
  ('4f400000-0000-4000-8000-000000000001', '2f400000-0000-4000-8000-000000000001', '3f400000-0000-4000-8000-000000000001', '1f400000-0000-4000-8000-000000000003', true);
select set_config('test.lifecycle_operational_team', (select id::text from public.branch_operational_teams where legacy_supervisor_team_id='4f400000-0000-4000-8000-000000000001'), false);

insert into public.checklist_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, checklist_type, definition_id, state, branch_name_snapshot, branch_code_snapshot, supervisor_name_snapshot
) values (
  '5f400000-0000-4000-8000-000000000001',
  '2f400000-0000-4000-8000-000000000001',
  '3f400000-0000-4000-8000-000000000001',
  '1f400000-0000-4000-8000-000000000003',
  '4f400000-0000-4000-8000-000000000001',
  '2026-08-24',
  'kitchen_opening',
  'kitchen_opening_v1',
  'draft',
  'Lifecycle Branch',
  'LIFE',
  'Phase 4 Supervisor'
);

insert into public.operational_staff(id, organization_id, branch_id, display_name, employment_status, created_by, staff_code, deactivated_at, deactivated_by) values
  ('7f400000-0000-4000-8000-000000000001', '2f400000-0000-4000-8000-000000000001', '3f400000-0000-4000-8000-000000000001', 'Lifecycle Staff', 'active', '1f400000-0000-4000-8000-000000000002', 'LC-1', null, null),
  ('7f400000-0000-4000-8000-000000000002', '2f400000-0000-4000-8000-000000000001', '3f400000-0000-4000-8000-000000000001', 'Inactive Lifecycle Staff', 'inactive', '1f400000-0000-4000-8000-000000000002', 'LC-2', now(), '1f400000-0000-4000-8000-000000000002');

insert into public.operational_staff_assignments(
  id, organization_id, branch_id, operational_staff_id, supervisor_team_id, operational_team_id, operational_roles, active, valid_to
) values
  ('8f400000-0000-4000-8000-000000000001', '2f400000-0000-4000-8000-000000000001', '3f400000-0000-4000-8000-000000000001', '7f400000-0000-4000-8000-000000000001', '4f400000-0000-4000-8000-000000000001', current_setting('test.lifecycle_operational_team')::uuid, array['kitchen'], true, null),
  ('8f400000-0000-4000-8000-000000000002', '2f400000-0000-4000-8000-000000000001', '3f400000-0000-4000-8000-000000000001', '7f400000-0000-4000-8000-000000000002', '4f400000-0000-4000-8000-000000000001', current_setting('test.lifecycle_operational_team')::uuid, array['cashier'], false, current_date);

insert into public.operational_staff_supervisor_training(
  id, organization_id, operational_staff_id, branch_id_at_start, status, started_by_user_id, cancelled_at, cancelled_by_user_id
) values (
  '9f400000-0000-4000-8000-000000000001',
  '2f400000-0000-4000-8000-000000000001',
  '7f400000-0000-4000-8000-000000000001',
  '3f400000-0000-4000-8000-000000000001',
  'cancelled',
  '1f400000-0000-4000-8000-000000000002',
  now(),
  '1f400000-0000-4000-8000-000000000002'
);

select ok(has_function_privilege('service_role','public.update_internal_admin_organization(uuid,uuid,text,text)','execute'),'service role can execute organization update RPC');
select ok(not has_function_privilege('authenticated','public.update_internal_admin_organization(uuid,uuid,text,text)','execute'),'authenticated cannot execute organization update RPC');
select ok(has_function_privilege('service_role','public.update_internal_admin_branch(uuid,uuid,uuid,text,text,text,text,text,text,text)','execute'),'service role can execute branch update RPC');
select ok(not has_function_privilege('authenticated','public.update_internal_admin_branch(uuid,uuid,uuid,text,text,text,text,text,text,text)','execute'),'authenticated cannot execute branch update RPC');

create temporary table updated_org on commit drop as
select * from public.update_internal_admin_organization(
  '1f400000-0000-4000-8000-000000000001',
  '2f400000-0000-4000-8000-000000000001',
  '  Renamed   Lifecycle Org  ',
  ' منظمة جديدة '
);
select is((select name from updated_org),'Renamed Lifecycle Org','Internal Admin edits English organization name');
select is((select name_ar from updated_org),'منظمة جديدة','Internal Admin edits Arabic organization name');
select is((select slug from updated_org),'lifecycle-org','organization slug remains stable after rename');
select throws_ok(
  $$select public.update_internal_admin_organization('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001','Duplicate Lifecycle Org',null)$$,
  '23505',
  'organization already exists',
  'duplicate organization name is rejected'
);
select throws_ok(
  $$select public.update_internal_admin_organization('1f400000-0000-4000-8000-000000000005','2f400000-0000-4000-8000-000000000001','Not Admin Update',null)$$,
  '42501',
  'internal admin access required',
  'non-Internal Admin cannot update organization'
);

select lives_ok(
  $$select public.deactivate_internal_admin_organization('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001')$$,
  'Internal Admin deactivates organization'
);
select is((select active from public.organizations where id='2f400000-0000-4000-8000-000000000001'),false,'organization active flag becomes false');
select is((select active from public.branches where id='3f400000-0000-4000-8000-000000000001'),true,'organization deactivate does not deactivate child branch');
select ok(not private.actor_manages_active_organization('1f400000-0000-4000-8000-000000000002','2f400000-0000-4000-8000-000000000001'),'manager active access is blocked after organization deactivation');
select ok(not private.actor_can_read_operational_branch('1f400000-0000-4000-8000-000000000003','3f400000-0000-4000-8000-000000000001'),'supervisor active access is blocked after organization deactivation');
select is(
  (select count(*) from public.list_internal_admin_organizations('1f400000-0000-4000-8000-000000000001') where id='2f400000-0000-4000-8000-000000000001' and not active),
  1::bigint,
  'inactive organization remains listable by Internal Admin'
);
select lives_ok(
  $$select public.reactivate_internal_admin_organization('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001')$$,
  'Internal Admin reactivates organization'
);
select is((select active from public.organizations where id='2f400000-0000-4000-8000-000000000001'),true,'organization active flag becomes true');
select is((select disabled_at is not null from public.profiles where id='1f400000-0000-4000-8000-000000000004'),true,'disabled users remain disabled after organization reactivation');
select is((select active from public.branches where id='3f400000-0000-4000-8000-000000000003'),false,'inactive child branch remains inactive after organization reactivation');

create temporary table updated_branch on commit drop as
select * from public.update_internal_admin_branch(
  '1f400000-0000-4000-8000-000000000001',
  '2f400000-0000-4000-8000-000000000001',
  '3f400000-0000-4000-8000-000000000001',
  '  Renamed   Lifecycle Branch  ',
  ' فرع جديد ',
  ' hun-ruh-001 ',
  'Riyadh',
  'Al Takhassusi',
  '123 Road',
  'UTC'
);
select is((select name from updated_branch),'Renamed Lifecycle Branch','Internal Admin edits English branch name');
select is((select name_ar from updated_branch),'فرع جديد','Internal Admin edits Arabic branch name');
select is((select timezone from updated_branch),'UTC','Internal Admin edits branch timezone');
select is((select code from updated_branch),'HUN-RUH-001','Internal Admin edits and normalizes branch code');
select is((select branch_code_snapshot from public.checklist_submissions where id='5f400000-0000-4000-8000-000000000001'),'LIFE','branch code edit does not rewrite historical checklist snapshots');
select throws_ok(
  $$select public.update_internal_admin_branch('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001','3f400000-0000-4000-8000-000000000001','Duplicate Branch',null,'HUN-RUH-001','Riyadh',null,null,'UTC')$$,
  '23505',
  'branch already exists',
  'duplicate branch name is rejected'
);
select throws_ok(
  $$select public.update_internal_admin_branch('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001','3f400000-0000-4000-8000-000000000001','Bad Timezone',null,'HUN-RUH-001','Riyadh',null,null,'Bad/Zone')$$,
  '22023',
  'invalid branch update request',
  'invalid branch timezone is rejected'
);
select throws_ok(
  $$select public.update_internal_admin_branch('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000002','3f400000-0000-4000-8000-000000000001','Cross Org Branch',null,'HUN-RUH-001','Riyadh',null,null,'UTC')$$,
  'P0002',
  'branch unavailable',
  'cross-organization branch mutation is rejected'
);
select throws_ok(
  $$select public.update_internal_admin_branch('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001','3f400000-0000-4000-8000-000000000001','Unique Branch Name',null,'DUPB','Riyadh',null,null,'UTC')$$,
  '23505',
  'branch code already exists',
  'duplicate branch code in same organization is rejected'
);

select lives_ok(
  $$select public.deactivate_internal_admin_branch('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001','3f400000-0000-4000-8000-000000000001')$$,
  'Internal Admin deactivates branch'
);
select is((select active from public.branches where id='3f400000-0000-4000-8000-000000000001'),false,'branch active flag becomes false');
select is((select count(*) from public.branch_operational_teams where branch_id='3f400000-0000-4000-8000-000000000001' and active),1::bigint,'branch deactivate preserves active operational team records');
select is((select count(*) from public.branch_operational_team_supervisors where branch_id='3f400000-0000-4000-8000-000000000001' and active),1::bigint,'branch deactivate preserves supervisor assignment records');
select is((select count(*) from public.operational_staff_assignments where branch_id='3f400000-0000-4000-8000-000000000001' and active),1::bigint,'branch deactivate preserves active staff assignment rows');
select ok(not private.actor_can_read_operational_branch('1f400000-0000-4000-8000-000000000003','3f400000-0000-4000-8000-000000000001'),'supervisor cannot operate inactive branch');
select ok(not private.actor_can_write_operational_team('1f400000-0000-4000-8000-000000000003','3f400000-0000-4000-8000-000000000001',current_setting('test.lifecycle_operational_team')::uuid),'supervisor cannot write inactive branch team');
select is(
  (select count(*) from public.list_internal_admin_branches('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001') where id='3f400000-0000-4000-8000-000000000001' and timezone='UTC' and city='Riyadh' and not active),
  1::bigint,
  'inactive branch remains visible to Internal Admin with timezone'
);

select lives_ok(
  $$select public.reactivate_internal_admin_branch('1f400000-0000-4000-8000-000000000001','2f400000-0000-4000-8000-000000000001','3f400000-0000-4000-8000-000000000001')$$,
  'Internal Admin reactivates branch'
);
select is((select active from public.branches where id='3f400000-0000-4000-8000-000000000001'),true,'branch active flag becomes true');
select is((select active from public.operational_staff_assignments where id='8f400000-0000-4000-8000-000000000002'),false,'closed assignments are not reopened');
select is((select employment_status from public.operational_staff where id='7f400000-0000-4000-8000-000000000002'),'inactive','inactive employees remain inactive');
select is((select status from public.operational_staff_supervisor_training where id='9f400000-0000-4000-8000-000000000001'),'cancelled','cancelled training remains cancelled');

select throws_ok(
  $$select public.deactivate_internal_admin_branch('1f400000-0000-4000-8000-000000000005','2f400000-0000-4000-8000-000000000001','3f400000-0000-4000-8000-000000000001')$$,
  '42501',
  'internal admin access required',
  'non-Internal Admin cannot deactivate branch'
);

select * from finish();
rollback;
