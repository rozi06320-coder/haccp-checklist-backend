-- Inventory Items Phase 1 persistence: draft/current-state only.
-- JSONB is accepted at the RPC boundary and normalized after validation.

create table public.inventory_items_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  supervisor_team_id uuid not null,
  business_date date not null,
  state text not null default 'draft' check (state = 'draft'),
  branch_name_snapshot text not null,
  supervisor_name_snapshot text not null,
  supervisor_team_name_snapshot text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id, supervisor_user_id, business_date),
  constraint inventory_items_reports_branch_scope_fkey
    foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint inventory_items_reports_team_scope_fkey
    foreign key(supervisor_team_id, branch_id, organization_id, supervisor_user_id)
    references public.branch_supervisor_teams(id, branch_id, organization_id, supervisor_user_id) on delete restrict,
  constraint inventory_items_reports_snapshots_check check (
    branch_name_snapshot = btrim(branch_name_snapshot) and length(branch_name_snapshot) > 0
    and supervisor_name_snapshot = btrim(supervisor_name_snapshot) and length(supervisor_name_snapshot) > 0
    and supervisor_team_name_snapshot = btrim(supervisor_team_name_snapshot) and length(supervisor_team_name_snapshot) > 0
  )
);
create index inventory_items_reports_team_date_idx
  on public.inventory_items_reports(supervisor_team_id, business_date desc);
create index inventory_items_reports_branch_date_idx
  on public.inventory_items_reports(branch_id, business_date desc);

create table public.inventory_beef_production_rows (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.inventory_items_reports(id) on delete cascade,
  production_date date not null,
  russian_kg numeric not null default 0 check (russian_kg >= 0),
  australian_kg numeric not null default 0 check (australian_kg >= 0),
  fat_kg numeric not null default 0 check (fat_kg >= 0),
  ready_patty numeric not null default 0 check (ready_patty >= 0),
  hunch_sauce_kg numeric not null default 0 check (hunch_sauce_kg >= 0),
  wastage_grams numeric not null default 0 check (wastage_grams >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(report_id, production_date)
);
create index inventory_beef_production_rows_report_idx
  on public.inventory_beef_production_rows(report_id, production_date);

create table public.inventory_item_usage_items (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.inventory_items_reports(id) on delete cascade,
  usage_month date not null,
  group_name text not null default 'Liwa',
  item_name text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inventory_item_usage_month_check check (usage_month = date_trunc('month', usage_month)::date),
  constraint inventory_item_usage_names_check check (
    group_name = btrim(group_name) and length(group_name) between 1 and 120
    and item_name = btrim(item_name) and length(item_name) between 1 and 160
  )
);
create index inventory_item_usage_items_report_idx
  on public.inventory_item_usage_items(report_id, usage_month, sort_order, item_name);

create table public.inventory_item_usage_day_values (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.inventory_item_usage_items(id) on delete cascade,
  day_number integer not null check (day_number between 1 and 31),
  quantity numeric not null default 0 check (quantity >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(item_id, day_number)
);
create index inventory_item_usage_day_values_item_idx
  on public.inventory_item_usage_day_values(item_id, day_number);

create trigger inventory_items_reports_set_updated_at
before update on public.inventory_items_reports
for each row execute function private.set_updated_at();
create trigger inventory_beef_production_rows_set_updated_at
before update on public.inventory_beef_production_rows
for each row execute function private.set_updated_at();
create trigger inventory_item_usage_items_set_updated_at
before update on public.inventory_item_usage_items
for each row execute function private.set_updated_at();
create trigger inventory_item_usage_day_values_set_updated_at
before update on public.inventory_item_usage_day_values
for each row execute function private.set_updated_at();

create function private.inventory_items_numeric_field(row_value jsonb, field_name text)
returns numeric language plpgsql immutable security definer set search_path = '' as $$
declare raw_value jsonb; raw_text text; parsed_value numeric;
begin
  raw_value := row_value -> field_name;
  if raw_value is null or pg_catalog.jsonb_typeof(raw_value) = 'null' then
    return 0;
  end if;
  if pg_catalog.jsonb_typeof(raw_value) = 'number' then
    parsed_value := (raw_value #>> '{}')::numeric;
  elsif pg_catalog.jsonb_typeof(raw_value) = 'string' then
    raw_text := pg_catalog.btrim(raw_value #>> '{}');
    if raw_text = '' then
      return 0;
    end if;
    parsed_value := raw_text::numeric;
  else
    raise exception 'invalid inventory numeric field' using errcode = '22023';
  end if;
  if parsed_value < 0 then
    raise exception 'invalid inventory numeric field' using errcode = '22023';
  end if;
  return parsed_value;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid inventory numeric field' using errcode = '22023';
end $$;
revoke all on function private.inventory_items_numeric_field(jsonb,text) from public, anon, authenticated;

create function private.inventory_items_date_field(row_value jsonb, field_name text)
returns date language plpgsql immutable security definer set search_path = '' as $$
declare raw_text text; parsed_date date;
begin
  if not (row_value ? field_name) or pg_catalog.jsonb_typeof(row_value -> field_name) <> 'string' then
    raise exception 'invalid inventory date field' using errcode = '22023';
  end if;
  raw_text := pg_catalog.btrim(row_value ->> field_name);
  if raw_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid inventory date field' using errcode = '22023';
  end if;
  parsed_date := raw_text::date;
  if pg_catalog.to_char(parsed_date, 'YYYY-MM-DD') <> raw_text then
    raise exception 'invalid inventory date field' using errcode = '22023';
  end if;
  return parsed_date;
exception
  when datetime_field_overflow or invalid_datetime_format then
    raise exception 'invalid inventory date field' using errcode = '22023';
end $$;
revoke all on function private.inventory_items_date_field(jsonb,text) from public, anon, authenticated;

create function private.inventory_items_month_field(row_value jsonb, field_name text)
returns date language plpgsql immutable security definer set search_path = '' as $$
declare parsed_month date;
begin
  parsed_month := private.inventory_items_date_field(row_value, field_name);
  if parsed_month <> pg_catalog.date_trunc('month', parsed_month)::date then
    raise exception 'invalid inventory month field' using errcode = '22023';
  end if;
  return parsed_month;
end $$;
revoke all on function private.inventory_items_month_field(jsonb,text) from public, anon, authenticated;

create function private.validate_inventory_beef_rows(rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb;
begin
  if pg_catalog.jsonb_typeof(rows) <> 'array' or pg_catalog.jsonb_array_length(rows) > 62 then
    raise exception 'invalid beef production rows' using errcode = '22023';
  end if;
  if (
    select count(*) <> count(distinct value ->> 'production_date')
    from pg_catalog.jsonb_array_elements(rows)
  ) then
    raise exception 'duplicate beef production row' using errcode = '22023';
  end if;
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    perform private.inventory_items_date_field(row_value, 'production_date');
    perform private.inventory_items_numeric_field(row_value, 'russian_kg');
    perform private.inventory_items_numeric_field(row_value, 'australian_kg');
    perform private.inventory_items_numeric_field(row_value, 'fat_kg');
    perform private.inventory_items_numeric_field(row_value, 'ready_patty');
    perform private.inventory_items_numeric_field(row_value, 'hunch_sauce_kg');
    perform private.inventory_items_numeric_field(row_value, 'wastage_grams');
  end loop;
end $$;
revoke all on function private.validate_inventory_beef_rows(jsonb) from public, anon, authenticated;

create function private.validate_inventory_item_usage(item_usage jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare usage_month date; days_in_month integer; item_value jsonb; usage_value jsonb; key text; value jsonb; day_number integer; raw_name text;
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
  for item_value in select value from pg_catalog.jsonb_array_elements(item_usage -> 'items') loop
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
    for key, value in select * from pg_catalog.jsonb_each(usage_value) loop
      if key !~ '^[0-9]+$' then
        raise exception 'invalid inventory day number' using errcode = '22023';
      end if;
      day_number := key::integer;
      if day_number < 1 or day_number > days_in_month then
        raise exception 'invalid inventory day number' using errcode = '22023';
      end if;
      perform private.inventory_items_numeric_field(pg_catalog.jsonb_build_object('quantity', value), 'quantity');
    end loop;
  end loop;
end $$;
revoke all on function private.validate_inventory_item_usage(jsonb) from public, anon, authenticated;

create function public.get_inventory_items_current_state(actor_user_id uuid, target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; report public.inventory_items_reports%rowtype;
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  select * into report
  from public.inventory_items_reports r
  where r.organization_id = ctx.organization_id
    and r.branch_id = ctx.branch_id
    and r.supervisor_user_id = actor_user_id
    and r.business_date = ctx.business_date
  order by r.updated_at desc, r.id
  limit 1;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'business_date', ctx.business_date,
    'state', 'draft',
    'updated_at', report.updated_at,
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
        'wastage_grams', row.wastage_grams
      ) order by row.production_date)
      from public.inventory_beef_production_rows row
      where row.report_id = report.id
    ), '[]'::jsonb),
    'item_usage', pg_catalog.jsonb_build_object(
      'usage_month', coalesce((select min(item.usage_month) from public.inventory_item_usage_items item where item.report_id = report.id), pg_catalog.date_trunc('month', ctx.business_date)::date),
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

create function public.save_inventory_items_draft(actor_user_id uuid, target_branch_id uuid, beef_rows jsonb, item_usage jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare ctx record; report public.inventory_items_reports%rowtype; usage_month date; item_value jsonb; created_item public.inventory_item_usage_items%rowtype; sort_index integer := 0; key text; value jsonb;
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

  for item_value in select value from pg_catalog.jsonb_array_elements(item_usage -> 'items') loop
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

    for key, value in select * from pg_catalog.jsonb_each(item_value -> 'usage') loop
      insert into public.inventory_item_usage_day_values(item_id, day_number, quantity)
      values (created_item.id, key::integer, private.inventory_items_numeric_field(pg_catalog.jsonb_build_object('quantity', value), 'quantity'));
    end loop;
  end loop;

  return public.get_inventory_items_current_state(actor_user_id, target_branch_id);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory draft denied' using errcode = '42501';
end $$;

alter table public.inventory_items_reports enable row level security;
alter table public.inventory_beef_production_rows enable row level security;
alter table public.inventory_item_usage_items enable row level security;
alter table public.inventory_item_usage_day_values enable row level security;

revoke all on public.inventory_items_reports, public.inventory_beef_production_rows,
  public.inventory_item_usage_items, public.inventory_item_usage_day_values
  from anon, authenticated;
revoke all on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb), public.get_inventory_items_current_state(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb), public.get_inventory_items_current_state(uuid,uuid)
  to service_role;
