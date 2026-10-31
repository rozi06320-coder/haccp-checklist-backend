-- SELECT-only Production post-migration verification for
-- 20261101120000_inventory_item_usage_populated_row_delete.sql.
--
-- This script reads PostgreSQL catalogs and function definitions only.
-- It does NOT mutate, delete, or modify any Inventory data or database objects.
--
-- Expected state:
-- 1. New four-argument delete RPC exists.
-- 2. Legacy three-argument delete RPC is absent.
-- 3. service_role has EXECUTE on four-argument RPC; anon/authenticated/PUBLIC are denied.
-- 4. SECURITY DEFINER, search_path='', and exact signature arguments verified.
-- 5. protect_inventory_usage_item trigger enforces one-way tombstone contract.
-- 6. protect_inventory_usage_day_value trigger enforces immutable historical day values.
-- 7. Supervisor state, Manager report, and Manager summary projections exclude deleted items.
-- 8. Direct client table writes remain denied on all inventory tables.
-- 9. Carry-forward compatibility helper and caller remain intact.
-- 10. No unexpected object collision or partial installation.

with
delete_proc as (
  select procedure.oid, procedure.prosecdef, procedure.proconfig,
    coalesce(pg_catalog.has_function_privilege('service_role', procedure.oid, 'EXECUTE'), false) as service_execute,
    coalesce(pg_catalog.has_function_privilege('anon', procedure.oid, 'EXECUTE'), false) as anon_execute,
    coalesce(pg_catalog.has_function_privilege('authenticated', procedure.oid, 'EXECUTE'), false) as authenticated_execute,
    exists(
      select 1 from pg_catalog.aclexplode(coalesce(procedure.proacl, '{}'::aclitem[])) acl
      where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
    ) as public_execute,
    pg_catalog.pg_get_functiondef(procedure.oid) as definition
  from pg_catalog.pg_proc procedure
  where procedure.oid = pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)')
),
legacy_delete_proc as (
  select procedure.oid
  from pg_catalog.pg_proc procedure
  where procedure.oid = pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)')
),
all_delete_overloads as (
  select procedure.oid, procedure.oid::pg_catalog.regprocedure::text as signature
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'public'
    and procedure.proname = 'delete_inventory_item_usage_item'
),
item_guard_proc as (
  select procedure.oid, procedure.prosecdef, procedure.proconfig,
    pg_catalog.pg_get_functiondef(procedure.oid) as definition
  from pg_catalog.pg_proc procedure
  where procedure.oid = pg_catalog.to_regprocedure('private.protect_inventory_usage_item()')
),
day_guard_proc as (
  select procedure.oid, procedure.prosecdef, procedure.proconfig,
    pg_catalog.pg_get_functiondef(procedure.oid) as definition
  from pg_catalog.pg_proc procedure
  where procedure.oid = pg_catalog.to_regprocedure('private.protect_inventory_usage_day_value()')
),
triggers_check as (
  select
    exists(
      select 1 from pg_catalog.pg_trigger trigger_row
      where trigger_row.tgrelid = 'public.inventory_item_usage_items'::regclass
        and trigger_row.tgname = 'inventory_item_usage_items_immutable'
        and not trigger_row.tgisinternal
    ) as item_trigger_exists,
    exists(
      select 1 from pg_catalog.pg_trigger trigger_row
      where trigger_row.tgrelid = 'public.inventory_item_usage_day_values'::regclass
        and trigger_row.tgname = 'inventory_item_usage_day_values_immutable'
        and not trigger_row.tgisinternal
    ) as day_trigger_exists
),
projections as (
  select
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('private.inventory_items_state_json(uuid,uuid,date)')) as supervisor_state,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)')) as manager_reports,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('public.get_managed_operations_summary(uuid,uuid,uuid,date)')) as manager_summary
),
carry_forward as (
  select procedure.oid, procedure.prosecdef, procedure.proconfig,
    pg_catalog.pg_get_functiondef(procedure.oid) as definition
  from pg_catalog.pg_proc procedure
  where procedure.oid = pg_catalog.to_regprocedure('private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)')
),
client_writes as (
  select
    pg_catalog.has_table_privilege('anon', 'public.inventory_items_reports', 'INSERT')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_items_reports', 'UPDATE')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_items_reports', 'DELETE')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_items_reports', 'INSERT')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_items_reports', 'UPDATE')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_items_reports', 'DELETE')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_item_usage_items', 'INSERT')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_item_usage_items', 'UPDATE')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_item_usage_items', 'DELETE')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_item_usage_items', 'INSERT')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_item_usage_items', 'UPDATE')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_item_usage_items', 'DELETE')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_item_usage_day_values', 'INSERT')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_item_usage_day_values', 'UPDATE')
    or pg_catalog.has_table_privilege('anon', 'public.inventory_item_usage_day_values', 'DELETE')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_item_usage_day_values', 'INSERT')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_item_usage_day_values', 'UPDATE')
    or pg_catalog.has_table_privilege('authenticated', 'public.inventory_item_usage_day_values', 'DELETE') as direct_client_writes_exist
),
checks(check_name, status, evidence, mandatory, sort_order) as (
  -- 1. Four-argument RPC exists with unique overload
  select 'new_four_argument_delete_rpc',
    case when count(*) = 1 then 'PASS' else 'BLOCKED' end,
    'public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb) exists', true, 10
  from delete_proc

  union all
  select 'unique_delete_rpc_overload',
    case when count(*) = 1 and max(signature) = 'delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)'
      then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(signature)::text, '[]'), true, 20
  from all_delete_overloads

  -- 2. Legacy three-argument RPC absent
  union all
  select 'legacy_three_argument_delete_absent',
    case when count(*) = 0 then 'PASS' else 'BLOCKED' end,
    'public.delete_inventory_item_usage_item(uuid,uuid,uuid) dropped', true, 30
  from legacy_delete_proc

  -- 3. Authorization on 4-arg RPC
  union all
  select 'delete_rpc_service_role_execute_only',
    case when count(*) = 1 and bool_and(service_execute and not anon_execute and not authenticated_execute and not public_execute)
      then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'service_execute', service_execute,
      'anon_execute', anon_execute,
      'authenticated_execute', authenticated_execute,
      'public_execute', public_execute
    ))::text, '[]'), true, 40
  from delete_proc

  -- 4. SECURITY DEFINER & empty search_path on delete RPC
  union all
  select 'delete_rpc_security_definer_and_search_path',
    case when count(*) = 1 and bool_and(prosecdef and proconfig @> array['search_path=""'])
      then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'security_definer', prosecdef,
      'config', proconfig
    ))::text, '[]'), true, 50
  from delete_proc

  -- 5. Delete RPC function definition contracts
  union all
  select 'delete_rpc_runtime_contracts',
    case when count(*) = 1 and bool_and(
      definition like '%private.inventory_items_actor_context%'
      and definition like '%private.lock_inventory_items_month%'
      and definition like '%(select count(*) from pg_catalog.jsonb_object_keys(expected_usage))>31%'
      and definition like '%private.inventory_items_numeric_field%'
      and definition like '%Item Usage changed after confirmation%'
      and definition like '%private.inventory_items_state_json%'
      and definition not like '%jsonb_object_length%'
    ) then 'PASS' else 'BLOCKED' end,
    'actor context, month lock, bounded key check, numeric validation, stale snapshot conflict, and state return', true, 60
  from delete_proc

  -- 6. Item usage tombstone trigger contract
  union all
  select 'item_tombstone_trigger_contract',
    case when count(*) = 1 and bool_and(
      prosecdef and proconfig @> array['search_path=""']
      and definition like '%new.deleted_at is not null%'
      and definition like '%new.deleted_by_user_id is not null%'
      and definition like '%old.deleted_at is null%'
      and definition like '%private.inventory_items_actor_context%'
      and definition like '%saved inventory item is immutable%'
    ) and (select item_trigger_exists from triggers_check)
      then 'PASS' else 'BLOCKED' end,
    'protect_inventory_usage_item enforces irreversible supervisor tombstone in draft month', true, 70
  from item_guard_proc

  -- 7. Day value immutability trigger contract
  union all
  select 'day_value_immutability_trigger_contract',
    case when count(*) = 1 and bool_and(
      prosecdef and proconfig @> array['search_path=""']
      and definition like '%saved inventory item day is immutable%'
    ) and (select day_trigger_exists from triggers_check)
      then 'PASS' else 'BLOCKED' end,
    'protect_inventory_usage_day_value enforces append-only immutability', true, 80
  from day_guard_proc

  -- 8. Projections exclude deleted items
  union all
  select 'projections_exclude_deleted_items',
    case when supervisor_state like '%item.deleted_at is null%'
      and manager_reports like '%item.deleted_at is null%'
      and manager_summary like '%item.deleted_at is null%'
      then 'PASS' else 'BLOCKED' end,
    'supervisor state, manager reports, and operations summary filter item.deleted_at is null', true, 90
  from projections

  -- 9. Direct client table writes remain denied
  union all
  select 'direct_client_writes_denied',
    case when not direct_client_writes_exist then 'PASS' else 'BLOCKED' end,
    'anon and authenticated denied INSERT/UPDATE/DELETE on reports, items, and day values', true, 100
  from client_writes

  -- 10. Carry-forward compatibility intact
  union all
  select 'carry_forward_compatibility_intact',
    case when count(*) = 1 and bool_and(
      prosecdef and proconfig @> array['search_path=""']
      and (select count(*) from pg_catalog.regexp_matches(definition, $regex$source_item\.deleted_at\s+is\s+null$regex$, 'gi')) >= 2
      and definition ~* $regex$where\s+target_item\.report_id\s*=\s*target_report_id$regex$
      and definition ~* $regex$row_number\s*\(\s*\)\s+over[\s\S]*partition\s+by[\s\S]*group_name[\s\S]*item_name$regex$
      and definition ~* $regex$where\s+source_item\.identity_rank\s*=\s*1$regex$
    ) and (select supervisor_state from projections) like '%private.inventory_items_carry_forward_items_json%'
      then 'PASS' else 'BLOCKED' end,
    'helper restored, tombstone exclusion, target history guard, normalized identity deduplication, called by state_json', true, 110
  from carry_forward
),
results as (
  select check_name, status, evidence, sort_order from checks
  union all
  select 'overall_readiness',
    case when not exists(select 1 from checks where mandatory and status <> 'PASS') then 'PASS' else 'BLOCKED' end,
    case when not exists(select 1 from checks where mandatory and status <> 'PASS')
      then 'Migration 20261101120000 post-apply contract verified: all 10 checks PASS'
      else 'Post-apply verification failed: one or more checks BLOCKED' end,
    1000
)
select check_name, status, evidence
from results
order by sort_order, check_name;
