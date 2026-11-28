-- Custom Cold Storage Schedule per Branch — Phase 2A: Additive Configuration & History Infrastructure
-- Preserves existing cold_storage_schedule_versions, cold_storage_schedule_slots,
-- branch_cold_storage_schedule_assignments, and all Branch Day Off objects.

begin;

do $$
begin
  if to_regclass('public.cold_storage_schedule_versions') is null
     or to_regclass('public.cold_storage_schedule_slots') is null
     or to_regclass('public.branch_cold_storage_schedule_assignments') is null
     or to_regprocedure('private.is_internal_admin(uuid)') is null
     or to_regprocedure('private.phase4a_business_date(text)') is null
     or to_regprocedure('private.cold_storage_schedule_slots_json(uuid)') is null then
    raise exception 'Cold Storage schedule prerequisite objects are missing.' using errcode = 'P0001';
  end if;
end;
$$;

create table if not exists public.cold_storage_schedule_assignment_audits (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  schedule_version_id uuid not null references public.cold_storage_schedule_versions(id) on delete restrict,
  effective_from_business_date date not null,
  actor_user_id uuid references public.profiles(id) on delete set null,
  action text not null check (action in ('created', 'closed', 'cancelled')),
  created_at timestamptz not null default now()
);

alter table public.cold_storage_schedule_assignment_audits enable row level security;
revoke all on table public.cold_storage_schedule_assignment_audits from public, anon, authenticated;

create or replace function public.get_internal_admin_branch_cold_storage_schedule_v2(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_branch record;
  v_business_date date;
  v_current record;
  v_pending record;
  v_history jsonb;
  v_available jsonb;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'schedule access denied' using errcode = '42501';
  end if;

  select b.id, b.organization_id, b.timezone, b.active
  into v_branch
  from public.branches b
  where b.id = target_branch_id
    and b.organization_id = target_organization_id;

  if not found then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  v_business_date := private.phase4a_business_date(v_branch.timezone);

  select a.*, v.code, v.name
  into v_current
  from public.branch_cold_storage_schedule_assignments a
  join public.cold_storage_schedule_versions v on v.id = a.schedule_version_id
  where a.branch_id = target_branch_id
    and a.cancelled_at is null
    and a.effective_from_business_date <= v_business_date
    and (a.effective_to_business_date is null or v_business_date < a.effective_to_business_date)
  order by a.effective_from_business_date desc
  limit 1;

  select a.*, v.code, v.name
  into v_pending
  from public.branch_cold_storage_schedule_assignments a
  join public.cold_storage_schedule_versions v on v.id = a.schedule_version_id
  where a.branch_id = target_branch_id
    and a.cancelled_at is null
    and a.effective_from_business_date > v_business_date
  order by a.effective_from_business_date asc
  limit 1;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'assignment_id', a.id,
        'schedule_version_id', a.schedule_version_id,
        'schedule_code', v.code,
        'schedule_name', v.name,
        'effective_from_business_date', a.effective_from_business_date,
        'effective_to_business_date', a.effective_to_business_date,
        'cancelled_at', a.cancelled_at,
        'created_at', a.created_at,
        'slots', private.cold_storage_schedule_slots_json(a.schedule_version_id)
      )
      order by a.effective_from_business_date desc, a.created_at desc
    ),
    '[]'::jsonb
  )
  into v_history
  from public.branch_cold_storage_schedule_assignments a
  join public.cold_storage_schedule_versions v on v.id = a.schedule_version_id
  where a.branch_id = target_branch_id;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'schedule_version_id', v.id,
        'schedule_code', v.code,
        'schedule_name', v.name,
        'slots', private.cold_storage_schedule_slots_json(v.id)
      )
      order by v.code
    ),
    '[]'::jsonb
  )
  into v_available
  from public.cold_storage_schedule_versions v
  where v.active
    and (v.organization_id is null or v.organization_id = target_organization_id);

  return pg_catalog.jsonb_build_object(
    'branch_id', target_branch_id,
    'organization_id', target_organization_id,
    'timezone', v_branch.timezone,
    'business_date', v_business_date,
    'next_valid_business_date', v_business_date + 1,
    'current', case
      when v_current.id is null then null
      else pg_catalog.jsonb_build_object(
        'assignment_id', v_current.id,
        'schedule_version_id', v_current.schedule_version_id,
        'schedule_code', v_current.code,
        'schedule_name', v_current.name,
        'effective_from_business_date', v_current.effective_from_business_date,
        'effective_to_business_date', v_current.effective_to_business_date,
        'slots', private.cold_storage_schedule_slots_json(v_current.schedule_version_id)
      )
    end,
    'pending', case
      when v_pending.id is null then null
      else pg_catalog.jsonb_build_object(
        'assignment_id', v_pending.id,
        'schedule_version_id', v_pending.schedule_version_id,
        'schedule_code', v_pending.code,
        'schedule_name', v_pending.name,
        'effective_from_business_date', v_pending.effective_from_business_date,
        'effective_to_business_date', v_pending.effective_to_business_date,
        'slots', private.cold_storage_schedule_slots_json(v_pending.schedule_version_id)
      )
    end,
    'history', v_history,
    'available', v_available
  );
end;
$$;

revoke all on function public.get_internal_admin_branch_cold_storage_schedule_v2(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.get_internal_admin_branch_cold_storage_schedule_v2(uuid, uuid, uuid) to service_role;

create or replace function public.set_internal_admin_branch_custom_cold_storage_schedule(
  actor_user_id uuid,
  organization_id uuid,
  branch_id uuid,
  slot_times text[],
  effective_from_business_date date,
  schedule_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch record;
  v_business_date date;
  v_raw_count integer;
  v_sorted_slots text[];
  v_clean_name text;
  v_existing_same record;
  v_existing_same_slots text[];
  v_pending record;
  v_prior record;
  v_new_version_id uuid;
  v_new_code text;
  v_new_assignment_id uuid;
  v_idx integer;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'schedule access denied' using errcode = '42501';
  end if;

  if slot_times is null or pg_catalog.array_ndims(slot_times) is distinct from 1 then
    raise exception 'slot_times must be a non-empty 1D array' using errcode = '22023';
  end if;

  v_raw_count := pg_catalog.cardinality(slot_times);
  if v_raw_count < 1 or v_raw_count > 48 then
    raise exception 'slot_times must contain between 1 and 48 check times' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(slot_times) as s(val)
    where val is null or val !~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$'
  ) then
    raise exception 'invalid HH:MM slot_time format' using errcode = '22023';
  end if;

  select pg_catalog.array_agg(
    val
    order by (
      case when val::time < time '04:00' then 1440 else 0 end
      + pg_catalog.date_part('hour', val::time)::integer * 60
      + pg_catalog.date_part('minute', val::time)::integer
    )
  )
  into v_sorted_slots
  from (select distinct val from pg_catalog.unnest(slot_times) as s(val)) dedup;

  if pg_catalog.cardinality(v_sorted_slots) <> v_raw_count then
    raise exception 'duplicate slot_times are not allowed' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(branch_id::text || ':cold-storage-schedule', 0)
  );

  select b.id, b.organization_id, b.timezone, b.active
  into v_branch
  from public.branches b
  where b.id = set_internal_admin_branch_custom_cold_storage_schedule.branch_id
    and b.organization_id = set_internal_admin_branch_custom_cold_storage_schedule.organization_id
    and b.active;

  if not found then
    raise exception 'active branch not found in organization' using errcode = 'P0002';
  end if;

  v_business_date := private.phase4a_business_date(v_branch.timezone);

  if effective_from_business_date is null or effective_from_business_date < v_business_date + 1 then
    raise exception 'effective_from_business_date must be at least the next branch-local business date' using errcode = '22023';
  end if;

  v_clean_name := nullif(pg_catalog.btrim(coalesce(schedule_name, '')), '');
  if v_clean_name is null then
    v_clean_name := 'Custom (' || v_raw_count::text || ' checks)';
  elsif pg_catalog.length(v_clean_name) > 120 then
    raise exception 'schedule_name must be 120 characters or fewer' using errcode = '22023';
  end if;

  -- Idempotency: if a non-cancelled assignment already starts on effective_from_business_date with identical slots & name
  select a.id, a.schedule_version_id, v.name as version_name
  into v_existing_same
  from public.branch_cold_storage_schedule_assignments a
  join public.cold_storage_schedule_versions v on v.id = a.schedule_version_id
  where a.branch_id = set_internal_admin_branch_custom_cold_storage_schedule.branch_id
    and a.cancelled_at is null
    and a.effective_from_business_date = set_internal_admin_branch_custom_cold_storage_schedule.effective_from_business_date
  for update;

  if v_existing_same.id is not null then
    select pg_catalog.array_agg(sl.slot_time order by sl.operational_ordinal)
    into v_existing_same_slots
    from public.cold_storage_schedule_slots sl
    where sl.schedule_version_id = v_existing_same.schedule_version_id;

    if v_existing_same_slots = v_sorted_slots and v_existing_same.version_name = v_clean_name then
      return public.get_internal_admin_branch_cold_storage_schedule_v2(
        actor_user_id,
        set_internal_admin_branch_custom_cold_storage_schedule.organization_id,
        set_internal_admin_branch_custom_cold_storage_schedule.branch_id
      );
    end if;

    raise exception 'a different Cold Storage schedule assignment already starts on this business date' using errcode = '23505';
  end if;

  -- Protect existing future assignments from silent overwrite
  select a.*
  into v_pending
  from public.branch_cold_storage_schedule_assignments a
  where a.branch_id = set_internal_admin_branch_custom_cold_storage_schedule.branch_id
    and a.cancelled_at is null
    and a.effective_from_business_date > v_business_date
  order by a.effective_from_business_date asc
  limit 1
  for update;

  if v_pending.id is not null then
    raise exception 'existing pending future Cold Storage schedule must be preserved' using errcode = '23505';
  end if;

  -- Create immutable schedule version + slots
  v_new_version_id := gen_random_uuid();
  v_new_code := 'CUSTOM_' || pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(v_new_version_id::text, '-', ''), 1, 20));

  insert into public.cold_storage_schedule_versions(id, organization_id, code, name, active)
  values (
    v_new_version_id,
    set_internal_admin_branch_custom_cold_storage_schedule.organization_id,
    v_new_code,
    v_clean_name,
    true
  );

  for v_idx in 1 .. v_raw_count loop
    insert into public.cold_storage_schedule_slots(schedule_version_id, slot_time, operational_ordinal)
    values (v_new_version_id, v_sorted_slots[v_idx], v_idx);
  end loop;

  -- Close current open assignment if one covers effective_from_business_date
  select a.*
  into v_prior
  from public.branch_cold_storage_schedule_assignments a
  where a.branch_id = set_internal_admin_branch_custom_cold_storage_schedule.branch_id
    and a.cancelled_at is null
    and a.effective_from_business_date < set_internal_admin_branch_custom_cold_storage_schedule.effective_from_business_date
    and (a.effective_to_business_date is null or a.effective_to_business_date > set_internal_admin_branch_custom_cold_storage_schedule.effective_from_business_date)
  order by a.effective_from_business_date desc
  limit 1
  for update;

  if v_prior.id is not null then
    update public.branch_cold_storage_schedule_assignments
    set effective_to_business_date = set_internal_admin_branch_custom_cold_storage_schedule.effective_from_business_date
    where id = v_prior.id;

    insert into public.cold_storage_schedule_assignment_audits(
      assignment_id, organization_id, branch_id, schedule_version_id,
      effective_from_business_date, actor_user_id, action
    )
    values (
      v_prior.id, v_prior.organization_id, v_prior.branch_id, v_prior.schedule_version_id,
      v_prior.effective_from_business_date, actor_user_id, 'closed'
    );
  end if;

  insert into public.branch_cold_storage_schedule_assignments(
    organization_id,
    branch_id,
    schedule_version_id,
    effective_from_business_date,
    created_by_user_id
  )
  values (
    set_internal_admin_branch_custom_cold_storage_schedule.organization_id,
    set_internal_admin_branch_custom_cold_storage_schedule.branch_id,
    v_new_version_id,
    set_internal_admin_branch_custom_cold_storage_schedule.effective_from_business_date,
    actor_user_id
  )
  returning id into v_new_assignment_id;

  insert into public.cold_storage_schedule_assignment_audits(
    assignment_id, organization_id, branch_id, schedule_version_id,
    effective_from_business_date, actor_user_id, action
  )
  values (
    v_new_assignment_id,
    set_internal_admin_branch_custom_cold_storage_schedule.organization_id,
    set_internal_admin_branch_custom_cold_storage_schedule.branch_id,
    v_new_version_id,
    set_internal_admin_branch_custom_cold_storage_schedule.effective_from_business_date,
    actor_user_id,
    'created'
  );

  return public.get_internal_admin_branch_cold_storage_schedule_v2(
    actor_user_id,
    set_internal_admin_branch_custom_cold_storage_schedule.organization_id,
    set_internal_admin_branch_custom_cold_storage_schedule.branch_id
  );
end;
$$;

revoke all on function public.set_internal_admin_branch_custom_cold_storage_schedule(uuid, uuid, uuid, text[], date, text) from public, anon, authenticated;
grant execute on function public.set_internal_admin_branch_custom_cold_storage_schedule(uuid, uuid, uuid, text[], date, text) to service_role;

commit;
