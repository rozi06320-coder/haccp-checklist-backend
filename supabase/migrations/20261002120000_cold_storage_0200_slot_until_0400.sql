-- Keep the final Cold Storage slot open through the canonical 04:00
-- business-day boundary. Configurable schedules are installed in production,
-- but remain optional in older/fresh environments supported by this repository.

create or replace function private.cold_storage_eligible_slot_at(tz text, as_of timestamptz)
returns text language sql stable strict security definer set search_path = '' as $$
  with local_time as (
    select (as_of at time zone tz)::time as value
  )
  select case
    when value >= time '12:00' and value < time '20:00' then '12:00'
    when value >= time '20:00' or value < time '02:00' then '20:00'
    when value >= time '02:00' and value < time '04:00' then '02:00'
    else null
  end
  from local_time
$$;

do $cold_storage_0200_until_0400$
begin
  if pg_catalog.to_regclass('public.cold_storage_schedule_versions') is not null
    and pg_catalog.to_regclass('public.cold_storage_schedule_slots') is not null
    and pg_catalog.to_regclass('public.branch_cold_storage_schedule_assignments') is not null
    and pg_catalog.to_regprocedure('private.cold_storage_slot_occurrence_local(date,text)') is not null
    and pg_catalog.to_regprocedure('private.cold_storage_schedule_context_at(uuid,timestamptz)') is not null
  then
    execute $function$
      create or replace function private.cold_storage_slot_occurrence_local(
        target_business_date date,
        target_slot text
      ) returns timestamp
      language sql immutable strict security definer set search_path = '' as $body$
        select target_business_date::timestamp
          + case when target_slot::time < time '04:00' then interval '1 day' else interval '0 day' end
          + target_slot::time
      $body$
    $function$;

    execute $function$
      create or replace function private.cold_storage_schedule_context_at(
        target_branch_id uuid,
        as_of timestamptz
      ) returns jsonb
      language plpgsql stable security definer set search_path = '' as $body$
      declare
        branch_timezone text;
        local_as_of timestamp;
        target_business_date date;
        target_schedule_version_id uuid;
        target_schedule_code text;
        target_schedule_name text;
        active_slot text;
        next_slot text;
        active_transition_local timestamp;
        next_slot_local timestamp;
      begin
        select branch.timezone into strict branch_timezone
        from public.branches branch where branch.id = target_branch_id and branch.active;
        local_as_of := as_of at time zone branch_timezone;
        target_business_date := private.phase4a_business_date_at(branch_timezone, as_of);
        target_schedule_version_id := private.cold_storage_schedule_version_for(target_branch_id, target_business_date);
        select version.code, version.name into strict target_schedule_code, target_schedule_name
        from public.cold_storage_schedule_versions version
        where version.id = target_schedule_version_id;

        with occurrence as (
          select slot.slot_time,
            private.cold_storage_slot_occurrence_local(target_business_date, slot.slot_time) as starts_at,
            lead(private.cold_storage_slot_occurrence_local(target_business_date, slot.slot_time), 1,
              (target_business_date + 1)::timestamp + time '04:00') over(order by slot.operational_ordinal) as ends_at
          from public.cold_storage_schedule_slots slot
          where slot.schedule_version_id = target_schedule_version_id
        )
        select occurrence.slot_time, occurrence.ends_at
        into active_slot, active_transition_local
        from occurrence
        where local_as_of >= occurrence.starts_at and local_as_of < occurrence.ends_at
        order by occurrence.starts_at desc limit 1;

        select slot.slot_time,
          private.cold_storage_slot_occurrence_local(target_business_date, slot.slot_time)
        into next_slot, next_slot_local
        from public.cold_storage_schedule_slots slot
        where slot.schedule_version_id = target_schedule_version_id
          and private.cold_storage_slot_occurrence_local(target_business_date, slot.slot_time) > local_as_of
        order by slot.operational_ordinal limit 1;

        if next_slot is null then
          select slot.slot_time,
            private.cold_storage_slot_occurrence_local(target_business_date + 1, slot.slot_time)
          into next_slot, next_slot_local
          from public.cold_storage_schedule_slots slot
          where slot.schedule_version_id = private.cold_storage_schedule_version_for(target_branch_id, target_business_date + 1)
          order by slot.operational_ordinal limit 1;
        end if;

        return pg_catalog.jsonb_build_object(
          'business_date', target_business_date,
          'schedule_version_id', target_schedule_version_id,
          'schedule_code', target_schedule_code,
          'schedule_name', target_schedule_name,
          'slots', private.cold_storage_schedule_slots_json(target_schedule_version_id),
          'active_slot', active_slot,
          'next_slot', next_slot,
          'next_transition_at', coalesce(active_transition_local, next_slot_local) at time zone branch_timezone
        );
      exception when no_data_found or too_many_rows then
        raise exception 'cold storage schedule unavailable' using errcode = '42501';
      end
      $body$
    $function$;

    execute $function$
      create or replace function private.cold_storage_closed_slots_for(
        target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp()
      ) returns text[] language sql stable security definer set search_path = '' as $body$
        with slots as (
          select slot.slot_time, slot.operational_ordinal,
            lead(private.cold_storage_slot_occurrence_local(target_business_date, slot.slot_time), 1,
              (target_business_date + 1)::timestamp + time '04:00') over(order by slot.operational_ordinal) closes_at
          from public.cold_storage_schedule_slots slot
          where slot.schedule_version_id = private.cold_storage_schedule_version_for(target_branch_id, target_business_date)
        )
        select coalesce(pg_catalog.array_agg(slots.slot_time order by slots.operational_ordinal), array[]::text[])
        from slots join public.branches branch on branch.id = target_branch_id
        where slots.closes_at <= (as_of at time zone branch.timezone)
      $body$
    $function$;
  else
    execute $function$
      create or replace function private.cold_storage_closed_slots_for(
        target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp()
      ) returns text[] language plpgsql stable security definer set search_path = '' as $body$
      declare branch_timezone text; local_date date; local_hour int;
      begin
        select timezone into strict branch_timezone from public.branches where id = target_branch_id;
        local_date := (as_of at time zone branch_timezone)::date;
        local_hour := extract(hour from as_of at time zone branch_timezone)::int;

        if target_business_date < local_date - 1 then
          return array['12:00','20:00','02:00']::text[];
        elsif target_business_date = local_date - 1 then
          if local_hour < 2 then return array['12:00']::text[]; end if;
          if local_hour < 4 then return array['12:00','20:00']::text[]; end if;
          return array['12:00','20:00','02:00']::text[];
        elsif target_business_date > local_date or local_hour < 20 then
          return array[]::text[];
        end if;
        return array['12:00']::text[];
      end
      $body$
    $function$;
  end if;
end
$cold_storage_0200_until_0400$;
