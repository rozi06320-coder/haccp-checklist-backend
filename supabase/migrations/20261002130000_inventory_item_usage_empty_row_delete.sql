-- Allow an authorized supervisor to tombstone an empty Item Usage row while its
-- branch/month Inventory Items report is still a draft.

alter table public.inventory_item_usage_items
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by_user_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.inventory_item_usage_items'::regclass
      and conname = 'inventory_item_usage_items_deleted_by_user_id_fkey'
  ) then
    alter table public.inventory_item_usage_items
      add constraint inventory_item_usage_items_deleted_by_user_id_fkey
      foreign key (deleted_by_user_id) references auth.users(id) on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.inventory_item_usage_items'::regclass
      and conname = 'inventory_item_usage_items_deleted_pair_check'
  ) then
    alter table public.inventory_item_usage_items
      add constraint inventory_item_usage_items_deleted_pair_check check (
        (deleted_at is null and deleted_by_user_id is null)
        or (deleted_at is not null and deleted_by_user_id is not null)
      );
  end if;
end $$;

create index if not exists inventory_item_usage_items_active_report_idx
  on public.inventory_item_usage_items(report_id, usage_month, sort_order, item_name)
  where deleted_at is null;

create or replace function private.protect_inventory_usage_item()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.deleted_at is not null or new.deleted_by_user_id is not null then
      raise exception 'new inventory item cannot be deleted' using errcode = '23505';
    end if;
    if not exists (
      select 1 from public.inventory_items_reports report
      where report.id = new.report_id and report.state = 'draft'
    ) then
      raise exception 'inventory month is closed' using errcode = '23505';
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE'
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
    and exists (
      select 1 from public.inventory_items_reports report
      where report.id = old.report_id and report.state = 'draft'
    )
    and not exists (
      select 1 from public.inventory_item_usage_day_values value
      where value.item_id = old.id
    )
  then
    return new;
  end if;

  raise exception 'saved inventory item is immutable' using errcode = '23505';
end $$;

revoke all on function private.protect_inventory_usage_item() from public, anon, authenticated;

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
  select * into strict ctx from private.phase4a_actor_context(p_actor_user_id, p_target_branch_id);
  selected_month := coalesce(p_target_inventory_month, pg_catalog.date_trunc('month', ctx.business_date)::date);
  if selected_month <> pg_catalog.date_trunc('month', selected_month)::date then
    raise exception 'invalid inventory month' using errcode = '22023';
  end if;

  select * into report
  from public.inventory_items_reports r
  where r.organization_id = ctx.organization_id
    and r.branch_id = ctx.branch_id
    and r.inventory_month = selected_month;

  select * into settings
  from public.branch_inventory_items_settings branch_settings
  where branch_settings.organization_id = ctx.organization_id
    and branch_settings.branch_id = ctx.branch_id;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'business_date', ctx.business_date,
    'inventory_month', selected_month,
    'state', coalesce(report.state, 'draft'),
    'updated_at', report.updated_at,
    'submitted_at', report.submitted_at,
    'beef_production_labels', pg_catalog.jsonb_build_object(
      'russian_label', settings.beef_russian_label,
      'australian_label', settings.beef_australian_label,
      'hunch_sauce_label', settings.beef_hunch_sauce_label
    ),
    'beef_rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', row.id,
        'production_date', row.production_date,
        'russian_kg', row.russian_kg,
        'australian_kg', row.australian_kg,
        'fat_kg', row.fat_kg,
        'total_kg', row.russian_kg + row.australian_kg + row.fat_kg,
        'ready_patty', row.ready_patty,
        'hunch_sauce_kg', row.hunch_sauce_kg,
        'wastage_grams', row.wastage_grams,
        'russian_label_snapshot', row.russian_label_snapshot,
        'australian_label_snapshot', row.australian_label_snapshot,
        'hunch_sauce_label_snapshot', row.hunch_sauce_label_snapshot
      ) order by row.production_date)
      from public.inventory_beef_production_rows row
      where row.report_id = report.id
    ), '[]'::jsonb),
    'item_usage', pg_catalog.jsonb_build_object(
      'usage_month', coalesce((
        select min(item.usage_month)
        from public.inventory_item_usage_items item
        where item.report_id = report.id
          and item.deleted_at is null
      ), selected_month),
      'items', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', item.id,
          'group_name', item.group_name,
          'item_name', item.item_name,
          'usage', coalesce((
            select pg_catalog.jsonb_object_agg(value.day_number::text, value.quantity order by value.day_number)
            from public.inventory_item_usage_day_values value
            where value.item_id = item.id
          ), '{}'::jsonb)
        ) order by item.sort_order, item.item_name, item.id)
        from public.inventory_item_usage_items item
        where item.report_id = report.id
          and item.deleted_at is null
      ), '[]'::jsonb)
    )
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory state denied' using errcode = '42501';
end $$;

revoke all on function private.inventory_items_state_json(uuid,uuid,date) from public, anon, authenticated;

create or replace function private.persist_inventory_items_daily_values(
  target_report_id uuid,
  target_inventory_month date,
  actor_user_id uuid,
  beef_rows jsonb,
  item_usage jsonb
)
returns void language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  beef_value jsonb;
  parsed_production_date date;
  parsed_russian_kg numeric;
  parsed_australian_kg numeric;
  parsed_fat_kg numeric;
  parsed_ready_patty numeric;
  parsed_hunch_sauce_kg numeric;
  parsed_wastage_grams numeric;
  existing_beef public.inventory_beef_production_rows%rowtype;
  settings public.branch_inventory_items_settings%rowtype;
  item_value jsonb;
  requested_item_id uuid;
  requested_group_name text;
  requested_item_name text;
  existing_item public.inventory_item_usage_items%rowtype;
  sort_index integer := 0;
  usage_day text;
  usage_quantity_json jsonb;
  parsed_usage_quantity numeric;
  existing_quantity numeric;
  inserted_count integer;
begin
  perform private.validate_inventory_item_usage(item_usage);
  if private.inventory_items_month_field(item_usage, 'usage_month') <> target_inventory_month then
    raise exception 'inventory usage month mismatch' using errcode = '22023';
  end if;
  perform private.validate_inventory_beef_rows_for_month(beef_rows, target_inventory_month);

  select branch_settings.* into settings
  from public.inventory_items_reports report
  left join public.branch_inventory_items_settings branch_settings
    on branch_settings.organization_id = report.organization_id
    and branch_settings.branch_id = report.branch_id
  where report.id = target_report_id;

  for beef_value in select value from pg_catalog.jsonb_array_elements(beef_rows) loop
    parsed_production_date := private.inventory_items_date_field(beef_value, 'production_date');
    parsed_russian_kg := private.inventory_items_numeric_field(beef_value, 'russian_kg');
    parsed_australian_kg := private.inventory_items_numeric_field(beef_value, 'australian_kg');
    parsed_fat_kg := private.inventory_items_numeric_field(beef_value, 'fat_kg');
    parsed_ready_patty := private.inventory_items_numeric_field(beef_value, 'ready_patty');
    parsed_hunch_sauce_kg := private.inventory_items_numeric_field(beef_value, 'hunch_sauce_kg');
    parsed_wastage_grams := private.inventory_items_numeric_field(beef_value, 'wastage_grams');

    insert into public.inventory_beef_production_rows(
      report_id, production_date, russian_kg, australian_kg, fat_kg, ready_patty, hunch_sauce_kg,
      wastage_grams, created_by, russian_label_snapshot, australian_label_snapshot, hunch_sauce_label_snapshot
    ) values (
      target_report_id,
      parsed_production_date,
      parsed_russian_kg,
      parsed_australian_kg,
      parsed_fat_kg,
      parsed_ready_patty,
      parsed_hunch_sauce_kg,
      parsed_wastage_grams,
      actor_user_id,
      private.inventory_items_label_snapshot(beef_value, 'russian_label_snapshot', coalesce(settings.beef_russian_label, 'Russian kg')),
      private.inventory_items_label_snapshot(beef_value, 'australian_label_snapshot', coalesce(settings.beef_australian_label, 'Australian kg')),
      private.inventory_items_label_snapshot(beef_value, 'hunch_sauce_label_snapshot', coalesce(settings.beef_hunch_sauce_label, 'Hunch sauce kg'))
    ) on conflict(report_id, production_date) do nothing;
    get diagnostics inserted_count = row_count;

    if inserted_count = 0 then
      select * into strict existing_beef
      from public.inventory_beef_production_rows row
      where row.report_id = target_report_id and row.production_date = parsed_production_date;
      if existing_beef.russian_kg is distinct from parsed_russian_kg
        or existing_beef.australian_kg is distinct from parsed_australian_kg
        or existing_beef.fat_kg is distinct from parsed_fat_kg
        or existing_beef.ready_patty is distinct from parsed_ready_patty
        or existing_beef.hunch_sauce_kg is distinct from parsed_hunch_sauce_kg
        or existing_beef.wastage_grams is distinct from parsed_wastage_grams
      then
        raise exception 'saved inventory beef day is immutable' using errcode = '23505';
      end if;
    end if;
  end loop;

  for item_value in select value from pg_catalog.jsonb_array_elements(item_usage -> 'items') loop
    sort_index := sort_index + 1;
    requested_group_name := coalesce(nullif(pg_catalog.btrim(item_value ->> 'group_name'), ''), 'Liwa');
    requested_item_name := pg_catalog.btrim(item_value ->> 'item_name');
    begin
      requested_item_id := nullif(pg_catalog.btrim(item_value ->> 'item_id'), '')::uuid;
    exception when invalid_text_representation then
      raise exception 'invalid inventory item id' using errcode = '22023';
    end;

    if requested_item_id is not null then
      select * into existing_item
      from public.inventory_item_usage_items item
      where item.id = requested_item_id
      for update;
      if existing_item.deleted_at is not null then
        raise exception 'deleted inventory item cannot be restored' using errcode = '23505';
      end if;
    else
      select * into existing_item
      from public.inventory_item_usage_items item
      where item.report_id = target_report_id
        and item.usage_month = target_inventory_month
        and item.group_name = requested_group_name
        and item.item_name = requested_item_name
        and item.deleted_at is null
      order by item.sort_order, item.id
      limit 1
      for update;
      if existing_item.id is null then
        select * into existing_item
        from public.inventory_item_usage_items item
        where item.report_id = target_report_id
          and item.usage_month = target_inventory_month
          and item.group_name = requested_group_name
          and item.item_name = requested_item_name
          and item.deleted_at is not null
        order by item.deleted_at desc, item.id
        limit 1
        for update;
        if existing_item.id is not null then
          raise exception 'deleted inventory item cannot be restored' using errcode = '23505';
        end if;
      end if;
    end if;

    if existing_item.id is null then
      if requested_item_id is null then
        insert into public.inventory_item_usage_items(
          report_id, usage_month, group_name, item_name, sort_order, created_by
        ) values (
          target_report_id, target_inventory_month, requested_group_name, requested_item_name, sort_index, actor_user_id
        ) returning * into existing_item;
      else
        insert into public.inventory_item_usage_items(
          id, report_id, usage_month, group_name, item_name, sort_order, created_by
        ) values (
          requested_item_id, target_report_id, target_inventory_month, requested_group_name,
          requested_item_name, sort_index, actor_user_id
        ) returning * into existing_item;
      end if;
    elsif existing_item.report_id is distinct from target_report_id
      or existing_item.usage_month is distinct from target_inventory_month
      or existing_item.group_name is distinct from requested_group_name
      or existing_item.item_name is distinct from requested_item_name
    then
      raise exception 'saved inventory item is immutable' using errcode = '23505';
    end if;

    for usage_day, usage_quantity_json in select * from pg_catalog.jsonb_each(item_value -> 'usage') loop
      parsed_usage_quantity := private.inventory_items_numeric_field(
        pg_catalog.jsonb_build_object('quantity', usage_quantity_json),
        'quantity'
      );
      insert into public.inventory_item_usage_day_values(item_id, day_number, quantity, created_by)
      values (existing_item.id, usage_day::integer, parsed_usage_quantity, actor_user_id)
      on conflict(item_id, day_number) do nothing;
      get diagnostics inserted_count = row_count;

      if inserted_count = 0 then
        select value.quantity into strict existing_quantity
        from public.inventory_item_usage_day_values value
        where value.item_id = existing_item.id and value.day_number = usage_day::integer;
        if existing_quantity is distinct from parsed_usage_quantity then
          raise exception 'saved inventory item day is immutable' using errcode = '23505';
        end if;
      end if;
    end loop;
  end loop;

  if (
    select count(*)
    from public.inventory_item_usage_items item
    where item.report_id = target_report_id and item.deleted_at is null
  ) > 200 then
    raise exception 'too many inventory items' using errcode = '22023';
  end if;
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory daily persistence conflict' using errcode = '23505';
end $$;

revoke all on function private.persist_inventory_items_daily_values(uuid,date,uuid,jsonb,jsonb)
  from public, anon, authenticated;

create or replace function public.delete_inventory_item_usage_item(
  actor_user_id uuid,
  target_branch_id uuid,
  target_item_usage_id uuid
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ctx record;
  target_report_id uuid;
  target_inventory_month date;
  target_report public.inventory_items_reports%rowtype;
  target_item public.inventory_item_usage_items%rowtype;
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);

  select report.id, report.inventory_month into target_report_id, target_inventory_month
  from public.inventory_item_usage_items item
  join public.inventory_items_reports report on report.id = item.report_id
  where item.id = target_item_usage_id
    and report.organization_id = ctx.organization_id
    and report.branch_id = ctx.branch_id;

  if target_report_id is null then
    raise exception 'inventory item delete denied' using errcode = '42501';
  end if;

  perform private.lock_inventory_items_month(target_branch_id, target_inventory_month);

  select * into strict target_report
  from public.inventory_items_reports report
  where report.id = target_report_id
    and report.organization_id = ctx.organization_id
    and report.branch_id = ctx.branch_id
  for update;

  select * into strict target_item
  from public.inventory_item_usage_items item
  where item.id = target_item_usage_id
    and item.report_id = target_report.id
  for update;

  if target_report.state <> 'draft' then
    raise exception 'inventory month already submitted' using errcode = '23505';
  end if;
  if target_item.deleted_at is not null then
    raise exception 'inventory item already deleted' using errcode = '23505';
  end if;
  if exists (
    select 1 from public.inventory_item_usage_day_values value
    where value.item_id = target_item.id
  ) then
    raise exception 'inventory item has saved usage values' using errcode = '23505';
  end if;

  update public.inventory_item_usage_items item set
    deleted_at = pg_catalog.now(),
    deleted_by_user_id = actor_user_id
  where item.id = target_item.id;

  update public.inventory_items_reports report
  set updated_at = pg_catalog.now()
  where report.id = target_report.id;

  return private.inventory_items_state_json(actor_user_id, target_branch_id, target_report.inventory_month);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory item delete denied' using errcode = '42501';
end $$;

revoke all on function public.delete_inventory_item_usage_item(uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.delete_inventory_item_usage_item(uuid,uuid,uuid)
  to service_role;

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
        report.submitted_by_name_snapshot,
        report.updated_at,
        report.submitted_at
      from branch_rows branch
      left join public.inventory_items_reports report
        on report.organization_id = target_organization_id
        and report.branch_id = branch.id
        and report.inventory_month = selected_month
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
            and item.deleted_at is null
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
            and item.deleted_at is null
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
        'submitted_by', case when state = 'submitted' then submitted_by_name_snapshot else null end,
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

revoke all on function public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)
  from public, anon, authenticated;
grant execute on function public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)
  to service_role;

create or replace function public.get_managed_operations_summary(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  requested_month date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_month date;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'operations summary access denied' using errcode = '42501';
  end if;

  selected_month := coalesce(requested_month, pg_catalog.date_trunc('month', pg_catalog.statement_timestamp())::date);
  if selected_month <> pg_catalog.date_trunc('month', selected_month)::date then
    raise exception 'invalid operations summary month' using errcode = '22023';
  end if;

  if branch_filter is not null and not exists (
    select 1
    from public.branches branch
    where branch.id = branch_filter
      and branch.organization_id = target_organization_id
      and branch.active
  ) then
    raise exception 'operations summary access denied' using errcode = '42501';
  end if;

  return (
    with active_branches as (
      select branch.id
      from public.branches branch
      where branch.organization_id = target_organization_id
        and branch.active
        and (branch_filter is null or branch.id = branch_filter)
    ),
    purchase_logs as (
      select
        count(*)::integer as unpaid_count,
        coalesce(sum(log.amount), 0)::text as unpaid_amount,
        coalesce((select sum(total_log.amount) from public.branch_purchase_logs total_log where total_log.organization_id = target_organization_id and (branch_filter is null or total_log.branch_id = branch_filter)), 0)::text as total_amount
      from public.branch_purchase_logs log
      where log.organization_id = target_organization_id
        and (branch_filter is null or log.branch_id = branch_filter)
        and log.payment_status = 'unpaid'
    ),
    supplier_receivings as (
      select count(*)::integer as entry_count, count(distinct receiving.branch_id)::integer as branch_count
      from public.branch_supplier_receivings receiving
      where receiving.organization_id = target_organization_id
        and (branch_filter is null or receiving.branch_id = branch_filter)
    ),
    maintenance_issues as (
      select
        (count(*) filter (where issue.status in ('new', 'in_progress', 'waiting_parts')))::integer as open_count,
        (count(*) filter (where issue.status in ('new', 'in_progress', 'waiting_parts') and issue.priority in ('urgent', 'high')))::integer as urgent_high_count
      from public.maintenance_issues issue
      where issue.organization_id = target_organization_id
        and (branch_filter is null or issue.branch_id = branch_filter)
    ),
    maintenance_purchases as (
      select
        count(*)::integer as purchase_count,
        coalesce(sum(purchase.amount), 0)::text as total_amount,
        (count(*) filter (where purchase.payment_status = 'unpaid'))::integer as unpaid_count,
        coalesce(sum(purchase.amount) filter (where purchase.payment_status = 'unpaid'), 0)::text as unpaid_amount
      from public.maintenance_purchase_logs purchase
      where purchase.organization_id = target_organization_id
        and (branch_filter is null or purchase.branch_id = branch_filter)
    ),
    inventory_reports as (
      select report.id, report.branch_id, report.state
      from public.inventory_items_reports report
      join active_branches branch on branch.id = report.branch_id
      where report.organization_id = target_organization_id
        and report.inventory_month = selected_month
    ),
    inventory as (
      select
        (select count(*)::integer from active_branches) as active_branch_count,
        count(distinct report.branch_id)::integer as reported_branch_count,
        count(distinct report.branch_id) filter (where report.state = 'submitted')::integer as submitted_branch_count,
        coalesce((select count(*)::integer from public.inventory_beef_production_rows beef join inventory_reports report on report.id = beef.report_id), 0) as beef_row_count,
        coalesce((select count(*)::integer from public.inventory_item_usage_items item join inventory_reports report on report.id = item.report_id where item.deleted_at is null), 0) as item_usage_row_count
      from inventory_reports report
    ),
    financial_closing as (
      select private.managed_financial_closing_operations_summary(target_organization_id, branch_filter, pg_catalog.now()) summary
    ),
    staff as (
      select
        (count(*) filter (where member.employment_status = 'active'))::integer as active_count,
        (count(*) filter (where member.employment_status = 'inactive'))::integer as inactive_count
      from public.operational_staff member
      where member.organization_id = target_organization_id
        and (branch_filter is null or member.branch_id = branch_filter)
    )
    select pg_catalog.jsonb_build_object(
      'generated_at', pg_catalog.statement_timestamp(),
      'scope', pg_catalog.jsonb_build_object('organization_id', target_organization_id, 'branch_id', branch_filter, 'month', pg_catalog.to_char(selected_month, 'YYYY-MM')),
      'purchase_logs', pg_catalog.jsonb_build_object('unpaid_count', purchase_logs.unpaid_count, 'unpaid_amount', purchase_logs.unpaid_amount, 'total_amount', purchase_logs.total_amount),
      'supplier_receivings', pg_catalog.jsonb_build_object('entry_count', supplier_receivings.entry_count, 'branch_count', supplier_receivings.branch_count),
      'maintenance_issues', pg_catalog.jsonb_build_object('open_count', maintenance_issues.open_count, 'urgent_high_count', maintenance_issues.urgent_high_count),
      'maintenance_purchases', pg_catalog.jsonb_build_object('purchase_count', maintenance_purchases.purchase_count, 'total_amount', maintenance_purchases.total_amount, 'unpaid_count', maintenance_purchases.unpaid_count, 'unpaid_amount', maintenance_purchases.unpaid_amount),
      'inventory', pg_catalog.jsonb_build_object('active_branch_count', inventory.active_branch_count, 'reported_branch_count', inventory.reported_branch_count, 'submitted_branch_count', inventory.submitted_branch_count, 'beef_row_count', inventory.beef_row_count, 'item_usage_row_count', inventory.item_usage_row_count),
      'financial_closing', financial_closing.summary,
      'staff', pg_catalog.jsonb_build_object('active_count', staff.active_count, 'inactive_count', staff.inactive_count),
      'availability', pg_catalog.jsonb_build_object('purchase_logs', 'ready', 'supplier_receivings', 'ready', 'maintenance_issues', 'ready', 'maintenance_purchases', 'ready', 'inventory', 'ready', 'financial_closing', 'ready', 'staff', 'ready')
    )
    from purchase_logs, supplier_receivings, maintenance_issues, maintenance_purchases, inventory, financial_closing, staff
  );
end;
$$;

revoke all on function public.get_managed_operations_summary(uuid,uuid,uuid,date)
  from public, anon, authenticated;
grant execute on function public.get_managed_operations_summary(uuid,uuid,uuid,date)
  to service_role;

alter table public.inventory_item_usage_items enable row level security;
revoke all on public.inventory_item_usage_items from public, anon, authenticated;
