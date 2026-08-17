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

create table public.maintenance_access_users (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  pin_hash bytea not null check (octet_length(pin_hash) = 32),
  salt bytea not null check (octet_length(salt) = 16),
  kdf_version smallint not null default 1 check (kdf_version = 1),
  cost integer not null default 16384 check (cost = 16384),
  block_size integer not null default 8 check (block_size = 8),
  parallelization integer not null default 1 check (parallelization = 1),
  credential_version uuid not null default gen_random_uuid(),
  active boolean not null default true,
  created_by uuid not null references auth.users(id),
  updated_by uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.maintenance_access_users enable row level security;
revoke all on table public.maintenance_access_users from public, anon, authenticated, service_role;

create unique index maintenance_access_users_active_name_key
  on public.maintenance_access_users(organization_id, lower(btrim(display_name)))
  where active;

create index maintenance_access_users_active_org_idx
  on public.maintenance_access_users(organization_id)
  where active;

create function public.list_maintenance_access_users(actor_user_id uuid, target_organization_id uuid)
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
    from public.maintenance_access_users access
    left join public.profiles updater on updater.id = access.updated_by
    where access.organization_id = target_organization_id
    order by access.active desc, lower(access.display_name), access.id
    limit 500;
end;
$$;

create function public.create_maintenance_access_user(
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
  saved public.maintenance_access_users%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or length(clean_name) = 0
    or length(clean_name) > 120
    or octet_length(new_pin_hash) <> 32
    or octet_length(new_salt) <> 16
    or new_kdf_version <> 1
    or new_cost <> 16384
    or new_block_size <> 8
    or new_parallelization <> 1
  then
    raise exception 'access denied' using errcode = '42501';
  end if;

  insert into public.maintenance_access_users(
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
    'maintenance_access_user_created',
    jsonb_build_object('access_user_id', saved.id, 'display_name', saved.display_name, 'new_status', 'active')
  );

  return query select saved.id, saved.organization_id, saved.display_name, saved.active, saved.created_at;
exception when unique_violation then
  raise exception 'maintenance access user already exists' using errcode = '23505';
end;
$$;

create function public.deactivate_maintenance_access_user(
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
  saved public.maintenance_access_users%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  update public.maintenance_access_users access
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
    'maintenance_access_user_deactivated',
    jsonb_build_object('access_user_id', saved.id, 'new_status', 'inactive')
  );

  return query select saved.id, saved.organization_id, saved.display_name, saved.active, saved.updated_at;
end;
$$;

revoke all on function public.list_maintenance_access_users(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_maintenance_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.deactivate_maintenance_access_user(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_maintenance_access_users(uuid, uuid) to service_role;
grant execute on function public.create_maintenance_access_user(uuid, uuid, text, bytea, bytea, smallint, integer, integer, integer) to service_role;
grant execute on function public.deactivate_maintenance_access_user(uuid, uuid, uuid) to service_role;
