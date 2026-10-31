-- Supabase SQL Editor-compatible rollback-only preflight for
-- 20261101120000_inventory_item_usage_populated_row_delete.sql.
--
-- Exercises the exact populated Item Usage delete migration DDL within a
-- transaction with bounded timeouts, verifies post-DDL structure, security,
-- and RPC contracts, and verifies zero persistent mutations via mandatory ROLLBACK.
-- Never mutates business data, even temporarily.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Baseline snapshot to guarantee zero persistent business data changes
create temporary table inventory_populated_delete_preflight_baseline on commit drop as
select
  (select count(*) from public.inventory_items_reports) as report_count,
  (select count(*) from public.inventory_item_usage_items) as item_count,
  (select count(*) from public.inventory_item_usage_day_values) as day_value_count,
  (select count(*) from public.inventory_beef_production_rows) as beef_count;

-- Migration prerequisite assertions
do $prerequisites$
declare
  delete_definition text;
  supervisor_state_definition text;
  manager_report_definition text;
  manager_summary_definition text;
begin
  if pg_catalog.to_regprocedure(
      'public.delete_inventory_item_usage_item(uuid,uuid,uuid)') is null
    or pg_catalog.to_regprocedure(
      'private.inventory_items_actor_context(uuid,uuid)') is null
    or pg_catalog.to_regprocedure(
      'private.lock_inventory_items_month(uuid,date)') is null
    or pg_catalog.to_regprocedure(
      'private.inventory_items_state_json(uuid,uuid,date)') is null
    or pg_catalog.to_regprocedure(
      'private.inventory_items_numeric_field(jsonb,text)') is null
    or pg_catalog.to_regprocedure(
      'public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)') is null
    or pg_catalog.to_regprocedure(
      'public.get_managed_operations_summary(uuid,uuid,uuid,date)') is null
    or pg_catalog.to_regclass('public.inventory_items_reports') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_items') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_day_values') is null
  then
    raise exception 'populated Item Usage delete prerequisites are missing'
      using errcode='42883';
  end if;

  select pg_catalog.pg_get_functiondef(
    'public.delete_inventory_item_usage_item(uuid,uuid,uuid)'::regprocedure)
  into delete_definition;
  select pg_catalog.pg_get_functiondef(
    'private.inventory_items_state_json(uuid,uuid,date)'::regprocedure)
  into supervisor_state_definition;
  select pg_catalog.pg_get_functiondef(
    'public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)'::regprocedure)
  into manager_report_definition;
  select pg_catalog.pg_get_functiondef(
    'public.get_managed_operations_summary(uuid,uuid,uuid,date)'::regprocedure)
  into manager_summary_definition;
  if delete_definition not like '%private.inventory_items_actor_context%'
    or delete_definition like '%private.phase4a_actor_context%'
    or supervisor_state_definition not like '%item.deleted_at is null%'
    or manager_report_definition not like '%item.deleted_at is null%'
    or manager_summary_definition not like '%item.deleted_at is null%'
    or not exists(
      select 1 from pg_catalog.pg_trigger trigger_row
      where trigger_row.tgrelid='public.inventory_item_usage_items'::regclass
        and trigger_row.tgname='inventory_item_usage_items_immutable'
        and not trigger_row.tgisinternal
    )
  then
    raise exception 'populated Item Usage delete prerequisite contract drifted'
      using errcode='55000';
  end if;
end
$prerequisites$;

-- Proposed DDL from 20261101120000_inventory_item_usage_populated_row_delete.sql

create or replace function private.protect_inventory_usage_item()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='INSERT' then
    if new.deleted_at is not null or new.deleted_by_user_id is not null then
      raise exception 'new inventory item cannot be deleted' using errcode='23505';
    end if;
    if not exists(
      select 1 from public.inventory_items_reports report
      where report.id=new.report_id and report.state='draft'
    ) then
      raise exception 'inventory month is closed' using errcode='23505';
    end if;
    return new;
  end if;

  if tg_op='UPDATE'
    and old.deleted_at is null
    and old.deleted_by_user_id is null
    and new.deleted_at is not null
    and new.deleted_by_user_id is not null
    and new.id is not distinct from old.id
    and new.report_id is not distinct from old.report_id
    and new.usage_month is not distinct from old.usage_month
    and new.group_name is not distinct from old.group_name
    and new.item_name is not distinct from old.item_name
    and new.sort_order is not distinct from old.sort_order
    and new.created_at is not distinct from old.created_at
    and new.created_by is not distinct from old.created_by
    and new.updated_at is not distinct from old.updated_at
    and exists(
      select 1
      from public.inventory_items_reports report
      join lateral private.inventory_items_actor_context(
        new.deleted_by_user_id,report.branch_id
      ) actor on actor.organization_id=report.organization_id
        and actor.branch_id=report.branch_id
      where report.id=old.report_id and report.state='draft'
    )
  then
    return new;
  end if;

  raise exception 'saved inventory item is immutable' using errcode='23505';
end
$$;

revoke all on function private.protect_inventory_usage_item()
  from public,anon,authenticated,service_role;

create function public.delete_inventory_item_usage_item(
  actor_user_id uuid,
  target_branch_id uuid,
  target_item_usage_id uuid,
  expected_usage jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  ctx record;
  target_report_id uuid;
  target_inventory_month date;
  target_report public.inventory_items_reports%rowtype;
  target_item public.inventory_item_usage_items%rowtype;
  usage_key text;
  usage_value jsonb;
  expected_quantity numeric;
  normalized_expected_usage jsonb:='{}'::jsonb;
  current_usage jsonb;
begin
  if actor_user_id is null or target_branch_id is null or target_item_usage_id is null
    or expected_usage is null or pg_catalog.jsonb_typeof(expected_usage)<>'object'
    or (select count(*) from pg_catalog.jsonb_object_keys(expected_usage))>31
  then
    raise exception 'invalid expected Item Usage snapshot' using errcode='22023';
  end if;

  for usage_key,usage_value in
    select key,value from pg_catalog.jsonb_each(expected_usage)
  loop
    if usage_key!~'^(?:[1-9]|[12][0-9]|3[01])$' then
      raise exception 'invalid expected Item Usage snapshot' using errcode='22023';
    end if;
    expected_quantity:=private.inventory_items_numeric_field(
      pg_catalog.jsonb_build_object('quantity',usage_value),'quantity');
    normalized_expected_usage:=normalized_expected_usage
      ||pg_catalog.jsonb_build_object(usage_key,expected_quantity);
  end loop;

  select * into strict ctx
  from private.inventory_items_actor_context(actor_user_id,target_branch_id);

  select report.id,report.inventory_month
  into target_report_id,target_inventory_month
  from public.inventory_item_usage_items item
  join public.inventory_items_reports report on report.id=item.report_id
  where item.id=target_item_usage_id
    and report.organization_id=ctx.organization_id
    and report.branch_id=ctx.branch_id;

  if target_report_id is null then
    raise exception 'inventory item delete denied' using errcode='42501';
  end if;

  perform private.lock_inventory_items_month(target_branch_id,target_inventory_month);

  select * into strict target_report
  from public.inventory_items_reports report
  where report.id=target_report_id
    and report.organization_id=ctx.organization_id
    and report.branch_id=ctx.branch_id
  for update;

  select * into strict target_item
  from public.inventory_item_usage_items item
  where item.id=target_item_usage_id and item.report_id=target_report.id
  for update;

  -- A correctly scoped retry is successful without changing the first actor or
  -- timestamp, including when the month was submitted after the original delete.
  if target_item.deleted_at is not null then
    return private.inventory_items_state_json(
      actor_user_id,target_branch_id,target_report.inventory_month);
  end if;

  if target_report.state<>'draft' then
    raise exception 'inventory month already submitted' using errcode='23505';
  end if;

  select coalesce(
    pg_catalog.jsonb_object_agg(
      value.day_number::text,pg_catalog.to_jsonb(value.quantity)
      order by value.day_number
    ),'{}'::jsonb
  ) into current_usage
  from public.inventory_item_usage_day_values value
  where value.item_id=target_item.id;

  if current_usage is distinct from normalized_expected_usage then
    raise exception 'Item Usage changed after confirmation' using errcode='40001';
  end if;

  update public.inventory_item_usage_items item set
    deleted_at=pg_catalog.statement_timestamp(),
    deleted_by_user_id=actor_user_id
  where item.id=target_item.id and item.deleted_at is null;

  if not found then
    raise exception 'inventory item delete conflict' using errcode='40001';
  end if;

  update public.inventory_items_reports report set
    updated_at=pg_catalog.statement_timestamp()
  where report.id=target_report.id;

  return private.inventory_items_state_json(
    actor_user_id,target_branch_id,target_report.inventory_month);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory item delete denied' using errcode='42501';
end
$$;

revoke all on function public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)
  to service_role;

revoke all on function public.delete_inventory_item_usage_item(uuid,uuid,uuid)
  from public,anon,authenticated,service_role;
drop function public.delete_inventory_item_usage_item(uuid,uuid,uuid);

-- Post-DDL assertions and data preservation verification
do $assertions$
declare
  target_func regprocedure;
  func_def text;
begin
  target_func := pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid,jsonb)');
  if target_func is null then
    raise exception 'four-argument delete RPC was not created' using errcode='55000';
  end if;

  if pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)') is not null then
    raise exception 'legacy three-argument delete RPC was not dropped' using errcode='55000';
  end if;

  if not pg_catalog.has_function_privilege('service_role', target_func, 'EXECUTE') then
    raise exception 'service_role does not have execute privilege on four-argument delete RPC' using errcode='55000';
  end if;

  if pg_catalog.has_function_privilege('anon', target_func, 'EXECUTE')
    or pg_catalog.has_function_privilege('authenticated', target_func, 'EXECUTE')
  then
    raise exception 'client roles have execute privilege on four-argument delete RPC' using errcode='55000';
  end if;

  func_def := pg_catalog.pg_get_functiondef(target_func);
  if func_def not like '%private.inventory_items_actor_context%'
    or func_def not like '%normalized_expected_usage%'
    or func_def not like '%private.inventory_items_state_json%'
  then
    raise exception 'four-argument delete RPC definition drifted' using errcode='55000';
  end if;

  if (select report_count <> (select count(*) from public.inventory_items_reports)
      or item_count <> (select count(*) from public.inventory_item_usage_items)
      or day_value_count <> (select count(*) from public.inventory_item_usage_day_values)
      or beef_count <> (select count(*) from public.inventory_beef_production_rows)
    from inventory_populated_delete_preflight_baseline)
  then
    raise exception 'business data mutated during transactional preflight' using errcode='55000';
  end if;
end
$assertions$;

rollback;
