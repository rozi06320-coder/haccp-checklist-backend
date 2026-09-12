create table if not exists public.branch_daily_inventory_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  business_date date not null,
  revision bigint not null default 1,
  created_by_user_id uuid not null references public.profiles(id) on delete restrict,
  updated_by_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_daily_inventory_reports_revision_check check (revision >= 1),
  constraint branch_daily_inventory_reports_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_daily_inventory_reports_branch_date_key unique (branch_id, business_date),
  constraint branch_daily_inventory_reports_scope_key unique (id, organization_id, branch_id, business_date)
);

create table if not exists public.branch_daily_inventory_entries (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.branch_daily_inventory_reports(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  business_date date not null,
  inventory_item_id uuid not null references public.branch_inventory_catalog_items(id) on delete restrict,
  inventory_item_name_snapshot text not null,
  inventory_item_unit_snapshot text not null,
  manual_opening_quantity numeric null,
  receiving_quantity numeric not null default 0,
  transfer_in_quantity numeric not null default 0,
  transfer_out_quantity numeric not null default 0,
  actual_closing_quantity numeric null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_daily_inventory_entries_manual_opening_check check (
    (pg_catalog.extract(day from business_date) = 1 and (manual_opening_quantity is null or manual_opening_quantity >= 0))
    or
    (pg_catalog.extract(day from business_date) <> 1 and manual_opening_quantity is null)
  ),
  constraint branch_daily_inventory_entries_receiving_check check (receiving_quantity >= 0),
  constraint branch_daily_inventory_entries_transfer_in_check check (transfer_in_quantity >= 0),
  constraint branch_daily_inventory_entries_transfer_out_check check (transfer_out_quantity >= 0),
  constraint branch_daily_inventory_entries_actual_closing_check check (actual_closing_quantity is null or actual_closing_quantity >= 0),
  constraint branch_daily_inventory_entries_name_snapshot_check check (
    inventory_item_name_snapshot = pg_catalog.regexp_replace(pg_catalog.btrim(inventory_item_name_snapshot), '[[:space:]]+', ' ', 'g')
    and length(inventory_item_name_snapshot) between 1 and 120
  ),
  constraint branch_daily_inventory_entries_unit_snapshot_check check (
    inventory_item_unit_snapshot in ('pcs', 'kg', 'g', 'L', 'ml')
  ),
  constraint branch_daily_inventory_entries_pcs_integer_check check (
    inventory_item_unit_snapshot <> 'pcs' or (
      (manual_opening_quantity is null or manual_opening_quantity = pg_catalog.floor(manual_opening_quantity))
      and receiving_quantity = pg_catalog.floor(receiving_quantity)
      and transfer_in_quantity = pg_catalog.floor(transfer_in_quantity)
      and transfer_out_quantity = pg_catalog.floor(transfer_out_quantity)
      and (actual_closing_quantity is null or actual_closing_quantity = pg_catalog.floor(actual_closing_quantity))
    )
  ),
  constraint branch_daily_inventory_entries_report_scope_fk foreign key (report_id, organization_id, branch_id, business_date) references public.branch_daily_inventory_reports(id, organization_id, branch_id, business_date) on delete cascade,
  constraint branch_daily_inventory_entries_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_daily_inventory_entries_inventory_item_fk foreign key (branch_id, inventory_item_id) references public.branch_inventory_catalog_items(branch_id, id) on delete restrict,
  constraint branch_daily_inventory_entries_report_item_key unique (report_id, inventory_item_id),
  constraint branch_daily_inventory_entries_branch_date_item_key unique (branch_id, business_date, inventory_item_id),
  constraint branch_daily_inventory_entries_scope_key unique (id, report_id, organization_id, branch_id, business_date, inventory_item_id)
);

create index if not exists branch_daily_inventory_reports_branch_date_idx
on public.branch_daily_inventory_reports(branch_id, business_date desc);

create index if not exists branch_daily_inventory_entries_report_idx
on public.branch_daily_inventory_entries(report_id, inventory_item_id);

create index if not exists branch_daily_inventory_entries_branch_date_item_idx
on public.branch_daily_inventory_entries(branch_id, business_date, inventory_item_id);

drop trigger if exists branch_daily_inventory_reports_set_updated_at on public.branch_daily_inventory_reports;
create trigger branch_daily_inventory_reports_set_updated_at
before update on public.branch_daily_inventory_reports
for each row execute function private.set_updated_at();

drop trigger if exists branch_daily_inventory_entries_set_updated_at on public.branch_daily_inventory_entries;
create trigger branch_daily_inventory_entries_set_updated_at
before update on public.branch_daily_inventory_entries
for each row execute function private.set_updated_at();

alter table public.branch_daily_inventory_reports enable row level security;
alter table public.branch_daily_inventory_entries enable row level security;

revoke all on table public.branch_daily_inventory_reports, public.branch_daily_inventory_entries from public, anon, authenticated, service_role;
grant select on table public.branch_daily_inventory_reports, public.branch_daily_inventory_entries to authenticated, service_role;

drop policy if exists branch_daily_inventory_reports_select_authorized on public.branch_daily_inventory_reports;
create policy branch_daily_inventory_reports_select_authorized
on public.branch_daily_inventory_reports for select to authenticated
using (private.has_branch_access(branch_id));

drop policy if exists branch_daily_inventory_entries_select_authorized on public.branch_daily_inventory_entries;
create policy branch_daily_inventory_entries_select_authorized
on public.branch_daily_inventory_entries for select to authenticated
using (private.has_branch_access(branch_id));

create or replace function private.branch_daily_inventory_payload(actor_user_id uuid, target_branch_id uuid, target_business_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_daily_inventory_reports%rowtype;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if target_business_date is null then
    raise exception 'daily inventory business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'daily inventory future business date denied' using errcode = '22023';
  end if;

  select * into report
  from public.branch_daily_inventory_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date;

  if report.id is null then
    return pg_catalog.jsonb_build_object(
      'report_id', null,
      'organization_id', ctx.organization_id,
      'branch_id', ctx.branch_id,
      'business_date', target_business_date,
      'current_business_date', ctx.business_date,
      'revision', 0,
      'created_at', null,
      'updated_at', null,
      'entries', '[]'::jsonb
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'organization_id', ctx.organization_id,
    'branch_id', ctx.branch_id,
    'business_date', target_business_date,
    'current_business_date', ctx.business_date,
    'revision', report.revision,
    'created_at', report.created_at,
    'updated_at', report.updated_at,
    'entries', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', entry.id,
          'inventory_item_id', entry.inventory_item_id,
          'inventory_item_name_snapshot', entry.inventory_item_name_snapshot,
          'inventory_item_unit_snapshot', entry.inventory_item_unit_snapshot,
          'manual_opening_quantity', entry.manual_opening_quantity,
          'opening_quantity', case
            when pg_catalog.extract(day from target_business_date) = 1 then entry.manual_opening_quantity
            else (
              select prev_entry.actual_closing_quantity
              from public.branch_daily_inventory_entries prev_entry
              where prev_entry.organization_id = ctx.organization_id
                and prev_entry.branch_id = ctx.branch_id
                and prev_entry.business_date = (target_business_date - 1)
                and prev_entry.inventory_item_id = entry.inventory_item_id
            )
          end,
          'is_opening_manual', (pg_catalog.extract(day from target_business_date) = 1),
          'receiving_quantity', entry.receiving_quantity,
          'transfer_in_quantity', entry.transfer_in_quantity,
          'transfer_out_quantity', entry.transfer_out_quantity,
          'actual_closing_quantity', entry.actual_closing_quantity,
          'created_at', entry.created_at,
          'updated_at', entry.updated_at
        ) order by pg_catalog.lower(entry.inventory_item_name_snapshot), entry.inventory_item_id
      )
      from public.branch_daily_inventory_entries entry
      where entry.report_id = report.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'daily inventory access denied' using errcode = '42501';
end;
$$;

create or replace function public.get_branch_daily_inventory(
  actor_user_id uuid,
  target_branch_id uuid,
  target_business_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return private.branch_daily_inventory_payload(actor_user_id, target_branch_id, target_business_date);
end;
$$;

create or replace function public.get_branch_daily_inventory(
  actor_user_id uuid,
  target_branch_id uuid,
  start_date date,
  end_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ctx record;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if start_date is null or end_date is null then
    raise exception 'daily inventory date range required' using errcode = '22004';
  end if;
  if start_date > end_date then
    raise exception 'daily inventory invalid date range' using errcode = '22023';
  end if;
  if (end_date - start_date) > 62 then
    raise exception 'daily inventory date range exceeds maximum of 62 days' using errcode = '22023';
  end if;
  if start_date > ctx.business_date or end_date > ctx.business_date then
    raise exception 'daily inventory future business date denied' using errcode = '22023';
  end if;

  return pg_catalog.jsonb_build_object(
    'organization_id', ctx.organization_id,
    'branch_id', ctx.branch_id,
    'start_date', start_date,
    'end_date', end_date,
    'current_business_date', ctx.business_date,
    'reports', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'report_id', report.id,
          'organization_id', ctx.organization_id,
          'branch_id', ctx.branch_id,
          'business_date', cal.day_date,
          'revision', coalesce(report.revision, 0),
          'created_at', report.created_at,
          'updated_at', report.updated_at,
          'entries', coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'id', entry.id,
                'inventory_item_id', entry.inventory_item_id,
                'inventory_item_name_snapshot', entry.inventory_item_name_snapshot,
                'inventory_item_unit_snapshot', entry.inventory_item_unit_snapshot,
                'manual_opening_quantity', entry.manual_opening_quantity,
                'opening_quantity', case
                  when pg_catalog.extract(day from cal.day_date) = 1 then entry.manual_opening_quantity
                  else (
                    select prev_entry.actual_closing_quantity
                    from public.branch_daily_inventory_entries prev_entry
                    where prev_entry.organization_id = ctx.organization_id
                      and prev_entry.branch_id = ctx.branch_id
                      and prev_entry.business_date = (cal.day_date - 1)
                      and prev_entry.inventory_item_id = entry.inventory_item_id
                  )
                end,
                'is_opening_manual', (pg_catalog.extract(day from cal.day_date) = 1),
                'receiving_quantity', entry.receiving_quantity,
                'transfer_in_quantity', entry.transfer_in_quantity,
                'transfer_out_quantity', entry.transfer_out_quantity,
                'actual_closing_quantity', entry.actual_closing_quantity,
                'created_at', entry.created_at,
                'updated_at', entry.updated_at
              ) order by pg_catalog.lower(entry.inventory_item_name_snapshot), entry.inventory_item_id
            )
            from public.branch_daily_inventory_entries entry
            where report.id is not null and entry.report_id = report.id
          ), '[]'::jsonb)
        ) order by cal.day_date asc
      )
      from (
        select (start_date + s)::date as day_date
        from pg_catalog.generate_series(0, end_date - start_date) as s
      ) cal
      left join public.branch_daily_inventory_reports report
        on report.organization_id = ctx.organization_id
       and report.branch_id = ctx.branch_id
       and report.business_date = cal.day_date
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'daily inventory access denied' using errcode = '42501';
end;
$$;

create or replace function public.save_branch_daily_inventory(
  actor_user_id uuid,
  target_branch_id uuid,
  target_business_date date,
  expected_revision bigint,
  entries jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_daily_inventory_reports%rowtype;
  entry_row jsonb;
  parsed_item_id uuid;
  parsed_manual_opening numeric;
  parsed_receiving numeric;
  parsed_transfer_in numeric;
  parsed_transfer_out numeric;
  parsed_actual_closing numeric;
  is_day_one boolean;
  changed boolean := false;
  stage_record record;
  cat_item record;
  effective_unit text;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if target_business_date is null then
    raise exception 'daily inventory business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'daily inventory future business date denied' using errcode = '22023';
  end if;
  if expected_revision is null or expected_revision < 0 then
    raise exception 'invalid daily inventory revision' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(entries, 'null'::jsonb)) <> 'array' then
    raise exception 'invalid daily inventory payload' using errcode = '22023';
  end if;

  is_day_one := (pg_catalog.extract(day from target_business_date) = 1);

  drop table if exists pg_temp.branch_daily_inventory_stage;
  drop table if exists pg_temp.branch_daily_inventory_existing;

  create temp table branch_daily_inventory_stage(
    inventory_item_id uuid primary key,
    manual_opening_quantity numeric null,
    receiving_quantity numeric not null default 0,
    transfer_in_quantity numeric not null default 0,
    transfer_out_quantity numeric not null default 0,
    actual_closing_quantity numeric null
  ) on commit drop;

  for entry_row in select * from pg_catalog.jsonb_array_elements(coalesce(entries, '[]'::jsonb)) loop
    if jsonb_typeof(entry_row) <> 'object' then
      raise exception 'invalid daily inventory payload' using errcode = '22023';
    end if;

    -- Whitelist: accept ONLY inventory_item_id, manual_opening_quantity, receiving_quantity, transfer_in_quantity, transfer_out_quantity, actual_closing_quantity
    if exists (
      select 1
      from pg_catalog.jsonb_object_keys(entry_row) as k
      where k not in (
        'inventory_item_id',
        'manual_opening_quantity',
        'receiving_quantity',
        'transfer_in_quantity',
        'transfer_out_quantity',
        'actual_closing_quantity'
      )
    ) then
      raise exception 'invalid daily inventory payload: unexpected field' using errcode = '22023';
    end if;

    begin
      parsed_item_id := (entry_row->>'inventory_item_id')::uuid;
    exception when others then
      raise exception 'invalid daily inventory item id' using errcode = '22023';
    end;
    if parsed_item_id is null then
      raise exception 'invalid daily inventory item id' using errcode = '22023';
    end if;

    -- manual_opening_quantity parsing and Day-1 validation
    if entry_row ? 'manual_opening_quantity' then
      if jsonb_typeof(entry_row->'manual_opening_quantity') not in ('number', 'null') then
        raise exception 'invalid manual opening quantity' using errcode = '22023';
      end if;

      if jsonb_typeof(entry_row->'manual_opening_quantity') = 'number' then
        begin
          parsed_manual_opening := (entry_row->>'manual_opening_quantity')::numeric;
        exception when others then
          raise exception 'invalid manual opening quantity' using errcode = '22023';
        end;
        if parsed_manual_opening is null or parsed_manual_opening < 0 or (parsed_manual_opening)::text = 'NaN' then
          raise exception 'invalid manual opening quantity' using errcode = '22023';
        end if;
        if not is_day_one then
          raise exception 'manual opening quantity allowed only on day 1' using errcode = '22023';
        end if;
      else
        parsed_manual_opening := null;
      end if;
    else
      parsed_manual_opening := null;
    end if;

    -- receiving_quantity
    if entry_row ? 'receiving_quantity' then
      if jsonb_typeof(entry_row->'receiving_quantity') <> 'number' then
        raise exception 'invalid receiving quantity' using errcode = '22023';
      end if;
      begin
        parsed_receiving := (entry_row->>'receiving_quantity')::numeric;
      exception when others then
        raise exception 'invalid receiving quantity' using errcode = '22023';
      end;
      if parsed_receiving is null or parsed_receiving < 0 or (parsed_receiving)::text = 'NaN' then
        raise exception 'invalid receiving quantity' using errcode = '22023';
      end if;
    else
      parsed_receiving := 0;
    end if;

    -- transfer_in_quantity
    if entry_row ? 'transfer_in_quantity' then
      if jsonb_typeof(entry_row->'transfer_in_quantity') <> 'number' then
        raise exception 'invalid transfer in quantity' using errcode = '22023';
      end if;
      begin
        parsed_transfer_in := (entry_row->>'transfer_in_quantity')::numeric;
      exception when others then
        raise exception 'invalid transfer in quantity' using errcode = '22023';
      end;
      if parsed_transfer_in is null or parsed_transfer_in < 0 or (parsed_transfer_in)::text = 'NaN' then
        raise exception 'invalid transfer in quantity' using errcode = '22023';
      end if;
    else
      parsed_transfer_in := 0;
    end if;

    -- transfer_out_quantity
    if entry_row ? 'transfer_out_quantity' then
      if jsonb_typeof(entry_row->'transfer_out_quantity') <> 'number' then
        raise exception 'invalid transfer out quantity' using errcode = '22023';
      end if;
      begin
        parsed_transfer_out := (entry_row->>'transfer_out_quantity')::numeric;
      exception when others then
        raise exception 'invalid transfer out quantity' using errcode = '22023';
      end;
      if parsed_transfer_out is null or parsed_transfer_out < 0 or (parsed_transfer_out)::text = 'NaN' then
        raise exception 'invalid transfer out quantity' using errcode = '22023';
      end if;
    else
      parsed_transfer_out := 0;
    end if;

    -- actual_closing_quantity
    if entry_row ? 'actual_closing_quantity' then
      if jsonb_typeof(entry_row->'actual_closing_quantity') not in ('number', 'null') then
        raise exception 'invalid actual closing quantity' using errcode = '22023';
      end if;

      if jsonb_typeof(entry_row->'actual_closing_quantity') = 'number' then
        begin
          parsed_actual_closing := (entry_row->>'actual_closing_quantity')::numeric;
        exception when others then
          raise exception 'invalid actual closing quantity' using errcode = '22023';
        end;
        if parsed_actual_closing is null or parsed_actual_closing < 0 or (parsed_actual_closing)::text = 'NaN' then
          raise exception 'invalid actual closing quantity' using errcode = '22023';
        end if;
      else
        parsed_actual_closing := null;
      end if;
    else
      parsed_actual_closing := null;
    end if;

    begin
      insert into branch_daily_inventory_stage(
        inventory_item_id,
        manual_opening_quantity,
        receiving_quantity,
        transfer_in_quantity,
        transfer_out_quantity,
        actual_closing_quantity
      ) values (
        parsed_item_id,
        parsed_manual_opening,
        parsed_receiving,
        parsed_transfer_in,
        parsed_transfer_out,
        parsed_actual_closing
      );
    exception when unique_violation then
      raise exception 'duplicate daily inventory item' using errcode = '23505';
    end;
  end loop;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(ctx.organization_id::text || ':' || ctx.branch_id::text || ':' || target_business_date::text || ':daily_inventory', 0)
  );

  select * into report
  from public.branch_daily_inventory_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date
  for update;

  if report.id is null and expected_revision <> 0 then
    raise exception 'daily inventory changed' using errcode = '40001';
  end if;
  if report.id is not null and expected_revision <> report.revision then
    raise exception 'daily inventory changed' using errcode = '40001';
  end if;

  create temp table branch_daily_inventory_existing on commit drop as
  select entry.id, entry.inventory_item_id, entry.inventory_item_name_snapshot,
         entry.inventory_item_unit_snapshot, entry.manual_opening_quantity,
         entry.receiving_quantity, entry.transfer_in_quantity,
         entry.transfer_out_quantity, entry.actual_closing_quantity
  from public.branch_daily_inventory_entries entry
  where report.id is not null and entry.report_id = report.id;

  -- Validate inventory items:
  for stage_record in select * from branch_daily_inventory_stage loop
    -- Check if entry is empty
    if not (
      stage_record.manual_opening_quantity is null
      and stage_record.receiving_quantity = 0
      and stage_record.transfer_in_quantity = 0
      and stage_record.transfer_out_quantity = 0
      and stage_record.actual_closing_quantity is null
    ) then
      select * into cat_item
      from public.branch_inventory_catalog_items i
      where i.id = stage_record.inventory_item_id
        and i.organization_id = ctx.organization_id
        and i.branch_id = ctx.branch_id;

      if not exists (select 1 from branch_daily_inventory_existing e where e.inventory_item_id = stage_record.inventory_item_id) then
        -- New inventory row: catalog item must exist, be in branch, and be active
        if cat_item.id is null then
          raise exception 'inventory item unavailable' using errcode = '42501';
        end if;
        if not cat_item.is_active then
          raise exception 'cannot record inventory for inactive item' using errcode = '22023';
        end if;
        effective_unit := cat_item.unit;
      else
        -- Existing row correction: preserve frozen unit snapshot
        select e.inventory_item_unit_snapshot into effective_unit
        from branch_daily_inventory_existing e
        where e.inventory_item_id = stage_record.inventory_item_id;
      end if;

      -- Validate unit canonicalness
      if effective_unit not in ('pcs', 'kg', 'g', 'L', 'ml') then
        raise exception 'unsupported inventory item unit: %', effective_unit using errcode = '22023';
      end if;

      -- Validate pcs integer constraint
      if effective_unit = 'pcs' then
        if stage_record.manual_opening_quantity is not null and pg_catalog.floor(stage_record.manual_opening_quantity) <> stage_record.manual_opening_quantity then
          raise exception 'pcs quantity must be an integer' using errcode = '22023';
        end if;
        if pg_catalog.floor(stage_record.receiving_quantity) <> stage_record.receiving_quantity then
          raise exception 'pcs quantity must be an integer' using errcode = '22023';
        end if;
        if pg_catalog.floor(stage_record.transfer_in_quantity) <> stage_record.transfer_in_quantity then
          raise exception 'pcs quantity must be an integer' using errcode = '22023';
        end if;
        if pg_catalog.floor(stage_record.transfer_out_quantity) <> stage_record.transfer_out_quantity then
          raise exception 'pcs quantity must be an integer' using errcode = '22023';
        end if;
        if stage_record.actual_closing_quantity is not null and pg_catalog.floor(stage_record.actual_closing_quantity) <> stage_record.actual_closing_quantity then
          raise exception 'pcs quantity must be an integer' using errcode = '22023';
        end if;
      end if;
    end if;
  end loop;

  -- Detect semantic changes:
  changed := (
    -- 1. Any new non-empty row
    exists (
      select 1 from branch_daily_inventory_stage s
      where not (
        s.manual_opening_quantity is null
        and s.receiving_quantity = 0
        and s.transfer_in_quantity = 0
        and s.transfer_out_quantity = 0
        and s.actual_closing_quantity is null
      )
      and not exists (
        select 1 from branch_daily_inventory_existing e
        where e.inventory_item_id = s.inventory_item_id
      )
    )
    -- 2. Any deleted row (empty stage entry for an existing item)
    or exists (
      select 1 from branch_daily_inventory_stage s
      join branch_daily_inventory_existing e on e.inventory_item_id = s.inventory_item_id
      where (
        s.manual_opening_quantity is null
        and s.receiving_quantity = 0
        and s.transfer_in_quantity = 0
        and s.transfer_out_quantity = 0
        and s.actual_closing_quantity is null
      )
    )
    -- 3. Any updated row (values changed)
    or exists (
      select 1 from branch_daily_inventory_stage s
      join branch_daily_inventory_existing e on e.inventory_item_id = s.inventory_item_id
      where not (
        s.manual_opening_quantity is null
        and s.receiving_quantity = 0
        and s.transfer_in_quantity = 0
        and s.transfer_out_quantity = 0
        and s.actual_closing_quantity is null
      )
      and (
        s.manual_opening_quantity is distinct from e.manual_opening_quantity
        or s.receiving_quantity <> e.receiving_quantity
        or s.transfer_in_quantity <> e.transfer_in_quantity
        or s.transfer_out_quantity <> e.transfer_out_quantity
        or s.actual_closing_quantity is distinct from e.actual_closing_quantity
      )
    )
  );

  if not changed then
    return private.branch_daily_inventory_payload(actor_user_id, target_branch_id, target_business_date);
  end if;

  -- Apply changes
  if report.id is null then
    insert into public.branch_daily_inventory_reports(
      organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id
    ) values (
      ctx.organization_id, ctx.branch_id, target_business_date, 1, actor_user_id, actor_user_id
    ) returning * into report;
  else
    update public.branch_daily_inventory_reports existing
    set revision = existing.revision + 1,
        updated_by_user_id = actor_user_id,
        updated_at = now()
    where existing.id = report.id
    returning * into report;
  end if;

  -- 1. Deletes: explicit all-empty stage entry removes existing entry
  delete from public.branch_daily_inventory_entries entry
  using branch_daily_inventory_stage stage
  where entry.report_id = report.id
    and entry.inventory_item_id = stage.inventory_item_id
    and stage.manual_opening_quantity is null
    and stage.receiving_quantity = 0
    and stage.transfer_in_quantity = 0
    and stage.transfer_out_quantity = 0
    and stage.actual_closing_quantity is null;

  -- 2. Updates: partial PATCH preserves omitted items and freezes snapshots
  update public.branch_daily_inventory_entries entry
  set manual_opening_quantity = stage.manual_opening_quantity,
      receiving_quantity = stage.receiving_quantity,
      transfer_in_quantity = stage.transfer_in_quantity,
      transfer_out_quantity = stage.transfer_out_quantity,
      actual_closing_quantity = stage.actual_closing_quantity,
      updated_at = now()
  from branch_daily_inventory_stage stage, branch_daily_inventory_existing existing
  where entry.report_id = report.id
    and entry.inventory_item_id = stage.inventory_item_id
    and existing.inventory_item_id = stage.inventory_item_id
    and not (
      stage.manual_opening_quantity is null
      and stage.receiving_quantity = 0
      and stage.transfer_in_quantity = 0
      and stage.transfer_out_quantity = 0
      and stage.actual_closing_quantity is null
    )
    and (
      existing.manual_opening_quantity is distinct from stage.manual_opening_quantity
      or existing.receiving_quantity <> stage.receiving_quantity
      or existing.transfer_in_quantity <> stage.transfer_in_quantity
      or existing.transfer_out_quantity <> stage.transfer_out_quantity
      or existing.actual_closing_quantity is distinct from stage.actual_closing_quantity
    );

  -- 3. Inserts: new items freeze current catalog name & unit snapshots
  insert into public.branch_daily_inventory_entries(
    report_id, organization_id, branch_id, business_date, inventory_item_id,
    inventory_item_name_snapshot, inventory_item_unit_snapshot,
    manual_opening_quantity, receiving_quantity, transfer_in_quantity,
    transfer_out_quantity, actual_closing_quantity
  )
  select report.id, ctx.organization_id, ctx.branch_id, target_business_date, item.id,
    item.name, item.unit,
    stage.manual_opening_quantity, stage.receiving_quantity, stage.transfer_in_quantity,
    stage.transfer_out_quantity, stage.actual_closing_quantity
  from branch_daily_inventory_stage stage
  join public.branch_inventory_catalog_items item
    on item.id = stage.inventory_item_id
   and item.organization_id = ctx.organization_id
   and item.branch_id = ctx.branch_id
  where not (
    stage.manual_opening_quantity is null
    and stage.receiving_quantity = 0
    and stage.transfer_in_quantity = 0
    and stage.transfer_out_quantity = 0
    and stage.actual_closing_quantity is null
  )
  and not exists (
    select 1 from branch_daily_inventory_existing existing
    where existing.inventory_item_id = stage.inventory_item_id
  );

  return private.branch_daily_inventory_payload(actor_user_id, target_branch_id, target_business_date);
exception
  when no_data_found or too_many_rows then
    raise exception 'daily inventory access denied' using errcode = '42501';
end;
$$;

revoke all on function private.branch_daily_inventory_payload(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.get_branch_daily_inventory(uuid, uuid, date), public.get_branch_daily_inventory(uuid, uuid, date, date), public.save_branch_daily_inventory(uuid, uuid, date, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.get_branch_daily_inventory(uuid, uuid, date), public.get_branch_daily_inventory(uuid, uuid, date, date), public.save_branch_daily_inventory(uuid, uuid, date, bigint, jsonb) to service_role;
