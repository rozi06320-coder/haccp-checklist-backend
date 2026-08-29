begin;
select plan(12);

create temp table backend_only_mutation_rpc(signature text primary key) on commit drop;
insert into backend_only_mutation_rpc(signature) values
  ('public.authorize_phase4a_evidence_read(uuid, uuid)'),
  ('public.authorize_phase4a_evidence_set(uuid, uuid, text, uuid[])'),
  ('public.authorize_phase4a_evidence_upload(uuid, uuid, text, text)'),
  ('public.confirm_operational_team_staff_import(uuid, uuid, uuid, uuid)'),
  ('public.create_branch_purchase_log(uuid, uuid, jsonb)'),
  ('public.create_branch_supplier(uuid, uuid, jsonb)'),
  ('public.create_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer)'),
  ('public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text)'),
  ('public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[])'),
  ('public.create_internal_admin_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer)'),
  ('public.create_internal_admin_operational_team(uuid, uuid, uuid, text, text, uuid, uuid, jsonb)'),
  ('public.create_internal_admin_organization(uuid, text)'),
  ('public.create_internal_admin_organization(uuid, text, text)'),
  ('public.create_maintenance_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer)'),
  ('public.create_managed_branch_shift(uuid, uuid, uuid, text, time without time zone, time without time zone)'),
  ('public.create_managed_supervisor_team(uuid, uuid, uuid, uuid)'),
  ('public.create_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid)'),
  ('public.create_operational_team_staff(uuid, uuid, uuid, text, text[], text, text, text, text, date, text, text)'),
  ('public.create_operational_team_staff_import_preview(uuid, uuid, uuid, jsonb)'),
  ('public.create_sales_tracking_online_order_provider(uuid, uuid, text)'),
  ('public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text)'),
  ('public.create_supervisor_operational_staff(uuid, uuid, text, text[])'),
  ('public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text)'),
  ('public.create_supervisor_operational_staff(uuid, uuid, text, text[], text, text, text, date, text, text)'),
  ('public.create_supervisor_operational_staff(uuid, uuid, text, uuid, text[])'),
  ('public.create_supervisor_owned_operational_team(uuid, uuid, text)'),
  ('public.deactivate_internal_admin_branch(uuid, uuid, uuid)'),
  ('public.deactivate_internal_admin_organization(uuid, uuid)'),
  ('public.deactivate_internal_admin_supervisor(uuid, uuid, uuid)'),
  ('public.deactivate_maintenance_access_user(uuid, uuid, uuid)'),
  ('public.deactivate_maintenance_user(uuid, uuid, uuid)'),
  ('public.deactivate_organization_manager(uuid, uuid, uuid)'),
  ('public.finalize_password_change(uuid)'),
  ('public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text)'),
  ('public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text)'),
  ('public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text)'),
  ('public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text)'),
  ('public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[])'),
  ('public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text)'),
  ('public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb)'),
  ('public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb, text, text, text, text, date)'),
  ('public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[])'),
  ('public.move_operational_staff_team(uuid, uuid, uuid, uuid, uuid)'),
  ('public.reactivate_internal_admin_branch(uuid, uuid, uuid)'),
  ('public.reactivate_internal_admin_organization(uuid, uuid)'),
  ('public.reactivate_internal_admin_supervisor(uuid, uuid, uuid)'),
  ('public.reactivate_maintenance_user(uuid, uuid, uuid)'),
  ('public.reactivate_organization_manager(uuid, uuid, uuid)'),
  ('public.register_maintenance_push_subscription(uuid, text, text, text, text)'),
  ('public.register_phase4a_evidence_upload(uuid, uuid, text, text, uuid, text, text, bigint, text)'),
  ('public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text)'),
  ('public.save_inventory_items_draft(uuid, uuid, jsonb, jsonb)'),
  ('public.save_managed_annual_evaluation_draft(uuid, uuid, uuid, integer, text, uuid, uuid, bigint, jsonb)'),
  ('public.save_oil_tracking_draft(uuid, uuid, bigint, jsonb)'),
  ('public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text)'),
  ('public.save_operational_team_hygiene_draft(uuid, uuid, uuid, bigint, jsonb)'),
  ('public.save_phase4a_draft(uuid, uuid, text, bigint, jsonb)'),
  ('public.save_phase4a_hygiene_draft(uuid, uuid, jsonb)'),
  ('public.save_sales_tracking_draft(uuid, uuid, bigint, text, jsonb, jsonb)'),
  ('public.save_supervisor_daily_audit_draft(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb)'),
  ('public.set_operational_team_staff_duty(uuid, uuid, uuid, date, text)'),
  ('public.set_supervisor_operational_duty(uuid, uuid, uuid, date, text)'),
  ('public.start_managed_operational_staff_supervisor_training(uuid, uuid, uuid)'),
  ('public.store_daily_audit_pin(uuid, uuid, bytea, bytea, smallint, integer, integer, integer)'),
  ('public.store_internal_admin_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer)'),
  ('public.store_organization_manager_daily_audit_pin(uuid, uuid, uuid, bytea, bytea, bytea, smallint, integer, integer, integer)'),
  ('public.submit_inventory_items(uuid, uuid, uuid, text, jsonb, jsonb)'),
  ('public.submit_managed_annual_evaluation(uuid, uuid, uuid, bigint)'),
  ('public.submit_oil_tracking_closing(uuid, uuid, bigint, uuid, text, jsonb)'),
  ('public.submit_oil_tracking_opening(uuid, uuid, bigint, uuid, text, jsonb)'),
  ('public.submit_operational_team_hygiene(uuid, uuid, uuid, uuid, text, jsonb)'),
  ('public.submit_phase4a_hygiene(uuid, uuid, uuid, text, jsonb)'),
  ('public.submit_phase4a_opening(uuid, uuid, text, bigint, uuid, text, jsonb)'),
  ('public.submit_sales_tracking(uuid, uuid, bigint, uuid, text)'),
  ('public.submit_supervisor_daily_audit(uuid, uuid, date, bigint, text, uuid, text, uuid, jsonb, text)'),
  ('public.update_branch_purchase_log_payment_status(uuid, uuid, uuid, text, text)'),
  ('public.update_internal_admin_branch_logo(uuid, uuid, uuid, text)'),
  ('public.update_internal_admin_organization(uuid, uuid, text, text)'),
  ('public.update_internal_admin_organization_logo(uuid, uuid, text)'),
  ('public.update_internal_admin_supervisor_profile(uuid, uuid, uuid, text, text, text, text, text, text, date)'),
  ('public.update_managed_branch_shift(uuid, uuid, uuid, uuid, text, time without time zone, time without time zone, boolean)'),
  ('public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, boolean)'),
  ('public.update_managed_supervisor_team(uuid, uuid, uuid, uuid, uuid, boolean)'),
  ('public.update_operational_team_staff(uuid, uuid, uuid, text, text, text[], text, text, text, text, date, text, text)'),
  ('public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[])'),
  ('public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text)'),
  ('public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, text[], text, text, text, date, text, text)'),
  ('public.update_supervisor_operational_staff(uuid, uuid, uuid, text, text, uuid, text[])');

select is((select count(*)::integer from backend_only_mutation_rpc where has_function_privilege('anon', signature, 'execute')), 0, 'anon cannot execute backend-only mutation RPCs');
select is((select count(*)::integer from backend_only_mutation_rpc where has_function_privilege('authenticated', signature, 'execute')), 0, 'authenticated cannot execute backend-only mutation RPCs');
select is((select count(*)::integer from backend_only_mutation_rpc where not has_function_privilege('service_role', signature, 'execute')), 0, 'service_role can execute backend-only mutation RPCs');

select is(has_function_privilege('anon', 'public.save_oil_tracking_draft(uuid,uuid,bigint,jsonb)', 'execute'), false, 'anon cannot execute Oil draft RPC');
select is(has_function_privilege('authenticated', 'public.submit_phase4a_opening(uuid,uuid,text,bigint,uuid,text,jsonb)', 'execute'), false, 'authenticated cannot execute opening submit RPC');
select is(has_function_privilege('authenticated', 'public.submit_operational_team_hygiene(uuid,uuid,uuid,uuid,text,jsonb)', 'execute'), false, 'authenticated cannot execute hygiene submit RPC');
select is(has_function_privilege('authenticated', 'public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb)', 'execute'), false, 'authenticated cannot execute Sales draft RPC');
select is(has_function_privilege('authenticated', 'public.submit_supervisor_daily_audit(uuid,uuid,date,bigint,text,uuid,text,uuid,jsonb,text)', 'execute'), false, 'authenticated cannot execute Daily Audit submit RPC');
select is(has_function_privilege('authenticated', 'public.update_internal_admin_organization(uuid,uuid,text,text)', 'execute'), false, 'authenticated cannot execute Internal Admin organization update RPC');
select is(has_function_privilege('authenticated', 'public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,text,date,text,text)', 'execute'), false, 'authenticated cannot execute operational staff update RPC');

select is((
  select count(*)::integer
  from pg_catalog.pg_default_acl d
  join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
  cross join pg_catalog.aclexplode(d.defaclacl) acl
  where n.nspname = 'public'
    and d.defaclrole = 'postgres'::regrole
    and d.defaclobjtype = 'f'
    and acl.privilege_type = 'EXECUTE'
    and acl.grantee in (0::oid, 'anon'::regrole, 'authenticated'::regrole)
), 0, 'future public functions do not default EXECUTE to PUBLIC, anon, or authenticated');

select is(has_function_privilege('service_role', 'public.get_phase4a_current_state(uuid,uuid,text)', 'execute'), true, 'representative read RPC remains service-role callable');

select * from finish();
rollback;
