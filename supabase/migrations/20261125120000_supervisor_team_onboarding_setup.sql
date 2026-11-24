-- 20261125120000_supervisor_team_onboarding_setup.sql
-- HACCP Supervisor Operational Team Onboarding — Phase 1: Database & Security Hardening
--
-- Implements:
--   1. public.supervisor_team_onboarding_states (persisted per-(supervisor, branch) waiting state)
--   2. public.supervisor_team_bootstrap_idempotency (idempotency ledger for team creation)
--   3. Waiting-state RPCs: get_supervisor_team_onboarding_state, set_supervisor_team_onboarding_waiting
--   4. Team creation hardening: create_supervisor_owned_operational_team_v2 (with idempotency,
--      immutable audit logging, waiting-state cleanup, and revocation-safe replay) while
--      preserving the exact 3-argument public.create_supervisor_owned_operational_team contract.
--   5. Concurrency & auto-cleanup triggers on public.branch_operational_team_supervisors.
--   6. Audit log constraint compatibility with origin/main and Branch Day Off actions.

begin;

-- =============================================================================
-- 1. Audit Log Action Constraint (Compatible with origin/main + Branch Day Off)
-- =============================================================================

alter table public.account_management_audit_logs
  drop constraint if exists account_management_audit_logs_action_check;

alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created','user_disabled','user_enabled','temporary_password_reset','password_changed',
      'branch_created','branch_assignment_added','branch_assignment_removed','branch_role_changed',
      'daily_audit_pin_configured','daily_audit_pin_replaced','daily_audit_access_granted',
      'daily_audit_user_access_granted','daily_audit_user_access_revoked','daily_audit_access_user_created',
      'daily_audit_access_user_revoked','maintenance_access_user_created','maintenance_access_user_deactivated',
      'maintenance_user_created','maintenance_user_deactivated','training_account_created',
      'training_account_updated','training_account_deactivated','training_account_reactivated',
      'training_account_password_reset','branch_shift_created','branch_shift_updated',
      'training_supervisor_granted','training_supervisor_suspended','training_supervisor_reactivated',
      'training_supervisor_revoked','training_supervisor_reassigned',
      'supervisor_team_assigned','supervisor_team_deactivated','supervisor_profile_updated',
      'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
      'operational_staff_assignment_created','operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated','operational_staff_duty_changed',
      'organization_logo_updated','branch_logo_updated','operational_staff_supervisor_training_started',
      'operational_staff_supervisor_training_cancelled','operational_staff_supervisor_training_promoted',
      'purchasing_user_created','purchasing_membership_enabled','purchasing_membership_disabled',
      'supervisor_demoted_to_staff','user_role_transitioned',
      'supervisor_operational_access_restored','supervisor_classification_changed',
      'training_membership_deactivated_for_supervisor_restore',
      'branch_weekly_day_off_configured','branch_closure_created',
      'branch_closure_reopened','branch_closure_cancelled',
      'supervisor_team_onboarding_waiting_selected',
      'supervisor_owned_team_created'
    )
  );

-- =============================================================================
-- 2. Tables, Constraints, RLS & Privileges
-- =============================================================================

create table public.supervisor_team_onboarding_states (
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  onboarding_choice text not null check (onboarding_choice in ('waiting_for_transfer')),
  selected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (supervisor_user_id, branch_id),
  constraint supervisor_team_onboarding_states_branch_scope_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict
);

create index supervisor_team_onboarding_states_branch_idx
  on public.supervisor_team_onboarding_states(organization_id, branch_id, supervisor_user_id);

create trigger supervisor_team_onboarding_states_set_updated_at
  before update on public.supervisor_team_onboarding_states
  for each row execute function private.set_updated_at();

alter table public.supervisor_team_onboarding_states enable row level security;
revoke all on public.supervisor_team_onboarding_states
  from public, anon, authenticated, service_role;

create table public.supervisor_team_bootstrap_idempotency (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  branch_id uuid not null,
  idempotency_key uuid not null,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  operational_team_id uuid not null references public.branch_operational_teams(id) on delete restrict,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  primary key (actor_user_id, branch_id, idempotency_key),
  constraint supervisor_team_bootstrap_idempotency_branch_scope_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict
);

create index supervisor_team_bootstrap_idempotency_team_idx
  on public.supervisor_team_bootstrap_idempotency(operational_team_id);

alter table public.supervisor_team_bootstrap_idempotency enable row level security;
revoke all on public.supervisor_team_bootstrap_idempotency
  from public, anon, authenticated, service_role;

-- =============================================================================
-- 3. Concurrency Lock & Waiting-State Auto-Clear Triggers on Team Assignment
-- =============================================================================

create function private.lock_supervisor_team_onboarding_on_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.active then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(new.branch_id::text, 17)
    );
  end if;
  return new;
end;
$$;

revoke all on function private.lock_supervisor_team_onboarding_on_assignment()
  from public, anon, authenticated, service_role;

create trigger branch_operational_team_supervisors_00_lock_onboarding
  before insert or update on public.branch_operational_team_supervisors
  for each row
  execute function private.lock_supervisor_team_onboarding_on_assignment();

create function private.clear_supervisor_team_onboarding_on_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.active then
    delete from public.supervisor_team_onboarding_states state
    where state.supervisor_user_id = new.supervisor_user_id
      and state.branch_id = new.branch_id;
  end if;
  return new;
end;
$$;

revoke all on function private.clear_supervisor_team_onboarding_on_assignment()
  from public, anon, authenticated, service_role;

create trigger branch_operational_team_supervisors_90_clear_onboarding
  after insert or update on public.branch_operational_team_supervisors
  for each row
  execute function private.clear_supervisor_team_onboarding_on_assignment();

-- =============================================================================
-- 4. Waiting State RPCs
-- =============================================================================

create function public.get_supervisor_team_onboarding_state(
  p_actor_user_id uuid,
  p_branch_ids uuid[]
)
returns table(
  branch_id uuid,
  onboarding_choice text,
  selected_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_branch_id uuid;
begin
  if p_actor_user_id is null
    or p_branch_ids is null
    or pg_catalog.cardinality(p_branch_ids) = 0
    or pg_catalog.cardinality(p_branch_ids) > 50
  then
    raise exception 'invalid onboarding branch scope' using errcode = '22023';
  end if;

  foreach v_branch_id in array p_branch_ids loop
    if v_branch_id is null
      or not private.actor_can_read_operational_branch(p_actor_user_id, v_branch_id)
    then
      raise exception 'supervisor onboarding access denied' using errcode = '42501';
    end if;
  end loop;

  return query
  select
    state.branch_id,
    state.onboarding_choice,
    state.selected_at
  from public.supervisor_team_onboarding_states state
  where state.supervisor_user_id = p_actor_user_id
    and state.branch_id = any(p_branch_ids)
    and not exists (
      select 1
      from public.branch_operational_team_supervisors assignment
      join public.branch_operational_teams team on team.id = assignment.operational_team_id
      where assignment.supervisor_user_id = p_actor_user_id
        and assignment.branch_id = state.branch_id
        and assignment.active
        and team.active
        and assignment.valid_from <= current_date
        and (assignment.valid_to is null or assignment.valid_to >= current_date)
    )
  order by state.branch_id;
end;
$$;

revoke all on function public.get_supervisor_team_onboarding_state(uuid, uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.get_supervisor_team_onboarding_state(uuid, uuid[])
  to service_role;

create function public.set_supervisor_team_onboarding_waiting(
  p_actor_user_id uuid,
  p_branch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  existing_state public.supervisor_team_onboarding_states%rowtype;
  saved_state public.supervisor_team_onboarding_states%rowtype;
begin
  if p_actor_user_id is null or p_branch_id is null then
    raise exception 'invalid onboarding branch scope' using errcode = '22023';
  end if;

  select branch.*
  into target_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = p_branch_id
    and branch.active
    and organization.active
  for update of branch;

  if target_branch.id is null
    or not private.actor_can_read_operational_branch(p_actor_user_id, p_branch_id)
  then
    raise exception 'supervisor onboarding access denied' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_branch_id::text, 17)
  );

  if exists (
    select 1
    from public.branch_operational_team_supervisors assignment
    join public.branch_operational_teams team on team.id = assignment.operational_team_id
    where assignment.supervisor_user_id = p_actor_user_id
      and assignment.branch_id = p_branch_id
      and assignment.active
      and team.active
      and assignment.valid_from <= current_date
      and (assignment.valid_to is null or assignment.valid_to >= current_date)
  ) then
    raise exception 'employee team already assigned' using errcode = '23505';
  end if;

  select state.*
  into existing_state
  from public.supervisor_team_onboarding_states state
  where state.supervisor_user_id = p_actor_user_id
    and state.branch_id = p_branch_id
  for update;

  if existing_state.supervisor_user_id is not null
    and existing_state.onboarding_choice = 'waiting_for_transfer'
  then
    return pg_catalog.jsonb_build_object(
      'branch_id', existing_state.branch_id,
      'onboarding_choice', existing_state.onboarding_choice,
      'selected_at', existing_state.selected_at
    );
  end if;

  insert into public.supervisor_team_onboarding_states(
    organization_id,
    branch_id,
    supervisor_user_id,
    onboarding_choice
  )
  values(
    target_branch.organization_id,
    p_branch_id,
    p_actor_user_id,
    'waiting_for_transfer'
  )
  on conflict (supervisor_user_id, branch_id) do update
    set organization_id = excluded.organization_id,
        onboarding_choice = 'waiting_for_transfer',
        updated_at = now()
  returning * into saved_state;

  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    branch_id,
    action,
    details
  )
  values(
    target_branch.organization_id,
    p_actor_user_id,
    p_actor_user_id,
    p_branch_id,
    'supervisor_team_onboarding_waiting_selected',
    pg_catalog.jsonb_build_object(
      'branch_id', p_branch_id,
      'onboarding_choice', 'waiting_for_transfer'
    )
  );

  return pg_catalog.jsonb_build_object(
    'branch_id', saved_state.branch_id,
    'onboarding_choice', saved_state.onboarding_choice,
    'selected_at', saved_state.selected_at
  );
end;
$$;

revoke all on function public.set_supervisor_team_onboarding_waiting(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.set_supervisor_team_onboarding_waiting(uuid, uuid)
  to service_role;

-- =============================================================================
-- 5. Team Creation Hardening (Backward-Compatible 3-arg + Idempotent v2)
-- =============================================================================

create function public.create_supervisor_owned_operational_team_v2(
  p_actor_user_id uuid,
  p_branch_id uuid,
  p_team_name text,
  p_idempotency_key uuid default null
)
returns table(
  team_id uuid,
  organization_id uuid,
  branch_id uuid,
  team_name text,
  active boolean,
  legacy_supervisor_team_id uuid,
  supervisor_user_id uuid,
  assignment_role text,
  can_write boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  clean_team_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_team_name, '')), '[[:space:]]+', ' ', 'g');
  v_request_hash text;
  prior_idem public.supervisor_team_bootstrap_idempotency%rowtype;
  legacy_team public.branch_supervisor_teams%rowtype;
  canonical_team public.branch_operational_teams%rowtype;
begin
  if p_actor_user_id is null or p_branch_id is null or pg_catalog.length(clean_team_name) not between 1 and 80 then
    raise exception 'invalid employee team name' using errcode = '22023';
  end if;

  v_request_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(private.normalize_operational_team_name(clean_team_name), 'UTF8')),
    'hex'
  );

  select branch.*
  into target_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = p_branch_id
    and branch.active
    and organization.active
  for update of branch;

  if target_branch.id is null then
    raise exception 'branch unavailable' using errcode = '42501';
  end if;

  if not private.actor_can_read_operational_branch(p_actor_user_id, p_branch_id) then
    raise exception 'employee team bootstrap denied' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_branch_id::text, 17));

  if p_idempotency_key is not null then
    select idem.*
    into prior_idem
    from public.supervisor_team_bootstrap_idempotency idem
    where idem.actor_user_id = p_actor_user_id
      and idem.branch_id = p_branch_id
      and idem.idempotency_key = p_idempotency_key
    for update;

    if prior_idem.idempotency_key is not null then
      if prior_idem.request_hash <> v_request_hash then
        raise exception 'employee team idempotency conflict' using errcode = '23505';
      end if;

      if not private.actor_can_write_operational_team(p_actor_user_id, p_branch_id, prior_idem.operational_team_id) then
        raise exception 'employee team bootstrap denied' using errcode = '42501';
      end if;

      select team.*
      into strict canonical_team
      from public.branch_operational_teams team
      where team.id = prior_idem.operational_team_id
        and team.branch_id = p_branch_id
        and team.organization_id = target_branch.organization_id
        and team.active;

      return query
      select
        canonical_team.id,
        canonical_team.organization_id,
        canonical_team.branch_id,
        canonical_team.name,
        canonical_team.active,
        canonical_team.legacy_supervisor_team_id,
        p_actor_user_id,
        'primary'::text,
        true;
      return;
    end if;
  end if;

  if exists (
    select 1
    from public.branch_operational_team_supervisors assignment
    join public.branch_operational_teams team on team.id = assignment.operational_team_id
    where assignment.supervisor_user_id = p_actor_user_id
      and assignment.branch_id = p_branch_id
      and assignment.active
      and team.active
  ) then
    raise exception 'employee team already assigned' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.branch_operational_teams team
    where team.branch_id = p_branch_id
      and team.active
      and team.normalized_name = private.normalize_operational_team_name(clean_team_name)
  ) then
    raise exception 'employee team already exists' using errcode = '23505';
  end if;

  select team.*
  into legacy_team
  from public.branch_supervisor_teams team
  where team.organization_id = target_branch.organization_id
    and team.branch_id = p_branch_id
    and team.supervisor_user_id = p_actor_user_id
    and team.active
  order by team.created_at desc, team.id
  limit 1
  for update;

  if legacy_team.id is null then
    insert into public.branch_supervisor_teams(organization_id, branch_id, supervisor_user_id, company_name)
    values(target_branch.organization_id, p_branch_id, p_actor_user_id, clean_team_name)
    returning * into legacy_team;
  elsif exists (
    select 1
    from public.branch_operational_teams team
    where team.legacy_supervisor_team_id = legacy_team.id
      and team.active
  ) then
    raise exception 'employee team already assigned' using errcode = '23505';
  end if;

  select team.*
  into canonical_team
  from public.branch_operational_teams team
  where team.legacy_supervisor_team_id = legacy_team.id
  for update;

  if canonical_team.id is null then
    insert into public.branch_operational_teams(organization_id, branch_id, name, active, legacy_supervisor_team_id)
    values(target_branch.organization_id, p_branch_id, clean_team_name, true, legacy_team.id)
    returning * into canonical_team;
  else
    update public.branch_operational_teams
    set name = clean_team_name,
        active = true
    where id = canonical_team.id
    returning * into canonical_team;
  end if;

  update public.branch_supervisor_teams
  set company_name = clean_team_name
  where id = legacy_team.id;

  if exists (
    select 1
    from public.branch_operational_team_supervisors assignment
    where assignment.operational_team_id = canonical_team.id
      and assignment.active
      and assignment.assignment_role = 'primary'
      and assignment.supervisor_user_id <> p_actor_user_id
  ) then
    raise exception 'employee team primary supervisor conflict' using errcode = '23505';
  end if;

  update public.branch_operational_team_supervisors assignment
  set assignment_role = 'primary',
      active = true,
      valid_to = null
  where assignment.operational_team_id = canonical_team.id
    and assignment.supervisor_user_id = p_actor_user_id
    and assignment.active;

  if not found then
    insert into public.branch_operational_team_supervisors(
      organization_id,
      branch_id,
      operational_team_id,
      supervisor_user_id,
      assignment_role,
      created_by
    )
    values(
      target_branch.organization_id,
      p_branch_id,
      canonical_team.id,
      p_actor_user_id,
      'primary',
      p_actor_user_id
    );
  end if;

  delete from public.supervisor_team_onboarding_states state
  where state.supervisor_user_id = p_actor_user_id
    and state.branch_id = p_branch_id;

  if p_idempotency_key is not null then
    insert into public.supervisor_team_bootstrap_idempotency(
      actor_user_id,
      branch_id,
      idempotency_key,
      organization_id,
      operational_team_id,
      request_hash
    )
    values(
      p_actor_user_id,
      p_branch_id,
      p_idempotency_key,
      target_branch.organization_id,
      canonical_team.id,
      v_request_hash
    );
  end if;

  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    branch_id,
    action,
    details
  )
  values(
    target_branch.organization_id,
    p_actor_user_id,
    p_actor_user_id,
    p_branch_id,
    'supervisor_owned_team_created',
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'team_id', canonical_team.id,
      'legacy_supervisor_team_id', canonical_team.legacy_supervisor_team_id,
      'team_name', canonical_team.name,
      'assignment_role', 'primary',
      'idempotency_key', p_idempotency_key
    ))
  );

  return query
  select
    canonical_team.id,
    canonical_team.organization_id,
    canonical_team.branch_id,
    canonical_team.name,
    canonical_team.active,
    canonical_team.legacy_supervisor_team_id,
    p_actor_user_id,
    'primary'::text,
    private.actor_can_write_operational_team(p_actor_user_id, p_branch_id, canonical_team.id);
end;
$$;

revoke all on function public.create_supervisor_owned_operational_team_v2(uuid, uuid, text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.create_supervisor_owned_operational_team_v2(uuid, uuid, text, uuid)
  to service_role;

create or replace function public.create_supervisor_owned_operational_team(
  p_actor_user_id uuid,
  p_branch_id uuid,
  p_team_name text
)
returns table(
  team_id uuid,
  organization_id uuid,
  branch_id uuid,
  team_name text,
  active boolean,
  legacy_supervisor_team_id uuid,
  supervisor_user_id uuid,
  assignment_role text,
  can_write boolean
)
language sql
security definer
set search_path = ''
as $$
  select *
  from public.create_supervisor_owned_operational_team_v2(
    p_actor_user_id,
    p_branch_id,
    p_team_name,
    null
  );
$$;

revoke all on function public.create_supervisor_owned_operational_team(uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.create_supervisor_owned_operational_team(uuid, uuid, text)
  to service_role;

commit;
