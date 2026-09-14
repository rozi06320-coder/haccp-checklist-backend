-- Manager Tracking Read Model for Daily Inventory, Daily Usage, and Daily Wastage
-- Read-only queries across organizations with strict tenant isolation, snapshots, and reconciliation.

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
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'daily inventory reconciliation report access denied' using errcode = '42501';
  end if;

  if target_branch_id is not null and not exists (
    select 1 from public.branches b
    where b.id = target_branch_id and b.organization_id = target_organization_id and b.active
  ) then
    raise exception 'daily inventory reconciliation report access denied' using errcode = '42501';
  end if;

  if target_inventory_item_id is not null and not exists (
    select 1 from public.branch_inventory_catalog_items item
    where item.id = target_inventory_item_id and item.organization_id = target_organization_id
  ) then
    raise exception 'daily inventory reconciliation report access denied' using errcode = '42501';
  end if;

  if from_date is null or to_date is null then
    raise exception 'date range required' using errcode = '22004';
  end if;

  if from_date > to_date then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  if (to_date - from_date) > 90 then
    raise exception 'date range exceeds maximum of 90 days' using errcode = '22023';
  end if;

  if requested_page < 1 or requested_page_size not between 1 and 100 then
    raise exception 'invalid pagination parameters' using errcode = '22023';
  end if;

  page_offset := (requested_page - 1) * requested_page_size;

  with item_movements as (
    select
      entry.id as entry_id,
      entry.business_date,
      entry.branch_id,
      branch.name as branch_name,
      entry.inventory_item_id,
      entry.inventory_item_name_snapshot as inventory_item_name,
      entry.inventory_item_unit_snapshot as inventory_item_unit,
      case
        when extract(day from entry.business_date) = 1 then entry.manual_opening_quantity
        else (
          select prev_entry.actual_closing_quantity
          from public.branch_daily_inventory_entries prev_entry
          where prev_entry.organization_id = target_organization_id
            and prev_entry.branch_id = entry.branch_id
            and prev_entry.business_date = (entry.business_date - 1)
            and prev_entry.inventory_item_id = entry.inventory_item_id
        )
      end as opening_quantity,
      entry.receiving_quantity,
      entry.transfer_in_quantity,
      entry.transfer_out_quantity,
      coalesce((
        select sum(s.total_usage_quantity)
        from public.branch_product_sales_usage_snapshots s
        where s.organization_id = target_organization_id
          and s.branch_id = entry.branch_id
          and s.business_date = entry.business_date
          and s.inventory_item_id = entry.inventory_item_id
      ), 0) as sales_usage_quantity,
      coalesce((
        select sum(w.quantity)
        from public.branch_daily_waste_entries w
        where w.organization_id = target_organization_id
          and w.branch_id = entry.branch_id
          and w.business_date = entry.business_date
          and w.inventory_item_id = entry.inventory_item_id
      ), 0) as wastage_quantity,
      entry.actual_closing_quantity,
      report.revision as report_revision,
      report.created_at as report_created_at,
      report.updated_at as report_updated_at,
      report.created_by_user_id
    from public.branch_daily_inventory_entries entry
    join public.branch_daily_inventory_reports report
      on report.id = entry.report_id
    join public.branches branch
      on branch.id = entry.branch_id
    where entry.organization_id = target_organization_id
      and entry.business_date >= from_date
      and entry.business_date <= to_date
      and (target_branch_id is null or entry.branch_id = target_branch_id)
      and (target_inventory_item_id is null or entry.inventory_item_id = target_inventory_item_id)
  ),
  calculated_reconciliation as (
    select
      m.*,
      case
        when m.opening_quantity is not null then
          m.opening_quantity + m.receiving_quantity + m.transfer_in_quantity - m.transfer_out_quantity - m.sales_usage_quantity - m.wastage_quantity
        else null
      end as expected_closing_quantity
    from item_movements m
  ),
  reconciliation_rows as (
    select
      c.*,
      case
        when c.actual_closing_quantity is not null and c.expected_closing_quantity is not null then
          c.actual_closing_quantity - c.expected_closing_quantity
        else null
      end as variance_quantity,
      count(*) over() as total_count,
      row_number() over(
        order by c.business_date desc, c.branch_name asc, pg_catalog.lower(c.inventory_item_name) asc, c.entry_id desc
      ) as row_num
    from calculated_reconciliation c
  )
  select pg_catalog.jsonb_build_object(
    'rows', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'business_date', r.business_date,
          'branch_id', r.branch_id,
          'branch_name', r.branch_name,
          'inventory_item_id', r.inventory_item_id,
          'inventory_item_name', r.inventory_item_name,
          'inventory_item_unit', r.inventory_item_unit,
          'opening_quantity', r.opening_quantity,
          'receiving_quantity', r.receiving_quantity,
          'transfer_in_quantity', r.transfer_in_quantity,
          'transfer_out_quantity', r.transfer_out_quantity,
          'sales_usage_quantity', r.sales_usage_quantity,
          'wastage_quantity', r.wastage_quantity,
          'expected_closing_quantity', r.expected_closing_quantity,
          'actual_closing_quantity', r.actual_closing_quantity,
          'variance_quantity', r.variance_quantity,
          'report_revision', r.report_revision,
          'report_created_at', r.report_created_at,
          'report_updated_at', r.report_updated_at,
          'created_by_user_id', r.created_by_user_id
        ) order by r.row_num
      )
      from reconciliation_rows r
      where r.row_num > page_offset and r.row_num <= (page_offset + requested_page_size)
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total_rows', coalesce((select max(r.total_count) from reconciliation_rows r), 0),
    'total_pages', case
      when coalesce((select max(r.total_count) from reconciliation_rows r), 0) = 0 then 0
      else ceil((select max(r.total_count) from reconciliation_rows r)::numeric / requested_page_size)::integer
    end,
    'from_date', from_date,
    'to_date', to_date
  ) into result;

  return result;
end;
$$;

create or replace function public.list_managed_product_sales_usage(
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
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'managed product sales usage access denied' using errcode = '42501';
  end if;

  if target_branch_id is not null and not exists (
    select 1 from public.branches b
    where b.id = target_branch_id and b.organization_id = target_organization_id and b.active
  ) then
    raise exception 'managed product sales usage access denied' using errcode = '42501';
  end if;

  if target_inventory_item_id is not null and not exists (
    select 1 from public.branch_inventory_catalog_items item
    where item.id = target_inventory_item_id and item.organization_id = target_organization_id
  ) then
    raise exception 'managed product sales usage access denied' using errcode = '42501';
  end if;

  if from_date is null or to_date is null then
    raise exception 'date range required' using errcode = '22004';
  end if;

  if from_date > to_date then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  if (to_date - from_date) > 90 then
    raise exception 'date range exceeds maximum of 90 days' using errcode = '22023';
  end if;

  if requested_page < 1 or requested_page_size not between 1 and 100 then
    raise exception 'invalid pagination parameters' using errcode = '22023';
  end if;

  page_offset := (requested_page - 1) * requested_page_size;

  with usage_items as (
    select
      usage.id as usage_id,
      usage.business_date,
      usage.branch_id,
      branch.name as branch_name,
      usage.product_id,
      usage.product_name_snapshot,
      sale.product_unit_snapshot,
      usage.inventory_behavior_snapshot,
      usage.inventory_item_id,
      usage.inventory_item_name_snapshot,
      usage.inventory_item_unit_snapshot,
      usage.sales_quantity_snapshot as sales_quantity,
      usage.quantity_per_sale_snapshot,
      usage.total_usage_quantity,
      report.revision as report_revision,
      report.created_at as report_created_at,
      report.updated_at as report_updated_at,
      count(*) over() as total_count,
      row_number() over(
        order by usage.business_date desc, branch.name asc, pg_catalog.lower(usage.product_name_snapshot) asc, pg_catalog.lower(usage.inventory_item_name_snapshot) asc, usage.id desc
      ) as row_num
    from public.branch_product_sales_usage_snapshots usage
    join public.branch_product_sales sale
      on sale.id = usage.product_sale_id
    join public.branch_product_sales_daily_reports report
      on report.id = usage.report_id
    join public.branches branch
      on branch.id = usage.branch_id
    where usage.organization_id = target_organization_id
      and usage.business_date >= from_date
      and usage.business_date <= to_date
      and (target_branch_id is null or usage.branch_id = target_branch_id)
      and (target_inventory_item_id is null or usage.inventory_item_id = target_inventory_item_id)
  )
  select pg_catalog.jsonb_build_object(
    'rows', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'business_date', u.business_date,
          'branch_id', u.branch_id,
          'branch_name', u.branch_name,
          'product_id', u.product_id,
          'product_name_snapshot', u.product_name_snapshot,
          'product_unit_snapshot', u.product_unit_snapshot,
          'inventory_behavior_snapshot', u.inventory_behavior_snapshot,
          'inventory_item_id', u.inventory_item_id,
          'inventory_item_name_snapshot', u.inventory_item_name_snapshot,
          'inventory_item_unit_snapshot', u.inventory_item_unit_snapshot,
          'sales_quantity', u.sales_quantity,
          'quantity_per_sale_snapshot', u.quantity_per_sale_snapshot,
          'total_usage_quantity', u.total_usage_quantity,
          'report_revision', u.report_revision,
          'report_created_at', u.report_created_at,
          'report_updated_at', u.report_updated_at
        ) order by u.row_num
      )
      from usage_items u
      where u.row_num > page_offset and u.row_num <= (page_offset + requested_page_size)
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total_rows', coalesce((select max(u.total_count) from usage_items u), 0),
    'total_pages', case
      when coalesce((select max(u.total_count) from usage_items u), 0) = 0 then 0
      else ceil((select max(u.total_count) from usage_items u)::numeric / requested_page_size)::integer
    end,
    'from_date', from_date,
    'to_date', to_date
  ) into result;

  return result;
end;
$$;

create or replace function public.list_managed_daily_waste(
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
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'managed daily waste access denied' using errcode = '42501';
  end if;

  if target_branch_id is not null and not exists (
    select 1 from public.branches b
    where b.id = target_branch_id and b.organization_id = target_organization_id and b.active
  ) then
    raise exception 'managed daily waste access denied' using errcode = '42501';
  end if;

  if target_inventory_item_id is not null and not exists (
    select 1 from public.branch_inventory_catalog_items item
    where item.id = target_inventory_item_id and item.organization_id = target_organization_id
  ) then
    raise exception 'managed daily waste access denied' using errcode = '42501';
  end if;

  if from_date is null or to_date is null then
    raise exception 'date range required' using errcode = '22004';
  end if;

  if from_date > to_date then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  if (to_date - from_date) > 90 then
    raise exception 'date range exceeds maximum of 90 days' using errcode = '22023';
  end if;

  if requested_page < 1 or requested_page_size not between 1 and 100 then
    raise exception 'invalid pagination parameters' using errcode = '22023';
  end if;

  page_offset := (requested_page - 1) * requested_page_size;

  with waste_items as (
    select
      entry.id as entry_id,
      entry.business_date,
      entry.branch_id,
      branch.name as branch_name,
      entry.inventory_item_id,
      entry.inventory_item_name_snapshot,
      entry.inventory_item_unit_snapshot,
      entry.quantity,
      entry.note,
      report.revision as report_revision,
      report.created_at as report_created_at,
      report.updated_at as report_updated_at,
      count(*) over() as total_count,
      row_number() over(
        order by entry.business_date desc, branch.name asc, pg_catalog.lower(entry.inventory_item_name_snapshot) asc, entry.id desc
      ) as row_num
    from public.branch_daily_waste_entries entry
    join public.branch_daily_waste_reports report
      on report.id = entry.report_id
    join public.branches branch
      on branch.id = entry.branch_id
    where entry.organization_id = target_organization_id
      and entry.business_date >= from_date
      and entry.business_date <= to_date
      and (target_branch_id is null or entry.branch_id = target_branch_id)
      and (target_inventory_item_id is null or entry.inventory_item_id = target_inventory_item_id)
  )
  select pg_catalog.jsonb_build_object(
    'rows', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'business_date', w.business_date,
          'branch_id', w.branch_id,
          'branch_name', w.branch_name,
          'inventory_item_id', w.inventory_item_id,
          'inventory_item_name_snapshot', w.inventory_item_name_snapshot,
          'inventory_item_unit_snapshot', w.inventory_item_unit_snapshot,
          'quantity', w.quantity,
          'note', w.note,
          'report_revision', w.report_revision,
          'report_created_at', w.report_created_at,
          'report_updated_at', w.report_updated_at
        ) order by w.row_num
      )
      from waste_items w
      where w.row_num > page_offset and w.row_num <= (page_offset + requested_page_size)
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total_rows', coalesce((select max(w.total_count) from waste_items w), 0),
    'total_pages', case
      when coalesce((select max(w.total_count) from waste_items w), 0) = 0 then 0
      else ceil((select max(w.total_count) from waste_items w)::numeric / requested_page_size)::integer
    end,
    'from_date', from_date,
    'to_date', to_date
  ) into result;

  return result;
end;
$$;

revoke all on function public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer) from public, anon, authenticated;
grant execute on function public.list_managed_daily_inventory_reconciliation(uuid,uuid,date,date,uuid,uuid,integer,integer) to service_role;

revoke all on function public.list_managed_product_sales_usage(uuid,uuid,date,date,uuid,uuid,integer,integer) from public, anon, authenticated;
grant execute on function public.list_managed_product_sales_usage(uuid,uuid,date,date,uuid,uuid,integer,integer) to service_role;

revoke all on function public.list_managed_daily_waste(uuid,uuid,date,date,uuid,uuid,integer,integer) from public, anon, authenticated;
grant execute on function public.list_managed_daily_waste(uuid,uuid,date,date,uuid,uuid,integer,integer) to service_role;
