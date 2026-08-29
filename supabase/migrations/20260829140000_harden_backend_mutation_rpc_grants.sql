-- Harden backend-only mutation RPC privileges after production grant drift.
-- No table data, RLS policies, or function bodies are changed here.

alter default privileges for role postgres in schema public revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke execute on functions from anon;
alter default privileges for role postgres in schema public revoke execute on functions from authenticated;
alter default privileges for role postgres in schema public grant execute on functions to service_role;

revoke execute on function public.authorize_phase4a_evidence_read(uuid, uuid) from public;
revoke execute on function public.authorize_phase4a_evidence_read(uuid, uuid) from anon;
revoke execute on function public.authorize_phase4a_evidence_read(uuid, uuid) from authenticated;
grant execute on function public.authorize_phase4a_evidence_read(uuid, uuid) to service_role;

revoke execute on function public.authorize_phase4a_evidence_set(uuid, uuid, text, uuid[]) from public;
revoke execute on function public.authorize_phase4a_evidence_set(uuid, uuid, text, uuid[]) from anon;
revoke execute on function public.authorize_phase4a_evidence_set(uuid, uuid, text, uuid[]) from authenticated;
grant execute on function public.authorize_phase4a_evidence_set(uuid, uuid, text, uuid[]) to service_role;

revoke execute on function public.authorize_phase4a_evidence_upload(uuid, uuid, text, text) from public;
revoke execute on function public.authorize_phase4a_evidence_upload(uuid, uuid, text, text) from anon;
revoke execute on function public.authorize_phase4a_evidence_upload(uuid, uuid, text, text) from authenticated;
grant execute on function public.authorize_phase4a_evidence_upload(uuid, uuid, text, text) to service_role;

revoke execute on function public.confirm_operational_team_staff_import(uuid, uuid, uuid, uuid) from public;
revoke execute on function public.confirm_operational_team_staff_import(uuid, uuid, uuid, uuid) from anon;
revoke execute on function public.confirm_operational_team_staff_import(uuid, uuid, uuid, uuid) from authenticated;
grant execute on function public.confirm_operational_team_staff_import(uuid, uuid, uuid, uuid) to service_role;

revoke execute on function public.create_branch_purchase_log(uuid, uuid, jsonb) from public;
revoke execute on function public.create_branch_purchase_log(uuid, uuid, jsonb) from anon;
revoke execute on function public.create_branch_purchase_log(uuid, uuid, jsonb) from authenticated;
grant execute on function public.create_branch_purchase_log(uuid, uuid, jsonb) to service_role;

revoke execute on function public.create_branch_supplier(uuid, uuid, jsonb) from public;
revoke execute on function public.create_branch_supplier(uuid, uuid, jsonb) from anon;
revoke execute on function public.create_branch_supplier(uuid, uuid, jsonb) from authenticated;
grant execute on function public.create_branch_supplier(uuid, uuid, jsonb) to service_role;

revoke execute on function public.create_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from public;
revoke execute on function public.create_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from anon;
revoke execute on function public.create_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from authenticated;
grant execute on function public.create_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) to service_role;

revoke execute on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text) from public;
revoke execute on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text) from anon;
revoke execute on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text) from authenticated;
grant execute on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text) to service_role;

revoke execute on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[]) from public;
revoke execute on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[]) from anon;
revoke execute on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[]) from authenticated;
grant execute on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[]) to service_role;

revoke execute on function public.create_internal_admin_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from public;
revoke execute on function public.create_internal_admin_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from anon;
revoke execute on function public.create_internal_admin_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from authenticated;
grant execute on function public.create_internal_admin_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) to service_role;

revoke execute on function public.create_internal_admin_operational_team(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) from public;
revoke execute on function public.create_internal_admin_operational_team(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) from anon;
revoke execute on function public.create_internal_admin_operational_team(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) from authenticated;
grant execute on function public.create_internal_admin_operational_team(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) to service_role;

revoke execute on function public.create_internal_admin_organization(uuid, text) from public;
revoke execute on function public.create_internal_admin_organization(uuid, text) from anon;
revoke execute on function public.create_internal_admin_organization(uuid, text) from authenticated;
grant execute on function public.create_internal_admin_organization(uuid, text) to service_role;

revoke execute on function public.create_internal_admin_organization(uuid, text, text) from public;
revoke execute on function public.create_internal_admin_organization(uuid, text, text) from anon;
revoke execute on function public.create_internal_admin_organization(uuid, text, text) from authenticated;
grant execute on function public.create_internal_admin_organization(uuid, text, text) to service_role;

revoke execute on function public.create_maintenance_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from public;
revoke execute on function public.create_maintenance_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from anon;
revoke execute on function public.create_maintenance_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from authenticated;
grant execute on function public.create_maintenance_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) to service_role;

revoke execute on function public.create_managed_branch_shift(uuid, uuid, uuid, text, time without time zone, time without time zone) from public;
revoke execute on function public.create_managed_branch_shift(uuid, uuid, uuid, text, time without time zone, time without time zone) from anon;
revoke execute on function public.create_managed_branch_shift(uuid, uuid, uuid, text, time without time zone, time without time zone) from authenticated;
grant execute on function public.create_managed_branch_shift(uuid, uuid, uuid, text, time without time zone, time without time zone) to service_role;

revoke execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid) from public;
revoke execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid) from anon;
revoke execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid) from authenticated;
grant execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid) to service_role;

revoke execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid) from public;
revoke execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid) from anon;
revoke execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid) from authenticated;
grant execute on function public.create_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid) to service_role;

revoke execute on function public.create_operational_team_staff(uuid, uuid, uuid, text, text[], text, text, text, text, date, text, text) from public;
revoke execute on function public.create_operational_team_staff(uuid, uuid, uuid, text, text[], text, text, text, text, date, text, text) from anon;
revoke execute on function public.create_operational_team_staff(uuid, uuid, uuid, text, text[], text, text, text, text, date, text, text) from authenticated;
grant execute on function public.create_operational_team_staff(uuid, uuid, uuid, text, text[], text, text, text, text, date, text, text) to service_role;

revoke execute on function public.create_operational_team_staff_import_preview(uuid, uuid, uuid, jsonb) from public;
revoke execute on function public.create_operational_team_staff_import_preview(uuid, uuid, uuid, jsonb) from anon;
revoke execute on function public.create_operational_team_staff_import_preview(uuid, uuid, uuid, jsonb) from authenticated;
grant execute on function public.create_operational_team_staff_import_preview(uuid, uuid, uuid, jsonb) to service_role;

revoke execute on function public.create_sales_tracking_online_order_provider(uuid, uuid, text) from public;
revoke execute on function public.create_sales_tracking_online_order_provider(uuid, uuid, text) from anon;
revoke execute on function public.create_sales_tracking_online_order_provider(uuid, uuid, text) from authenticated;
grant execute on function public.create_sales_tracking_online_order_provider(uuid, uuid, text) to service_role;

revoke execute on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text) from public;
revoke execute on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text) from anon;
revoke execute on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text) from authenticated;
grant execute on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text) to service_role;

revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[]) from public;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[]) from anon;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[]) from authenticated;
grant execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[]) to service_role;

revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text) from public;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text) from anon;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text) from authenticated;
grant execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text) to service_role;

revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text, text, date, text, text) from public;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text, text, date, text, text) from anon;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text, text, date, text, text) from authenticated;
grant execute on function public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text, text, date, text, text) to service_role;

revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, uuid, text[]) from public;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, uuid, text[]) from anon;
revoke execute on function public.create_supervisor_operational_staff(uuid, uuid, text, uuid, text[]) from authenticated;
grant execute on function public.create_supervisor_operational_staff(uuid, uuid, text, uuid, text[]) to service_role;

revoke execute on function public.create_supervisor_owned_operational_team(uuid, uuid, text) from public;
revoke execute on function public.create_supervisor_owned_operational_team(uuid, uuid, text) from anon;
revoke execute on function public.create_supervisor_owned_operational_team(uuid, uuid, text) from authenticated;
grant execute on function public.create_supervisor_owned_operational_team(uuid, uuid, text) to service_role;

revoke execute on function public.deactivate_internal_admin_branch(uuid, uuid, uuid) from public;
revoke execute on function public.deactivate_internal_admin_branch(uuid, uuid, uuid) from anon;
revoke execute on function public.deactivate_internal_admin_branch(uuid, uuid, uuid) from authenticated;
grant execute on function public.deactivate_internal_admin_branch(uuid, uuid, uuid) to service_role;

revoke execute on function public.deactivate_internal_admin_organization(uuid, uuid) from public;
revoke execute on function public.deactivate_internal_admin_organization(uuid, uuid) from anon;
revoke execute on function public.deactivate_internal_admin_organization(uuid, uuid) from authenticated;
grant execute on function public.deactivate_internal_admin_organization(uuid, uuid) to service_role;

revoke execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) from public;
revoke execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) from anon;
revoke execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) from authenticated;
grant execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) to service_role;

revoke execute on function public.deactivate_maintenance_access_user(uuid, uuid, uuid) from public;
revoke execute on function public.deactivate_maintenance_access_user(uuid, uuid, uuid) from anon;
revoke execute on function public.deactivate_maintenance_access_user(uuid, uuid, uuid) from authenticated;
grant execute on function public.deactivate_maintenance_access_user(uuid, uuid, uuid) to service_role;

revoke execute on function public.deactivate_maintenance_user(uuid, uuid, uuid) from public;
revoke execute on function public.deactivate_maintenance_user(uuid, uuid, uuid) from anon;
revoke execute on function public.deactivate_maintenance_user(uuid, uuid, uuid) from authenticated;
grant execute on function public.deactivate_maintenance_user(uuid, uuid, uuid) to service_role;

revoke execute on function public.deactivate_organization_manager(uuid, uuid, uuid) from public;
revoke execute on function public.deactivate_organization_manager(uuid, uuid, uuid) from anon;
revoke execute on function public.deactivate_organization_manager(uuid, uuid, uuid) from authenticated;
grant execute on function public.deactivate_organization_manager(uuid, uuid, uuid) to service_role;

revoke execute on function public.finalize_password_change(uuid) from public;
revoke execute on function public.finalize_password_change(uuid) from anon;
revoke execute on function public.finalize_password_change(uuid) from authenticated;
grant execute on function public.finalize_password_change(uuid) to service_role;

revoke execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) from public;
revoke execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) from anon;
revoke execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) from authenticated;
grant execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) to service_role;

revoke execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text) from public;
revoke execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text) from anon;
revoke execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text) from authenticated;
grant execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text) to service_role;

revoke execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) from public;
revoke execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) from anon;
revoke execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) from authenticated;
grant execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) to service_role;

revoke execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text) from public;
revoke execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text) from anon;
revoke execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text) from authenticated;
grant execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text) to service_role;

revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) from public;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) from anon;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) from authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) to service_role;

revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) from public;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) from anon;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) from authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) to service_role;

revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb) from public;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb) from anon;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb) from authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb) to service_role;

revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb, text, text, text, text, date) from public;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb, text, text, text, text, date) from anon;
revoke execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb, text, text, text, text, date) from authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb, text, text, text, text, date) to service_role;

revoke execute on function public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[]) from public;
revoke execute on function public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[]) from anon;
revoke execute on function public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[]) from authenticated;
grant execute on function public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[]) to service_role;

revoke execute on function public.move_operational_staff_team(uuid, uuid, uuid, uuid, uuid) from public;
revoke execute on function public.move_operational_staff_team(uuid, uuid, uuid, uuid, uuid) from anon;
revoke execute on function public.move_operational_staff_team(uuid, uuid, uuid, uuid, uuid) from authenticated;
grant execute on function public.move_operational_staff_team(uuid, uuid, uuid, uuid, uuid) to service_role;

revoke execute on function public.reactivate_internal_admin_branch(uuid, uuid, uuid) from public;
revoke execute on function public.reactivate_internal_admin_branch(uuid, uuid, uuid) from anon;
revoke execute on function public.reactivate_internal_admin_branch(uuid, uuid, uuid) from authenticated;
grant execute on function public.reactivate_internal_admin_branch(uuid, uuid, uuid) to service_role;

revoke execute on function public.reactivate_internal_admin_organization(uuid, uuid) from public;
revoke execute on function public.reactivate_internal_admin_organization(uuid, uuid) from anon;
revoke execute on function public.reactivate_internal_admin_organization(uuid, uuid) from authenticated;
grant execute on function public.reactivate_internal_admin_organization(uuid, uuid) to service_role;

revoke execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) from public;
revoke execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) from anon;
revoke execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) from authenticated;
grant execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) to service_role;

revoke execute on function public.reactivate_maintenance_user(uuid, uuid, uuid) from public;
revoke execute on function public.reactivate_maintenance_user(uuid, uuid, uuid) from anon;
revoke execute on function public.reactivate_maintenance_user(uuid, uuid, uuid) from authenticated;
grant execute on function public.reactivate_maintenance_user(uuid, uuid, uuid) to service_role;

revoke execute on function public.reactivate_organization_manager(uuid, uuid, uuid) from public;
revoke execute on function public.reactivate_organization_manager(uuid, uuid, uuid) from anon;
revoke execute on function public.reactivate_organization_manager(uuid, uuid, uuid) from authenticated;
grant execute on function public.reactivate_organization_manager(uuid, uuid, uuid) to service_role;

revoke execute on function public.register_maintenance_push_subscription(uuid, text, text, text, text) from public;
revoke execute on function public.register_maintenance_push_subscription(uuid, text, text, text, text) from anon;
revoke execute on function public.register_maintenance_push_subscription(uuid, text, text, text, text) from authenticated;
grant execute on function public.register_maintenance_push_subscription(uuid, text, text, text, text) to service_role;

revoke execute on function public.register_phase4a_evidence_upload(uuid, uuid, text, text, uuid, text, text, bigint, text) from public;
revoke execute on function public.register_phase4a_evidence_upload(uuid, uuid, text, text, uuid, text, text, bigint, text) from anon;
revoke execute on function public.register_phase4a_evidence_upload(uuid, uuid, text, text, uuid, text, text, bigint, text) from authenticated;
grant execute on function public.register_phase4a_evidence_upload(uuid, uuid, text, text, uuid, text, text, bigint, text) to service_role;

revoke execute on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text) from public;
revoke execute on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text) from anon;
revoke execute on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text) from authenticated;
grant execute on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text) to service_role;

revoke execute on function public.save_inventory_items_draft(uuid, uuid, jsonb, jsonb) from public;
revoke execute on function public.save_inventory_items_draft(uuid, uuid, jsonb, jsonb) from anon;
revoke execute on function public.save_inventory_items_draft(uuid, uuid, jsonb, jsonb) from authenticated;
grant execute on function public.save_inventory_items_draft(uuid, uuid, jsonb, jsonb) to service_role;

revoke execute on function public.save_managed_annual_evaluation_draft(uuid, uuid, uuid, integer, text, uuid, uuid, bigint, jsonb) from public;
revoke execute on function public.save_managed_annual_evaluation_draft(uuid, uuid, uuid, integer, text, uuid, uuid, bigint, jsonb) from anon;
revoke execute on function public.save_managed_annual_evaluation_draft(uuid, uuid, uuid, integer, text, uuid, uuid, bigint, jsonb) from authenticated;
grant execute on function public.save_managed_annual_evaluation_draft(uuid, uuid, uuid, integer, text, uuid, uuid, bigint, jsonb) to service_role;

revoke execute on function public.save_oil_tracking_draft(uuid, uuid, bigint, jsonb) from public;
revoke execute on function public.save_oil_tracking_draft(uuid, uuid, bigint, jsonb) from anon;
revoke execute on function public.save_oil_tracking_draft(uuid, uuid, bigint, jsonb) from authenticated;
grant execute on function public.save_oil_tracking_draft(uuid, uuid, bigint, jsonb) to service_role;

revoke execute on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) from public;
revoke execute on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) from anon;
revoke execute on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) from authenticated;
grant execute on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) to service_role;

revoke execute on function public.save_operational_team_hygiene_draft(uuid, uuid, uuid, bigint, jsonb) from public;
revoke execute on function public.save_operational_team_hygiene_draft(uuid, uuid, uuid, bigint, jsonb) from anon;
revoke execute on function public.save_operational_team_hygiene_draft(uuid, uuid, uuid, bigint, jsonb) from authenticated;
grant execute on function public.save_operational_team_hygiene_draft(uuid, uuid, uuid, bigint, jsonb) to service_role;

revoke execute on function public.save_phase4a_draft(uuid, uuid, text, bigint, jsonb) from public;
revoke execute on function public.save_phase4a_draft(uuid, uuid, text, bigint, jsonb) from anon;
revoke execute on function public.save_phase4a_draft(uuid, uuid, text, bigint, jsonb) from authenticated;
grant execute on function public.save_phase4a_draft(uuid, uuid, text, bigint, jsonb) to service_role;

revoke execute on function public.save_phase4a_hygiene_draft(uuid, uuid, jsonb) from public;
revoke execute on function public.save_phase4a_hygiene_draft(uuid, uuid, jsonb) from anon;
revoke execute on function public.save_phase4a_hygiene_draft(uuid, uuid, jsonb) from authenticated;
grant execute on function public.save_phase4a_hygiene_draft(uuid, uuid, jsonb) to service_role;

revoke execute on function public.save_sales_tracking_draft(uuid, uuid, bigint, text, jsonb, jsonb) from public;
revoke execute on function public.save_sales_tracking_draft(uuid, uuid, bigint, text, jsonb, jsonb) from anon;
revoke execute on function public.save_sales_tracking_draft(uuid, uuid, bigint, text, jsonb, jsonb) from authenticated;
grant execute on function public.save_sales_tracking_draft(uuid, uuid, bigint, text, jsonb, jsonb) to service_role;

revoke execute on function public.save_supervisor_daily_audit_draft(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb) from public;
revoke execute on function public.save_supervisor_daily_audit_draft(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb) from anon;
revoke execute on function public.save_supervisor_daily_audit_draft(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb) from authenticated;
grant execute on function public.save_supervisor_daily_audit_draft(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb) to service_role;

revoke execute on function public.set_operational_team_staff_duty(uuid, uuid, uuid, date, text) from public;
revoke execute on function public.set_operational_team_staff_duty(uuid, uuid, uuid, date, text) from anon;
revoke execute on function public.set_operational_team_staff_duty(uuid, uuid, uuid, date, text) from authenticated;
grant execute on function public.set_operational_team_staff_duty(uuid, uuid, uuid, date, text) to service_role;

revoke execute on function public.set_supervisor_operational_duty(uuid, uuid, uuid, date, text) from public;
revoke execute on function public.set_supervisor_operational_duty(uuid, uuid, uuid, date, text) from anon;
revoke execute on function public.set_supervisor_operational_duty(uuid, uuid, uuid, date, text) from authenticated;
grant execute on function public.set_supervisor_operational_duty(uuid, uuid, uuid, date, text) to service_role;

revoke execute on function public.start_managed_operational_staff_supervisor_training(uuid, uuid, uuid) from public;
revoke execute on function public.start_managed_operational_staff_supervisor_training(uuid, uuid, uuid) from anon;
revoke execute on function public.start_managed_operational_staff_supervisor_training(uuid, uuid, uuid) from authenticated;
grant execute on function public.start_managed_operational_staff_supervisor_training(uuid, uuid, uuid) to service_role;

revoke execute on function public.store_daily_audit_pin(uuid, uuid, bytea, bytea, smallint, integer, integer, integer) from public;
revoke execute on function public.store_daily_audit_pin(uuid, uuid, bytea, bytea, smallint, integer, integer, integer) from anon;
revoke execute on function public.store_daily_audit_pin(uuid, uuid, bytea, bytea, smallint, integer, integer, integer) from authenticated;
grant execute on function public.store_daily_audit_pin(uuid, uuid, bytea, bytea, smallint, integer, integer, integer) to service_role;

revoke execute on function public.store_internal_admin_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) from public;
revoke execute on function public.store_internal_admin_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) from anon;
revoke execute on function public.store_internal_admin_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) from authenticated;
grant execute on function public.store_internal_admin_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) to service_role;

revoke execute on function public.store_organization_manager_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) from public;
revoke execute on function public.store_organization_manager_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) from anon;
revoke execute on function public.store_organization_manager_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) from authenticated;
grant execute on function public.store_organization_manager_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer) to service_role;

revoke execute on function public.submit_inventory_items(uuid, uuid, uuid, text, jsonb, jsonb) from public;
revoke execute on function public.submit_inventory_items(uuid, uuid, uuid, text, jsonb, jsonb) from anon;
revoke execute on function public.submit_inventory_items(uuid, uuid, uuid, text, jsonb, jsonb) from authenticated;
grant execute on function public.submit_inventory_items(uuid, uuid, uuid, text, jsonb, jsonb) to service_role;

revoke execute on function public.submit_managed_annual_evaluation(uuid, uuid, uuid, bigint) from public;
revoke execute on function public.submit_managed_annual_evaluation(uuid, uuid, uuid, bigint) from anon;
revoke execute on function public.submit_managed_annual_evaluation(uuid, uuid, uuid, bigint) from authenticated;
grant execute on function public.submit_managed_annual_evaluation(uuid, uuid, uuid, bigint) to service_role;

revoke execute on function public.submit_oil_tracking_closing(uuid, uuid, bigint, uuid, text, jsonb) from public;
revoke execute on function public.submit_oil_tracking_closing(uuid, uuid, bigint, uuid, text, jsonb) from anon;
revoke execute on function public.submit_oil_tracking_closing(uuid, uuid, bigint, uuid, text, jsonb) from authenticated;
grant execute on function public.submit_oil_tracking_closing(uuid, uuid, bigint, uuid, text, jsonb) to service_role;

revoke execute on function public.submit_oil_tracking_opening(uuid, uuid, bigint, uuid, text, jsonb) from public;
revoke execute on function public.submit_oil_tracking_opening(uuid, uuid, bigint, uuid, text, jsonb) from anon;
revoke execute on function public.submit_oil_tracking_opening(uuid, uuid, bigint, uuid, text, jsonb) from authenticated;
grant execute on function public.submit_oil_tracking_opening(uuid, uuid, bigint, uuid, text, jsonb) to service_role;

revoke execute on function public.submit_operational_team_hygiene(uuid, uuid, uuid, uuid, text, jsonb) from public;
revoke execute on function public.submit_operational_team_hygiene(uuid, uuid, uuid, uuid, text, jsonb) from anon;
revoke execute on function public.submit_operational_team_hygiene(uuid, uuid, uuid, uuid, text, jsonb) from authenticated;
grant execute on function public.submit_operational_team_hygiene(uuid, uuid, uuid, uuid, text, jsonb) to service_role;

revoke execute on function public.submit_phase4a_hygiene(uuid, uuid, uuid, text, jsonb) from public;
revoke execute on function public.submit_phase4a_hygiene(uuid, uuid, uuid, text, jsonb) from anon;
revoke execute on function public.submit_phase4a_hygiene(uuid, uuid, uuid, text, jsonb) from authenticated;
grant execute on function public.submit_phase4a_hygiene(uuid, uuid, uuid, text, jsonb) to service_role;

revoke execute on function public.submit_phase4a_opening(uuid, uuid, text, bigint, uuid, text, jsonb) from public;
revoke execute on function public.submit_phase4a_opening(uuid, uuid, text, bigint, uuid, text, jsonb) from anon;
revoke execute on function public.submit_phase4a_opening(uuid, uuid, text, bigint, uuid, text, jsonb) from authenticated;
grant execute on function public.submit_phase4a_opening(uuid, uuid, text, bigint, uuid, text, jsonb) to service_role;

revoke execute on function public.submit_sales_tracking(uuid, uuid, bigint, uuid, text) from public;
revoke execute on function public.submit_sales_tracking(uuid, uuid, bigint, uuid, text) from anon;
revoke execute on function public.submit_sales_tracking(uuid, uuid, bigint, uuid, text) from authenticated;
grant execute on function public.submit_sales_tracking(uuid, uuid, bigint, uuid, text) to service_role;

revoke execute on function public.submit_supervisor_daily_audit(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb, text) from public;
revoke execute on function public.submit_supervisor_daily_audit(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb, text) from anon;
revoke execute on function public.submit_supervisor_daily_audit(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb, text) from authenticated;
grant execute on function public.submit_supervisor_daily_audit(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb, text) to service_role;

revoke execute on function public.update_branch_purchase_log_payment_status(uuid, uuid, uuid, text, text) from public;
revoke execute on function public.update_branch_purchase_log_payment_status(uuid, uuid, uuid, text, text) from anon;
revoke execute on function public.update_branch_purchase_log_payment_status(uuid, uuid, uuid, text, text) from authenticated;
grant execute on function public.update_branch_purchase_log_payment_status(uuid, uuid, uuid, text, text) to service_role;

revoke execute on function public.update_internal_admin_branch_logo(uuid, uuid, uuid, text) from public;
revoke execute on function public.update_internal_admin_branch_logo(uuid, uuid, uuid, text) from anon;
revoke execute on function public.update_internal_admin_branch_logo(uuid, uuid, uuid, text) from authenticated;
grant execute on function public.update_internal_admin_branch_logo(uuid, uuid, uuid, text) to service_role;

revoke execute on function public.update_internal_admin_organization(uuid, uuid, text, text) from public;
revoke execute on function public.update_internal_admin_organization(uuid, uuid, text, text) from anon;
revoke execute on function public.update_internal_admin_organization(uuid, uuid, text, text) from authenticated;
grant execute on function public.update_internal_admin_organization(uuid, uuid, text, text) to service_role;

revoke execute on function public.update_internal_admin_organization_logo(uuid, uuid, text) from public;
revoke execute on function public.update_internal_admin_organization_logo(uuid, uuid, text) from anon;
revoke execute on function public.update_internal_admin_organization_logo(uuid, uuid, text) from authenticated;
grant execute on function public.update_internal_admin_organization_logo(uuid, uuid, text) to service_role;

revoke execute on function public.update_internal_admin_supervisor_profile(uuid, uuid, uuid, text, text, text, text, text, text, date) from public;
revoke execute on function public.update_internal_admin_supervisor_profile(uuid, uuid, uuid, text, text, text, text, text, text, date) from anon;
revoke execute on function public.update_internal_admin_supervisor_profile(uuid, uuid, uuid, text, text, text, text, text, text, date) from authenticated;
grant execute on function public.update_internal_admin_supervisor_profile(uuid, uuid, uuid, text, text, text, text, text, text, date) to service_role;

revoke execute on function public.update_managed_branch_shift(uuid, uuid, uuid, uuid, text, time without time zone, time without time zone, boolean) from public;
revoke execute on function public.update_managed_branch_shift(uuid, uuid, uuid, uuid, text, time without time zone, time without time zone, boolean) from anon;
revoke execute on function public.update_managed_branch_shift(uuid, uuid, uuid, uuid, text, time without time zone, time without time zone, boolean) from authenticated;
grant execute on function public.update_managed_branch_shift(uuid, uuid, uuid, uuid, text, time without time zone, time without time zone, boolean) to service_role;

revoke execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, boolean) from public;
revoke execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, boolean) from anon;
revoke execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, boolean) from authenticated;
grant execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, boolean) to service_role;

revoke execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid, boolean) from public;
revoke execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid, boolean) from anon;
revoke execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid, boolean) from authenticated;
grant execute on function public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid, boolean) to service_role;

revoke execute on function public.update_operational_team_staff(uuid, uuid, uuid, text, text, text[], text, text, text, text, date, text, text) from public;
revoke execute on function public.update_operational_team_staff(uuid, uuid, uuid, text, text, text[], text, text, text, text, date, text, text) from anon;
revoke execute on function public.update_operational_team_staff(uuid, uuid, uuid, text, text, text[], text, text, text, text, date, text, text) from authenticated;
grant execute on function public.update_operational_team_staff(uuid, uuid, uuid, text, text, text[], text, text, text, text, date, text, text) to service_role;

revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[]) from public;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[]) from anon;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[]) from authenticated;
grant execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[]) to service_role;

revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text) from public;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text) from anon;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text) from authenticated;
grant execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text) to service_role;

revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text, text, date, text, text) from public;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text, text, date, text, text) from anon;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text, text, date, text, text) from authenticated;
grant execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text, text, date, text, text) to service_role;

revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, uuid, text[]) from public;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, uuid, text[]) from anon;
revoke execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, uuid, text[]) from authenticated;
grant execute on function public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, uuid, text[]) to service_role;

