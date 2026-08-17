create or replace function private.validate_inventory_item_usage(item_usage jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare usage_month date; days_in_month integer; item_value jsonb; usage_value jsonb; usage_day text; usage_quantity jsonb; day_number integer; raw_name text;
begin
  if pg_catalog.jsonb_typeof(item_usage) <> 'object'
    or not (item_usage ? 'usage_month')
    or not (item_usage ? 'items')
    or pg_catalog.jsonb_typeof(item_usage -> 'items') <> 'array'
    or pg_catalog.jsonb_array_length(item_usage -> 'items') > 200
  then
    raise exception 'invalid item usage' using errcode = '22023';
  end if;
  usage_month := private.inventory_items_month_field(item_usage, 'usage_month');
  days_in_month := extract(day from (usage_month + interval '1 month - 1 day'));
  for item_value in select item_entry.value from pg_catalog.jsonb_array_elements(item_usage -> 'items') item_entry(value) loop
    raw_name := pg_catalog.btrim(coalesce(item_value ->> 'item_name', ''));
    if raw_name = '' or pg_catalog.length(raw_name) > 160 then
      raise exception 'invalid inventory item name' using errcode = '22023';
    end if;
    if pg_catalog.length(pg_catalog.btrim(coalesce(item_value ->> 'group_name', 'Liwa'))) > 120 then
      raise exception 'invalid inventory group name' using errcode = '22023';
    end if;
    if not (item_value ? 'usage') or pg_catalog.jsonb_typeof(item_value -> 'usage') <> 'object' then
      raise exception 'invalid item usage values' using errcode = '22023';
    end if;
    usage_value := item_value -> 'usage';
    for usage_day, usage_quantity in select entry.key, entry.value from pg_catalog.jsonb_each(usage_value) entry(key,value) loop
      if usage_day !~ '^[0-9]+$' then
        raise exception 'invalid inventory day number' using errcode = '22023';
      end if;
      day_number := usage_day::integer;
      if day_number < 1 or day_number > days_in_month then
        raise exception 'invalid inventory day number' using errcode = '22023';
      end if;
      perform private.inventory_items_numeric_field(pg_catalog.jsonb_build_object('quantity', usage_quantity), 'quantity');
    end loop;
  end loop;
end $$;
revoke all on function private.validate_inventory_item_usage(jsonb) from public, anon, authenticated;

create or replace function public.save_inventory_items_draft(actor_user_id uuid, target_branch_id uuid, beef_rows jsonb, item_usage jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare ctx record; report public.inventory_items_reports%rowtype; usage_month date; item_value jsonb; created_item public.inventory_item_usage_items%rowtype; sort_index integer := 0; usage_day text; usage_quantity jsonb;
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  perform private.validate_inventory_beef_rows(beef_rows);
  perform private.validate_inventory_item_usage(item_usage);
  usage_month := private.inventory_items_month_field(item_usage, 'usage_month');

  insert into public.inventory_items_reports(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state,
    branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot
  ) values (
    ctx.organization_id, ctx.branch_id, actor_user_id, ctx.team_id, ctx.business_date, 'draft',
    ctx.branch_name, ctx.supervisor_name, ctx.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_user_id, business_date) do update set
    state = 'draft',
    supervisor_team_id = excluded.supervisor_team_id,
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    supervisor_team_name_snapshot = excluded.supervisor_team_name_snapshot
  returning * into report;

  delete from public.inventory_beef_production_rows where report_id = report.id;
  delete from public.inventory_item_usage_items where report_id = report.id;

  insert into public.inventory_beef_production_rows(
    report_id, production_date, russian_kg, australian_kg, fat_kg, ready_patty, hunch_sauce_kg, wastage_grams
  )
  select report.id,
    private.inventory_items_date_field(row_value, 'production_date'),
    private.inventory_items_numeric_field(row_value, 'russian_kg'),
    private.inventory_items_numeric_field(row_value, 'australian_kg'),
    private.inventory_items_numeric_field(row_value, 'fat_kg'),
    private.inventory_items_numeric_field(row_value, 'ready_patty'),
    private.inventory_items_numeric_field(row_value, 'hunch_sauce_kg'),
    private.inventory_items_numeric_field(row_value, 'wastage_grams')
  from pg_catalog.jsonb_array_elements(beef_rows) entry(row_value);

  for item_value in select item_entry.value from pg_catalog.jsonb_array_elements(item_usage -> 'items') item_entry(value) loop
    sort_index := sort_index + 1;
    insert into public.inventory_item_usage_items(report_id, usage_month, group_name, item_name, sort_order)
    values (
      report.id,
      usage_month,
      coalesce(nullif(pg_catalog.btrim(item_value ->> 'group_name'), ''), 'Liwa'),
      pg_catalog.btrim(item_value ->> 'item_name'),
      sort_index
    )
    returning * into created_item;

    for usage_day, usage_quantity in select entry.key, entry.value from pg_catalog.jsonb_each(item_value -> 'usage') entry(key,value) loop
      insert into public.inventory_item_usage_day_values(item_id, day_number, quantity)
      values (created_item.id, usage_day::integer, private.inventory_items_numeric_field(pg_catalog.jsonb_build_object('quantity', usage_quantity), 'quantity'));
    end loop;
  end loop;

  return public.get_inventory_items_current_state(actor_user_id, target_branch_id);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory draft denied' using errcode = '42501';
end $$;
revoke all on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb) to service_role;
