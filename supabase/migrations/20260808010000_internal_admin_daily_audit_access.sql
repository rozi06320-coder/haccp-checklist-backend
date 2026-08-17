create function public.list_internal_admin_daily_audit_pins(actor_user_id uuid,target_organization_id uuid)
returns table(manager_user_id uuid,full_name text,email text,account_status text,configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path=''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id=target_organization_id and organization.active)
  then raise exception 'access denied' using errcode='42501'; end if;
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

create function public.store_internal_admin_daily_audit_pin(
  actor_user_id uuid,target_organization_id uuid,target_manager_user_id uuid,
  new_pin_hash bytea,new_salt bytea,new_pin_fingerprint bytea,
  new_kdf_version smallint,new_cost integer,new_block_size integer,new_parallelization integer
)
returns table(manager_user_id uuid,configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path=''
as $$
#variable_conflict use_column
declare was_configured boolean; old_version uuid; saved_version uuid;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id=target_organization_id and organization.active)
    or not exists(
      select 1 from public.organization_memberships membership
      join public.profiles profile on profile.id=membership.user_id
      where membership.organization_id=target_organization_id and membership.user_id=target_manager_user_id
        and membership.role='organization_manager' and profile.disabled_at is null
    )
  then raise exception 'access denied' using errcode='42501'; end if;
  if octet_length(new_pin_hash)<>32 or octet_length(new_salt)<>16 or octet_length(new_pin_fingerprint)<>32
    or new_kdf_version<>1 or new_cost<>16384 or new_block_size<>8 or new_parallelization<>1
  then raise exception 'invalid credential input' using errcode='22023'; end if;
  select credential.credential_version into old_version
    from private.organization_manager_daily_audit_pins credential
    where credential.organization_id=target_organization_id and credential.manager_user_id=target_manager_user_id;
  was_configured := found;
  insert into private.organization_manager_daily_audit_pins(
    organization_id,manager_user_id,pin_hash,salt,pin_fingerprint,kdf_version,cost,block_size,
    parallelization,configured_by,updated_by
  ) values(
    target_organization_id,target_manager_user_id,new_pin_hash,new_salt,new_pin_fingerprint,
    new_kdf_version,new_cost,new_block_size,new_parallelization,actor_user_id,actor_user_id
  ) on conflict on constraint organization_manager_daily_audit_pins_pkey do update set
    pin_hash=excluded.pin_hash,salt=excluded.salt,pin_fingerprint=excluded.pin_fingerprint,
    kdf_version=excluded.kdf_version,cost=excluded.cost,block_size=excluded.block_size,
    parallelization=excluded.parallelization,credential_version=gen_random_uuid(),
    updated_at=now(),updated_by=excluded.updated_by
  returning organization_manager_daily_audit_pins.credential_version into saved_version;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,target_user_id,action,details)
  values(
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

create function public.list_internal_admin_daily_audit_access_users(actor_user_id uuid, target_organization_id uuid)
returns table(id uuid,organization_id uuid,display_name text,active boolean,created_at timestamptz,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path=''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id=target_organization_id and organization.active)
  then raise exception 'access denied' using errcode='42501'; end if;
  return query
    select access.id, access.organization_id, access.display_name,
      access.active, access.created_at, access.updated_at, updater.full_name
    from public.daily_audit_access_users access
    left join public.profiles updater on updater.id = access.updated_by
    where access.organization_id = target_organization_id
    order by access.active desc, lower(access.display_name), access.id
    limit 500;
end $$;

create function public.create_internal_admin_daily_audit_access_user(
  actor_user_id uuid,
  target_organization_id uuid,
  access_display_name text,
  new_pin_hash bytea,
  new_salt bytea,
  new_kdf_version smallint,
  new_cost integer,
  new_block_size integer,
  new_parallelization integer
)
returns table(id uuid,organization_id uuid,display_name text,active boolean,created_at timestamptz)
language plpgsql security definer set search_path=''
as $$
declare
  clean_name text := regexp_replace(btrim(coalesce(access_display_name, '')), '\s+', ' ', 'g');
  saved public.daily_audit_access_users%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id=target_organization_id and organization.active)
    or length(clean_name) = 0 or length(clean_name) > 120
    or octet_length(new_pin_hash)<>32 or octet_length(new_salt)<>16
    or new_kdf_version<>1 or new_cost<>16384 or new_block_size<>8 or new_parallelization<>1
  then raise exception 'access denied' using errcode = '42501'; end if;
  insert into public.daily_audit_access_users(
    organization_id, display_name, pin_hash, salt, kdf_version, cost,
    block_size, parallelization, created_by, updated_by
  ) values(
    target_organization_id, clean_name, new_pin_hash, new_salt,
    new_kdf_version, new_cost, new_block_size, new_parallelization, actor_user_id, actor_user_id
  ) returning * into saved;
  insert into public.account_management_audit_logs(organization_id, actor_user_id, action, details)
  values(target_organization_id,actor_user_id,'daily_audit_access_user_created',
    jsonb_build_object('access_user_id', saved.id, 'display_name', saved.display_name, 'new_status', 'active'));
  return query select saved.id, saved.organization_id, saved.display_name, saved.active, saved.created_at;
exception when unique_violation then
  raise exception 'daily audit access user already exists' using errcode = '23505';
end $$;

create function public.revoke_internal_admin_daily_audit_access_user(
  actor_user_id uuid,
  target_organization_id uuid,
  target_access_user_id uuid
)
returns table(id uuid,organization_id uuid,display_name text,active boolean,updated_at timestamptz)
language plpgsql security definer set search_path=''
as $$
declare saved public.daily_audit_access_users%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id=target_organization_id and organization.active)
  then raise exception 'access denied' using errcode = '42501'; end if;
  update public.daily_audit_access_users access
  set active = false, updated_at = now(), updated_by = actor_user_id, credential_version = gen_random_uuid()
  where access.id = target_access_user_id and access.organization_id = target_organization_id
  returning * into saved;
  if saved.id is null then raise exception 'access denied' using errcode = '42501'; end if;
  insert into public.account_management_audit_logs(organization_id, actor_user_id, action, details)
  values(saved.organization_id, actor_user_id, 'daily_audit_access_user_revoked',
    jsonb_build_object('access_user_id', saved.id, 'new_status', 'inactive'));
  return query select saved.id, saved.organization_id, saved.display_name, saved.active, saved.updated_at;
end $$;

revoke all on function public.list_internal_admin_daily_audit_pins(uuid,uuid) from public,anon,authenticated;
revoke all on function public.store_internal_admin_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer) from public,anon,authenticated;
revoke all on function public.list_internal_admin_daily_audit_access_users(uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_internal_admin_daily_audit_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer) from public,anon,authenticated;
revoke all on function public.revoke_internal_admin_daily_audit_access_user(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_internal_admin_daily_audit_pins(uuid,uuid) to service_role;
grant execute on function public.store_internal_admin_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer) to service_role;
grant execute on function public.list_internal_admin_daily_audit_access_users(uuid,uuid) to service_role;
grant execute on function public.create_internal_admin_daily_audit_access_user(uuid,uuid,text,bytea,bytea,smallint,integer,integer,integer) to service_role;
grant execute on function public.revoke_internal_admin_daily_audit_access_user(uuid,uuid,uuid) to service_role;
