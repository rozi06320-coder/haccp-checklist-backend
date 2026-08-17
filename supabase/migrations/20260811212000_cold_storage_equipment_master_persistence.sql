-- Cold Storage equipment master Phase 3: use active branch master equipment
-- for unsubmitted work while preserving submission-scoped historical snapshots.

create function private.cold_storage_try_uuid(candidate text)
returns uuid
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return candidate::uuid;
exception
  when invalid_text_representation then
    return null;
end;
$$;

revoke all on function private.cold_storage_try_uuid(text)
  from public, anon, authenticated, service_role;

create function private.resolve_cold_storage_equipment_roster(
  target_organization_id uuid,
  target_branch_id uuid,
  supplied_equipment jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  entry jsonb;
  equipment_key text;
  explicit_master boolean;
  master_id uuid;
  master_row public.branch_cold_storage_equipment%rowtype;
  legacy_equipment jsonb := '[]'::jsonb;
  resolved_equipment jsonb;
begin
  if supplied_equipment is null
    or pg_catalog.jsonb_typeof(supplied_equipment) <> 'array'
    or pg_catalog.jsonb_array_length(supplied_equipment) > 100
  then
    raise exception 'invalid cold storage equipment' using errcode = '22023';
  end if;

  if (
    select pg_catalog.count(*) <> pg_catalog.count(distinct pg_catalog.btrim(value ->> 'equipment_id'))
    from pg_catalog.jsonb_array_elements(supplied_equipment)
  ) then
    raise exception 'duplicate cold storage equipment' using errcode = '22023';
  end if;

  for entry in
    select value from pg_catalog.jsonb_array_elements(supplied_equipment)
  loop
    if not (entry ? 'equipment_id')
      or pg_catalog.jsonb_typeof(entry -> 'equipment_id') <> 'string'
      or pg_catalog.length(pg_catalog.btrim(entry ->> 'equipment_id')) not between 1 and 80
    then
      raise exception 'invalid cold storage equipment row' using errcode = '22023';
    end if;

    equipment_key := pg_catalog.btrim(entry ->> 'equipment_id');
    explicit_master := entry ? 'master_equipment_id';

    if explicit_master then
      if pg_catalog.jsonb_typeof(entry -> 'master_equipment_id') <> 'string' then
        raise exception 'invalid cold storage master equipment' using errcode = '22023';
      end if;
      master_id := private.cold_storage_try_uuid(pg_catalog.btrim(entry ->> 'master_equipment_id'));
      if master_id is null or equipment_key <> master_id::text then
        raise exception 'invalid cold storage master equipment' using errcode = '22023';
      end if;
    else
      master_id := private.cold_storage_try_uuid(equipment_key);
    end if;

    master_row := null;
    if master_id is not null then
      select master.* into master_row
      from public.branch_cold_storage_equipment master
      where master.id = master_id;
    end if;

    if master_row.id is not null then
      if master_row.organization_id <> target_organization_id
        or master_row.branch_id <> target_branch_id
        or not master_row.active
      then
        raise exception 'cold storage master equipment denied' using errcode = '42501';
      end if;
      -- The server-owned active master row is added below. Browser-supplied
      -- name, type, active, organization, and branch fields are ignored.
      continue;
    elsif explicit_master then
      raise exception 'cold storage master equipment denied' using errcode = '42501';
    end if;

    if not (entry ? 'equipment_name' and entry ? 'equipment_type')
      or pg_catalog.jsonb_typeof(entry -> 'equipment_name') <> 'string'
      or pg_catalog.length(pg_catalog.btrim(entry ->> 'equipment_name')) not between 1 and 120
      or entry ->> 'equipment_type' not in ('refrigerator', 'freezer')
      or (entry ? 'active' and pg_catalog.jsonb_typeof(entry -> 'active') <> 'boolean')
    then
      raise exception 'invalid cold storage equipment row' using errcode = '22023';
    end if;

    legacy_equipment := legacy_equipment || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'equipment_id', equipment_key,
        'equipment_name', pg_catalog.btrim(entry ->> 'equipment_name'),
        'equipment_type', entry ->> 'equipment_type',
        'active', coalesce((entry ->> 'active')::boolean, true)
      )
    );
  end loop;

  select coalesce(
    pg_catalog.jsonb_agg(roster.item order by roster.sort_name, roster.equipment_id),
    '[]'::jsonb
  ) into resolved_equipment
  from (
    select
      master.id::text as equipment_id,
      pg_catalog.lower(master.name) as sort_name,
      pg_catalog.jsonb_build_object(
        'equipment_id', master.id::text,
        'master_equipment_id', master.id,
        'organization_id', master.organization_id,
        'branch_id', master.branch_id,
        'equipment_name', master.name,
        'equipment_type', master.equipment_type,
        'active', true
      ) as item
    from public.branch_cold_storage_equipment master
    where master.organization_id = target_organization_id
      and master.branch_id = target_branch_id
      and master.active

    union all

    select
      legacy.value ->> 'equipment_id',
      pg_catalog.lower(legacy.value ->> 'equipment_name'),
      legacy.value
    from pg_catalog.jsonb_array_elements(legacy_equipment) legacy(value)
  ) roster;

  if pg_catalog.jsonb_array_length(resolved_equipment) > 100 then
    raise exception 'invalid cold storage equipment' using errcode = '22023';
  end if;

  return resolved_equipment;
end;
$$;

revoke all on function private.resolve_cold_storage_equipment_roster(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;

create function private.cold_storage_snapshot_equipment(target_submission_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'id', equipment.id,
        'equipment_id', equipment.equipment_id,
        'master_equipment_id', equipment.master_equipment_id,
        'organization_id', equipment.organization_id,
        'branch_id', equipment.branch_id,
        'equipment_name', equipment.equipment_name,
        'equipment_type', equipment.equipment_type,
        'active', equipment.active
      ))
      order by pg_catalog.lower(equipment.equipment_name), equipment.equipment_id
    ),
    '[]'::jsonb
  )
  from public.cold_storage_equipment equipment
  where equipment.submission_id = target_submission_id;
$$;

revoke all on function private.cold_storage_snapshot_equipment(uuid)
  from public, anon, authenticated, service_role;

create or replace function private.replace_cold_storage_equipment(
  submission_id uuid,
  equipment jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.cold_storage_equipment snapshot
  where snapshot.submission_id = replace_cold_storage_equipment.submission_id;

  insert into public.cold_storage_equipment(
    submission_id,
    equipment_id,
    equipment_name,
    equipment_type,
    active,
    master_equipment_id,
    organization_id,
    branch_id
  )
  select
    submission_id,
    pg_catalog.btrim(row_value ->> 'equipment_id'),
    pg_catalog.btrim(row_value ->> 'equipment_name'),
    row_value ->> 'equipment_type',
    coalesce((row_value ->> 'active')::boolean, true),
    case when row_value ? 'master_equipment_id'
      then (row_value ->> 'master_equipment_id')::uuid else null end,
    case when row_value ? 'organization_id'
      then (row_value ->> 'organization_id')::uuid else null end,
    case when row_value ? 'branch_id'
      then (row_value ->> 'branch_id')::uuid else null end
  from pg_catalog.jsonb_array_elements(equipment) entry(row_value);
end;
$$;

revoke all on function private.replace_cold_storage_equipment(uuid, jsonb)
  from public, anon, authenticated, service_role;

create or replace function private.upsert_cold_storage_submission(
  actor_user_id uuid,
  target_branch_id uuid,
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
  actor_context record;
  submission public.cold_storage_submissions%rowtype;
  has_submitted boolean;
  resolved_equipment jsonb;
begin
  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  insert into public.cold_storage_submissions(
    organization_id,
    branch_id,
    supervisor_user_id,
    supervisor_team_id,
    business_date,
    state,
    branch_name_snapshot,
    supervisor_name_snapshot,
    team_name_snapshot
  ) values (
    actor_context.organization_id,
    actor_context.branch_id,
    actor_user_id,
    actor_context.team_id,
    actor_context.business_date,
    'draft',
    actor_context.branch_name,
    actor_context.supervisor_name,
    actor_context.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_team_id, business_date) do update set
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    team_name_snapshot = excluded.team_name_snapshot
  returning * into submission;

  select * into strict submission
  from public.cold_storage_submissions existing
  where existing.id = submission.id
  for update;

  select exists(
    select 1
    from public.cold_storage_readings reading
    where reading.submission_id = submission.id
      and reading.submitted_at is not null
  ) into has_submitted;

  if has_submitted then
    perform private.validate_cold_storage_equipment(equipment);
    if not private.cold_storage_equipment_set_matches(submission.id, equipment) then
      raise exception 'submitted cold storage equipment is immutable' using errcode = '23505';
    end if;
    resolved_equipment := private.cold_storage_snapshot_equipment(submission.id);
  else
    resolved_equipment := private.resolve_cold_storage_equipment_roster(
      actor_context.organization_id,
      actor_context.branch_id,
      equipment
    );
    perform private.replace_cold_storage_equipment(submission.id, resolved_equipment);
    resolved_equipment := private.cold_storage_snapshot_equipment(submission.id);
  end if;

  perform private.validate_cold_storage_readings(resolved_equipment, readings);
  perform private.replace_cold_storage_unsubmitted_readings(submission.id, readings);
  return submission;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage operation denied' using errcode = '42501';
end;
$$;

revoke all on function private.upsert_cold_storage_submission(uuid, uuid, jsonb, jsonb)
  from public, anon, authenticated, service_role;

create or replace function public.get_cold_storage_current_state(
  actor_user_id uuid,
  target_branch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context record;
  submission public.cold_storage_submissions%rowtype;
  has_submitted boolean := false;
  equipment_result jsonb;
  readings_result jsonb;
begin
  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  select * into submission
  from public.cold_storage_submissions existing
  where existing.organization_id = actor_context.organization_id
    and existing.branch_id = actor_context.branch_id
    and existing.supervisor_team_id = actor_context.team_id
    and existing.business_date = actor_context.business_date
  order by existing.updated_at desc, existing.id
  limit 1;

  if submission.id is not null then
    select exists(
      select 1
      from public.cold_storage_readings reading
      where reading.submission_id = submission.id
        and reading.submitted_at is not null
    ) into has_submitted;
  end if;

  if has_submitted then
    select coalesce(
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', snapshot.id,
        'equipment_id', snapshot.equipment_id,
        'equipment_name', snapshot.equipment_name,
        'equipment_type', snapshot.equipment_type,
        'active', snapshot.active
      ) order by pg_catalog.lower(snapshot.equipment_name), snapshot.equipment_id),
      '[]'::jsonb
    ) into equipment_result
    from public.cold_storage_equipment snapshot
    where snapshot.submission_id = submission.id;

    select coalesce(
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', reading.id,
        'equipment_id', reading.equipment_id,
        'slot', reading.slot,
        'temperature_c', reading.temperature_c,
        'status', reading.status,
        'corrective_action', reading.corrective_action,
        'submitted_at', reading.submitted_at
      ) order by reading.equipment_id,
        case reading.slot when '12:00' then 1 when '20:00' then 2 when '02:00' then 3 when '3:00' then 4 else 5 end),
      '[]'::jsonb
    ) into readings_result
    from public.cold_storage_readings reading
    where reading.submission_id = submission.id;
  else
    select coalesce(
      pg_catalog.jsonb_agg(roster.item order by roster.sort_name, roster.equipment_id),
      '[]'::jsonb
    ) into equipment_result
    from (
      select
        master.id::text as equipment_id,
        pg_catalog.lower(master.name) as sort_name,
        pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
          'id', snapshot.id,
          'equipment_id', master.id::text,
          'equipment_name', master.name,
          'equipment_type', master.equipment_type,
          'active', true
        )) as item
      from public.branch_cold_storage_equipment master
      left join lateral (
        select linked.id
        from public.cold_storage_equipment linked
        where linked.submission_id = submission.id
          and linked.master_equipment_id = master.id
        order by linked.id
        limit 1
      ) snapshot on true
      where master.organization_id = actor_context.organization_id
        and master.branch_id = actor_context.branch_id
        and master.active

      union all

      select
        legacy.equipment_id,
        pg_catalog.lower(legacy.equipment_name),
        pg_catalog.jsonb_build_object(
          'id', legacy.id,
          'equipment_id', legacy.equipment_id,
          'equipment_name', legacy.equipment_name,
          'equipment_type', legacy.equipment_type,
          'active', legacy.active
        )
      from public.cold_storage_equipment legacy
      where legacy.submission_id = submission.id
        and legacy.master_equipment_id is null
    ) roster;

    select coalesce(
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', reading.id,
        'equipment_id', coalesce(snapshot.master_equipment_id::text, reading.equipment_id),
        'slot', reading.slot,
        'temperature_c', reading.temperature_c,
        'status', reading.status,
        'corrective_action', reading.corrective_action,
        'submitted_at', reading.submitted_at
      ) order by coalesce(snapshot.master_equipment_id::text, reading.equipment_id),
        case reading.slot when '12:00' then 1 when '20:00' then 2 when '02:00' then 3 when '3:00' then 4 else 5 end),
      '[]'::jsonb
    ) into readings_result
    from public.cold_storage_readings reading
    join public.cold_storage_equipment snapshot
      on snapshot.submission_id = reading.submission_id
     and snapshot.equipment_id = reading.equipment_id
    left join public.branch_cold_storage_equipment master
      on master.id = snapshot.master_equipment_id
     and master.organization_id = actor_context.organization_id
     and master.branch_id = actor_context.branch_id
    where reading.submission_id = submission.id
      and (snapshot.master_equipment_id is null or master.active);
  end if;

  return pg_catalog.jsonb_build_object(
    'submission_id', submission.id,
    'business_date', actor_context.business_date,
    'state', coalesce(submission.state, 'none'),
    'equipment', equipment_result,
    'readings', readings_result
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage state denied' using errcode = '42501';
end;
$$;

create or replace function public.save_cold_storage_draft(
  actor_user_id uuid,
  target_branch_id uuid,
  equipment jsonb,
  readings jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.upsert_cold_storage_submission(
    actor_user_id,
    target_branch_id,
    equipment,
    readings
  );
  return public.get_cold_storage_current_state(actor_user_id, target_branch_id);
end;
$$;

create or replace function public.submit_cold_storage_slot(
  actor_user_id uuid,
  target_branch_id uuid,
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
  submission public.cold_storage_submissions%rowtype;
  prior record;
  submitted_at_value timestamptz;
  snapshot_equipment jsonb;
begin
  if pg_catalog.length(request_hash) <> 64 then
    raise exception 'invalid cold storage slot submit' using errcode = '22023';
  end if;

  insert into public.cold_storage_submission_idempotency(
    actor_user_id,
    slot,
    idempotency_key,
    request_hash
  ) values (
    actor_user_id,
    slot,
    idempotency_key,
    request_hash
  )
  on conflict do nothing;

  select * into strict prior
  from public.cold_storage_submission_idempotency existing
  where existing.actor_user_id = submit_cold_storage_slot.actor_user_id
    and existing.slot = submit_cold_storage_slot.slot
    and existing.idempotency_key = submit_cold_storage_slot.idempotency_key
  for update;

  if prior.request_hash <> request_hash then
    raise exception 'idempotency conflict' using errcode = '23505';
  end if;
  if prior.submission_id is not null then
    return private.cold_storage_current_result(
      actor_user_id,
      target_branch_id,
      prior.submission_id
    );
  end if;

  submission := private.upsert_cold_storage_submission(
    actor_user_id,
    target_branch_id,
    equipment,
    readings
  );
  snapshot_equipment := private.cold_storage_snapshot_equipment(submission.id);
  perform private.validate_cold_storage_slot_submit(slot, snapshot_equipment, readings);

  select * into strict submission
  from public.cold_storage_submissions existing
  where existing.id = submission.id
  for update;

  if exists(
    select 1
    from public.cold_storage_readings reading
    where reading.submission_id = submission.id
      and reading.slot = submit_cold_storage_slot.slot
      and reading.submitted_at is not null
  ) then
    raise exception 'cold storage slot already submitted' using errcode = '23505';
  end if;

  submitted_at_value := pg_catalog.now();
  update public.cold_storage_readings reading
  set submitted_at = submitted_at_value,
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
  join public.cold_storage_equipment snapshot
    on snapshot.submission_id = submission.id
   and snapshot.equipment_id = pg_catalog.btrim(entry.row_value ->> 'equipment_id')
   and snapshot.active
  where reading.submission_id = submission.id
    and reading.equipment_id = snapshot.equipment_id
    and reading.slot = submit_cold_storage_slot.slot;

  insert into public.cold_storage_issues(
    submission_id,
    equipment_id,
    slot,
    temperature_c,
    corrective_action
  )
  select submission.id,
    reading.equipment_id,
    reading.slot,
    reading.temperature_c,
    reading.corrective_action
  from public.cold_storage_readings reading
  join public.cold_storage_equipment snapshot
    on snapshot.submission_id = reading.submission_id
   and snapshot.equipment_id = reading.equipment_id
  where reading.submission_id = submission.id
    and reading.slot = submit_cold_storage_slot.slot
    and snapshot.active
    and reading.temperature_c >= 5;

  if not exists(
    select 1
    from public.cold_storage_equipment snapshot
    cross join (values ('12:00'), ('20:00'), ('02:00')) expected(slot)
    where snapshot.submission_id = submission.id
      and snapshot.active
      and not exists (
        select 1
        from public.cold_storage_readings reading
        where reading.submission_id = snapshot.submission_id
          and reading.equipment_id = snapshot.equipment_id
          and reading.slot = expected.slot
          and reading.submitted_at is not null
      )
  ) then
    update public.cold_storage_submissions
    set state = 'submitted'
    where id = submission.id;
  end if;

  update public.cold_storage_submission_idempotency replay
  set submission_id = submission.id
  where replay.actor_user_id = submit_cold_storage_slot.actor_user_id
    and replay.slot = submit_cold_storage_slot.slot
    and replay.idempotency_key = submit_cold_storage_slot.idempotency_key;

  return private.cold_storage_current_result(actor_user_id, target_branch_id, submission.id);
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage submit denied' using errcode = '42501';
end;
$$;

revoke all on function public.get_cold_storage_current_state(uuid, uuid),
  public.save_cold_storage_draft(uuid, uuid, jsonb, jsonb),
  public.submit_cold_storage_slot(uuid, uuid, text, uuid, text, jsonb, jsonb)
from public, anon, authenticated;

grant execute on function public.get_cold_storage_current_state(uuid, uuid),
  public.save_cold_storage_draft(uuid, uuid, jsonb, jsonb),
  public.submit_cold_storage_slot(uuid, uuid, text, uuid, text, jsonb, jsonb)
to service_role;
