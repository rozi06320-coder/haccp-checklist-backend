-- Inventory Items daily persistence hardening.
-- Saved beef dates, item identities, and item/day values are append-only.

create or replace function private.prevent_inventory_report_reopen()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' and old.state = 'submitted' then
    raise exception 'submitted inventory month is immutable' using errcode = '23505';
  end if;
  if tg_op = 'UPDATE' and old.state = 'submitted' then
    raise exception 'submitted inventory month is immutable' using errcode = '23505';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end $$;
revoke all on function private.prevent_inventory_report_reopen() from public, anon, authenticated;

drop trigger if exists inventory_items_reports_prevent_reopen on public.inventory_items_reports;
create trigger inventory_items_reports_prevent_reopen
before update or delete on public.inventory_items_reports
for each row execute function private.prevent_inventory_report_reopen();

create or replace function private.protect_inventory_beef_daily_row()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'saved inventory beef day is immutable' using errcode = '23505';
  end if;
  if not exists (
    select 1 from public.inventory_items_reports report
    where report.id = new.report_id and report.state = 'draft'
  ) then
    raise exception 'inventory month is closed' using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function private.protect_inventory_beef_daily_row() from public, anon, authenticated;

drop trigger if exists inventory_beef_production_rows_immutable on public.inventory_beef_production_rows;
create trigger inventory_beef_production_rows_immutable
before insert or update or delete on public.inventory_beef_production_rows
for each row execute function private.protect_inventory_beef_daily_row();

create or replace function private.protect_inventory_usage_item()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'saved inventory item is immutable' using errcode = '23505';
  end if;
  if not exists (
    select 1 from public.inventory_items_reports report
    where report.id = new.report_id and report.state = 'draft'
  ) then
    raise exception 'inventory month is closed' using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function private.protect_inventory_usage_item() from public, anon, authenticated;

drop trigger if exists inventory_item_usage_items_immutable on public.inventory_item_usage_items;
create trigger inventory_item_usage_items_immutable
before insert or update or delete on public.inventory_item_usage_items
for each row execute function private.protect_inventory_usage_item();

create or replace function private.protect_inventory_usage_day_value()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'saved inventory item day is immutable' using errcode = '23505';
  end if;
  if not exists (
    select 1
    from public.inventory_item_usage_items item
    join public.inventory_items_reports report on report.id = item.report_id
    where item.id = new.item_id and report.state = 'draft'
  ) then
    raise exception 'inventory month is closed' using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function private.protect_inventory_usage_day_value() from public, anon, authenticated;

drop trigger if exists inventory_item_usage_day_values_immutable on public.inventory_item_usage_day_values;
create trigger inventory_item_usage_day_values_immutable
before insert or update or delete on public.inventory_item_usage_day_values
for each row execute function private.protect_inventory_usage_day_value();

create or replace function private.lock_inventory_items_month(actor_user_id uuid, target_branch_id uuid, target_inventory_month date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(actor_user_id::text || ':' || target_branch_id::text || ':' || target_inventory_month::text, 0)
  );
end $$;
revoke all on function private.lock_inventory_items_month(uuid,uuid,date) from public, anon, authenticated;

create or replace function private.persist_inventory_items_daily_values(
  target_report_id uuid,
  target_inventory_month date,
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

  for beef_value in select value from pg_catalog.jsonb_array_elements(beef_rows) loop
    parsed_production_date := private.inventory_items_date_field(beef_value, 'production_date');
    parsed_russian_kg := private.inventory_items_numeric_field(beef_value, 'russian_kg');
    parsed_australian_kg := private.inventory_items_numeric_field(beef_value, 'australian_kg');
    parsed_fat_kg := private.inventory_items_numeric_field(beef_value, 'fat_kg');
    parsed_ready_patty := private.inventory_items_numeric_field(beef_value, 'ready_patty');
    parsed_hunch_sauce_kg := private.inventory_items_numeric_field(beef_value, 'hunch_sauce_kg');
    parsed_wastage_grams := private.inventory_items_numeric_field(beef_value, 'wastage_grams');

    insert into public.inventory_beef_production_rows(
      report_id, production_date, russian_kg, australian_kg, fat_kg, ready_patty, hunch_sauce_kg, wastage_grams
    ) values (
      target_report_id, parsed_production_date, parsed_russian_kg, parsed_australian_kg, parsed_fat_kg,
      parsed_ready_patty, parsed_hunch_sauce_kg, parsed_wastage_grams
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
        insert into public.inventory_item_usage_items(report_id, usage_month, group_name, item_name, sort_order)
        values (target_report_id, target_inventory_month, requested_group_name, requested_item_name, sort_index)
        returning * into existing_item;
      else
        insert into public.inventory_item_usage_items(id, report_id, usage_month, group_name, item_name, sort_order)
        values (requested_item_id, target_report_id, target_inventory_month, requested_group_name, requested_item_name, sort_index)
        returning * into existing_item;
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
      insert into public.inventory_item_usage_day_values(item_id, day_number, quantity)
      values (existing_item.id, usage_day::integer, parsed_usage_quantity)
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
revoke all on function private.persist_inventory_items_daily_values(uuid,date,jsonb,jsonb) from public, anon, authenticated;

create or replace function public.save_inventory_items_draft(
  p_actor_user_id uuid,
  p_target_branch_id uuid,
  beef_rows jsonb,
  item_usage jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  ctx record;
  report public.inventory_items_reports%rowtype;
  usage_month date;
begin
  select * into strict ctx from private.phase4a_actor_context(p_actor_user_id, p_target_branch_id);
  usage_month := private.inventory_items_month_field(item_usage, 'usage_month');
  perform private.validate_inventory_item_usage(item_usage);
  perform private.validate_inventory_beef_rows_for_month(beef_rows, usage_month);
  perform private.lock_inventory_items_month(p_actor_user_id, p_target_branch_id, usage_month);

  select * into report
  from public.inventory_items_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.supervisor_user_id = p_actor_user_id
    and existing.inventory_month = usage_month
  limit 1
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
  else
    update public.inventory_items_reports existing set
      supervisor_team_id = ctx.team_id,
      business_date = ctx.business_date,
      branch_name_snapshot = ctx.branch_name,
      supervisor_name_snapshot = ctx.supervisor_name,
      supervisor_team_name_snapshot = ctx.supervisor_name || ' Team'
    where existing.id = report.id
    returning * into report;
  end if;

  perform private.persist_inventory_items_daily_values(report.id, usage_month, beef_rows, item_usage);
  return private.inventory_items_state_json(p_actor_user_id, p_target_branch_id, usage_month);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory draft denied' using errcode = '42501';
end $$;

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
  response_json jsonb;
begin
  select * into strict ctx from private.phase4a_actor_context(p_actor_user_id, p_target_branch_id);
  if p_idempotency_key is null or p_request_hash is null or pg_catalog.btrim(p_request_hash) = '' then
    raise exception 'invalid inventory idempotency' using errcode = '22023';
  end if;
  usage_month := private.inventory_items_month_field(item_usage, 'usage_month');
  perform private.validate_inventory_item_usage(item_usage);
  perform private.validate_inventory_beef_rows_for_month(beef_rows, usage_month);
  if pg_catalog.jsonb_array_length(beef_rows) = 0 and pg_catalog.jsonb_array_length(item_usage -> 'items') = 0 then
    raise exception 'empty inventory submission' using errcode = '22023';
  end if;

  perform private.lock_inventory_items_month(p_actor_user_id, p_target_branch_id, usage_month);
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
        and replay_report.supervisor_user_id = p_actor_user_id
        and replay_report.inventory_month = usage_month
    ) then
      raise exception 'changed idempotency payload' using errcode = '23505';
    end if;
    return existing_idempotency.response_json;
  end if;

  select * into report
  from public.inventory_items_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.supervisor_user_id = p_actor_user_id
    and existing.inventory_month = usage_month
  limit 1
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
  else
    update public.inventory_items_reports existing set
      supervisor_team_id = ctx.team_id,
      business_date = ctx.business_date,
      branch_name_snapshot = ctx.branch_name,
      supervisor_name_snapshot = ctx.supervisor_name,
      supervisor_team_name_snapshot = ctx.supervisor_name || ' Team'
    where existing.id = report.id
    returning * into report;
  end if;

  perform private.persist_inventory_items_daily_values(report.id, usage_month, beef_rows, item_usage);

  update public.inventory_items_reports existing set
    state = 'submitted',
    submitted_at = pg_catalog.now()
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

alter table public.inventory_items_reports enable row level security;
alter table public.inventory_beef_production_rows enable row level security;
alter table public.inventory_item_usage_items enable row level security;
alter table public.inventory_item_usage_day_values enable row level security;
alter table public.inventory_items_submission_idempotency enable row level security;

revoke all on public.inventory_items_reports, public.inventory_beef_production_rows,
  public.inventory_item_usage_items, public.inventory_item_usage_day_values,
  public.inventory_items_submission_idempotency from anon, authenticated;
revoke all on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)
  to service_role;
