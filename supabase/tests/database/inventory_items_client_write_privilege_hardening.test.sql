begin;
select plan(13);

select ok(not pg_catalog.has_table_privilege('anon','public.inventory_items_reports','INSERT')
  and not pg_catalog.has_table_privilege('anon','public.inventory_items_reports','UPDATE')
  and not pg_catalog.has_table_privilege('anon','public.inventory_items_reports','DELETE'),
  'anon has no direct report write privileges');
select ok(not pg_catalog.has_table_privilege('authenticated','public.inventory_items_reports','INSERT')
  and not pg_catalog.has_table_privilege('authenticated','public.inventory_items_reports','UPDATE')
  and not pg_catalog.has_table_privilege('authenticated','public.inventory_items_reports','DELETE'),
  'authenticated has no direct report write privileges');
select ok(not pg_catalog.has_table_privilege('anon','public.inventory_item_usage_day_values','INSERT')
  and not pg_catalog.has_table_privilege('anon','public.inventory_item_usage_day_values','UPDATE')
  and not pg_catalog.has_table_privilege('anon','public.inventory_item_usage_day_values','DELETE'),
  'anon has no direct Item Usage day-value write privileges');
select ok(not pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_day_values','INSERT')
  and not pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_day_values','UPDATE')
  and not pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_day_values','DELETE'),
  'authenticated has no direct Item Usage day-value write privileges');
select ok(not pg_catalog.has_table_privilege('anon','public.inventory_item_usage_items','INSERT')
  and not pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_items','INSERT'),
  'unrelated Item Usage parent direct-write boundary remains closed');

select is((select count(*) from pg_catalog.pg_attribute attribute
  join pg_catalog.pg_class relation on relation.oid=attribute.attrelid
  join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
  cross join lateral pg_catalog.aclexplode(attribute.attacl) acl
  join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
  where namespace.nspname='public'
    and relation.relname in('inventory_items_reports','inventory_item_usage_day_values')
    and grantee.rolname in('anon','authenticated')
    and acl.privilege_type in('INSERT','UPDATE')),0::bigint,
  'no client column-write grants bypass the table-level revocation');
select ok((select bool_and(relation.relrowsecurity) from pg_catalog.pg_class relation
  where relation.oid in('public.inventory_items_reports'::regclass,
    'public.inventory_item_usage_items'::regclass,
    'public.inventory_item_usage_day_values'::regclass)),
  'RLS remains enabled on all Inventory Items persistence tables');
select is((select count(*) from pg_catalog.pg_policy policy
  where policy.polrelid in('public.inventory_items_reports'::regclass,
    'public.inventory_item_usage_day_values'::regclass)
    and policy.polcmd in('*'::"char",'a'::"char",'w'::"char",'d'::"char")),0::bigint,
  'no direct client write policy was added');

select ok(pg_catalog.has_function_privilege('service_role',
  'public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE'),
  'service_role retains current-state RPC access');
select ok(pg_catalog.has_function_privilege('service_role',
  'public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)','EXECUTE'),
  'service_role retains draft RPC access');
select ok(pg_catalog.has_function_privilege('service_role',
  'public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)','EXECUTE'),
  'service_role retains submit RPC access');
select ok(pg_catalog.has_function_privilege('service_role',
  'public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)','EXECUTE'),
  'service_role retains post-delete-migration RPC access');
select ok(not pg_catalog.has_function_privilege('anon',
  'public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)','EXECUTE')
  and not pg_catalog.has_function_privilege('authenticated',
  'public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)','EXECUTE'),
  'browser roles cannot execute the Item Usage delete RPC directly');

select * from finish();
rollback;
