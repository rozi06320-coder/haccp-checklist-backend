-- Continuous Daily Inventory balance.
--
-- A manual opening is the initial start-of-day baseline for an item. Only the
-- earliest historical manual opening is authoritative; later month-start
-- values are retained as history but no longer reset the balance. An actual
-- closing is an optional end-of-day physical checkpoint. Independent product
-- sales and waste movements participate even when no inventory entry exists.

create index if not exists branch_daily_inventory_entries_branch_item_date_idx
on public.branch_daily_inventory_entries(branch_id, inventory_item_id, business_date);

create or replace function private.branch_daily_inventory_balance_rows(
  target_organization_id uuid,
  target_branch_id uuid,
  through_date date
)
returns table (
  organization_id uuid,
  branch_id uuid,
  business_date date,
  inventory_item_id uuid,
  inventory_item_name text,
  inventory_item_unit text,
  entry_id uuid,
  baseline_effective_date date,
  manual_opening_quantity numeric,
  opening_quantity numeric,
  receiving_quantity numeric,
  transfer_in_quantity numeric,
  transfer_out_quantity numeric,
  sales_usage_quantity numeric,
  wastage_quantity numeric,
  calculated_closing_quantity numeric,
  actual_closing_quantity numeric,
  variance_quantity numeric,
  entry_created_at timestamptz,
  entry_updated_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  with recursive
  baseline as (
    select distinct on (entry.inventory_item_id)
      entry.inventory_item_id,
      entry.business_date as effective_date,
      entry.manual_opening_quantity as quantity
    from public.branch_daily_inventory_entries entry
    where entry.organization_id = target_organization_id
      and entry.branch_id = target_branch_id
      and entry.business_date <= through_date
      and entry.manual_opening_quantity is not null
    order by entry.inventory_item_id, entry.business_date, entry.created_at, entry.id
  ),
  first_activity as (
    select activity.inventory_item_id, min(activity.business_date) as business_date
    from (
      select entry.inventory_item_id, entry.business_date
      from public.branch_daily_inventory_entries entry
      where entry.organization_id = target_organization_id
        and entry.branch_id = target_branch_id
        and entry.business_date <= through_date
      union all
      select usage.inventory_item_id, usage.business_date
      from public.branch_product_sales_usage_snapshots usage
      where usage.organization_id = target_organization_id
        and usage.branch_id = target_branch_id
        and usage.business_date <= through_date
      union all
      select waste.inventory_item_id, waste.business_date
      from public.branch_daily_waste_entries waste
      where waste.organization_id = target_organization_id
        and waste.branch_id = target_branch_id
        and waste.business_date <= through_date
    ) activity
    group by activity.inventory_item_id
  ),
  item_scope as (
    select
      item.id as inventory_item_id,
      item.name as inventory_item_name,
      item.unit as inventory_item_unit,
      baseline.effective_date as baseline_effective_date,
      baseline.quantity as baseline_quantity,
      case
        when baseline.effective_date is not null then baseline.effective_date
        when first_activity.business_date is not null then first_activity.business_date
        else through_date
      end as first_date
    from public.branch_inventory_catalog_items item
    left join baseline on baseline.inventory_item_id = item.id
    left join first_activity on first_activity.inventory_item_id = item.id
    where item.organization_id = target_organization_id
      and item.branch_id = target_branch_id
      and (
        item.is_active
        or baseline.inventory_item_id is not null
        or first_activity.inventory_item_id is not null
      )
  ),
  inventory_movements as (
    select
      entry.inventory_item_id,
      entry.business_date,
      entry.id as entry_id,
      entry.inventory_item_name_snapshot,
      entry.inventory_item_unit_snapshot,
      entry.receiving_quantity,
      entry.transfer_in_quantity,
      entry.transfer_out_quantity,
      entry.actual_closing_quantity,
      entry.created_at,
      entry.updated_at
    from public.branch_daily_inventory_entries entry
    where entry.organization_id = target_organization_id
      and entry.branch_id = target_branch_id
      and entry.business_date <= through_date
  ),
  sales_movements as (
    select usage.inventory_item_id, usage.business_date, sum(usage.total_usage_quantity) as quantity
    from public.branch_product_sales_usage_snapshots usage
    where usage.organization_id = target_organization_id
      and usage.branch_id = target_branch_id
      and usage.business_date <= through_date
    group by usage.inventory_item_id, usage.business_date
  ),
  waste_movements as (
    select waste.inventory_item_id, waste.business_date, sum(waste.quantity) as quantity
    from public.branch_daily_waste_entries waste
    where waste.organization_id = target_organization_id
      and waste.branch_id = target_branch_id
      and waste.business_date <= through_date
    group by waste.inventory_item_id, waste.business_date
  ),
  balance as (
    select
      target_organization_id as organization_id,
      target_branch_id as branch_id,
      scope.first_date as business_date,
      scope.inventory_item_id,
      coalesce(inv.inventory_item_name_snapshot, scope.inventory_item_name) as inventory_item_name,
      coalesce(inv.inventory_item_unit_snapshot, scope.inventory_item_unit) as inventory_item_unit,
      inv.entry_id,
      scope.baseline_effective_date,
      scope.baseline_quantity as manual_opening_quantity,
      case when scope.first_date = scope.baseline_effective_date then scope.baseline_quantity else null end as opening_quantity,
      coalesce(inv.receiving_quantity, 0) as receiving_quantity,
      coalesce(inv.transfer_in_quantity, 0) as transfer_in_quantity,
      coalesce(inv.transfer_out_quantity, 0) as transfer_out_quantity,
      coalesce(sales.quantity, 0) as sales_usage_quantity,
      coalesce(waste.quantity, 0) as wastage_quantity,
      case when scope.first_date = scope.baseline_effective_date then
        scope.baseline_quantity
          + coalesce(inv.receiving_quantity, 0)
          + coalesce(inv.transfer_in_quantity, 0)
          - coalesce(inv.transfer_out_quantity, 0)
          - coalesce(sales.quantity, 0)
          - coalesce(waste.quantity, 0)
      else null end as calculated_closing_quantity,
      inv.actual_closing_quantity,
      case
        when inv.actual_closing_quantity is not null and scope.first_date = scope.baseline_effective_date then
          inv.actual_closing_quantity - (
            scope.baseline_quantity
              + coalesce(inv.receiving_quantity, 0)
              + coalesce(inv.transfer_in_quantity, 0)
              - coalesce(inv.transfer_out_quantity, 0)
              - coalesce(sales.quantity, 0)
              - coalesce(waste.quantity, 0)
          )
        else null
      end as variance_quantity,
      inv.created_at as entry_created_at,
      inv.updated_at as entry_updated_at
    from item_scope scope
    left join inventory_movements inv
      on inv.inventory_item_id = scope.inventory_item_id
     and inv.business_date = scope.first_date
    left join sales_movements sales
      on sales.inventory_item_id = scope.inventory_item_id
     and sales.business_date = scope.first_date
    left join waste_movements waste
      on waste.inventory_item_id = scope.inventory_item_id
     and waste.business_date = scope.first_date
    where scope.first_date <= through_date

    union all

    select
      prior.organization_id,
      prior.branch_id,
      (prior.business_date + 1)::date,
      prior.inventory_item_id,
      coalesce(inv.inventory_item_name_snapshot, prior.inventory_item_name),
      coalesce(inv.inventory_item_unit_snapshot, prior.inventory_item_unit),
      inv.entry_id,
      prior.baseline_effective_date,
      prior.manual_opening_quantity,
      coalesce(prior.actual_closing_quantity, prior.calculated_closing_quantity) as opening_quantity,
      coalesce(inv.receiving_quantity, 0),
      coalesce(inv.transfer_in_quantity, 0),
      coalesce(inv.transfer_out_quantity, 0),
      coalesce(sales.quantity, 0),
      coalesce(waste.quantity, 0),
      case when coalesce(prior.actual_closing_quantity, prior.calculated_closing_quantity) is not null then
        coalesce(prior.actual_closing_quantity, prior.calculated_closing_quantity)
          + coalesce(inv.receiving_quantity, 0)
          + coalesce(inv.transfer_in_quantity, 0)
          - coalesce(inv.transfer_out_quantity, 0)
          - coalesce(sales.quantity, 0)
          - coalesce(waste.quantity, 0)
      else null end,
      inv.actual_closing_quantity,
      case
        when inv.actual_closing_quantity is not null
          and coalesce(prior.actual_closing_quantity, prior.calculated_closing_quantity) is not null
        then inv.actual_closing_quantity - (
          coalesce(prior.actual_closing_quantity, prior.calculated_closing_quantity)
            + coalesce(inv.receiving_quantity, 0)
            + coalesce(inv.transfer_in_quantity, 0)
            - coalesce(inv.transfer_out_quantity, 0)
            - coalesce(sales.quantity, 0)
            - coalesce(waste.quantity, 0)
        )
        else null
      end,
      inv.created_at,
      inv.updated_at
    from balance prior
    left join inventory_movements inv
      on inv.inventory_item_id = prior.inventory_item_id
     and inv.business_date = (prior.business_date + 1)::date
    left join sales_movements sales
      on sales.inventory_item_id = prior.inventory_item_id
     and sales.business_date = (prior.business_date + 1)::date
    left join waste_movements waste
      on waste.inventory_item_id = prior.inventory_item_id
     and waste.business_date = (prior.business_date + 1)::date
    where prior.business_date < through_date
  )
  select * from balance;
$$;

revoke all on function private.branch_daily_inventory_balance_rows(uuid, uuid, date) from public, anon, authenticated;

create or replace function private.branch_daily_inventory_payload(actor_user_id uuid, target_branch_id uuid, target_business_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_daily_inventory_reports%rowtype;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if target_business_date is null then
    raise exception 'daily inventory business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'daily inventory future business date denied' using errcode = '22023';
  end if;

  select * into report
  from public.branch_daily_inventory_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'organization_id', ctx.organization_id,
    'branch_id', ctx.branch_id,
    'business_date', target_business_date,
    'current_business_date', ctx.business_date,
    'revision', coalesce(report.revision, 0),
    'created_at', report.created_at,
    'updated_at', report.updated_at,
    'entries', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', row.entry_id,
          'inventory_item_id', row.inventory_item_id,
          'inventory_item_name_snapshot', row.inventory_item_name,
          'inventory_item_unit_snapshot', row.inventory_item_unit,
          'baseline_effective_date', row.baseline_effective_date,
          'manual_opening_quantity', case when row.business_date = row.baseline_effective_date then row.manual_opening_quantity else null end,
          'opening_quantity', row.opening_quantity,
          'is_opening_manual', (row.business_date = row.baseline_effective_date),
          'receiving_quantity', row.receiving_quantity,
          'transfer_in_quantity', row.transfer_in_quantity,
          'transfer_out_quantity', row.transfer_out_quantity,
          'sales_usage_quantity', row.sales_usage_quantity,
          'wastage_quantity', row.wastage_quantity,
          'expected_closing_quantity', row.calculated_closing_quantity,
          'actual_closing_quantity', row.actual_closing_quantity,
          'variance_quantity', row.variance_quantity,
          'created_at', row.entry_created_at,
          'updated_at', row.entry_updated_at
        ) order by pg_catalog.lower(row.inventory_item_name), row.inventory_item_id
      )
      from private.branch_daily_inventory_balance_rows(ctx.organization_id, ctx.branch_id, target_business_date) row
      where row.business_date = target_business_date
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'daily inventory access denied' using errcode = '42501';
end;
$$;

create or replace function public.get_branch_daily_inventory(
  actor_user_id uuid,
  target_branch_id uuid,
  start_date date,
  end_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ctx record;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if start_date is null or end_date is null then raise exception 'daily inventory date range required' using errcode = '22004'; end if;
  if start_date > end_date or (end_date - start_date) > 62 then raise exception 'daily inventory invalid date range' using errcode = '22023'; end if;
  if end_date > ctx.business_date then raise exception 'daily inventory future business date denied' using errcode = '22023'; end if;

  return pg_catalog.jsonb_build_object(
    'organization_id', ctx.organization_id,
    'branch_id', ctx.branch_id,
    'start_date', start_date,
    'end_date', end_date,
    'current_business_date', ctx.business_date,
    'reports', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'report_id', report.id,
          'organization_id', ctx.organization_id,
          'branch_id', ctx.branch_id,
          'business_date', calendar.day_date,
          'revision', coalesce(report.revision, 0),
          'created_at', report.created_at,
          'updated_at', report.updated_at,
          'entries', coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'id', row.entry_id,
                'inventory_item_id', row.inventory_item_id,
                'inventory_item_name_snapshot', row.inventory_item_name,
                'inventory_item_unit_snapshot', row.inventory_item_unit,
                'baseline_effective_date', row.baseline_effective_date,
                'manual_opening_quantity', case when row.business_date = row.baseline_effective_date then row.manual_opening_quantity else null end,
                'opening_quantity', row.opening_quantity,
                'is_opening_manual', (row.business_date = row.baseline_effective_date),
                'receiving_quantity', row.receiving_quantity,
                'transfer_in_quantity', row.transfer_in_quantity,
                'transfer_out_quantity', row.transfer_out_quantity,
                'sales_usage_quantity', row.sales_usage_quantity,
                'wastage_quantity', row.wastage_quantity,
                'expected_closing_quantity', row.calculated_closing_quantity,
                'actual_closing_quantity', row.actual_closing_quantity,
                'variance_quantity', row.variance_quantity,
                'created_at', row.entry_created_at,
                'updated_at', row.entry_updated_at
              ) order by pg_catalog.lower(row.inventory_item_name), row.inventory_item_id
            )
            from private.branch_daily_inventory_balance_rows(ctx.organization_id, ctx.branch_id, end_date) row
            where row.business_date = calendar.day_date
          ), '[]'::jsonb)
        ) order by calendar.day_date
      )
      from (
        select (start_date + offset_value)::date as day_date
        from pg_catalog.generate_series(0, end_date - start_date) offset_value
      ) calendar
      left join public.branch_daily_inventory_reports report
        on report.organization_id = ctx.organization_id
       and report.branch_id = ctx.branch_id
       and report.business_date = calendar.day_date
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'daily inventory access denied' using errcode = '42501';
end;
$$;

create or replace function public.list_managed_daily_inventory_reconciliation(
  actor_user_id uuid,
  target_organization_id uuid,
  from_date date,
  to_date date,
  target_branch_id uuid default null,
  target_inventory_item_id uuid default null,
  requested_page integer default 1,
  requested_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  page_offset integer;
  result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then raise exception 'daily inventory reconciliation report access denied' using errcode = '42501'; end if;
  if from_date is null or to_date is null then raise exception 'date range required' using errcode = '22004'; end if;
  if from_date > to_date then raise exception 'invalid date range' using errcode = '22023'; end if;
  if (to_date - from_date) > 90 then raise exception 'date range exceeds maximum of 90 days' using errcode = '22023'; end if;
  if requested_page < 1 or requested_page_size not between 1 and 100 then raise exception 'invalid pagination parameters' using errcode = '22023'; end if;
  if target_branch_id is not null and not exists (select 1 from public.branches b where b.id = target_branch_id and b.organization_id = target_organization_id and b.active) then raise exception 'daily inventory reconciliation report access denied' using errcode = '42501'; end if;
  if target_inventory_item_id is not null and not exists (select 1 from public.branch_inventory_catalog_items i where i.id = target_inventory_item_id and i.organization_id = target_organization_id) then raise exception 'daily inventory reconciliation report access denied' using errcode = '42501'; end if;
  page_offset := (requested_page - 1) * requested_page_size;

  with rows as (
    select
      balance.*,
      branch.name as branch_name,
      report.revision as report_revision,
      report.created_at as report_created_at,
      report.updated_at as report_updated_at,
      report.created_by_user_id,
      count(*) over() as total_count,
      row_number() over(order by balance.business_date desc, branch.name, pg_catalog.lower(balance.inventory_item_name), balance.inventory_item_id) as row_num
    from public.branches branch
    cross join lateral private.branch_daily_inventory_balance_rows(target_organization_id, branch.id, to_date) balance
    left join public.branch_daily_inventory_reports report
      on report.organization_id = target_organization_id and report.branch_id = branch.id and report.business_date = balance.business_date
    where branch.organization_id = target_organization_id
      and branch.active
      and balance.business_date between from_date and to_date
      and (target_branch_id is null or branch.id = target_branch_id)
      and (target_inventory_item_id is null or balance.inventory_item_id = target_inventory_item_id)
      and (
        balance.entry_id is not null
        or balance.sales_usage_quantity <> 0
        or balance.wastage_quantity <> 0
      )
  )
  select pg_catalog.jsonb_build_object(
    'rows', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'business_date', row.business_date,
      'branch_id', row.branch_id,
      'branch_name', row.branch_name,
      'inventory_item_id', row.inventory_item_id,
      'inventory_item_name', row.inventory_item_name,
      'inventory_item_unit', row.inventory_item_unit,
      'opening_quantity', row.opening_quantity,
      'receiving_quantity', row.receiving_quantity,
      'transfer_in_quantity', row.transfer_in_quantity,
      'transfer_out_quantity', row.transfer_out_quantity,
      'sales_usage_quantity', row.sales_usage_quantity,
      'wastage_quantity', row.wastage_quantity,
      'expected_closing_quantity', row.calculated_closing_quantity,
      'actual_closing_quantity', row.actual_closing_quantity,
      'variance_quantity', row.variance_quantity,
      'report_revision', coalesce(row.report_revision, 0),
      'report_created_at', row.report_created_at,
      'report_updated_at', row.report_updated_at,
      'created_by_user_id', row.created_by_user_id
    ) order by row.row_num) from rows row where row.row_num > page_offset and row.row_num <= page_offset + requested_page_size), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total_rows', coalesce((select max(row.total_count) from rows row), 0),
    'total_pages', case when coalesce((select max(row.total_count) from rows row), 0) = 0 then 0 else ceil((select max(row.total_count) from rows row)::numeric / requested_page_size)::integer end,
    'from_date', from_date,
    'to_date', to_date
  ) into result;
  return result;
end;
$$;

create or replace function public.list_managed_daily_inventory_branch_overview(
  actor_user_id uuid,
  target_organization_id uuid,
  target_business_date date,
  target_branch_id uuid default null,
  attention_filter text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then raise exception 'daily inventory branch overview access denied' using errcode = '42501'; end if;
  if target_business_date is null then raise exception 'business date required' using errcode = '22004'; end if;
  if target_branch_id is not null and not exists (
    select 1 from public.branches branch
    where branch.id = target_branch_id and branch.organization_id = target_organization_id and branch.active
  ) then raise exception 'daily inventory branch overview access denied' using errcode = '42501'; end if;
  if attention_filter is not null and attention_filter not in ('all','needs_attention','no_submission') then raise exception 'invalid attention filter' using errcode = '22023'; end if;

  with authorized_branches as (
    select b.id, b.name, b.code
    from public.branches b
    where b.organization_id = target_organization_id and b.active and (target_branch_id is null or b.id = target_branch_id)
  ), summaries as (
    select
      branch.id as branch_id,
      branch.name as branch_name,
      branch.code as branch_code,
      target_business_date as business_date,
      (report.id is not null) as has_submission,
      count(balance.inventory_item_id)::integer as total_entries_count,
      count(*) filter (where balance.inventory_item_id is not null and balance.actual_closing_quantity is not null)::integer as items_checked_count,
      count(*) filter (where balance.inventory_item_id is not null and balance.variance_quantity is not null and balance.variance_quantity <> 0)::integer as variance_items_count,
      count(*) filter (where balance.inventory_item_id is not null and balance.actual_closing_quantity is null)::integer as missing_closing_count,
      count(*) filter (where balance.inventory_item_id is not null and balance.calculated_closing_quantity is null)::integer as unreconciled_items_count
    from authorized_branches branch
    left join public.branch_daily_inventory_reports report
      on report.organization_id = target_organization_id and report.branch_id = branch.id and report.business_date = target_business_date
    left join lateral (
      select row.* from private.branch_daily_inventory_balance_rows(target_organization_id, branch.id, target_business_date) row
      where row.business_date = target_business_date
    ) balance on true
    group by branch.id, branch.name, branch.code, report.id
  ), classified as (
    select summaries.*,
      case
        when not has_submission then 'no_submission'
        when total_entries_count = 0 or variance_items_count > 0 or unreconciled_items_count > 0 then 'needs_attention'
        else 'clear'
      end as attention_status
    from summaries
  ), filtered as (
    select * from classified
    where attention_filter is null or attention_filter = 'all' or attention_status = attention_filter
  )
  select pg_catalog.jsonb_build_object(
    'business_date', target_business_date,
    'rows', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'branch_id', row.branch_id, 'branch_name', row.branch_name, 'branch_code', row.branch_code,
      'business_date', row.business_date, 'has_submission', row.has_submission,
      'total_entries_count', row.total_entries_count, 'items_checked_count', row.items_checked_count,
      'variance_items_count', row.variance_items_count, 'missing_closing_count', row.missing_closing_count,
      'unreconciled_items_count', row.unreconciled_items_count, 'attention_status', row.attention_status
    ) order by row.branch_name, row.branch_id) from filtered row), '[]'::jsonb),
    'total_branches', (select count(*)::integer from classified),
    'needs_attention_count', (select count(*) filter (where attention_status = 'needs_attention')::integer from classified),
    'no_submission_count', (select count(*) filter (where attention_status = 'no_submission')::integer from classified),
    'clear_count', (select count(*) filter (where attention_status = 'clear')::integer from classified)
  ) into result;
  return result;
end;
$$;

revoke all on function private.branch_daily_inventory_payload(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.get_branch_daily_inventory(uuid, uuid, date, date) from public, anon, authenticated;
revoke all on function public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer) from public, anon, authenticated;
revoke all on function public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text) from public, anon, authenticated;
grant execute on function public.get_branch_daily_inventory(uuid, uuid, date, date) to service_role;
grant execute on function public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer) to service_role;
grant execute on function public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text) to service_role;
