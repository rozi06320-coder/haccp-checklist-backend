-- Inventory Items branch-shared monthly ledger.
-- Report identity is organization + branch + inventory month; supervisors are actors, not owners.

do $$
begin
  if exists (
    select 1
    from public.inventory_items_reports
    group by organization_id, branch_id, inventory_month
    having count(*) > 1
  ) then
    raise exception 'inventory branch ledger migration blocked: duplicate branch/month reports exist'
      using errcode = '23514';
  end if;
end $$;

alter table public.inventory_items_reports
  drop constraint if exists inventory_items_reports_branch_supervisor_month_key;
alter table public.inventory_items_reports
  add constraint inventory_items_reports_organization_branch_month_key
  unique(organization_id, branch_id, inventory_month);

comment on column public.inventory_items_reports.supervisor_user_id is
  'Original report creator for audit only; report identity and access are branch/month scoped.';
comment on column public.inventory_items_reports.supervisor_team_id is
  'Original report creator team for audit only; report identity and access are branch/month scoped.';

alter table public.inventory_beef_production_rows
  add column created_by uuid references auth.users(id) on delete restrict;
alter table public.inventory_item_usage_items
  add column created_by uuid references auth.users(id) on delete restrict;
alter table public.inventory_item_usage_day_values
  add column created_by uuid references auth.users(id) on delete restrict;
alter table public.inventory_items_reports
  add column submitted_by_user_id uuid references auth.users(id) on delete restrict,
  add column submitted_by_name_snapshot text;

-- Existing rows predate entry-level attribution. Their report creator is the only safe backfill.
alter table public.inventory_items_reports disable trigger user;
alter table public.inventory_beef_production_rows disable trigger user;
alter table public.inventory_item_usage_items disable trigger user;
alter table public.inventory_item_usage_day_values disable trigger user;

update public.inventory_beef_production_rows row
set created_by = report.supervisor_user_id
from public.inventory_items_reports report
where report.id = row.report_id and row.created_by is null;

update public.inventory_item_usage_items item
set created_by = report.supervisor_user_id
from public.inventory_items_reports report
where report.id = item.report_id and item.created_by is null;

update public.inventory_item_usage_day_values value
set created_by = report.supervisor_user_id
from public.inventory_item_usage_items item
join public.inventory_items_reports report on report.id = item.report_id
where item.id = value.item_id and value.created_by is null;

update public.inventory_items_reports report
set submitted_by_user_id = report.supervisor_user_id,
    submitted_by_name_snapshot = report.supervisor_name_snapshot
where report.state = 'submitted' and report.submitted_by_user_id is null;

alter table public.inventory_items_reports enable trigger user;
alter table public.inventory_beef_production_rows enable trigger user;
alter table public.inventory_item_usage_items enable trigger user;
alter table public.inventory_item_usage_day_values enable trigger user;

alter table public.inventory_beef_production_rows alter column created_by set not null;
alter table public.inventory_item_usage_items alter column created_by set not null;
alter table public.inventory_item_usage_day_values alter column created_by set not null;
alter table public.inventory_items_reports
  add constraint inventory_items_reports_submission_actor_check check (
    (state = 'draft' and submitted_at is null and submitted_by_user_id is null and submitted_by_name_snapshot is null)
    or
    (state = 'submitted' and submitted_at is not null and submitted_by_user_id is not null
      and submitted_by_name_snapshot = pg_catalog.btrim(submitted_by_name_snapshot)
      and pg_catalog.length(submitted_by_name_snapshot) > 0)
  );

comment on column public.inventory_beef_production_rows.created_by is
  'Verified supervisor actor who first persisted this immutable business date.';
comment on column public.inventory_item_usage_items.created_by is
  'Verified supervisor actor who first persisted this immutable usage item.';
comment on column public.inventory_item_usage_day_values.created_by is
  'Verified supervisor actor who first persisted this immutable item/day value.';
comment on column public.inventory_items_reports.submitted_by_user_id is
  'Verified supervisor actor who submitted the shared branch/month ledger.';

create or replace function private.lock_inventory_items_month(target_branch_id uuid, target_inventory_month date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(target_branch_id::text || ':' || target_inventory_month::text, 0)
  );
end $$;
revoke all on function private.lock_inventory_items_month(uuid,date) from public, anon, authenticated;
drop function private.lock_inventory_items_month(uuid,uuid,date);

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
    and r.inventory_month = selected_month;

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
      report_id, production_date, russian_kg, australian_kg, fat_kg, ready_patty, hunch_sauce_kg,
      wastage_grams, created_by
    ) values (
      target_report_id, parsed_production_date, parsed_russian_kg, parsed_australian_kg, parsed_fat_kg,
      parsed_ready_patty, parsed_hunch_sauce_kg, parsed_wastage_grams, actor_user_id
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
revoke all on function private.persist_inventory_items_daily_values(uuid,date,uuid,jsonb,jsonb) from public, anon, authenticated;

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
  perform private.lock_inventory_items_month(p_target_branch_id, usage_month);

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

drop function private.persist_inventory_items_daily_values(uuid,date,jsonb,jsonb);

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

alter table public.inventory_items_reports enable row level security;
alter table public.inventory_beef_production_rows enable row level security;
alter table public.inventory_item_usage_items enable row level security;
alter table public.inventory_item_usage_day_values enable row level security;
alter table public.inventory_items_submission_idempotency enable row level security;

revoke all on public.inventory_items_reports, public.inventory_beef_production_rows,
  public.inventory_item_usage_items, public.inventory_item_usage_day_values,
  public.inventory_items_submission_idempotency from anon, authenticated;
revoke all on function public.get_inventory_items_current_state(uuid,uuid),
  public.get_inventory_items_current_state(uuid,uuid,date),
  public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb),
  public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)
  from public, anon, authenticated;
grant execute on function public.get_inventory_items_current_state(uuid,uuid),
  public.get_inventory_items_current_state(uuid,uuid,date),
  public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb),
  public.list_managed_inventory_items_reports(uuid,uuid,date,uuid)
  to service_role;
