begin;
select plan(36);

-- 1. Verify anon has ZERO privileges (including TRUNCATE/TRIGGER/SELECT) on all 4 target tables
select is(has_table_privilege('anon', 'public.account_management_audit_logs', 'SELECT'), false, 'anon cannot SELECT audit logs');
select is(has_table_privilege('anon', 'public.account_management_audit_logs', 'INSERT'), false, 'anon cannot INSERT audit logs');
select is(has_table_privilege('anon', 'public.account_management_audit_logs', 'TRUNCATE'), false, 'anon cannot TRUNCATE audit logs');

select is(has_table_privilege('anon', 'public.branch_operational_teams', 'SELECT'), false, 'anon cannot SELECT operational teams');
select is(has_table_privilege('anon', 'public.branch_operational_teams', 'INSERT'), false, 'anon cannot INSERT operational teams');
select is(has_table_privilege('anon', 'public.branch_operational_teams', 'TRUNCATE'), false, 'anon cannot TRUNCATE operational teams');

select is(has_table_privilege('anon', 'public.branch_operational_team_supervisors', 'SELECT'), false, 'anon cannot SELECT team supervisors');
select is(has_table_privilege('anon', 'public.branch_operational_team_supervisors', 'TRUNCATE'), false, 'anon cannot TRUNCATE team supervisors');

select is(has_table_privilege('anon', 'public.branch_supervisor_teams', 'SELECT'), false, 'anon cannot SELECT legacy supervisor teams');
select is(has_table_privilege('anon', 'public.branch_supervisor_teams', 'TRUNCATE'), false, 'anon cannot TRUNCATE legacy supervisor teams');

-- 2. Verify authenticated has SELECT ONLY and ZERO mutation/DDL privileges on all 4 target tables
select is(has_table_privilege('authenticated', 'public.account_management_audit_logs', 'SELECT'), true, 'authenticated keeps SELECT on audit logs');
select is(has_table_privilege('authenticated', 'public.account_management_audit_logs', 'INSERT'), false, 'authenticated cannot INSERT audit logs');
select is(has_table_privilege('authenticated', 'public.account_management_audit_logs', 'UPDATE'), false, 'authenticated cannot UPDATE audit logs');
select is(has_table_privilege('authenticated', 'public.account_management_audit_logs', 'DELETE'), false, 'authenticated cannot DELETE audit logs');
select is(has_table_privilege('authenticated', 'public.account_management_audit_logs', 'TRUNCATE'), false, 'authenticated cannot TRUNCATE audit logs');
select is(has_table_privilege('authenticated', 'public.account_management_audit_logs', 'TRIGGER'), false, 'authenticated cannot TRIGGER audit logs');

select is(has_table_privilege('authenticated', 'public.branch_operational_teams', 'SELECT'), true, 'authenticated keeps SELECT on operational teams');
select is(has_table_privilege('authenticated', 'public.branch_operational_teams', 'INSERT'), false, 'authenticated cannot INSERT operational teams');
select is(has_table_privilege('authenticated', 'public.branch_operational_teams', 'UPDATE'), false, 'authenticated cannot UPDATE operational teams');
select is(has_table_privilege('authenticated', 'public.branch_operational_teams', 'DELETE'), false, 'authenticated cannot DELETE operational teams');
select is(has_table_privilege('authenticated', 'public.branch_operational_teams', 'TRUNCATE'), false, 'authenticated cannot TRUNCATE operational teams');
select is(has_table_privilege('authenticated', 'public.branch_operational_teams', 'TRIGGER'), false, 'authenticated cannot TRIGGER operational teams');

select is(has_table_privilege('authenticated', 'public.branch_operational_team_supervisors', 'SELECT'), true, 'authenticated keeps SELECT on team supervisors');
select is(has_table_privilege('authenticated', 'public.branch_operational_team_supervisors', 'INSERT'), false, 'authenticated cannot INSERT team supervisors');
select is(has_table_privilege('authenticated', 'public.branch_operational_team_supervisors', 'UPDATE'), false, 'authenticated cannot UPDATE team supervisors');
select is(has_table_privilege('authenticated', 'public.branch_operational_team_supervisors', 'DELETE'), false, 'authenticated cannot DELETE team supervisors');
select is(has_table_privilege('authenticated', 'public.branch_operational_team_supervisors', 'TRUNCATE'), false, 'authenticated cannot TRUNCATE team supervisors');

select is(has_table_privilege('authenticated', 'public.branch_supervisor_teams', 'SELECT'), true, 'authenticated keeps SELECT on legacy supervisor teams');
select is(has_table_privilege('authenticated', 'public.branch_supervisor_teams', 'INSERT'), false, 'authenticated cannot INSERT legacy supervisor teams');
select is(has_table_privilege('authenticated', 'public.branch_supervisor_teams', 'UPDATE'), false, 'authenticated cannot UPDATE legacy supervisor teams');
select is(has_table_privilege('authenticated', 'public.branch_supervisor_teams', 'DELETE'), false, 'authenticated cannot DELETE legacy supervisor teams');
select is(has_table_privilege('authenticated', 'public.branch_supervisor_teams', 'TRUNCATE'), false, 'authenticated cannot TRUNCATE legacy supervisor teams');

-- 3. Verify service_role retains INSERT on account_management_audit_logs
select is(has_table_privilege('service_role', 'public.account_management_audit_logs', 'INSERT'), true, 'service_role retains INSERT on audit logs');

-- 4. Runtime RLS check: authenticated SELECT works for own branch, cross-org returns 0 rows
insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'priv-sup1@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'priv-sup2@example.invalid', '{}', '{}', now(), now())
on conflict (id) do nothing;

update public.profiles set full_name = 'Priv Test Sup', must_change_password = false
where id in ('d0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002');

insert into public.organizations(id, name, slug, active)
values
  ('d1000000-0000-4000-8000-000000000001', 'Priv Org 1', 'priv-org-1', true),
  ('d1000000-0000-4000-8000-000000000002', 'Priv Org 2', 'priv-org-2', true)
on conflict (id) do nothing;

insert into public.branches(id, organization_id, name, code, timezone, country_code, active)
values
  ('d2000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Priv Branch 1', 'PRV-1', 'Asia/Riyadh', 'SA', true),
  ('d2000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000002', 'Priv Branch 2', 'PRV-2', 'Asia/Riyadh', 'SA', true)
on conflict (id) do nothing;

insert into public.branch_memberships(branch_id, user_id, role, active)
values
  ('d2000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001', 'branch_manager', true),
  ('d2000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000002', 'branch_manager', true)
on conflict do nothing;

select * from public.create_supervisor_owned_operational_team_v2('d0000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', 'Org1 Team', null);
select * from public.create_supervisor_owned_operational_team_v2('d0000000-0000-4000-8000-000000000002', 'd2000000-0000-4000-8000-000000000002', 'Org2 Team', null);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000001', true);

select is(
  (select count(*)::integer from public.branch_operational_teams where branch_id = 'd2000000-0000-4000-8000-000000000001'),
  1,
  'authenticated supervisor can SELECT own branch operational team via RLS'
);

select is(
  (select count(*)::integer from public.branch_operational_teams where branch_id = 'd2000000-0000-4000-8000-000000000002'),
  0,
  'authenticated supervisor cannot SELECT cross-organization operational team via RLS'
);

select throws_ok(
  $$delete from public.branch_operational_teams where branch_id = 'd2000000-0000-4000-8000-000000000001'$$,
  '42501', null, 'authenticated DELETE on branch_operational_teams denied'
);

reset role;

select * from finish();
rollback;
