-- Allow authorized edits to a persisted Beef Production day while its month is draft.

alter table public.inventory_beef_production_rows
  add column if not exists updated_by_user_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.inventory_beef_production_rows'::regclass
      and conname = 'inventory_beef_production_rows_updated_by_user_id_fkey'
  ) then
    alter table public.inventory_beef_production_rows
      add constraint inventory_beef_production_rows_updated_by_user_id_fkey
      foreign key (updated_by_user_id) references auth.users(id) on delete restrict;
  end if;
end $$;

create or replace function private.protect_inventory_beef_daily_row()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'saved inventory beef day is immutable' using errcode = '23505';
  end if;

  if not exists (
    select 1
    from public.inventory_items_reports report
    where report.id = new.report_id
      and report.state = 'draft'
  ) then
    raise exception 'inventory month is closed' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' then
    if new.updated_by_user_id is not null then
      raise exception 'new inventory beef day cannot have an updater' using errcode = '23514';
    end if;
    return new;
  end if;

  if new.id is distinct from old.id
    or new.report_id is distinct from old.report_id
    or new.production_date is distinct from old.production_date
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
    or new.updated_at is distinct from old.updated_at
    or new.russian_label_snapshot is distinct from old.russian_label_snapshot
    or new.australian_label_snapshot is distinct from old.australian_label_snapshot
    or new.hunch_sauce_label_snapshot is distinct from old.hunch_sauce_label_snapshot
    or new.updated_by_user_id is null
  then
    raise exception 'saved inventory beef identity is immutable' using errcode = '23514';
  end if;

  return new;
end $$;

revoke all on function private.protect_inventory_beef_daily_row() from public, anon, authenticated;

create or replace function private.set_inventory_beef_production_updated_at()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare
  changed_at timestamptz := pg_catalog.clock_timestamp();
begin
  new.updated_at := case
    when changed_at > old.updated_at + interval '1 microsecond' then changed_at
    else old.updated_at + interval '1 microsecond'
  end;
  return new;
end $$;

revoke all on function private.set_inventory_beef_production_updated_at() from public, anon, authenticated;

drop trigger if exists inventory_beef_production_rows_set_updated_at on public.inventory_beef_production_rows;
create trigger inventory_beef_production_rows_set_updated_at
before update on public.inventory_beef_production_rows
for each row execute function private.set_inventory_beef_production_updated_at();

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
        'hunch_sauce_label_snapshot', row.hunch_sauce_label_snapshot,
        'updated_at', row.updated_at,
        'updated_by_user_id', row.updated_by_user_id
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

create or replace function public.update_inventory_beef_production_row(
  actor_user_id uuid,
  target_branch_id uuid,
  target_row_id uuid,
  expected_updated_at timestamptz,
  row_values jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  ctx record;
  target_inventory_month date;
  target_report public.inventory_items_reports%rowtype;
  target_row public.inventory_beef_production_rows%rowtype;
  parsed_russian_kg numeric;
  parsed_australian_kg numeric;
  parsed_fat_kg numeric;
  parsed_ready_patty numeric;
  parsed_hunch_sauce_kg numeric;
  parsed_wastage_grams numeric;
begin
  select * into strict ctx
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  select report.* into target_report
  from public.inventory_beef_production_rows beef
  join public.inventory_items_reports report on report.id = beef.report_id
  where beef.id = target_row_id;

  if target_report.id is null then
    raise exception 'inventory beef row not found' using errcode = 'P0002';
  end if;
  if target_report.organization_id <> ctx.organization_id
    or target_report.branch_id <> ctx.branch_id
  then
    raise exception 'inventory beef row update denied' using errcode = '42501';
  end if;
  target_inventory_month := target_report.inventory_month;

  perform private.lock_inventory_items_month(target_branch_id, target_inventory_month);

  select * into strict target_report
  from public.inventory_items_reports report
  where report.id = target_report.id
    and report.organization_id = ctx.organization_id
    and report.branch_id = ctx.branch_id
  for update;

  select * into strict target_row
  from public.inventory_beef_production_rows beef
  where beef.id = target_row_id
    and beef.report_id = target_report.id
  for update;

  if target_report.state <> 'draft' then
    raise exception 'inventory month already submitted' using errcode = '23514';
  end if;
  if expected_updated_at is null then
    raise exception 'inventory beef expected timestamp is required' using errcode = '23514';
  end if;
  if target_row.updated_at is distinct from expected_updated_at then
    raise exception 'inventory beef row changed' using errcode = '40001';
  end if;
  if pg_catalog.jsonb_typeof(row_values) <> 'object'
    or not row_values ?& array[
      'russian_kg', 'australian_kg', 'fat_kg', 'ready_patty', 'hunch_sauce_kg', 'wastage_grams'
    ]
    or exists (
      select 1
      from pg_catalog.jsonb_object_keys(row_values) as key_name
      where key_name <> all(array[
        'russian_kg', 'australian_kg', 'fat_kg', 'ready_patty', 'hunch_sauce_kg', 'wastage_grams'
      ])
    )
  then
    raise exception 'invalid inventory beef row values' using errcode = '23514';
  end if;

  parsed_russian_kg := private.inventory_items_numeric_field(row_values, 'russian_kg');
  parsed_australian_kg := private.inventory_items_numeric_field(row_values, 'australian_kg');
  parsed_fat_kg := private.inventory_items_numeric_field(row_values, 'fat_kg');
  parsed_ready_patty := private.inventory_items_numeric_field(row_values, 'ready_patty');
  parsed_hunch_sauce_kg := private.inventory_items_numeric_field(row_values, 'hunch_sauce_kg');
  parsed_wastage_grams := private.inventory_items_numeric_field(row_values, 'wastage_grams');

  update public.inventory_beef_production_rows beef set
    russian_kg = parsed_russian_kg,
    australian_kg = parsed_australian_kg,
    fat_kg = parsed_fat_kg,
    ready_patty = parsed_ready_patty,
    hunch_sauce_kg = parsed_hunch_sauce_kg,
    wastage_grams = parsed_wastage_grams,
    updated_by_user_id = actor_user_id
  where beef.id = target_row.id;

  update public.inventory_items_reports report
  set updated_at = pg_catalog.clock_timestamp()
  where report.id = target_report.id;

  return private.inventory_items_state_json(actor_user_id, target_branch_id, target_inventory_month);
exception
  when no_data_found then
    raise exception 'inventory beef row not found' using errcode = 'P0002';
  when too_many_rows then
    raise exception 'inventory beef row update conflict' using errcode = '23514';
end $$;

revoke all on function public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb)
  from public, anon, authenticated;
grant execute on function public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb)
  to service_role;
