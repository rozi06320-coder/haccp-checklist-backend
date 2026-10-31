-- SELECT-only Production readiness diagnostic for
-- 20261101140000_inventory_items_carry_forward_compatibility.sql.
-- Reads catalogs and aggregate compatibility counts only; never invokes RPCs
-- or changes functions, permissions, Inventory data, or migration history.

with
state_function as (
  select procedure.oid,procedure.prosecdef,procedure.proconfig,procedure.proowner,procedure.proacl,
    pg_catalog.pg_get_function_result(procedure.oid) result_type,
    pg_catalog.pg_get_functiondef(procedure.oid) definition
  from pg_catalog.pg_proc procedure
  where procedure.oid=pg_catalog.to_regprocedure('private.inventory_items_state_json(uuid,uuid,date)')
),
carry_overloads as (
  select procedure.oid,procedure.oid::pg_catalog.regprocedure::text signature,
    pg_catalog.pg_get_function_result(procedure.oid) result_type,
    pg_catalog.pg_get_functiondef(procedure.oid) definition
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname='private'
    and procedure.proname='inventory_items_carry_forward_items_json'
),
required_columns(table_name,column_name) as (
  values
    ('inventory_items_reports','id'),('inventory_items_reports','organization_id'),
    ('inventory_items_reports','branch_id'),('inventory_items_reports','inventory_month'),
    ('inventory_items_reports','state'),('inventory_items_reports','submitted_at'),
    ('inventory_item_usage_items','id'),('inventory_item_usage_items','report_id'),
    ('inventory_item_usage_items','usage_month'),('inventory_item_usage_items','group_name'),
    ('inventory_item_usage_items','item_name'),('inventory_item_usage_items','sort_order'),
    ('inventory_item_usage_items','deleted_at'),
    ('inventory_item_usage_day_values','item_id'),('inventory_item_usage_day_values','day_number'),
    ('inventory_item_usage_day_values','quantity')
),
missing_columns as (
  select required.* from required_columns required
  left join information_schema.columns column_row
    on column_row.table_schema='public'
   and column_row.table_name=required.table_name
   and column_row.column_name=required.column_name
  where column_row.column_name is null
),
function_consumers as (
  select procedure.oid::pg_catalog.regprocedure::text signature
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname in('public','private') and procedure.prokind='f'
    and procedure.oid<>pg_catalog.to_regprocedure('private.inventory_items_state_json(uuid,uuid,date)')
    and pg_catalog.pg_get_functiondef(procedure.oid) ~* $regex$private\.inventory_items_state_json\s*\($regex$
),
data_compatibility as (
  select
    (select count(*) from public.inventory_items_reports report
      where report.inventory_month<>pg_catalog.date_trunc('month',report.inventory_month)::date) invalid_report_months,
    (select count(*) from public.inventory_item_usage_items item
      join public.inventory_items_reports report on report.id=item.report_id
      where item.usage_month<>report.inventory_month) mismatched_item_months,
    (select count(*) from (
      select report.organization_id,report.branch_id,report.inventory_month
      from public.inventory_items_reports report
      group by report.organization_id,report.branch_id,report.inventory_month having count(*)>1
    ) duplicate_month) duplicate_branch_months,
    (select count(*) from public.inventory_items_reports report
      where report.state='submitted' and report.submitted_at is not null
        and exists(select 1 from public.inventory_item_usage_items item
          where item.report_id=report.id and item.deleted_at is null)) eligible_source_reports,
    (select count(*) from public.inventory_item_usage_items item where item.deleted_at is not null) tombstoned_items,
    (select count(*) from (
      select item.report_id,
        pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.group_name),'[[:space:]]+',' ','g')) normalized_group,
        pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.item_name),'[[:space:]]+',' ','g')) normalized_item
      from public.inventory_item_usage_items item where item.deleted_at is null
      group by item.report_id,
        pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.group_name),'[[:space:]]+',' ','g')),
        pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.item_name),'[[:space:]]+',' ','g'))
      having count(*)>1
    ) duplicate_identity) normalized_duplicate_groups,
    (select count(*) from public.inventory_items_reports report
      where exists(select 1 from public.inventory_item_usage_items item where item.report_id=report.id)) target_reports_with_history
),
checks(check_name,status,evidence,mandatory,sort_order) as (
  select 'required_relations',case when
      pg_catalog.to_regclass('public.inventory_items_reports') is not null
      and pg_catalog.to_regclass('public.inventory_item_usage_items') is not null
      and pg_catalog.to_regclass('public.inventory_item_usage_day_values') is not null
      and pg_catalog.to_regclass('public.inventory_beef_production_rows') is not null
      and pg_catalog.to_regclass('public.branch_inventory_items_settings') is not null
    then 'PASS' else 'BLOCKED' end,
    'reports, Item Usage parent/day history, Beef rows, and branch settings',true,10

  union all
  select 'required_columns',case when count(*)=0 then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(missing) order by table_name,column_name)::text,'[]'),true,20
  from missing_columns missing

  union all
  select 'carry_forward_helper_absent',case when count(*)=0 then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(overload) order by signature)::text,'[]'),true,30
  from carry_overloads overload

  union all
  select 'state_projection_contract',case when count(*)=1 and bool_and(
      result_type='jsonb' and prosecdef and proconfig @> array['search_path=""']
      and definition like '%private.inventory_items_actor_context%'
      and definition like '%item.deleted_at is null%'
      and definition like '%public.inventory_item_usage_day_values%'
      and definition not like '%private.inventory_items_carry_forward_items_json%'
    ) then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'result_type',result_type,'security_definer',prosecdef,'config',proconfig,
      'definition_md5',pg_catalog.md5(definition)
    ))::text,'[]'),true,40
  from state_function

  union all
  select 'service_role_public_state_rpc',case when
      pg_catalog.to_regprocedure('public.get_inventory_items_current_state(uuid,uuid,date)') is not null
      and pg_catalog.has_function_privilege('service_role','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE')
      and not pg_catalog.has_function_privilege('anon','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE')
      and not pg_catalog.has_function_privilege('authenticated','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE')
    then 'PASS' else 'BLOCKED' end,
    'service_role-only authoritative public state RPC',true,50

  union all
  select 'data_shape_compatibility',case when
      invalid_report_months=0 and mismatched_item_months=0 and duplicate_branch_months=0
    then 'PASS' else 'BLOCKED' end,
    pg_catalog.to_jsonb(data_compatibility)::text,true,60
  from data_compatibility

  union all
  select 'projection_impact_counts','INFO',pg_catalog.jsonb_build_object(
      'eligible_source_reports',eligible_source_reports,
      'tombstoned_items_excluded',tombstoned_items,
      'normalized_duplicate_groups_deduplicated',normalized_duplicate_groups,
      'target_reports_with_any_history_never_reseeded',target_reports_with_history
    )::text,false,70
  from data_compatibility

  union all
  select 'state_projection_consumers','INFO',coalesce((
    select pg_catalog.jsonb_agg(signature order by signature)::text from function_consumers
  ),'[]'),false,80

  union all
  select 'migration_is_function_only','PASS',
    'CREATE OR REPLACE functions and function ACL hardening only; no Inventory table DML',true,90
),
results as (
  select check_name,status,evidence,sort_order from checks
  union all
  select 'overall_readiness',case when not exists(
      select 1 from checks where mandatory and status<>'PASS'
    ) then 'PASS' else 'BLOCKED' end,
    case when not exists(select 1 from checks where mandatory and status<>'PASS')
      then 'carry-forward compatibility remediation is eligible for transactional preflight'
      else 'carry-forward prerequisites differ; do not execute remediation' end,1000
)
select check_name,status,evidence
from results
order by sort_order,check_name;
