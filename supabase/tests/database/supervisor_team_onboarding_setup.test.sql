begin;
select plan(40);

-- =============================================================================
-- 1. Schema, RLS, Privileges & Function Security Assertions
-- =============================================================================

select has_table('public', 'supervisor_team_onboarding_states', 'supervisor_team_onboarding_states exists');
select has_table('public', 'supervisor_team_bootstrap_idempotency', 'supervisor_team_bootstrap_idempotency exists');

select ok(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'supervisor_team_onboarding_states'),
  'RLS enabled on supervisor_team_onboarding_states'
);
select ok(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'supervisor_team_bootstrap_idempotency'),
  'RLS enabled on supervisor_team_bootstrap_idempotency'
);

select is(has_table_privilege('anon', 'public.supervisor_team_onboarding_states', 'select'), false, 'anon cannot select onboarding states');
select is(has_table_privilege('authenticated', 'public.supervisor_team_onboarding_states', 'select'), false, 'authenticated cannot select onboarding states');
select is(has_table_privilege('authenticated', 'public.supervisor_team_onboarding_states', 'insert'), false, 'authenticated cannot insert onboarding states');
select is(has_table_privilege('authenticated', 'public.supervisor_team_bootstrap_idempotency', 'select'), false, 'authenticated cannot select bootstrap idempotency');

select is(has_function_privilege('authenticated', 'public.get_supervisor_team_onboarding_state(uuid,uuid[])', 'execute'), false, 'authenticated cannot execute get_supervisor_team_onboarding_state');
select is(has_function_privilege('service_role', 'public.get_supervisor_team_onboarding_state(uuid,uuid[])', 'execute'), true, 'service_role can execute get_supervisor_team_onboarding_state');

select is(has_function_privilege('authenticated', 'public.set_supervisor_team_onboarding_waiting(uuid,uuid)', 'execute'), false, 'authenticated cannot execute set_supervisor_team_onboarding_waiting');
select is(has_function_privilege('service_role', 'public.set_supervisor_team_onboarding_waiting(uuid,uuid)', 'execute'), true, 'service_role can execute set_supervisor_team_onboarding_waiting');

select is(has_function_privilege('authenticated', 'public.create_supervisor_owned_operational_team_v2(uuid,uuid,text,uuid)', 'execute'), false, 'authenticated cannot execute create_supervisor_owned_operational_team_v2');
select is(has_function_privilege('service_role', 'public.create_supervisor_owned_operational_team_v2(uuid,uuid,text,uuid)', 'execute'), true, 'service_role can execute create_supervisor_owned_operational_team_v2');

select is(has_function_privilege('authenticated', 'public.create_supervisor_owned_operational_team(uuid,uuid,text)', 'execute'), false, 'authenticated cannot execute legacy 3-arg create_supervisor_owned_operational_team');
select is(has_function_privilege('service_role', 'public.create_supervisor_owned_operational_team(uuid,uuid,text)', 'execute'), true, 'service_role can execute legacy 3-arg create_supervisor_owned_operational_team');

select is(
  (
    select count(*)::integer
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('public', 'get_supervisor_team_onboarding_state'),
      ('public', 'set_supervisor_team_onboarding_waiting'),
      ('public', 'create_supervisor_owned_operational_team_v2'),
      ('public', 'create_supervisor_owned_operational_team'),
      ('private', 'lock_supervisor_team_onboarding_on_assignment'),
      ('private', 'clear_supervisor_team_onboarding_on_assignment')
    )
      and (
        not p.prosecdef
        or p.proconfig is null
        or not (p.proconfig @> array['search_path='] or p.proconfig @> array['search_path=""'])
      )
  ),
  0,
  'all Phase 1 onboarding functions enforce SECURITY DEFINER and empty search_path'
);

-- =============================================================================
-- 2. Fixture Setup
-- =============================================================================

insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'onb-admin@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'onb-sup-a@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'onb-sup-b@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000000', 'f0000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'onb-disabled@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'onb-org2@example.invalid', '{}', '{}', now(), now())
on conflict (id) do nothing;

update public.profiles
set full_name = 'Onboarding User ' || right(id::text, 2),
    must_change_password = false,
    disabled_at = case when id = 'f0000000-0000-4000-8000-000000000004' then now() else null end
where id in (
  'f0000000-0000-4000-8000-000000000001',
  'f0000000-0000-4000-8000-000000000002',
  'f0000000-0000-4000-8000-000000000003',
  'f0000000-0000-4000-8000-000000000004',
  'f0000000-0000-4000-8000-000000000005'
);

insert into public.internal_admin_memberships(user_id, active)
values ('f0000000-0000-4000-8000-000000000001', true)
on conflict (user_id) do update set active = true;

insert into public.organizations(id, name, slug, active)
values
  ('f1000000-0000-4000-8000-000000000001', 'Onboarding Org 1', 'onb-org-1', true),
  ('f1000000-0000-4000-8000-000000000002', 'Onboarding Org 2', 'onb-org-2', true)
on conflict (id) do nothing;

insert into public.branches(id, organization_id, name, code, timezone, country_code, active, created_at)
values
  ('f2000000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', 'Onb Branch A', 'ONB-A', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z'),
  ('f2000000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000001', 'Onb Branch B', 'ONB-B', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z'),
  ('f2000000-0000-4000-8000-000000000003', 'f1000000-0000-4000-8000-000000000002', 'Onb Branch C Org2', 'ONB-C', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z')
on conflict (id) do nothing;

delete from public.daily_report_module_applicability
where branch_id in (
  'f2000000-0000-4000-8000-000000000001',
  'f2000000-0000-4000-8000-000000000002'
);

delete from public.daily_report_branch_lifecycle
where branch_id in (
  'f2000000-0000-4000-8000-000000000001',
  'f2000000-0000-4000-8000-000000000002'
);

insert into public.daily_report_branch_lifecycle(
  organization_id, branch_id, timezone, active, effective_from_business_date
)
values
  ('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', 'Asia/Riyadh', true, '2026-01-01'),
  ('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000002', 'Asia/Riyadh', true, '2026-01-01')
on conflict do nothing;

select private.seed_daily_report_module_applicability('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000001', '2026-01-01');
select private.seed_daily_report_module_applicability('f1000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000002', '2026-01-01');

-- Sup A has Branch A & Branch B; Sup B has Branch A; Disabled has Branch A; Org2 Sup has Branch C
insert into public.branch_memberships(branch_id, user_id, role, active)
values
  ('f2000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000002', 'branch_manager', true),
  ('f2000000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000002', 'branch_manager', true),
  ('f2000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000003', 'branch_manager', true),
  ('f2000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000004', 'branch_manager', true),
  ('f2000000-0000-4000-8000-000000000003', 'f0000000-0000-4000-8000-000000000005', 'branch_manager', true)
on conflict do nothing;

-- =============================================================================
-- 3. Waiting State Persistence, Multi-Branch Isolation & Idempotent Waiting
-- =============================================================================

select is(
  (select public.set_supervisor_team_onboarding_waiting(
     'f0000000-0000-4000-8000-000000000002',
     'f2000000-0000-4000-8000-000000000001'
   ) ->> 'onboarding_choice'),
  'waiting_for_transfer',
  'Sup A sets waiting state on Branch A'
);

-- Repeated waiting request must NOT create duplicate audit events
select lives_ok(
  $$select public.set_supervisor_team_onboarding_waiting(
      'f0000000-0000-4000-8000-000000000002',
      'f2000000-0000-4000-8000-000000000001'
    )$$,
  'repeated waiting call succeeds idempotently'
);

select is(
  (select count(*)::integer
   from public.account_management_audit_logs
   where target_user_id = 'f0000000-0000-4000-8000-000000000002'
     and branch_id = 'f2000000-0000-4000-8000-000000000001'
     and action = 'supervisor_team_onboarding_waiting_selected'),
  1,
  'repeated waiting request does not create duplicate audit events'
);

-- Branch A waiting does not affect Branch B
select is(
  (select array_agg(branch_id order by branch_id)
   from public.get_supervisor_team_onboarding_state(
     'f0000000-0000-4000-8000-000000000002',
     array['f2000000-0000-4000-8000-000000000001', 'f2000000-0000-4000-8000-000000000002']::uuid[]
   )),
  array['f2000000-0000-4000-8000-000000000001']::uuid[],
  'waiting state is scoped per supervisor and branch (Branch A only, not Branch B)'
);

-- Unauthorized, disabled, and cross-org access rejected
select throws_ok(
  $$select public.set_supervisor_team_onboarding_waiting('f0000000-0000-4000-8000-000000000004', 'f2000000-0000-4000-8000-000000000001')$$,
  '42501', null, 'disabled supervisor cannot set waiting state'
);
select throws_ok(
  $$select public.set_supervisor_team_onboarding_waiting('f0000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000003')$$,
  '42501', null, 'cross-org branch rejected for waiting state'
);
select throws_ok(
  $$select * from public.get_supervisor_team_onboarding_state('f0000000-0000-4000-8000-000000000002', array['f2000000-0000-4000-8000-000000000003']::uuid[])$$,
  '42501', null, 'cross-org branch rejected for reading onboarding state'
);

-- =============================================================================
-- 4. Switching Waiting -> Create Team, Idempotency, Revocation & Audit Logging
-- =============================================================================

create temporary table sup_a_team on commit drop as
select * from public.create_supervisor_owned_operational_team_v2(
  'f0000000-0000-4000-8000-000000000002',
  'f2000000-0000-4000-8000-000000000001',
  '  Alpha   Team  ',
  'f8000000-0000-4000-8000-000000000001'::uuid
);

select is((select team_name from sup_a_team), 'Alpha Team', 'create_supervisor_owned_operational_team_v2 creates normalized team');
select is(
  (select count(*)::integer
   from public.supervisor_team_onboarding_states
   where supervisor_user_id = 'f0000000-0000-4000-8000-000000000002'
     and branch_id = 'f2000000-0000-4000-8000-000000000001'),
  0,
  'team creation clears waiting state on Branch A'
);
select is(
  (select count(*)::integer
   from public.account_management_audit_logs
   where target_user_id = 'f0000000-0000-4000-8000-000000000002'
     and branch_id = 'f2000000-0000-4000-8000-000000000001'
     and action = 'supervisor_owned_team_created'),
  1,
  'team creation writes immutable supervisor_owned_team_created audit log'
);

-- Waiting rejected once writable team exists
select throws_ok(
  $$select public.set_supervisor_team_onboarding_waiting('f0000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001')$$,
  '23505', null, 'waiting state rejected when supervisor already has writable team'
);

-- Idempotent retry with same key and normalized name returns the exact same team without duplicate audit
select is(
  (select team_id
   from public.create_supervisor_owned_operational_team_v2(
     'f0000000-0000-4000-8000-000000000002',
     'f2000000-0000-4000-8000-000000000001',
     'alpha team',
     'f8000000-0000-4000-8000-000000000001'::uuid
   )),
  (select team_id from sup_a_team),
  'idempotent retry with same key and normalized name returns same team'
);
select is(
  (select count(*)::integer
   from public.account_management_audit_logs
   where target_user_id = 'f0000000-0000-4000-8000-000000000002'
     and branch_id = 'f2000000-0000-4000-8000-000000000001'
     and action = 'supervisor_owned_team_created'),
  1,
  'idempotent retry does not duplicate audit logs'
);

-- Different payload with same idempotency key is rejected
select throws_ok(
  $$select * from public.create_supervisor_owned_operational_team_v2(
      'f0000000-0000-4000-8000-000000000002',
      'f2000000-0000-4000-8000-000000000001',
      'Different Team Name',
      'f8000000-0000-4000-8000-000000000001'::uuid
    )$$,
  '23505', null, 'different team name with same idempotency key is rejected'
);

-- Duplicate active team name by another supervisor in same branch rejected
select throws_ok(
  $$select * from public.create_supervisor_owned_operational_team_v2(
      'f0000000-0000-4000-8000-000000000003',
      'f2000000-0000-4000-8000-000000000001',
      'ALPHA TEAM',
      'f8000000-0000-4000-8000-000000000002'::uuid
    )$$,
  '23505', null, 'duplicate active team name in same branch is rejected'
);

-- Empty new team generates 0 required Staff Hygiene checks and 0 missed issues
select is(
  (select count(*)::integer
   from public.operational_staff_assignments
   where operational_team_id = (select team_id from sup_a_team) and active),
  0,
  'new supervisor-owned team starts with zero staff'
);
select is(
  (select required
   from public.get_daily_report_staff_hygiene_applicability(
     'f0000000-0000-4000-8000-000000000001',
     'f1000000-0000-4000-8000-000000000001',
     current_date - 1
   )
   where branch_id = 'f2000000-0000-4000-8000-000000000001'
     and operational_team_id = (select team_id from sup_a_team)),
  false,
  'empty new team has required = false in Staff Hygiene applicability'
);
select is(
  (select count(*)::integer
   from private.phase4a_managed_missed_issue_rows_at(
     'f1000000-0000-4000-8000-000000000001',
     now()
   )
   where branch_id = 'f2000000-0000-4000-8000-000000000001'
     and checklist_type = 'staff_hygiene'),
  0,
  'empty new team generates zero Staff Hygiene missed issues'
);

-- =============================================================================
-- 5. Team Transfer Clears Waiting State & Revoked Access Cannot Replay Creation
-- =============================================================================

-- Sup B sets waiting on Branch A
select lives_ok(
  $$select public.set_supervisor_team_onboarding_waiting(
      'f0000000-0000-4000-8000-000000000003',
      'f2000000-0000-4000-8000-000000000001'
    )$$,
  'Sup B enters waiting state on Branch A'
);

-- Internal Admin transfers Sup A's team to Sup B via existing change_internal_admin_operational_team_primary_supervisor
select lives_ok(
  $$select * from public.change_internal_admin_operational_team_primary_supervisor(
      'f0000000-0000-4000-8000-000000000001',
      'f1000000-0000-4000-8000-000000000001',
      (select team_id from sup_a_team),
      'f0000000-0000-4000-8000-000000000003',
      (select id from public.branch_operational_team_supervisors
       where operational_team_id = (select team_id from sup_a_team)
         and supervisor_user_id = 'f0000000-0000-4000-8000-000000000002'
         and active)
    )$$,
  'existing team transfer RPC transfers Alpha Team from Sup A to Sup B'
);

select is(
  (select count(*)::integer
   from public.supervisor_team_onboarding_states
   where supervisor_user_id = 'f0000000-0000-4000-8000-000000000003'
     and branch_id = 'f2000000-0000-4000-8000-000000000001'),
  0,
  'team transfer automatically clears destination supervisor waiting state'
);

-- Now Sup A's team ownership was transferred away -> Sup A cannot replay create_supervisor_owned_operational_team_v2 with old idempotency_key!
select throws_ok(
  $$select * from public.create_supervisor_owned_operational_team_v2(
      'f0000000-0000-4000-8000-000000000002',
      'f2000000-0000-4000-8000-000000000001',
      'Alpha Team',
      'f8000000-0000-4000-8000-000000000001'::uuid
    )$$,
  '42501', null, 'supervisor whose team access was transferred/revoked cannot replay idempotent team creation'
);

-- Legacy 3-arg create_supervisor_owned_operational_team works unchanged on Branch B for Sup A
select is(
  (select team_name
   from public.create_supervisor_owned_operational_team(
     'f0000000-0000-4000-8000-000000000002',
     'f2000000-0000-4000-8000-000000000002',
     'Beta Team'
   )),
  'Beta Team',
  'legacy 3-arg create_supervisor_owned_operational_team works unchanged on Branch B'
);

select * from finish();
rollback;
