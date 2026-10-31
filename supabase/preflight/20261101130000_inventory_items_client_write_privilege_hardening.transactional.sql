-- Supabase SQL Editor-compatible rollback-only preflight.
-- The REVOKE is exercised only inside this transaction and is rolled back.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create temporary table inventory_privilege_preflight_baseline on commit drop as
select
  pg_catalog.has_function_privilege('service_role','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE') state_execute,
  pg_catalog.has_function_privilege('service_role','public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)','EXECUTE') save_execute,
  pg_catalog.has_function_privilege('service_role','public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)','EXECUTE') submit_execute,
  pg_catalog.has_function_privilege('service_role','public.delete_inventory_item_usage_item(uuid,uuid,uuid)','EXECUTE') delete_execute,
  (select count(*) from public.inventory_items_reports) report_count,
  (select count(*) from public.inventory_item_usage_items) item_count,
  (select count(*) from public.inventory_item_usage_day_values) day_value_count;

do $prerequisites$
begin
  if pg_catalog.to_regrole('anon') is null
    or pg_catalog.to_regrole('authenticated') is null
    or pg_catalog.to_regrole('service_role') is null
    or pg_catalog.to_regclass('public.inventory_items_reports') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_items') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_day_values') is null
  then raise exception 'Inventory Items privilege prerequisites are missing' using errcode='42883'; end if;

  if exists(
    select 1 from pg_catalog.pg_policy policy
    where policy.polrelid in('public.inventory_items_reports'::regclass,'public.inventory_item_usage_day_values'::regclass)
      and policy.polcmd in('*'::"char",'a'::"char",'w'::"char",'d'::"char")
  ) then raise exception 'Inventory Items write-policy baseline drifted' using errcode='55000'; end if;

  if exists(
    select 1 from pg_catalog.pg_attribute attribute
    join pg_catalog.pg_class relation on relation.oid=attribute.attrelid
    join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
    cross join lateral pg_catalog.aclexplode(attribute.attacl) acl
    join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
    where namespace.nspname='public'
      and relation.relname in('inventory_items_reports','inventory_item_usage_day_values')
      and grantee.rolname in('anon','authenticated')
      and acl.privilege_type in('INSERT','UPDATE')
  ) then raise exception 'Inventory Items column grants require separate remediation' using errcode='55000'; end if;

  if not (select bool_and(relation.relrowsecurity)
    from pg_catalog.pg_class relation
    where relation.oid in(
      'public.inventory_items_reports'::regclass,
      'public.inventory_item_usage_items'::regclass,
      'public.inventory_item_usage_day_values'::regclass
    ))
  then raise exception 'Inventory Items RLS baseline drifted' using errcode='55000'; end if;

  if not (select state_execute and save_execute and submit_execute and delete_execute
    from inventory_privilege_preflight_baseline)
  then raise exception 'Inventory Items service-role RPC access is missing' using errcode='55000'; end if;
end
$prerequisites$;

revoke insert,update,delete
  on table public.inventory_items_reports,public.inventory_item_usage_day_values
  from anon,authenticated;

do $assertions$
begin
  if pg_catalog.has_table_privilege('anon','public.inventory_items_reports','INSERT')
    or pg_catalog.has_table_privilege('anon','public.inventory_items_reports','UPDATE')
    or pg_catalog.has_table_privilege('anon','public.inventory_items_reports','DELETE')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_items_reports','INSERT')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_items_reports','UPDATE')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_items_reports','DELETE')
    or pg_catalog.has_table_privilege('anon','public.inventory_item_usage_day_values','INSERT')
    or pg_catalog.has_table_privilege('anon','public.inventory_item_usage_day_values','UPDATE')
    or pg_catalog.has_table_privilege('anon','public.inventory_item_usage_day_values','DELETE')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_day_values','INSERT')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_day_values','UPDATE')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_day_values','DELETE')
  then raise exception 'client table-write privilege survived REVOKE' using errcode='55000'; end if;

  if (select report_count<>(select count(*) from public.inventory_items_reports)
      or item_count<>(select count(*) from public.inventory_item_usage_items)
      or day_value_count<>(select count(*) from public.inventory_item_usage_day_values)
      or state_execute is distinct from pg_catalog.has_function_privilege('service_role','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE')
      or save_execute is distinct from pg_catalog.has_function_privilege('service_role','public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)','EXECUTE')
      or submit_execute is distinct from pg_catalog.has_function_privilege('service_role','public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)','EXECUTE')
      or delete_execute is distinct from pg_catalog.has_function_privilege('service_role','public.delete_inventory_item_usage_item(uuid,uuid,uuid)','EXECUTE')
    from inventory_privilege_preflight_baseline)
  then raise exception 'Inventory data or service-role RPC access changed' using errcode='55000'; end if;
end
$assertions$;

rollback;
