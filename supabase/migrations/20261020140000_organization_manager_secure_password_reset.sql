-- Internal Admin Organization Manager password resets. Password verification
-- happens server-side against Supabase Auth before the service role issues a
-- short-lived, one-time, operation-bound step-up grant.

create table public.organization_manager_password_reset_operations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  actor_user_id uuid not null,
  target_user_id uuid not null,
  actor_session_id uuid not null,
  request_key_hash text not null,
  target_previously_required_password_change boolean not null,
  status text not null default 'pending_auth',
  recovery_generation integer not null default 0,
  replaces_operation_id uuid references public.organization_manager_password_reset_operations(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  state_changed_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  constraint organization_manager_password_reset_request_hash_check
    check(request_key_hash~'^[0-9a-f]{64}$'),
  constraint organization_manager_password_reset_status_check
    check(status in('pending_auth','auth_outcome_unknown','succeeded','auth_rejected','superseded')),
  constraint organization_manager_password_reset_recovery_check
    check(recovery_generation between 0 and 3
      and ((recovery_generation=0 and replaces_operation_id is null)
        or (recovery_generation>0 and replaces_operation_id is not null))),
  constraint organization_manager_password_reset_completion_check check(
    (status in('pending_auth','auth_outcome_unknown') and completed_at is null)
    or (status in('succeeded','auth_rejected','superseded') and completed_at is not null)
  ),
  constraint organization_manager_password_reset_actor_target_check check(actor_user_id<>target_user_id),
  unique(actor_user_id,request_key_hash),
  unique(replaces_operation_id)
);

create unique index organization_manager_password_reset_one_unresolved_target_idx
  on public.organization_manager_password_reset_operations(target_user_id)
  where status in('pending_auth','auth_outcome_unknown');
create index organization_manager_password_reset_organization_created_idx
  on public.organization_manager_password_reset_operations(organization_id,created_at desc);

create table public.organization_manager_password_reset_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  operation_id uuid references public.organization_manager_password_reset_operations(id) on delete restrict,
  actor_user_id uuid not null,
  target_user_id uuid not null,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint organization_manager_password_reset_events_type_check check(event_type in(
    'step_up_issued','step_up_consumed','reset_started','auth_rejected',
    'auth_outcome_unknown','succeeded','recovery_superseded'
  )),
  constraint organization_manager_password_reset_events_details_check
    check(jsonb_typeof(details)='object' and private.account_audit_details_are_safe(details))
);
create index organization_manager_password_reset_events_scope_idx
  on public.organization_manager_password_reset_events(organization_id,target_user_id,occurred_at,id);

create table private.organization_manager_password_reset_step_up_grants (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null,
  actor_session_id uuid not null,
  organization_id uuid not null,
  target_user_id uuid not null,
  operation text not null default 'organization_manager_password_reset',
  secret_sha256 text not null unique,
  issued_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  constraint organization_manager_password_reset_step_up_operation_check
    check(operation='organization_manager_password_reset'),
  constraint organization_manager_password_reset_step_up_hash_check
    check(secret_sha256~'^[0-9a-f]{64}$'),
  constraint organization_manager_password_reset_step_up_expiry_check
    check(expires_at>issued_at and expires_at<=issued_at+interval '5 minutes'),
  constraint organization_manager_password_reset_step_up_consumed_check
    check(consumed_at is null or (consumed_at>=issued_at and consumed_at<=expires_at))
);

create table private.organization_manager_password_reset_rate_limits (
  phase text not null,
  dimension text not null,
  key_hash text not null,
  bucket_started_at timestamptz not null,
  attempt_count integer not null,
  updated_at timestamptz not null default statement_timestamp(),
  primary key(phase,dimension,key_hash,bucket_started_at),
  constraint organization_manager_password_reset_rate_phase_check
    check(phase in('step_up','reset')),
  constraint organization_manager_password_reset_rate_dimension_check
    check(dimension in('actor','target','ip')),
  constraint organization_manager_password_reset_rate_hash_check
    check(key_hash~'^[0-9a-f]{64}$'),
  constraint organization_manager_password_reset_rate_count_check check(attempt_count>0)
);

alter table public.organization_manager_password_reset_operations enable row level security;
alter table public.organization_manager_password_reset_events enable row level security;
revoke all on table public.organization_manager_password_reset_operations
  from public,anon,authenticated,service_role;
revoke all on table public.organization_manager_password_reset_events
  from public,anon,authenticated,service_role;
revoke all on table private.organization_manager_password_reset_step_up_grants
  from public,anon,authenticated,service_role;
revoke all on table private.organization_manager_password_reset_rate_limits
  from public,anon,authenticated,service_role;

create function private.reject_organization_manager_password_reset_event_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  raise exception 'Organization Manager password reset events are immutable' using errcode='42501';
end;
$$;
create trigger organization_manager_password_reset_events_immutability
before update or delete on public.organization_manager_password_reset_events
for each row execute function private.reject_organization_manager_password_reset_event_mutation();

create function private.assert_organization_manager_password_reset_scope(
  p_actor_user_id uuid,p_organization_id uuid,p_target_user_id uuid
)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare active_manager_organization_count integer;
begin
  if p_actor_user_id is null or p_organization_id is null or p_target_user_id is null
    or p_actor_user_id=p_target_user_id or not private.is_internal_admin(p_actor_user_id)
    or not exists(select 1 from public.organizations organization
      where organization.id=p_organization_id and organization.active)
    or not exists(select 1 from public.profiles profile
      where profile.id=p_target_user_id and profile.disabled_at is null)
    or not exists(select 1 from public.organization_memberships membership
      where membership.organization_id=p_organization_id and membership.user_id=p_target_user_id
        and membership.role='organization_manager' and membership.active)
    or exists(select 1 from public.internal_admin_memberships membership
      where membership.user_id=p_target_user_id and membership.active)
    or exists(select 1 from public.branch_memberships membership
      join public.branches branch on branch.id=membership.branch_id
      where membership.user_id=p_target_user_id and branch.active)
    or exists(select 1 from public.maintenance_memberships membership
      where membership.user_id=p_target_user_id and membership.active)
    or exists(select 1 from public.purchasing_memberships membership
      where membership.user_id=p_target_user_id and membership.active)
  then
    raise exception 'password reset denied' using errcode='42501';
  end if;

  select count(distinct membership.organization_id)::integer
  into active_manager_organization_count
  from public.organization_memberships membership
  join public.organizations organization on organization.id=membership.organization_id
  where membership.user_id=p_target_user_id and membership.role='organization_manager'
    and membership.active and organization.active;
  if active_manager_organization_count<>1 then
    raise exception 'password reset denied' using errcode='42501';
  end if;
  return true;
end;
$$;

create function public.is_backend_auth_session_active(p_user_id uuid,p_session_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select p_user_id is not null and p_session_id is not null and exists(
    select 1 from auth.sessions session
    where session.id=p_session_id and session.user_id=p_user_id
  );
$$;

-- Only Organization Manager traffic is session-revocation gated. Internal
-- Admin and Branch Supervisor requests remain on the existing JWT path.
create function public.validate_organization_manager_backend_session(
  p_actor_user_id uuid,p_actor_session_id uuid
)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  if not exists(
    select 1 from public.organization_memberships membership
    join public.organizations organization on organization.id=membership.organization_id
    where membership.user_id=p_actor_user_id and membership.role='organization_manager'
      and membership.active and organization.active
  ) then return 'not_applicable'; end if;
  if exists(select 1 from auth.sessions session
    where session.id=p_actor_session_id and session.user_id=p_actor_user_id)
  then return 'active'; end if;
  return 'revoked';
end;
$$;

create function public.consume_organization_manager_password_reset_rate_limit(
  p_actor_user_id uuid,p_organization_id uuid,p_target_user_id uuid,
  p_client_address_hash text,p_phase text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare bucket_start timestamptz;
  actor_count integer; target_count integer; ip_count integer;
begin
  perform private.assert_organization_manager_password_reset_scope(
    p_actor_user_id,p_organization_id,p_target_user_id
  );
  if p_phase not in('step_up','reset') or p_client_address_hash is null
    or p_client_address_hash!~'^[0-9a-f]{64}$' then
    raise exception 'invalid reset request' using errcode='22023';
  end if;
  bucket_start:=date_bin(interval '15 minutes',statement_timestamp(),timestamptz '2000-01-01 00:00:00+00');

  insert into private.organization_manager_password_reset_rate_limits(
    phase,dimension,key_hash,bucket_started_at,attempt_count
  ) values(p_phase,'actor',encode(extensions.digest(convert_to(p_actor_user_id::text,'UTF8'),'sha256'),'hex'),bucket_start,1)
  on conflict(phase,dimension,key_hash,bucket_started_at) do update
    set attempt_count=private.organization_manager_password_reset_rate_limits.attempt_count+1,
      updated_at=statement_timestamp()
  returning attempt_count into actor_count;
  insert into private.organization_manager_password_reset_rate_limits(
    phase,dimension,key_hash,bucket_started_at,attempt_count
  ) values(p_phase,'target',encode(extensions.digest(convert_to(p_target_user_id::text,'UTF8'),'sha256'),'hex'),bucket_start,1)
  on conflict(phase,dimension,key_hash,bucket_started_at) do update
    set attempt_count=private.organization_manager_password_reset_rate_limits.attempt_count+1,
      updated_at=statement_timestamp()
  returning attempt_count into target_count;
  insert into private.organization_manager_password_reset_rate_limits(
    phase,dimension,key_hash,bucket_started_at,attempt_count
  ) values(p_phase,'ip',p_client_address_hash,bucket_start,1)
  on conflict(phase,dimension,key_hash,bucket_started_at) do update
    set attempt_count=private.organization_manager_password_reset_rate_limits.attempt_count+1,
      updated_at=statement_timestamp()
  returning attempt_count into ip_count;

  return jsonb_build_object(
    'allowed',actor_count<=5 and target_count<=3 and ip_count<=10
  );
end;
$$;

create function public.issue_organization_manager_password_reset_step_up(
  p_actor_user_id uuid,p_actor_session_id uuid,p_organization_id uuid,
  p_target_user_id uuid,p_grant_secret_hash text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved private.organization_manager_password_reset_step_up_grants%rowtype;
begin
  perform private.assert_organization_manager_password_reset_scope(
    p_actor_user_id,p_organization_id,p_target_user_id
  );
  if p_actor_session_id is null or p_grant_secret_hash is null
    or p_grant_secret_hash!~'^[0-9a-f]{64}$'
    or not exists(select 1 from auth.sessions session
      where session.id=p_actor_session_id and session.user_id=p_actor_user_id) then
    raise exception 'password reset denied' using errcode='42501';
  end if;
  insert into private.organization_manager_password_reset_step_up_grants(
    actor_user_id,actor_session_id,organization_id,target_user_id,secret_sha256,expires_at
  ) values(p_actor_user_id,p_actor_session_id,p_organization_id,p_target_user_id,
    p_grant_secret_hash,statement_timestamp()+interval '5 minutes')
  returning * into saved;
  insert into public.organization_manager_password_reset_events(
    organization_id,actor_user_id,target_user_id,event_type,details
  ) values(p_organization_id,p_actor_user_id,p_target_user_id,'step_up_issued',
    jsonb_build_object('grant_id',saved.id));
  return jsonb_build_object('grant_id',saved.id,'expires_at',saved.expires_at);
exception when unique_violation then
  raise exception 'password reset denied' using errcode='42501';
end;
$$;

create function public.begin_organization_manager_password_reset(
  p_actor_user_id uuid,p_actor_session_id uuid,p_organization_id uuid,p_target_user_id uuid,
  p_request_key_hash text,p_step_up_secret_hash text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare existing_operation public.organization_manager_password_reset_operations%rowtype;
  unresolved public.organization_manager_password_reset_operations%rowtype;
  saved public.organization_manager_password_reset_operations%rowtype;
  consumed_grant_id uuid; prior_forced boolean; next_generation integer:=0;
begin
  if p_request_key_hash is null or p_request_key_hash!~'^[0-9a-f]{64}$'
    or p_step_up_secret_hash is null or p_step_up_secret_hash!~'^[0-9a-f]{64}$' then
    raise exception 'invalid reset request' using errcode='22023';
  end if;
  perform private.assert_organization_manager_password_reset_scope(
    p_actor_user_id,p_organization_id,p_target_user_id
  );
  if not exists(select 1 from auth.sessions session
    where session.id=p_actor_session_id and session.user_id=p_actor_user_id) then
    raise exception 'password reset denied' using errcode='42501';
  end if;

  select profile.must_change_password into prior_forced
  from public.profiles profile
  where profile.id=p_target_user_id and profile.disabled_at is null
  for update;
  if not found then raise exception 'password reset denied' using errcode='42501'; end if;

  update private.organization_manager_password_reset_step_up_grants grant_row
  set consumed_at=statement_timestamp()
  where grant_row.secret_sha256=p_step_up_secret_hash
    and grant_row.actor_user_id=p_actor_user_id and grant_row.actor_session_id=p_actor_session_id
    and grant_row.organization_id=p_organization_id and grant_row.target_user_id=p_target_user_id
    and grant_row.operation='organization_manager_password_reset'
    and grant_row.consumed_at is null and statement_timestamp()<grant_row.expires_at
  returning grant_row.id into consumed_grant_id;
  if consumed_grant_id is null then
    raise exception 'password reset step-up required' using errcode='P0001';
  end if;
  insert into public.organization_manager_password_reset_events(
    organization_id,actor_user_id,target_user_id,event_type,details
  ) values(p_organization_id,p_actor_user_id,p_target_user_id,'step_up_consumed',
    jsonb_build_object('grant_id',consumed_grant_id));

  select operation.* into existing_operation
  from public.organization_manager_password_reset_operations operation
  where operation.actor_user_id=p_actor_user_id and operation.request_key_hash=p_request_key_hash;
  if found then
    if existing_operation.actor_session_id<>p_actor_session_id
      or existing_operation.organization_id<>p_organization_id
      or existing_operation.target_user_id<>p_target_user_id then
      raise exception 'password reset denied' using errcode='42501';
    end if;
    return jsonb_build_object('operation_id',existing_operation.id,'status',existing_operation.status,
      'replayed',true,'recovery_generation',existing_operation.recovery_generation);
  end if;

  select operation.* into unresolved
  from public.organization_manager_password_reset_operations operation
  where operation.target_user_id=p_target_user_id
    and operation.status in('pending_auth','auth_outcome_unknown')
  for update;
  if found then
    if unresolved.state_changed_at>statement_timestamp()-interval '2 minutes'
      or unresolved.recovery_generation>=3 then
      raise exception 'password reset recovery unavailable' using errcode='55000';
    end if;
    next_generation:=unresolved.recovery_generation+1;
    update public.organization_manager_password_reset_operations
    set status='superseded',state_changed_at=statement_timestamp(),completed_at=statement_timestamp()
    where id=unresolved.id and status in('pending_auth','auth_outcome_unknown');
    if not found then raise exception 'password reset state changed' using errcode='40001'; end if;
    insert into public.organization_manager_password_reset_events(
      organization_id,operation_id,actor_user_id,target_user_id,event_type,details
    ) values(unresolved.organization_id,unresolved.id,p_actor_user_id,p_target_user_id,
      'recovery_superseded',jsonb_build_object('recovery_generation',next_generation));
  end if;

  insert into public.organization_manager_password_reset_operations(
    organization_id,actor_user_id,target_user_id,actor_session_id,request_key_hash,
    target_previously_required_password_change,recovery_generation,replaces_operation_id
  ) values(p_organization_id,p_actor_user_id,p_target_user_id,p_actor_session_id,p_request_key_hash,
    prior_forced,next_generation,unresolved.id)
  returning * into saved;
  update public.profiles set must_change_password=true
  where id=p_target_user_id and disabled_at is null;

  insert into public.organization_manager_password_reset_events(
    organization_id,operation_id,actor_user_id,target_user_id,event_type,details
  ) values(p_organization_id,saved.id,p_actor_user_id,p_target_user_id,'reset_started',
    jsonb_build_object('recovery_generation',saved.recovery_generation,
      'replaces_operation_id',saved.replaces_operation_id));
  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  ) values(p_organization_id,p_actor_user_id,p_target_user_id,'temporary_password_reset',
    jsonb_build_object('reset_operation_id',saved.id,'result','attempt_started',
      'recovery_generation',saved.recovery_generation));
  return jsonb_build_object('operation_id',saved.id,'status',saved.status,'replayed',false,
    'recovery_generation',saved.recovery_generation);
end;
$$;

create function public.finalize_organization_manager_password_reset(
  p_operation_id uuid,p_actor_user_id uuid,p_organization_id uuid,p_target_user_id uuid
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare operation public.organization_manager_password_reset_operations%rowtype;
begin
  select candidate.* into operation
  from public.organization_manager_password_reset_operations candidate
  where candidate.id=p_operation_id for update;
  if not found or operation.actor_user_id<>p_actor_user_id
    or operation.organization_id<>p_organization_id or operation.target_user_id<>p_target_user_id then
    raise exception 'password reset denied' using errcode='42501';
  end if;
  if operation.status='succeeded' then
    return jsonb_build_object('operation_id',operation.id,'status',operation.status);
  end if;
  if operation.status<>'pending_auth' then
    raise exception 'password reset state changed' using errcode='40001';
  end if;
  perform private.assert_organization_manager_password_reset_scope(
    p_actor_user_id,p_organization_id,p_target_user_id
  );
  if not exists(select 1 from public.profiles profile
    where profile.id=p_target_user_id and profile.disabled_at is null and profile.must_change_password) then
    raise exception 'password reset denied' using errcode='42501';
  end if;

  -- Revoke every pre-reset target session before normal access can resume.
  delete from auth.sessions session where session.user_id=p_target_user_id;
  update public.organization_manager_password_reset_operations
  set status='succeeded',state_changed_at=statement_timestamp(),completed_at=statement_timestamp()
  where id=p_operation_id and status='pending_auth';
  if not found then raise exception 'password reset state changed' using errcode='40001'; end if;
  insert into public.organization_manager_password_reset_events(
    organization_id,operation_id,actor_user_id,target_user_id,event_type,details
  ) values(p_organization_id,p_operation_id,p_actor_user_id,p_target_user_id,'succeeded','{}');
  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  ) values(p_organization_id,p_actor_user_id,p_target_user_id,'temporary_password_reset',
    jsonb_build_object('reset_operation_id',p_operation_id,'result','succeeded'));
  return jsonb_build_object('operation_id',p_operation_id,'status','succeeded');
end;
$$;

create function public.fail_organization_manager_password_reset(
  p_operation_id uuid,p_actor_user_id uuid,p_organization_id uuid,p_target_user_id uuid,p_result text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare operation public.organization_manager_password_reset_operations%rowtype;
begin
  if p_result not in('auth_rejected','auth_outcome_unknown') then
    raise exception 'invalid reset result' using errcode='22023';
  end if;
  select candidate.* into operation
  from public.organization_manager_password_reset_operations candidate
  where candidate.id=p_operation_id for update;
  if not found or operation.actor_user_id<>p_actor_user_id
    or operation.organization_id<>p_organization_id or operation.target_user_id<>p_target_user_id
    or not private.is_internal_admin(p_actor_user_id) then
    raise exception 'password reset denied' using errcode='42501';
  end if;
  if operation.status='succeeded' then
    return jsonb_build_object('operation_id',operation.id,'status',operation.status);
  end if;
  if operation.status<>'pending_auth' then
    return jsonb_build_object('operation_id',operation.id,'status',operation.status);
  end if;

  update public.organization_manager_password_reset_operations
  set status=p_result,state_changed_at=statement_timestamp(),
    completed_at=case when p_result='auth_rejected' then statement_timestamp() else null end
  where id=p_operation_id and status='pending_auth';
  if p_result='auth_rejected' then
    update public.profiles set must_change_password=operation.target_previously_required_password_change
    where id=p_target_user_id and disabled_at is null and must_change_password;
  end if;
  insert into public.organization_manager_password_reset_events(
    organization_id,operation_id,actor_user_id,target_user_id,event_type,details
  ) values(p_organization_id,p_operation_id,p_actor_user_id,p_target_user_id,p_result,
    jsonb_build_object('recovery_generation',operation.recovery_generation));
  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  ) values(p_organization_id,p_actor_user_id,p_target_user_id,'temporary_password_reset',
    jsonb_build_object('reset_operation_id',p_operation_id,'result',p_result));
  return jsonb_build_object('operation_id',p_operation_id,'status',p_result);
end;
$$;

create function public.get_organization_manager_password_reset_status(
  p_operation_id uuid,p_actor_user_id uuid,p_organization_id uuid,p_target_user_id uuid
)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare operation public.organization_manager_password_reset_operations%rowtype;
begin
  select candidate.* into operation from public.organization_manager_password_reset_operations candidate
  where candidate.id=p_operation_id and candidate.actor_user_id=p_actor_user_id
    and candidate.organization_id=p_organization_id and candidate.target_user_id=p_target_user_id;
  if not found or not private.is_internal_admin(p_actor_user_id) then
    raise exception 'password reset denied' using errcode='42501';
  end if;
  return jsonb_build_object('operation_id',operation.id,'status',operation.status);
end;
$$;

-- A forced-password flow must not clear the restriction while a reset or
-- ambiguous recovery remains unresolved, even if an old session races Auth.
create or replace function public.finalize_password_change(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare changed_rows integer;
begin
  if exists(select 1 from public.organization_manager_password_reset_operations operation
    where operation.target_user_id=p_user_id and operation.status in('pending_auth','auth_outcome_unknown'))
    or not exists(select 1 from public.profiles where id=p_user_id and disabled_at is null and must_change_password) then
    raise exception 'password change finalization denied' using errcode='42501';
  end if;
  if not exists(
    select 1 from public.organization_memberships where user_id=p_user_id and role='organization_manager'
    union all select 1 from public.branch_memberships membership join public.branches branch on branch.id=membership.branch_id where membership.user_id=p_user_id
    union all select 1 from public.maintenance_memberships membership join public.organizations organization on organization.id=membership.organization_id where membership.user_id=p_user_id and membership.active and organization.active
    union all select 1 from public.purchasing_memberships membership join public.organizations organization on organization.id=membership.organization_id where membership.user_id=p_user_id and membership.active and organization.active
  ) then raise exception 'password change finalization denied' using errcode='42501'; end if;
  update public.profiles set must_change_password=false
  where id=p_user_id and disabled_at is null and must_change_password;
  get diagnostics changed_rows=row_count;
  if changed_rows<>1 then raise exception 'password change finalization denied' using errcode='42501'; end if;
  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  )
  select attribution.organization_id,p_user_id,p_user_id,'password_changed','{}'::jsonb
  from (
    select organization_id from public.organization_memberships where user_id=p_user_id and role='organization_manager'
    union select branch.organization_id from public.branch_memberships membership join public.branches branch on branch.id=membership.branch_id where membership.user_id=p_user_id
    union select membership.organization_id from public.maintenance_memberships membership join public.organizations organization on organization.id=membership.organization_id where membership.user_id=p_user_id and membership.active and organization.active
    union select membership.organization_id from public.purchasing_memberships membership join public.organizations organization on organization.id=membership.organization_id where membership.user_id=p_user_id and membership.active and organization.active
  ) attribution;
  return jsonb_build_object('success',true);
end;
$$;

revoke all on function private.reject_organization_manager_password_reset_event_mutation() from public,anon,authenticated,service_role;
revoke all on function private.assert_organization_manager_password_reset_scope(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.is_backend_auth_session_active(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.validate_organization_manager_backend_session(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.consume_organization_manager_password_reset_rate_limit(uuid,uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.issue_organization_manager_password_reset_step_up(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.begin_organization_manager_password_reset(uuid,uuid,uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.finalize_organization_manager_password_reset(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.fail_organization_manager_password_reset(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.get_organization_manager_password_reset_status(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.finalize_password_change(uuid) from public,anon,authenticated,service_role;

grant execute on function public.is_backend_auth_session_active(uuid,uuid) to service_role;
grant execute on function public.validate_organization_manager_backend_session(uuid,uuid) to service_role;
grant execute on function public.consume_organization_manager_password_reset_rate_limit(uuid,uuid,uuid,text,text) to service_role;
grant execute on function public.issue_organization_manager_password_reset_step_up(uuid,uuid,uuid,uuid,text) to service_role;
grant execute on function public.begin_organization_manager_password_reset(uuid,uuid,uuid,uuid,text,text) to service_role;
grant execute on function public.finalize_organization_manager_password_reset(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.fail_organization_manager_password_reset(uuid,uuid,uuid,uuid,text) to service_role;
grant execute on function public.get_organization_manager_password_reset_status(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.finalize_password_change(uuid) to service_role;

comment on table public.organization_manager_password_reset_operations is
  'Secret-free reset lifecycle history. Actor and target UUID snapshots deliberately have no restrictive auth.users foreign keys.';
comment on table public.organization_manager_password_reset_events is
  'Immutable, secret-free step-up, reset, and bounded recovery event history.';
comment on function public.begin_organization_manager_password_reset(uuid,uuid,uuid,uuid,text,text) is
  'Consumes one exact step-up grant and starts or safely replaces a stale unresolved reset under a target lock.';
