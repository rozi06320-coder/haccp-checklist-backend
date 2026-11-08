begin;
select plan(25);

-- 1. Contract & Schema Assertions
select has_function('private','incomplete_branch_tasks_completion_at',
  array['uuid','uuid','date','timestamp with time zone'],
  'private.incomplete_branch_tasks_completion_at function exists');

select ok((select procedure.prosecdef from pg_proc procedure
  where procedure.oid='private.incomplete_branch_tasks_completion_at(uuid,uuid,date,timestamptz)'::regprocedure),
  'private.incomplete_branch_tasks_completion_at is SECURITY DEFINER');

-- 2. Fixture Setup: Target Org & Branches
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '7a000000-0000-4000-8000-000000000001'::uuid,
  '7a000000-0000-4000-8000-000000000002'::uuid
]) id
on conflict (id) do nothing;

insert into public.organizations(id,name,slug,active)
values
  ('8a000000-0000-4000-8000-000000000001','Oil Test Org','oil-test-org',true)
on conflict (id) do nothing;

insert into public.branches(id,organization_id,name,code,timezone,active)
values
  ('9a000000-0000-4000-8000-000000000001','8a000000-0000-4000-8000-000000000001',
    'Oil Standard Branch','OIL-STD','Asia/Riyadh',true),
  ('9a000000-0000-4000-8000-000000000002','8a000000-0000-4000-8000-000000000001',
    'Oil Exempt Branch','OIL-EXM','Asia/Riyadh',true),
  ('9a000000-0000-4000-8000-000000000003','8a000000-0000-4000-8000-000000000001',
    'Oil Dubai Branch','OIL-DXB','Asia/Dubai',true)
on conflict (id) do nothing;

update public.profiles set full_name = 'Oil Supervisor', must_change_password = false
where id::text like '7a000000-%';

insert into public.branch_memberships(branch_id,user_id,role)
values
  ('9a000000-0000-4000-8000-000000000001','7a000000-0000-4000-8000-000000000001','branch_manager'),
  ('9a000000-0000-4000-8000-000000000002','7a000000-0000-4000-8000-000000000001','branch_manager'),
  ('9a000000-0000-4000-8000-000000000003','7a000000-0000-4000-8000-000000000001','branch_manager')
on conflict do nothing;

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values
  ('aa000000-0000-4000-8000-000000000001','8a000000-0000-4000-8000-000000000001',
   '9a000000-0000-4000-8000-000000000001','7a000000-0000-4000-8000-000000000001'),
  ('aa000000-0000-4000-8000-000000000002','8a000000-0000-4000-8000-000000000001',
   '9a000000-0000-4000-8000-000000000002','7a000000-0000-4000-8000-000000000001'),
  ('aa000000-0000-4000-8000-000000000003','8a000000-0000-4000-8000-000000000001',
   '9a000000-0000-4000-8000-000000000003','7a000000-0000-4000-8000-000000000001')
on conflict (id) do nothing;

-- Backdate teams created_at to before branch_close_at
update public.branch_supervisor_teams
set created_at = '2026-11-01 00:00:00+00'
where organization_id = '8a000000-0000-4000-8000-000000000001';

update public.branch_operational_teams
set created_at = '2026-11-01 00:00:00+00'
where organization_id = '8a000000-0000-4000-8000-000000000001';

-- Clean existing test rows
delete from public.daily_report_module_applicability
where branch_id in (
  '9a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000002',
  '9a000000-0000-4000-8000-000000000003'
);
delete from public.daily_report_branch_lifecycle
where branch_id in (
  '9a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000002',
  '9a000000-0000-4000-8000-000000000003'
);

-- Seed lifecycles
insert into public.daily_report_branch_lifecycle(
  organization_id,branch_id,effective_from_business_date,effective_to_business_date,active,timezone
) values
  ('8a000000-0000-4000-8000-000000000001','9a000000-0000-4000-8000-000000000001','2026-11-01',null,true,'Asia/Riyadh'),
  ('8a000000-0000-4000-8000-000000000001','9a000000-0000-4000-8000-000000000002','2026-11-01',null,true,'Asia/Riyadh'),
  ('8a000000-0000-4000-8000-000000000001','9a000000-0000-4000-8000-000000000003','2026-11-01',null,true,'Asia/Dubai');

-- Seed applicability for 6 modules
insert into public.daily_report_module_applicability(
  organization_id,branch_id,module_key,requirement_basis,required,effective_from_business_date,effective_to_business_date
)
select '8a000000-0000-4000-8000-000000000001', b.branch_id, m.module_key, m.basis,
  case when b.branch_id = '9a000000-0000-4000-8000-000000000002' and m.module_key = 'oil_tracking' then false else true end,
  '2026-11-01'::date, null
from (
  values
    ('9a000000-0000-4000-8000-000000000001'::uuid),
    ('9a000000-0000-4000-8000-000000000002'::uuid),
    ('9a000000-0000-4000-8000-000000000003'::uuid)
) b(branch_id)
cross join (
  values
    ('kitchen_opening', 'static'),
    ('foh_opening', 'static'),
    ('staff_hygiene', 'eligible_operational_staff'),
    ('daily_audit', 'static'),
    ('cold_storage', 'eligible_cold_storage_equipment'),
    ('oil_tracking', 'eligible_oil_tracking_fryers')
) m(module_key, basis);

-- Base business date: 2026-11-04.
-- In Asia/Riyadh (UTC+3), branch_close_at is 2026-11-05 04:00 local = 2026-11-05 01:00 UTC.
-- In Asia/Dubai (UTC+4), branch_close_at is 2026-11-05 04:00 local = 2026-11-05 00:00 UTC.

-- Test 3: Cutoff boundary enforcement (04:00 AM local time)
select throws_ok($$
  select * from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 00:59:00+00'::timestamptz
  )
$$, '55000', 'branch business date is not complete', 'evaluating before 04:00 branch-local cutoff throws 55000');

-- Scenario A: Zero submissions on required branch evaluates to incomplete
select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'incomplete',
  'Zero submissions on required branch evaluates to incomplete'
);

-- Scenario B: Exempt branch evaluates to not_required
select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000002',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'not_required',
  'Exempt branch evaluates to not_required'
);

-- Scenario C: 5 fryers configured, 2 active, both Opening & Closing submitted -> completed
insert into public.oil_tracking_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, state, opening_submitted_at, closing_submitted_at,
  branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot
) values (
  'ba000000-0000-4000-8000-000000000001',
  '8a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  '7a000000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001',
  '2026-11-04',
  'submitted',
  '2026-11-04 07:30:00+00',
  '2026-11-04 21:30:00+00',
  'Oil Standard Branch', 'Supervisor 1', 'Team A'
);

insert into public.oil_tracking_fryer_results(
  submission_id, fryer_id, fryer_label_snapshot, fryer_short_label_snapshot,
  in_use_today, oil_status, opening_temperature_c, opening_status, opening_note,
  closing_tpm_percent, closing_note
) values
  ('ba000000-0000-4000-8000-000000000001', 'fryer-1', 'Fryer 1', 'F1', true, 'new_oil', 175, 'pass', '', 18, ''),
  ('ba000000-0000-4000-8000-000000000001', 'fryer-2', 'Fryer 2', 'F2', true, 'filtered_oil', 178, 'pass', '', 23, 'Filtered after rush'),
  ('ba000000-0000-4000-8000-000000000001', 'fryer-3', 'Fryer 3', 'F3', false, 'pending', null, 'pending', '', null, ''),
  ('ba000000-0000-4000-8000-000000000001', 'fryer-4', 'Fryer 4', 'F4', false, 'pending', null, 'pending', '', null, ''),
  ('ba000000-0000-4000-8000-000000000001', 'fryer-5', 'Fryer 5', 'F5', false, 'pending', null, 'pending', '', null, '');

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'completed',
  '5 fryers with 2 active and both phases submitted evaluates to completed'
);

-- Scenario D: 5 fryers configured, 1 active, both phases submitted -> completed
update public.oil_tracking_fryer_results
set in_use_today = false, oil_status = 'pending', opening_temperature_c = null, opening_status = 'pending', closing_tpm_percent = null, closing_note = ''
where submission_id = 'ba000000-0000-4000-8000-000000000001' and fryer_id = 'fryer-2';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'completed',
  '5 fryers with 1 active and both phases submitted evaluates to completed'
);

-- Scenario E: Only Opening submitted (closing is null, state = draft) -> incomplete
update public.oil_tracking_submissions
set state = 'draft', closing_submitted_at = null
where id = 'ba000000-0000-4000-8000-000000000001';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'incomplete',
  '5 fryers with only Opening submitted evaluates to incomplete'
);

-- Scenario F: Zero active fryers (all 5 inactive) -> incomplete
update public.oil_tracking_fryer_results
set in_use_today = false, oil_status = 'pending', opening_temperature_c = null, opening_status = 'pending', closing_tpm_percent = null
where submission_id = 'ba000000-0000-4000-8000-000000000001';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'incomplete',
  'Zero active fryers in draft evaluates to incomplete'
);

-- Also test zero active fryers when state = submitted
update public.oil_tracking_submissions
set state = 'submitted', closing_submitted_at = '2026-11-04 21:30:00+00'
where id = 'ba000000-0000-4000-8000-000000000001';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'incomplete',
  'Zero active fryers even if marked submitted evaluates to incomplete'
);

-- Restore 2 active fryers
update public.oil_tracking_fryer_results
set in_use_today = true, oil_status = 'new_oil', opening_temperature_c = 175, opening_status = 'pass', closing_tpm_percent = 18
where submission_id = 'ba000000-0000-4000-8000-000000000001' and fryer_id in ('fryer-1', 'fryer-2');

-- Scenario G: Invalid / Unverifiable records fail closed to 'unknown'
-- G1: Active fryer with failed check and empty note -> unknown
update public.oil_tracking_fryer_results
set opening_status = 'fail', opening_note = ''
where submission_id = 'ba000000-0000-4000-8000-000000000001' and fryer_id = 'fryer-1';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'unknown',
  'Active fryer with failed opening and empty note fails closed to unknown'
);

-- Restore valid opening note
update public.oil_tracking_fryer_results
set opening_status = 'pass', opening_note = ''
where submission_id = 'ba000000-0000-4000-8000-000000000001' and fryer_id = 'fryer-1';

-- G2: Active fryer with TPM >= 21 and empty closing note -> unknown
update public.oil_tracking_fryer_results
set closing_tpm_percent = 24, closing_note = '   '
where submission_id = 'ba000000-0000-4000-8000-000000000001' and fryer_id = 'fryer-1';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'unknown',
  'Active fryer with closing TPM >= 21 and empty note fails closed to unknown'
);

-- Restore valid closing note
update public.oil_tracking_fryer_results
set closing_tpm_percent = 24, closing_note = 'Replaced oil immediately'
where submission_id = 'ba000000-0000-4000-8000-000000000001' and fryer_id = 'fryer-1';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'completed',
  'Active fryer with closing TPM >= 21 and valid corrective action note evaluates to completed'
);

-- G3: Future timestamp submitted_at -> unknown
update public.oil_tracking_submissions
set closing_submitted_at = '2026-11-05 05:00:00+00'
where id = 'ba000000-0000-4000-8000-000000000001';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'unknown',
  'Closing submitted in future relative to p_as_of fails closed to unknown'
);

-- Restore closing submitted at
update public.oil_tracking_submissions
set closing_submitted_at = '2026-11-04 21:30:00+00'
where id = 'ba000000-0000-4000-8000-000000000001';

-- G4: State = submitted but closing_submitted_at is null -> unknown
update public.oil_tracking_submissions
set closing_submitted_at = null
where id = 'ba000000-0000-4000-8000-000000000001';

select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'unknown',
  'Submitted state with null closing timestamp fails closed to unknown'
);

-- Restore valid closing submitted at
update public.oil_tracking_submissions
set closing_submitted_at = '2026-11-04 21:30:00+00'
where id = 'ba000000-0000-4000-8000-000000000001';

-- Scenario H: Dubai Timezone (Asia/Dubai) Boundary Verification
-- For Dubai on 2026-11-04, 04:00 local is 2026-11-05 00:00 UTC.
-- Zero submissions on Dubai branch:
-- At 2026-11-04 23:59 UTC -> throws 55000 (before 04:00 Dubai)
select throws_ok($$
  select * from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000003',
    '2026-11-04'::date,
    '2026-11-04 23:59:00+00'::timestamptz
  )
$$, '55000', 'branch business date is not complete', 'Dubai cutoff enforced before 04:00 Dubai time');

-- At 2026-11-05 00:01 UTC -> 04:01 Dubai time, evaluates to incomplete
select is(
  (select module_state from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000003',
    '2026-11-04'::date,
    '2026-11-05 00:01:00+00'::timestamptz
  ) where module_key = 'oil_tracking'),
  'incomplete',
  'Dubai cutoff passes at 04:01 Dubai time and evaluates to incomplete'
);

-- Scenario I: Regression check - All 6 canonical modules evaluated without breaking
select is(
  (select count(*) from private.incomplete_branch_tasks_completion_at(
    '8a000000-0000-4000-8000-000000000001',
    '9a000000-0000-4000-8000-000000000001',
    '2026-11-04'::date,
    '2026-11-05 02:00:00+00'::timestamptz
  )),
  6::bigint,
  'incomplete_branch_tasks_completion_at returns all 6 canonical modules'
);

select is(
  (select array_agg(module_key order by ordinal)
   from (
     select module_key, row_number() over () as ordinal
     from private.incomplete_branch_tasks_completion_at(
       '8a000000-0000-4000-8000-000000000001',
       '9a000000-0000-4000-8000-000000000001',
       '2026-11-04'::date,
       '2026-11-05 02:00:00+00'::timestamptz
     )
   ) x),
  array['kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking']::text[],
  'Canonical module order is strictly preserved'
);

-- Scenario J: Complete branch tasks producer RPC integration
-- Now create completed records for all other 5 modules so we can verify get_incomplete_branch_tasks_completion
-- kitchen_opening
insert into public.checklist_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, checklist_type, definition_id, state, submitted_at,
  branch_name_snapshot, branch_code_snapshot, supervisor_name_snapshot
) values (
  'ca000000-0000-4000-8000-000000000001',
  '8a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  '7a000000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001',
  '2026-11-04', 'kitchen_opening', 'kitchen_opening_v1', 'submitted', '2026-11-04 06:00:00+00',
  'Oil Standard Branch', 'OIL-STD', 'Supervisor 1'
);

insert into public.opening_item_results(submission_id, definition_id, item_id, ordinal, item_text_snapshot, answer)
select 'ca000000-0000-4000-8000-000000000001', cdi.definition_id, cdi.item_id, cdi.ordinal, cdi.item_text, 'completed'
from public.checklist_definition_items cdi
where cdi.definition_id = 'kitchen_opening_v1';

-- foh_opening
insert into public.checklist_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, checklist_type, definition_id, state, submitted_at,
  branch_name_snapshot, branch_code_snapshot, supervisor_name_snapshot
) values (
  'ca000000-0000-4000-8000-000000000002',
  '8a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  '7a000000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001',
  '2026-11-04', 'foh_opening', 'foh_opening_v1', 'submitted', '2026-11-04 06:30:00+00',
  'Oil Standard Branch', 'OIL-STD', 'Supervisor 1'
);

insert into public.opening_item_results(submission_id, definition_id, item_id, ordinal, item_text_snapshot, answer)
select 'ca000000-0000-4000-8000-000000000002', cdi.definition_id, cdi.item_id, cdi.ordinal, cdi.item_text, 'completed'
from public.checklist_definition_items cdi
where cdi.definition_id = 'foh_opening_v1';

-- daily_audit
insert into public.checklist_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, checklist_type, definition_id, state, submitted_at,
  branch_name_snapshot, branch_code_snapshot, supervisor_name_snapshot
) values (
  'ca000000-0000-4000-8000-000000000003',
  '8a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  '7a000000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001',
  '2026-11-04', 'daily_audit', 'daily_audit_v1', 'submitted', '2026-11-04 10:00:00+00',
  'Oil Standard Branch', 'OIL-STD', 'Supervisor 1'
);

insert into public.daily_audit_item_results(submission_id, organization_id, branch_id, item_id, item_number, answer)
select 'ca000000-0000-4000-8000-000000000003', '8a000000-0000-4000-8000-000000000001', '9a000000-0000-4000-8000-000000000001',
  def.item_id, def.item_number, 'compliant'
from public.daily_audit_item_definitions def
where def.active;

-- staff_hygiene: 1 staff on duty assigned to team
insert into public.operational_staff(id, organization_id, branch_id, display_name, employment_status, created_by, created_at)
values ('ea000000-0000-4000-8000-000000000001', '8a000000-0000-4000-8000-000000000001', '9a000000-0000-4000-8000-000000000001', 'Staff Member 1', 'active', '7a000000-0000-4000-8000-000000000001', '2026-11-01 00:00:00+00')
on conflict (id) do nothing;

insert into public.operational_staff_assignments(id, organization_id, branch_id, operational_staff_id, supervisor_team_id, operational_team_id, operational_roles, valid_from, valid_to, created_at)
values ('fa000000-0000-4000-8000-000000000001', '8a000000-0000-4000-8000-000000000001', '9a000000-0000-4000-8000-000000000001', 'ea000000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001',
  (select id from public.branch_operational_teams where legacy_supervisor_team_id = 'aa000000-0000-4000-8000-000000000001'),
  array['kitchen'::text], '2026-11-01', null, '2026-11-01 00:00:00+00');

insert into public.checklist_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  operational_team_id, operational_team_name_snapshot, submitted_by_user_id, hygiene_revision,
  business_date, checklist_type, definition_id, state, submitted_at,
  branch_name_snapshot, branch_code_snapshot, supervisor_name_snapshot
) values (
  'ca000000-0000-4000-8000-000000000004',
  '8a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  '7a000000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001',
  (select id from public.branch_operational_teams where legacy_supervisor_team_id = 'aa000000-0000-4000-8000-000000000001'),
  'Team A',
  '7a000000-0000-4000-8000-000000000001',
  1,
  '2026-11-04', 'staff_hygiene', 'staff_hygiene_v1', 'submitted', '2026-11-04 07:00:00+00',
  'Oil Standard Branch', 'OIL-STD', 'Supervisor 1'
);

insert into public.hygiene_staff_snapshots(submission_id, operational_staff_id, display_name_snapshot, operational_roles_snapshot, uniform_result, fingernails_result, hair_result, facial_hair_result)
values ('ca000000-0000-4000-8000-000000000004', 'ea000000-0000-4000-8000-000000000001', 'Staff Member 1', array['kitchen'::text], 'pass', 'pass', 'pass', 'pass');

-- cold_storage: 1 equipment, all slots completed
insert into public.branch_cold_storage_equipment(id, organization_id, branch_id, equipment_type, name, created_by, active, created_at)
values ('1b000000-0000-4000-8000-000000000001', '8a000000-0000-4000-8000-000000000001', '9a000000-0000-4000-8000-000000000001', 'refrigerator', 'Main Fridge', '7a000000-0000-4000-8000-000000000001', true, '2026-11-01 00:00:00+00');

insert into public.cold_storage_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, state, branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot
) values (
  'ca000000-0000-4000-8000-000000000005',
  '8a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  '7a000000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001',
  '2026-11-04', 'submitted', 'Oil Standard Branch', 'Supervisor 1', 'Team A'
);

insert into public.cold_storage_equipment(id, submission_id, master_equipment_id, organization_id, branch_id, equipment_id, equipment_name, equipment_type, active)
values (gen_random_uuid(), 'ca000000-0000-4000-8000-000000000005', '1b000000-0000-4000-8000-000000000001', '8a000000-0000-4000-8000-000000000001', '9a000000-0000-4000-8000-000000000001', '1b000000-0000-4000-8000-000000000001', 'Main Fridge', 'refrigerator', true);

insert into public.cold_storage_readings(submission_id, equipment_id, slot, temperature_c, status, submitted_at)
values
  ('ca000000-0000-4000-8000-000000000005', '1b000000-0000-4000-8000-000000000001', '12:00', 3.5, 'pass', '2026-11-04 12:15:00+00'),
  ('ca000000-0000-4000-8000-000000000005', '1b000000-0000-4000-8000-000000000001', '20:00', 3.2, 'pass', '2026-11-04 20:15:00+00'),
  ('ca000000-0000-4000-8000-000000000005', '1b000000-0000-4000-8000-000000000001', '02:00', 3.0, 'pass', '2026-11-05 02:05:00+00');

-- Evaluation: all 6 modules are completed!
select is(
  (select count(*) filter (where module_state = 'completed')
   from private.incomplete_branch_tasks_completion_at(
     '8a000000-0000-4000-8000-000000000001',
     '9a000000-0000-4000-8000-000000000001',
     '2026-11-04'::date,
     '2026-11-05 03:00:00+00'::timestamptz
   )),
  6::bigint,
  'All 6 modules including partial fryer oil tracking evaluate to completed'
);

-- Setup evaluation job for get_incomplete_branch_tasks_completion
insert into private.organization_manager_notification_evaluation_jobs(
  id, organization_id, branch_id, notification_category, business_date, state, lease_token, leased_by, lease_expires_at
) values (
  'fb000000-0000-4000-8000-000000000001',
  '8a000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  'incomplete_branch_tasks',
  '2026-11-04',
  'running',
  'bb000000-0000-4000-8000-000000000001',
  '7a000000-0000-4000-8000-000000000001',
  now() + interval '5 minutes'
);

select is(
  (select distinct source_completeness
   from public.get_incomplete_branch_tasks_completion(
     'fb000000-0000-4000-8000-000000000001',
     'bb000000-0000-4000-8000-000000000001'
   )),
  'complete',
  'get_incomplete_branch_tasks_completion evaluates source_completeness as complete when oil tracking has partial fryers'
);

-- When oil tracking is zero active fryers (incomplete), source_completeness is STILL 'complete' (not 'unknown')!
-- Meaning the worker recognizes the branch as incomplete and produces manager notification rather than retrying unknown!
update public.oil_tracking_fryer_results
set in_use_today = false, oil_status = 'pending', opening_temperature_c = null, opening_status = 'pending', closing_tpm_percent = null, closing_note = ''
where submission_id = 'ba000000-0000-4000-8000-000000000001';

update public.oil_tracking_submissions
set state = 'draft', closing_submitted_at = null
where id = 'ba000000-0000-4000-8000-000000000001';

select is(
  (select distinct source_completeness
   from public.get_incomplete_branch_tasks_completion(
     'fb000000-0000-4000-8000-000000000001',
     'bb000000-0000-4000-8000-000000000001'
   )),
  'complete',
  'get_incomplete_branch_tasks_completion source_completeness is complete (not unknown) when oil tracking is incomplete'
);

select is(
  (select module_state
   from public.get_incomplete_branch_tasks_completion(
     'fb000000-0000-4000-8000-000000000001',
     'bb000000-0000-4000-8000-000000000001'
   ) where module_key = 'oil_tracking'),
  'incomplete',
  'oil_tracking module_state is incomplete'
);

-- When oil tracking has 0 submissions on a required branch, source_completeness is STILL 'complete' (not 'unknown')!
delete from public.oil_tracking_submissions where id = 'ba000000-0000-4000-8000-000000000001';

select is(
  (select distinct source_completeness
   from public.get_incomplete_branch_tasks_completion(
     'fb000000-0000-4000-8000-000000000001',
     'bb000000-0000-4000-8000-000000000001'
   )),
  'complete',
  'get_incomplete_branch_tasks_completion source_completeness is complete when oil tracking has 0 submissions'
);

select is(
  (select module_state
   from public.get_incomplete_branch_tasks_completion(
     'fb000000-0000-4000-8000-000000000001',
     'bb000000-0000-4000-8000-000000000001'
   ) where module_key = 'oil_tracking'),
  'incomplete',
  'oil_tracking module_state is incomplete when zero submissions exist'
);

select finish();
rollback;
