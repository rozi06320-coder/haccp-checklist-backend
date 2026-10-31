-- SELECT-only Production dependency audit for
-- 20261101120000_inventory_item_usage_populated_row_delete.sql.
--
-- This script reads PostgreSQL catalogs and function definitions only. It does
-- not read Inventory Items business rows, invoke application RPCs, acquire
-- locks, create temporary objects, or write migration history.
--
-- Expected baseline: the legacy three-argument delete RPC exists and the new
-- four-argument RPC does not. Any mixed/partial state is BLOCKED.

with
role_ids as (
  select
    (select oid from pg_catalog.pg_roles where rolname='anon') as anon_oid,
    (select oid from pg_catalog.pg_roles where rolname='authenticated') as authenticated_oid,
    (select oid from pg_catalog.pg_roles where rolname='service_role') as service_role_oid
),
definitions as (
  select
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)')) as legacy_delete,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('private.protect_inventory_usage_item()')) as item_guard,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('private.protect_inventory_usage_day_value()')) as day_guard,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('private.inventory_items_actor_context(uuid,uuid)')) as actor_context,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('private.lock_inventory_items_month(uuid,date)')) as month_lock,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('private.inventory_items_state_json(uuid,uuid,date)')) as supervisor_state,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)')) as manager_reports,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('public.get_managed_operations_summary(uuid,uuid,uuid,date)')) as manager_totals,
    pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)')) as carry_forward
),
client_write_access as (
  select
    relation.relname table_name,
    role_target.role_name,
    relation.relrowsecurity rls_enabled,
    coalesce((
      select pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type)
      from pg_catalog.aclexplode(coalesce(relation.relacl,'{}'::aclitem[])) acl
      where acl.grantee=role_target.role_oid
        and acl.privilege_type in('INSERT','UPDATE','DELETE')
    ),'{}'::text[]) explicit_write_acl,
    coalesce(pg_catalog.has_table_privilege(role_target.role_oid,relation.oid,'INSERT'),false) effective_insert,
    coalesce(pg_catalog.has_table_privilege(role_target.role_oid,relation.oid,'UPDATE'),false) effective_update,
    coalesce(pg_catalog.has_table_privilege(role_target.role_oid,relation.oid,'DELETE'),false) effective_delete,
    coalesce((
      select pg_catalog.array_agg(parent.rolname order by parent.rolname)
      from pg_catalog.pg_roles parent
      where parent.oid<>role_target.role_oid
        and pg_catalog.pg_has_role(role_target.role_oid,parent.oid,'USAGE')
        and (
          pg_catalog.has_table_privilege(parent.oid,relation.oid,'INSERT')
          or pg_catalog.has_table_privilege(parent.oid,relation.oid,'UPDATE')
          or pg_catalog.has_table_privilege(parent.oid,relation.oid,'DELETE')
        )
    ),'{}'::name[]) inherited_write_roles
  from pg_catalog.pg_class relation
  cross join role_ids roles
  cross join lateral (values
    ('anon',roles.anon_oid),('authenticated',roles.authenticated_oid)
  ) role_target(role_name,role_oid)
  where relation.oid in(
    pg_catalog.to_regclass('public.inventory_items_reports'),
    pg_catalog.to_regclass('public.inventory_item_usage_items'),
    pg_catalog.to_regclass('public.inventory_item_usage_day_values')
  )
),
executable_definitions as (
  select source_name,
    pg_catalog.regexp_replace(
      pg_catalog.regexp_replace(
        pg_catalog.regexp_replace(definition,$regex$--[^\r\n]*$regex$,' ','g'),
        $regex$/\*.*?\*/$regex$,' ','gs'
      ),
      $regex$'(?:''|[^'])*'$regex$,' ','g'
    ) definition
  from definitions
  cross join lateral (values
    ('legacy_delete',legacy_delete),('item_guard',item_guard)
  ) source(source_name,definition)
),
schema_references as (
  select executable.source_name,
    pg_catalog.lower(reference_match[1]||'.'||reference_match[2]) reference_name
  from executable_definitions executable
  cross join lateral pg_catalog.regexp_matches(
    executable.definition,$regex$\m(public|private)\.([A-Za-z_][A-Za-z0-9_]*)$regex$,'g'
  ) reference_match
),
unexpected_schema_references as (
  select distinct source_name,reference_name
  from schema_references
  where (source_name='legacy_delete' and reference_name not in(
      'public.delete_inventory_item_usage_item',
      'public.inventory_item_usage_items',
      'public.inventory_items_reports',
      'public.inventory_item_usage_day_values',
      'private.inventory_items_actor_context',
      'private.lock_inventory_items_month',
      'private.inventory_items_state_json'
    ))
    or (source_name='item_guard' and reference_name not in(
      'private.protect_inventory_usage_item',
      'public.inventory_items_reports',
      'public.inventory_item_usage_day_values'
    ))
),
checks(check_name,status,evidence,mandatory) as (
  select 'environment_roles',
    case when anon_oid is not null and authenticated_oid is not null and service_role_oid is not null then 'PASS' else 'BLOCKED' end,
    'anon='||coalesce(anon_oid::text,'missing')||'; authenticated='||coalesce(authenticated_oid::text,'missing')||'; service_role='||coalesce(service_role_oid::text,'missing'),true
  from role_ids

  union all
  select 'baseline_rpc_state',
    case when pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)') is not null
      and pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)') is null
      then 'PASS' else 'BLOCKED' end,
    'legacy_3='||coalesce(pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)')::text,'missing')||
      '; new_4='||coalesce(pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)')::text,'absent'),true

  union all
  select 'required_tables',
    case when pg_catalog.to_regclass('public.inventory_items_reports') is not null
      and pg_catalog.to_regclass('public.inventory_item_usage_items') is not null
      and pg_catalog.to_regclass('public.inventory_item_usage_day_values') is not null then 'PASS' else 'BLOCKED' end,
    'reports='||coalesce(pg_catalog.to_regclass('public.inventory_items_reports')::text,'missing')||
      '; items='||coalesce(pg_catalog.to_regclass('public.inventory_item_usage_items')::text,'missing')||
      '; values='||coalesce(pg_catalog.to_regclass('public.inventory_item_usage_day_values')::text,'missing'),true

  union all
  select 'required_item_columns',case when count(*)=11 then 'PASS' else 'BLOCKED' end,
    count(*)::text||'/11 columns present',true
  from information_schema.columns
  where table_schema='public' and table_name='inventory_item_usage_items'
    and column_name in('id','report_id','usage_month','group_name','item_name','sort_order','created_at','created_by','updated_at','deleted_at','deleted_by_user_id')

  union all
  select 'required_day_value_columns',case when count(*)=7 then 'PASS' else 'BLOCKED' end,
    count(*)::text||'/7 columns present',true
  from information_schema.columns
  where table_schema='public' and table_name='inventory_item_usage_day_values'
    and column_name in('id','item_id','day_number','quantity','created_at','created_by','updated_at')

  union all
  select 'required_report_columns',case when count(*)=7 then 'PASS' else 'BLOCKED' end,
    count(*)::text||'/7 columns present',true
  from information_schema.columns
  where table_schema='public' and table_name='inventory_items_reports'
    and column_name in('id','organization_id','branch_id','inventory_month','state','updated_at','submitted_at')

  union all
  select 'deleted_pair_constraint',
    case when count(*)=1 and bool_and(pg_catalog.pg_get_constraintdef(oid) like '%deleted_at IS NULL%deleted_by_user_id IS NULL%deleted_at IS NOT NULL%deleted_by_user_id IS NOT NULL%') then 'PASS' else 'BLOCKED' end,
    coalesce(max(pg_catalog.pg_get_constraintdef(oid)),'missing'),true
  from pg_catalog.pg_constraint
  where conrelid=pg_catalog.to_regclass('public.inventory_item_usage_items')
    and conname='inventory_item_usage_items_deleted_pair_check'

  union all
  select 'deleted_actor_fk_restrict',
    case when count(*)=1 and bool_and(contype='f' and confdeltype='r') then 'PASS' else 'BLOCKED' end,
    coalesce(max(pg_catalog.pg_get_constraintdef(oid)),'missing'),true
  from pg_catalog.pg_constraint
  where conrelid=pg_catalog.to_regclass('public.inventory_item_usage_items')
    and conname='inventory_item_usage_items_deleted_by_user_id_fkey'

  union all
  select 'day_value_fk_contract',
    case when count(*)=1 and bool_and(contype='f' and confrelid=pg_catalog.to_regclass('public.inventory_item_usage_items') and confdeltype='c') then 'PASS' else 'BLOCKED' end,
    coalesce(max(pg_catalog.pg_get_constraintdef(oid)),'missing')||'; hard parent DELETE must remain trigger-blocked',true
  from pg_catalog.pg_constraint
  where conrelid=pg_catalog.to_regclass('public.inventory_item_usage_day_values')
    and conkey=array[(select attnum from pg_catalog.pg_attribute where attrelid=pg_catalog.to_regclass('public.inventory_item_usage_day_values') and attname='item_id')]::smallint[]

  union all
  select 'rls_enabled_all_inventory_usage_tables',
    case when count(*)=3 and bool_and(relrowsecurity) then 'PASS' else 'BLOCKED' end,
    count(*)::text||'/3 tables; enabled='||coalesce(bool_and(relrowsecurity)::text,'false'),true
  from pg_catalog.pg_class
  where oid in(pg_catalog.to_regclass('public.inventory_items_reports'),pg_catalog.to_regclass('public.inventory_item_usage_items'),pg_catalog.to_regclass('public.inventory_item_usage_day_values'))

  union all
  select 'direct_client_table_writes_denied',
    case when not exists(select 1 from client_write_access
      where pg_catalog.cardinality(explicit_write_acl)>0
        or effective_insert or effective_update or effective_delete
    ) then 'PASS' else 'BLOCKED' end,
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'table',table_name,'role',role_name,'explicit_write_acl',explicit_write_acl,
      'effective_insert',effective_insert,'effective_update',effective_update,
      'effective_delete',effective_delete,'inherited_write_roles',inherited_write_roles,
      'rls_enabled',rls_enabled
    ) order by table_name,role_name)::text from client_write_access),'[]'),true

  union all
  select 'legacy_rpc_security',
    case when procedure.oid is not null and procedure.prosecdef
      and coalesce(pg_catalog.array_to_string(procedure.proconfig,','),'') like '%search_path=""%'
      then 'PASS' else 'BLOCKED' end,
    'security_definer='||coalesce(procedure.prosecdef::text,'false')||'; config='||coalesce(pg_catalog.array_to_string(procedure.proconfig,','),'missing'),true
  from pg_catalog.pg_proc procedure
  right join (select pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)') as oid) target on target.oid=procedure.oid

  union all
  select 'legacy_rpc_acl_service_role_only',
    case when procedure.oid is not null
      and exists(select 1 from pg_catalog.aclexplode(coalesce(procedure.proacl,'{}'::aclitem[])) acl,role_ids roles where acl.grantee=roles.service_role_oid and acl.privilege_type='EXECUTE')
      and not exists(select 1 from pg_catalog.aclexplode(coalesce(procedure.proacl,'{}'::aclitem[])) acl,role_ids roles where acl.grantee in(0,roles.anon_oid,roles.authenticated_oid) and acl.privilege_type='EXECUTE')
      then 'PASS' else 'BLOCKED' end,
    'service_role explicit EXECUTE; PUBLIC/anon/authenticated denied',true
  from pg_catalog.pg_proc procedure
  right join (select pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)') as oid) target on target.oid=procedure.oid

  union all
  select 'legacy_rpc_authorization_and_scope',
    case when legacy_delete like '%private.inventory_items_actor_context%'
      and legacy_delete not like '%private.phase4a_actor_context%'
      and legacy_delete like '%report.organization_id = ctx.organization_id%'
      and legacy_delete like '%report.branch_id = ctx.branch_id%'
      then 'PASS' else 'BLOCKED' end,
    'modern actor context plus organization and branch predicates required',true
  from definitions

  union all
  select 'legacy_rpc_lock_and_draft_guards',
    case when legacy_delete like '%private.lock_inventory_items_month%'
      and legacy_delete ilike '%for update%'
      and legacy_delete like '%target_report.state <> ''draft''%'
      then 'PASS' else 'BLOCKED' end,
    'branch/month advisory lock, row lock, and draft-only check required',true
  from definitions

  union all
  select 'legacy_rpc_empty_only_baseline',
    case when legacy_delete like '%inventory item has saved usage values%'
      and legacy_delete like '%inventory_item_usage_day_values%'
      and legacy_delete not like '%DELETE FROM public.inventory_item_usage_day_values%'
      then 'PASS' else 'BLOCKED' end,
    'legacy RPC must still reject populated rows and never delete child values',true
  from definitions

  union all
  select 'actor_context_contract',
    case when actor_context like '%private.phase2_branch_context%'
      and actor_context not like '%private.phase4a_actor_context%'
      and actor_context like '%SECURITY DEFINER%'
      then 'PASS' else 'BLOCKED' end,
    'canonical active branch-manager context; SECURITY DEFINER; empty search_path',true
  from definitions

  union all
  select 'month_lock_contract',
    case when month_lock like '%pg_advisory_xact_lock%'
      and month_lock like '%target_branch_id::text%target_inventory_month::text%'
      then 'PASS' else 'BLOCKED' end,
    'transaction advisory lock is keyed by target branch and inventory month',true
  from definitions

  union all
  select 'required_private_helper_security',
    case when count(*)=6 and bool_and(procedure.prosecdef)
      and bool_and(coalesce(pg_catalog.array_to_string(procedure.proconfig,','),'') like '%search_path=""%')
      then 'PASS' else 'BLOCKED' end,
    count(*)::text||'/6 SECURITY DEFINER helpers with empty search_path',true
  from pg_catalog.pg_proc procedure
  where procedure.oid in(
    pg_catalog.to_regprocedure('private.inventory_items_actor_context(uuid,uuid)'),
    pg_catalog.to_regprocedure('private.lock_inventory_items_month(uuid,date)'),
    pg_catalog.to_regprocedure('private.inventory_items_numeric_field(jsonb,text)'),
    pg_catalog.to_regprocedure('private.inventory_items_state_json(uuid,uuid,date)'),
    pg_catalog.to_regprocedure('private.protect_inventory_usage_item()'),
    pg_catalog.to_regprocedure('private.protect_inventory_usage_day_value()')
  )

  union all
  select 'item_immutable_trigger',
    case when count(*)=1 and bool_and(not tgisinternal) then 'PASS' else 'BLOCKED' end,
    coalesce(max(pg_catalog.pg_get_triggerdef(oid)),'missing'),true
  from pg_catalog.pg_trigger
  where tgrelid=pg_catalog.to_regclass('public.inventory_item_usage_items')
    and tgname='inventory_item_usage_items_immutable'

  union all
  select 'item_guard_one_way_baseline',
    case when item_guard like '%old.deleted_at is null%'
      and item_guard like '%new.deleted_at is not null%'
      and item_guard like '%not exists%inventory_item_usage_day_values%'
      and item_guard like '%saved inventory item is immutable%'
      then 'PASS' else 'BLOCKED' end,
    'legacy guard permits only empty-row tombstone and rejects DELETE/restoration/other UPDATE',true
  from definitions

  union all
  select 'day_value_immutable_trigger',
    case when count(*)=1 and bool_and(not tgisinternal) then 'PASS' else 'BLOCKED' end,
    coalesce(max(pg_catalog.pg_get_triggerdef(oid)),'missing'),true
  from pg_catalog.pg_trigger
  where tgrelid=pg_catalog.to_regclass('public.inventory_item_usage_day_values')
    and tgname='inventory_item_usage_day_values_immutable'

  union all
  select 'day_value_guard_contract',
    case when day_guard like '%tg_op <> ''INSERT''%'
      and day_guard like '%saved inventory item day is immutable%'
      and day_guard like '%report.state = ''draft''%'
      then 'PASS' else 'BLOCKED' end,
    'existing day values reject UPDATE and DELETE; inserts require draft report',true
  from definitions

  union all
  select 'supervisor_state_excludes_tombstones',
    case when supervisor_state like '%item.deleted_at is null%' then 'PASS' else 'BLOCKED' end,
    'private.inventory_items_state_json filters item.deleted_at is null',true
  from definitions

  union all
  select 'manager_reports_exclude_tombstones',
    case when manager_reports like '%item.deleted_at is null%' then 'PASS' else 'BLOCKED' end,
    'list_managed_inventory_items_reports filters item.deleted_at is null',true
  from definitions

  union all
  select 'manager_active_totals_exclude_tombstones',
    case when manager_totals like '%item.deleted_at is null%' then 'PASS' else 'BLOCKED' end,
    'get_managed_operations_summary active Item Usage total filters deleted_at',true
  from definitions

  union all
  select 'monthly_carry_forward_excludes_tombstones',
    case when (select count(*) from pg_catalog.regexp_matches(
        carry_forward,$regex$source_item\.deleted_at\s+is\s+null$regex$,'gi'
      ))>=2
      and carry_forward ~* $regex$where\s+target_item\.report_id\s*=\s*target_report_id$regex$
      and carry_forward ~* $regex$row_number\s*\(\s*\)\s+over$regex$
      and carry_forward ~* $regex$partition\s+by[\s\S]*group_name[\s\S]*item_name$regex$
      and carry_forward ~* $regex$where\s+source_item\.identity_rank\s*=\s*1$regex$
      then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_build_object(
      'source_deleted_filters',(select count(*) from pg_catalog.regexp_matches(
        carry_forward,$regex$source_item\.deleted_at\s+is\s+null$regex$,'gi')),
      'any_target_history_blocks_reseed',carry_forward ~* $regex$where\s+target_item\.report_id\s*=\s*target_report_id$regex$,
      'normalized_identity_deduplication',carry_forward ~* $regex$row_number\s*\(\s*\)\s+over[\s\S]*partition\s+by[\s\S]*group_name[\s\S]*item_name[\s\S]*identity_rank\s*=\s*1$regex$
    )::text,true
  from definitions

  union all
  select 'manager_projection_security',
    case when count(*)=2 and bool_and(procedure.prosecdef)
      and bool_and(coalesce(pg_catalog.array_to_string(procedure.proconfig,','),'') like '%search_path=""%')
      then 'PASS' else 'BLOCKED' end,
    count(*)::text||'/2 manager projections SECURITY DEFINER with empty search_path',true
  from pg_catalog.pg_proc procedure
  where procedure.oid in(
    pg_catalog.to_regprocedure('public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)'),
    pg_catalog.to_regprocedure('public.get_managed_operations_summary(uuid,uuid,uuid,date)')
  )

  union all
  select 'active_index_contract',
    case when count(*)=1 and bool_and(pg_catalog.pg_get_expr(index_row.indpred,index_row.indrelid) like '%deleted_at IS NULL%') then 'PASS' else 'BLOCKED' end,
    coalesce(max(pg_catalog.pg_get_indexdef(index_row.indexrelid)),'missing'),true
  from pg_catalog.pg_index index_row
  join pg_catalog.pg_class index_class on index_class.oid=index_row.indexrelid
  where index_row.indrelid=pg_catalog.to_regclass('public.inventory_item_usage_items')
    and index_class.relname='inventory_item_usage_items_active_report_idx'

  union all
  select 'new_migration_object_collision_scan',
    case when pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)') is null
      and not exists(select 1 from pg_catalog.pg_proc procedure
        join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
        where namespace.nspname='public' and procedure.proname='delete_inventory_item_usage_item'
          and procedure.oid<>pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)'))
      then 'PASS' else 'BLOCKED' end,
    'no four-argument or unexpected overload may already exist',true

  union all
  select 'partial_installation_detection',
    case when pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)') is not null
      and pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)') is null
      and item_guard like '%not exists%inventory_item_usage_day_values%'
      and item_guard not like '%inventory_items_actor_context(%'
      then 'PASS' else 'BLOCKED' end,
    'exact legacy baseline required; mixed legacy/new trigger or RPC state is blocked',true
  from definitions

  union all
  select 'unrelated_schema_dependency_scan',
    case when not exists(select 1 from unexpected_schema_references) then 'PASS' else 'BLOCKED' end,
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'source',source_name,'unexpected_executable_reference',reference_name
    ) order by source_name,reference_name)::text from unexpected_schema_references),'[]'),true
)
select result.check_name,result.status,result.evidence
from (
  select check_name,status,evidence from checks
  union all
  select 'overall_readiness',
    case when not exists(select 1 from checks where mandatory and status<>'PASS') then 'PASS' else 'BLOCKED' end,
    case when not exists(select 1 from checks where mandatory and status<>'PASS')
      then 'all mandatory dependency checks passed; eligible for transactional migration preflight'
      else 'one or more mandatory dependency checks are BLOCKED; do not apply or preflight the migration' end
) result
order by case when result.check_name='overall_readiness' then 1 else 0 end,result.check_name;
