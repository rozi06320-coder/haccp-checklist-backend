-- Inventory Items manager monthly reports.

create or replace function public.list_managed_inventory_items_reports(
  actor_user_id uuid,
  target_organization_id uuid,
  target_inventory_month date,
  optional_branch_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare selected_month date;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'inventory management report access denied' using errcode = '42501';
  end if;
  selected_month := coalesce(target_inventory_month, pg_catalog.date_trunc('month', pg_catalog.statement_timestamp())::date);
  if selected_month <> pg_catalog.date_trunc('month', selected_month)::date then
    raise exception 'invalid inventory report month' using errcode = '22023';
  end if;
  if optional_branch_id is not null and not private.managed_active_branch(actor_user_id, target_organization_id, optional_branch_id) then
    raise exception 'inventory management report access denied' using errcode = '42501';
  end if;

  return (
    with branch_rows as (
      select b.id, b.name, b.code
      from public.branches b
      where b.organization_id = target_organization_id
        and b.active
        and (optional_branch_id is null or b.id = optional_branch_id)
    ),
    selected_reports as (
      select
        branch.id branch_id,
        branch.name branch_name,
        branch.code branch_code,
        report.id report_id,
        report.business_date,
        report.inventory_month,
        report.state,
        report.supervisor_user_id,
        report.supervisor_team_id,
        report.supervisor_name_snapshot,
        report.supervisor_team_name_snapshot,
        report.updated_at,
        report.submitted_at
      from branch_rows branch
      left join lateral (
        select r.*
        from public.inventory_items_reports r
        where r.organization_id = target_organization_id
          and r.branch_id = branch.id
          and r.inventory_month = selected_month
        order by (r.state = 'submitted') desc, r.submitted_at desc nulls last, r.updated_at desc, r.id
        limit 1
      ) report on true
    ),
    shaped as (
      select
        report.*,
        coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'row_id', row.id,
            'production_date', row.production_date,
            'russian_kg', row.russian_kg,
            'australian_kg', row.australian_kg,
            'fat_kg', row.fat_kg,
            'total_kg', row.russian_kg + row.australian_kg + row.fat_kg,
            'ready_patty', row.ready_patty,
            'hunch_sauce_kg', row.hunch_sauce_kg,
            'wastage_grams', row.wastage_grams
          ) order by row.production_date)
          from public.inventory_beef_production_rows row
          where row.report_id = report.report_id
        ), '[]'::jsonb) beef_rows,
        coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'item_id', item.id,
            'group_name', item.group_name,
            'item_name', item.item_name,
            'usage', coalesce((
              select pg_catalog.jsonb_object_agg(value.day_number::text, value.quantity order by value.day_number)
              from public.inventory_item_usage_day_values value
              where value.item_id = item.id
            ), '{}'::jsonb),
            'total_usage', coalesce((
              select sum(value.quantity)
              from public.inventory_item_usage_day_values value
              where value.item_id = item.id
            ), 0)
          ) order by item.sort_order, item.item_name, item.id)
          from public.inventory_item_usage_items item
          where item.report_id = report.report_id
        ), '[]'::jsonb) item_usage_rows,
        coalesce((
          select sum(row.russian_kg)
          from public.inventory_beef_production_rows row
          where row.report_id = report.report_id
        ), 0) russian_kg_total,
        coalesce((
          select sum(row.australian_kg)
          from public.inventory_beef_production_rows row
          where row.report_id = report.report_id
        ), 0) australian_kg_total,
        coalesce((
          select sum(row.russian_kg + row.australian_kg + row.fat_kg)
          from public.inventory_beef_production_rows row
          where row.report_id = report.report_id
        ), 0) total_kg,
        coalesce((
          select sum(row.ready_patty)
          from public.inventory_beef_production_rows row
          where row.report_id = report.report_id
        ), 0) ready_patty_total,
        coalesce((
          select sum(row.hunch_sauce_kg)
          from public.inventory_beef_production_rows row
          where row.report_id = report.report_id
        ), 0) hunch_sauce_total,
        coalesce((
          select sum(row.wastage_grams)
          from public.inventory_beef_production_rows row
          where row.report_id = report.report_id
        ), 0) wastage_total,
        coalesce((
          select sum(value.quantity)
          from public.inventory_item_usage_items item
          join public.inventory_item_usage_day_values value on value.item_id = item.id
          where item.report_id = report.report_id
        ), 0) item_usage_total
      from selected_reports report
    )
    select pg_catalog.jsonb_build_object(
      'inventory_month', selected_month,
      'reports', coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'branch_id', branch_id,
        'branch_name', branch_name,
        'branch_code', branch_code,
        'inventory_month', selected_month,
        'status', case when report_id is null then 'not_submitted' else state end,
        'report_id', report_id,
        'business_date', business_date,
        'supervisor_user_id', supervisor_user_id,
        'submitted_by', case when state = 'submitted' then supervisor_name_snapshot else null end,
        'supervisor_team_id', supervisor_team_id,
        'supervisor_team_name', supervisor_team_name_snapshot,
        'updated_at', updated_at,
        'submitted_at', submitted_at,
        'summary', pg_catalog.jsonb_build_object(
          'russian_kg_total', russian_kg_total,
          'australian_kg_total', australian_kg_total,
          'total_kg', total_kg,
          'ready_patty_total', ready_patty_total,
          'hunch_sauce_total', hunch_sauce_total,
          'wastage_total', wastage_total,
          'item_usage_total', item_usage_total
        ),
        'beef_rows', beef_rows,
        'item_usage_rows', item_usage_rows
      ) order by branch_name, branch_code), '[]'::jsonb)
    )
    from shaped
  );
end $$;

revoke all on function public.list_managed_inventory_items_reports(uuid,uuid,date,uuid) from public, anon, authenticated;
grant execute on function public.list_managed_inventory_items_reports(uuid,uuid,date,uuid) to service_role;
