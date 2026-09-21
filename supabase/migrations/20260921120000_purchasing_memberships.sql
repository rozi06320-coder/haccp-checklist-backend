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
      'training_account_created',
      'training_account_updated',
      'training_account_deactivated',
      'training_account_reactivated',
      'training_account_password_reset',
      'branch_shift_created',
      'branch_shift_updated',
      'supervisor_team_assigned',
      'supervisor_team_deactivated',
      'supervisor_profile_updated',
      'operational_staff_created',
      'operational_staff_updated',
      'operational_staff_deactivated',
      'operational_staff_assignment_created',
      'operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated',
      'operational_staff_duty_changed',
      'organization_logo_updated',
      'branch_logo_updated',
      'operational_staff_supervisor_training_started',
      'operational_staff_supervisor_training_cancelled',
      'operational_staff_supervisor_training_promoted',
      'purchasing_user_created',
      'purchasing_membership_enabled',
      'purchasing_membership_disabled'
    )
  );

create table public.purchasing_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  active boolean not null default true,
  created_by uuid null references auth.users(id) on delete set null,
  updated_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchasing_memberships_organization_user_key unique (organization_id, user_id)
);

create index purchasing_memberships_organization_active_idx
  on public.purchasing_memberships(organization_id, active);

create index purchasing_memberships_user_active_idx
  on public.purchasing_memberships(user_id, active);

create trigger purchasing_memberships_set_updated_at
before update on public.purchasing_memberships
for each row execute function private.set_updated_at();

alter table public.purchasing_memberships enable row level security;

revoke all on table public.purchasing_memberships from public, anon, authenticated, service_role;
grant select on table public.purchasing_memberships to authenticated, service_role;

create function private.has_active_purchasing_membership(
  actor_user_id uuid,
  target_organization_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.purchasing_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.user_id = actor_user_id
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );
$$;

revoke all on function private.has_active_purchasing_membership(uuid, uuid) from public, anon, authenticated;
grant execute on function private.has_active_purchasing_membership(uuid, uuid) to authenticated;

create or replace function private.has_organization_access(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_organization_manager(target_organization_id)
  or private.has_active_purchasing_membership(auth.uid(), target_organization_id)
  or exists (
    select 1
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    join public.branch_memberships membership on membership.branch_id = branch.id
    where branch.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.role in ('staff', 'branch_manager')
      and membership.active
      and branch.active
      and organization.active
  )
  or exists (
    select 1
    from public.maintenance_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );
$$;

create policy purchasing_memberships_select_own_or_manager_or_internal_admin
on public.purchasing_memberships
for select
to authenticated
using (
  user_id = auth.uid()
  or private.is_organization_manager(organization_id)
  or private.is_internal_admin(auth.uid())
);

create function public.list_managed_purchasing_memberships(
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
  disabled boolean,
  created_at timestamptz,
  updated_at timestamptz,
  updated_by_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (
    private.is_internal_admin(actor_user_id)
    or exists (
      select 1
      from public.organization_memberships manager_membership
      join public.profiles manager_profile on manager_profile.id = manager_membership.user_id
      join public.organizations organization on organization.id = manager_membership.organization_id
      where manager_membership.organization_id = target_organization_id
        and manager_membership.user_id = actor_user_id
        and manager_membership.role = 'organization_manager'
        and manager_membership.active
        and organization.active
        and manager_profile.disabled_at is null
        and not manager_profile.must_change_password
    )
  ) then
    raise exception 'purchasing membership access denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'purchasing membership access denied' using errcode = '42501';
  end if;

  return query
    select profile.id, profile.full_name, profile.full_name_ar, auth_user.email::text,
      membership.active, profile.must_change_password, profile.disabled_at is not null,
      membership.created_at, membership.updated_at, updater.full_name
    from public.purchasing_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    left join public.profiles updater on updater.id = membership.updated_by
    where membership.organization_id = target_organization_id
    order by membership.active desc, profile.disabled_at is not null,
      pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

create function public.grant_existing_purchasing_membership(
  actor_user_id uuid,
  target_organization_id uuid,
  target_email text
)
returns table(id uuid, full_name text, email text, active boolean, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(target_email));
  target_auth_user auth.users%rowtype;
  saved public.purchasing_memberships%rowtype;
begin
  if normalized_email is null or normalized_email = '' or pg_catalog.length(normalized_email) > 254 then
    raise exception 'invalid existing user email' using errcode = '22023';
  end if;

  if not (
    private.is_internal_admin(actor_user_id)
    or exists (
      select 1
      from public.organization_memberships manager_membership
      join public.profiles manager_profile on manager_profile.id = manager_membership.user_id
      join public.organizations organization on organization.id = manager_membership.organization_id
      where manager_membership.organization_id = target_organization_id
        and manager_membership.user_id = actor_user_id
        and manager_membership.role = 'organization_manager'
        and manager_membership.active
        and organization.active
        and manager_profile.disabled_at is null
        and not manager_profile.must_change_password
    )
  ) then
    raise exception 'purchasing membership access denied' using errcode = '42501';
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

  insert into public.purchasing_memberships(organization_id, user_id, active, created_by, updated_by)
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
    'purchasing_membership_enabled',
    pg_catalog.jsonb_build_object('role', 'purchasing', 'new_status', 'active')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, saved.active, saved.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = saved.user_id;
end;
$$;

create function public.set_purchasing_membership_active(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  new_active boolean
)
returns table(id uuid, full_name text, email text, active boolean, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved public.purchasing_memberships%rowtype;
begin
  if not (
    private.is_internal_admin(actor_user_id)
    or exists (
      select 1
      from public.organization_memberships manager_membership
      join public.profiles manager_profile on manager_profile.id = manager_membership.user_id
      join public.organizations organization on organization.id = manager_membership.organization_id
      where manager_membership.organization_id = target_organization_id
        and manager_membership.user_id = actor_user_id
        and manager_membership.role = 'organization_manager'
        and manager_membership.active
        and organization.active
        and manager_profile.disabled_at is null
        and not manager_profile.must_change_password
    )
  ) then
    raise exception 'purchasing membership access denied' using errcode = '42501';
  end if;

  update public.purchasing_memberships membership
  set active = new_active,
      updated_by = actor_user_id,
      updated_at = now()
  where membership.organization_id = target_organization_id
    and membership.user_id = target_user_id
  returning * into saved;

  if saved.user_id is null then
    raise exception 'purchasing membership access denied' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    case when new_active then 'purchasing_membership_enabled' else 'purchasing_membership_disabled' end,
    pg_catalog.jsonb_build_object('role', 'purchasing', 'new_status', case when new_active then 'active' else 'inactive' end)
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, saved.active, saved.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = saved.user_id;
end;
$$;

create function public.finalize_provisioned_purchasing_user(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_full_name_ar text default null
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
      full_name_ar = nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_full_name_ar, '')), '\s+', ' ', 'g'), ''),
      must_change_password = true,
      disabled_at = null,
      updated_at = now()
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.purchasing_memberships(organization_id, user_id, active, created_by, updated_by)
  values(p_organization_id, p_new_user_id, true, p_actor_user_id, p_actor_user_id)
  on conflict(organization_id, user_id) do update
    set active = true,
        updated_by = excluded.updated_by,
        updated_at = now();

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'purchasing_user_created',
    pg_catalog.jsonb_build_object('role', 'purchasing', 'new_status', 'active')
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

revoke all on function public.list_managed_purchasing_memberships(uuid, uuid) from public, anon, authenticated;
revoke all on function public.grant_existing_purchasing_membership(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.set_purchasing_membership_active(uuid, uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.finalize_provisioned_purchasing_user(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.list_managed_purchasing_memberships(uuid, uuid) to service_role;
grant execute on function public.grant_existing_purchasing_membership(uuid, uuid, text) to service_role;
grant execute on function public.set_purchasing_membership_active(uuid, uuid, uuid, boolean) to service_role;
grant execute on function public.finalize_provisioned_purchasing_user(uuid, uuid, uuid, text, text) to service_role;
