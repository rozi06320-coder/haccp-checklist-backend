-- Manager Daily Inventory Branch Overview Read Model for ONE business date
-- Provides branch-level monitoring overview across all authorized active branches in an organization.

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
declare
  result jsonb;
begin
  -- 1. Authorization check
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'daily inventory branch overview access denied' using errcode = '42501';
  end if;

  -- 2. Validate target branch if provided
  if target_branch_id is not null and not exists (
    select 1 from public.branches b
    where b.id = target_branch_id and b.organization_id = target_organization_id and b.active
  ) then
    raise exception 'daily inventory branch overview access denied' using errcode = '42501';
  end if;

  -- 3. Validate target business date
  if target_business_date is null then
    raise exception 'business date required' using errcode = '22004';
  end if;

  -- 4. Validate attention filter
  if attention_filter is not null and attention_filter not in ('all', 'needs_attention', 'no_submission') then
    raise exception 'invalid attention filter' using errcode = '22023';
  end if;

  -- 5. Query and compute overview
  with authorized_branches as (
    select
      b.id as branch_id,
      b.name as branch_name,
      b.code as branch_code
    from public.branches b
    where b.organization_id = target_organization_id
      and b.active
      and (target_branch_id is null or b.id = target_branch_id)
  ),
  root_reports as (
    select
      r.id as report_id,
      r.branch_id,
      r.business_date
    from public.branch_daily_inventory_reports r
    where r.organization_id = target_organization_id
      and r.business_date = target_business_date
      and (target_branch_id is null or r.branch_id = target_branch_id)
  ),
  entries_movements as (
    select
      e.id as entry_id,
      e.branch_id,
      e.inventory_item_id,
      case
        when extract(day from e.business_date) = 1 then e.manual_opening_quantity
        else (
          select prev_entry.actual_closing_quantity
          from public.branch_daily_inventory_entries prev_entry
          where prev_entry.organization_id = target_organization_id
            and prev_entry.branch_id = e.branch_id
            and prev_entry.business_date = (e.business_date - 1)
            and prev_entry.inventory_item_id = e.inventory_item_id
        )
      end as opening_quantity,
      e.receiving_quantity,
      e.transfer_in_quantity,
      e.transfer_out_quantity,
      coalesce((
        select sum(s.total_usage_quantity)
        from public.branch_product_sales_usage_snapshots s
        where s.organization_id = target_organization_id
          and s.branch_id = e.branch_id
          and s.business_date = e.business_date
          and s.inventory_item_id = e.inventory_item_id
      ), 0) as sales_usage_quantity,
      coalesce((
        select sum(w.quantity)
        from public.branch_daily_waste_entries w
        where w.organization_id = target_organization_id
          and w.branch_id = e.branch_id
          and w.business_date = e.business_date
          and w.inventory_item_id = e.inventory_item_id
      ), 0) as wastage_quantity,
      e.actual_closing_quantity
    from public.branch_daily_inventory_entries e
    where e.organization_id = target_organization_id
      and e.business_date = target_business_date
      and (target_branch_id is null or e.branch_id = target_branch_id)
  ),
  entries_reconciled as (
    select
      em.branch_id,
      em.actual_closing_quantity,
      case
        when em.opening_quantity is not null then
          em.opening_quantity + em.receiving_quantity + em.transfer_in_quantity - em.transfer_out_quantity - em.sales_usage_quantity - em.wastage_quantity
        else null
      end as expected_closing_quantity,
      case
        when em.actual_closing_quantity is not null and (
          case
            when em.opening_quantity is not null then
              em.opening_quantity + em.receiving_quantity + em.transfer_in_quantity - em.transfer_out_quantity - em.sales_usage_quantity - em.wastage_quantity
            else null
          end
        ) is not null then
          em.actual_closing_quantity - (
            em.opening_quantity + em.receiving_quantity + em.transfer_in_quantity - em.transfer_out_quantity - em.sales_usage_quantity - em.wastage_quantity
          )
        else null
      end as variance_quantity
    from entries_movements em
  ),
  entries_aggregated as (
    select
      er.branch_id,
      count(*)::integer as total_entries_count,
      count(case when er.actual_closing_quantity is not null then 1 end)::integer as items_checked_count,
      count(case when er.actual_closing_quantity is null then 1 end)::integer as missing_closing_count,
      count(case when er.variance_quantity is not null and er.variance_quantity <> 0 then 1 end)::integer as variance_items_count,
      count(case when er.expected_closing_quantity is null then 1 end)::integer as unreconciled_items_count
    from entries_reconciled er
    group by er.branch_id
  ),
  branch_summaries as (
    select
      ab.branch_id,
      ab.branch_name,
      ab.branch_code,
      target_business_date as business_date,
      (rr.report_id is not null) as has_submission,
      coalesce(ea.total_entries_count, 0)::integer as total_entries_count,
      coalesce(ea.items_checked_count, 0)::integer as items_checked_count,
      coalesce(ea.variance_items_count, 0)::integer as variance_items_count,
      coalesce(ea.missing_closing_count, 0)::integer as missing_closing_count,
      coalesce(ea.unreconciled_items_count, 0)::integer as unreconciled_items_count,
      case
        when rr.report_id is null then 'no_submission'
        when coalesce(ea.total_entries_count, 0) = 0
          or coalesce(ea.missing_closing_count, 0) > 0
          or coalesce(ea.variance_items_count, 0) > 0
          or coalesce(ea.unreconciled_items_count, 0) > 0
        then 'needs_attention'
        else 'clear'
      end as attention_status
    from authorized_branches ab
    left join root_reports rr
      on rr.branch_id = ab.branch_id
    left join entries_aggregated ea
      on ea.branch_id = ab.branch_id
  ),
  global_counts as (
    select
      count(*)::integer as total_branches,
      count(case when bs.attention_status = 'needs_attention' then 1 end)::integer as needs_attention_count,
      count(case when bs.attention_status = 'no_submission' then 1 end)::integer as no_submission_count,
      count(case when bs.attention_status = 'clear' then 1 end)::integer as clear_count
    from branch_summaries bs
  ),
  filtered_rows as (
    select
      bs.branch_id,
      bs.branch_name,
      bs.branch_code,
      bs.business_date,
      bs.has_submission,
      bs.total_entries_count,
      bs.items_checked_count,
      bs.variance_items_count,
      bs.missing_closing_count,
      bs.unreconciled_items_count,
      bs.attention_status
    from branch_summaries bs
    where
      attention_filter is null
      or attention_filter = 'all'
      or bs.attention_status = attention_filter
    order by bs.branch_name asc, bs.branch_id asc
  )
  select pg_catalog.jsonb_build_object(
    'business_date', target_business_date,
    'rows', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'branch_id', fr.branch_id,
          'branch_name', fr.branch_name,
          'branch_code', fr.branch_code,
          'business_date', fr.business_date,
          'has_submission', fr.has_submission,
          'total_entries_count', fr.total_entries_count,
          'items_checked_count', fr.items_checked_count,
          'variance_items_count', fr.variance_items_count,
          'missing_closing_count', fr.missing_closing_count,
          'unreconciled_items_count', fr.unreconciled_items_count,
          'attention_status', fr.attention_status
        ) order by fr.branch_name asc, fr.branch_id asc
      )
      from filtered_rows fr
    ), '[]'::jsonb),
    'total_branches', coalesce((select gc.total_branches from global_counts gc), 0),
    'needs_attention_count', coalesce((select gc.needs_attention_count from global_counts gc), 0),
    'no_submission_count', coalesce((select gc.no_submission_count from global_counts gc), 0),
    'clear_count', coalesce((select gc.clear_count from global_counts gc), 0)
  ) into result;

  return result;
end;
$$;

revoke all on function public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text) from public, anon, authenticated;
grant execute on function public.list_managed_daily_inventory_branch_overview(uuid,uuid,date,uuid,text) to service_role;
