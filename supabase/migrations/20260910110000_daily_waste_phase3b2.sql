create table if not exists public.branch_daily_waste_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  business_date date not null,
  revision bigint not null default 1,
  created_by_user_id uuid not null references public.profiles(id) on delete restrict,
  updated_by_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_daily_waste_reports_revision_check check (revision >= 1),
  constraint branch_daily_waste_reports_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_daily_waste_reports_branch_date_key unique (branch_id, business_date),
  constraint branch_daily_waste_reports_scope_key unique (id, organization_id, branch_id, business_date)
);

create table if not exists public.branch_daily_waste_entries (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.branch_daily_waste_reports(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  business_date date not null,
  inventory_item_id uuid not null references public.branch_inventory_catalog_items(id) on delete restrict,
  inventory_item_name_snapshot text not null,
  inventory_item_unit_snapshot text not null,
  quantity numeric not null,
  note text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_daily_waste_entries_quantity_check check (quantity > 0),
  constraint branch_daily_waste_entries_name_snapshot_check check (inventory_item_name_snapshot = pg_catalog.regexp_replace(pg_catalog.btrim(inventory_item_name_snapshot), '[[:space:]]+', ' ', 'g') and length(inventory_item_name_snapshot) between 1 and 120),
  constraint branch_daily_waste_entries_unit_snapshot_check check (inventory_item_unit_snapshot in ('pcs','kg','g','L','ml')),
  constraint branch_daily_waste_entries_note_check check (note is null or (note = pg_catalog.btrim(note) and length(note) between 1 and 500)),
  constraint branch_daily_waste_entries_report_scope_fk foreign key (report_id, organization_id, branch_id, business_date) references public.branch_daily_waste_reports(id, organization_id, branch_id, business_date) on delete cascade,
  constraint branch_daily_waste_entries_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_daily_waste_entries_inventory_item_fk foreign key (branch_id, inventory_item_id) references public.branch_inventory_catalog_items(branch_id, id) on delete restrict,
  constraint branch_daily_waste_entries_report_item_key unique (report_id, inventory_item_id),
  constraint branch_daily_waste_entries_branch_date_item_key unique (branch_id, business_date, inventory_item_id),
  constraint branch_daily_waste_entries_scope_key unique (id, report_id, organization_id, branch_id, business_date, inventory_item_id)
);

create index if not exists branch_daily_waste_reports_branch_date_idx
on public.branch_daily_waste_reports(branch_id, business_date desc);

create index if not exists branch_daily_waste_entries_report_idx
on public.branch_daily_waste_entries(report_id, inventory_item_id);

create index if not exists branch_daily_waste_entries_branch_date_item_idx
on public.branch_daily_waste_entries(branch_id, business_date, inventory_item_id);

drop trigger if exists branch_daily_waste_reports_set_updated_at on public.branch_daily_waste_reports;
create trigger branch_daily_waste_reports_set_updated_at
before update on public.branch_daily_waste_reports
for each row execute function private.set_updated_at();

drop trigger if exists branch_daily_waste_entries_set_updated_at on public.branch_daily_waste_entries;
create trigger branch_daily_waste_entries_set_updated_at
before update on public.branch_daily_waste_entries
for each row execute function private.set_updated_at();

alter table public.branch_daily_waste_reports enable row level security;
alter table public.branch_daily_waste_entries enable row level security;

revoke all on table public.branch_daily_waste_reports, public.branch_daily_waste_entries from public, anon, authenticated, service_role;
grant select on table public.branch_daily_waste_reports, public.branch_daily_waste_entries to authenticated, service_role;

drop policy if exists branch_daily_waste_reports_select_authorized on public.branch_daily_waste_reports;
create policy branch_daily_waste_reports_select_authorized
on public.branch_daily_waste_reports for select to authenticated
using (private.has_branch_access(branch_id));

drop policy if exists branch_daily_waste_entries_select_authorized on public.branch_daily_waste_entries;
create policy branch_daily_waste_entries_select_authorized
on public.branch_daily_waste_entries for select to authenticated
using (private.has_branch_access(branch_id));

create or replace function private.is_daily_waste_note_required(p_unit text, p_quantity numeric)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  u text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_unit, '')));
begin
  if u = 'pcs' then
    return p_quantity > 5;
  elsif u = 'g' then
    return p_quantity > 700;
  elsif u = 'kg' then
    return p_quantity > 0.7;
  elsif u = 'ml' then
    return p_quantity > 700;
  elsif u = 'l' then
    return p_quantity > 0.7;
  else
    raise exception 'unsupported inventory item unit: %', p_unit using errcode = '22023';
  end if;
end;
$$;

create or replace function private.branch_daily_waste_payload(actor_user_id uuid, target_branch_id uuid, target_business_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_daily_waste_reports%rowtype;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if target_business_date is null then
    raise exception 'daily waste business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'daily waste future business date denied' using errcode = '22023';
  end if;

  select * into report
  from public.branch_daily_waste_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'organization_id', ctx.organization_id,
    'branch_id', ctx.branch_id,
    'business_date', target_business_date,
    'current_business_date', ctx.business_date,
    'revision', coalesce(report.revision, 0),
    'created_at', report.created_at,
    'updated_at', report.updated_at,
    'entries', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'entry_id', entry.id,
        'inventory_item_id', entry.inventory_item_id,
        'inventory_item_name_snapshot', entry.inventory_item_name_snapshot,
        'inventory_item_unit_snapshot', entry.inventory_item_unit_snapshot,
        'quantity', entry.quantity,
        'note', entry.note,
        'created_at', entry.created_at,
        'updated_at', entry.updated_at
      ) order by pg_catalog.lower(entry.inventory_item_name_snapshot), entry.inventory_item_id)
      from public.branch_daily_waste_entries entry
      where entry.report_id = report.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'daily waste access denied' using errcode = '42501';
end;
$$;

create or replace function public.get_branch_daily_waste(
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
    raise exception 'daily waste date range required' using errcode = '22004';
  end if;
  if start_date > end_date then
    raise exception 'daily waste invalid date range' using errcode = '22023';
  end if;
  if (end_date - start_date) > 62 then
    raise exception 'daily waste date range exceeds maximum of 62 days' using errcode = '22023';
  end if;
  if start_date > ctx.business_date or end_date > ctx.business_date then
    raise exception 'daily waste future business date denied' using errcode = '22023';
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
          'business_date', report.business_date,
          'revision', report.revision,
          'created_at', report.created_at,
          'updated_at', report.updated_at,
          'entries', coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'entry_id', entry.id,
                'inventory_item_id', entry.inventory_item_id,
                'inventory_item_name_snapshot', entry.inventory_item_name_snapshot,
                'inventory_item_unit_snapshot', entry.inventory_item_unit_snapshot,
                'quantity', entry.quantity,
                'note', entry.note,
                'created_at', entry.created_at,
                'updated_at', entry.updated_at
              ) order by pg_catalog.lower(entry.inventory_item_name_snapshot), entry.inventory_item_id
            )
            from public.branch_daily_waste_entries entry
            where entry.report_id = report.id
          ), '[]'::jsonb)
        ) order by report.business_date asc
      )
      from public.branch_daily_waste_reports report
      where report.organization_id = ctx.organization_id
        and report.branch_id = ctx.branch_id
        and report.business_date between start_date and end_date
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'daily waste access denied' using errcode = '42501';
end;
$$;

create or replace function public.save_branch_daily_waste(
  actor_user_id uuid,
  target_branch_id uuid,
  target_business_date date,
  expected_revision bigint,
  waste jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_daily_waste_reports%rowtype;
  item_row jsonb;
  parsed_item_id uuid;
  parsed_quantity numeric;
  parsed_note text;
  changed boolean := false;
  stage_record record;
  cat_item record;
  effective_unit text;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if target_business_date is null then
    raise exception 'daily waste business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'daily waste future business date denied' using errcode = '22023';
  end if;
  if expected_revision is null or expected_revision < 0 then
    raise exception 'invalid daily waste revision' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(waste, 'null'::jsonb)) <> 'array' then
    raise exception 'invalid daily waste payload' using errcode = '22023';
  end if;

  drop table if exists pg_temp.branch_daily_waste_stage;
  drop table if exists pg_temp.branch_daily_waste_existing;

  create temp table branch_daily_waste_stage(
    inventory_item_id uuid primary key,
    quantity numeric not null check (quantity >= 0),
    note text null
  ) on commit drop;

  for item_row in select * from pg_catalog.jsonb_array_elements(coalesce(waste, '[]'::jsonb)) loop
    if jsonb_typeof(item_row) <> 'object' then
      raise exception 'invalid daily waste payload' using errcode = '22023';
    end if;

    -- Whitelist: accept ONLY inventory_item_id, quantity, note
    if exists (
      select 1
      from pg_catalog.jsonb_object_keys(item_row) as k
      where k not in ('inventory_item_id', 'quantity', 'note')
    ) then
      raise exception 'invalid daily waste payload: unexpected field' using errcode = '22023';
    end if;

    begin
      parsed_item_id := (item_row->>'inventory_item_id')::uuid;
      parsed_quantity := (item_row->>'quantity')::numeric;
    exception when others then
      raise exception 'invalid daily waste payload' using errcode = '22023';
    end;

    if parsed_item_id is null or parsed_quantity is null or parsed_quantity < 0 then
      raise exception 'invalid daily waste quantity' using errcode = '22023';
    end if;

    if item_row ? 'note' and jsonb_typeof(item_row->'note') not in ('string', 'null') then
      raise exception 'invalid daily waste note' using errcode = '22023';
    end if;

    parsed_note := pg_catalog.btrim(item_row->>'note');
    if parsed_note = '' then
      parsed_note := null;
    end if;
    if parsed_note is not null and pg_catalog.length(parsed_note) > 500 then
      raise exception 'daily waste note exceeds maximum length' using errcode = '22023';
    end if;

    begin
      insert into branch_daily_waste_stage(inventory_item_id, quantity, note)
      values (parsed_item_id, parsed_quantity, parsed_note);
    exception when unique_violation then
      raise exception 'duplicate daily waste inventory item' using errcode = '23505';
    end;
  end loop;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(ctx.organization_id::text || ':' || ctx.branch_id::text || ':' || target_business_date::text || ':daily_waste', 0)
  );

  select * into report
  from public.branch_daily_waste_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date
  for update;

  if report.id is null and expected_revision <> 0 then
    raise exception 'daily waste changed' using errcode = '40001';
  end if;
  if report.id is not null and expected_revision <> report.revision then
    raise exception 'daily waste changed' using errcode = '40001';
  end if;

  create temp table branch_daily_waste_existing on commit drop as
  select entry.id, entry.inventory_item_id, entry.inventory_item_name_snapshot,
         entry.inventory_item_unit_snapshot, entry.quantity, entry.note
  from public.branch_daily_waste_entries entry
  where report.id is not null and entry.report_id = report.id;

  -- Validate inventory items:
  for stage_record in select * from branch_daily_waste_stage loop
    if stage_record.quantity > 0 then
      select * into cat_item
      from public.branch_inventory_catalog_items i
      where i.id = stage_record.inventory_item_id
        and i.organization_id = ctx.organization_id
        and i.branch_id = ctx.branch_id;

      if not exists (select 1 from branch_daily_waste_existing e where e.inventory_item_id = stage_record.inventory_item_id) then
        -- New waste row: catalog item must exist, be in branch, and be active
        if cat_item.id is null then
          raise exception 'inventory item unavailable' using errcode = '42501';
        end if;
        if not cat_item.is_active then
          raise exception 'cannot record waste for inactive inventory item' using errcode = '22023';
        end if;
        effective_unit := cat_item.unit;
      else
        -- Existing row correction: preserve frozen unit snapshot
        select e.inventory_item_unit_snapshot into effective_unit
        from branch_daily_waste_existing e
        where e.inventory_item_id = stage_record.inventory_item_id;
      end if;

      -- Validate unit canonicalness
      if effective_unit not in ('pcs', 'kg', 'g', 'L', 'ml') then
        raise exception 'unsupported inventory item unit: %', effective_unit using errcode = '22023';
      end if;

      -- Validate pcs integer constraint
      if effective_unit = 'pcs' and pg_catalog.floor(stage_record.quantity) <> stage_record.quantity then
        raise exception 'pcs quantity must be an integer' using errcode = '22023';
      end if;

      -- Validate threshold note requirement using private helper
      if private.is_daily_waste_note_required(effective_unit, stage_record.quantity) and stage_record.note is null then
        raise exception 'note required when waste exceeds threshold for unit %', effective_unit using errcode = '22023';
      end if;
    end if;
  end loop;

  -- Detect semantic changes:
  changed := (
    -- 1. Any new positive row
    exists (
      select 1 from branch_daily_waste_stage s
      where s.quantity > 0
        and not exists (
          select 1 from branch_daily_waste_existing e
          where e.inventory_item_id = s.inventory_item_id
        )
    )
    -- 2. Any deleted row (quantity 0 for existing item)
    or exists (
      select 1 from branch_daily_waste_stage s
      join branch_daily_waste_existing e on e.inventory_item_id = s.inventory_item_id
      where s.quantity = 0
    )
    -- 3. Any updated row (quantity or note changed)
    or exists (
      select 1 from branch_daily_waste_stage s
      join branch_daily_waste_existing e on e.inventory_item_id = s.inventory_item_id
      where s.quantity > 0
        and (s.quantity <> e.quantity or coalesce(s.note, '') <> coalesce(e.note, ''))
    )
  );

  if not changed then
    return private.branch_daily_waste_payload(actor_user_id, target_branch_id, target_business_date);
  end if;

  -- Apply changes
  if report.id is null then
    insert into public.branch_daily_waste_reports(
      organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id
    ) values (
      ctx.organization_id, ctx.branch_id, target_business_date, 1, actor_user_id, actor_user_id
    ) returning * into report;
  else
    update public.branch_daily_waste_reports existing
    set revision = existing.revision + 1,
        updated_by_user_id = actor_user_id,
        updated_at = now()
    where existing.id = report.id
    returning * into report;
  end if;

  -- 1. Deletes: explicit zero removes existing entry
  delete from public.branch_daily_waste_entries entry
  using branch_daily_waste_stage stage
  where entry.report_id = report.id
    and entry.inventory_item_id = stage.inventory_item_id
    and stage.quantity = 0;

  -- 2. Updates: quantity or note correction preserves frozen name & unit snapshots
  update public.branch_daily_waste_entries entry
  set quantity = stage.quantity,
      note = stage.note,
      updated_at = now()
  from branch_daily_waste_stage stage, branch_daily_waste_existing existing
  where entry.report_id = report.id
    and entry.inventory_item_id = stage.inventory_item_id
    and existing.inventory_item_id = stage.inventory_item_id
    and stage.quantity > 0
    and (existing.quantity <> stage.quantity or coalesce(existing.note, '') <> coalesce(stage.note, ''));

  -- 3. Inserts: new items freeze current catalog name & unit snapshots
  insert into public.branch_daily_waste_entries(
    report_id, organization_id, branch_id, business_date, inventory_item_id,
    inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity, note
  )
  select report.id, ctx.organization_id, ctx.branch_id, target_business_date, item.id,
    item.name, item.unit, stage.quantity, stage.note
  from branch_daily_waste_stage stage
  join public.branch_inventory_catalog_items item
    on item.id = stage.inventory_item_id
   and item.organization_id = ctx.organization_id
   and item.branch_id = ctx.branch_id
  where stage.quantity > 0
    and not exists (
      select 1 from branch_daily_waste_existing existing
      where existing.inventory_item_id = stage.inventory_item_id
    );

  return private.branch_daily_waste_payload(actor_user_id, target_branch_id, target_business_date);
exception
  when no_data_found or too_many_rows then
    raise exception 'daily waste access denied' using errcode = '42501';
end;
$$;

revoke all on function private.is_daily_waste_note_required(text, numeric) from public, anon, authenticated;
revoke all on function private.branch_daily_waste_payload(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.get_branch_daily_waste(uuid, uuid, date, date), public.save_branch_daily_waste(uuid, uuid, date, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.get_branch_daily_waste(uuid, uuid, date, date), public.save_branch_daily_waste(uuid, uuid, date, bigint, jsonb) to service_role;
