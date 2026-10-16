-- Phase 3A: operational employee Training authentication and revocable sessions.
-- Reuses the Phase 2A credential/session tables; no learner progress or course
-- publication behavior is introduced here.

alter table public.operational_staff_training_credentials
  add column failed_window_started_at timestamptz;

alter table public.operational_staff_training_credentials
  add constraint operational_staff_training_credentials_failure_window_check
  check (
    failed_attempt_count = 0 or failed_window_started_at is not null
  );

alter table public.training_learner_sessions
  add column token_digest text,
  add column idle_expires_at timestamptz;

alter table public.training_learner_sessions
  add constraint training_learner_sessions_token_digest_check
    check (token_digest is null or token_digest ~ '^[0-9a-f]{64}$'),
  add constraint training_learner_sessions_idle_expiry_check
    check (
      idle_expires_at is null
      or (idle_expires_at > issued_at and idle_expires_at <= expires_at)
    );

create unique index training_learner_sessions_token_digest_idx
  on public.training_learner_sessions(token_digest)
  where token_digest is not null;

create index training_learner_sessions_idle_expiry_idx
  on public.training_learner_sessions(idle_expires_at)
  where revoked_at is null and token_digest is not null;

create or replace function private.normalize_training_credential_failure_window()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.failed_attempt_count = 0 then
    new.failed_window_started_at := null;
  end if;
  return new;
end;
$$;

create trigger operational_staff_training_credentials_05_failure_window
before insert or update on public.operational_staff_training_credentials
for each row execute function private.normalize_training_credential_failure_window();

create or replace function private.training_learner_employee_is_eligible(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.operational_staff staff
    join public.organizations organization
      on organization.id = staff.organization_id
     and organization.active
    join public.branches branch
      on branch.id = staff.branch_id
     and branch.organization_id = staff.organization_id
     and branch.active
    join public.branch_training_access access
      on access.organization_id = staff.organization_id
     and access.branch_id = staff.branch_id
     and access.enabled
     and access.pin_hash is not null
    where staff.id = target_employee_id
      and staff.organization_id = target_organization_id
      and staff.branch_id = target_branch_id
      and staff.employment_status = 'active'
      and exists (
        select 1
        from public.operational_staff_assignments assignment
        join public.branch_operational_teams operational_team
          on operational_team.id = assignment.operational_team_id
         and operational_team.organization_id = assignment.organization_id
         and operational_team.branch_id = assignment.branch_id
         and operational_team.active
        where assignment.operational_staff_id = staff.id
          and assignment.organization_id = staff.organization_id
          and assignment.branch_id = staff.branch_id
          and assignment.active
          and assignment.valid_from <= private.phase4a_business_date(branch.timezone)
          and (
            assignment.valid_to is null
            or assignment.valid_to >= private.phase4a_business_date(branch.timezone)
          )
      )
  );
$$;

create or replace function public.get_training_learner_login_credential(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_code text
)
returns table(
  employee_id uuid,
  organization_id uuid,
  branch_id uuid,
  display_name text,
  employee_code text,
  pin_hash text,
  salt text,
  kdf_version integer,
  cost integer,
  block_size integer,
  parallelization integer,
  credential_version uuid,
  credential_status text,
  failed_attempt_count integer,
  locked_until timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  candidate_ids uuid[];
begin
  if target_employee_code is null
    or length(btrim(target_employee_code)) < 1
    or length(btrim(target_employee_code)) > 80 then
    return;
  end if;

  select array_agg(staff.id order by staff.id)
  into candidate_ids
  from public.operational_staff staff
  where staff.organization_id = target_organization_id
    and staff.branch_id = target_branch_id
    and pg_catalog.lower(btrim(staff.staff_code)) = pg_catalog.lower(btrim(target_employee_code))
    and private.training_learner_employee_is_eligible(
      target_organization_id,
      target_branch_id,
      staff.id
    );

  if coalesce(cardinality(candidate_ids), 0) <> 1 then
    return;
  end if;

  return query
  select
    staff.id,
    staff.organization_id,
    staff.branch_id,
    staff.display_name,
    staff.staff_code,
    credential.pin_hash,
    credential.salt,
    credential.kdf_version,
    credential.cost,
    credential.block_size,
    credential.parallelization,
    credential.credential_version,
    credential.status,
    credential.failed_attempt_count,
    credential.locked_until
  from public.operational_staff staff
  join public.operational_staff_training_credentials credential
    on credential.employee_id = staff.id
   and credential.organization_id = staff.organization_id
  where staff.id = candidate_ids[1]
    and staff.organization_id = target_organization_id
    and staff.branch_id = target_branch_id;
end;
$$;

create or replace function public.complete_training_learner_login(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  expected_credential_version uuid,
  authentication_succeeded boolean,
  new_token_digest text
)
returns table(
  session_id uuid,
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  employee_id uuid,
  display_name text,
  employee_code text,
  issued_at timestamptz,
  expires_at timestamptz,
  idle_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  credential public.operational_staff_training_credentials%rowtype;
  now_at timestamptz := statement_timestamp();
  next_failure_count integer;
  new_session_id uuid;
begin
  if new_token_digest is null or new_token_digest !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid Training learner session token' using errcode = '22023';
  end if;

  select stored.*
  into credential
  from public.operational_staff_training_credentials stored
  where stored.employee_id = target_employee_id
    and stored.organization_id = target_organization_id
  for update;

  if credential.employee_id is null
    or credential.credential_version <> expected_credential_version then
    return;
  end if;

  if credential.status = 'locked'
    and credential.locked_until is not null
    and credential.locked_until <= now_at then
    update public.operational_staff_training_credentials stored
    set status = 'active',
        failed_attempt_count = 0,
        failed_window_started_at = null,
        locked_until = null,
        updated_at = now_at
    where stored.employee_id = credential.employee_id
      and stored.organization_id = credential.organization_id
    returning stored.* into credential;
  end if;

  if authentication_succeeded is not true then
    if credential.status <> 'active' then
      return;
    end if;

    if credential.failed_window_started_at is null
      or credential.failed_window_started_at <= now_at - interval '15 minutes' then
      next_failure_count := 1;
      credential.failed_window_started_at := now_at;
    else
      next_failure_count := credential.failed_attempt_count + 1;
    end if;

    update public.operational_staff_training_credentials stored
    set failed_attempt_count = next_failure_count,
        failed_window_started_at = credential.failed_window_started_at,
        status = case when next_failure_count >= 5 then 'locked' else 'active' end,
        locked_until = case when next_failure_count >= 5 then now_at + interval '15 minutes' else null end,
        updated_at = now_at
    where stored.employee_id = credential.employee_id
      and stored.organization_id = credential.organization_id;

    if next_failure_count >= 5 then
      update public.training_learner_sessions learner_session
      set revoked_at = coalesce(learner_session.revoked_at, now_at)
      where learner_session.organization_id = target_organization_id
        and learner_session.employee_id = target_employee_id
        and learner_session.revoked_at is null;
    end if;
    return;
  end if;

  if credential.status <> 'active'
    or not private.training_learner_employee_is_eligible(
      target_organization_id,
      target_branch_id,
      target_employee_id
    ) then
    return;
  end if;

  update public.operational_staff_training_credentials stored
  set failed_attempt_count = 0,
      failed_window_started_at = null,
      locked_until = null,
      updated_at = now_at
  where stored.employee_id = credential.employee_id
    and stored.organization_id = credential.organization_id;

  insert into public.training_learner_sessions(
    organization_id,
    employee_id,
    branch_id_at_auth,
    credential_version,
    issued_at,
    expires_at,
    last_seen_at,
    token_digest,
    idle_expires_at
  ) values (
    target_organization_id,
    target_employee_id,
    target_branch_id,
    credential.credential_version,
    now_at,
    now_at + interval '12 hours',
    now_at,
    new_token_digest,
    now_at + interval '1 hour'
  )
  returning id into new_session_id;

  return query
  select
    learner_session.id,
    organization.id,
    organization.name,
    organization.name_ar,
    branch.id,
    branch.name,
    branch.name_ar,
    staff.id,
    staff.display_name,
    staff.staff_code,
    learner_session.issued_at,
    learner_session.expires_at,
    learner_session.idle_expires_at
  from public.training_learner_sessions learner_session
  join public.organizations organization
    on organization.id = learner_session.organization_id
  join public.branches branch
    on branch.id = learner_session.branch_id_at_auth
   and branch.organization_id = learner_session.organization_id
  join public.operational_staff staff
    on staff.id = learner_session.employee_id
   and staff.organization_id = learner_session.organization_id
  where learner_session.id = new_session_id;
end;
$$;

create or replace function public.validate_training_learner_session(
  target_token_digest text
)
returns table(
  session_id uuid,
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  employee_id uuid,
  display_name text,
  employee_code text,
  issued_at timestamptz,
  expires_at timestamptz,
  idle_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  learner_session public.training_learner_sessions%rowtype;
  now_at timestamptz := statement_timestamp();
begin
  if target_token_digest is null or target_token_digest !~ '^[0-9a-f]{64}$' then
    return;
  end if;

  select stored.*
  into learner_session
  from public.training_learner_sessions stored
  where stored.token_digest = target_token_digest
  for update;

  if learner_session.id is null then
    return;
  end if;

  if learner_session.revoked_at is not null
    or learner_session.expires_at <= now_at
    or learner_session.idle_expires_at is null
    or learner_session.idle_expires_at <= now_at
    or not exists (
      select 1
      from public.operational_staff_training_credentials credential
      where credential.employee_id = learner_session.employee_id
        and credential.organization_id = learner_session.organization_id
        and credential.credential_version = learner_session.credential_version
        and credential.status = 'active'
    )
    or not private.training_learner_employee_is_eligible(
      learner_session.organization_id,
      learner_session.branch_id_at_auth,
      learner_session.employee_id
    ) then
    update public.training_learner_sessions stored
    set revoked_at = coalesce(stored.revoked_at, now_at)
    where stored.id = learner_session.id;
    return;
  end if;

  update public.training_learner_sessions stored
  set last_seen_at = now_at,
      idle_expires_at = least(stored.expires_at, now_at + interval '1 hour')
  where stored.id = learner_session.id
  returning stored.* into learner_session;

  return query
  select
    learner_session.id,
    organization.id,
    organization.name,
    organization.name_ar,
    branch.id,
    branch.name,
    branch.name_ar,
    staff.id,
    staff.display_name,
    staff.staff_code,
    learner_session.issued_at,
    learner_session.expires_at,
    learner_session.idle_expires_at
  from public.organizations organization
  join public.branches branch
    on branch.id = learner_session.branch_id_at_auth
   and branch.organization_id = organization.id
  join public.operational_staff staff
    on staff.id = learner_session.employee_id
   and staff.organization_id = organization.id
  where organization.id = learner_session.organization_id;
end;
$$;

create or replace function public.revoke_training_learner_session(
  target_token_digest text
)
returns table(revoked boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  matched_id uuid;
begin
  if target_token_digest is null or target_token_digest !~ '^[0-9a-f]{64}$' then
    return query select false;
    return;
  end if;

  update public.training_learner_sessions learner_session
  set revoked_at = coalesce(learner_session.revoked_at, statement_timestamp())
  where learner_session.token_digest = target_token_digest
  returning learner_session.id into matched_id;

  return query select matched_id is not null;
end;
$$;

revoke all on function private.training_learner_employee_is_eligible(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.normalize_training_credential_failure_window()
  from public, anon, authenticated, service_role;

revoke all on function public.get_training_learner_login_credential(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.complete_training_learner_login(uuid, uuid, uuid, uuid, boolean, text)
  from public, anon, authenticated;
revoke all on function public.validate_training_learner_session(text)
  from public, anon, authenticated;
revoke all on function public.revoke_training_learner_session(text)
  from public, anon, authenticated;

grant execute on function public.get_training_learner_login_credential(uuid, uuid, text)
  to service_role;
grant execute on function public.complete_training_learner_login(uuid, uuid, uuid, uuid, boolean, text)
  to service_role;
grant execute on function public.validate_training_learner_session(text)
  to service_role;
grant execute on function public.revoke_training_learner_session(text)
  to service_role;

comment on column public.training_learner_sessions.token_digest is
  'SHA-256 digest of the 256-bit opaque learner token. Raw tokens are never stored.';
comment on column public.training_learner_sessions.idle_expires_at is
  'Sliding idle-session deadline, capped by the absolute 12-hour expiry.';
comment on table public.training_learner_sessions is
  'Revocable learner sessions. Browsers hold a random opaque token; only its digest is stored, and employee identity is resolved server-side.';
comment on function public.complete_training_learner_login(uuid, uuid, uuid, uuid, boolean, text) is
  'Atomically records learner PIN failures or creates a revocable session after backend scrypt verification.';
