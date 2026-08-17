drop function if exists public.list_daily_audit_access_users(uuid, uuid);
drop function if exists public.create_daily_audit_access_user(uuid, uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer);
drop function if exists public.revoke_daily_audit_access_user(uuid, uuid, uuid);
drop function if exists public.get_daily_audit_access_user_credentials(uuid, uuid);

drop index if exists public.daily_audit_access_users_active_name_key;
drop index if exists public.daily_audit_access_users_active_branch_idx;

alter table public.daily_audit_access_users
  drop constraint if exists daily_audit_access_users_organization_id_branch_id_fkey,
  drop constraint if exists daily_audit_access_users_branch_id_fkey,
  drop column if exists branch_id;

create unique index daily_audit_access_users_active_name_key
  on public.daily_audit_access_users(organization_id, lower(btrim(display_name)))
  where active;

create index daily_audit_access_users_active_org_idx
  on public.daily_audit_access_users(organization_id)
  where active;

create function public.list_daily_audit_access_users(actor_user_id uuid, target_organization_id uuid)
returns table(
  id uuid,
  organization_id uuid,
  display_name text,
  active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  updated_by_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  return query
    select access.id, access.organization_id, access.display_name,
      access.active, access.created_at, access.updated_at, updater.full_name
    from public.daily_audit_access_users access
    left join public.profiles updater on updater.id = access.updated_by
    where access.organization_id = target_organization_id
    order by access.active desc, lower(access.display_name), access.id
    limit 500;
end;
$$;

create function public.create_daily_audit_access_user(
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
returns table(
  id uuid,
  organization_id uuid,
  display_name text,
  active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_name text := regexp_replace(btrim(coalesce(access_display_name, '')), '\s+', ' ', 'g');
  saved public.daily_audit_access_users%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or length(clean_name) = 0
    or length(clean_name) > 120
    or octet_length(new_pin_hash)<>32
    or octet_length(new_salt)<>16
    or new_kdf_version<>1
    or new_cost<>16384
    or new_block_size<>8
    or new_parallelization<>1
  then
    raise exception 'access denied' using errcode = '42501';
  end if;

  insert into public.daily_audit_access_users(
    organization_id, display_name, pin_hash, salt, kdf_version, cost,
    block_size, parallelization, created_by, updated_by
  ) values(
    target_organization_id, clean_name, new_pin_hash, new_salt,
    new_kdf_version, new_cost, new_block_size, new_parallelization, actor_user_id, actor_user_id
  ) returning * into saved;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    'daily_audit_access_user_created',
    jsonb_build_object('access_user_id', saved.id, 'display_name', saved.display_name, 'new_status', 'active')
  );

  return query select saved.id, saved.organization_id, saved.display_name, saved.active, saved.created_at;
exception when unique_violation then
  raise exception 'daily audit access user already exists' using errcode = '23505';
end;
$$;

create function public.revoke_daily_audit_access_user(
  actor_user_id uuid,
  target_organization_id uuid,
  target_access_user_id uuid
)
returns table(
  id uuid,
  organization_id uuid,
  display_name text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved public.daily_audit_access_users%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  update public.daily_audit_access_users access
  set active = false, updated_at = now(), updated_by = actor_user_id, credential_version = gen_random_uuid()
  where access.id = target_access_user_id
    and access.organization_id = target_organization_id
  returning * into saved;

  if saved.id is null then
    raise exception 'access denied' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, action, details)
  values(
    saved.organization_id,
    actor_user_id,
    'daily_audit_access_user_revoked',
    jsonb_build_object('access_user_id', saved.id, 'new_status', 'inactive')
  );

  return query select saved.id, saved.organization_id, saved.display_name, saved.active, saved.updated_at;
end;
$$;

create function public.get_daily_audit_access_user_credentials(actor_user_id uuid, target_branch_id uuid)
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
  if not private.actor_owns_operational_team(actor_user_id, target_branch_id, null) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  select branch.organization_id into strict target_org
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id and organization.active
  where branch.id = target_branch_id and branch.active;

  return query
    select access.organization_id, access.id, access.display_name, access.pin_hash, access.salt,
      access.kdf_version, access.cost, access.block_size, access.parallelization, access.credential_version
    from public.daily_audit_access_users access
    where access.organization_id = target_org
      and access.active
    order by access.id;
end;
$$;

revoke all on function public.list_daily_audit_access_users(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.revoke_daily_audit_access_user(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_daily_audit_access_user_credentials(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_daily_audit_access_users(uuid, uuid) to service_role;
grant execute on function public.create_daily_audit_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) to service_role;
grant execute on function public.revoke_daily_audit_access_user(uuid, uuid, uuid) to service_role;
grant execute on function public.get_daily_audit_access_user_credentials(uuid, uuid) to service_role;
