begin;
select plan(67);

-- =============================================================================
-- 1. Security, Search Path, and Function Privilege Assertions
-- =============================================================================

select has_function(
  'public',
  'get_supervisor_branch_day_off_status',
  array['uuid', 'uuid'],
  'public.get_supervisor_branch_day_off_status exists'
);

select is(
  has_function_privilege('anon', 'public.get_supervisor_branch_day_off_status(uuid,uuid)', 'execute'),
  false,
  'anon cannot execute get_supervisor_branch_day_off_status'
);
select is(
  has_function_privilege('authenticated', 'public.get_supervisor_branch_day_off_status(uuid,uuid)', 'execute'),
  false,
  'authenticated cannot execute get_supervisor_branch_day_off_status'
);
select is(
  has_function_privilege('service_role', 'public.get_supervisor_branch_day_off_status(uuid,uuid)', 'execute'),
  true,
  'service_role can execute get_supervisor_branch_day_off_status'
);

select is(
  (
    select count(*)::integer
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('public', 'get_daily_report_authoritative_applicability'),
      ('public', 'get_daily_report_staff_hygiene_applicability'),
      ('public', 'get_manager_staff_hygiene_applicability_range'),
      ('public', 'get_supervisor_branch_day_off_status'),
      ('public', 'get_phase4a_management_overview'),
      ('public', 'get_management_overview_with_daily_audit'),
      ('public', 'get_phase4a_supervisor_overview'),
      ('public', 'list_organization_manager_notification_projection'),
      ('public', 'list_organization_manager_notification_projection_cursor'),
      ('public', 'count_organization_manager_notification_projection'),
      ('public', 'get_organization_manager_notification_detail'),
      ('public', 'list_organization_manager_notifications'),
      ('private', 'managed_financial_closing_operations_summary'),
      ('private', 'phase4a_managed_missed_issue_rows_at'),
      ('private', 'oil_tracking_managed_missed_issue_rows_at'),
      ('private', 'cold_storage_missed_slots_for'),
      ('private', 'cold_storage_managed_missed_issue_rows_at'),
      ('private', 'sales_tracking_managed_issue_rows_at'),
      ('private', 'incomplete_branch_tasks_completion_at'),
      ('private', 'organization_manager_sales_tracking_status'),
      ('private', 'supervisor_notification_condition_unresolved')
    )
      and (
        not p.prosecdef
        or p.proconfig is null
        or not (p.proconfig @> array['search_path='] or p.proconfig @> array['search_path=""'])
      )
  ),
  0,
  'all Phase 3 functions enforce SECURITY DEFINER and empty search_path'
);

-- =============================================================================
-- 2. Fixture Setup: Two Organizations, Branch A (Day Off), Branch B & C (On Duty), Branch D (Org 2)
-- =============================================================================

insert into auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'p3-admin@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'p3-mgr1@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'p3-sup-a@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'p3-sup-b@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'p3-sup-c@example.invalid', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'p3-mgr2@example.invalid', '{}', '{}', now(), now())
on conflict (id) do nothing;

update public.profiles
set full_name = 'Phase 3 User ' || right(id::text, 2),
    must_change_password = false,
    disabled_at = null
where id in (
  'e0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000002',
  'e0000000-0000-4000-8000-000000000003',
  'e0000000-0000-4000-8000-000000000004',
  'e0000000-0000-4000-8000-000000000005',
  'e0000000-0000-4000-8000-000000000006'
);

insert into public.internal_admin_memberships(user_id, active)
values ('e0000000-0000-4000-8000-000000000001', true)
on conflict (user_id) do update set active = true;

insert into public.organizations(id, name, slug, active)
values
  ('e1000000-0000-4000-8000-000000000001', 'Phase 3 Org One', 'phase3-org-one', true),
  ('e1000000-0000-4000-8000-000000000002', 'Phase 3 Org Two', 'phase3-org-two', true)
on conflict (id) do nothing;

insert into public.organization_memberships(organization_id, user_id, role, active)
values
  ('e1000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000002', 'organization_manager', true),
  ('e1000000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000006', 'organization_manager', true)
on conflict (organization_id, user_id) do nothing;

-- Branch A, B, C in Org 1 (created well in the past so historical closed-day checks apply); Branch D in Org 2.
-- Note: Branch C has oil_tracking_percentage_included = false to verify branch-specific exemptions remain preserved.
insert into public.branches(
  id, organization_id, name, code, timezone, country_code, active, created_at,
  sales_tracking_percentage_included, oil_tracking_percentage_included, foh_opening_included
)
values
  ('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'Branch A', 'P3-BRA', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, true, true),
  ('e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'Branch B', 'P3-BRB', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, true, true),
  ('e2000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'Branch C', 'P3-BRC', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, false, true),
  ('e2000000-0000-4000-8000-000000000004', 'e1000000-0000-4000-8000-000000000002', 'Branch D Org2', 'P3-BRD', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z', true, true, true)
on conflict (id) do nothing;

-- Ensure daily_report_branch_lifecycle and daily_report_module_applicability cover 2026-01-01 onward
delete from public.daily_report_module_applicability
where branch_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003',
  'e2000000-0000-4000-8000-000000000004'
);
delete from public.daily_report_branch_lifecycle
where branch_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003',
  'e2000000-0000-4000-8000-000000000004'
);

insert into public.daily_report_branch_lifecycle(
  organization_id, branch_id, timezone, active, effective_from_business_date
)
values
  ('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'Asia/Riyadh', true, '2026-01-01'),
  ('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', 'Asia/Riyadh', true, '2026-01-01'),
  ('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000003', 'Asia/Riyadh', true, '2026-01-01'),
  ('e1000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000004', 'Asia/Riyadh', true, '2026-01-01');

select private.seed_daily_report_module_applicability('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', '2026-01-01');
select private.seed_daily_report_module_applicability('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', '2026-01-01');
select private.seed_daily_report_module_applicability('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000003', '2026-01-01');
select private.seed_daily_report_module_applicability('e1000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000004', '2026-01-01');

-- Seed synthetic configurable Cold Storage schedule versions, slots, and branch assignments
insert into public.cold_storage_schedule_versions(id, organization_id, code, name, active)
values
  ('e9000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'DEFAULT_3', 'Default 3-Slot Schedule', true),
  ('e9000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'CUSTOM_2', 'Custom 2-Slot Schedule', true)
on conflict (id) do nothing;

insert into public.cold_storage_schedule_slots(schedule_version_id, slot_time, operational_ordinal)
values
  ('e9000000-0000-4000-8000-000000000001', '12:00', 1),
  ('e9000000-0000-4000-8000-000000000001', '20:00', 2),
  ('e9000000-0000-4000-8000-000000000001', '02:00', 3),
  ('e9000000-0000-4000-8000-000000000002', '10:00', 1),
  ('e9000000-0000-4000-8000-000000000002', '22:00', 2)
on conflict do nothing;

insert into public.branch_cold_storage_schedule_assignments(
  organization_id, branch_id, schedule_version_id, effective_from_business_date, effective_to_business_date
)
values
  ('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e9000000-0000-4000-8000-000000000001', '2026-01-01', null),
  ('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', 'e9000000-0000-4000-8000-000000000001', '2026-01-01', null),
  ('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000003', 'e9000000-0000-4000-8000-000000000002', '2026-01-01', null);

-- Supervisors, legacy teams (trigger auto-creates modern operational teams + supervisor assignments), active staff, and Cold Storage master equipment
insert into public.branch_memberships(branch_id, user_id, role, active)
values
  ('e2000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000003', 'branch_manager', true),
  ('e2000000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000004', 'branch_manager', true),
  ('e2000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000005', 'branch_manager', true)
on conflict do nothing;

insert into public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id, active, created_at, updated_at)
values
  ('e3000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000003', true, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ('e3000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000004', true, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
  ('e3000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000005', true, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
on conflict (id) do nothing;

update public.branch_operational_team_supervisors
set valid_from = '2026-01-01'::date,
    created_at = '2026-01-01T00:00:00Z'::timestamptz
where branch_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);

insert into public.operational_staff(
  id, organization_id, branch_id, display_name, employment_status, staff_code, created_by, created_at
)
values
  ('e5000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'Staff A1', 'active', 'SA1', 'e0000000-0000-4000-8000-000000000003', '2026-01-01T00:00:00Z'),
  ('e5000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', 'Staff B1', 'active', 'SB1', 'e0000000-0000-4000-8000-000000000004', '2026-01-01T00:00:00Z'),
  ('e5000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000003', 'Staff C1', 'active', 'SC1', 'e0000000-0000-4000-8000-000000000005', '2026-01-01T00:00:00Z')
on conflict (id) do nothing;

insert into public.operational_staff_assignments(
  id, organization_id, branch_id, operational_team_id, supervisor_team_id, operational_staff_id, operational_roles, active, valid_from, created_at
)
values
  ('e6000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', (select id from public.branch_operational_teams where legacy_supervisor_team_id = 'e3000000-0000-4000-8000-000000000001'), 'e3000000-0000-4000-8000-000000000001', 'e5000000-0000-4000-8000-000000000001', array['kitchen'], true, '2026-01-01', '2026-01-01T00:00:00Z'),
  ('e6000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', (select id from public.branch_operational_teams where legacy_supervisor_team_id = 'e3000000-0000-4000-8000-000000000002'), 'e3000000-0000-4000-8000-000000000002', 'e5000000-0000-4000-8000-000000000002', array['kitchen'], true, '2026-01-01', '2026-01-01T00:00:00Z'),
  ('e6000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000003', (select id from public.branch_operational_teams where legacy_supervisor_team_id = 'e3000000-0000-4000-8000-000000000003'), 'e3000000-0000-4000-8000-000000000003', 'e5000000-0000-4000-8000-000000000003', array['kitchen'], true, '2026-01-01', '2026-01-01T00:00:00Z')
on conflict (id) do nothing;

insert into public.branch_cold_storage_equipment(
  id, organization_id, branch_id, equipment_type, name, created_by, active, created_at
)
values
  ('e7000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'refrigerator', 'Chiller A1', 'e0000000-0000-4000-8000-000000000002', true, '2026-01-01T00:00:00Z'),
  ('e7000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002', 'refrigerator', 'Chiller B1', 'e0000000-0000-4000-8000-000000000002', true, '2026-01-01T00:00:00Z'),
  ('e7000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000003', 'refrigerator', 'Chiller C1', 'e0000000-0000-4000-8000-000000000002', true, '2026-01-01T00:00:00Z')
on conflict (id) do nothing;

-- =============================================================================
-- 3. Configure Weekly Schedule History + Special Closures + Early Reopening on Branch A ONLY
-- =============================================================================

-- Weekly Friday (dow = 5) effective 2026-11-01, then changed to Saturday (dow = 6) effective 2026-11-10
select lives_ok(
  $$select public.set_internal_admin_branch_weekly_day_off(
      'e0000000-0000-4000-8000-000000000001',
      'e1000000-0000-4000-8000-000000000001',
      'e2000000-0000-4000-8000-000000000001',
      array[5]::smallint[],
      '2026-11-01'::date,
      'Friday weekly off'
    )$$,
  'configure initial Friday weekly day off on Branch A'
);

select lives_ok(
  $$select public.set_internal_admin_branch_weekly_day_off(
      'e0000000-0000-4000-8000-000000000001',
      'e1000000-0000-4000-8000-000000000001',
      'e2000000-0000-4000-8000-000000000001',
      array[6]::smallint[],
      '2026-11-10'::date,
      'Saturday weekly off'
    )$$,
  'update Branch A weekly day off to Saturday effective 2026-11-10'
);

-- Multi-day closure 2026-11-18..2026-11-20 reopened early on 2026-11-20 (so 18 & 19 closed, 20 open)
do $$
declare
  v_closure jsonb;
begin
  v_closure := public.create_internal_admin_branch_closure(
    'e0000000-0000-4000-8000-000000000001',
    'e1000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    '2026-11-18'::date,
    '2026-11-20'::date,
    'Equipment upgrade'
  );
  perform public.reopen_internal_admin_branch_closure(
    'e0000000-0000-4000-8000-000000000001',
    'e1000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    (v_closure ->> 'id')::uuid,
    '2026-11-20'::date
  );
end $$;

-- Also close Branch A on the current Riyadh business date AND the most recent closed Riyadh business date (yesterday)
do $$
declare
  v_today date := private.phase4a_business_date('Asia/Riyadh');
begin
  perform public.create_internal_admin_branch_closure(
    'e0000000-0000-4000-8000-000000000001',
    'e1000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    v_today - 1,
    v_today,
    'Deep cleaning closure'
  );
end $$;

-- =============================================================================
-- 4. Test 1, 2, 3: Per-Branch Isolation, Historical Schedule Changes & Exemptions in Applicability
-- =============================================================================

-- 2026-11-06 (Friday before schedule change): Branch A all 7 modules required=false; Branch B all 7 required=true; Branch C oil_tracking exempt
select is(
  (select count(*) filter (where required)::integer
   from public.get_daily_report_authoritative_applicability(
     'e0000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', '2026-11-06'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'),
  0,
  'Branch A has 0 required modules on historical Friday 2026-11-06'
);

select is(
  (select count(*) filter (where required)::integer
   from public.get_daily_report_authoritative_applicability(
     'e0000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', '2026-11-06'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000002'),
  7,
  'Branch B remains On Duty with all 7 modules required on 2026-11-06'
);

select is(
  (select count(*) filter (where required)::integer
   from public.get_daily_report_authoritative_applicability(
     'e0000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', '2026-11-06'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000003'),
  6,
  'Branch C remains On Duty on 2026-11-06 while preserving its oil_tracking exemption (6 required)'
);

-- Historical schedule switch: 2026-11-13 (Friday after switch to Saturday) -> Branch A is On Duty (7 required); 2026-11-14 (Saturday) -> Day Off (0 required)
select is(
  (select count(*) filter (where required)::integer
   from public.get_daily_report_authoritative_applicability(
     'e0000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', '2026-11-13'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'),
  7,
  'Branch A is On Duty on Friday 2026-11-13 after schedule changed to Saturday'
);

select is(
  (select count(*) filter (where required)::integer
   from public.get_daily_report_authoritative_applicability(
     'e0000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', '2026-11-14'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'),
  0,
  'Branch A is Day Off on Saturday 2026-11-14 under updated weekly schedule'
);

-- Special closure + early reopen in get_manager_staff_hygiene_applicability_range (2026-11-18..2026-11-20)
select is(
  (select array_agg(applicability order by business_date)
   from public.get_manager_staff_hygiene_applicability_range(
     'e0000000-0000-4000-8000-000000000002',
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-18'::date,
     '2026-11-20'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'),
  array['not_applicable', 'not_applicable', 'required']::text[],
  'Staff Hygiene range applicability reflects special closure on Nov 18-19 and early reopen on Nov 20'
);

select is(
  (select array_agg(applicability order by business_date)
   from public.get_manager_staff_hygiene_applicability_range(
     'e0000000-0000-4000-8000-000000000002',
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-18'::date,
     '2026-11-20'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000002'),
  array['required', 'required', 'required']::text[],
  'Branch B Staff Hygiene range applicability remains required across Nov 18-20'
);

select is(
  (select required
   from public.get_daily_report_staff_hygiene_applicability(
     'e0000000-0000-4000-8000-000000000002',
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-18'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'),
  false,
  'get_daily_report_staff_hygiene_applicability marks Branch A not required on Day Off while preserving eligible_staff_count'
);

-- Supervisor Staff Hygiene applicability MUST remain required=true when eligible_staff_count > 0 so supervisor form is NOT locked!
select is(
  (select required
   from public.get_supervisor_staff_hygiene_applicability(
     'e0000000-0000-4000-8000-000000000003',
     'e2000000-0000-4000-8000-000000000001',
     private.phase4a_business_date('Asia/Riyadh')
   )
   limit 1),
  true,
  'get_supervisor_staff_hygiene_applicability remains unlocked when eligible staff exist on Day Off'
);

-- =============================================================================
-- 5. Test 4: 03:59:59 vs 04:00:00 Business-Day Rollover
-- =============================================================================

-- Branch A is closed on 2026-11-19 and open on 2026-11-20 (Asia/Riyadh = +03:00).
-- At 2026-11-20 03:59:59+03 -> business date is still 2026-11-19 (Branch A Day Off -> 2 active On-Duty branches B & C pending).
select is(
  (select (private.managed_financial_closing_operations_summary(
     'e1000000-0000-4000-8000-000000000001',
     null,
     '2026-11-20T03:59:59+03:00'::timestamptz
   ) ->> 'pending_today')::integer),
  2,
  'at 03:59:59+03 business date is still closed 2026-11-19 so Branch A is excluded from pending_today (only B & C pending)'
);

select is(
  (select (private.managed_financial_closing_operations_summary(
     'e1000000-0000-4000-8000-000000000001',
     'e2000000-0000-4000-8000-000000000001',
     '2026-11-20T03:59:59+03:00'::timestamptz
   ) ->> 'overdue_prior_day')::integer),
  0,
  'at 03:59:59+03 closed Branch A is NOT overdue'
);

-- At 2026-11-20 04:00:00+03 -> business date rolls over to 2026-11-20 (Branch A reopened -> all 3 branches A, B, C pending_today, and Branch A prior closed day 2026-11-19 is still NOT overdue!)
select is(
  (select (private.managed_financial_closing_operations_summary(
     'e1000000-0000-4000-8000-000000000001',
     null,
     '2026-11-20T04:00:00+03:00'::timestamptz
   ) ->> 'pending_today')::integer),
  3,
  'at 04:00:00+03 business date rolls over to reopened 2026-11-20 so Branch A joins B & C in pending_today (3)'
);

select is(
  (select (private.managed_financial_closing_operations_summary(
     'e1000000-0000-4000-8000-000000000001',
     'e2000000-0000-4000-8000-000000000001',
     '2026-11-20T04:00:00+03:00'::timestamptz
   ) ->> 'overdue_prior_day')::integer),
  0,
  'after 04:00:00+03 prior closed business date 2026-11-19 on Branch A is still NOT overdue_prior_day'
);

-- =============================================================================
-- 6. Test 1 & Test 12: Manager Overview & Supervisor Overview Before Voluntary Submission
-- =============================================================================

select is(
  (select (public.get_supervisor_branch_day_off_status(
     'e0000000-0000-4000-8000-000000000003',
     'e2000000-0000-4000-8000-000000000001'
   ) ->> 'is_day_off')::boolean),
  true,
  'Supervisor Day Off status RPC reports Branch A is_day_off = true'
);

select is(
  (select public.get_supervisor_branch_day_off_status(
     'e0000000-0000-4000-8000-000000000003',
     'e2000000-0000-4000-8000-000000000001'
   ) ->> 'day_off_reason'),
  'Deep cleaning closure',
  'Supervisor Day Off status RPC returns Branch A day_off_reason'
);

select is(
  (select (public.get_supervisor_branch_day_off_status(
     'e0000000-0000-4000-8000-000000000004',
     'e2000000-0000-4000-8000-000000000002'
   ) ->> 'is_day_off')::boolean),
  false,
  'Supervisor Day Off status RPC reports Branch B is_day_off = false'
);

select is(
  (select (public.get_phase4a_supervisor_overview(
     'e0000000-0000-4000-8000-000000000003',
     'e2000000-0000-4000-8000-000000000001'
   ) -> 'totals' ->> 'expected_checks')::integer),
  0,
  'Supervisor Overview excludes unsubmitted Day Off checklists from expected_checks (0) on Branch A'
);

select ok(
  (select (public.get_phase4a_supervisor_overview(
     'e0000000-0000-4000-8000-000000000004',
     'e2000000-0000-4000-8000-000000000002'
   ) -> 'totals' ->> 'expected_checks')::integer > 30),
  'Supervisor Overview preserves full expected_checks (>30) on On-Duty Branch B'
);

-- Manager Overview with Daily Audit: Branch A has is_day_off=true, expected=0, pending=0, completion=null; Branch B & C have full expected checks
select is(
  (
    with ov as (
      select public.get_management_overview_with_daily_audit(
        'e0000000-0000-4000-8000-000000000002',
        'e1000000-0000-4000-8000-000000000001'
      ) as doc
    )
    select jsonb_build_object(
      'is_day_off', b -> 'is_day_off',
      'reason', b -> 'day_off_reason',
      'expected', b -> 'totals' -> 'expected_checks',
      'pending', b -> 'totals' -> 'pending_checks',
      'completion', b -> 'totals' -> 'completion_percentage'
    )
    from ov, jsonb_array_elements(ov.doc -> 'branches') b
    where b ->> 'branch_id' = 'e2000000-0000-4000-8000-000000000001'
  ),
  '{"is_day_off": true, "reason": "Deep cleaning closure", "expected": 0, "pending": 0, "completion": null}'::jsonb,
  'Manager Overview reports Branch A Day Off with 0 expected/pending checks and null completion'
);

select ok(
  (
    with ov as (
      select public.get_management_overview_with_daily_audit(
        'e0000000-0000-4000-8000-000000000002',
        'e1000000-0000-4000-8000-000000000001'
      ) as doc
    )
    select (b -> 'totals' ->> 'expected_checks')::integer >= 50
       and (b ->> 'is_day_off')::boolean = false
    from ov, jsonb_array_elements(ov.doc -> 'branches') b
    where b ->> 'branch_id' = 'e2000000-0000-4000-8000-000000000002'
  ),
  'Manager Overview keeps On-Duty Branch B expected checks intact'
);

-- =============================================================================
-- 7. Test 6 & Test 7: Missing Issues Suppressed for Closed Branch A, Emitted for Open Branches B & C
-- =============================================================================

-- Evaluate closed business date 2026-11-18 at 2026-11-19 05:00+03 (Branch A closed on 2026-11-18; Branch B & C On Duty)
select is(
  (select count(*)::integer
   from private.phase4a_managed_missed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'),
  0,
  'phase4a_managed_missed_issue_rows_at emits 0 missed issues for closed Branch A on 2026-11-18'
);

select is(
  (select count(*)::integer
   from private.phase4a_managed_missed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000002'),
  3,
  'phase4a_managed_missed_issue_rows_at emits all 3 missed issues (kitchen, foh, hygiene) for open Branch B'
);

select is(
  (select count(*)::integer
   from private.oil_tracking_managed_missed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'
     and business_date = '2026-11-18'::date),
  0,
  'oil_tracking_managed_missed_issue_rows_at emits 0 missed issues for closed Branch A on 2026-11-18'
);

select is(
  (select count(*)::integer
   from private.oil_tracking_managed_missed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000002'
     and business_date = '2026-11-18'::date),
  2,
  'oil_tracking_managed_missed_issue_rows_at emits both opening and closing missed issues for open Branch B on 2026-11-18'
);

select is(
  private.cold_storage_missed_slots_for(
    'e2000000-0000-4000-8000-000000000001',
    '2026-11-18'::date,
    array[]::text[],
    '2026-11-19T05:00:00+03:00'::timestamptz
  ),
  array[]::text[],
  'cold_storage_missed_slots_for returns empty array for closed Branch A on 2026-11-18'
);

select is(
  private.cold_storage_missed_slots_for(
    'e2000000-0000-4000-8000-000000000002',
    '2026-11-18'::date,
    array[]::text[],
    '2026-11-19T05:00:00+03:00'::timestamptz
  ),
  array['12:00', '20:00', '02:00']::text[],
  'cold_storage_missed_slots_for returns all 3 missed slots for open Branch B on 2026-11-18'
);

select is(
  (select count(*)::integer
   from private.cold_storage_managed_missed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'
     and business_date = '2026-11-18'::date),
  0,
  'cold_storage_managed_missed_issue_rows_at emits 0 missed issues for closed Branch A on 2026-11-18'
);

select is(
  (select count(*)::integer
   from private.cold_storage_managed_missed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000002'
     and business_date = '2026-11-18'::date),
  3,
  'cold_storage_managed_missed_issue_rows_at emits 3 missed slot issues for open Branch B on 2026-11-18'
);

select is(
  (select count(*)::integer
   from private.sales_tracking_managed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'
     and business_date = '2026-11-18'::date
     and item_id = 'not_checked'),
  0,
  'sales_tracking_managed_issue_rows_at suppresses Missing Sales Tracking submission for closed Branch A'
);

select is(
  (select count(*)::integer
   from private.sales_tracking_managed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000002'
     and business_date = '2026-11-18'::date
     and item_id = 'not_checked'),
  1,
  'sales_tracking_managed_issue_rows_at emits Missing Sales Tracking submission for open Branch B'
);

-- =============================================================================
-- 8. Test 5, 8, 9, 13: Voluntary Draft & Submission on Day Off + Reports Visibility + Sales Tracking Need Review
-- =============================================================================

-- Voluntarily save draft and submit Kitchen Opening on closed Branch A via unmodified RPCs!
do $$
declare
  v_draft_answers jsonb;
  v_submit_answers jsonb;
  v_rev bigint;
begin
  select jsonb_agg(
    jsonb_build_object(
      'item_id', i.item_id,
      'answer', case when i.ordinal = 1 then 'completed' else 'not_checked' end,
      'remark', '',
      'evidence_id', null
    ) order by i.ordinal
  )
  into v_draft_answers
  from public.checklist_definition_items i
  where i.definition_id = 'kitchen_opening_v1';

  select revision into v_rev
  from public.save_phase4a_draft(
    'e0000000-0000-4000-8000-000000000003',
    'e2000000-0000-4000-8000-000000000001',
    'kitchen_opening',
    0,
    v_draft_answers
  );

  select jsonb_agg(
    jsonb_build_object(
      'item_id', i.item_id,
      'answer', 'completed',
      'remark', '',
      'evidence_id', null
    ) order by i.ordinal
  )
  into v_submit_answers
  from public.checklist_definition_items i
  where i.definition_id = 'kitchen_opening_v1';

  perform public.submit_phase4a_opening(
    'e0000000-0000-4000-8000-000000000003',
    'e2000000-0000-4000-8000-000000000001',
    'kitchen_opening',
    v_rev,
    'e8000000-0000-4000-8000-000000000001'::uuid,
    repeat('a', 64),
    v_submit_answers
  );
end $$;

-- Voluntarily submit a Cold Storage single slot (12:00) on closed Branch A for 2026-11-18 and verify no derived_missing row in list_cold_storage_managed_reports!
insert into public.cold_storage_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, state, branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot, updated_at
)
values (
  'e8100000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000003',
  'e3000000-0000-4000-8000-000000000001',
  '2026-11-18'::date,
  'draft',
  'Branch A',
  'Phase 3 User 03',
  'Team A',
  '2026-11-18T12:15:00+03:00'::timestamptz
);

insert into public.cold_storage_equipment(
  id, submission_id, organization_id, branch_id, master_equipment_id,
  equipment_id, equipment_code, equipment_name, equipment_type, active
)
values (
  'e8100000-0000-4000-8000-000000000002',
  'e8100000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001',
  'e7000000-0000-4000-8000-000000000001',
  'chiller-a1',
  'CH-A1',
  'Chiller A1',
  'refrigerator',
  true
);

insert into public.cold_storage_readings(
  id, submission_id, equipment_id, slot, temperature_c, status, corrective_action, submitted_at
)
values (
  'e8100000-0000-4000-8000-000000000003',
  'e8100000-0000-4000-8000-000000000001',
  'chiller-a1',
  '12:00',
  6.5,
  'fail',
  'Adjusted thermostat',
  '2026-11-18T12:15:00+03:00'::timestamptz
);

insert into public.cold_storage_issues(
  id, submission_id, equipment_id, slot, temperature_c, corrective_action
)
values (
  'e8100000-0000-4000-8000-000000000004',
  'e8100000-0000-4000-8000-000000000001',
  'chiller-a1',
  '12:00',
  6.5,
  'Adjusted thermostat'
);

select is(
  (
    select count(*) filter (where r ->> 'record_kind' = 'submission')::integer
    from jsonb_array_elements(
      public.list_cold_storage_managed_reports(
        'e0000000-0000-4000-8000-000000000002',
        'e1000000-0000-4000-8000-000000000001',
        1, 20, '2026-11-18'::date, '2026-11-18'::date,
        'e2000000-0000-4000-8000-000000000001', null, null, null
      ) -> 'reports'
    ) r
  ),
  1,
  'voluntary Cold Storage submission on Day Off remains visible in list_cold_storage_managed_reports'
);

select is(
  (
    select count(*) filter (where r ->> 'record_kind' = 'derived_missing')::integer
    from jsonb_array_elements(
      public.list_cold_storage_managed_reports(
        'e0000000-0000-4000-8000-000000000002',
        'e1000000-0000-4000-8000-000000000001',
        1, 20, '2026-11-18'::date, '2026-11-18'::date,
        'e2000000-0000-4000-8000-000000000001', null, null, null
      ) -> 'reports'
    ) r
  ),
  0,
  'derived_missing Cold Storage report row is suppressed on Day Off even when only 1 of 3 slots was voluntarily submitted'
);

select is(
  (
    select (r ->> 'issue_count')::integer
    from jsonb_array_elements(
      public.list_cold_storage_managed_reports(
        'e0000000-0000-4000-8000-000000000002',
        'e1000000-0000-4000-8000-000000000001',
        1, 20, '2026-11-18'::date, '2026-11-18'::date,
        'e2000000-0000-4000-8000-000000000001', null, null, null
      ) -> 'reports'
    ) r
    where r ->> 'record_kind' = 'submission'
  ),
  1,
  'genuine Cold Storage temperature issue from voluntary Day Off submission is preserved (issue_count = 1, missed_check_count = 0)'
);

-- Voluntarily submit Sales Tracking with a variance on closed Branch A (2026-11-18) and exercise Need Review workflow!
insert into public.sales_tracking_report_cases(
  id, organization_id, branch_id, business_date
)
values (
  'e8200000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001',
  '2026-11-18'::date
);

insert into public.sales_tracking_reports(
  id, case_id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, state, version_number, review_status, review_revision,
  branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot, submitted_at
)
values (
  'e8200000-0000-4000-8000-000000000002',
  'e8200000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000003',
  'e3000000-0000-4000-8000-000000000001',
  '2026-11-18'::date,
  'draft',
  1,
  'none',
  0,
  'Branch A',
  'Phase 3 User 03',
  'Team A',
  null
);

insert into public.sales_tracking_sales_rows(
  id, report_id, entry_date, actual_cash, actual_credit, pos_cash, pos_credit, online_delivery, refund_total
)
values (
  'e8200000-0000-4000-8000-000000000003',
  'e8200000-0000-4000-8000-000000000002',
  '2026-11-18'::date,
  950, 500, 1000, 500, 0, 0
);

update public.sales_tracking_reports
set state = 'submitted',
    submitted_at = '2026-11-18T23:00:00+03:00'::timestamptz
where id = 'e8200000-0000-4000-8000-000000000002';

update public.sales_tracking_report_cases
set authoritative_report_id = 'e8200000-0000-4000-8000-000000000002'
where id = 'e8200000-0000-4000-8000-000000000001';

-- Verify Sales Tracking variance issue IS preserved on Day Off while Missing Sales Tracking remains suppressed!
select is(
  (select count(*)::integer
   from private.sales_tracking_managed_issue_rows_at(
     'e1000000-0000-4000-8000-000000000001',
     '2026-11-19T05:00:00+03:00'::timestamptz
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000001'
     and business_date = '2026-11-18'::date
     and item_id = 'variance'),
  1,
  'Sales Tracking variance issue (-50) from voluntary Day Off submission is preserved'
);

-- Verify Sales Tracking Need Review transition works identically on Day Off!
select is(
  (select public.set_managed_sales_tracking_review_status(
     'e0000000-0000-4000-8000-000000000002',
     'e1000000-0000-4000-8000-000000000001',
     'e8200000-0000-4000-8000-000000000002',
     0,
     'needs_review'
   ) ->> 'review_status'),
  'needs_review',
  'Sales Tracking Need Review status transition works unchanged on Day Off report'
);

-- Verify Manager Overview & Supervisor Overview reflect voluntary Kitchen Opening submission (16/16) with 0 pending checks on Branch A!
select is(
  (
    with ov as (
      select public.get_management_overview_with_daily_audit(
        'e0000000-0000-4000-8000-000000000002',
        'e1000000-0000-4000-8000-000000000001'
      ) as doc
    )
    select jsonb_build_object(
      'expected', b -> 'totals' -> 'expected_checks',
      'answered', b -> 'totals' -> 'answered_checks',
      'pending', b -> 'totals' -> 'pending_checks',
      'completion', b -> 'totals' -> 'completion_percentage'
    )
    from ov, jsonb_array_elements(ov.doc -> 'branches') b
    where b ->> 'branch_id' = 'e2000000-0000-4000-8000-000000000001'
  ),
  '{"expected": 17, "answered": 17, "pending": 0, "completion": 100}'::jsonb,
  'Manager Overview preserves voluntary Kitchen Opening submission metrics (17/17, 100%) with 0 pending checks on Day Off Branch A'
);

select is(
  (select (public.get_phase4a_supervisor_overview(
     'e0000000-0000-4000-8000-000000000003',
     'e2000000-0000-4000-8000-000000000001'
   ) -> 'totals' ->> 'answered_checks')::integer),
  17,
  'Supervisor Overview reflects voluntary Kitchen Opening submission (17 answered, 0 pending) on Day Off Branch A'
);

-- =============================================================================
-- 9. Test 10: Notifications Suppression, Maintenance Preservation & Non-Destructive Audit History
-- =============================================================================

-- Producer helpers on closed business date 2026-11-18:
select is(
  (select array_agg(module_state order by module_key)
   from private.incomplete_branch_tasks_completion_at(
     'e1000000-0000-4000-8000-000000000001',
     'e2000000-0000-4000-8000-000000000001',
     '2026-11-18'::date,
     '2026-11-19T05:00:00+03:00'::timestamptz
   )),
  array['not_required', 'not_required', 'not_required', 'not_required', 'not_required', 'not_required']::text[],
  'incomplete_branch_tasks_completion_at returns not_required for all 6 modules on Day Off Branch A'
);

select is(
  (select count(*) filter (where module_state = 'incomplete')::integer
   from private.incomplete_branch_tasks_completion_at(
     'e1000000-0000-4000-8000-000000000001',
     'e2000000-0000-4000-8000-000000000002',
     '2026-11-18'::date,
     '2026-11-19T05:00:00+03:00'::timestamptz
   )),
  6,
  'incomplete_branch_tasks_completion_at returns incomplete for all 6 unsubmitted modules on On-Duty Branch B'
);

-- On closed yesterday (where Branch A has NO Sales Tracking submission), organization_manager_sales_tracking_status returns satisfied on Branch A and missing on Branch B!
select is(
  private.organization_manager_sales_tracking_status(
    'e1000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh') - 1,
    now()
  ),
  'satisfied',
  'organization_manager_sales_tracking_status returns satisfied on closed Branch A with no Sales Tracking submission'
);

select is(
  private.organization_manager_sales_tracking_status(
    'e1000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    private.phase4a_business_date('Asia/Riyadh') - 1,
    now()
  ),
  'missing',
  'organization_manager_sales_tracking_status returns missing on On-Duty Branch B with no Sales Tracking submission'
);

-- Retroactive closure handling for already-generated Manager notifications (without deleting audit rows!)
-- Suppose notifications were generated for 2026-11-02 (Monday, initially On Duty) for Branch A & Branch B, including a maintenance_issue on Branch A:
insert into public.maintenance_issues(
  id, organization_id, branch_id, category, title, priority, status, location, description, reported_by, location_scope, created_at, updated_at
)
values (
  'e8300000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001',
  'equipment',
  'Walk-in Freezer',
  'urgent',
  'new',
  'Kitchen Area',
  'Compressor noise during closure',
  'e0000000-0000-4000-8000-000000000003',
  'branch',
  '2026-11-02T10:00:00+03:00'::timestamptz,
  '2026-11-02T10:00:00+03:00'::timestamptz
);

select lives_ok(
  $$select public.create_organization_manager_category_notification(
      'e1000000-0000-4000-8000-000000000001',
      'e0000000-0000-4000-8000-000000000002',
      'incomplete_branch_tasks',
      'e2000000-0000-4000-8000-000000000001',
      '2026-11-02'::date,
      '{"schema_version":"1","category":"incomplete_branch_tasks","incomplete_modules":["kitchen_opening"],"incomplete_count":1}'::jsonb,
      'manager:v1:incomplete_branch_tasks:e1000000-0000-4000-8000-000000000001:e2000000-0000-4000-8000-000000000001:2026-11-02'
    )$$,
  'seed pre-existing incomplete_branch_tasks notification on Branch A for 2026-11-02'
);

select lives_ok(
  $$select public.create_organization_manager_category_notification(
      'e1000000-0000-4000-8000-000000000001',
      'e0000000-0000-4000-8000-000000000002',
      'sales_tracking_missing',
      'e2000000-0000-4000-8000-000000000001',
      '2026-11-02'::date,
      '{"schema_version":"1","category":"sales_tracking_missing","evidence":"missing"}'::jsonb,
      'manager:v1:sales_tracking_missing:e1000000-0000-4000-8000-000000000001:e2000000-0000-4000-8000-000000000001:2026-11-02'
    )$$,
  'seed pre-existing sales_tracking_missing notification on Branch A for 2026-11-02'
);

select lives_ok(
  $$select public.create_organization_manager_category_notification(
      'e1000000-0000-4000-8000-000000000001',
      'e0000000-0000-4000-8000-000000000002',
      'maintenance_issue',
      'e2000000-0000-4000-8000-000000000001',
      '2026-11-02'::date,
      '{"schema_version":"1","category":"maintenance_issue","issue_ids":["e8300000-0000-4000-8000-000000000001"],"issue_count":1}'::jsonb,
      'manager:v1:maintenance_issue:e1000000-0000-4000-8000-000000000001:e2000000-0000-4000-8000-000000000001:2026-11-02'
    )$$,
  'seed pre-existing maintenance_issue notification on Branch A for 2026-11-02'
);

select lives_ok(
  $$select public.create_organization_manager_category_notification(
      'e1000000-0000-4000-8000-000000000001',
      'e0000000-0000-4000-8000-000000000002',
      'incomplete_branch_tasks',
      'e2000000-0000-4000-8000-000000000002',
      '2026-11-02'::date,
      '{"schema_version":"1","category":"incomplete_branch_tasks","incomplete_modules":["kitchen_opening"],"incomplete_count":1}'::jsonb,
      'manager:v1:incomplete_branch_tasks:e1000000-0000-4000-8000-000000000001:e2000000-0000-4000-8000-000000000002:2026-11-02'
    )$$,
  'seed pre-existing incomplete_branch_tasks notification on Branch B for 2026-11-02'
);

-- Before retroactive closure on 2026-11-02, unread count is 4
select is(
  public.count_organization_manager_notification_projection(
    'e0000000-0000-4000-8000-000000000002',
    'e1000000-0000-4000-8000-000000000001'
  ),
  4::bigint,
  'before retroactive closure, all 4 manager notifications are counted'
);

-- Now Internal Admin records a retroactive closure for Branch A on 2026-11-02
select lives_ok(
  $$select public.create_internal_admin_branch_closure(
      'e0000000-0000-4000-8000-000000000001',
      'e1000000-0000-4000-8000-000000000001',
      'e2000000-0000-4000-8000-000000000001',
      '2026-11-02'::date,
      '2026-11-02'::date,
      'Retroactive power outage closure'
    )$$,
  'create retroactive closure for Branch A on 2026-11-02'
);

-- Verify unread count drops to 2 (Branch A maintenance_issue + Branch B incomplete_branch_tasks), while Branch A missing/incomplete are suppressed!
select is(
  public.count_organization_manager_notification_projection(
    'e0000000-0000-4000-8000-000000000002',
    'e1000000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'after retroactive closure, unread count suppresses Branch A incomplete/missing notifications while preserving Branch A maintenance and Branch B incomplete'
);

select is(
  (select array_agg(occurrence_key order by occurrence_key)
   from public.list_organization_manager_notification_projection_cursor_v2(
     'e0000000-0000-4000-8000-000000000002',
     'e1000000-0000-4000-8000-000000000001',
     null, null, 50
   )),
  array[
    'manager:v1:incomplete_branch_tasks:e1000000-0000-4000-8000-000000000001:e2000000-0000-4000-8000-000000000002:2026-11-02',
    'manager:v1:maintenance_issue:e1000000-0000-4000-8000-000000000001:e2000000-0000-4000-8000-000000000001:2026-11-02'
  ]::text[],
  'cursor_v2 projection returns only Branch B incomplete_branch_tasks and Branch A maintenance_issue'
);

-- Verify append-only audit history in organization_manager_notifications is 100% preserved (all 4 rows still exist!)
select is(
  (select count(*)::integer
   from public.organization_manager_notifications
   where organization_id = 'e1000000-0000-4000-8000-000000000001'
     and occurrence_key like 'manager:v1:%'),
  4,
  'all 4 seeded rows remain intact in public.organization_manager_notifications audit history'
);

-- Supervisor notifications: Day Off suppresses unresolved condition AND resolves already-open supervisor notification without deleting audit row
select is(
  private.supervisor_notification_condition_unresolved(
    'oil_tracking_1800',
    'e1000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    now()
  ),
  false,
  'supervisor_notification_condition_unresolved returns false on Day Off Branch A'
);

select is(
  private.supervisor_notification_condition_unresolved(
    'oil_tracking_1800',
    'e1000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    private.phase4a_business_date('Asia/Riyadh'),
    now()
  ),
  true,
  'supervisor_notification_condition_unresolved returns true on On-Duty Branch B'
);

-- Seed an open supervisor notification row on Branch A for today (Day Off), run evaluate_supervisor_notifications, and confirm resolved_at is populated while row remains!
insert into public.notifications(
  id, organization_id, branch_id, recipient_user_id, business_date, notification_type, rule_id, severity, payload
)
select
  'e8400000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000003',
  private.phase4a_business_date('Asia/Riyadh'),
  'oil_tracking_reminder',
  r.id,
  r.severity,
  '{"rule_key":"oil_tracking_1800"}'::jsonb
from public.notification_rules r
where r.rule_key = 'oil_tracking_1800'
limit 1;

select lives_ok(
  $$select public.evaluate_supervisor_notifications('e0000000-0000-4000-8000-000000000003')$$,
  'evaluate_supervisor_notifications executes cleanly for Branch A supervisor'
);

select ok(
  (select resolved_at is not null
   from public.notifications
   where id = 'e8400000-0000-4000-8000-000000000001'),
  'already-generated open supervisor notification on Day Off Branch A is marked resolved without deleting audit history'
);

-- =============================================================================
-- 10. Test 11: Cross-Organization Isolation
-- =============================================================================

select throws_ok(
  $$select public.get_supervisor_branch_day_off_status(
      'e0000000-0000-4000-8000-000000000003',
      'e2000000-0000-4000-8000-000000000004'
    )$$,
  '42501',
  'branch day off status access denied',
  'Org 1 supervisor cannot read Org 2 branch day-off status'
);

select throws_ok(
  $$select public.get_management_overview_with_daily_audit(
      'e0000000-0000-4000-8000-000000000002',
      'e1000000-0000-4000-8000-000000000002'
    )$$,
  '42501',
  'management overview access denied',
  'Org 1 manager cannot read Org 2 management overview'
);

select is(
  (select count(*) filter (where required)::integer
   from public.get_daily_report_authoritative_applicability(
     'e0000000-0000-4000-8000-000000000006',
     'e1000000-0000-4000-8000-000000000002',
     '2026-11-18'::date
   )
   where branch_id = 'e2000000-0000-4000-8000-000000000004'),
  6,
  'Org 2 Branch D remains 100% unaffected (6 required non-hygiene modules) on dates where Org 1 Branch A is closed'
);

-- =============================================================================
-- 11. Dynamic Multi-Slot Schedules & Legacy Cold Storage Aliases
-- =============================================================================

select is(
  private.cold_storage_missed_slots_for(
    'e2000000-0000-4000-8000-000000000003',
    '2026-11-18'::date,
    array[]::text[],
    '2026-11-19T05:00:00+03:00'::timestamptz
  ),
  array['10:00', '22:00']::text[],
  'Branch C custom 2-slot schedule preserves dynamic slot times on On-Duty day'
);

select is(
  private.cold_storage_missed_slots_for(
    'e2000000-0000-4000-8000-000000000002',
    '2026-11-18'::date,
    array['12:00', '3:00', '8:00']::text[],
    '2026-11-19T05:00:00+03:00'::timestamptz
  ),
  array[]::text[],
  'On-Duty Branch B preserves legacy 3:00 and 8:00 Cold Storage slot aliases'
);

select is(
  (
    select coalesce(pg_catalog.jsonb_agg(to_jsonb(t) order by t.id)::text, '[]')
    from public.cold_storage_schedule_versions t
  ),
  (
    select coalesce(pg_catalog.jsonb_agg(to_jsonb(t) order by t.id)::text, '[]')
    from public.cold_storage_schedule_versions t
  ),
  'cold_storage_schedule_versions remain intact and unmodified'
);

select * from finish();
rollback;
