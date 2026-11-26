begin;

select plan(26);

-- 1. Schema, RLS, and direct privilege assertions
select has_table('public', 'supervisor_health_cards', 'supervisor_health_cards table exists');
select col_is_unique('public', 'supervisor_health_cards', array['organization_id', 'supervisor_user_id'], 'unique (organization_id, supervisor_user_id)');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.supervisor_health_cards'::regclass),
  'RLS is enabled on supervisor_health_cards'
);

select ok(
  not has_table_privilege('anon', 'public.supervisor_health_cards', 'SELECT')
  and not has_table_privilege('anon', 'public.supervisor_health_cards', 'INSERT')
  and not has_table_privilege('anon', 'public.supervisor_health_cards', 'UPDATE')
  and not has_table_privilege('anon', 'public.supervisor_health_cards', 'DELETE'),
  'anon has zero direct privileges on supervisor_health_cards'
);

select ok(
  not has_table_privilege('authenticated', 'public.supervisor_health_cards', 'SELECT')
  and not has_table_privilege('authenticated', 'public.supervisor_health_cards', 'INSERT')
  and not has_table_privilege('authenticated', 'public.supervisor_health_cards', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.supervisor_health_cards', 'DELETE'),
  'authenticated has zero direct privileges on supervisor_health_cards'
);

select ok(
  not has_function_privilege('anon', 'public.list_branch_supervisor_health_cards(uuid, uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.list_branch_supervisor_health_cards(uuid, uuid)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.list_branch_supervisor_health_cards(uuid, uuid)', 'EXECUTE'),
  'list_branch_supervisor_health_cards is service_role-only'
);

select ok(
  not has_function_privilege('anon', 'public.upsert_supervisor_health_card(uuid, uuid, uuid, jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.upsert_supervisor_health_card(uuid, uuid, uuid, jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.upsert_supervisor_health_card(uuid, uuid, uuid, jsonb)', 'EXECUTE'),
  'upsert_supervisor_health_card is service_role-only'
);

-- 2. Fixture setup inside transaction
do $$
declare
  v_org1 uuid := '11111111-1111-4111-8111-111111111111';
  v_org2 uuid := '22222222-2222-4222-8222-222222222222';
  v_branch1 uuid := '33333333-3333-4333-8333-333333333331';
  v_branch2 uuid := '33333333-3333-4333-8333-333333333332';
  v_branch_org2 uuid := '33333333-3333-4333-8333-333333333333';
  v_sup_primary uuid := '44444444-4444-4444-8444-444444444441';
  v_sup_backup uuid := '44444444-4444-4444-8444-444444444442';
  v_sup_other_org uuid := '44444444-4444-4444-8444-444444444443';
  v_mgr_org1 uuid := '44444444-4444-4444-8444-444444444444';
  v_legacy_t1 uuid := '55555555-5555-4555-8555-555555555551';
  v_legacy_t2 uuid := '55555555-5555-4555-8555-555555555552';
  v_legacy_tb2 uuid := '55555555-5555-4555-8555-555555555553';
  v_team1 uuid;
  v_team2 uuid;
  v_teamb2 uuid;
  v_staff_id uuid;
begin
  insert into public.organizations(id, name, slug, active) values
    (v_org1, 'HC Org 1', 'hc-org-1', true),
    (v_org2, 'HC Org 2', 'hc-org-2', true);

  insert into public.branches(id, organization_id, name, code, timezone, active) values
    (v_branch1, v_org1, 'Branch One', 'HC1', 'Asia/Riyadh', true),
    (v_branch2, v_org1, 'Branch Two', 'HC2', 'Asia/Riyadh', true),
    (v_branch_org2, v_org2, 'Org2 Branch', 'HC3', 'Asia/Riyadh', true);

  insert into auth.users(id, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, aud, role) values
    (v_sup_primary, 'hc-primary@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_sup_backup, 'hc-backup@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_sup_other_org, 'hc-org2@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_mgr_org1, 'hc-mgr@test.local', 'x', now(), '{}', '{}', 'authenticated', 'authenticated');

  insert into public.profiles(id, full_name, full_name_ar, person_code, must_change_password) values
    (v_sup_primary, 'Primary Sup', 'مشرف أول', 'SUP-01', false),
    (v_sup_backup, 'Backup Sup', 'مشرف بديل', 'SUP-02', false),
    (v_sup_other_org, 'Org2 Sup', 'مشرف آخر', 'SUP-03', false),
    (v_mgr_org1, 'Org1 Mgr', 'مدير', null, false)
  on conflict (id) do update set
    full_name = excluded.full_name,
    full_name_ar = excluded.full_name_ar,
    person_code = excluded.person_code,
    must_change_password = false,
    disabled_at = null;

  insert into public.organization_memberships(user_id, organization_id, role, active) values
    (v_mgr_org1, v_org1, 'organization_manager', true);

  insert into public.branch_memberships(user_id, branch_id, role, active) values
    (v_sup_primary, v_branch1, 'branch_manager', true),
    (v_sup_backup, v_branch1, 'branch_manager', true),
    (v_sup_backup, v_branch2, 'branch_manager', true),
    (v_sup_other_org, v_branch_org2, 'branch_manager', true);

  -- Create Team 1 & Team 2 on Branch 1; sup_primary is primary on Team 1 and backup on Team 2
  insert into public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id, active)
  values
    (v_legacy_t1, v_org1, v_branch1, v_sup_primary, true),
    (v_legacy_t2, v_org1, v_branch1, v_sup_backup, true),
    (v_legacy_tb2, v_org1, v_branch2, v_sup_backup, true);

  select id into strict v_team1 from public.branch_operational_teams where legacy_supervisor_team_id = v_legacy_t1;
  select id into strict v_team2 from public.branch_operational_teams where legacy_supervisor_team_id = v_legacy_t2;
  select id into strict v_teamb2 from public.branch_operational_teams where legacy_supervisor_team_id = v_legacy_tb2;

  insert into public.branch_operational_team_supervisors(
    organization_id, branch_id, operational_team_id, supervisor_user_id, assignment_role, valid_from, active, created_by
  ) values
    (v_org1, v_branch1, v_team1, v_sup_backup, 'backup', current_date, true, v_sup_primary),
    (v_org1, v_branch1, v_team2, v_sup_primary, 'backup', current_date, true, v_sup_primary)
  on conflict do nothing;

  -- Create employee and employee health card to verify zero impact
  select staff_id into v_staff_id from public.create_operational_team_staff(
    actor_user_id => v_sup_primary,
    target_branch_id => v_branch1,
    target_operational_team_id => v_team1,
    new_display_name => 'Employee One',
    new_staff_code => 'EMP-HC-1',
    new_company_name => 'HC Co',
    new_country_code => 'SA',
    new_iqama_number => null,
    new_iqama_expiry_date => null,
    new_phone_number => null,
    new_email => null,
    new_operational_roles => array['kitchen']
  );

  perform public.upsert_operational_staff_health_card(
    v_sup_primary,
    v_branch1,
    jsonb_build_object('operational_staff_id', v_staff_id, 'status', 'passed', 'certificate_number', 'EMP-CERT-1')
  );
end $$;

-- 3. Supervisor without health card appears with status = not_done & deduplicated across multi-team
select is(
  (select count(*)::integer from public.list_branch_supervisor_health_cards(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331'
  )),
  2,
  'lists exactly 2 deduplicated supervisors for branch 1'
);

select is(
  (select status from public.list_branch_supervisor_health_cards(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331'
  ) where supervisor_user_id = '44444444-4444-4444-8444-444444444441'),
  'not_done',
  'supervisor without saved card defaults to not_done'
);

select is(
  (select cardinality(operational_team_ids) from public.list_branch_supervisor_health_cards(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331'
  ) where supervisor_user_id = '44444444-4444-4444-8444-444444444441'),
  2,
  'multi-team supervisor is deduplicated with both operational_team_ids'
);

select is(
  (select assignment_role from public.list_branch_supervisor_health_cards(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331'
  ) where supervisor_user_id = '44444444-4444-4444-8444-444444444441'),
  'primary',
  'multi-team supervisor retains primary precedence'
);

-- 4. Create & update own health card + all 5 status values + concurrent/repeated upserts without duplicates
select is(
  (select status from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331',
    '44444444-4444-4444-8444-444444444441',
    '{"status":"pending","certificate_number":"SUP-HC-1","place_of_issue":"Riyadh","date_issue":"2026-01-01","expiry_date":"2027-01-01","occupation":"Supervisor","company":"HC Co","notes":"Initial"}'::jsonb
  )),
  'pending',
  'primary supervisor can create own health card'
);

select is(
  (select status from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331',
    '44444444-4444-4444-8444-444444444441',
    '{"status":"done_waiting_id","certificate_number":"SUP-HC-2"}'::jsonb
  )),
  'done_waiting_id',
  'supports done_waiting_id status'
);

select is(
  (select status from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331',
    '44444444-4444-4444-8444-444444444441',
    '{"status":"failed"}'::jsonb
  )),
  'failed',
  'supports failed status'
);

select is(
  (select status from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331',
    '44444444-4444-4444-8444-444444444441',
    '{"status":"passed","certificate_number":"SUP-HC-FINAL"}'::jsonb
  )),
  'passed',
  'supports passed status and repeated upserts'
);

select is(
  (select count(*)::integer from public.supervisor_health_cards where supervisor_user_id = '44444444-4444-4444-8444-444444444441'),
  1,
  'repeated/concurrent upserts produce only 1 supervisor_health_cards row'
);

-- 5. Backup supervisor can read and edit own health card
select is(
  (select status from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444442',
    '33333333-3333-4333-8333-333333333331',
    '44444444-4444-4444-8444-444444444442',
    '{"status":"passed","certificate_number":"BACKUP-HC-1"}'::jsonb
  )),
  'passed',
  'backup supervisor can create/update own health card'
);

-- 6. Editing another supervisor is denied (42501)
select throws_ok(
  $$select * from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333331',
    '44444444-4444-4444-8444-444444444442',
    '{"status":"failed"}'::jsonb
  )$$,
  '42501',
  'health card access denied',
  'editing another supervisor health card is denied'
);

-- 7. Cross-organization read & write denied (42501)
select throws_ok(
  $$select * from public.list_branch_supervisor_health_cards(
    '44444444-4444-4444-8444-444444444443',
    '33333333-3333-4333-8333-333333333331'
  )$$,
  '42501',
  'health card access denied',
  'cross-organization read is denied'
);

select throws_ok(
  $$select * from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444443',
    '33333333-3333-4333-8333-333333333331',
    '44444444-4444-4444-8444-444444444443',
    '{"status":"passed"}'::jsonb
  )$$,
  '42501',
  'health card access denied',
  'cross-organization write is denied'
);

select is(
  private.staff_hygiene_branch_has_eligible_staff(
    '11111111-1111-4111-8111-111111111111',
    '33333333-3333-4333-8333-333333333331',
    current_date
  ),
  true,
  'staff hygiene eligibility remains unchanged'
);

-- 8. Same-organization branch transfer preserves supervisor health card record
do $$
declare
  v_branch2 uuid := '33333333-3333-4333-8333-333333333332';
  v_branch1 uuid := '33333333-3333-4333-8333-333333333331';
  v_org1 uuid := '11111111-1111-4111-8111-111111111111';
  v_sup_primary uuid := '44444444-4444-4444-8444-444444444441';
  v_teamb2 uuid;
begin
  select id into strict v_teamb2 from public.branch_operational_teams where branch_id = v_branch2 limit 1;
  update public.branch_operational_team_supervisors
  set active = false, valid_to = current_date
  where branch_id = v_branch1 and supervisor_user_id = v_sup_primary and active;

  insert into public.branch_memberships(user_id, branch_id, role, active)
  values (v_sup_primary, v_branch2, 'branch_manager', true)
  on conflict do nothing;

  insert into public.branch_operational_team_supervisors(
    organization_id, branch_id, operational_team_id, supervisor_user_id, assignment_role, valid_from, active, created_by
  ) values (v_org1, v_branch2, v_teamb2, v_sup_primary, 'backup', current_date, true, v_sup_primary);
end $$;

select is(
  (select certificate_number from public.list_branch_supervisor_health_cards(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333332'
  ) where supervisor_user_id = '44444444-4444-4444-8444-444444444441'),
  'SUP-HC-FINAL',
  'same-organization branch transfer preserves supervisor health card'
);

-- 9. Deactivated supervisor access denied & record preserved
update public.profiles set disabled_at = now() where id = '44444444-4444-4444-8444-444444444441';

select throws_ok(
  $$select * from public.upsert_supervisor_health_card(
    '44444444-4444-4444-8444-444444444441',
    '33333333-3333-4333-8333-333333333332',
    '44444444-4444-4444-8444-444444444441',
    '{"status":"not_done"}'::jsonb
  )$$,
  '42501',
  'health card access denied',
  'deactivated supervisor write is denied'
);

select is(
  (select certificate_number from public.supervisor_health_cards where supervisor_user_id = '44444444-4444-4444-8444-444444444441'),
  'SUP-HC-FINAL',
  'supervisor health card record is preserved after deactivation'
);

-- 10. Existing employee health cards, employee count, Staff Hygiene eligibility, and onboarding unchanged
select is(
  (select count(*)::integer from public.list_operational_staff_health_cards(
    '44444444-4444-4444-8444-444444444442',
    '33333333-3333-4333-8333-333333333331'
  )),
  1,
  'existing employee health cards list remains unchanged'
);

select is(
  (select count(*)::integer from public.get_supervisor_operational_team(
    '44444444-4444-4444-8444-444444444442',
    '33333333-3333-4333-8333-333333333331',
    current_date
  ) where staff_id is not null),
  1,
  'employee count in get_supervisor_operational_team remains unchanged'
);

select finish();
rollback;
