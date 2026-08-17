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
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
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

revoke all on function public.list_managed_maintenance_users(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_managed_maintenance_users(uuid, uuid) to service_role;
