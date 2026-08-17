alter table public.organization_memberships
  add column if not exists active boolean not null default true;

create index if not exists organization_memberships_active_user_idx
  on public.organization_memberships(user_id, active);

create or replace function private.is_organization_manager(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.role = 'organization_manager'
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );
$$;

create or replace function private.has_branch_access(target_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.branch_memberships membership
    where membership.branch_id = target_branch_id
      and membership.user_id = auth.uid()
      and membership.role in ('staff', 'branch_manager')
  )
  or exists (
    select 1
    from public.branches branch
    join public.organization_memberships membership
      on membership.organization_id = branch.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where branch.id = target_branch_id
      and membership.user_id = auth.uid()
      and membership.role = 'organization_manager'
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );
$$;

create function public.finalize_provisioned_organization_manager(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if p_full_name is null or pg_catalog.btrim(p_full_name) = '' or pg_catalog.length(pg_catalog.btrim(p_full_name)) > 120 then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;

  if not private.is_internal_admin(p_actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = p_organization_id and organization.active)
  then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  update public.profiles
  set full_name = pg_catalog.regexp_replace(pg_catalog.btrim(p_full_name), '\s+', ' ', 'g'),
      must_change_password = true,
      disabled_at = null,
      updated_at = now()
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.organization_memberships(organization_id, user_id, role, active)
  values(p_organization_id, p_new_user_id, 'organization_manager', true)
  on conflict(organization_id, user_id) do update
    set role = 'organization_manager',
        active = true,
        updated_at = now();

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'user_created',
    pg_catalog.jsonb_build_object('role', 'organization_manager', 'new_status', 'active')
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create function public.list_internal_admin_organization_managers(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  organization_id uuid,
  organization_name text,
  active boolean,
  must_change_password boolean,
  disabled boolean,
  created_at timestamptz,
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

  return query
    select profile.id, profile.full_name, auth_user.email::text,
      organization.id, organization.name, membership.active,
      profile.must_change_password,
      profile.disabled_at is not null as disabled,
      profile.created_at,
      membership.updated_at
    from public.organization_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.role = 'organization_manager'
    order by membership.active desc, profile.disabled_at is not null,
      pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

create function public.deactivate_organization_manager(
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
  saved public.organization_memberships%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.organization_memberships membership
  set active = false,
      updated_at = now()
  where membership.organization_id = target_organization_id
    and membership.user_id = target_user_id
    and membership.role = 'organization_manager'
  returning * into saved;

  if saved.user_id is null then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_disabled',
    pg_catalog.jsonb_build_object('role', 'organization_manager', 'new_status', 'inactive')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, saved.active, saved.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = saved.user_id;
end;
$$;

revoke all on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.list_internal_admin_organization_managers(uuid, uuid) from public, anon, authenticated;
revoke all on function public.deactivate_organization_manager(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) to service_role;
grant execute on function public.list_internal_admin_organization_managers(uuid, uuid) to service_role;
grant execute on function public.deactivate_organization_manager(uuid, uuid, uuid) to service_role;
