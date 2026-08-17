-- Refrigerator & Freezer schedule: 12:00, 20:00, and 02:00.
-- Legacy 3:00/8:00 rows remain readable, while new writes use canonical 24-hour slots.

alter table public.cold_storage_readings
  drop constraint if exists cold_storage_readings_slot_check;
alter table public.cold_storage_submission_idempotency
  drop constraint if exists cold_storage_submission_idempotency_slot_check;
alter table public.cold_storage_issues
  drop constraint if exists cold_storage_issues_slot_check;

alter table public.cold_storage_readings
  add constraint cold_storage_readings_slot_check
  check (slot in ('12:00','20:00','02:00','3:00','8:00'));
alter table public.cold_storage_submission_idempotency
  add constraint cold_storage_submission_idempotency_slot_check
  check (slot in ('12:00','20:00','02:00','3:00','8:00'));
alter table public.cold_storage_issues
  add constraint cold_storage_issues_slot_check
  check (slot in ('12:00','20:00','02:00','3:00','8:00'));

create or replace function private.validate_cold_storage_readings(equipment jsonb, readings jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb;
begin
  if pg_catalog.jsonb_typeof(readings) <> 'array' or pg_catalog.jsonb_array_length(readings) > 300 then
    raise exception 'invalid cold storage readings' using errcode = '22023';
  end if;
  if (
    select count(*) <> count(distinct ((value ->> 'equipment_id') || '|' || (value ->> 'slot')))
    from pg_catalog.jsonb_array_elements(readings)
  ) then
    raise exception 'duplicate cold storage reading' using errcode = '22023';
  end if;
  for row_value in select value from pg_catalog.jsonb_array_elements(readings) loop
    if not (
      row_value ? 'equipment_id'
      and row_value ? 'slot'
      and row_value ? 'status'
    )
    or pg_catalog.jsonb_typeof(row_value -> 'equipment_id') <> 'string'
    or not exists (
      select 1 from pg_catalog.jsonb_array_elements(equipment) eq
      where pg_catalog.btrim(eq ->> 'equipment_id') = pg_catalog.btrim(row_value ->> 'equipment_id')
    )
    or row_value ->> 'slot' not in ('12:00','20:00','02:00')
    or row_value ->> 'status' not in ('pending','pass','fail')
    or pg_catalog.length(coalesce(row_value ->> 'corrective_action', '')) > 2000
    then
      raise exception 'invalid cold storage reading row' using errcode = '22023';
    end if;
    perform private.cold_storage_numeric_field(row_value, 'temperature_c');
  end loop;
end $$;
revoke all on function private.validate_cold_storage_readings(jsonb,jsonb) from public, anon, authenticated;

create or replace function private.validate_cold_storage_slot_submit(target_slot text, equipment jsonb, readings jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare eq_value jsonb; reading_value jsonb; reading_count integer; temperature numeric; action text; active_count integer := 0;
begin
  if target_slot not in ('12:00','20:00','02:00') then
    raise exception 'invalid cold storage slot' using errcode = '22023';
  end if;
  perform private.validate_cold_storage_equipment(equipment);
  perform private.validate_cold_storage_readings(equipment, readings);

  for eq_value in select value from pg_catalog.jsonb_array_elements(equipment) loop
    if coalesce((eq_value ->> 'active')::boolean, true) then
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
      if temperature is null or (temperature >= 5 and pg_catalog.length(action) = 0) then
        raise exception 'invalid cold storage slot submit' using errcode = '22023';
      end if;
    end if;
  end loop;
  if active_count = 0 then
    raise exception 'invalid cold storage slot submit' using errcode = '22023';
  end if;
end $$;
revoke all on function private.validate_cold_storage_slot_submit(text,jsonb,jsonb) from public, anon, authenticated;

do $$
declare definition text; updated_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.submit_cold_storage_slot(uuid,uuid,text,uuid,text,jsonb,jsonb)'::regprocedure)
  into definition;
  updated_definition := replace(
    definition,
    $old$cross join (values ('12:00'), ('3:00'), ('8:00')) expected(slot)$old$,
    $new$cross join (values ('12:00'), ('20:00'), ('02:00')) expected(slot)$new$
  );
  if updated_definition = definition then
    raise exception 'failed to update cold storage submit completion slots' using errcode = '22023';
  end if;
  execute updated_definition;
end $$;

create or replace function private.cold_storage_due_slots_for(target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp())
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare branch_timezone text; local_date date; local_hour int;
begin
  select timezone into strict branch_timezone from public.branches where id = target_branch_id;
  local_date := (as_of at time zone branch_timezone)::date;
  local_hour := extract(hour from as_of at time zone branch_timezone)::int;

  if target_business_date < local_date - 1 then
    return array['12:00','20:00','02:00']::text[];
  elsif target_business_date = local_date - 1 then
    if local_hour < 2 then return array['12:00','20:00']::text[]; end if;
    return array['12:00','20:00','02:00']::text[];
  elsif target_business_date > local_date or local_hour < 12 then
    return array[]::text[];
  elsif local_hour < 20 then
    return array['12:00']::text[];
  end if;
  return array['12:00','20:00']::text[];
end $$;

create or replace function private.cold_storage_closed_slots_for(target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp())
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare branch_timezone text; local_date date; local_hour int;
begin
  select timezone into strict branch_timezone from public.branches where id = target_branch_id;
  local_date := (as_of at time zone branch_timezone)::date;
  local_hour := extract(hour from as_of at time zone branch_timezone)::int;

  if target_business_date < local_date - 1 then
    return array['12:00','20:00','02:00']::text[];
  elsif target_business_date = local_date - 1 then
    if local_hour < 2 then return array['12:00']::text[]; end if;
    if local_hour < 3 then return array['12:00','20:00']::text[]; end if;
    return array['12:00','20:00','02:00']::text[];
  elsif target_business_date > local_date or local_hour < 20 then
    return array[]::text[];
  end if;
  return array['12:00']::text[];
end $$;

create or replace function private.cold_storage_missed_slots_for(
  target_branch_id uuid,
  target_business_date date,
  submitted_slots text[],
  as_of timestamptz default pg_catalog.statement_timestamp()
) returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(slot order by case slot when '12:00' then 1 when '20:00' then 2 else 3 end), array[]::text[])
  from unnest(private.cold_storage_closed_slots_for(target_branch_id, target_business_date, as_of)) slot
  where not (
    slot = any(coalesce(submitted_slots, array[]::text[]))
    or (slot = '20:00' and '3:00' = any(coalesce(submitted_slots, array[]::text[])))
    or (slot = '02:00' and '8:00' = any(coalesce(submitted_slots, array[]::text[])))
  );
$$;

revoke all on function private.cold_storage_due_slots_for(uuid,date,timestamptz),
  private.cold_storage_closed_slots_for(uuid,date,timestamptz),
  private.cold_storage_missed_slots_for(uuid,date,text[],timestamptz)
from public, anon, authenticated;

do $$
declare definition text; updated_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.get_phase4a_management_overview(uuid,uuid)'::regprocedure)
  into definition;
  updated_definition := replace(definition, $old$
      case
        when extract(hour from snapshot_at at time zone branch.timezone) < 12 then array[]::text[]
        when extract(hour from snapshot_at at time zone branch.timezone) < 15 then array['12:00']::text[]
        when extract(hour from snapshot_at at time zone branch.timezone) < 20 then array['12:00','3:00']::text[]
        else array['12:00','3:00','8:00']::text[]
      end due_cold_slots
$old$, $new$
      private.cold_storage_due_slots_for(
        branch.id,
        private.phase4a_business_date(branch.timezone),
        snapshot_at
      ) due_cold_slots
$new$);
  if updated_definition = definition then
    raise exception 'failed to update management overview cold storage slots' using errcode = '22023';
  end if;
  execute updated_definition;
end $$;
