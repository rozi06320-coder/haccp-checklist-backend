create or replace function public.list_managed_maintenance_users(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  must_change_password boolean,
  created_at timestamptz,
  updated_at timestamptz,
  updated_by_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  return query
    select profile.id, profile.full_name, auth_user.email::text, membership.active,
      profile.must_change_password, membership.created_at, membership.updated_at, updater.full_name
    from public.maintenance_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    left join public.profiles updater on updater.id = membership.updated_by
    where membership.organization_id = target_organization_id
    order by membership.active desc, pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

create or replace function public.deactivate_maintenance_user(
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
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  update public.maintenance_memberships membership
  set active = false, updated_by = actor_user_id, updated_at = now()
  where membership.organization_id = target_organization_id
    and membership.user_id = target_user_id
  returning * into saved;

  if saved.user_id is null then
    raise exception 'maintenance user access denied' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'maintenance_user_deactivated',
    pg_catalog.jsonb_build_object('new_status', 'inactive')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, saved.active, saved.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = saved.user_id;
end;
$$;

revoke all on function public.list_managed_maintenance_users(uuid, uuid) from public, anon, authenticated;
revoke all on function public.deactivate_maintenance_user(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_managed_maintenance_users(uuid, uuid) to service_role;
grant execute on function public.deactivate_maintenance_user(uuid, uuid, uuid) to service_role;
