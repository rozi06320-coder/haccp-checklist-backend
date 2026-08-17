alter table public.account_management_audit_logs
  drop constraint account_management_audit_logs_action_check;
alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created','user_disabled','user_enabled','temporary_password_reset','password_changed',
      'branch_assignment_added','branch_assignment_removed','branch_role_changed',
      'daily_audit_pin_configured','daily_audit_pin_replaced','daily_audit_access_granted',
      'branch_shift_created','branch_shift_updated','supervisor_team_assigned','supervisor_team_deactivated',
      'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
      'operational_staff_assignment_created','operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated','operational_staff_duty_changed'
    )
  );

create table private.organization_manager_daily_audit_pins (
  organization_id uuid not null,
  manager_user_id uuid not null,
  pin_hash bytea not null check (octet_length(pin_hash)=32),
  salt bytea not null check (octet_length(salt)=16),
  pin_fingerprint bytea not null check (octet_length(pin_fingerprint)=32),
  kdf_version smallint not null check (kdf_version=1),
  cost integer not null check (cost=16384),
  block_size integer not null check (block_size=8),
  parallelization integer not null check (parallelization=1),
  credential_version uuid not null default gen_random_uuid(),
  configured_at timestamptz not null default now(),
  configured_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (organization_id,manager_user_id),
  unique (organization_id,pin_fingerprint),
  foreign key (organization_id,manager_user_id)
    references public.organization_memberships(organization_id,user_id) on delete cascade
);
alter table private.organization_manager_daily_audit_pins enable row level security;
revoke all on table private.organization_manager_daily_audit_pins from public,anon,authenticated,service_role;

create function public.list_organization_manager_daily_audit_pins(actor_user_id uuid,target_organization_id uuid)
returns table(manager_user_id uuid,full_name text,email text,account_status text,configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path=''
as $$
begin
  if not exists(
    select 1 from public.organization_memberships membership
    join public.organizations organization on organization.id=membership.organization_id
    join public.profiles profile on profile.id=membership.user_id
    where membership.organization_id=target_organization_id and membership.user_id=actor_user_id
      and membership.role='organization_manager' and organization.active
      and profile.disabled_at is null and not profile.must_change_password
  ) then raise exception 'access denied' using errcode='42501'; end if;
  return query
    select membership.user_id,profile.full_name,auth_user.email::text,
      case when profile.must_change_password then 'password_change_required' else 'active' end,
      credential.manager_user_id is not null,credential.updated_at,updater.full_name
    from public.organization_memberships membership
    join public.profiles profile on profile.id=membership.user_id and profile.disabled_at is null
    join auth.users auth_user on auth_user.id=membership.user_id
    left join private.organization_manager_daily_audit_pins credential
      on credential.organization_id=membership.organization_id and credential.manager_user_id=membership.user_id
    left join public.profiles updater on updater.id=credential.updated_by
    where membership.organization_id=target_organization_id and membership.role='organization_manager'
    order by lower(coalesce(profile.full_name,'')),membership.user_id;
end $$;

create function public.store_organization_manager_daily_audit_pin(
  actor_user_id uuid,target_organization_id uuid,target_manager_user_id uuid,
  new_pin_hash bytea,new_salt bytea,new_pin_fingerprint bytea,
  new_kdf_version smallint,new_cost integer,new_block_size integer,new_parallelization integer
)
returns table(manager_user_id uuid,configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path=''
as $$
declare was_configured boolean; old_version uuid; saved_version uuid;
begin
  if not exists(
    select 1 from public.organization_memberships membership
    join public.organizations organization on organization.id=membership.organization_id
    join public.profiles profile on profile.id=membership.user_id
    where membership.organization_id=target_organization_id and membership.user_id=actor_user_id
      and membership.role='organization_manager' and organization.active
      and profile.disabled_at is null and not profile.must_change_password
  ) or not exists(
    select 1 from public.organization_memberships membership
    join public.profiles profile on profile.id=membership.user_id
    where membership.organization_id=target_organization_id and membership.user_id=target_manager_user_id
      and membership.role='organization_manager' and profile.disabled_at is null
  ) then raise exception 'access denied' using errcode='42501'; end if;
  if octet_length(new_pin_hash)<>32 or octet_length(new_salt)<>16 or octet_length(new_pin_fingerprint)<>32
    or new_kdf_version<>1 or new_cost<>16384 or new_block_size<>8 or new_parallelization<>1
  then raise exception 'invalid credential input' using errcode='22023'; end if;
  select credential_version into old_version from private.organization_manager_daily_audit_pins
    where organization_id=target_organization_id and manager_user_id=target_manager_user_id;
  was_configured := found;
  insert into private.organization_manager_daily_audit_pins(
    organization_id,manager_user_id,pin_hash,salt,pin_fingerprint,kdf_version,cost,block_size,
    parallelization,configured_by,updated_by
  ) values(
    target_organization_id,target_manager_user_id,new_pin_hash,new_salt,new_pin_fingerprint,
    new_kdf_version,new_cost,new_block_size,new_parallelization,actor_user_id,actor_user_id
  ) on conflict(organization_id,manager_user_id) do update set
    pin_hash=excluded.pin_hash,salt=excluded.salt,pin_fingerprint=excluded.pin_fingerprint,
    kdf_version=excluded.kdf_version,cost=excluded.cost,block_size=excluded.block_size,
    parallelization=excluded.parallelization,credential_version=gen_random_uuid(),
    updated_at=now(),updated_by=excluded.updated_by
  returning credential_version into saved_version;
  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  ) values(
    target_organization_id,actor_user_id,target_manager_user_id,
    case when was_configured then 'daily_audit_pin_replaced' else 'daily_audit_pin_configured' end,
    jsonb_build_object('previous_configured',was_configured,'new_configured',true,
      'previous_credential_version',old_version,'new_credential_version',saved_version)
  );
  return query select credential.manager_user_id,true,credential.updated_at,updater.full_name
    from private.organization_manager_daily_audit_pins credential
    left join public.profiles updater on updater.id=credential.updated_by
    where credential.organization_id=target_organization_id and credential.manager_user_id=target_manager_user_id;
end $$;

create function public.get_organization_manager_daily_audit_credentials(actor_user_id uuid,target_branch_id uuid)
returns table(organization_id uuid,manager_user_id uuid,pin_hash bytea,salt bytea,kdf_version smallint,cost integer,block_size integer,parallelization integer,credential_version uuid)
language plpgsql security definer set search_path=''
as $$
begin
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,null) then
    raise exception 'access denied' using errcode='42501';
  end if;
  return query
    select credential.organization_id,credential.manager_user_id,credential.pin_hash,credential.salt,
      credential.kdf_version,credential.cost,credential.block_size,credential.parallelization,credential.credential_version
    from private.organization_manager_daily_audit_pins credential
    join public.branches branch on branch.organization_id=credential.organization_id and branch.id=target_branch_id and branch.active
    join public.organizations organization on organization.id=credential.organization_id and organization.active
    join public.organization_memberships membership
      on membership.organization_id=credential.organization_id and membership.user_id=credential.manager_user_id
      and membership.role='organization_manager'
    join public.profiles profile on profile.id=credential.manager_user_id
      and profile.disabled_at is null and not profile.must_change_password
    order by credential.manager_user_id;
end $$;

create function public.record_organization_manager_daily_audit_access_grant(
  actor_user_id uuid,target_branch_id uuid,target_manager_user_id uuid,target_credential_version uuid
)
returns table(organization_id uuid,manager_user_id uuid,credential_version uuid)
language plpgsql security definer set search_path=''
as $$
declare target_org uuid;
begin
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,null) then
    raise exception 'access denied' using errcode='42501';
  end if;
  select branch.organization_id into strict target_org from public.branches branch
    join public.organizations organization on organization.id=branch.organization_id and organization.active
    where branch.id=target_branch_id and branch.active;
  if not exists(
    select 1 from private.organization_manager_daily_audit_pins credential
    join public.organization_memberships membership
      on membership.organization_id=credential.organization_id and membership.user_id=credential.manager_user_id
      and membership.role='organization_manager'
    join public.profiles profile on profile.id=credential.manager_user_id
    where credential.organization_id=target_org and credential.manager_user_id=target_manager_user_id
      and credential.credential_version=target_credential_version
      and profile.disabled_at is null and not profile.must_change_password
  ) then raise exception 'access denied' using errcode='42501'; end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,target_user_id,branch_id,action,details)
  values(target_org,actor_user_id,target_manager_user_id,target_branch_id,'daily_audit_access_granted',
    jsonb_build_object('credential_version',target_credential_version));
  return query select target_org,target_manager_user_id,target_credential_version;
end $$;

create function public.validate_organization_manager_daily_audit_grant(
  actor_user_id uuid,target_branch_id uuid,target_manager_user_id uuid,target_credential_version uuid
)
returns boolean language sql stable security definer set search_path=''
as $$
  select private.actor_owns_operational_team(actor_user_id,target_branch_id,null) and exists(
    select 1 from private.organization_manager_daily_audit_pins credential
    join public.branches branch on branch.id=target_branch_id and branch.organization_id=credential.organization_id and branch.active
    join public.organizations organization on organization.id=credential.organization_id and organization.active
    join public.organization_memberships membership
      on membership.organization_id=credential.organization_id and membership.user_id=credential.manager_user_id
      and membership.role='organization_manager'
    join public.profiles profile on profile.id=credential.manager_user_id
      and profile.disabled_at is null and not profile.must_change_password
    where credential.manager_user_id=target_manager_user_id and credential.credential_version=target_credential_version
  );
$$;

revoke all on function public.list_organization_manager_daily_audit_pins(uuid,uuid) from public,anon,authenticated;
revoke all on function public.store_organization_manager_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer) from public,anon,authenticated;
revoke all on function public.get_organization_manager_daily_audit_credentials(uuid,uuid) from public,anon,authenticated;
revoke all on function public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_organization_manager_daily_audit_pins(uuid,uuid) to service_role;
grant execute on function public.store_organization_manager_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer) to service_role;
grant execute on function public.get_organization_manager_daily_audit_credentials(uuid,uuid) to service_role;
grant execute on function public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid) to service_role;
