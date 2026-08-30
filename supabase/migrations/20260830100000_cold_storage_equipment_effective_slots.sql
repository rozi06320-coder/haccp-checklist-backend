-- Cold Storage equipment effective-slot eligibility.
-- Master equipment added after a slot starts is visible immediately but only
-- participates beginning with the next scheduled slot.

create or replace function private.cold_storage_slot_order(slot text)
returns integer
language sql
immutable
strict
security definer
set search_path = ''
as $$
  select case slot
    when '12:00' then 1
    when '20:00' then 2
    when '02:00' then 3
    else null
  end
$$;

create or replace function private.cold_storage_master_first_eligible_slot(
  branch_timezone text,
  equipment_created_at timestamptz
)
returns table(first_eligible_business_date date, first_eligible_slot text)
language sql
stable
strict
security definer
set search_path = ''
as $$
  with local_equipment as (
    select
      equipment_created_at at time zone branch_timezone as local_created_at
  ),
  calculated as (
    select
      local_created_at::time as local_time,
      (local_created_at - interval '3 hours')::date as created_business_date
    from local_equipment
  )
  select
    case
      when local_time >= time '02:00' and local_time < time '03:00'
        then created_business_date + 1
      else created_business_date
    end,
    case
      when local_time >= time '03:00' and local_time < time '12:00' then '12:00'
      when local_time >= time '12:00' and local_time < time '20:00' then '20:00'
      when local_time >= time '20:00' or local_time < time '02:00' then '02:00'
      else '12:00'
    end
  from calculated
$$;

create or replace function private.cold_storage_equipment_slot_eligible(
  first_eligible_business_date date,
  first_eligible_slot text,
  target_business_date date,
  target_slot text
)
returns boolean
language sql
immutable
security definer
set search_path = ''
as $$
  select
    first_eligible_business_date is null
    or first_eligible_slot is null
    or target_business_date > first_eligible_business_date
    or (
      target_business_date = first_eligible_business_date
      and private.cold_storage_slot_order(target_slot) >= private.cold_storage_slot_order(first_eligible_slot)
    )
$$;

create or replace function private.cold_storage_json_equipment_slot_eligible(
  equipment jsonb,
  target_business_date date,
  target_slot text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.cold_storage_equipment_slot_eligible(
    nullif(equipment ->> 'first_eligible_business_date', '')::date,
    nullif(equipment ->> 'first_eligible_slot', ''),
    target_business_date,
    target_slot
  )
$$;

create or replace function private.cold_storage_master_has_backfilled_history(
  target_master_equipment_id uuid,
  master_created_at timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cold_storage_equipment snapshot
    join public.cold_storage_readings reading
      on reading.submission_id = snapshot.submission_id
     and reading.equipment_id = snapshot.equipment_id
     and reading.submitted_at is not null
    where snapshot.master_equipment_id = target_master_equipment_id
      and reading.submitted_at < master_created_at
  )
$$;

create or replace function private.ensure_cold_storage_snapshot_master_equipment(
  target_submission_id uuid,
  target_organization_id uuid,
  target_branch_id uuid
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.cold_storage_equipment(
    submission_id,
    equipment_id,
    equipment_code,
    equipment_name,
    equipment_type,
    active,
    master_equipment_id,
    organization_id,
    branch_id
  )
  select
    target_submission_id,
    master.id::text,
    master.equipment_code,
    master.name,
    master.equipment_type,
    true,
    master.id,
    master.organization_id,
    master.branch_id
  from public.branch_cold_storage_equipment master
  where master.organization_id = target_organization_id
    and master.branch_id = target_branch_id
    and master.active
    and not exists (
      select 1
      from public.cold_storage_equipment snapshot
      where snapshot.submission_id = target_submission_id
        and (
          snapshot.master_equipment_id = master.id
          or snapshot.equipment_id = master.id::text
        )
    );
$$;

create or replace function private.cold_storage_submission_equipment_roster(
  target_submission_id uuid,
  target_branch_id uuid,
  target_business_date date
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with branch_scope as (
    select branch.organization_id, branch.timezone
    from public.branches branch
    where branch.id = target_branch_id
  ),
  snapshot_rows as (
    select
      snapshot.id,
      snapshot.equipment_id,
      snapshot.equipment_code,
      snapshot.equipment_name,
      snapshot.equipment_type,
      case
        when master.id is null then snapshot.active
        else snapshot.active and master.active
      end as active,
      snapshot.master_equipment_id,
      master.created_at as master_created_at,
      private.cold_storage_master_has_backfilled_history(master.id, master.created_at)
        or snapshot.master_equipment_id is null
        or master.id is null as legacy_eligible,
      branch_scope.timezone
    from public.cold_storage_equipment snapshot
    cross join branch_scope
    left join public.branch_cold_storage_equipment master
      on master.id = snapshot.master_equipment_id
     and master.branch_id = target_branch_id
     and master.organization_id = branch_scope.organization_id
    where snapshot.submission_id = target_submission_id
  ),
  enriched as (
    select
      snapshot_rows.*,
      case
        when snapshot_rows.legacy_eligible then target_business_date
        else eligibility.first_eligible_business_date
      end as first_eligible_business_date,
      case
        when snapshot_rows.legacy_eligible then '12:00'
        else eligibility.first_eligible_slot
      end as first_eligible_slot
    from snapshot_rows
    left join lateral private.cold_storage_master_first_eligible_slot(snapshot_rows.timezone, snapshot_rows.master_created_at) eligibility
      on not snapshot_rows.legacy_eligible
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'id', enriched.id,
        'equipment_id', enriched.equipment_id,
        'master_equipment_id', enriched.master_equipment_id,
        'equipment_code', enriched.equipment_code,
        'equipment_name', enriched.equipment_name,
        'equipment_type', enriched.equipment_type,
        'active', enriched.active,
        'created_at', enriched.master_created_at,
        'first_eligible_business_date', enriched.first_eligible_business_date,
        'first_eligible_slot', enriched.first_eligible_slot
      ))
      order by pg_catalog.lower(enriched.equipment_name), enriched.equipment_id
    ),
    '[]'::jsonb
  )
  from enriched
$$;

create or replace function private.cold_storage_filter_eligible_readings(
  equipment jsonb,
  readings jsonb,
  target_business_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  reading_value jsonb;
  equipment_value jsonb;
  temperature numeric;
  action text;
  filtered jsonb := '[]'::jsonb;
begin
  for reading_value in
    select value from pg_catalog.jsonb_array_elements(readings)
  loop
    equipment_value := null;
    select value into equipment_value
    from pg_catalog.jsonb_array_elements(equipment)
    where pg_catalog.btrim(value ->> 'equipment_id') = pg_catalog.btrim(reading_value ->> 'equipment_id')
    limit 1;

    if equipment_value is null then
      raise exception 'invalid cold storage reading row' using errcode = '22023';
    end if;

    if coalesce((equipment_value ->> 'active')::boolean, true)
      and private.cold_storage_json_equipment_slot_eligible(equipment_value, target_business_date, reading_value ->> 'slot')
    then
      filtered := filtered || pg_catalog.jsonb_build_array(reading_value);
      continue;
    end if;

    temperature := private.cold_storage_numeric_field(reading_value, 'temperature_c');
    action := pg_catalog.btrim(coalesce(reading_value ->> 'corrective_action', ''));
    if temperature is not null or pg_catalog.length(action) > 0 then
      raise exception 'cold storage equipment is not eligible for slot' using errcode = '22023';
    end if;
  end loop;

  return filtered;
end
$$;

create or replace function private.validate_cold_storage_slot_submit_for_eligible(
  target_slot text,
  equipment jsonb,
  readings jsonb,
  target_business_date date
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  eq_value jsonb;
  reading_value jsonb;
  reading_count integer;
  temperature numeric;
  action text;
  active_count integer := 0;
begin
  if target_slot not in ('12:00','20:00','02:00') then
    raise exception 'invalid cold storage slot' using errcode = '22023';
  end if;
  perform private.validate_cold_storage_equipment(equipment);
  perform private.validate_cold_storage_readings(equipment, readings);

  for eq_value in
    select value from pg_catalog.jsonb_array_elements(equipment)
    where coalesce((value ->> 'active')::boolean, true)
      and private.cold_storage_json_equipment_slot_eligible(value, target_business_date, target_slot)
  loop
    active_count := active_count + 1;

    select count(*) into reading_count
    from pg_catalog.jsonb_array_elements(readings)
    where pg_catalog.btrim(value ->> 'equipment_id') = pg_catalog.btrim(eq_value ->> 'equipment_id')
      and value ->> 'slot' = target_slot;

    if reading_count <> 1 then
      raise exception 'invalid cold storage slot submit' using errcode = '22023';
    end if;

    select value into strict reading_value
    from pg_catalog.jsonb_array_elements(readings)
    where pg_catalog.btrim(value ->> 'equipment_id') = pg_catalog.btrim(eq_value ->> 'equipment_id')
      and value ->> 'slot' = target_slot;

    temperature := private.cold_storage_numeric_field(reading_value, 'temperature_c');
    action := pg_catalog.btrim(coalesce(reading_value ->> 'corrective_action', ''));
    if temperature is null then
      raise exception 'invalid cold storage slot submit' using errcode = '22023';
    end if;
    if temperature >= 5 and pg_catalog.length(action) = 0 then
      raise exception 'invalid cold storage slot submit' using errcode = '22023';
    end if;
  end loop;

  if active_count = 0 then
    raise exception 'invalid cold storage slot submit' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(readings) reading(row_value)
    left join pg_catalog.jsonb_array_elements(equipment) equipment_row(eq_value)
      on pg_catalog.btrim(equipment_row.eq_value ->> 'equipment_id') = pg_catalog.btrim(reading.row_value ->> 'equipment_id')
    where reading.row_value ->> 'slot' = target_slot
      and (
        equipment_row.eq_value is null
        or not coalesce((equipment_row.eq_value ->> 'active')::boolean, true)
        or not private.cold_storage_json_equipment_slot_eligible(equipment_row.eq_value, target_business_date, target_slot)
      )
      and (
        private.cold_storage_numeric_field(reading.row_value, 'temperature_c') is not null
        or pg_catalog.length(pg_catalog.btrim(coalesce(reading.row_value ->> 'corrective_action', ''))) > 0
      )
  ) then
    raise exception 'cold storage equipment is not eligible for slot' using errcode = '22023';
  end if;
end
$$;

create or replace function private.cold_storage_submission_complete(
  target_submission_id uuid,
  target_branch_id uuid,
  target_business_date date
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1
    from pg_catalog.jsonb_array_elements(
      private.cold_storage_submission_equipment_roster(target_submission_id, target_branch_id, target_business_date)
    ) equipment(row_value)
    cross join (values ('12:00'), ('20:00'), ('02:00')) expected(slot)
    where coalesce((equipment.row_value ->> 'active')::boolean, true)
      and private.cold_storage_json_equipment_slot_eligible(equipment.row_value, target_business_date, expected.slot)
      and not exists (
        select 1
        from public.cold_storage_readings reading
        where reading.submission_id = target_submission_id
          and reading.equipment_id = equipment.row_value ->> 'equipment_id'
          and reading.slot = expected.slot
          and reading.submitted_at is not null
      )
  )
$$;

create or replace function private.upsert_cold_storage_submission(
  actor_user_id uuid,
  target_branch_id uuid,
  expected_revision bigint,
  equipment jsonb,
  readings jsonb
)
returns public.cold_storage_submissions
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  c record;
  s public.cold_storage_submissions%rowtype;
  has_submitted boolean;
  resolved_equipment jsonb;
  filtered_readings jsonb;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text || ':' || c.branch_id::text || ':' || c.business_date::text || ':cold_storage', 0));

  select * into s
  from public.cold_storage_submissions x
  where x.organization_id = c.organization_id
    and x.branch_id = c.branch_id
    and x.business_date = c.business_date
  for update;

  if (s.id is null and coalesce(expected_revision, 0) <> 0)
    or (s.id is not null and coalesce(expected_revision, -1) <> s.branch_revision)
  then
    raise exception 'cold storage changed' using errcode = '40001';
  end if;

  if s.id is null then
    insert into public.cold_storage_submissions(
      organization_id,
      branch_id,
      supervisor_user_id,
      supervisor_team_id,
      business_date,
      state,
      branch_name_snapshot,
      supervisor_name_snapshot,
      team_name_snapshot,
      branch_revision,
      updated_by_user_id
    ) values (
      c.organization_id,
      c.branch_id,
      actor_user_id,
      c.legacy_team_id,
      c.business_date,
      'draft',
      c.branch_name,
      c.actor_name,
      c.actor_name || ' Team',
      1,
      actor_user_id
    )
    returning * into s;
  else
    update public.cold_storage_submissions
    set branch_revision = branch_revision + 1,
      updated_by_user_id = actor_user_id,
      updated_at = now()
    where id = s.id
    returning * into s;
  end if;

  select exists (
    select 1
    from public.cold_storage_readings r
    where r.submission_id = s.id
      and r.submitted_at is not null
  ) into has_submitted;

  if has_submitted then
    perform private.validate_cold_storage_equipment(equipment);
    perform private.ensure_cold_storage_snapshot_master_equipment(s.id, c.organization_id, c.branch_id);
  else
    resolved_equipment := private.resolve_cold_storage_equipment_roster(c.organization_id, c.branch_id, equipment);
    perform private.replace_cold_storage_equipment(s.id, resolved_equipment);
  end if;

  resolved_equipment := private.cold_storage_submission_equipment_roster(s.id, c.branch_id, c.business_date);
  perform private.validate_cold_storage_readings(resolved_equipment, readings);
  filtered_readings := private.cold_storage_filter_eligible_readings(resolved_equipment, readings, c.business_date);
  perform private.replace_cold_storage_unsubmitted_readings(s.id, filtered_readings);

  return s;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage operation denied' using errcode = '42501';
end
$$;

create or replace function public.get_cold_storage_current_state(actor_user_id uuid, target_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c record;
  s public.cold_storage_submissions%rowtype;
  branch_timezone text;
  active_slot text;
  equipment_result jsonb;
  readings_result jsonb;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);
  select branch.timezone into strict branch_timezone
  from public.branches branch
  where branch.id = c.branch_id
    and branch.organization_id = c.organization_id
    and branch.active;

  active_slot := private.cold_storage_current_eligible_slot(c.branch_id);

  select * into s
  from public.cold_storage_submissions x
  where x.organization_id = c.organization_id
    and x.branch_id = c.branch_id
    and x.business_date = c.business_date;

  with active_master as (
    select
      master.id::text as equipment_id,
      pg_catalog.lower(master.name) as sort_name,
      master.id as master_equipment_id,
      master.equipment_code,
      master.name,
      master.equipment_type,
      master.created_at,
      private.cold_storage_master_has_backfilled_history(master.id, master.created_at) as legacy_eligible,
      snapshot.id as snapshot_id
    from public.branch_cold_storage_equipment master
    left join lateral (
      select existing.id
      from public.cold_storage_equipment existing
      where existing.submission_id = s.id
        and existing.master_equipment_id = master.id
      limit 1
    ) snapshot on true
    where master.organization_id = c.organization_id
      and master.branch_id = c.branch_id
      and master.active
  ),
  active_master_enriched as (
    select
      active_master.*,
      case
        when active_master.legacy_eligible then c.business_date
        else eligibility.first_eligible_business_date
      end as first_eligible_business_date,
      case
        when active_master.legacy_eligible then '12:00'
        else eligibility.first_eligible_slot
      end as first_eligible_slot
    from active_master
    left join lateral private.cold_storage_master_first_eligible_slot(branch_timezone, active_master.created_at) eligibility
      on not active_master.legacy_eligible
  ),
  historical_snapshot as (
    select
      snapshot.equipment_id,
      pg_catalog.lower(snapshot.equipment_name) as sort_name,
      snapshot.id as snapshot_id,
      snapshot.master_equipment_id,
      snapshot.equipment_code,
      snapshot.equipment_name as name,
      snapshot.equipment_type,
      master.created_at,
      false as active,
      c.business_date as first_eligible_business_date,
      '12:00' as first_eligible_slot
    from public.cold_storage_equipment snapshot
    left join public.branch_cold_storage_equipment master
      on master.id = snapshot.master_equipment_id
     and master.organization_id = c.organization_id
     and master.branch_id = c.branch_id
    where snapshot.submission_id = s.id
      and not exists (
        select 1
        from public.branch_cold_storage_equipment active
        where active.id = snapshot.master_equipment_id
          and active.organization_id = c.organization_id
          and active.branch_id = c.branch_id
          and active.active
      )
      and exists (
        select 1
        from public.cold_storage_readings reading
        where reading.submission_id = snapshot.submission_id
          and reading.equipment_id = snapshot.equipment_id
          and reading.submitted_at is not null
      )
  ),
  equipment_union as (
    select
      equipment_id,
      sort_name,
      snapshot_id,
      master_equipment_id,
      equipment_code,
      name,
      equipment_type,
      true as active,
      created_at,
      first_eligible_business_date,
      first_eligible_slot
    from active_master_enriched
    union all
    select
      equipment_id,
      sort_name,
      snapshot_id,
      master_equipment_id,
      equipment_code,
      name,
      equipment_type,
      active,
      created_at,
      first_eligible_business_date,
      first_eligible_slot
    from historical_snapshot
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'id', equipment_union.snapshot_id,
        'equipment_id', equipment_union.equipment_id,
        'equipment_code', equipment_union.equipment_code,
        'equipment_name', equipment_union.name,
        'equipment_type', equipment_union.equipment_type,
        'active', equipment_union.active,
        'created_at', equipment_union.created_at,
        'first_eligible_business_date', equipment_union.first_eligible_business_date,
        'first_eligible_slot', equipment_union.first_eligible_slot,
        'eligible_for_active_slot',
          active_slot is not null
          and equipment_union.active
          and private.cold_storage_equipment_slot_eligible(
            equipment_union.first_eligible_business_date,
            equipment_union.first_eligible_slot,
            c.business_date,
            active_slot
          )
      ))
      order by equipment_union.sort_name, equipment_union.equipment_id
    ),
    '[]'::jsonb
  ) into equipment_result
  from equipment_union;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', reading.id,
        'equipment_id', coalesce(snapshot.master_equipment_id::text, reading.equipment_id),
        'slot', reading.slot,
        'temperature_c', reading.temperature_c,
        'status', reading.status,
        'corrective_action', reading.corrective_action,
        'submitted_at', reading.submitted_at
      )
      order by coalesce(snapshot.master_equipment_id::text, reading.equipment_id),
        case reading.slot when '12:00' then 1 when '20:00' then 2 when '02:00' then 3 when '3:00' then 4 else 5 end
    ),
    '[]'::jsonb
  ) into readings_result
  from public.cold_storage_readings reading
  join public.cold_storage_equipment snapshot
    on snapshot.submission_id = reading.submission_id
   and snapshot.equipment_id = reading.equipment_id
  left join public.branch_cold_storage_equipment master
    on master.id = snapshot.master_equipment_id
   and master.organization_id = c.organization_id
   and master.branch_id = c.branch_id
  where reading.submission_id = s.id
    and (
      reading.submitted_at is not null
      or snapshot.master_equipment_id is null
      or master.active
    );

  return pg_catalog.jsonb_build_object(
    'submission_id', s.id,
    'business_date', c.business_date,
    'state', coalesce(s.state, 'none'),
    'revision', coalesce(s.branch_revision, 0),
    'equipment', equipment_result,
    'readings', readings_result
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage state denied' using errcode = '42501';
end
$$;

create or replace function public.submit_cold_storage_slot(
  actor_user_id uuid,
  target_branch_id uuid,
  expected_revision bigint,
  slot text,
  idempotency_key uuid,
  request_hash text,
  equipment jsonb,
  readings jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.cold_storage_submissions%rowtype;
  prior record;
  submitted_time timestamptz;
  snapshot_equipment jsonb;
begin
  if length(request_hash) <> 64 then
    raise exception 'invalid cold storage slot submit' using errcode = '22023';
  end if;

  insert into public.cold_storage_submission_idempotency(actor_user_id, slot, idempotency_key, request_hash)
  values(actor_user_id, slot, idempotency_key, request_hash)
  on conflict do nothing;

  select * into strict prior
  from public.cold_storage_submission_idempotency x
  where x.actor_user_id = submit_cold_storage_slot.actor_user_id
    and x.slot = submit_cold_storage_slot.slot
    and x.idempotency_key = submit_cold_storage_slot.idempotency_key
  for update;

  if prior.request_hash <> request_hash then
    raise exception 'idempotency conflict' using errcode = '23505';
  end if;
  if prior.submission_id is not null then
    return private.cold_storage_current_result(actor_user_id, target_branch_id, prior.submission_id);
  end if;

  perform private.phase2_branch_context(actor_user_id, target_branch_id);
  perform private.enforce_cold_storage_requested_slot(target_branch_id, slot);

  s := private.upsert_cold_storage_submission(actor_user_id, target_branch_id, expected_revision, equipment, readings);
  snapshot_equipment := private.cold_storage_submission_equipment_roster(s.id, target_branch_id, s.business_date);
  perform private.validate_cold_storage_slot_submit_for_eligible(slot, snapshot_equipment, readings, s.business_date);

  select * into strict s
  from public.cold_storage_submissions
  where id = s.id
  for update;

  if exists (
    select 1
    from public.cold_storage_readings r
    where r.submission_id = s.id
      and r.slot = submit_cold_storage_slot.slot
      and r.submitted_at is not null
  ) then
    raise exception 'cold storage slot already submitted' using errcode = '23505';
  end if;

  submitted_time := now();
  update public.cold_storage_readings r
  set submitted_at = submitted_time,
    submitted_by_user_id = actor_user_id,
    temperature_c = private.cold_storage_numeric_field(entry.row_value, 'temperature_c'),
    status = case
      when private.cold_storage_numeric_field(entry.row_value, 'temperature_c') < 5 then 'pass'
      else 'fail'
    end,
    corrective_action = case
      when private.cold_storage_numeric_field(entry.row_value, 'temperature_c') >= 5
        then pg_catalog.btrim(coalesce(entry.row_value ->> 'corrective_action', ''))
      else coalesce(entry.row_value ->> 'corrective_action', '')
    end
  from pg_catalog.jsonb_array_elements(readings) entry(row_value)
  join pg_catalog.jsonb_array_elements(snapshot_equipment) equipment(row_value)
    on pg_catalog.btrim(equipment.row_value ->> 'equipment_id') = pg_catalog.btrim(entry.row_value ->> 'equipment_id')
   and coalesce((equipment.row_value ->> 'active')::boolean, true)
   and private.cold_storage_json_equipment_slot_eligible(equipment.row_value, s.business_date, submit_cold_storage_slot.slot)
  where r.submission_id = s.id
    and r.equipment_id = equipment.row_value ->> 'equipment_id'
    and r.slot = submit_cold_storage_slot.slot;

  insert into public.cold_storage_issues(submission_id, equipment_id, slot, temperature_c, corrective_action)
  select s.id, r.equipment_id, r.slot, r.temperature_c, r.corrective_action
  from public.cold_storage_readings r
  join pg_catalog.jsonb_array_elements(snapshot_equipment) equipment(row_value)
    on equipment.row_value ->> 'equipment_id' = r.equipment_id
   and coalesce((equipment.row_value ->> 'active')::boolean, true)
   and private.cold_storage_json_equipment_slot_eligible(equipment.row_value, s.business_date, r.slot)
  where r.submission_id = s.id
    and r.slot = submit_cold_storage_slot.slot
    and r.temperature_c >= 5;

  update public.cold_storage_submissions
  set state = case
      when private.cold_storage_submission_complete(s.id, target_branch_id, s.business_date) then 'submitted'
      else 'draft'
    end,
    branch_revision = branch_revision + 1,
    updated_by_user_id = actor_user_id
  where id = s.id
  returning * into s;

  update public.cold_storage_submission_idempotency
  set submission_id = s.id
  where cold_storage_submission_idempotency.actor_user_id = submit_cold_storage_slot.actor_user_id
    and cold_storage_submission_idempotency.slot = submit_cold_storage_slot.slot
    and cold_storage_submission_idempotency.idempotency_key = submit_cold_storage_slot.idempotency_key;

  return private.cold_storage_current_result(actor_user_id, target_branch_id, s.id);
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage submit denied' using errcode = '42501';
end
$$;

revoke all on function private.cold_storage_slot_order(text) from public, anon, authenticated;
revoke all on function private.cold_storage_master_first_eligible_slot(text, timestamptz) from public, anon, authenticated;
revoke all on function private.cold_storage_equipment_slot_eligible(date, text, date, text) from public, anon, authenticated;
revoke all on function private.cold_storage_json_equipment_slot_eligible(jsonb, date, text) from public, anon, authenticated;
revoke all on function private.cold_storage_master_has_backfilled_history(uuid, timestamptz) from public, anon, authenticated;
revoke all on function private.ensure_cold_storage_snapshot_master_equipment(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function private.cold_storage_submission_equipment_roster(uuid, uuid, date) from public, anon, authenticated;
revoke all on function private.cold_storage_filter_eligible_readings(jsonb, jsonb, date) from public, anon, authenticated;
revoke all on function private.validate_cold_storage_slot_submit_for_eligible(text, jsonb, jsonb, date) from public, anon, authenticated;
revoke all on function private.cold_storage_submission_complete(uuid, uuid, date) from public, anon, authenticated;
revoke all on function private.upsert_cold_storage_submission(uuid, uuid, bigint, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.get_cold_storage_current_state(uuid, uuid) from public, anon, authenticated;
revoke all on function public.submit_cold_storage_slot(uuid, uuid, bigint, text, uuid, text, jsonb, jsonb) from public, anon, authenticated;

grant execute on function public.get_cold_storage_current_state(uuid, uuid) to service_role;
grant execute on function public.submit_cold_storage_slot(uuid, uuid, bigint, text, uuid, text, jsonb, jsonb) to service_role;
