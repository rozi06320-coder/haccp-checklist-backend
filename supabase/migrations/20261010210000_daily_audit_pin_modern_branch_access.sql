begin;

-- Daily Audit persistence already authorizes the canonical branch membership.
-- Keep PIN credential lookup and Manager-grant validation on the same boundary;
-- a legacy Supervisor-team row is optional historical attribution only.
create or replace function public.get_daily_audit_access_user_credentials(actor_user_id uuid, target_branch_id uuid)
returns table(
  organization_id uuid,
  access_user_id uuid,
  display_name text,
  pin_hash bytea,
  salt bytea,
  kdf_version smallint,
  cost integer,
  block_size integer,
  parallelization integer,
  credential_version uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_org uuid;
begin
  if not private.actor_can_read_operational_branch(actor_user_id, target_branch_id) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  select branch.organization_id into strict target_org
  from public.branches branch
  join public.organizations organization
    on organization.id = branch.organization_id
   and organization.active
  where branch.id = target_branch_id
    and branch.active;

  return query
    select access.organization_id, access.id, access.display_name, access.pin_hash, access.salt,
      access.kdf_version, access.cost, access.block_size, access.parallelization, access.credential_version
    from public.daily_audit_access_users access
    where access.organization_id = target_org
      and access.active
    order by access.id;
end;
$$;

create or replace function public.get_organization_manager_daily_audit_credentials(actor_user_id uuid, target_branch_id uuid)
returns table(
  organization_id uuid,
  manager_user_id uuid,
  display_name text,
  pin_hash bytea,
  salt bytea,
  kdf_version smallint,
  cost integer,
  block_size integer,
  parallelization integer,
  credential_version uuid
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.actor_can_read_operational_branch(actor_user_id, target_branch_id) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  return query
    select credential.organization_id, credential.manager_user_id,
      coalesce(nullif(btrim(profile.full_name), ''), 'Organization Manager') as display_name,
      credential.pin_hash, credential.salt, credential.kdf_version, credential.cost,
      credential.block_size, credential.parallelization, credential.credential_version
    from private.organization_manager_daily_audit_pins credential
    join public.branches branch
      on branch.organization_id = credential.organization_id
     and branch.id = target_branch_id
     and branch.active
    join public.organizations organization
      on organization.id = credential.organization_id
     and organization.active
    join public.organization_memberships membership
      on membership.organization_id = credential.organization_id
     and membership.user_id = credential.manager_user_id
     and membership.role = 'organization_manager'
    join public.profiles profile
      on profile.id = credential.manager_user_id
     and profile.disabled_at is null
     and not profile.must_change_password
    order by credential.manager_user_id;
end;
$$;

create or replace function public.record_organization_manager_daily_audit_access_grant(
  actor_user_id uuid,
  target_branch_id uuid,
  target_manager_user_id uuid,
  target_credential_version uuid
)
returns table(organization_id uuid, manager_user_id uuid, credential_version uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_org uuid;
begin
  if not private.actor_can_read_operational_branch(actor_user_id, target_branch_id) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  select branch.organization_id into strict target_org
  from public.branches branch
  join public.organizations organization
    on organization.id = branch.organization_id
   and organization.active
  where branch.id = target_branch_id
    and branch.active;

  if not exists (
    select 1
    from private.organization_manager_daily_audit_pins credential
    join public.organization_memberships membership
      on membership.organization_id = credential.organization_id
     and membership.user_id = credential.manager_user_id
     and membership.role = 'organization_manager'
    join public.profiles profile
      on profile.id = credential.manager_user_id
    where credential.organization_id = target_org
      and credential.manager_user_id = target_manager_user_id
      and credential.credential_version = target_credential_version
      and profile.disabled_at is null
      and not profile.must_change_password
  ) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    branch_id,
    action,
    details
  ) values (
    target_org,
    actor_user_id,
    target_manager_user_id,
    target_branch_id,
    'daily_audit_access_granted',
    jsonb_build_object('credential_version', target_credential_version)
  );

  return query select target_org, target_manager_user_id, target_credential_version;
end;
$$;

create or replace function public.validate_organization_manager_daily_audit_grant(
  actor_user_id uuid,
  target_branch_id uuid,
  target_manager_user_id uuid,
  target_credential_version uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.actor_can_read_operational_branch(actor_user_id, target_branch_id)
    and exists (
      select 1
      from private.organization_manager_daily_audit_pins credential
      join public.branches branch
        on branch.id = target_branch_id
       and branch.organization_id = credential.organization_id
       and branch.active
      join public.organizations organization
        on organization.id = credential.organization_id
       and organization.active
      join public.organization_memberships membership
        on membership.organization_id = credential.organization_id
       and membership.user_id = credential.manager_user_id
       and membership.role = 'organization_manager'
      join public.profiles profile
        on profile.id = credential.manager_user_id
       and profile.disabled_at is null
       and not profile.must_change_password
      where credential.manager_user_id = target_manager_user_id
        and credential.credential_version = target_credential_version
    );
$$;

revoke all on function public.get_daily_audit_access_user_credentials(uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_organization_manager_daily_audit_credentials(uuid, uuid) from public, anon, authenticated;
revoke all on function public.record_organization_manager_daily_audit_access_grant(uuid, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.validate_organization_manager_daily_audit_grant(uuid, uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.get_daily_audit_access_user_credentials(uuid, uuid) to service_role;
grant execute on function public.get_organization_manager_daily_audit_credentials(uuid, uuid) to service_role;
grant execute on function public.record_organization_manager_daily_audit_access_grant(uuid, uuid, uuid, uuid) to service_role;
grant execute on function public.validate_organization_manager_daily_audit_grant(uuid, uuid, uuid, uuid) to service_role;

commit;
