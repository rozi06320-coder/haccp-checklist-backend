begin;

-- Remediation for remaining 19 Manager-related SECURITY DEFINER RPCs.
-- These functions are called only by the Express backend using service-role credentials.
-- They accept an actor UUID because the backend has already authenticated the request,
-- so browser/client roles (public, anon, authenticated) must never execute them directly
-- to prevent actor-forgery and unauthorized cross-organization data access or mutations.

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

commit;
