drop function if exists public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text);
drop function if exists public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text);

create function public.finalize_provisioned_maintenance_user(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_full_name_ar text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
  normalized_full_name_ar text := private.clean_optional_master_name(p_full_name_ar);
begin
  if p_full_name is null or pg_catalog.btrim(p_full_name) = '' or pg_catalog.length(pg_catalog.btrim(p_full_name)) > 120 then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;

  if not private.is_internal_admin(p_actor_user_id) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = p_organization_id and organization.active) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  update public.profiles
  set full_name = pg_catalog.regexp_replace(pg_catalog.btrim(p_full_name), '\s+', ' ', 'g'),
      full_name_ar = normalized_full_name_ar,
      must_change_password = true,
      disabled_at = null,
      updated_at = now()
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.maintenance_memberships(organization_id, user_id, active, created_by, updated_by)
  values(p_organization_id, p_new_user_id, true, p_actor_user_id, p_actor_user_id)
  on conflict(organization_id, user_id) do update
    set active = true, updated_by = excluded.updated_by, updated_at = now();

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'maintenance_user_created',
    pg_catalog.jsonb_build_object('new_status', 'active')
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create function public.finalize_provisioned_maintenance_user(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.finalize_provisioned_maintenance_user(p_actor_user_id, p_organization_id, p_new_user_id, p_full_name, null)
$$;

drop function if exists public.list_managed_maintenance_users(uuid, uuid);

create function public.list_managed_maintenance_users(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  full_name_ar text,
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
    select profile.id, profile.full_name, profile.full_name_ar, auth_user.email::text, membership.active,
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

revoke all on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.list_managed_maintenance_users(uuid, uuid) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text, text) to service_role;
grant execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) to service_role;
grant execute on function public.list_managed_maintenance_users(uuid, uuid) to service_role;
