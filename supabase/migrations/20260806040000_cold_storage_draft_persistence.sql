-- Phase 1 Refrigerator & Freezer persistence: draft/current-state only.
-- JSONB is accepted only at the RPC boundary and normalized after validation.

create table public.cold_storage_submissions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  supervisor_team_id uuid not null,
  business_date date not null,
  state text not null default 'draft' check (state in ('draft','submitted')),
  branch_name_snapshot text not null,
  supervisor_name_snapshot text not null,
  team_name_snapshot text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id, supervisor_team_id, business_date),
  constraint cold_storage_submissions_branch_scope_fkey
    foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint cold_storage_submissions_team_scope_fkey
    foreign key(supervisor_team_id, branch_id, organization_id)
    references public.branch_supervisor_teams(id, branch_id, organization_id) on delete restrict,
  constraint cold_storage_submissions_snapshots_check check (
    branch_name_snapshot = btrim(branch_name_snapshot) and length(branch_name_snapshot) > 0
    and supervisor_name_snapshot = btrim(supervisor_name_snapshot) and length(supervisor_name_snapshot) > 0
    and team_name_snapshot = btrim(team_name_snapshot) and length(team_name_snapshot) > 0
  )
);
create index cold_storage_submissions_team_date_idx
  on public.cold_storage_submissions(supervisor_team_id, business_date desc);
create index cold_storage_submissions_branch_date_idx
  on public.cold_storage_submissions(branch_id, business_date desc);

create table public.cold_storage_equipment (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.cold_storage_submissions(id) on delete cascade,
  equipment_id text not null,
  equipment_name text not null,
  equipment_type text not null check (equipment_type in ('refrigerator','freezer')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(submission_id, equipment_id),
  constraint cold_storage_equipment_identity_check check (
    equipment_id = btrim(equipment_id) and length(equipment_id) between 1 and 80
    and equipment_name = btrim(equipment_name) and length(equipment_name) between 1 and 120
  )
);
create index cold_storage_equipment_submission_idx
  on public.cold_storage_equipment(submission_id, equipment_id);

create table public.cold_storage_readings (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.cold_storage_submissions(id) on delete cascade,
  equipment_id text not null,
  slot text not null check (slot in ('12:00','4:00','8:00')),
  temperature_c numeric,
  status text not null default 'pending' check (status in ('pending','pass','fail')),
  corrective_action text not null default '',
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(submission_id, equipment_id, slot),
  constraint cold_storage_readings_equipment_fkey
    foreign key(submission_id, equipment_id)
    references public.cold_storage_equipment(submission_id, equipment_id) on delete cascade,
  constraint cold_storage_readings_corrective_action_check check (length(corrective_action) <= 2000)
);
create index cold_storage_readings_submission_idx
  on public.cold_storage_readings(submission_id, equipment_id, slot);

create trigger cold_storage_submissions_set_updated_at
before update on public.cold_storage_submissions
for each row execute function private.set_updated_at();
create trigger cold_storage_equipment_set_updated_at
before update on public.cold_storage_equipment
for each row execute function private.set_updated_at();
create trigger cold_storage_readings_set_updated_at
before update on public.cold_storage_readings
for each row execute function private.set_updated_at();

create function private.cold_storage_numeric_field(row_value jsonb, field_name text)
returns numeric language plpgsql immutable security definer set search_path = '' as $$
declare raw_value jsonb; raw_text text;
begin
  raw_value := row_value -> field_name;
  if raw_value is null or pg_catalog.jsonb_typeof(raw_value) = 'null' then
    return null;
  end if;
  if pg_catalog.jsonb_typeof(raw_value) = 'number' then
    return (raw_value #>> '{}')::numeric;
  end if;
  if pg_catalog.jsonb_typeof(raw_value) = 'string' then
    raw_text := pg_catalog.btrim(raw_value #>> '{}');
    if raw_text = '' then
      return null;
    end if;
    return raw_text::numeric;
  end if;
  raise exception 'invalid cold storage numeric field' using errcode = '22023';
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid cold storage numeric field' using errcode = '22023';
end $$;
revoke all on function private.cold_storage_numeric_field(jsonb,text) from public, anon, authenticated;

create function private.validate_cold_storage_equipment(equipment jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb;
begin
  if pg_catalog.jsonb_typeof(equipment) <> 'array' or pg_catalog.jsonb_array_length(equipment) > 100 then
    raise exception 'invalid cold storage equipment' using errcode = '22023';
  end if;
  if (
    select count(*) <> count(distinct value ->> 'equipment_id')
    from pg_catalog.jsonb_array_elements(equipment)
  ) then
    raise exception 'duplicate cold storage equipment' using errcode = '22023';
  end if;
  for row_value in select value from pg_catalog.jsonb_array_elements(equipment) loop
    if not (
      row_value ? 'equipment_id'
      and row_value ? 'equipment_name'
      and row_value ? 'equipment_type'
    )
    or pg_catalog.jsonb_typeof(row_value -> 'equipment_id') <> 'string'
    or pg_catalog.length(pg_catalog.btrim(row_value ->> 'equipment_id')) not between 1 and 80
    or pg_catalog.jsonb_typeof(row_value -> 'equipment_name') <> 'string'
    or pg_catalog.length(pg_catalog.btrim(row_value ->> 'equipment_name')) not between 1 and 120
    or row_value ->> 'equipment_type' not in ('refrigerator','freezer')
    or (row_value ? 'active' and pg_catalog.jsonb_typeof(row_value -> 'active') <> 'boolean')
    then
      raise exception 'invalid cold storage equipment row' using errcode = '22023';
    end if;
  end loop;
end $$;
revoke all on function private.validate_cold_storage_equipment(jsonb) from public, anon, authenticated;

create function private.validate_cold_storage_readings(equipment jsonb, readings jsonb)
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
    or row_value ->> 'slot' not in ('12:00','4:00','8:00')
    or row_value ->> 'status' not in ('pending','pass','fail')
    or pg_catalog.length(coalesce(row_value ->> 'corrective_action', '')) > 2000
    then
      raise exception 'invalid cold storage reading row' using errcode = '22023';
    end if;
    perform private.cold_storage_numeric_field(row_value, 'temperature_c');
  end loop;
end $$;
revoke all on function private.validate_cold_storage_readings(jsonb,jsonb) from public, anon, authenticated;

create function public.get_cold_storage_current_state(actor_user_id uuid, target_branch_id uuid)
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
      ) order by r.equipment_id, case r.slot when '12:00' then 1 when '4:00' then 2 else 3 end)
      from public.cold_storage_readings r
      where r.submission_id = submission.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage state denied' using errcode = '42501';
end $$;

create function public.save_cold_storage_draft(actor_user_id uuid, target_branch_id uuid, equipment jsonb, readings jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare c record; submission public.cold_storage_submissions%rowtype;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  perform private.validate_cold_storage_equipment(equipment);
  perform private.validate_cold_storage_readings(equipment, readings);

  insert into public.cold_storage_submissions(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state,
    branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot
  ) values (
    c.organization_id, c.branch_id, actor_user_id, c.team_id, c.business_date, 'draft',
    c.branch_name, c.supervisor_name, c.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_team_id, business_date) do update set
    state = 'draft',
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    team_name_snapshot = excluded.team_name_snapshot
  returning * into submission;

  delete from public.cold_storage_readings where submission_id = submission.id;
  delete from public.cold_storage_equipment where submission_id = submission.id;

  insert into public.cold_storage_equipment(
    submission_id, equipment_id, equipment_name, equipment_type, active
  )
  select submission.id,
    pg_catalog.btrim(row_value ->> 'equipment_id'),
    pg_catalog.btrim(row_value ->> 'equipment_name'),
    row_value ->> 'equipment_type',
    coalesce((row_value ->> 'active')::boolean, true)
  from pg_catalog.jsonb_array_elements(equipment) entry(row_value);

  insert into public.cold_storage_readings(
    submission_id, equipment_id, slot, temperature_c, status, corrective_action
  )
  select submission.id,
    pg_catalog.btrim(row_value ->> 'equipment_id'),
    row_value ->> 'slot',
    private.cold_storage_numeric_field(row_value, 'temperature_c'),
    row_value ->> 'status',
    coalesce(row_value ->> 'corrective_action', '')
  from pg_catalog.jsonb_array_elements(readings) entry(row_value);

  return public.get_cold_storage_current_state(actor_user_id, target_branch_id);
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage draft denied' using errcode = '42501';
end $$;

alter table public.cold_storage_submissions enable row level security;
alter table public.cold_storage_equipment enable row level security;
alter table public.cold_storage_readings enable row level security;

revoke all on public.cold_storage_submissions, public.cold_storage_equipment, public.cold_storage_readings
  from anon, authenticated;
revoke all on function public.save_cold_storage_draft(uuid,uuid,jsonb,jsonb),
  public.get_cold_storage_current_state(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.save_cold_storage_draft(uuid,uuid,jsonb,jsonb),
  public.get_cold_storage_current_state(uuid,uuid)
  to service_role;
