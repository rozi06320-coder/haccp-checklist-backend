-- Repair production drift from the Inventory Items Beef Production field-label rollout.
-- This migration is intentionally convergent because some environments received only
-- part of 20260927140000_inventory_beef_production_label.sql.

create table if not exists public.branch_inventory_items_settings (
  branch_id uuid primary key,
  organization_id uuid not null,
  beef_russian_label text,
  beef_australian_label text,
  beef_hunch_sauce_label text,
  updated_at timestamptz not null default pg_catalog.now(),
  updated_by uuid references auth.users(id) on delete restrict
);

alter table public.branch_inventory_items_settings
  add column if not exists branch_id uuid,
  add column if not exists organization_id uuid,
  add column if not exists beef_russian_label text,
  add column if not exists beef_australian_label text,
  add column if not exists beef_hunch_sauce_label text,
  add column if not exists updated_at timestamptz default pg_catalog.now(),
  add column if not exists updated_by uuid;

update public.branch_inventory_items_settings settings
set organization_id = branch.organization_id
from public.branches branch
where branch.id = settings.branch_id
  and settings.organization_id is null;

update public.branch_inventory_items_settings
set
  beef_russian_label = nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(beef_russian_label, '')), '[[:space:]]+', ' ', 'g'), ''),
  beef_australian_label = nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(beef_australian_label, '')), '[[:space:]]+', ' ', 'g'), ''),
  beef_hunch_sauce_label = nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(beef_hunch_sauce_label, '')), '[[:space:]]+', ' ', 'g'), ''),
  updated_at = coalesce(updated_at, pg_catalog.now());

alter table public.branch_inventory_items_settings
  alter column branch_id set not null,
  alter column organization_id set not null,
  alter column updated_at set default pg_catalog.now(),
  alter column updated_at set not null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.branch_inventory_items_settings'::regclass
      and contype = 'p'
  ) then
    alter table public.branch_inventory_items_settings
      add constraint branch_inventory_items_settings_pkey primary key (branch_id);
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.branch_inventory_items_settings'::regclass
      and conname = 'branch_inventory_items_settings_updated_by_fkey'
  ) then
    alter table public.branch_inventory_items_settings
      add constraint branch_inventory_items_settings_updated_by_fkey
      foreign key (updated_by) references auth.users(id) on delete restrict;
  end if;
end $$;

alter table public.branch_inventory_items_settings
  drop constraint if exists branch_inventory_items_settings_branch_fkey,
  drop constraint if exists branch_inventory_items_settings_beef_russian_label_check,
  drop constraint if exists branch_inventory_items_settings_beef_australian_label_check,
  drop constraint if exists branch_inventory_items_settings_beef_hunch_sauce_label_check;

alter table public.branch_inventory_items_settings
  add constraint branch_inventory_items_settings_branch_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete cascade,
  add constraint branch_inventory_items_settings_beef_russian_label_check check (
    beef_russian_label is null
    or (
      beef_russian_label = pg_catalog.btrim(beef_russian_label)
      and pg_catalog.length(beef_russian_label) between 1 and 120
    )
  ),
  add constraint branch_inventory_items_settings_beef_australian_label_check check (
    beef_australian_label is null
    or (
      beef_australian_label = pg_catalog.btrim(beef_australian_label)
      and pg_catalog.length(beef_australian_label) between 1 and 120
    )
  ),
  add constraint branch_inventory_items_settings_beef_hunch_sauce_label_check check (
    beef_hunch_sauce_label is null
    or (
      beef_hunch_sauce_label = pg_catalog.btrim(beef_hunch_sauce_label)
      and pg_catalog.length(beef_hunch_sauce_label) between 1 and 120
    )
  );

alter table public.branch_inventory_items_settings
  drop constraint if exists branch_inventory_items_settings_beef_production_label_check,
  drop column if exists beef_production_label;

alter table public.branch_inventory_items_settings enable row level security;
revoke all on public.branch_inventory_items_settings from public, anon, authenticated;

alter table public.inventory_beef_production_rows
  add column if not exists russian_label_snapshot text,
  add column if not exists australian_label_snapshot text,
  add column if not exists hunch_sauce_label_snapshot text;

alter table public.inventory_beef_production_rows
  drop constraint if exists inventory_beef_production_rows_russian_label_snapshot_check,
  drop constraint if exists inventory_beef_production_rows_australian_label_snapshot_check,
  drop constraint if exists inventory_beef_production_rows_hunch_sauce_label_snapshot_check;

alter table public.inventory_beef_production_rows
  add constraint inventory_beef_production_rows_russian_label_snapshot_check check (
    russian_label_snapshot is null
    or (
      russian_label_snapshot = pg_catalog.btrim(russian_label_snapshot)
      and pg_catalog.length(russian_label_snapshot) between 1 and 120
    )
  ),
  add constraint inventory_beef_production_rows_australian_label_snapshot_check check (
    australian_label_snapshot is null
    or (
      australian_label_snapshot = pg_catalog.btrim(australian_label_snapshot)
      and pg_catalog.length(australian_label_snapshot) between 1 and 120
    )
  ),
  add constraint inventory_beef_production_rows_hunch_sauce_label_snapshot_check check (
    hunch_sauce_label_snapshot is null
    or (
      hunch_sauce_label_snapshot = pg_catalog.btrim(hunch_sauce_label_snapshot)
      and pg_catalog.length(hunch_sauce_label_snapshot) between 1 and 120
    )
  );

create or replace function private.inventory_items_label_snapshot(row_value jsonb, field_name text, default_label text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  raw_value text := row_value ->> field_name;
  clean_value text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(raw_value, '')), '[[:space:]]+', ' ', 'g'), '');
begin
  clean_value := coalesce(clean_value, default_label);
  if clean_value is null or pg_catalog.length(clean_value) > 120 then
    raise exception 'invalid inventory label snapshot' using errcode = '22023';
  end if;
  return clean_value;
end $$;

revoke all on function private.inventory_items_label_snapshot(jsonb,text,text) from public, anon, authenticated;

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
      ), '[]'::jsonb)
    )
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory state denied' using errcode = '42501';
end $$;

revoke all on function private.inventory_items_state_json(uuid,uuid,date) from public, anon, authenticated;

create or replace function public.update_inventory_beef_production_field_labels(
  actor_user_id uuid,
  target_branch_id uuid,
  russian_label text,
  australian_label text,
  hunch_sauce_label text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ctx record;
  clean_russian text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(russian_label, '')), '[[:space:]]+', ' ', 'g'), '');
  clean_australian text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(australian_label, '')), '[[:space:]]+', ' ', 'g'), '');
  clean_hunch_sauce text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(hunch_sauce_label, '')), '[[:space:]]+', ' ', 'g'), '');
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  if pg_catalog.length(coalesce(clean_russian, '')) > 120
    or pg_catalog.length(coalesce(clean_australian, '')) > 120
    or pg_catalog.length(coalesce(clean_hunch_sauce, '')) > 120 then
    raise exception 'invalid beef production field labels' using errcode = '22023';
  end if;

  insert into public.branch_inventory_items_settings(
    branch_id, organization_id, beef_russian_label, beef_australian_label, beef_hunch_sauce_label, updated_at, updated_by
  ) values (
    ctx.branch_id, ctx.organization_id, clean_russian, clean_australian, clean_hunch_sauce, pg_catalog.now(), actor_user_id
  )
  on conflict(branch_id) do update set
    organization_id = excluded.organization_id,
    beef_russian_label = excluded.beef_russian_label,
    beef_australian_label = excluded.beef_australian_label,
    beef_hunch_sauce_label = excluded.beef_hunch_sauce_label,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  return pg_catalog.jsonb_build_object(
    'beef_production_labels', pg_catalog.jsonb_build_object(
      'russian_label', clean_russian,
      'australian_label', clean_australian,
      'hunch_sauce_label', clean_hunch_sauce
    )
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory label update denied' using errcode = '42501';
end $$;

revoke all on function public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)
  from public, anon, authenticated;
grant execute on function public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)
  to service_role;

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
    else
      select * into existing_item
      from public.inventory_item_usage_items item
      where item.report_id = target_report_id
        and item.usage_month = target_inventory_month
        and item.group_name = requested_group_name
        and item.item_name = requested_item_name
      order by item.sort_order, item.id
      limit 1
      for update;
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

  if (select count(*) from public.inventory_item_usage_items item where item.report_id = target_report_id) > 200 then
    raise exception 'too many inventory items' using errcode = '22023';
  end if;
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory daily persistence conflict' using errcode = '23505';
end $$;

revoke all on function private.persist_inventory_items_daily_values(uuid,date,uuid,jsonb,jsonb)
  from public, anon, authenticated;

create or replace function public.submit_inventory_items(
  p_actor_user_id uuid,
  p_target_branch_id uuid,
  p_idempotency_key uuid,
  p_request_hash text,
  beef_rows jsonb,
  item_usage jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  ctx record;
  report public.inventory_items_reports%rowtype;
  existing_idempotency public.inventory_items_submission_idempotency%rowtype;
  usage_month date;
  current_month date;
  current_month_last_date date;
  response_json jsonb;
begin
  select * into strict ctx from private.phase4a_actor_context(p_actor_user_id, p_target_branch_id);
  if p_idempotency_key is null or p_request_hash is null or pg_catalog.btrim(p_request_hash) = '' then
    raise exception 'invalid inventory idempotency' using errcode = '22023';
  end if;
  usage_month := private.inventory_items_month_field(item_usage, 'usage_month');
  perform private.validate_inventory_item_usage(item_usage);
  perform private.validate_inventory_beef_rows_for_month(beef_rows, usage_month);

  perform private.lock_inventory_items_month(p_target_branch_id, usage_month);
  select * into existing_idempotency
  from public.inventory_items_submission_idempotency idem
  where idem.actor_user_id = p_actor_user_id
    and idem.idempotency_key = p_idempotency_key;
  if existing_idempotency.actor_user_id is not null then
    if existing_idempotency.request_hash <> p_request_hash or not exists (
      select 1 from public.inventory_items_reports replay_report
      where replay_report.id = existing_idempotency.report_id
        and replay_report.organization_id = ctx.organization_id
        and replay_report.branch_id = ctx.branch_id
        and replay_report.inventory_month = usage_month
    ) then
      raise exception 'changed idempotency payload' using errcode = '23505';
    end if;
    return existing_idempotency.response_json;
  end if;

  current_month := pg_catalog.date_trunc('month', ctx.business_date)::date;
  current_month_last_date := (current_month + interval '1 month - 1 day')::date;
  if usage_month > current_month
    or (usage_month = current_month and ctx.business_date < current_month_last_date) then
    raise exception 'inventory month cannot be closed yet' using errcode = '22023';
  end if;

  if pg_catalog.jsonb_array_length(beef_rows) = 0 and not exists (
    select 1
    from pg_catalog.jsonb_array_elements(item_usage -> 'items') item
    where exists (select 1 from pg_catalog.jsonb_each(item -> 'usage'))
  ) then
    raise exception 'empty inventory submission' using errcode = '22023';
  end if;

  select * into report
  from public.inventory_items_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.inventory_month = usage_month
  for update;

  if report.id is not null and report.state = 'submitted' then
    raise exception 'inventory month already submitted' using errcode = '23505';
  end if;

  if report.id is null then
    insert into public.inventory_items_reports(
      organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, inventory_month, state,
      branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot
    ) values (
      ctx.organization_id, ctx.branch_id, p_actor_user_id, ctx.team_id, ctx.business_date, usage_month, 'draft',
      ctx.branch_name, ctx.supervisor_name, ctx.supervisor_name || ' Team'
    ) returning * into report;
  end if;

  perform private.persist_inventory_items_daily_values(
    report.id, usage_month, p_actor_user_id, beef_rows, item_usage
  );

  update public.inventory_items_reports existing set
    state = 'submitted',
    submitted_at = pg_catalog.now(),
    submitted_by_user_id = p_actor_user_id,
    submitted_by_name_snapshot = ctx.supervisor_name
  where existing.id = report.id
  returning * into report;

  response_json := private.inventory_items_state_json(p_actor_user_id, p_target_branch_id, usage_month);
  insert into public.inventory_items_submission_idempotency(actor_user_id, idempotency_key, request_hash, report_id, response_json)
  values (p_actor_user_id, p_idempotency_key, p_request_hash, report.id, response_json);
  return response_json;
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory submit denied' using errcode = '42501';
end $$;

revoke all on function public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)
  to service_role;
