begin;
select plan(85);

-- Inline the remediation migration
revoke execute on function public.cancel_managed_operational_staff_supervisor_training(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.get_cold_storage_managed_report_detail(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.get_managed_annual_evaluation_detail(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.get_managed_annual_evaluation_workspace(uuid, uuid, integer, uuid, text, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.get_managed_daily_audit_report_detail(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.get_managed_supervisor_training_promotion_state(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.get_management_organization_branding(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.get_oil_tracking_managed_report_detail(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.grant_existing_organization_manager(uuid, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.list_cold_storage_managed_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text)
  from public, anon, authenticated;
revoke execute on function public.list_internal_admin_organization_managers(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.list_managed_branch_shifts(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.list_managed_daily_audit_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text)
  from public, anon, authenticated;
revoke execute on function public.list_managed_maintenance_users(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.list_managed_operational_staff(uuid, uuid, integer, integer, text, uuid, uuid, text, text, date)
  from public, anon, authenticated;
revoke execute on function public.list_managed_organization_users(uuid, uuid, integer, integer, text, text, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.list_oil_tracking_managed_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text)
  from public, anon, authenticated;
revoke execute on function public.list_organization_manager_daily_audit_pins(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.list_phase4a_managed_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text, text)
  from public, anon, authenticated;

grant execute on function public.cancel_managed_operational_staff_supervisor_training(uuid, uuid, uuid)
  to service_role;
grant execute on function public.get_cold_storage_managed_report_detail(uuid, uuid, uuid)
  to service_role;
grant execute on function public.get_managed_annual_evaluation_detail(uuid, uuid, uuid)
  to service_role;
grant execute on function public.get_managed_annual_evaluation_workspace(uuid, uuid, integer, uuid, text, uuid, text)
  to service_role;
grant execute on function public.get_managed_daily_audit_report_detail(uuid, uuid, uuid)
  to service_role;
grant execute on function public.get_managed_supervisor_training_promotion_state(uuid, uuid, uuid)
  to service_role;
grant execute on function public.get_management_organization_branding(uuid, uuid)
  to service_role;
grant execute on function public.get_oil_tracking_managed_report_detail(uuid, uuid, uuid)
  to service_role;
grant execute on function public.grant_existing_organization_manager(uuid, uuid, text)
  to service_role;
grant execute on function public.list_cold_storage_managed_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text)
  to service_role;
grant execute on function public.list_internal_admin_organization_managers(uuid, uuid)
  to service_role;
grant execute on function public.list_managed_branch_shifts(uuid, uuid, uuid)
  to service_role;
grant execute on function public.list_managed_daily_audit_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text)
  to service_role;
grant execute on function public.list_managed_maintenance_users(uuid, uuid)
  to service_role;
grant execute on function public.list_managed_operational_staff(uuid, uuid, integer, integer, text, uuid, uuid, text, text, date)
  to service_role;
grant execute on function public.list_managed_organization_users(uuid, uuid, integer, integer, text, text, uuid, text)
  to service_role;
grant execute on function public.list_oil_tracking_managed_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text)
  to service_role;
grant execute on function public.list_organization_manager_daily_audit_pins(uuid, uuid)
  to service_role;
grant execute on function public.list_phase4a_managed_reports(uuid, uuid, integer, integer, date, date, uuid, uuid, text, text, text)
  to service_role;

insert into auth.users(
  instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values (
  '00000000-0000-0000-0000-000000000000',
  '1b000000-0000-4000-8000-000000000001',
  'authenticated','authenticated','manager-remediation@example.invalid','{}','{}',now(),now()
);
update public.profiles
set full_name='Manager Remediation Test',must_change_password=false
where id='1b000000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug)
values('2b000000-0000-4000-8000-000000000001','Manager Remediation Test Org','manager-remediation-test-org');
insert into public.organization_memberships(organization_id,user_id,role)
values(
  '2b000000-0000-4000-8000-000000000001',
  '1b000000-0000-4000-8000-000000000001',
  'organization_manager'
);

-- Effective privileges for all 19 exact PostgREST-visible signatures.

-- 1. cancel_managed_operational_staff_supervisor_training
select is(has_function_privilege('public','public.cancel_managed_operational_staff_supervisor_training(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot cancel supervisor training');
select is(has_function_privilege('anon','public.cancel_managed_operational_staff_supervisor_training(uuid,uuid,uuid)','execute'),false,'anon cannot cancel supervisor training');
select is(has_function_privilege('authenticated','public.cancel_managed_operational_staff_supervisor_training(uuid,uuid,uuid)','execute'),false,'authenticated cannot cancel supervisor training');
select is(has_function_privilege('service_role','public.cancel_managed_operational_staff_supervisor_training(uuid,uuid,uuid)','execute'),true,'service_role can cancel supervisor training');

-- 2. get_cold_storage_managed_report_detail
select is(has_function_privilege('public','public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read cold storage managed report detail');
select is(has_function_privilege('anon','public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)','execute'),false,'anon cannot read cold storage managed report detail');
select is(has_function_privilege('authenticated','public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)','execute'),false,'authenticated cannot read cold storage managed report detail');
select is(has_function_privilege('service_role','public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)','execute'),true,'service_role can read cold storage managed report detail');

-- 3. get_managed_annual_evaluation_detail
select is(has_function_privilege('public','public.get_managed_annual_evaluation_detail(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read managed annual evaluation detail');
select is(has_function_privilege('anon','public.get_managed_annual_evaluation_detail(uuid,uuid,uuid)','execute'),false,'anon cannot read managed annual evaluation detail');
select is(has_function_privilege('authenticated','public.get_managed_annual_evaluation_detail(uuid,uuid,uuid)','execute'),false,'authenticated cannot read managed annual evaluation detail');
select is(has_function_privilege('service_role','public.get_managed_annual_evaluation_detail(uuid,uuid,uuid)','execute'),true,'service_role can read managed annual evaluation detail');

-- 4. get_managed_annual_evaluation_workspace
select is(has_function_privilege('public','public.get_managed_annual_evaluation_workspace(uuid,uuid,integer,uuid,text,uuid,text)','execute'),false,'PUBLIC cannot read managed annual evaluation workspace');
select is(has_function_privilege('anon','public.get_managed_annual_evaluation_workspace(uuid,uuid,integer,uuid,text,uuid,text)','execute'),false,'anon cannot read managed annual evaluation workspace');
select is(has_function_privilege('authenticated','public.get_managed_annual_evaluation_workspace(uuid,uuid,integer,uuid,text,uuid,text)','execute'),false,'authenticated cannot read managed annual evaluation workspace');
select is(has_function_privilege('service_role','public.get_managed_annual_evaluation_workspace(uuid,uuid,integer,uuid,text,uuid,text)','execute'),true,'service_role can read managed annual evaluation workspace');

-- 5. get_managed_daily_audit_report_detail
select is(has_function_privilege('public','public.get_managed_daily_audit_report_detail(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read daily audit managed report detail');
select is(has_function_privilege('anon','public.get_managed_daily_audit_report_detail(uuid,uuid,uuid)','execute'),false,'anon cannot read daily audit managed report detail');
select is(has_function_privilege('authenticated','public.get_managed_daily_audit_report_detail(uuid,uuid,uuid)','execute'),false,'authenticated cannot read daily audit managed report detail');
select is(has_function_privilege('service_role','public.get_managed_daily_audit_report_detail(uuid,uuid,uuid)','execute'),true,'service_role can read daily audit managed report detail');

-- 6. get_managed_supervisor_training_promotion_state
select is(has_function_privilege('public','public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read supervisor training promotion state');
select is(has_function_privilege('anon','public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid)','execute'),false,'anon cannot read supervisor training promotion state');
select is(has_function_privilege('authenticated','public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid)','execute'),false,'authenticated cannot read supervisor training promotion state');
select is(has_function_privilege('service_role','public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid)','execute'),true,'service_role can read supervisor training promotion state');

-- 7. get_management_organization_branding
select is(has_function_privilege('public','public.get_management_organization_branding(uuid,uuid)','execute'),false,'PUBLIC cannot read management organization branding');
select is(has_function_privilege('anon','public.get_management_organization_branding(uuid,uuid)','execute'),false,'anon cannot read management organization branding');
select is(has_function_privilege('authenticated','public.get_management_organization_branding(uuid,uuid)','execute'),false,'authenticated cannot read management organization branding');
select is(has_function_privilege('service_role','public.get_management_organization_branding(uuid,uuid)','execute'),true,'service_role can read management organization branding');

-- 8. get_oil_tracking_managed_report_detail
select is(has_function_privilege('public','public.get_oil_tracking_managed_report_detail(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read oil tracking managed report detail');
select is(has_function_privilege('anon','public.get_oil_tracking_managed_report_detail(uuid,uuid,uuid)','execute'),false,'anon cannot read oil tracking managed report detail');
select is(has_function_privilege('authenticated','public.get_oil_tracking_managed_report_detail(uuid,uuid,uuid)','execute'),false,'authenticated cannot read oil tracking managed report detail');
select is(has_function_privilege('service_role','public.get_oil_tracking_managed_report_detail(uuid,uuid,uuid)','execute'),true,'service_role can read oil tracking managed report detail');

-- 9. grant_existing_organization_manager
select is(has_function_privilege('public','public.grant_existing_organization_manager(uuid,uuid,text)','execute'),false,'PUBLIC cannot grant organization manager');
select is(has_function_privilege('anon','public.grant_existing_organization_manager(uuid,uuid,text)','execute'),false,'anon cannot grant organization manager');
select is(has_function_privilege('authenticated','public.grant_existing_organization_manager(uuid,uuid,text)','execute'),false,'authenticated cannot grant organization manager');
select is(has_function_privilege('service_role','public.grant_existing_organization_manager(uuid,uuid,text)','execute'),true,'service_role can grant organization manager');

-- 10. list_cold_storage_managed_reports
select is(has_function_privilege('public','public.list_cold_storage_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'PUBLIC cannot list cold storage managed reports');
select is(has_function_privilege('anon','public.list_cold_storage_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'anon cannot list cold storage managed reports');
select is(has_function_privilege('authenticated','public.list_cold_storage_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'authenticated cannot list cold storage managed reports');
select is(has_function_privilege('service_role','public.list_cold_storage_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),true,'service_role can list cold storage managed reports');

-- 11. list_internal_admin_organization_managers
select is(has_function_privilege('public','public.list_internal_admin_organization_managers(uuid,uuid)','execute'),false,'PUBLIC cannot list internal admin organization managers');
select is(has_function_privilege('anon','public.list_internal_admin_organization_managers(uuid,uuid)','execute'),false,'anon cannot list internal admin organization managers');
select is(has_function_privilege('authenticated','public.list_internal_admin_organization_managers(uuid,uuid)','execute'),false,'authenticated cannot list internal admin organization managers');
select is(has_function_privilege('service_role','public.list_internal_admin_organization_managers(uuid,uuid)','execute'),true,'service_role can list internal admin organization managers');

-- 12. list_managed_branch_shifts
select is(has_function_privilege('public','public.list_managed_branch_shifts(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot list managed branch shifts');
select is(has_function_privilege('anon','public.list_managed_branch_shifts(uuid,uuid,uuid)','execute'),false,'anon cannot list managed branch shifts');
select is(has_function_privilege('authenticated','public.list_managed_branch_shifts(uuid,uuid,uuid)','execute'),false,'authenticated cannot list managed branch shifts');
select is(has_function_privilege('service_role','public.list_managed_branch_shifts(uuid,uuid,uuid)','execute'),true,'service_role can list managed branch shifts');

-- 13. list_managed_daily_audit_reports
select is(has_function_privilege('public','public.list_managed_daily_audit_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'PUBLIC cannot list daily audit managed reports');
select is(has_function_privilege('anon','public.list_managed_daily_audit_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'anon cannot list daily audit managed reports');
select is(has_function_privilege('authenticated','public.list_managed_daily_audit_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'authenticated cannot list daily audit managed reports');
select is(has_function_privilege('service_role','public.list_managed_daily_audit_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),true,'service_role can list daily audit managed reports');

-- 14. list_managed_maintenance_users
select is(has_function_privilege('public','public.list_managed_maintenance_users(uuid,uuid)','execute'),false,'PUBLIC cannot list managed maintenance users');
select is(has_function_privilege('anon','public.list_managed_maintenance_users(uuid,uuid)','execute'),false,'anon cannot list managed maintenance users');
select is(has_function_privilege('authenticated','public.list_managed_maintenance_users(uuid,uuid)','execute'),false,'authenticated cannot list managed maintenance users');
select is(has_function_privilege('service_role','public.list_managed_maintenance_users(uuid,uuid)','execute'),true,'service_role can list managed maintenance users');

-- 15. list_managed_operational_staff
select is(has_function_privilege('public','public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date)','execute'),false,'PUBLIC cannot list managed operational staff');
select is(has_function_privilege('anon','public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date)','execute'),false,'anon cannot list managed operational staff');
select is(has_function_privilege('authenticated','public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date)','execute'),false,'authenticated cannot list managed operational staff');
select is(has_function_privilege('service_role','public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date)','execute'),true,'service_role can list managed operational staff');

-- 16. list_managed_organization_users
select is(has_function_privilege('public','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),false,'PUBLIC cannot list managed organization users');
select is(has_function_privilege('anon','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),false,'anon cannot list managed organization users');
select is(has_function_privilege('authenticated','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),false,'authenticated cannot list managed organization users');
select is(has_function_privilege('service_role','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),true,'service_role can list managed organization users');

-- 17. list_oil_tracking_managed_reports
select is(has_function_privilege('public','public.list_oil_tracking_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'PUBLIC cannot list oil tracking managed reports');
select is(has_function_privilege('anon','public.list_oil_tracking_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'anon cannot list oil tracking managed reports');
select is(has_function_privilege('authenticated','public.list_oil_tracking_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),false,'authenticated cannot list oil tracking managed reports');
select is(has_function_privilege('service_role','public.list_oil_tracking_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text)','execute'),true,'service_role can list oil tracking managed reports');

-- 18. list_organization_manager_daily_audit_pins
select is(has_function_privilege('public','public.list_organization_manager_daily_audit_pins(uuid,uuid)','execute'),false,'PUBLIC cannot list organization manager daily audit pins');
select is(has_function_privilege('anon','public.list_organization_manager_daily_audit_pins(uuid,uuid)','execute'),false,'anon cannot list organization manager daily audit pins');
select is(has_function_privilege('authenticated','public.list_organization_manager_daily_audit_pins(uuid,uuid)','execute'),false,'authenticated cannot list organization manager daily audit pins');
select is(has_function_privilege('service_role','public.list_organization_manager_daily_audit_pins(uuid,uuid)','execute'),true,'service_role can list organization manager daily audit pins');

-- 19. list_phase4a_managed_reports
select is(has_function_privilege('public','public.list_phase4a_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text,text)','execute'),false,'PUBLIC cannot list phase4a managed reports');
select is(has_function_privilege('anon','public.list_phase4a_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text,text)','execute'),false,'anon cannot list phase4a managed reports');
select is(has_function_privilege('authenticated','public.list_phase4a_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot list phase4a managed reports');
select is(has_function_privilege('service_role','public.list_phase4a_managed_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text,text)','execute'),true,'service_role can list phase4a managed reports');

-- Forged-actor tests: anon cannot execute
set local role anon;
select throws_ok(
  $$select public.grant_existing_organization_manager('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','attacker@example.invalid')$$,
  '42501','permission denied for function grant_existing_organization_manager',
  'anon direct mutation call is denied before actor authorization'
);
select throws_ok(
  $$select public.list_phase4a_managed_reports('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001')$$,
  '42501','permission denied for function list_phase4a_managed_reports',
  'anon direct list call is denied before actor authorization'
);
reset role;

-- Forged-actor tests: authenticated cannot execute
set local role authenticated;
select throws_ok(
  $$select public.grant_existing_organization_manager('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','attacker@example.invalid')$$,
  '42501','permission denied for function grant_existing_organization_manager',
  'authenticated direct mutation call is denied before actor authorization'
);
select throws_ok(
  $$select public.list_phase4a_managed_reports('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001')$$,
  '42501','permission denied for function list_phase4a_managed_reports',
  'authenticated direct list call is denied before actor authorization'
);
reset role;

-- Backend execution via service_role succeeds
set local role service_role;
select lives_ok(
  $$select public.list_phase4a_managed_reports('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001')$$,
  'service_role can execute Phase4A Manager Reports through the backend boundary'
);
select lives_ok(
  $$select public.list_oil_tracking_managed_reports('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001')$$,
  'service_role can execute Oil Manager Reports through the backend boundary'
);
select lives_ok(
  $$select public.list_cold_storage_managed_reports('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001')$$,
  'service_role can execute Cold Storage Manager Reports through the backend boundary'
);
select lives_ok(
  $$select public.list_managed_daily_audit_reports('1b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001')$$,
  'service_role can execute Daily Audit Manager Reports through the backend boundary'
);

-- Cross-organization authorization still fails inside the function if actor does not manage the target organization
select throws_ok(
  $$select public.list_phase4a_managed_reports('1b000000-0000-4000-8000-000000000001','99000000-0000-4000-8000-000000000099')$$,
  '42501','report access denied',
  'service_role call fails closed when actor does not manage target organization'
);
reset role;

select * from finish();
rollback;
