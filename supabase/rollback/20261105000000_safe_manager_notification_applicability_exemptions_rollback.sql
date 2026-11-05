-- Rollback Migration: safe_manager_notification_applicability_exemptions_rollback
-- Reverses migration 20261105000000_safe_manager_notification_applicability_exemptions.sql
-- CRITICAL: Preserves Bakery Riyadh and Central Kitchen sales_tracking_percentage_included = false
-- and oil_tracking_percentage_included = false (exact pre-migration baseline values).

begin;

-- 1. Revert branch-level flags added by migration
update public.branches
set foh_opening_included = true
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id = '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid;

update public.branches
set cold_storage_0200_notification_required = true
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id in (
    'dea33e25-4732-4dcf-96db-010ad917c16c'::uuid,
    '82321e25-25f2-490a-a933-7c15e11c6428'::uuid
  );

-- 2. Restore daily_report_module_applicability back to required = true
perform private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid,'03acf21e-fbca-48d0-955f-5e783d43c23e'::uuid,'sales_tracking',true,'2026-10-27'::date,null);
perform private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid,'03acf21e-fbca-48d0-955f-5e783d43c23e'::uuid,'oil_tracking',true,'2026-10-27'::date,null);
perform private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid,'4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid,'sales_tracking',true,'2026-10-27'::date,null);
perform private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid,'4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid,'oil_tracking',true,'2026-10-27'::date,null);
perform private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid,'4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid,'foh_opening',true,'2026-10-27'::date,null);

-- 3. Restore pre-migration functions from their respective migrations
-- A. private.seed_daily_report_module_applicability (from 20261027103000)
create or replace function private.seed_daily_report_module_applicability(
  p_organization_id uuid,p_branch_id uuid,p_effective_from_business_date date
)
returns void
language plpgsql
security definer
set search_path=''
as $$
begin
  if p_organization_id is null or p_branch_id is null or p_effective_from_business_date is null then
    raise exception 'invalid seed scope' using errcode='22023';
  end if;
  insert into public.daily_report_module_applicability(
    organization_id,branch_id,module_key,requirement_basis,effective_from_business_date,required
  )
  select p_organization_id,p_branch_id,module.module_key,
    case module.module_key
      when'staff_hygiene'then'eligible_operational_staff'
      when'cold_storage'then'eligible_cold_storage_equipment'
      when'oil_tracking'then'eligible_oil_tracking_fryers'
      else'static'end,
    p_effective_from_business_date,true
  from pg_catalog.unnest(array[
    'kitchen_opening','foh_opening','staff_hygiene','daily_audit',
    'cold_storage','oil_tracking','sales_tracking'
  ]::text[]) module(module_key)
  where not exists(select 1 from public.daily_report_module_applicability existing
    where existing.branch_id=p_branch_id and existing.module_key=module.module_key);
end;
$$;

revoke all on function private.seed_daily_report_module_applicability(uuid,uuid,date)
  from public,anon,authenticated,service_role;

-- B. private.enqueue_organization_manager_maintenance_issue (from 20261021130000)
create or replace function private.enqueue_organization_manager_maintenance_issue()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare recipient record;
begin
  if not coalesce(private.organization_manager_push_producer_enabled(new.created_at),false) then
    return new;
  end if;
  for recipient in
    select distinct membership.user_id
    from public.organization_memberships membership
    join public.organizations organization on organization.id=membership.organization_id
    join public.profiles profile on profile.id=membership.user_id
    where membership.organization_id=new.organization_id
      and membership.role='organization_manager'
      and membership.active and organization.active
      and profile.disabled_at is null and not profile.must_change_password
  loop
    perform public.create_organization_manager_notification(
      new.organization_id,recipient.user_id,'maintenance_issue_created','maintenance_issue',
      new.id,'maintenance-issue:'||new.id::text);
  end loop;
  return new;
end;
$$;

revoke all on function private.enqueue_organization_manager_maintenance_issue()
  from public,anon,authenticated,service_role;

commit;
