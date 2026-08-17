create or replace function public.grant_existing_organization_manager(
  actor_user_id uuid,
  target_organization_id uuid,
  target_email text
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(target_email));
  target_auth_user auth.users%rowtype;
  saved public.organization_memberships%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if normalized_email is null or normalized_email = '' or pg_catalog.length(normalized_email) > 254 then
    raise exception 'invalid existing user email' using errcode = '22023';
  end if;

  select auth_user.* into target_auth_user
  from auth.users auth_user
  where pg_catalog.lower(auth_user.email::text) = normalized_email
  limit 1;

  if target_auth_user.id is null then
    raise exception 'existing user not found' using errcode = 'P0002';
  end if;

  if not exists(select 1 from public.profiles profile where profile.id = target_auth_user.id) then
    raise exception 'existing profile not found' using errcode = 'P0002';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_auth_user.id;

  insert into public.organization_memberships(organization_id, user_id, role, active)
  values(target_organization_id, target_auth_user.id, 'organization_manager', true)
  on conflict(organization_id, user_id) do update
    set role = 'organization_manager',
        active = true,
        updated_at = now()
  returning * into saved;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_auth_user.id,
    'user_enabled',
    pg_catalog.jsonb_build_object('role', 'organization_manager', 'new_status', 'active')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, saved.active, saved.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = saved.user_id;
end;
$$;

create or replace function public.reactivate_organization_manager(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.organization_memberships membership
  set active = true,
      updated_at = now()
  where membership.organization_id = target_organization_id
    and membership.user_id = target_user_id
    and membership.role = 'organization_manager';

  if not found then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_user_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_enabled',
    pg_catalog.jsonb_build_object('role', 'organization_manager', 'new_status', 'active')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, true, profile.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id;
end;
$$;

drop function if exists public.list_internal_admin_supervisors(uuid, uuid);

create or replace function public.list_internal_admin_supervisors(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  branches jsonb,
  active boolean,
  disabled boolean,
  must_change_password boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select profile.id, profile.full_name, auth_user.email::text,
      coalesce(jsonb_agg(distinct jsonb_build_object(
        'id', branch.id,
        'name', branch.name,
        'code', branch.code,
        'active', membership.active
      )) filter (where branch.id is not null), '[]'::jsonb) as branches,
      coalesce(pg_catalog.bool_or(membership.active), false) as active,
      profile.disabled_at is not null as disabled,
      profile.must_change_password,
      profile.created_at
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where branch.organization_id = target_organization_id
      and membership.role = 'branch_manager'
    group by profile.id, profile.full_name, auth_user.email, profile.disabled_at, profile.must_change_password, profile.created_at
    order by coalesce(pg_catalog.bool_or(membership.active), false) desc,
      profile.disabled_at is not null,
      pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

drop function if exists public.deactivate_internal_admin_supervisor(uuid, uuid, uuid);

create or replace function public.deactivate_internal_admin_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.branch_memberships membership
  set active = false,
      updated_at = now()
  from public.branches branch
  where branch.id = membership.branch_id
    and branch.organization_id = target_organization_id
    and membership.user_id = target_user_id
    and membership.role = 'branch_manager';
  get diagnostics changed_rows = row_count;

  if changed_rows = 0 then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.branch_supervisor_teams team
  set active = false,
      updated_at = now()
  where team.organization_id = target_organization_id
    and team.supervisor_user_id = target_user_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_disabled',
    pg_catalog.jsonb_build_object('role', 'branch_manager', 'new_status', 'inactive')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, false, now()
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id;
end;
$$;

create or replace function public.grant_existing_branch_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_email text,
  target_branch_ids uuid[]
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(target_email));
  target_auth_user auth.users%rowtype;
  assigned_branch_id uuid;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if normalized_email is null or normalized_email = '' or pg_catalog.length(normalized_email) > 254 then
    raise exception 'invalid existing user email' using errcode = '22023';
  end if;
  if target_branch_ids is null or pg_catalog.cardinality(target_branch_ids) = 0 then
    raise exception 'invalid branch assignment' using errcode = '22023';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.count(distinct item)
    from pg_catalog.unnest(target_branch_ids) as item
  ) then
    raise exception 'invalid branch assignment' using errcode = '22023';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.cardinality(target_branch_ids)
    from public.branches branch
    where branch.id = any(target_branch_ids)
      and branch.organization_id = target_organization_id
      and branch.active
  ) then
    raise exception 'invalid branch assignment' using errcode = '22023';
  end if;

  select auth_user.* into target_auth_user
  from auth.users auth_user
  where pg_catalog.lower(auth_user.email::text) = normalized_email
  limit 1;

  if target_auth_user.id is null then
    raise exception 'existing user not found' using errcode = 'P0002';
  end if;
  if not exists(select 1 from public.profiles profile where profile.id = target_auth_user.id) then
    raise exception 'existing profile not found' using errcode = 'P0002';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_auth_user.id;

  foreach assigned_branch_id in array target_branch_ids loop
    insert into public.branch_memberships(branch_id, user_id, role, active)
    values(assigned_branch_id, target_auth_user.id, 'branch_manager', true)
    on conflict(branch_id, user_id) do update
      set role = 'branch_manager',
          active = true,
          updated_at = now();

    update public.branch_supervisor_teams team
    set active = true,
        updated_at = now()
    where team.organization_id = target_organization_id
      and team.branch_id = assigned_branch_id
      and team.supervisor_user_id = target_auth_user.id;

    if not found then
      insert into public.branch_supervisor_teams(organization_id, branch_id, supervisor_user_id, active)
      values(target_organization_id, assigned_branch_id, target_auth_user.id, true);
    end if;
  end loop;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_auth_user.id,
    'user_enabled',
    pg_catalog.jsonb_build_object('role', 'branch_manager', 'branch_count', pg_catalog.cardinality(target_branch_ids))
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, true, now()
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_auth_user.id;
end;
$$;

create or replace function public.reactivate_internal_admin_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.branch_memberships membership
  set active = true,
      updated_at = now()
  from public.branches branch
  where branch.id = membership.branch_id
    and branch.organization_id = target_organization_id
    and membership.user_id = target_user_id
    and membership.role = 'branch_manager';
  get diagnostics changed_rows = row_count;

  if changed_rows = 0 then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_user_id;

  update public.branch_supervisor_teams team
  set active = true,
      updated_at = now()
  where team.organization_id = target_organization_id
    and team.supervisor_user_id = target_user_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_enabled',
    pg_catalog.jsonb_build_object('role', 'branch_manager', 'new_status', 'active')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, true, now()
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id;
end;
$$;

create or replace function public.grant_existing_maintenance_user(
  actor_user_id uuid,
  target_organization_id uuid,
  target_email text
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(target_email));
  target_auth_user auth.users%rowtype;
  saved public.maintenance_memberships%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  if normalized_email is null or normalized_email = '' or pg_catalog.length(normalized_email) > 254 then
    raise exception 'invalid existing user email' using errcode = '22023';
  end if;

  select auth_user.* into target_auth_user
  from auth.users auth_user
  where pg_catalog.lower(auth_user.email::text) = normalized_email
  limit 1;

  if target_auth_user.id is null then
    raise exception 'existing user not found' using errcode = 'P0002';
  end if;
  if not exists(select 1 from public.profiles profile where profile.id = target_auth_user.id) then
    raise exception 'existing profile not found' using errcode = 'P0002';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_auth_user.id;

  insert into public.maintenance_memberships(organization_id, user_id, active, created_by, updated_by)
  values(target_organization_id, target_auth_user.id, true, actor_user_id, actor_user_id)
  on conflict(organization_id, user_id) do update
    set active = true,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning * into saved;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_auth_user.id,
    'user_enabled',
    pg_catalog.jsonb_build_object('new_status', 'active')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, saved.active, saved.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = saved.user_id;
end;
$$;

create or replace function public.reactivate_maintenance_user(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved public.maintenance_memberships%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  update public.maintenance_memberships membership
  set active = true,
      updated_by = actor_user_id,
      updated_at = now()
  where membership.organization_id = target_organization_id
    and membership.user_id = target_user_id
  returning * into saved;

  if saved.user_id is null then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_user_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_enabled',
    pg_catalog.jsonb_build_object('new_status', 'active')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, saved.active, saved.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = saved.user_id;
end;
$$;

revoke all on function public.grant_existing_organization_manager(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.reactivate_organization_manager(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_internal_admin_supervisors(uuid, uuid) from public, anon, authenticated;
revoke all on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.grant_existing_branch_supervisor(uuid, uuid, text, uuid[]) from public, anon, authenticated;
revoke all on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.grant_existing_maintenance_user(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.reactivate_maintenance_user(uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.grant_existing_organization_manager(uuid, uuid, text) to service_role;
grant execute on function public.reactivate_organization_manager(uuid, uuid, uuid) to service_role;
grant execute on function public.list_internal_admin_supervisors(uuid, uuid) to service_role;
grant execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) to service_role;
grant execute on function public.grant_existing_branch_supervisor(uuid, uuid, text, uuid[]) to service_role;
grant execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) to service_role;
grant execute on function public.grant_existing_maintenance_user(uuid, uuid, text) to service_role;
grant execute on function public.reactivate_maintenance_user(uuid, uuid, uuid) to service_role;
