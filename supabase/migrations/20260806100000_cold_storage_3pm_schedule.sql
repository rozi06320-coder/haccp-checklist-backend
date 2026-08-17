alter table public.cold_storage_readings
  drop constraint if exists cold_storage_readings_slot_check;
alter table public.cold_storage_submission_idempotency
  drop constraint if exists cold_storage_submission_idempotency_slot_check;
alter table public.cold_storage_issues
  drop constraint if exists cold_storage_issues_slot_check;

update public.cold_storage_readings set slot = '3:00' where slot = '4:00';
update public.cold_storage_submission_idempotency set slot = '3:00' where slot = '4:00';
update public.cold_storage_issues set slot = '3:00' where slot = '4:00';

alter table public.cold_storage_readings
  add constraint cold_storage_readings_slot_check check (slot in ('12:00','3:00','8:00'));
alter table public.cold_storage_submission_idempotency
  add constraint cold_storage_submission_idempotency_slot_check check (slot in ('12:00','3:00','8:00'));
alter table public.cold_storage_issues
  add constraint cold_storage_issues_slot_check check (slot in ('12:00','3:00','8:00'));

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
    or row_value ->> 'slot' not in ('12:00','3:00','8:00')
    or row_value ->> 'status' not in ('pending','pass','fail')
    or pg_catalog.length(coalesce(row_value ->> 'corrective_action', '')) > 2000
    then
      raise exception 'invalid cold storage reading row' using errcode = '22023';
    end if;
    perform private.cold_storage_numeric_field(row_value, 'temperature_c');
  end loop;
end $$;
revoke all on function private.validate_cold_storage_readings(jsonb,jsonb) from public, anon, authenticated;

create or replace function public.get_cold_storage_current_state(actor_user_id uuid, target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; submission public.cold_storage_submissions%rowtype;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  select * into submission
  from public.cold_storage_submissions s
  where s.organization_id = c.organization_id
    and s.branch_id = c.branch_id
    and s.supervisor_team_id = c.team_id
    and s.business_date = c.business_date
  order by s.updated_at desc, s.id
  limit 1;

  return pg_catalog.jsonb_build_object(
    'submission_id', submission.id,
    'business_date', c.business_date,
    'state', coalesce(submission.state, 'none'),
    'equipment', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', e.id,
        'equipment_id', e.equipment_id,
        'equipment_name', e.equipment_name,
        'equipment_type', e.equipment_type,
        'active', e.active
      ) order by lower(e.equipment_name), e.equipment_id)
      from public.cold_storage_equipment e
      where e.submission_id = submission.id
    ), '[]'::jsonb),
    'readings', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', r.id,
        'equipment_id', r.equipment_id,
        'slot', r.slot,
        'temperature_c', r.temperature_c,
        'status', r.status,
        'corrective_action', r.corrective_action,
        'submitted_at', r.submitted_at
      ) order by r.equipment_id, case r.slot when '12:00' then 1 when '3:00' then 2 else 3 end)
      from public.cold_storage_readings r
      where r.submission_id = submission.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage state denied' using errcode = '42501';
end $$;

create or replace function private.validate_cold_storage_slot_submit(target_slot text, equipment jsonb, readings jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare eq_value jsonb; reading_value jsonb; reading_count integer; temperature numeric; action text; active_count integer := 0;
begin
  if target_slot not in ('12:00','3:00','8:00') then
    raise exception 'invalid cold storage slot' using errcode = '22023';
  end if;
  perform private.validate_cold_storage_equipment(equipment);
  perform private.validate_cold_storage_readings(equipment, readings);

  for eq_value in select value from pg_catalog.jsonb_array_elements(equipment) loop
    if coalesce((eq_value ->> 'active')::boolean, true) then
      active_count := active_count + 1;
      select count(*)
      into reading_count
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
    end if;
  end loop;
  if active_count = 0 then
    raise exception 'invalid cold storage slot submit' using errcode = '22023';
  end if;
end $$;
revoke all on function private.validate_cold_storage_slot_submit(text,jsonb,jsonb) from public, anon, authenticated;

create or replace function public.submit_cold_storage_slot(
  actor_user_id uuid,
  target_branch_id uuid,
  slot text,
  idempotency_key uuid,
  request_hash text,
  equipment jsonb,
  readings jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare submission public.cold_storage_submissions%rowtype; prior record; submitted_at_value timestamptz;
begin
  if length(request_hash) <> 64 then
    raise exception 'invalid cold storage slot submit' using errcode = '22023';
  end if;
  perform private.validate_cold_storage_slot_submit(slot, equipment, readings);

  insert into public.cold_storage_submission_idempotency(actor_user_id, slot, idempotency_key, request_hash)
  values(actor_user_id, slot, idempotency_key, request_hash)
  on conflict do nothing;
  select * into strict prior from public.cold_storage_submission_idempotency x
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

  submission := private.upsert_cold_storage_submission(actor_user_id, target_branch_id, equipment, readings);
  select * into strict submission from public.cold_storage_submissions where id = submission.id for update;
  if exists(select 1 from public.cold_storage_readings r where r.submission_id = submission.id and r.slot = submit_cold_storage_slot.slot and r.submitted_at is not null) then
    raise exception 'cold storage slot already submitted' using errcode = '23505';
  end if;

  submitted_at_value := now();
  update public.cold_storage_readings r set
    submitted_at = submitted_at_value,
    temperature_c = private.cold_storage_numeric_field(entry.row_value, 'temperature_c'),
    status = case when private.cold_storage_numeric_field(entry.row_value, 'temperature_c') < 5 then 'pass' else 'fail' end,
    corrective_action = case
      when private.cold_storage_numeric_field(entry.row_value, 'temperature_c') >= 5 then pg_catalog.btrim(coalesce(entry.row_value ->> 'corrective_action', ''))
      else coalesce(entry.row_value ->> 'corrective_action', '')
    end
  from pg_catalog.jsonb_array_elements(readings) entry(row_value)
  join public.cold_storage_equipment e
    on e.submission_id = submission.id
   and e.equipment_id = pg_catalog.btrim(entry.row_value ->> 'equipment_id')
   and e.active
  where r.submission_id = submission.id
    and r.equipment_id = e.equipment_id
    and r.slot = submit_cold_storage_slot.slot;

  insert into public.cold_storage_issues(submission_id, equipment_id, slot, temperature_c, corrective_action)
  select submission.id, r.equipment_id, r.slot, r.temperature_c, r.corrective_action
  from public.cold_storage_readings r
  join public.cold_storage_equipment e on e.submission_id = r.submission_id and e.equipment_id = r.equipment_id
  where r.submission_id = submission.id
    and r.slot = submit_cold_storage_slot.slot
    and e.active
    and r.temperature_c >= 5;

  if not exists(
    select 1
    from public.cold_storage_equipment e
    cross join (values ('12:00'), ('3:00'), ('8:00')) expected(slot)
    where e.submission_id = submission.id
      and e.active
      and not exists (
        select 1 from public.cold_storage_readings r
        where r.submission_id = e.submission_id
          and r.equipment_id = e.equipment_id
          and r.slot = expected.slot
          and r.submitted_at is not null
      )
  ) then
    update public.cold_storage_submissions set state = 'submitted' where id = submission.id;
  end if;

  update public.cold_storage_submission_idempotency i
  set submission_id = submission.id
  where i.actor_user_id = submit_cold_storage_slot.actor_user_id
    and i.slot = submit_cold_storage_slot.slot
    and i.idempotency_key = submit_cold_storage_slot.idempotency_key;

  return private.cold_storage_current_result(actor_user_id, target_branch_id, submission.id);
end $$;
