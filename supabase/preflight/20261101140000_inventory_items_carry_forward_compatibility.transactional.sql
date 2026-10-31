-- Supabase SQL Editor-compatible rollback-only preflight.
-- Exercises the complete compatibility DDL, asserts structure/security/data
-- preservation, and restores the baseline with final ROLLBACK.
begin;
set local lock_timeout='5s';
set local statement_timeout='120s';

create temporary table inventory_carry_forward_preflight_baseline on commit drop as
select
  (select count(*) from public.inventory_items_reports) report_count,
  (select count(*) from public.inventory_item_usage_items) item_count,
  (select count(*) from public.inventory_item_usage_day_values) day_value_count,
  (select count(*) from public.inventory_beef_production_rows) beef_count,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(
    'private.inventory_items_state_json(uuid,uuid,date)'::regprocedure
  )) original_state_definition_md5,
  pg_catalog.has_function_privilege(
    'service_role','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE'
  ) public_state_service_execute;

do $prerequisites$
declare state_definition text;
begin
  if pg_catalog.to_regclass('public.inventory_items_reports') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_items') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_day_values') is null
    or pg_catalog.to_regclass('public.inventory_beef_production_rows') is null
    or pg_catalog.to_regclass('public.branch_inventory_items_settings') is null
    or pg_catalog.to_regprocedure('private.inventory_items_actor_context(uuid,uuid)') is null
    or pg_catalog.to_regprocedure('private.inventory_items_state_json(uuid,uuid,date)') is null
    or pg_catalog.to_regprocedure('public.get_inventory_items_current_state(uuid,uuid,date)') is null
  then raise exception 'Inventory Items carry-forward prerequisites are missing' using errcode='42883'; end if;

  if exists(
    select 1 from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='private' and procedure.proname='inventory_items_carry_forward_items_json'
  ) then raise exception 'carry-forward helper collision or partial installation' using errcode='42723'; end if;

  select pg_catalog.pg_get_functiondef(
    'private.inventory_items_state_json(uuid,uuid,date)'::regprocedure
  ) into state_definition;
  if state_definition not like '%private.inventory_items_actor_context%'
    or state_definition not like '%item.deleted_at is null%'
    or state_definition not like '%public.inventory_item_usage_day_values%'
    or state_definition like '%private.inventory_items_carry_forward_items_json%'
  then raise exception 'state projection baseline drifted' using errcode='55000'; end if;
end
$prerequisites$;

create or replace function private.inventory_items_carry_forward_items_json(
  target_organization_id uuid,
  target_branch_id uuid,
  target_inventory_month date,
  target_report_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  source_report_id uuid;
  projected_items jsonb;
begin
  if target_report_id is not null and exists (
    select 1
    from public.inventory_item_usage_items target_item
    where target_item.report_id = target_report_id
  ) then
    return '[]'::jsonb;
  end if;

  select source_report.id
  into source_report_id
  from public.inventory_items_reports source_report
  where source_report.organization_id = target_organization_id
    and source_report.branch_id = target_branch_id
    and source_report.inventory_month < target_inventory_month
    and source_report.state = 'submitted'
    and source_report.submitted_at is not null
    and exists (
      select 1
      from public.inventory_item_usage_items source_item
      where source_item.report_id = source_report.id
        and source_item.deleted_at is null
    )
  order by source_report.inventory_month desc,source_report.submitted_at desc,source_report.id desc
  limit 1;

  if source_report_id is null then return '[]'::jsonb; end if;

  with ranked_source_items as (
    select source_item.id,source_item.group_name,source_item.item_name,source_item.sort_order,
      pg_catalog.row_number() over (
        partition by
          pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(source_item.group_name),'[[:space:]]+',' ','g')),
          pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(source_item.item_name),'[[:space:]]+',' ','g'))
        order by source_item.sort_order,source_item.item_name,source_item.id
      ) identity_rank
    from public.inventory_item_usage_items source_item
    where source_item.report_id=source_report_id and source_item.deleted_at is null
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'group_name',source_item.group_name,'item_name',source_item.item_name,'usage','{}'::jsonb
    ) order by source_item.sort_order,source_item.item_name,source_item.id),'[]'::jsonb)
  into projected_items
  from ranked_source_items source_item
  where source_item.identity_rank=1;

  return projected_items;
end
$$;

revoke all on function private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)
  from public,anon,authenticated;

create or replace function private.inventory_items_state_json(
  p_actor_user_id uuid,
  p_target_branch_id uuid,
  p_target_inventory_month date
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ctx record;
  report public.inventory_items_reports%rowtype;
  selected_month date;
  settings public.branch_inventory_items_settings%rowtype;
begin
  select * into strict ctx from private.inventory_items_actor_context(p_actor_user_id,p_target_branch_id);
  selected_month:=coalesce(p_target_inventory_month,pg_catalog.date_trunc('month',ctx.business_date)::date);
  if selected_month<>pg_catalog.date_trunc('month',selected_month)::date then
    raise exception 'invalid inventory month' using errcode='22023';
  end if;

  select * into report from public.inventory_items_reports r
  where r.organization_id=ctx.organization_id and r.branch_id=ctx.branch_id
    and r.inventory_month=selected_month;

  select * into settings from public.branch_inventory_items_settings branch_settings
  where branch_settings.organization_id=ctx.organization_id and branch_settings.branch_id=ctx.branch_id;

  return pg_catalog.jsonb_build_object(
    'report_id',report.id,'business_date',ctx.business_date,'inventory_month',selected_month,
    'state',coalesce(report.state,'draft'),'updated_at',report.updated_at,'submitted_at',report.submitted_at,
    'beef_production_labels',pg_catalog.jsonb_build_object(
      'russian_label',settings.beef_russian_label,'australian_label',settings.beef_australian_label,
      'hunch_sauce_label',settings.beef_hunch_sauce_label
    ),
    'beef_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',row.id,'production_date',row.production_date,'russian_kg',row.russian_kg,
      'australian_kg',row.australian_kg,'fat_kg',row.fat_kg,
      'total_kg',row.russian_kg+row.australian_kg+row.fat_kg,'ready_patty',row.ready_patty,
      'hunch_sauce_kg',row.hunch_sauce_kg,'wastage_grams',row.wastage_grams,
      'russian_label_snapshot',row.russian_label_snapshot,
      'australian_label_snapshot',row.australian_label_snapshot,
      'hunch_sauce_label_snapshot',row.hunch_sauce_label_snapshot,
      'updated_at',row.updated_at,'updated_by_user_id',row.updated_by_user_id
    ) order by row.production_date) from public.inventory_beef_production_rows row
      where row.report_id=report.id),'[]'::jsonb),
    'item_usage',pg_catalog.jsonb_build_object(
      'usage_month',coalesce((select min(item.usage_month)
        from public.inventory_item_usage_items item
        where item.report_id=report.id and item.deleted_at is null),selected_month),
      'items',case when exists(select 1 from public.inventory_item_usage_items target_item
        where target_item.report_id=report.id)
      then coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id',item.id,'group_name',item.group_name,'item_name',item.item_name,
        'usage',coalesce((select pg_catalog.jsonb_object_agg(value.day_number::text,value.quantity order by value.day_number)
          from public.inventory_item_usage_day_values value where value.item_id=item.id),'{}'::jsonb)
      ) order by item.sort_order,item.item_name,item.id)
      from public.inventory_item_usage_items item
      where item.report_id=report.id and item.deleted_at is null),'[]'::jsonb)
      else private.inventory_items_carry_forward_items_json(
        ctx.organization_id,ctx.branch_id,selected_month,report.id
      ) end
    )
  );
exception when no_data_found or too_many_rows then
  raise exception 'inventory state denied' using errcode='42501';
end $$;

revoke all on function private.inventory_items_state_json(uuid,uuid,date)
  from public,anon,authenticated;

do $assertions$
declare carry_definition text; state_definition text;
begin
  select pg_catalog.pg_get_functiondef(
    'private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)'::regprocedure
  ) into carry_definition;
  select pg_catalog.pg_get_functiondef(
    'private.inventory_items_state_json(uuid,uuid,date)'::regprocedure
  ) into state_definition;

  if (select count(*) from pg_catalog.regexp_matches(
      carry_definition,$regex$source_item\.deleted_at\s+is\s+null$regex$,'gi'))<2
    or carry_definition !~* $regex$where\s+target_item\.report_id\s*=\s*target_report_id$regex$
    or carry_definition !~* $regex$row_number\s*\(\s*\)\s+over[\s\S]*partition\s+by[\s\S]*source_item\.group_name[\s\S]*source_item\.item_name$regex$
    or carry_definition !~* $regex$where\s+source_item\.identity_rank\s*=\s*1$regex$
    or state_definition !~* $regex$private\.inventory_items_carry_forward_items_json\s*\($regex$
  then raise exception 'carry-forward structural assertion failed' using errcode='55000'; end if;

  if pg_catalog.has_function_privilege('anon','private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)','EXECUTE')
    or pg_catalog.has_function_privilege('authenticated','private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)','EXECUTE')
    or not pg_catalog.has_function_privilege('service_role','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE')
  then raise exception 'carry-forward authorization assertion failed' using errcode='55000'; end if;

  if (select report_count<>(select count(*) from public.inventory_items_reports)
      or item_count<>(select count(*) from public.inventory_item_usage_items)
      or day_value_count<>(select count(*) from public.inventory_item_usage_day_values)
      or beef_count<>(select count(*) from public.inventory_beef_production_rows)
      or public_state_service_execute is distinct from pg_catalog.has_function_privilege(
        'service_role','public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE')
    from inventory_carry_forward_preflight_baseline)
  then raise exception 'Inventory rows or public RPC service access changed' using errcode='55000'; end if;
end
$assertions$;

rollback;
