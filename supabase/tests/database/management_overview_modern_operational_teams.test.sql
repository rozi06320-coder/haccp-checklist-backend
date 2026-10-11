begin;
select plan(24);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '2f100000-0000-4000-8000-000000000001'::uuid,
  '2f100000-0000-4000-8000-000000000002',
  '2f100000-0000-4000-8000-000000000003',
  '2f100000-0000-4000-8000-000000000004',
  '2f100000-0000-4000-8000-000000000005',
  '2f100000-0000-4000-8000-000000000006',
  '2f100000-0000-4000-8000-000000000007',
  '2f100000-0000-4000-8000-000000000008',
  '2f100000-0000-4000-8000-000000000009'
]) id;

update public.profiles
set full_name='Modern Overview Fixture', must_change_password=false
where id::text like '2f1%';

insert into public.organizations(id,name,slug)
values('2f200000-0000-4000-8000-000000000001','Modern Overview Org','modern-overview-org');

insert into public.organization_memberships(organization_id,user_id,role)
values('2f200000-0000-4000-8000-000000000001','2f100000-0000-4000-8000-000000000001','organization_manager');

insert into public.branches(id,organization_id,name,code,timezone,active)
values('2f300000-0000-4000-8000-000000000001','2f200000-0000-4000-8000-000000000001','Modern-only Branch','MODERN','Asia/Riyadh',true);

insert into public.branch_memberships(branch_id,user_id,role,active)
select '2f300000-0000-4000-8000-000000000001', id, 'branch_manager', true
from unnest(array[
  '2f100000-0000-4000-8000-000000000002'::uuid,
  '2f100000-0000-4000-8000-000000000003',
  '2f100000-0000-4000-8000-000000000004',
  '2f100000-0000-4000-8000-000000000005',
  '2f100000-0000-4000-8000-000000000006',
  '2f100000-0000-4000-8000-000000000007',
  '2f100000-0000-4000-8000-000000000008',
  '2f100000-0000-4000-8000-000000000009'
]) id;

insert into public.branch_operational_teams(id,organization_id,branch_id,name,active)
select id,'2f200000-0000-4000-8000-000000000001','2f300000-0000-4000-8000-000000000001',name,true
from (values
  ('2f400000-0000-4000-8000-000000000001'::uuid,'Team A'),
  ('2f400000-0000-4000-8000-000000000002','Team B'),
  ('2f400000-0000-4000-8000-000000000003','Inactive Team'),
  ('2f400000-0000-4000-8000-000000000004','Inactive Assignment Team'),
  ('2f400000-0000-4000-8000-000000000005','Future Assignment Team'),
  ('2f400000-0000-4000-8000-000000000006','Expired Assignment Team'),
  ('2f400000-0000-4000-8000-000000000007','Disabled Supervisor Team'),
  ('2f400000-0000-4000-8000-000000000008','Password Change Team'),
  ('2f400000-0000-4000-8000-000000000009','Inactive Membership Team')
) team(id,name);

insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,
  assignment_role,active,valid_from,valid_to,created_by
)
select gen_random_uuid(),'2f200000-0000-4000-8000-000000000001',
  '2f300000-0000-4000-8000-000000000001',team_id,user_id,'primary',active,
  valid_from,valid_to,'2f100000-0000-4000-8000-000000000001'
from (values
  ('2f400000-0000-4000-8000-000000000001'::uuid,'2f100000-0000-4000-8000-000000000002'::uuid,true,private.phase4a_business_date('Asia/Riyadh')-1,null::date),
  ('2f400000-0000-4000-8000-000000000002','2f100000-0000-4000-8000-000000000003',true,private.phase4a_business_date('Asia/Riyadh')-1,null),
  ('2f400000-0000-4000-8000-000000000003','2f100000-0000-4000-8000-000000000004',true,private.phase4a_business_date('Asia/Riyadh')-1,null),
  ('2f400000-0000-4000-8000-000000000004','2f100000-0000-4000-8000-000000000005',false,private.phase4a_business_date('Asia/Riyadh')-2,private.phase4a_business_date('Asia/Riyadh')-1),
  ('2f400000-0000-4000-8000-000000000005','2f100000-0000-4000-8000-000000000006',true,private.phase4a_business_date('Asia/Riyadh')+1,null),
  ('2f400000-0000-4000-8000-000000000006','2f100000-0000-4000-8000-000000000007',false,private.phase4a_business_date('Asia/Riyadh')-2,private.phase4a_business_date('Asia/Riyadh')-1),
  ('2f400000-0000-4000-8000-000000000007','2f100000-0000-4000-8000-000000000008',true,private.phase4a_business_date('Asia/Riyadh')-1,null),
  ('2f400000-0000-4000-8000-000000000008','2f100000-0000-4000-8000-000000000009',true,private.phase4a_business_date('Asia/Riyadh')-1,null),
  ('2f400000-0000-4000-8000-000000000009','2f100000-0000-4000-8000-000000000004',true,private.phase4a_business_date('Asia/Riyadh')-1,null)
) assignment(team_id,user_id,active,valid_from,valid_to);

update public.branch_operational_teams set active=false
where id='2f400000-0000-4000-8000-000000000003';
update public.profiles set disabled_at=now()
where id='2f100000-0000-4000-8000-000000000008';
update public.profiles set must_change_password=true
where id='2f100000-0000-4000-8000-000000000009';
update public.branch_memberships set active=false
where branch_id='2f300000-0000-4000-8000-000000000001'
  and user_id='2f100000-0000-4000-8000-000000000004';

create temporary table modern_overview(payload jsonb) on commit drop;
insert into modern_overview
select public.get_phase4a_management_overview(
  '2f100000-0000-4000-8000-000000000001',
  '2f200000-0000-4000-8000-000000000001'
);

select is((select count(*) from public.branch_supervisor_teams
  where branch_id='2f300000-0000-4000-8000-000000000001'),0::bigint,
  'modern-only branch has no legacy Supervisor team rows');
select is((payload->'summary'->>'active_team_count')::int,2,
  'only two valid modern operational teams are active') from modern_overview;
select is(payload->'branches'->0->>'status','ready',
  'modern-only branch is ready') from modern_overview;
select is((payload->'branches'->0->>'active_team_count')::int,2,
  'branch active-team count is distinct operational teams') from modern_overview;
select is((select checklist->'team_states' from modern_overview
  cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist
  where checklist->>'checklist_type'='staff_hygiene'),
  '{"draft": 0, "submitted": 0, "not_started": 2}'::jsonb,
  'Staff Hygiene creates one work unit per eligible operational team') from modern_overview;
select is((select (checklist->>'expected_checks')::int from modern_overview
  cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist
  where checklist->>'checklist_type'='oil_tracking'),2,
  'Oil Tracking is one branch work unit and is not multiplied by team count') from modern_overview;
select is((select (checklist->>'expected_checks')::int from modern_overview
  cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist
  where checklist->>'checklist_type'='sales_tracking'),1,
  'Sales Tracking is one branch work unit and is not multiplied by team count') from modern_overview;
select is((select checklist->'team_states' from modern_overview
  cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist
  where checklist->>'checklist_type'='oil_tracking'),
  '{"draft": 0, "submitted": 0, "not_started": 1}'::jsonb,
  'branch-owned Oil state is counted once') from modern_overview;
select is((select checklist->'team_states' from modern_overview
  cross join lateral pg_catalog.jsonb_array_elements(payload->'branches'->0->'checklists') checklist
  where checklist->>'checklist_type'='sales_tracking')->>'not_started','1',
  'branch-owned Sales state is counted once') from modern_overview;

select is((select count(*) from public.branch_operational_teams where active
  and branch_id='2f300000-0000-4000-8000-000000000001'),8::bigint,
  'fixture contains active teams that fail other eligibility gates');
select is((payload->'branches'->0->>'active_team_count')::int,2,
  'inactive assignment is excluded') from modern_overview;
select is((payload->'branches'->0->>'active_team_count')::int,2,
  'future assignment is excluded') from modern_overview;
select is((payload->'branches'->0->>'active_team_count')::int,2,
  'expired assignment is excluded') from modern_overview;
select is((payload->'branches'->0->>'active_team_count')::int,2,
  'disabled Supervisor is excluded') from modern_overview;
select is((payload->'branches'->0->>'active_team_count')::int,2,
  'must-change-password Supervisor is excluded') from modern_overview;
select is((payload->'branches'->0->>'active_team_count')::int,2,
  'inactive branch membership is excluded') from modern_overview;

select is(pg_catalog.jsonb_array_length(
  public.get_management_overview_with_daily_audit(
    '2f100000-0000-4000-8000-000000000001',
    '2f200000-0000-4000-8000-000000000001'
  )->'branches'->0->'checklists'
),7,'Daily Audit remains one branch-owned checklist row');
select is(
  (public.get_management_overview_with_daily_audit(
    '2f100000-0000-4000-8000-000000000001',
    '2f200000-0000-4000-8000-000000000001'
  )->'branches'->0->'totals'->>'expected_checks')::int
  - (select (payload->'branches'->0->'totals'->>'expected_checks')::int from modern_overview),
  13,'Daily Audit denominator is added once per branch, not once per team');

select ok((select procedure.prosecdef from pg_catalog.pg_proc procedure
  where procedure.oid='public.get_phase4a_management_overview(uuid,uuid)'::regprocedure),
  'Manager Overview remains SECURITY DEFINER');
select ok((select procedure.proconfig @> array['search_path=""'] from pg_catalog.pg_proc procedure
  where procedure.oid='public.get_phase4a_management_overview(uuid,uuid)'::regprocedure),
  'Manager Overview retains empty search_path');
select is(has_function_privilege('service_role','public.get_phase4a_management_overview(uuid,uuid)','execute'),true,
  'service_role can execute Manager Overview');
select is(has_function_privilege('authenticated','public.get_phase4a_management_overview(uuid,uuid)','execute'),false,
  'authenticated cannot execute Manager Overview');
select is(has_function_privilege('anon','public.get_phase4a_management_overview(uuid,uuid)','execute'),false,
  'anon cannot execute Manager Overview');
select is((select count(*) from information_schema.routine_privileges
  where routine_schema='public'
    and routine_name='get_phase4a_management_overview'
    and grantee='PUBLIC'),0::bigint,
  'PUBLIC cannot execute Manager Overview');

select * from finish();
rollback;
