begin;

select plan(18);

-- 1. Security & privilege assertions on list_managed_people_directory_v3
select ok(
  to_regprocedure('public.list_managed_people_directory_v3(uuid, uuid, uuid, date, text, text)') is not null,
  'list_managed_people_directory_v3 exists'
);

select ok(
  (
    select prosecdef and array_to_string(proconfig, ',') like '%search_path=%'
    from pg_proc
    where oid = 'public.list_managed_people_directory_v3(uuid, uuid, uuid, date, text, text)'::regprocedure
  ),
  'list_managed_people_directory_v3 enforces SECURITY DEFINER and empty search_path'
);

select ok(
  not has_function_privilege('anon', 'public.list_managed_people_directory_v3(uuid, uuid, uuid, date, text, text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.list_managed_people_directory_v3(uuid, uuid, uuid, date, text, text)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.list_managed_people_directory_v3(uuid, uuid, uuid, date, text, text)', 'EXECUTE'),
  'list_managed_people_directory_v3 is service_role-only'
);

-- 2. Fixture setup & deterministic before-snapshots
create temp table _hc_snapshots (
  phase text not null,
  staff_snapshot jsonb not null,
  sup_snapshot jsonb not null
) on commit drop;

do $$
declare
  v_org1 uuid := 'a1111111-1111-4111-8111-111111111111';
  v_org2 uuid := 'a2222222-2222-4222-8222-222222222222';
  v_b1 uuid := 'b1111111-1111-4111-8111-111111111111';
  v_b2 uuid := 'b2222222-2222-4222-8222-222222222222';
  v_b_org2 uuid := 'b3333333-3333-4333-8333-333333333333';
  v_mgr1 uuid := 'c1111111-1111-4111-8111-111111111111';
  v_mgr2 uuid := 'c2222222-2222-4222-8222-222222222222';
  v_sup_multi uuid := 'd1111111-1111-4111-8111-111111111111';
  v_sup_unsaved uuid := 'd2222222-2222-4222-8222-222222222222';
  v_sup_disabled uuid := 'd3333333-3333-4333-8333-333333333333';
  v_lt1 uuid := 'e1111111-1111-4111-8111-111111111111';
  v_lt2 uuid := 'e2222222-2222-4222-8222-222222222222';
  v_lt3 uuid := 'e3333333-3333-4333-8333-333333333333';
  v_t1 uuid;
  v_t2 uuid;
  v_t3 uuid;
  v_staff_id uuid;
begin
  insert into public.organizations(id, name, slug, active) values
    (v_org1, 'Mgr HC Org 1', 'mgr-hc-1', true),
    (v_org2, 'Mgr HC Org 2', 'mgr-hc-2', true);

  insert into public.branches(id, organization_id, name, name_ar, code, timezone, active) values
    (v_b1, v_org1, 'Olaya Branch', 'فرع العليا', 'MHC1', 'Asia/Riyadh', true),
    (v_b2, v_org1, 'Malaz Branch', 'فرع الملز', 'MHC2', 'Asia/Riyadh', true),
    (v_b_org2, v_org2, 'Org2 Branch', 'فرع آخر', 'MHC3', 'Asia/Riyadh', true);

  insert into auth.users(id, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, aud, role) values
    (v_mgr1, 'mgr1-hc@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_mgr2, 'mgr2-hc@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_sup_multi, 'supm-hc@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_sup_unsaved, 'supu-hc@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_sup_disabled, 'supd-hc@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated');

  insert into public.profiles(id, full_name, full_name_ar, person_code, must_change_password, disabled_at) values
    (v_mgr1, 'Manager 1', 'مدير 1', null, false, null),
    (v_mgr2, 'Manager 2', 'مدير 2', null, false, null),
    (v_sup_multi, 'Multi Sup', 'مشرف متعدد', 'SUP-M1', false, null),
    (v_sup_unsaved, 'Unsaved Sup', 'مشرف جديد', 'SUP-U1', false, null),
    (v_sup_disabled, 'Disabled Sup', 'مشرف معطل', 'SUP-D1', false, null)
  on conflict (id) do update set
    full_name = excluded.full_name,
    full_name_ar = excluded.full_name_ar,
    person_code = excluded.person_code,
    must_change_password = false,
    disabled_at = null;

  insert into public.organization_memberships(user_id, organization_id, role, active) values
    (v_mgr1, v_org1, 'organization_manager', true),
    (v_mgr2, v_org2, 'organization_manager', true);

  insert into public.branch_memberships(user_id, branch_id, role, active) values
    (v_sup_multi, v_b1, 'branch_manager', true),
    (v_sup_multi, v_b2, 'branch_manager', true),
    (v_sup_unsaved, v_b1, 'branch_manager', true),
    (v_sup_disabled, v_b2, 'branch_manager', true);

  -- Multi-branch & multi-team assignments:
  -- sup_multi is primary on b1/t1, backup on b2/t2; sup_unsaved is backup on b1/t1; sup_disabled is primary on b2/t2 (then disabled)
  insert into public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id, active) values
    (v_lt1, v_org1, v_b1, v_sup_multi, true),
    (v_lt2, v_org1, v_b2, v_sup_disabled, true);

  select id into strict v_t1 from public.branch_operational_teams where legacy_supervisor_team_id = v_lt1;
  select id into strict v_t2 from public.branch_operational_teams where legacy_supervisor_team_id = v_lt2;

  insert into public.branch_operational_team_supervisors(
    organization_id, branch_id, operational_team_id, supervisor_user_id, assignment_role, valid_from, active, created_by
  ) values
    (v_org1, v_b1, v_t1, v_sup_unsaved, 'backup', current_date, true, v_mgr1),
    (v_org1, v_b2, v_t2, v_sup_multi, 'backup', current_date, true, v_mgr1)
  on conflict do nothing;

  -- Save health cards for sup_multi and sup_disabled, then disable sup_disabled
  perform public.upsert_supervisor_health_card(
    v_sup_multi, v_b1, v_sup_multi,
    '{"status":"passed","certificate_number":"SUP-PASS-1","place_of_issue":"Riyadh","date_issue":"2026-01-15","expiry_date":"2027-01-15","occupation":"Supervisor","company":"Mgr Co","notes":"Preserved"}'::jsonb
  );
  perform public.upsert_supervisor_health_card(
    v_sup_disabled, v_b2, v_sup_disabled,
    '{"status":"pending","certificate_number":"SUP-DIS-1"}'::jsonb
  );
  update public.profiles set disabled_at = now() where id = v_sup_disabled;

  -- Create 1 employee & employee health card on b1/t1
  select staff_id into v_staff_id from public.create_operational_team_staff(
    actor_user_id => v_sup_multi,
    target_branch_id => v_b1,
    target_operational_team_id => v_t1,
    new_display_name => 'Staff Preserved',
    new_staff_code => 'EMP-P1',
    new_company_name => 'Mgr Co',
    new_country_code => 'SA',
    new_iqama_number => null,
    new_iqama_expiry_date => null,
    new_phone_number => null,
    new_email => null,
    new_operational_roles => array['kitchen']
  );
  perform public.upsert_operational_staff_health_card(
    v_sup_multi, v_b1,
    jsonb_build_object('operational_staff_id', v_staff_id, 'status', 'failed', 'certificate_number', 'EMP-CERT-P1', 'notes', 'Keep intact')
  );

  -- Capture deterministic before-snapshots
  insert into _hc_snapshots(phase, staff_snapshot, sup_snapshot)
  select
    'before',
    coalesce((select pg_catalog.jsonb_agg(to_jsonb(t) order by t.id) from public.operational_staff_health_cards t), '[]'::jsonb),
    coalesce((select pg_catalog.jsonb_agg(to_jsonb(t) order by t.id) from public.supervisor_health_cards t), '[]'::jsonb);
end $$;

-- 3. Execute v3 & capture after-snapshots
do $$
declare
  v_res jsonb;
begin
  v_res := public.list_managed_people_directory_v3(
    'c1111111-1111-4111-8111-111111111111'::uuid,
    'a1111111-1111-4111-8111-111111111111'::uuid,
    null,
    date_trunc('month', current_date)::date,
    null,
    null
  );
  insert into _hc_snapshots(phase, staff_snapshot, sup_snapshot)
  select
    'after',
    coalesce((select pg_catalog.jsonb_agg(to_jsonb(t) order by t.id) from public.operational_staff_health_cards t), '[]'::jsonb),
    coalesce((select pg_catalog.jsonb_agg(to_jsonb(t) order by t.id) from public.supervisor_health_cards t), '[]'::jsonb);
end $$;

-- 4. Exact JSONB snapshot preservation checks (all columns, IDs, timestamps)
select is(
  (select staff_snapshot from _hc_snapshots where phase = 'after'),
  (select staff_snapshot from _hc_snapshots where phase = 'before'),
  'operational_staff_health_cards exact JSONB snapshot is 100% preserved'
);

select is(
  (select sup_snapshot from _hc_snapshots where phase = 'after'),
  (select sup_snapshot from _hc_snapshots where phase = 'before'),
  'supervisor_health_cards exact JSONB snapshot is 100% preserved'
);

-- 5. v1 & v2 contracts remain unchanged (no supervisor_health_cards key)
select ok(
  not (public.list_managed_people_directory(
    'c1111111-1111-4111-8111-111111111111'::uuid,
    'a1111111-1111-4111-8111-111111111111'::uuid,
    null,
    date_trunc('month', current_date)::date,
    null,
    null
  ) ? 'supervisor_health_cards'),
  'v1 RPC contract unchanged'
);

select ok(
  not (public.list_managed_people_directory_v2(
    'c1111111-1111-4111-8111-111111111111'::uuid,
    'a1111111-1111-4111-8111-111111111111'::uuid,
    null,
    date_trunc('month', current_date)::date,
    null,
    null
  ) ? 'supervisor_health_cards'),
  'v2 RPC contract unchanged'
);

-- 6. v3 supervisor_health_cards behavior checks
select is(
  jsonb_array_length(
    public.list_managed_people_directory_v3(
      'c1111111-1111-4111-8111-111111111111'::uuid,
      'a1111111-1111-4111-8111-111111111111'::uuid,
      null,
      date_trunc('month', current_date)::date,
      null,
      null
    )->'supervisor_health_cards'
  ),
  2,
  'v3 returns 2 deduplicated active supervisors (disabled supervisor excluded)'
);

select is(
  (
    select item->>'status'
    from jsonb_array_elements(
      public.list_managed_people_directory_v3(
        'c1111111-1111-4111-8111-111111111111'::uuid,
        'a1111111-1111-4111-8111-111111111111'::uuid,
        null,
        date_trunc('month', current_date)::date,
        null,
        null
      )->'supervisor_health_cards'
    ) as item
    where item->>'supervisor_user_id' = 'd1111111-1111-4111-8111-111111111111'
  ),
  'passed',
  'v3 returns saved status for multi-branch supervisor'
);

select is(
  (
    select jsonb_array_length(item->'branches')
    from jsonb_array_elements(
      public.list_managed_people_directory_v3(
        'c1111111-1111-4111-8111-111111111111'::uuid,
        'a1111111-1111-4111-8111-111111111111'::uuid,
        null,
        date_trunc('month', current_date)::date,
        null,
        null
      )->'supervisor_health_cards'
    ) as item
    where item->>'supervisor_user_id' = 'd1111111-1111-4111-8111-111111111111'
  ),
  2,
  'v3 aggregates both active branches for multi-branch supervisor without duplicating row'
);

select is(
  (
    select item->>'status'
    from jsonb_array_elements(
      public.list_managed_people_directory_v3(
        'c1111111-1111-4111-8111-111111111111'::uuid,
        'a1111111-1111-4111-8111-111111111111'::uuid,
        null,
        date_trunc('month', current_date)::date,
        null,
        null
      )->'supervisor_health_cards'
    ) as item
    where item->>'supervisor_user_id' = 'd2222222-2222-4222-8222-222222222222'
  ),
  'not_done',
  'v3 defaults unsaved supervisor status to not_done'
);

select is(
  (
    select item->>'assignment_role'
    from jsonb_array_elements(
      public.list_managed_people_directory_v3(
        'c1111111-1111-4111-8111-111111111111'::uuid,
        'a1111111-1111-4111-8111-111111111111'::uuid,
        'b2222222-2222-4222-8222-222222222222'::uuid,
        date_trunc('month', current_date)::date,
        null,
        null
      )->'supervisor_health_cards'
    ) as item
    where item->>'supervisor_user_id' = 'd1111111-1111-4111-8111-111111111111'
  ),
  'backup',
  'v3 branch_filter accurately scopes assignment_role to backup on Branch 2'
);

select is(
  jsonb_array_length(
    public.list_managed_people_directory_v3(
      'c1111111-1111-4111-8111-111111111111'::uuid,
      'a1111111-1111-4111-8111-111111111111'::uuid,
      'b2222222-2222-4222-8222-222222222222'::uuid,
      date_trunc('month', current_date)::date,
      null,
      null
    )->'supervisor_health_cards'
  ),
  1,
  'v3 branch_filter on Branch 2 returns only Branch 2 active supervisor'
);

select is(
  (
    select count(*)::integer from public.supervisor_health_cards
    where supervisor_user_id = 'd3333333-3333-4333-8333-333333333333'
  ),
  1,
  'disabled supervisor stored health card record remains intact'
);

select is(
  jsonb_array_length(
    public.list_managed_people_directory_v3(
      'c1111111-1111-4111-8111-111111111111'::uuid,
      'a1111111-1111-4111-8111-111111111111'::uuid,
      null,
      date_trunc('month', current_date)::date,
      null,
      null
    )->'health_cards'
  ),
  1,
  'existing employee health_cards array remains unchanged'
);

select is(
  (
    public.list_managed_people_directory_v3(
      'c1111111-1111-4111-8111-111111111111'::uuid,
      'a1111111-1111-4111-8111-111111111111'::uuid,
      null,
      date_trunc('month', current_date)::date,
      null,
      null
    )->>'people_total'
  )::integer,
  (
    public.list_managed_people_directory_v2(
      'c1111111-1111-4111-8111-111111111111'::uuid,
      'a1111111-1111-4111-8111-111111111111'::uuid,
      null,
      date_trunc('month', current_date)::date,
      null,
      null
    )->>'people_total'
  )::integer,
  'people_total counter matches v2 unchanged'
);

select throws_ok(
  $$select public.list_managed_people_directory_v3(
    'c2222222-2222-4222-8222-222222222222'::uuid,
    'a1111111-1111-4111-8111-111111111111'::uuid,
    null,
    date_trunc('month', current_date)::date,
    null,
    null
  )$$,
  '42501',
  'people directory access denied',
  'cross-organization v3 access is denied'
);

select is(
  (
    select status from public.upsert_supervisor_health_card(
      'd1111111-1111-4111-8111-111111111111'::uuid,
      'b1111111-1111-4111-8111-111111111111'::uuid,
      'd1111111-1111-4111-8111-111111111111'::uuid,
      '{"status":"done_waiting_id","certificate_number":"SUP-PASS-2"}'::jsonb
    )
  ),
  'done_waiting_id',
  'existing supervisor self-edit workflow remains unchanged'
);

select finish();
rollback;
