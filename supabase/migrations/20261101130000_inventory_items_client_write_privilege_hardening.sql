begin;

-- Production drift granted direct browser-role writes even though every
-- Inventory Items mutation is mediated by service-role-only SECURITY DEFINER
-- RPCs. Remove only the confirmed table-write privileges.
do $prerequisites$
declare
  target_table regclass;
  target_role oid;
  target_function regprocedure;
  delete_function regprocedure;
begin
  if pg_catalog.to_regrole('anon') is null
    or pg_catalog.to_regrole('authenticated') is null
    or pg_catalog.to_regrole('service_role') is null
  then
    raise exception 'Inventory Items privilege roles are missing' using errcode='42704';
  end if;

  foreach target_table in array array[
    pg_catalog.to_regclass('public.inventory_items_reports'),
    pg_catalog.to_regclass('public.inventory_item_usage_items'),
    pg_catalog.to_regclass('public.inventory_item_usage_day_values')
  ] loop
    if target_table is null then
      raise exception 'Inventory Items privilege target table is missing' using errcode='42P01';
    end if;
    if not (select relation.relrowsecurity from pg_catalog.pg_class relation where relation.oid=target_table) then
      raise exception 'Inventory Items privilege target does not enforce RLS: %',target_table using errcode='55000';
    end if;
  end loop;

  if exists(
    select 1
    from pg_catalog.pg_policy policy
    where policy.polrelid in(
      'public.inventory_items_reports'::regclass,
      'public.inventory_item_usage_day_values'::regclass
    ) and policy.polcmd in('*'::"char",'a'::"char",'w'::"char",'d'::"char")
  ) then
    raise exception 'Inventory Items client write-policy baseline drifted' using errcode='55000';
  end if;

  if exists(
    select 1
    from pg_catalog.pg_attribute attribute
    join pg_catalog.pg_class relation on relation.oid=attribute.attrelid
    join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
    cross join lateral pg_catalog.aclexplode(attribute.attacl) acl
    join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
    where namespace.nspname='public'
      and relation.relname in('inventory_items_reports','inventory_item_usage_day_values')
      and grantee.rolname in('anon','authenticated')
      and acl.privilege_type in('INSERT','UPDATE')
  ) then
    raise exception 'Inventory Items client column-write grants require separate remediation' using errcode='55000';
  end if;

  if exists(
    select 1
    from (values ('anon'::name),('authenticated'::name)) expected(role_name)
    join pg_catalog.pg_roles role on role.rolname=expected.role_name
    where role.rolsuper or role.rolbypassrls
      or pg_catalog.pg_has_role(role.oid,
        (select relation.relowner from pg_catalog.pg_class relation
         where relation.oid='public.inventory_items_reports'::regclass),'USAGE')
      or pg_catalog.pg_has_role(role.oid,
        (select relation.relowner from pg_catalog.pg_class relation
         where relation.oid='public.inventory_item_usage_day_values'::regclass),'USAGE')
  ) then
    raise exception 'Inventory Items client role bypasses the expected RLS boundary' using errcode='55000';
  end if;

  foreach target_function in array array[
    pg_catalog.to_regprocedure('public.get_inventory_items_current_state(uuid,uuid,date)'),
    pg_catalog.to_regprocedure('public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'),
    pg_catalog.to_regprocedure('public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)')
  ] loop
    if target_function is null
      or not (select procedure.prosecdef from pg_catalog.pg_proc procedure where procedure.oid=target_function)
      or not pg_catalog.has_function_privilege('service_role',target_function,'EXECUTE')
    then
      raise exception 'Inventory Items service-role RPC contract is missing' using errcode='42883';
    end if;
  end loop;

  if pg_catalog.num_nonnulls(
      pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)'),
      pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)')
    )<>1
  then
    raise exception 'Inventory Items delete RPC state is missing or ambiguous' using errcode='42883';
  end if;
  delete_function:=coalesce(
    pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)'),
    pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)')
  );
  if not (select procedure.prosecdef from pg_catalog.pg_proc procedure where procedure.oid=delete_function)
    or not pg_catalog.has_function_privilege('service_role',delete_function,'EXECUTE')
  then
    raise exception 'Inventory Items delete service-role RPC contract is missing' using errcode='42883';
  end if;

  if pg_catalog.has_table_privilege('anon','public.inventory_item_usage_items','INSERT')
    or pg_catalog.has_table_privilege('anon','public.inventory_item_usage_items','UPDATE')
    or pg_catalog.has_table_privilege('anon','public.inventory_item_usage_items','DELETE')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_items','INSERT')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_items','UPDATE')
    or pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_items','DELETE')
  then
    raise exception 'Unexpected direct client writes exist on inventory_item_usage_items' using errcode='55000';
  end if;
end
$prerequisites$;

revoke insert,update,delete
  on table public.inventory_items_reports,public.inventory_item_usage_day_values
  from anon,authenticated;

do $postconditions$
declare
  target_function regprocedure;
  delete_function regprocedure;
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
  then
    raise exception 'Inventory Items client write privileges remain after remediation' using errcode='55000';
  end if;

  foreach target_function in array array[
    'public.get_inventory_items_current_state(uuid,uuid,date)'::regprocedure,
    'public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'::regprocedure,
    'public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)'::regprocedure
  ] loop
    if not pg_catalog.has_function_privilege('service_role',target_function,'EXECUTE') then
      raise exception 'Inventory Items service-role RPC access changed' using errcode='55000';
    end if;
  end loop;
  delete_function:=coalesce(
    pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)'),
    pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)')
  );
  if delete_function is null
    or not pg_catalog.has_function_privilege('service_role',delete_function,'EXECUTE')
  then
    raise exception 'Inventory Items delete service-role RPC access changed' using errcode='55000';
  end if;
end
$postconditions$;

commit;
