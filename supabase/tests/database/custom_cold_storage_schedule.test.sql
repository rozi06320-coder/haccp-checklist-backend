begin;
select plan(38);

-- 1-6: Security, search_path, and privileges of new RPCs
select has_function('public', 'set_internal_admin_branch_custom_cold_storage_schedule', array['uuid','uuid','uuid','text[]','date','text'], 'set_internal_admin_branch_custom_cold_storage_schedule exists');
select has_function('public', 'get_internal_admin_branch_cold_storage_schedule_v2', array['uuid','uuid','uuid'], 'get_internal_admin_branch_cold_storage_schedule_v2 exists');
select is(has_function_privilege('anon', 'public.set_internal_admin_branch_custom_cold_storage_schedule(uuid,uuid,uuid,text[],date,text)', 'execute'), false, 'anon cannot execute set_internal_admin_branch_custom_cold_storage_schedule');
select is(has_function_privilege('authenticated', 'public.set_internal_admin_branch_custom_cold_storage_schedule(uuid,uuid,uuid,text[],date,text)', 'execute'), false, 'authenticated cannot execute set_internal_admin_branch_custom_cold_storage_schedule');
select is(has_function_privilege('service_role', 'public.set_internal_admin_branch_custom_cold_storage_schedule(uuid,uuid,uuid,text[],date,text)', 'execute'), true, 'service_role can execute set_internal_admin_branch_custom_cold_storage_schedule');
select is(has_function_privilege('service_role', 'public.get_internal_admin_branch_cold_storage_schedule_v2(uuid,uuid,uuid)', 'execute'), true, 'service_role can execute get_internal_admin_branch_cold_storage_schedule_v2');

-- 7-13: 04:00 boundary & legacy 3:00 / 8:00 slot ordering
select is(private.cold_storage_slot_order('3:00'), 1200, 'legacy 3:00 alias order preserved');
select is(private.cold_storage_slot_order('8:00'), 1560, 'legacy 8:00 alias order preserved');
select is(private.cold_storage_slot_order('02:00'), 1560, '02:00 sorts after midnight (<04:00)');
select is(private.cold_storage_slot_order('03:00'), 1620, '03:00 sorts in current business day (<04:00)');
select is(private.cold_storage_slot_order('03:59'), 1679, '03:59 sorts at end of current business day (<04:00)');
select is(private.cold_storage_slot_order('04:00'), 240, '04:00 starts new business day');
select is(private.cold_storage_slot_order('12:00'), 720, '12:00 sorts at 720');

-- Seed isolated org, actors, branches, and baseline STANDARD / EVERY_2_HOURS versions
do $$
declare
  v_admin uuid := 'c1000000-0000-4000-8000-000000000001';
  v_mgr uuid := 'c1000000-0000-4000-8000-000000000002';
  v_sup uuid := 'c1000000-0000-4000-8000-000000000003';
  v_org_a uuid := 'c2000000-0000-4000-8000-000000000001';
  v_org_b uuid := 'c2000000-0000-4000-8000-000000000002';
  v_br_a uuid := 'c3000000-0000-4000-8000-000000000001';
  v_br_b uuid := 'c3000000-0000-4000-8000-000000000002';
  v_br_c uuid := 'c3000000-0000-4000-8000-000000000003';
  v_br_d uuid := 'c3000000-0000-4000-8000-000000000004';
  v_br_e uuid := 'c3000000-0000-4000-8000-000000000005';
  v_team_a uuid := 'c4000000-0000-4000-8000-000000000001';
  v_std_id uuid := 'c5000000-0000-4000-8000-000000000001';
  v_2h_id uuid := 'c5000000-0000-4000-8000-000000000002';
  v_sub_id uuid := 'c6000000-0000-4000-8000-000000000001';
  v_eq_id uuid := 'c7000000-0000-4000-8000-000000000001';
  v_today date := private.phase4a_business_date('Asia/Riyadh');
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cs-admin@example.com', 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
    (v_mgr, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cs-mgr@example.com', 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
    (v_sup, '00000000-0000-4000-8000-000000000000', 'authenticated', 'authenticated', 'cs-sup@example.com', 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now())
  on conflict (id) do nothing;

  insert into public.internal_admin_memberships (user_id, active) values (v_admin, true) on conflict (user_id) do update set active = true;
  insert into public.organizations (id, name, slug, active) values
    (v_org_a, 'CS Org A', 'cs-org-a', true),
    (v_org_b, 'CS Org B', 'cs-org-b', true)
  on conflict (id) do nothing;

  insert into public.organization_memberships (organization_id, user_id, role, active)
  values (v_org_a, v_mgr, 'organization_manager', true)
  on conflict (organization_id, user_id) do nothing;

  insert into public.branches (id, organization_id, name, code, timezone, country_code, active, created_at, sales_tracking_percentage_included, oil_tracking_percentage_included, foh_opening_included)
  values
    (v_br_a, v_org_a, 'CS Branch A', 'CS-A', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, true, true),
    (v_br_b, v_org_a, 'CS Branch B', 'CS-B', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, false, true),
    (v_br_c, v_org_a, 'CS Branch C', 'CS-C', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', false, true, true),
    (v_br_d, v_org_a, 'CS Branch D', 'CS-D', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, true, true),
    (v_br_e, v_org_a, 'CS Branch E', 'CS-E', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, true, true)
  on conflict (id) do nothing;

  insert into public.cold_storage_schedule_versions (id, organization_id, code, name, active)
  values
    (v_std_id, null, 'STANDARD', 'Standard', true),
    (v_2h_id, null, 'EVERY_2_HOURS', 'Every 2 Hours', true)
  on conflict (id) do nothing;

  insert into public.cold_storage_schedule_slots (schedule_version_id, slot_time, operational_ordinal)
  values
    (v_std_id, '12:00', 1), (v_std_id, '20:00', 2), (v_std_id, '02:00', 3),
    (v_2h_id, '04:00', 1), (v_2h_id, '06:00', 2), (v_2h_id, '08:00', 3), (v_2h_id, '10:00', 4),
    (v_2h_id, '12:00', 5), (v_2h_id, '14:00', 6), (v_2h_id, '16:00', 7), (v_2h_id, '18:00', 8),
    (v_2h_id, '20:00', 9), (v_2h_id, '22:00', 10), (v_2h_id, '00:00', 11), (v_2h_id, '02:00', 12)
  on conflict do nothing;

  insert into public.branch_cold_storage_schedule_assignments (organization_id, branch_id, schedule_version_id, effective_from_business_date, created_by_user_id)
  values
    (v_org_a, v_br_a, v_std_id, date '2026-01-01', v_admin),
    (v_org_a, v_br_b, v_2h_id, date '2026-01-01', v_admin)
  on conflict do nothing;

  insert into public.branch_memberships (branch_id, user_id, role, active)
  values (v_br_a, v_sup, 'branch_manager', true)
  on conflict do nothing;

  insert into public.branch_supervisor_teams (id, organization_id, branch_id, supervisor_user_id, active, created_at, updated_at)
  values (v_team_a, v_org_a, v_br_a, v_sup, true, now(), now())
  on conflict (id) do nothing;

  -- Historical submission pinned to STANDARD on v_br_a
  insert into public.cold_storage_submissions (id, organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state, branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot, schedule_version_id)
  values (v_sub_id, v_org_a, v_br_a, v_sup, v_team_a, v_today, 'draft', 'CS Branch A', 'Sup', 'Team A', v_std_id)
  on conflict (id) do nothing;

  insert into public.branch_cold_storage_equipment (id, organization_id, branch_id, equipment_code, name, equipment_type, active, created_by)
  values (v_eq_id, v_org_a, v_br_a, 'C1', 'Walk-in Chiller', 'refrigerator', true, v_sup)
  on conflict (id) do nothing;

  insert into public.cold_storage_equipment (submission_id, organization_id, branch_id, master_equipment_id, equipment_id, equipment_code, equipment_name, equipment_type, active)
  values (v_sub_id, v_org_a, v_br_a, v_eq_id, v_eq_id::text, 'C1', 'Walk-in Chiller', 'refrigerator', true)
  on conflict do nothing;

  insert into public.cold_storage_readings (submission_id, equipment_id, slot, temperature_c, status, corrective_action, submitted_at)
  values
    (v_sub_id, v_eq_id::text, '12:00', 3.5, 'pass', '', now()),
    (v_sub_id, v_eq_id::text, '20:00', 4.0, 'pass', '', now()),
    (v_sub_id, v_eq_id::text, '02:00', 3.8, 'pass', '', now())
  on conflict do nothing;
end;
$$;

set local role service_role;

-- 14-19: Validation, Auth, Cross-Org, Future Date checks
select throws_ok(
  $$select public.set_internal_admin_branch_custom_cold_storage_schedule('c1000000-0000-4000-8000-000000000002'::uuid, 'c2000000-0000-4000-8000-000000000001'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid, array['09:00'], private.phase4a_business_date('Asia/Riyadh') + 1, 'Unauthorized')$$,
  '42501', null, 'non-internal-admin rejected with 42501'
);
select throws_ok(
  $$select public.set_internal_admin_branch_custom_cold_storage_schedule('c1000000-0000-4000-8000-000000000001'::uuid, 'c2000000-0000-4000-8000-000000000002'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid, array['09:00'], private.phase4a_business_date('Asia/Riyadh') + 1, 'CrossOrg')$$,
  'P0002', null, 'cross-organization branch rejected with P0002'
);
select throws_ok(
  $$select public.set_internal_admin_branch_custom_cold_storage_schedule('c1000000-0000-4000-8000-000000000001'::uuid, 'c2000000-0000-4000-8000-000000000001'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid, array['09:00','09:00'], private.phase4a_business_date('Asia/Riyadh') + 1, 'Dup')$$,
  '22023', null, 'duplicate slots rejected with 22023'
);
select throws_ok(
  $$select public.set_internal_admin_branch_custom_cold_storage_schedule('c1000000-0000-4000-8000-000000000001'::uuid, 'c2000000-0000-4000-8000-000000000001'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid, array['24:00'], private.phase4a_business_date('Asia/Riyadh') + 1, 'BadTime')$$,
  '22023', null, 'invalid slot format 24:00 rejected with 22023'
);
select throws_ok(
  $$select public.set_internal_admin_branch_custom_cold_storage_schedule('c1000000-0000-4000-8000-000000000001'::uuid, 'c2000000-0000-4000-8000-000000000001'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid, array[]::text[], private.phase4a_business_date('Asia/Riyadh') + 1, 'Empty')$$,
  '22023', null, 'empty slots rejected with 22023'
);
select throws_ok(
  $$select public.set_internal_admin_branch_custom_cold_storage_schedule('c1000000-0000-4000-8000-000000000001'::uuid, 'c2000000-0000-4000-8000-000000000001'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid, array['09:00'], private.phase4a_business_date('Asia/Riyadh'), 'Today')$$,
  '22023', null, 'current business date rejected with 22023'
);

-- 20-26: Variable slot counts (1, 3, 4, 12, 48), 04:00 sorting, idempotency, and future protection
-- Branch A: 4 custom slots sorted across midnight (01:30, 03:30 after 21:00 and 10:00)
select is(
  (public.set_internal_admin_branch_custom_cold_storage_schedule(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000001'::uuid,
    array['03:30','10:00','01:30','21:00'],
    private.phase4a_business_date('Asia/Riyadh') + 1,
    '4-Slot Overnight'
  ) -> 'pending' -> 'slots' -> 0 ->> 'slot'),
  '10:00',
  '4-slot custom schedule sorts 10:00 first in 04:00 business day'
);
select is(
  (public.get_internal_admin_branch_cold_storage_schedule_v2(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000001'::uuid
  ) -> 'pending' -> 'slots' -> 3 ->> 'slot'),
  '03:30',
  '4-slot custom schedule sorts 03:30 last in 04:00 business day'
);

-- Idempotent repeat succeeds without duplicate version
select is(
  (public.set_internal_admin_branch_custom_cold_storage_schedule(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000001'::uuid,
    array['21:00','01:30','10:00','03:30'],
    private.phase4a_business_date('Asia/Riyadh') + 1,
    '4-Slot Overnight'
  ) -> 'pending' ->> 'schedule_name'),
  '4-Slot Overnight',
  'repeated identical request is idempotent'
);

-- Conflicting future assignment on Branch A rejected with 23505
select throws_ok(
  $$select public.set_internal_admin_branch_custom_cold_storage_schedule('c1000000-0000-4000-8000-000000000001'::uuid, 'c2000000-0000-4000-8000-000000000001'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid, array['09:00'], private.phase4a_business_date('Asia/Riyadh') + 2, 'Overwrite')$$,
  '23505', null, 'existing pending future assignment protected with 23505'
);

-- Branch C: 1 custom slot
select is(
  jsonb_array_length(public.set_internal_admin_branch_custom_cold_storage_schedule(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000003'::uuid,
    array['14:00'],
    private.phase4a_business_date('Asia/Riyadh') + 1,
    '1-Slot'
  ) -> 'pending' -> 'slots'),
  1,
  '1-slot custom schedule supported'
);

-- Branch D: 12 custom slots
select is(
  jsonb_array_length(public.set_internal_admin_branch_custom_cold_storage_schedule(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000004'::uuid,
    array['04:00','06:00','08:00','10:00','12:00','14:00','16:00','18:00','20:00','22:00','00:00','02:00'],
    private.phase4a_business_date('Asia/Riyadh') + 1,
    '12-Slot'
  ) -> 'pending' -> 'slots'),
  12,
  '12-slot custom schedule supported'
);

-- Branch E: 48 custom slots (every 30 mins)
select is(
  jsonb_array_length(public.set_internal_admin_branch_custom_cold_storage_schedule(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000005'::uuid,
    (
      select array_agg(
        lpad((i / 2)::text, 2, '0') || ':' || case when i % 2 = 0 then '00' else '30' end
      )
      from generate_series(0, 47) i
    ),
    private.phase4a_business_date('Asia/Riyadh') + 1,
    '48-Slot'
  ) -> 'pending' -> 'slots'),
  48,
  '48-slot custom schedule supported'
);

-- 27-32: History, Today's schedule unchanged, Draft & pinned schedule_version_id preserved
select is(
  (public.get_internal_admin_branch_cold_storage_schedule_v2(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000001'::uuid
  ) -> 'current' ->> 'schedule_code'),
  'STANDARD',
  'current active schedule on Branch A remains STANDARD today'
);
select is(
  jsonb_array_length(public.get_internal_admin_branch_cold_storage_schedule_v2(
    'c1000000-0000-4000-8000-000000000001'::uuid,
    'c2000000-0000-4000-8000-000000000001'::uuid,
    'c3000000-0000-4000-8000-000000000001'::uuid
  ) -> 'history'),
  2,
  'schedule history returns both active and pending assignments'
);
reset role;
select is(
  (select schedule_version_id from public.cold_storage_submissions where id = 'c6000000-0000-4000-8000-000000000001'::uuid),
  'c5000000-0000-4000-8000-000000000001'::uuid,
  'existing submission retains pinned STANDARD schedule_version_id'
);
select is(
  (select count(*)::integer from public.cold_storage_readings where submission_id = 'c6000000-0000-4000-8000-000000000001'::uuid),
  3,
  'existing draft temperature readings preserved untouched'
);
set local role service_role;

-- Dynamic Supervisor Overview uses pinned schedule_version_id
select is(
  (
    select (c ->> 'answered_checks')::integer
    from jsonb_array_elements(public.get_phase4a_supervisor_overview('c1000000-0000-4000-8000-000000000003'::uuid, 'c3000000-0000-4000-8000-000000000001'::uuid) -> 'checklists') c
    where c ->> 'checklist_type' = 'cold_storage'
  ),
  3,
  'get_phase4a_supervisor_overview computes dynamic answered_checks for pinned schedule'
);

-- Dynamic first eligible slot respects EVERY_2_HOURS on Branch B and 04:00 boundary
select is(
  (select first_eligible_slot from private.cold_storage_master_first_eligible_slot('c3000000-0000-4000-8000-000000000002'::uuid, timestamptz '2026-11-27 00:30:00+00')),
  '04:00',
  'Branch B EVERY_2_HOURS equipment created at 03:30 Riyadh (00:30 UTC) becomes eligible at 04:00 next business day'
);

-- 33-38: Dynamic missed-slot close times, Branch Day Off interaction, exemptions preserved
select is(
  (
    select (created_at at time zone 'Asia/Riyadh')::time
    from private.cold_storage_managed_missed_issue_rows_at('c2000000-0000-4000-8000-000000000001'::uuid, timestamptz '2026-11-28 19:00:00+00')
    where branch_id = 'c3000000-0000-4000-8000-000000000002'::uuid
      and business_date = date '2026-11-28'
      and slot = '12:00'
    limit 1
  ),
  time '14:00',
  'Branch B EVERY_2_HOURS 12:00 missed issue closes dynamically at next slot 14:00'
);
select is(
  (
    select count(*)::integer
    from private.cold_storage_managed_missed_issue_rows_at('c2000000-0000-4000-8000-000000000001'::uuid, now())
    where branch_id = 'c3000000-0000-4000-8000-000000000001'::uuid
      and business_date = private.phase4a_business_date('Asia/Riyadh')
  ),
  0,
  'Branch A with submitted 12:00/20:00/02:00 readings produces 0 missed issues for today'
);
reset role;
select ok(
  not exists (select 1 from public.branches where id = 'c3000000-0000-4000-8000-000000000002'::uuid and oil_tracking_percentage_included),
  'Branch B oil_tracking exemption preserved'
);
select ok(
  not exists (select 1 from public.branches where id = 'c3000000-0000-4000-8000-000000000003'::uuid and sales_tracking_percentage_included),
  'Branch C sales_tracking exemption preserved'
);
select is(
  (select count(*)::integer from public.cold_storage_schedule_slots where schedule_version_id = 'c5000000-0000-4000-8000-000000000001'::uuid),
  3,
  'STANDARD schedule slots remain 3 and unmodified'
);
select is(
  (select count(*)::integer from public.cold_storage_schedule_slots where schedule_version_id = 'c5000000-0000-4000-8000-000000000002'::uuid),
  12,
  'EVERY_2_HOURS schedule slots remain 12 and unmodified'
);
set local role service_role;

select * from finish();
rollback;
