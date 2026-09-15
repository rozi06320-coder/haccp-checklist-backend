begin;
select plan(24);

-- 1. Setup Auth Users and Profiles
insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000010'::uuid, -- Supervisor Alice
  '1e000000-0000-4000-8000-000000000020'::uuid, -- Supervisor Bob (unauthorized for Team Alice)
  '1e000000-0000-4000-8000-000000000030'::uuid  -- Manager Charlie
]) id;

update public.profiles set
  full_name = case id
    when '1e000000-0000-4000-8000-000000000010' then 'Supervisor Alice'
    when '1e000000-0000-4000-8000-000000000020' then 'Supervisor Bob'
    else 'Manager Charlie' end,
  must_change_password = false
where id in (
  '1e000000-0000-4000-8000-000000000010',
  '1e000000-0000-4000-8000-000000000020',
  '1e000000-0000-4000-8000-000000000030'
);

-- 2. Setup Org and Branch
insert into public.organizations(id, name, slug)
values('2e000000-0000-4000-8000-000000000010', 'Batch Test Org', 'batch-test-org');

insert into public.branches(id, organization_id, name, code, timezone)
values('3e000000-0000-4000-8000-000000000010', '2e000000-0000-4000-8000-000000000010', 'Batch Test Branch', 'BTB', 'Asia/Riyadh');

insert into public.organization_memberships(organization_id, user_id, role)
values('2e000000-0000-4000-8000-000000000010', '1e000000-0000-4000-8000-000000000030', 'organization_manager');

insert into public.branch_memberships(branch_id, user_id, role)
values
  ('3e000000-0000-4000-8000-000000000010', '1e000000-0000-4000-8000-000000000010', 'branch_manager'),
  ('3e000000-0000-4000-8000-000000000010', '1e000000-0000-4000-8000-000000000020', 'branch_manager');

-- 3. Setup Supervisor Teams (triggers automatic operational team creation)
insert into public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id, company_name)
values
  ('5e000000-0000-4000-8000-000000000010', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '1e000000-0000-4000-8000-000000000010', 'Alice Company'),
  ('5e000000-0000-4000-8000-000000000020', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '1e000000-0000-4000-8000-000000000020', 'Bob Company');

-- Store generated operational team IDs into session config
select set_config('test.team_alice', (select id::text from public.branch_operational_teams where legacy_supervisor_team_id = '5e000000-0000-4000-8000-000000000010'), false);
select set_config('test.team_bob', (select id::text from public.branch_operational_teams where legacy_supervisor_team_id = '5e000000-0000-4000-8000-000000000020'), false);

-- Team Empty has Alice as supervisor but no staff
insert into public.branch_operational_teams(id, organization_id, branch_id, name, active, legacy_supervisor_team_id)
values
  ('4e000000-0000-4000-8000-000000000030', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', 'Team Empty', true, null);

insert into public.branch_operational_team_supervisors(id, organization_id, branch_id, operational_team_id, supervisor_user_id, active, valid_from, assignment_role, created_by)
values ('9e000000-0000-4000-8000-000000000030', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '4e000000-0000-4000-8000-000000000030', '1e000000-0000-4000-8000-000000000010', true, current_date, 'primary', '1e000000-0000-4000-8000-000000000010'::uuid);

-- 4. Setup Operational Staff
insert into public.operational_staff(id, organization_id, branch_id, display_name, employment_status, deactivated_at, deactivated_by, staff_code, created_by)
values
  ('6e000000-0000-4000-8000-000000000011', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', 'Worker 1 (Alice Active)', 'active', null, null, 'W-1', '1e000000-0000-4000-8000-000000000010'),
  ('6e000000-0000-4000-8000-000000000012', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', 'Worker 2 (Alice Active)', 'active', null, null, 'W-2', '1e000000-0000-4000-8000-000000000010'),
  ('6e000000-0000-4000-8000-000000000013', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', 'Worker 3 (Alice Inactive)', 'inactive', now(), '1e000000-0000-4000-8000-000000000010'::uuid, 'W-3', '1e000000-0000-4000-8000-000000000010'),
  ('6e000000-0000-4000-8000-000000000014', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', 'Worker 4 (Alice Inactive Assign)', 'active', null, null, 'W-4', '1e000000-0000-4000-8000-000000000010');

-- 5. Staff Assignments
insert into public.operational_staff_assignments(id, organization_id, branch_id, operational_staff_id, operational_team_id, supervisor_team_id, active, operational_roles)
values
  ('7e000000-0000-4000-8000-000000000011', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '6e000000-0000-4000-8000-000000000011', current_setting('test.team_alice')::uuid, '5e000000-0000-4000-8000-000000000010', true, array['kitchen']),
  ('7e000000-0000-4000-8000-000000000012', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '6e000000-0000-4000-8000-000000000012', current_setting('test.team_alice')::uuid, '5e000000-0000-4000-8000-000000000010', true, array['front_of_house']),
  ('7e000000-0000-4000-8000-000000000013', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '6e000000-0000-4000-8000-000000000013', current_setting('test.team_alice')::uuid, '5e000000-0000-4000-8000-000000000010', false, array['kitchen']),
  ('7e000000-0000-4000-8000-000000000014', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '6e000000-0000-4000-8000-000000000014', current_setting('test.team_alice')::uuid, '5e000000-0000-4000-8000-000000000010', false, array['kitchen']);

-- TEST 1: Factor catalog count exactly 30
select is(
  (select count(*) from public.operational_staff_monthly_evaluation_factors),
  30::bigint,
  'factor catalog contains exactly 30 factors'
);

-- TEST 2: Factor display orders are 1..30 unique
select is(
  (select array_agg(display_order order by display_order) from public.operational_staff_monthly_evaluation_factors),
  (select array_agg(s order by s) from generate_series(1, 30) s),
  'factor display orders are exactly 1 through 30'
);

set local role service_role;

-- TEST 3: Unauthorized supervisor rejected (Supervisor Bob cannot finalize Team Alice)
select throws_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000020',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  '42501',
  'monthly evaluation access denied',
  'unauthorized supervisor cannot finalize other team'
);

-- TEST 4: Wrong operational team rejected (team not in branch)
select throws_ok(
  $$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '00000000-0000-0000-0000-000000000000',
    '2026-08-01'
  )$$,
  '42501',
  'operational team not found for branch',
  'non-existent operational team rejected'
);

-- TEST 5: Zero eligible staff rejected (Team Empty has 0 staff)
select throws_ok(
  $$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010', -- Supervisor Alice is authorized supervisor for Empty
    '3e000000-0000-4000-8000-000000000010',
    '4e000000-0000-4000-8000-000000000030', -- Empty team
    '2026-08-01'
  )$$,
  '22023',
  'no active eligible staff found for team',
  'team with zero eligible staff rejected'
);

-- TEST 6: Incomplete team monthly evaluations rejected when missing evaluations
select throws_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  '22023',
  'incomplete team monthly evaluations: missing evaluation row for eligible staff',
  'missing evaluations for eligible staff rejected'
);

-- Setup Draft Evaluations for Worker 1 and Worker 2
insert into public.operational_staff_monthly_evaluations(
  id, organization_id, branch_id, supervisor_team_id, operational_staff_id, evaluation_month, evaluator_name, status, average_score, evaluated_by_user_id
) values
  ('8e000000-0000-4000-8000-000000000011', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '5e000000-0000-4000-8000-000000000010', '6e000000-0000-4000-8000-000000000011', '2026-08-01', 'Alice', 'draft', 4.0, '1e000000-0000-4000-8000-000000000010'::uuid),
  ('8e000000-0000-4000-8000-000000000012', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '5e000000-0000-4000-8000-000000000010', '6e000000-0000-4000-8000-000000000012', '2026-08-01', 'Alice', 'draft', 4.0, '1e000000-0000-4000-8000-000000000010'::uuid);

-- TEST 7: Missing canonical factors rejected (Worker 1 has 0 scores)
select throws_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  '22023',
  'incomplete or invalid monthly evaluation factors',
  'evaluations missing all canonical factors rejected'
);

-- Insert 29 factors for Worker 1, all 30 for Worker 2
insert into public.operational_staff_monthly_evaluation_scores(evaluation_id, section, factor_key, factor_label, rating, comment)
select '8e000000-0000-4000-8000-000000000011', f.section, f.factor_key, f.factor_label, 4, 'Good'
from public.operational_staff_monthly_evaluation_factors f
where f.display_order <= 29;

insert into public.operational_staff_monthly_evaluation_scores(evaluation_id, section, factor_key, factor_label, rating, comment)
select '8e000000-0000-4000-8000-000000000012', f.section, f.factor_key, f.factor_label, 5, 'Great'
from public.operational_staff_monthly_evaluation_factors f;

-- TEST 8: Missing factor #30 on Worker 1 rejected
select throws_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  '22023',
  'incomplete or invalid monthly evaluation factors',
  'evaluation with 29 of 30 factors rejected'
);

-- Insert factor #30 with null rating for Worker 1
insert into public.operational_staff_monthly_evaluation_scores(evaluation_id, section, factor_key, factor_label, rating, comment)
select '8e000000-0000-4000-8000-000000000011', f.section, f.factor_key, f.factor_label, null, 'Unrated'
from public.operational_staff_monthly_evaluation_factors f
where f.display_order = 30;

-- TEST 9: Null rating rejected
select throws_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  '22023',
  'incomplete or invalid monthly evaluation factors',
  'null rating rejected'
);

-- Fix factor #30 on Worker 1 to rating 4, but add an unexpected rogue factor
update public.operational_staff_monthly_evaluation_scores
set rating = 4
where evaluation_id = '8e000000-0000-4000-8000-000000000011' and factor_key = 'skills_leadership_skills';

insert into public.operational_staff_monthly_evaluation_scores(evaluation_id, section, factor_key, factor_label, rating, comment)
values ('8e000000-0000-4000-8000-000000000011', 'Extra', 'extra_unapproved_factor', 'Unapproved', 5, 'Rogue');

-- TEST 10: Unexpected factor rejected
select throws_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  '22023',
  'unexpected monthly evaluation factors found',
  'unexpected rogue factor outside catalog rejected'
);

-- Remove the unexpected rogue factor
delete from public.operational_staff_monthly_evaluation_scores
where evaluation_id = '8e000000-0000-4000-8000-000000000011' and factor_key = 'extra_unapproved_factor';

-- TEST 11: Failed finalizations left no partial updates (status is still draft)
select is(
  (select status from public.operational_staff_monthly_evaluations where id = '8e000000-0000-4000-8000-000000000011'),
  'draft',
  'failed attempts leave status as draft'
);

-- TEST 12: No batch inserted before success
select is(
  (select count(*) from public.operational_staff_monthly_evaluation_batches where operational_team_id = current_setting('test.team_alice')::uuid),
  0::bigint,
  'no batch record created prior to success'
);

-- TEST 13: Read RPC returns null before batch is created
select is(
  public.get_operational_staff_monthly_evaluation_batch(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    current_setting('test.team_alice')::uuid,
    '2026-08-01'
  ),
  null,
  'get_operational_staff_monthly_evaluation_batch returns null when not finalized'
);

-- TEST 14: SUCCESSFUL FINALIZATION
select lives_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  'successful batch finalization for Team Alice'
);

-- TEST 15: Both eligible evaluations transitioned to completed
select is(
  (select count(*) from public.operational_staff_monthly_evaluations
   where id in ('8e000000-0000-4000-8000-000000000011', '8e000000-0000-4000-8000-000000000012')
     and status = 'completed'),
  2::bigint,
  'all eligible evaluations marked completed'
);

-- TEST 16: Exactly one batch row created
select is(
  (select count(*) from public.operational_staff_monthly_evaluation_batches where operational_team_id = current_setting('test.team_alice')::uuid),
  1::bigint,
  'exactly one batch row created'
);

-- TEST 17: Batch total_evaluated_staff is authoritative (2)
select is(
  (select total_evaluated_staff from public.operational_staff_monthly_evaluation_batches where operational_team_id = current_setting('test.team_alice')::uuid),
  2,
  'batch total evaluated staff is 2'
);

-- TEST 18: Batch completed_by_user_id is Supervisor Alice
select is(
  (select completed_by_user_id from public.operational_staff_monthly_evaluation_batches where operational_team_id = current_setting('test.team_alice')::uuid),
  '1e000000-0000-4000-8000-000000000010'::uuid,
  'batch completed_by_user_id matches supervisor'
);

-- TEST 19: Read RPC returns the populated batch JSON
select is(
  (select (public.get_operational_staff_monthly_evaluation_batch(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    current_setting('test.team_alice')::uuid,
    '2026-08-01'
  )->>'total_evaluated_staff')::int),
  2,
  'get_operational_staff_monthly_evaluation_batch returns completed batch details'
);

-- TEST 20: Re-finalizing the same month fails deterministically with 23505 (conflict)
select throws_ok(
  format($$select * from public.finalize_operational_staff_monthly_evaluations(
    '1e000000-0000-4000-8000-000000000010',
    '3e000000-0000-4000-8000-000000000010',
    '%s'::uuid,
    '2026-08-01'
  )$$, current_setting('test.team_alice')),
  '23505',
  'monthly evaluation batch already finalized',
  'second finalization rejected with conflict 23505'
);

reset role;-- TEST 21: Post-finalization roster addition does NOT modify the frozen batch
insert into public.operational_staff(id, organization_id, branch_id, display_name, employment_status, deactivated_at, deactivated_by, staff_code, created_by)
values ('6e000000-0000-4000-8000-000000000099', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', 'New Hire Late', 'active', null, null, 'W-Late', '1e000000-0000-4000-8000-000000000010');

insert into public.operational_staff_assignments(id, organization_id, branch_id, operational_staff_id, operational_team_id, supervisor_team_id, active, operational_roles)
values ('7e000000-0000-4000-8000-000000000099', '2e000000-0000-4000-8000-000000000010', '3e000000-0000-4000-8000-000000000010', '6e000000-0000-4000-8000-000000000099', current_setting('test.team_alice')::uuid, '5e000000-0000-4000-8000-000000000010', true, array['kitchen']);

select is(
  (select total_evaluated_staff from public.operational_staff_monthly_evaluation_batches where operational_team_id = current_setting('test.team_alice')::uuid),
  2,
  'post-finalization roster addition does not alter frozen batch total'
);

-- TEST 22: Terminated / Inactive workers did NOT count toward required staff
select is(
  (select count(*) from public.operational_staff_monthly_evaluations where operational_staff_id in ('6e000000-0000-4000-8000-000000000013', '6e000000-0000-4000-8000-000000000014')),
  0::bigint,
  'terminated or inactive assignment staff required no evaluations'
);

-- TEST 23: Factor catalog read RPC works and returns 30 factors
select is(
  (select count(*) from public.list_operational_staff_monthly_evaluation_factors()),
  30::bigint,
  'list_operational_staff_monthly_evaluation_factors returns 30 rows'
);

-- TEST 24: Factor catalog read RPC is service_role only
reset role;
select ok(
  not has_function_privilege('authenticated', 'public.list_operational_staff_monthly_evaluation_factors()', 'execute')
  and has_function_privilege('service_role', 'public.list_operational_staff_monthly_evaluation_factors()', 'execute'),
  'list_operational_staff_monthly_evaluation_factors is service_role only'
);

rollback;
