-- Phase 2 Refrigerator & Freezer persistence: scheduled slot submit,
-- idempotency, immutable submitted readings, and issues.

create table public.cold_storage_submission_idempotency (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  slot text not null check (slot in ('12:00','4:00','8:00')),
  idempotency_key uuid not null,
  request_hash text not null,
  submission_id uuid references public.cold_storage_submissions(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key(actor_user_id, slot, idempotency_key),
  constraint cold_storage_idempotency_hash_check check (length(request_hash) = 64)
);

create table public.cold_storage_issues (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.cold_storage_submissions(id) on delete cascade,
  equipment_id text not null,
  slot text not null check (slot in ('12:00','4:00','8:00')),
  temperature_c numeric not null,
  corrective_action text not null,
  created_at timestamptz not null default now(),
  constraint cold_storage_issues_corrective_action_check check (
    corrective_action = btrim(corrective_action) and length(corrective_action) between 1 and 2000
  )
);
create index cold_storage_issues_submission_idx on public.cold_storage_issues(submission_id, slot, equipment_id);

create function private.cold_storage_equipment_set_matches(submission uuid, equipment jsonb)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select array_agg(equipment_id order by equipment_id)
    from public.cold_storage_equipment
    where submission_id = submission
  ), array[]::text[]) = coalesce((
    select array_agg(pg_catalog.btrim(value ->> 'equipment_id') order by pg_catalog.btrim(value ->> 'equipment_id'))
    from pg_catalog.jsonb_array_elements(equipment)
  ), array[]::text[]);
$$;
revoke all on function private.cold_storage_equipment_set_matches(uuid,jsonb) from public, anon, authenticated;

create function private.replace_cold_storage_equipment(submission_id uuid, equipment jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.cold_storage_equipment e where e.submission_id = replace_cold_storage_equipment.submission_id;
  insert into public.cold_storage_equipment(
    submission_id, equipment_id, equipment_name, equipment_type, active
  )
  select submission_id,
    pg_catalog.btrim(row_value ->> 'equipment_id'),
    pg_catalog.btrim(row_value ->> 'equipment_name'),
    row_value ->> 'equipment_type',
    coalesce((row_value ->> 'active')::boolean, true)
  from pg_catalog.jsonb_array_elements(equipment) entry(row_value);
end $$;
revoke all on function private.replace_cold_storage_equipment(uuid,jsonb) from public, anon, authenticated;

create function private.replace_cold_storage_unsubmitted_readings(submission_id uuid, readings jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.cold_storage_readings r
  where r.submission_id = replace_cold_storage_unsubmitted_readings.submission_id
    and r.submitted_at is null;

  insert into public.cold_storage_readings(
    submission_id, equipment_id, slot, temperature_c, status, corrective_action
  )
  select submission_id,
    pg_catalog.btrim(row_value ->> 'equipment_id'),
    row_value ->> 'slot',
    private.cold_storage_numeric_field(row_value, 'temperature_c'),
    row_value ->> 'status',
    coalesce(row_value ->> 'corrective_action', '')
  from pg_catalog.jsonb_array_elements(readings) entry(row_value)
  where not exists (
    select 1 from public.cold_storage_readings r
    where r.submission_id = replace_cold_storage_unsubmitted_readings.submission_id
      and r.equipment_id = pg_catalog.btrim(row_value ->> 'equipment_id')
      and r.slot = row_value ->> 'slot'
      and r.submitted_at is not null
  );
end $$;
revoke all on function private.replace_cold_storage_unsubmitted_readings(uuid,jsonb) from public, anon, authenticated;

create function private.upsert_cold_storage_submission(
  actor_user_id uuid,
  target_branch_id uuid,
  equipment jsonb,
  readings jsonb
) returns public.cold_storage_submissions
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare c record; submission public.cold_storage_submissions%rowtype; has_submitted boolean;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  insert into public.cold_storage_submissions(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state,
    branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot
  ) values (
    c.organization_id, c.branch_id, actor_user_id, c.team_id, c.business_date, 'draft',
    c.branch_name, c.supervisor_name, c.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_team_id, business_date) do update set
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    team_name_snapshot = excluded.team_name_snapshot
  returning * into submission;

  select exists(
    select 1 from public.cold_storage_readings r
    where r.submission_id = submission.id and r.submitted_at is not null
  ) into has_submitted;

  if has_submitted then
    if not private.cold_storage_equipment_set_matches(submission.id, equipment) then
      raise exception 'submitted cold storage equipment is immutable' using errcode = '23505';
    end if;
  else
    perform private.replace_cold_storage_equipment(submission.id, equipment);
  end if;

  perform private.replace_cold_storage_unsubmitted_readings(submission.id, readings);
  return submission;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage operation denied' using errcode = '42501';
end $$;
revoke all on function private.upsert_cold_storage_submission(uuid,uuid,jsonb,jsonb) from public, anon, authenticated;

create or replace function public.save_cold_storage_draft(actor_user_id uuid, target_branch_id uuid, equipment jsonb, readings jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.validate_cold_storage_equipment(equipment);
  perform private.validate_cold_storage_readings(equipment, readings);
  perform private.upsert_cold_storage_submission(actor_user_id, target_branch_id, equipment, readings);
  return public.get_cold_storage_current_state(actor_user_id, target_branch_id);
end $$;

create function private.validate_cold_storage_slot_submit(target_slot text, equipment jsonb, readings jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare eq_value jsonb; reading_value jsonb; reading_count integer; temperature numeric; action text; active_count integer := 0;
begin
  if target_slot not in ('12:00','4:00','8:00') then
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

create function private.cold_storage_current_result(actor_user_id uuid, target_branch_id uuid, submission_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select public.get_cold_storage_current_state(actor_user_id, target_branch_id)
    || pg_catalog.jsonb_build_object(
      'submission_id', submission_id,
      'issue_count', (
        select count(*) from public.cold_storage_issues issue
        where issue.submission_id = submission_id
      )
    );
$$;
revoke all on function private.cold_storage_current_result(uuid,uuid,uuid) from public, anon, authenticated;

create function public.submit_cold_storage_slot(
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
    cross join (values ('12:00'), ('4:00'), ('8:00')) expected(slot)
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
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage submit denied' using errcode = '42501';
end $$;

alter table public.cold_storage_submission_idempotency enable row level security;
alter table public.cold_storage_issues enable row level security;

revoke all on public.cold_storage_submission_idempotency, public.cold_storage_issues
  from anon, authenticated;
revoke all on function public.submit_cold_storage_slot(uuid,uuid,text,uuid,text,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.submit_cold_storage_slot(uuid,uuid,text,uuid,text,jsonb,jsonb)
  to service_role;
