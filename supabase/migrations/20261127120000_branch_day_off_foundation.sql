-- Phase 1: Branch Day Off Database Foundation
-- Installs effective-dated weekly day-off schedules, one-day and multi-day
-- branch closures, central 04:00 branch-local day-off helpers, and Internal
-- Admin SECURITY DEFINER RPCs with immutable audit logging.
-- Strictly additive: does not deactivate branches, does not modify existing
-- submissions, and does not alter existing checklist/overview/notification RPCs.

begin;

-- 1. Fail-closed prerequisite assertion: verify account_management_audit_logs_action_check
-- already supports all Branch Day Off and Supervisor Team Onboarding actions without modifying it.
do $$
declare
  v_def text;
  v_required text[] := array[
    'branch_weekly_day_off_configured',
    'branch_closure_created',
    'branch_closure_reopened',
    'branch_closure_cancelled',
    'supervisor_team_onboarding_waiting_selected',
    'supervisor_owned_team_created'
  ];
  v_action text;
begin
  select pg_catalog.pg_get_constraintdef(c.oid)
  into v_def
  from pg_catalog.pg_constraint c
  where c.conrelid = to_regclass('public.account_management_audit_logs')
    and c.conname = 'account_management_audit_logs_action_check';

  if v_def is null then
    raise exception 'missing account_management_audit_logs_action_check prerequisite';
  end if;

  foreach v_action in array v_required loop
    if position('''' || v_action || '''' in v_def) = 0 then
      raise exception 'account_management_audit_logs_action_check missing required action: %', v_action;
    end if;
  end loop;
end;
$$;

-- 2. Weekday array validator (0 = Sunday .. 6 = Saturday, matching extract(dow from date), strictly sorted & unique)
create or replace function private.branch_day_off_days_of_week_are_valid(candidate smallint[])
returns boolean
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  len integer;
  idx integer;
  prev smallint := -1;
  curr smallint;
begin
  if candidate is null then
    return false;
  end if;

  if pg_catalog.array_ndims(candidate) is null then
    return candidate = '{}'::smallint[];
  end if;

  if pg_catalog.array_ndims(candidate) <> 1 or pg_catalog.array_lower(candidate, 1) <> 1 then
    return false;
  end if;

  len := pg_catalog.array_length(candidate, 1);
  if len is null or len > 7 then
    return false;
  end if;

  for idx in 1..len loop
    curr := candidate[idx];
    if curr is null or curr < 0 or curr > 6 or curr <= prev then
      return false;
    end if;
    prev := curr;
  end loop;

  return true;
end;
$$;

revoke all on function private.branch_day_off_days_of_week_are_valid(smallint[]) from public, anon, authenticated, service_role;

-- 3. Effective-dated weekly day-off schedules table
create table public.branch_weekly_day_off_schedules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  days_of_week smallint[] not null default '{}'::smallint[],
  effective_from_business_date date not null,
  effective_to_business_date date,
  reason text,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  updated_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  updated_at timestamptz not null default pg_catalog.statement_timestamp(),
  constraint branch_weekly_day_off_schedules_branch_scope_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint branch_weekly_day_off_schedules_period_check
    check (effective_to_business_date is null or effective_to_business_date > effective_from_business_date),
  constraint branch_weekly_day_off_schedules_days_check
    check (private.branch_day_off_days_of_week_are_valid(days_of_week)),
  constraint branch_weekly_day_off_schedules_reason_check
    check (reason is null or (reason = pg_catalog.btrim(reason) and pg_catalog.length(reason) between 1 and 240)),
  unique (branch_id, effective_from_business_date)
);

create unique index branch_weekly_day_off_schedules_open_key
  on public.branch_weekly_day_off_schedules(branch_id)
  where effective_to_business_date is null;

create index branch_weekly_day_off_schedules_lookup_idx
  on public.branch_weekly_day_off_schedules(branch_id, effective_from_business_date desc, effective_to_business_date);

create index branch_weekly_day_off_schedules_org_idx
  on public.branch_weekly_day_off_schedules(organization_id, branch_id);

-- 4. One-day and multi-day branch closures table
create table public.branch_closures (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  start_business_date date not null,
  end_business_date date not null,
  reason text,
  status text not null default 'active',
  reopened_early_at timestamptz,
  reopened_by_user_id uuid references auth.users(id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by_user_id uuid references auth.users(id) on delete restrict,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  updated_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  updated_at timestamptz not null default pg_catalog.statement_timestamp(),
  constraint branch_closures_branch_scope_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint branch_closures_period_check
    check (end_business_date >= start_business_date),
  constraint branch_closures_status_check
    check (status in ('active', 'cancelled')),
  constraint branch_closures_reason_check
    check (reason is null or (reason = pg_catalog.btrim(reason) and pg_catalog.length(reason) between 1 and 240)),
  constraint branch_closures_cancel_metadata_check
    check (
      (status = 'active' and cancelled_at is null and cancelled_by_user_id is null)
      or (status = 'cancelled' and cancelled_at is not null and cancelled_by_user_id is not null)
    ),
  constraint branch_closures_reopen_metadata_check
    check (
      (reopened_early_at is null and reopened_by_user_id is null)
      or (reopened_early_at is not null and reopened_by_user_id is not null)
    )
);

create index branch_closures_active_lookup_idx
  on public.branch_closures(branch_id, start_business_date, end_business_date)
  where status = 'active';

create index branch_closures_org_branch_idx
  on public.branch_closures(organization_id, branch_id, start_business_date desc);

-- 5. Overlap guards for weekly schedules and active closures
create or replace function private.guard_branch_weekly_day_off_schedule_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  conflict_found boolean;
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('branch-day-off:weekly:' || new.branch_id::text, 0)
  );

  select exists (
    select 1
    from public.branch_weekly_day_off_schedules candidate
    where candidate.branch_id = new.branch_id
      and candidate.id <> new.id
      and candidate.effective_from_business_date < coalesce(new.effective_to_business_date, 'infinity'::date)
      and new.effective_from_business_date < coalesce(candidate.effective_to_business_date, 'infinity'::date)
  ) into conflict_found;

  if conflict_found then
    raise exception 'branch weekly day off schedules overlap' using errcode = '23505';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_branch_weekly_day_off_schedule_overlap() from public, anon, authenticated, service_role;

create trigger branch_weekly_day_off_schedules_no_overlap
  before insert or update on public.branch_weekly_day_off_schedules
  for each row execute function private.guard_branch_weekly_day_off_schedule_overlap();

create or replace function private.guard_branch_closure_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  conflict_found boolean;
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('branch-day-off:closure:' || new.branch_id::text, 0)
  );

  if new.status = 'active' then
    select exists (
      select 1
      from public.branch_closures candidate
      where candidate.branch_id = new.branch_id
        and candidate.id <> new.id
        and candidate.status = 'active'
        and candidate.start_business_date <= new.end_business_date
        and new.start_business_date <= candidate.end_business_date
    ) into conflict_found;

    if conflict_found then
      raise exception 'active branch closures overlap' using errcode = '23505';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.guard_branch_closure_overlap() from public, anon, authenticated, service_role;

create trigger branch_closures_no_active_overlap
  before insert or update on public.branch_closures
  for each row execute function private.guard_branch_closure_overlap();

-- 6. Central branch day-off evaluation helpers (preserving 04:00 branch-local business date)
create or replace function private.is_branch_day_off(
  target_branch_id uuid,
  target_business_date date
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    case
      when target_branch_id is null or target_business_date is null then false
      else exists (
        select 1
        from public.branch_closures closure
        where closure.branch_id = target_branch_id
          and closure.status = 'active'
          and target_business_date between closure.start_business_date and closure.end_business_date
      )
      or exists (
        select 1
        from public.branch_weekly_day_off_schedules schedule
        where schedule.branch_id = target_branch_id
          and schedule.effective_from_business_date <= target_business_date
          and (schedule.effective_to_business_date is null or schedule.effective_to_business_date > target_business_date)
          and extract(dow from target_business_date)::smallint = any(schedule.days_of_week)
      )
    end
$$;

revoke all on function private.is_branch_day_off(uuid, date) from public, anon, authenticated;
grant execute on function private.is_branch_day_off(uuid, date) to service_role;

create or replace function private.is_branch_day_off_at(
  target_branch_id uuid,
  as_of timestamptz default pg_catalog.statement_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select private.is_branch_day_off(
        branch.id,
        private.phase4a_business_date_at(branch.timezone, coalesce(as_of, pg_catalog.statement_timestamp()))
      )
      from public.branches branch
      where branch.id = target_branch_id
    ),
    false
  )
$$;

revoke all on function private.is_branch_day_off_at(uuid, timestamptz) from public, anon, authenticated;
grant execute on function private.is_branch_day_off_at(uuid, timestamptz) to service_role;

create or replace function private.branch_day_off_reason(
  target_branch_id uuid,
  target_business_date date
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select
    case
      when target_branch_id is null or target_business_date is null then null
      when exists (
        select 1
        from public.branch_closures closure
        where closure.branch_id = target_branch_id
          and closure.status = 'active'
          and target_business_date between closure.start_business_date and closure.end_business_date
      ) then (
        select closure.reason
        from public.branch_closures closure
        where closure.branch_id = target_branch_id
          and closure.status = 'active'
          and target_business_date between closure.start_business_date and closure.end_business_date
        order by closure.start_business_date desc, closure.created_at desc, closure.id desc
        limit 1
      )
      when exists (
        select 1
        from public.branch_weekly_day_off_schedules schedule
        where schedule.branch_id = target_branch_id
          and schedule.effective_from_business_date <= target_business_date
          and (schedule.effective_to_business_date is null or schedule.effective_to_business_date > target_business_date)
          and extract(dow from target_business_date)::smallint = any(schedule.days_of_week)
      ) then (
        select schedule.reason
        from public.branch_weekly_day_off_schedules schedule
        where schedule.branch_id = target_branch_id
          and schedule.effective_from_business_date <= target_business_date
          and (schedule.effective_to_business_date is null or schedule.effective_to_business_date > target_business_date)
          and extract(dow from target_business_date)::smallint = any(schedule.days_of_week)
        order by schedule.effective_from_business_date desc, schedule.id desc
        limit 1
      )
      else null
    end
$$;

revoke all on function private.branch_day_off_reason(uuid, date) from public, anon, authenticated;
grant execute on function private.branch_day_off_reason(uuid, date) to service_role;

-- 7. Internal Admin SECURITY DEFINER RPCs
create or replace function public.set_internal_admin_branch_weekly_day_off(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid,
  p_days_of_week smallint[],
  p_effective_from_business_date date default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch public.branches%rowtype;
  v_open public.branch_weekly_day_off_schedules%rowtype;
  v_saved public.branch_weekly_day_off_schedules%rowtype;
  v_normalized_days smallint[];
  v_normalized_reason text;
  v_current_business_date date;
  v_effective_from date;
  v_now timestamptz := pg_catalog.statement_timestamp();
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if p_organization_id is null or p_branch_id is null then
    raise exception 'invalid branch weekly day off request' using errcode = '22023';
  end if;

  select branch.*
  into v_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
    and organization.active;

  if v_branch.id is null then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  if p_days_of_week is null then
    raise exception 'invalid weekly day off days_of_week' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(p_days_of_week) as d(day_num)
    where d.day_num is null or d.day_num < 0 or d.day_num > 6
  ) then
    raise exception 'invalid weekly day off days_of_week' using errcode = '22023';
  end if;

  select coalesce(pg_catalog.array_agg(distinct d.day_num order by d.day_num), '{}'::smallint[])
  into v_normalized_days
  from pg_catalog.unnest(p_days_of_week) as d(day_num);

  if coalesce(pg_catalog.array_length(p_days_of_week, 1), 0)
     <> coalesce(pg_catalog.array_length(v_normalized_days, 1), 0)
  then
    raise exception 'duplicate weekday in days_of_week' using errcode = '22023';
  end if;

  v_normalized_reason := nullif(pg_catalog.btrim(coalesce(p_reason, '')), '');
  if v_normalized_reason is not null and pg_catalog.length(v_normalized_reason) > 240 then
    raise exception 'weekly day off reason exceeds maximum length' using errcode = '22023';
  end if;

  v_current_business_date := private.phase4a_business_date_at(v_branch.timezone, v_now);
  v_effective_from := coalesce(p_effective_from_business_date, v_current_business_date);

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('branch-day-off:weekly:' || v_branch.id::text, 0)
  );

  select schedule.*
  into v_open
  from public.branch_weekly_day_off_schedules schedule
  where schedule.branch_id = v_branch.id
    and schedule.effective_to_business_date is null
  for update;

  if v_open.id is not null and v_effective_from < v_open.effective_from_business_date then
    raise exception 'weekly day off schedule cannot move backward' using errcode = '22023';
  elsif v_open.id is not null and v_open.effective_from_business_date = v_effective_from then
    update public.branch_weekly_day_off_schedules schedule
    set days_of_week = v_normalized_days,
        reason = v_normalized_reason,
        updated_by_user_id = p_actor_user_id,
        updated_at = v_now
    where schedule.id = v_open.id
    returning * into v_saved;
  else
    if v_open.id is not null then
      update public.branch_weekly_day_off_schedules schedule
      set effective_to_business_date = v_effective_from,
          updated_by_user_id = p_actor_user_id,
          updated_at = v_now
      where schedule.id = v_open.id;
    end if;

    insert into public.branch_weekly_day_off_schedules (
      organization_id,
      branch_id,
      days_of_week,
      effective_from_business_date,
      effective_to_business_date,
      reason,
      created_by_user_id,
      updated_by_user_id,
      created_at,
      updated_at
    )
    values (
      v_branch.organization_id,
      v_branch.id,
      v_normalized_days,
      v_effective_from,
      null,
      v_normalized_reason,
      p_actor_user_id,
      p_actor_user_id,
      v_now,
      v_now
    )
    returning * into v_saved;
  end if;

  insert into public.account_management_audit_logs (
    organization_id,
    actor_user_id,
    branch_id,
    action,
    details
  )
  values (
    v_branch.organization_id,
    p_actor_user_id,
    v_branch.id,
    'branch_weekly_day_off_configured',
    pg_catalog.jsonb_build_object(
      'schedule_id', v_saved.id,
      'days_of_week', pg_catalog.to_jsonb(v_saved.days_of_week),
      'effective_from_business_date', v_saved.effective_from_business_date,
      'previous_schedule_id', v_open.id,
      'reason', v_saved.reason
    )
  );

  return pg_catalog.jsonb_build_object(
    'id', v_saved.id,
    'organization_id', v_saved.organization_id,
    'branch_id', v_saved.branch_id,
    'days_of_week', pg_catalog.to_jsonb(v_saved.days_of_week),
    'effective_from_business_date', v_saved.effective_from_business_date,
    'effective_to_business_date', v_saved.effective_to_business_date,
    'reason', v_saved.reason,
    'updated_at', v_saved.updated_at
  );
end;
$$;

create or replace function public.create_internal_admin_branch_closure(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid,
  p_start_business_date date,
  p_end_business_date date,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch public.branches%rowtype;
  v_created public.branch_closures%rowtype;
  v_normalized_reason text;
  v_now timestamptz := pg_catalog.statement_timestamp();
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if p_organization_id is null
     or p_branch_id is null
     or p_start_business_date is null
     or p_end_business_date is null
     or p_end_business_date < p_start_business_date
  then
    raise exception 'invalid branch closure date range' using errcode = '22023';
  end if;

  select branch.*
  into v_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
    and organization.active;

  if v_branch.id is null then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  v_normalized_reason := nullif(pg_catalog.btrim(coalesce(p_reason, '')), '');
  if v_normalized_reason is not null and pg_catalog.length(v_normalized_reason) > 240 then
    raise exception 'branch closure reason exceeds maximum length' using errcode = '22023';
  end if;

  insert into public.branch_closures (
    organization_id,
    branch_id,
    start_business_date,
    end_business_date,
    reason,
    status,
    created_by_user_id,
    updated_by_user_id,
    created_at,
    updated_at
  )
  values (
    v_branch.organization_id,
    v_branch.id,
    p_start_business_date,
    p_end_business_date,
    v_normalized_reason,
    'active',
    p_actor_user_id,
    p_actor_user_id,
    v_now,
    v_now
  )
  returning * into v_created;

  insert into public.account_management_audit_logs (
    organization_id,
    actor_user_id,
    branch_id,
    action,
    details
  )
  values (
    v_branch.organization_id,
    p_actor_user_id,
    v_branch.id,
    'branch_closure_created',
    pg_catalog.jsonb_build_object(
      'closure_id', v_created.id,
      'start_business_date', v_created.start_business_date,
      'end_business_date', v_created.end_business_date,
      'reason', v_created.reason,
      'status', v_created.status
    )
  );

  return pg_catalog.jsonb_build_object(
    'id', v_created.id,
    'organization_id', v_created.organization_id,
    'branch_id', v_created.branch_id,
    'start_business_date', v_created.start_business_date,
    'end_business_date', v_created.end_business_date,
    'reason', v_created.reason,
    'status', v_created.status,
    'created_at', v_created.created_at,
    'updated_at', v_created.updated_at
  );
end;
$$;

create or replace function public.reopen_internal_admin_branch_closure(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid,
  p_closure_id uuid,
  p_reopen_from_business_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch public.branches%rowtype;
  v_closure public.branch_closures%rowtype;
  v_updated public.branch_closures%rowtype;
  v_reopen_from date;
  v_previous_end date;
  v_audit_action text;
  v_now timestamptz := pg_catalog.statement_timestamp();
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if p_organization_id is null or p_branch_id is null or p_closure_id is null then
    raise exception 'invalid branch closure reopen request' using errcode = '22023';
  end if;

  select branch.*
  into v_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
    and organization.active;

  if v_branch.id is null then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('branch-day-off:closure:' || v_branch.id::text, 0)
  );

  select closure.*
  into v_closure
  from public.branch_closures closure
  where closure.id = p_closure_id
    and closure.branch_id = v_branch.id
    and closure.organization_id = v_branch.organization_id
  for update;

  if v_closure.id is null then
    raise exception 'branch closure not found' using errcode = 'P0002';
  end if;

  if v_closure.status <> 'active' then
    raise exception 'branch closure is not active' using errcode = '22023';
  end if;

  v_reopen_from := coalesce(
    p_reopen_from_business_date,
    private.phase4a_business_date_at(v_branch.timezone, v_now)
  );

  if v_reopen_from > v_closure.end_business_date then
    raise exception 'reopen date is after closure end date' using errcode = '22023';
  end if;

  v_previous_end := v_closure.end_business_date;

  if v_reopen_from <= v_closure.start_business_date then
    update public.branch_closures closure
    set status = 'cancelled',
        cancelled_at = v_now,
        cancelled_by_user_id = p_actor_user_id,
        updated_by_user_id = p_actor_user_id,
        updated_at = v_now
    where closure.id = v_closure.id
    returning * into v_updated;

    v_audit_action := 'branch_closure_cancelled';
  else
    update public.branch_closures closure
    set end_business_date = v_reopen_from - 1,
        reopened_early_at = v_now,
        reopened_by_user_id = p_actor_user_id,
        updated_by_user_id = p_actor_user_id,
        updated_at = v_now
    where closure.id = v_closure.id
    returning * into v_updated;

    v_audit_action := 'branch_closure_reopened';
  end if;

  insert into public.account_management_audit_logs (
    organization_id,
    actor_user_id,
    branch_id,
    action,
    details
  )
  values (
    v_branch.organization_id,
    p_actor_user_id,
    v_branch.id,
    v_audit_action,
    pg_catalog.jsonb_build_object(
      'closure_id', v_updated.id,
      'start_business_date', v_updated.start_business_date,
      'previous_end_business_date', v_previous_end,
      'end_business_date', v_updated.end_business_date,
      'reopen_from_business_date', v_reopen_from,
      'status', v_updated.status
    )
  );

  return pg_catalog.jsonb_build_object(
    'id', v_updated.id,
    'organization_id', v_updated.organization_id,
    'branch_id', v_updated.branch_id,
    'start_business_date', v_updated.start_business_date,
    'end_business_date', v_updated.end_business_date,
    'reason', v_updated.reason,
    'status', v_updated.status,
    'reopened_early_at', v_updated.reopened_early_at,
    'cancelled_at', v_updated.cancelled_at,
    'updated_at', v_updated.updated_at
  );
end;
$$;

create or replace function public.get_internal_admin_branch_day_off_config(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_branch public.branches%rowtype;
  v_current_business_date date;
  v_now timestamptz := pg_catalog.statement_timestamp();
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if p_organization_id is null or p_branch_id is null then
    raise exception 'invalid branch day off config request' using errcode = '22023';
  end if;

  select branch.*
  into v_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
    and organization.active;

  if v_branch.id is null then
    raise exception 'branch not found' using errcode = 'P0002';
  end if;

  v_current_business_date := private.phase4a_business_date_at(v_branch.timezone, v_now);

  return pg_catalog.jsonb_build_object(
    'organization_id', v_branch.organization_id,
    'branch_id', v_branch.id,
    'timezone', v_branch.timezone,
    'current_business_date', v_current_business_date,
    'is_day_off_today', private.is_branch_day_off(v_branch.id, v_current_business_date),
    'day_off_reason_today', private.branch_day_off_reason(v_branch.id, v_current_business_date),
    'current_weekly_schedule', (
      select pg_catalog.jsonb_build_object(
        'id', schedule.id,
        'days_of_week', pg_catalog.to_jsonb(schedule.days_of_week),
        'effective_from_business_date', schedule.effective_from_business_date,
        'effective_to_business_date', schedule.effective_to_business_date,
        'reason', schedule.reason,
        'updated_at', schedule.updated_at
      )
      from public.branch_weekly_day_off_schedules schedule
      where schedule.branch_id = v_branch.id
        and schedule.effective_to_business_date is null
      limit 1
    ),
    'weekly_schedule_history', coalesce(
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'id', schedule.id,
            'days_of_week', pg_catalog.to_jsonb(schedule.days_of_week),
            'effective_from_business_date', schedule.effective_from_business_date,
            'effective_to_business_date', schedule.effective_to_business_date,
            'reason', schedule.reason,
            'updated_at', schedule.updated_at
          )
          order by schedule.effective_from_business_date desc, schedule.id desc
        )
        from public.branch_weekly_day_off_schedules schedule
        where schedule.branch_id = v_branch.id
      ),
      '[]'::jsonb
    ),
    'closures', coalesce(
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'id', closure.id,
            'start_business_date', closure.start_business_date,
            'end_business_date', closure.end_business_date,
            'reason', closure.reason,
            'status', closure.status,
            'reopened_early_at', closure.reopened_early_at,
            'cancelled_at', closure.cancelled_at,
            'created_at', closure.created_at,
            'updated_at', closure.updated_at
          )
          order by closure.start_business_date desc, closure.created_at desc, closure.id desc
        )
        from public.branch_closures closure
        where closure.branch_id = v_branch.id
      ),
      '[]'::jsonb
    )
  );
end;
$$;

-- 8. Row Level Security & Privilege Hardening
alter table public.branch_weekly_day_off_schedules enable row level security;
alter table public.branch_closures enable row level security;

revoke all on table public.branch_weekly_day_off_schedules from public, anon, authenticated, service_role;
revoke all on table public.branch_closures from public, anon, authenticated, service_role;

revoke all on function public.set_internal_admin_branch_weekly_day_off(uuid, uuid, uuid, smallint[], date, text)
  from public, anon, authenticated;
revoke all on function public.create_internal_admin_branch_closure(uuid, uuid, uuid, date, date, text)
  from public, anon, authenticated;
revoke all on function public.reopen_internal_admin_branch_closure(uuid, uuid, uuid, uuid, date)
  from public, anon, authenticated;
revoke all on function public.get_internal_admin_branch_day_off_config(uuid, uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.set_internal_admin_branch_weekly_day_off(uuid, uuid, uuid, smallint[], date, text)
  to service_role;
grant execute on function public.create_internal_admin_branch_closure(uuid, uuid, uuid, date, date, text)
  to service_role;
grant execute on function public.reopen_internal_admin_branch_closure(uuid, uuid, uuid, uuid, date)
  to service_role;
grant execute on function public.get_internal_admin_branch_day_off_config(uuid, uuid, uuid)
  to service_role;

commit;
