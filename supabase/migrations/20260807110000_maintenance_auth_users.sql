alter table public.account_management_audit_logs
  drop constraint if exists account_management_audit_logs_action_check;

alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created',
      'user_disabled',
      'user_enabled',
      'temporary_password_reset',
      'password_changed',
      'branch_created',
      'branch_assignment_added',
      'branch_assignment_removed',
      'branch_role_changed',
      'daily_audit_pin_configured',
      'daily_audit_pin_replaced',
      'daily_audit_access_granted',
      'daily_audit_user_access_granted',
      'daily_audit_user_access_revoked',
      'daily_audit_access_user_created',
      'daily_audit_access_user_revoked',
      'maintenance_access_user_created',
      'maintenance_access_user_deactivated',
      'maintenance_user_created',
      'maintenance_user_deactivated',
      'branch_shift_created',
      'branch_shift_updated',
      'supervisor_team_assigned',
      'supervisor_team_deactivated',
      'operational_staff_created',
      'operational_staff_updated',
      'operational_staff_deactivated',
      'operational_staff_assignment_created',
      'operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated',
      'operational_staff_duty_changed'
    )
  );

create table public.maintenance_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

alter table public.maintenance_memberships enable row level security;
revoke all on table public.maintenance_memberships from public, anon, authenticated, service_role;
grant select on table public.maintenance_memberships to authenticated;

create index maintenance_memberships_user_id_idx
  on public.maintenance_memberships(user_id)
  where active;

create trigger maintenance_memberships_set_updated_at
before update on public.maintenance_memberships
for each row execute function private.set_updated_at();

create policy maintenance_memberships_select_own_or_manager
on public.maintenance_memberships
for select
to authenticated
using (
  user_id = auth.uid()
  or private.is_organization_manager(organization_id)
);

create function private.actor_has_active_maintenance_membership(actor uuid, target_organization uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles profile
    join public.maintenance_memberships membership on membership.user_id = profile.id
    join public.organizations organization on organization.id = membership.organization_id
    where profile.id = actor
      and profile.disabled_at is null
      and not profile.must_change_password
      and membership.active
      and organization.active
      and (target_organization is null or membership.organization_id = target_organization)
  );
$$;

revoke all on function private.actor_has_active_maintenance_membership(uuid, uuid) from public, anon, authenticated;

create function public.finalize_provisioned_maintenance_user(
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

  if not private.actor_manages_active_organization(p_actor_user_id, p_organization_id) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  update public.profiles
  set full_name = pg_catalog.regexp_replace(pg_catalog.btrim(p_full_name), '\s+', ' ', 'g'),
      must_change_password = true,
      disabled_at = null
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

create function public.list_managed_maintenance_users(
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

create function public.deactivate_maintenance_user(
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
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
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

revoke all on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.list_managed_maintenance_users(uuid, uuid) from public, anon, authenticated;
revoke all on function public.deactivate_maintenance_user(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_maintenance_user(uuid, uuid, uuid, text) to service_role;
grant execute on function public.list_managed_maintenance_users(uuid, uuid) to service_role;
grant execute on function public.deactivate_maintenance_user(uuid, uuid, uuid) to service_role;
