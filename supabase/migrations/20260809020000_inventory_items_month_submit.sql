-- Inventory Items Phase 2A: month-scoped draft plus submit/close-month lock.

alter table public.inventory_items_reports
  add column if not exists inventory_month date,
  add column if not exists submitted_at timestamptz;

update public.inventory_items_reports
set inventory_month = pg_catalog.date_trunc('month', business_date)::date
where inventory_month is null;

alter table public.inventory_items_reports
  alter column inventory_month set not null;

alter table public.inventory_items_reports
  drop constraint if exists inventory_items_reports_state_check,
  add constraint inventory_items_reports_state_check check (state in ('draft', 'submitted')),
  add constraint inventory_items_reports_inventory_month_check check (inventory_month = pg_catalog.date_trunc('month', inventory_month)::date);

alter table public.inventory_items_reports
  drop constraint if exists inventory_items_reports_branch_id_supervisor_user_id_business_date_key;
alter table public.inventory_items_reports
  drop constraint if exists inventory_items_reports_branch_id_supervisor_user_id_busine_key;

alter table public.inventory_items_reports
  add constraint inventory_items_reports_branch_supervisor_month_key unique(branch_id, supervisor_user_id, inventory_month);

create index if not exists inventory_items_reports_team_month_idx
  on public.inventory_items_reports(supervisor_team_id, inventory_month desc);
create index if not exists inventory_items_reports_branch_month_idx
  on public.inventory_items_reports(branch_id, inventory_month desc);

create table if not exists public.inventory_items_submission_idempotency (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null,
  report_id uuid not null references public.inventory_items_reports(id) on delete restrict,
  response_json jsonb not null,
  created_at timestamptz not null default now(),
  primary key(actor_user_id, idempotency_key),
  constraint inventory_items_submission_hash_check check (request_hash = btrim(request_hash) and length(request_hash) between 16 and 256)
);

alter table public.inventory_items_submission_idempotency enable row level security;

create or replace function private.validate_inventory_beef_rows_for_month(rows jsonb, target_month date)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb; production_date date;
begin
  perform private.validate_inventory_beef_rows(rows);
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    production_date := private.inventory_items_date_field(row_value, 'production_date');
    if pg_catalog.date_trunc('month', production_date)::date <> target_month then
      raise exception 'inventory production date outside month' using errcode = '22023';
    end if;
  end loop;
end $$;
revoke all on function private.validate_inventory_beef_rows_for_month(jsonb,date) from public, anon, authenticated;

create or replace function private.inventory_items_state_json(p_actor_user_id uuid, p_target_branch_id uuid, p_target_inventory_month date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; report public.inventory_items_reports%rowtype; selected_month date;
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
    and r.supervisor_user_id = p_actor_user_id
    and r.inventory_month = selected_month
  order by r.updated_at desc, r.id
  limit 1;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'business_date', ctx.business_date,
    'inventory_month', selected_month,
    'state', coalesce(report.state, 'draft'),
    'updated_at', report.updated_at,
    'submitted_at', report.submitted_at,
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
      'usage_month', coalesce((select min(item.usage_month) from public.inventory_item_usage_items item where item.report_id = report.id), selected_month),
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

create or replace function public.get_inventory_items_current_state(actor_user_id uuid, target_branch_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
  select private.inventory_items_state_json(actor_user_id, target_branch_id, null::date);
$$;

create or replace function public.get_inventory_items_current_state(actor_user_id uuid, target_branch_id uuid, target_inventory_month date)
returns jsonb language sql security definer set search_path = '' as $$
  select private.inventory_items_state_json(actor_user_id, target_branch_id, target_inventory_month);
$$;

drop function if exists public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb);

create or replace function public.save_inventory_items_draft(p_actor_user_id uuid, p_target_branch_id uuid, beef_rows jsonb, item_usage jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare ctx record; report public.inventory_items_reports%rowtype; usage_month date; item_value jsonb; created_item public.inventory_item_usage_items%rowtype; sort_index integer := 0; usage_day text; usage_quantity jsonb;
begin
  select * into strict ctx from private.phase4a_actor_context(p_actor_user_id, p_target_branch_id);
  perform private.validate_inventory_item_usage(item_usage);
  usage_month := private.inventory_items_month_field(item_usage, 'usage_month');
  perform private.validate_inventory_beef_rows_for_month(beef_rows, usage_month);

  select * into report
  from public.inventory_items_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.supervisor_user_id = p_actor_user_id
    and existing.inventory_month = usage_month
  limit 1;
  if report.id is not null and report.state = 'submitted' then
    raise exception 'inventory month already submitted' using errcode = '23505';
  end if;

  insert into public.inventory_items_reports(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, inventory_month, state,
    branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot
  ) values (
    ctx.organization_id, ctx.branch_id, p_actor_user_id, ctx.team_id, ctx.business_date, usage_month, 'draft',
    ctx.branch_name, ctx.supervisor_name, ctx.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_user_id, inventory_month) do update set
    state = 'draft',
    supervisor_team_id = excluded.supervisor_team_id,
    business_date = excluded.business_date,
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

    for usage_day, usage_quantity in select * from pg_catalog.jsonb_each(item_value -> 'usage') loop
      insert into public.inventory_item_usage_day_values(item_id, day_number, quantity)
      values (created_item.id, usage_day::integer, private.inventory_items_numeric_field(pg_catalog.jsonb_build_object('quantity', usage_quantity), 'quantity'));
    end loop;
  end loop;

  return private.inventory_items_state_json(p_actor_user_id, p_target_branch_id, usage_month);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory draft denied' using errcode = '42501';
end $$;

create or replace function public.submit_inventory_items(p_actor_user_id uuid, p_target_branch_id uuid, p_idempotency_key uuid, p_request_hash text, beef_rows jsonb, item_usage jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare ctx record; report public.inventory_items_reports%rowtype; existing_idempotency public.inventory_items_submission_idempotency%rowtype; usage_month date; response_json jsonb; item_value jsonb; created_item public.inventory_item_usage_items%rowtype; sort_index integer := 0; usage_day text; usage_quantity jsonb;
begin
  select * into strict ctx from private.phase4a_actor_context(p_actor_user_id, p_target_branch_id);
  if p_request_hash is null or pg_catalog.btrim(p_request_hash) = '' then
    raise exception 'invalid inventory idempotency hash' using errcode = '22023';
  end if;

  select * into existing_idempotency
  from public.inventory_items_submission_idempotency idem
  where idem.actor_user_id = p_actor_user_id
    and idem.idempotency_key = p_idempotency_key;
  if existing_idempotency.actor_user_id is not null then
    if existing_idempotency.request_hash <> p_request_hash then
      raise exception 'changed idempotency payload' using errcode = '23505';
    end if;
    return existing_idempotency.response_json;
  end if;

  perform private.validate_inventory_item_usage(item_usage);
  usage_month := private.inventory_items_month_field(item_usage, 'usage_month');
  perform private.validate_inventory_beef_rows_for_month(beef_rows, usage_month);
  if pg_catalog.jsonb_array_length(beef_rows) = 0 and pg_catalog.jsonb_array_length(item_usage -> 'items') = 0 then
    raise exception 'empty inventory submission' using errcode = '22023';
  end if;

  select * into report
  from public.inventory_items_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.supervisor_user_id = p_actor_user_id
    and existing.inventory_month = usage_month
  limit 1;
  if report.id is not null and report.state = 'submitted' then
    raise exception 'inventory month already submitted' using errcode = '23505';
  end if;

  insert into public.inventory_items_reports(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, inventory_month, state, submitted_at,
    branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot
  ) values (
    ctx.organization_id, ctx.branch_id, p_actor_user_id, ctx.team_id, ctx.business_date, usage_month, 'submitted', now(),
    ctx.branch_name, ctx.supervisor_name, ctx.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_user_id, inventory_month) do update set
    state = 'submitted',
    submitted_at = coalesce(public.inventory_items_reports.submitted_at, excluded.submitted_at),
    supervisor_team_id = excluded.supervisor_team_id,
    business_date = excluded.business_date,
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

    for usage_day, usage_quantity in select * from pg_catalog.jsonb_each(item_value -> 'usage') loop
      insert into public.inventory_item_usage_day_values(item_id, day_number, quantity)
      values (created_item.id, usage_day::integer, private.inventory_items_numeric_field(pg_catalog.jsonb_build_object('quantity', usage_quantity), 'quantity'));
    end loop;
  end loop;

  response_json := private.inventory_items_state_json(p_actor_user_id, p_target_branch_id, usage_month);
  insert into public.inventory_items_submission_idempotency(actor_user_id, idempotency_key, request_hash, report_id, response_json)
  values (p_actor_user_id, p_idempotency_key, p_request_hash, report.id, response_json);
  return response_json;
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory submit denied' using errcode = '42501';
end $$;

revoke all on public.inventory_items_submission_idempotency from anon, authenticated;
revoke all on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.get_inventory_items_current_state(uuid,uuid),
  public.get_inventory_items_current_state(uuid,uuid,date),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.get_inventory_items_current_state(uuid,uuid),
  public.get_inventory_items_current_state(uuid,uuid,date),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)
  to service_role;
