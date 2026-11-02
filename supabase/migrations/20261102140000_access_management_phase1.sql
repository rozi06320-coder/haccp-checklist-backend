begin;

-- Phase 1 Access Management: Unified Supervisor & Training Supervisor Assignment
-- Additive forward-only migration.
-- Strictly preserves existing branch_manager workflows and training PIN access.

do $preflight$
begin
  if pg_catalog.to_regclass('public.organizations') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.profiles') is null
    or pg_catalog.to_regclass('public.branch_memberships') is null
    or pg_catalog.to_regclass('public.training_memberships') is null
    or pg_catalog.to_regclass('public.training_membership_branches') is null
    or pg_catalog.to_regclass('public.account_management_audit_logs') is null
    or pg_catalog.to_regprocedure('private.is_internal_admin(uuid)') is null
  then
    raise exception 'access management phase 1 prerequisites are missing' using errcode = '42883';
  end if;

  if pg_catalog.to_regprocedure('public.list_internal_admin_access_assignments(uuid,uuid,uuid,text,text)') is not null then
    raise exception 'access management phase 1 is already installed' using errcode = '42710';
  end if;
end
$preflight$;

-- 1. Additive columns on public.training_memberships
alter table public.training_memberships
  add column if not exists training_role text not null default 'training_supervisor',
  add column if not exists credential_version uuid not null default gen_random_uuid();

do $guard_constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'training_memberships_training_role_check'
      and conrelid = 'public.training_memberships'::regclass
  ) then
    alter table public.training_memberships
      add constraint training_memberships_training_role_check
      check (training_role in ('training_supervisor'));
  end if;
end
$guard_constraints$;

-- 2. Expand account_management_audit_logs action check constraint
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
      'training_supervisor_granted',
      'training_supervisor_suspended',
      'training_supervisor_reactivated',
      'training_supervisor_revoked',
      'training_supervisor_reassigned',
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
      'purchasing_membership_disabled',
      'supervisor_demoted_to_staff'
    )
  );

-- 3. Enforce mutual exclusivity at database level between active Supervisor and active Training Supervisor
create or replace function private.enforce_access_assignment_mutual_exclusivity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_user_id uuid;
  target_organization_id uuid;
begin
  if tg_table_name = 'branch_memberships' then
    target_user_id := new.user_id;
    select branch.organization_id into target_organization_id
    from public.branches branch
    where branch.id = new.branch_id;
  elsif tg_table_name = 'training_memberships' then
    target_user_id := new.user_id;
    target_organization_id := new.organization_id;
  end if;

  if target_user_id is not null and target_organization_id is not null then
    if exists (
      select 1
      from public.branch_memberships bm
      join public.branches b on b.id = bm.branch_id
      where b.organization_id = target_organization_id
        and bm.user_id = target_user_id
        and bm.role = 'branch_manager'
        and bm.active
    ) and exists (
      select 1
      from public.training_memberships tm
      where tm.organization_id = target_organization_id
        and tm.user_id = target_user_id
        and tm.training_role = 'training_supervisor'
        and tm.active
    ) then
      raise exception 'account cannot simultaneously hold active supervisor and training supervisor roles'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists branch_memberships_access_assignment_exclusivity on public.branch_memberships;
create trigger branch_memberships_access_assignment_exclusivity
  after insert or update of role, active, branch_id on public.branch_memberships
  for each row execute function private.enforce_access_assignment_mutual_exclusivity();

drop trigger if exists training_memberships_access_assignment_exclusivity on public.training_memberships;
create trigger training_memberships_access_assignment_exclusivity
  after insert or update of active, organization_id, training_role on public.training_memberships
  for each row execute function private.enforce_access_assignment_mutual_exclusivity();

-- 4. Unified Read/Filter RPC for Internal Admin Access Assignments
create or replace function public.list_internal_admin_access_assignments(
  actor_user_id uuid,
  target_organization_id uuid,
  filter_branch_id uuid default null,
  filter_access_type text default null,
  filter_status text default null
)
returns table(
  assignment_id uuid,
  user_id uuid,
  full_name text,
  full_name_ar text,
  email text,
  phone_number text,
  access_type text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  status text,
  must_change_password boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'access assignments access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations org
    where org.id = target_organization_id
      and org.active
  ) then
    raise exception 'access assignments access denied' using errcode = '42501';
  end if;

  if filter_access_type is not null and filter_access_type not in ('supervisor', 'training_supervisor') then
    raise exception 'invalid access type filter' using errcode = '22023';
  end if;

  if filter_status is not null and filter_status not in ('active', 'suspended', 'revoked', 'unassigned') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;

  return query
  with supervisor_rows as (
    select
      bm.branch_id as assignment_id,
      p.id as user_id,
      p.full_name,
      p.full_name_ar,
      u.email::text,
      p.phone_number,
      'supervisor'::text as access_type,
      b.id as branch_id,
      b.name as branch_name,
      b.name_ar as branch_name_ar,
      b.code as branch_code,
      case
        when p.disabled_at is not null or not bm.active then 'suspended'
        else 'active'
      end as status,
      p.must_change_password,
      bm.created_at,
      bm.updated_at
    from public.branch_memberships bm
    join public.branches b on b.id = bm.branch_id
    join public.profiles p on p.id = bm.user_id
    join auth.users u on u.id = p.id
    where b.organization_id = target_organization_id
      and bm.role = 'branch_manager'
  ),
  training_supervisor_rows as (
    select
      tmb.branch_id as assignment_id,
      p.id as user_id,
      p.full_name,
      p.full_name_ar,
      u.email::text,
      p.phone_number,
      'training_supervisor'::text as access_type,
      b.id as branch_id,
      b.name as branch_name,
      b.name_ar as branch_name_ar,
      b.code as branch_code,
      case
        when p.disabled_at is not null or not tm.active then 'suspended'
        when tmb.branch_id is null then 'unassigned'
        else 'active'
      end as status,
      p.must_change_password,
      tm.created_at,
      tm.updated_at
    from public.training_memberships tm
    join public.profiles p on p.id = tm.user_id
    join auth.users u on u.id = p.id
    left join public.training_membership_branches tmb
      on tmb.organization_id = tm.organization_id
     and tmb.user_id = tm.user_id
    left join public.branches b
      on b.id = tmb.branch_id
     and b.organization_id = tm.organization_id
    where tm.organization_id = target_organization_id
      and tm.training_role = 'training_supervisor'
  ),
  combined as (
    select * from supervisor_rows
    union all
    select * from training_supervisor_rows
  )
  select c.*
  from combined c
  where (filter_branch_id is null or c.branch_id = filter_branch_id)
    and (filter_access_type is null or c.access_type = filter_access_type)
    and (filter_status is null or c.status = filter_status)
  order by
    c.status = 'active' desc,
    c.access_type,
    pg_catalog.lower(coalesce(c.full_name, c.email)),
    c.user_id;
end;
$$;

-- 5. Training Supervisor Operations: Grant
create or replace function public.grant_internal_admin_training_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  target_branch_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  branch_count integer;
  target_profile public.profiles%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations org
    where org.id = target_organization_id
      and org.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if target_user_id is null or target_branch_ids is null or pg_catalog.cardinality(target_branch_ids) = 0 then
    raise exception 'invalid training supervisor parameters' using errcode = '22023';
  end if;

  -- Validate target profile
  select * into target_profile
  from public.profiles p
  where p.id = target_user_id;

  if target_profile.id is null then
    raise exception 'target user profile not found' using errcode = 'P0002';
  end if;

  -- Enforce mutual exclusivity: user cannot already be an active branch_manager in this organization
  if exists (
    select 1
    from public.branch_memberships bm
    join public.branches b on b.id = bm.branch_id
    where b.organization_id = target_organization_id
      and bm.user_id = target_user_id
      and bm.role = 'branch_manager'
      and bm.active
  ) then
    raise exception 'account holds an active supervisor role; transition must be explicitly demoted or revoked first'
      using errcode = '23514';
  end if;

  -- Validate branch scope within active target organization
  select count(*)::integer into branch_count
  from public.branches b
  where b.organization_id = target_organization_id
    and b.id = any(target_branch_ids)
    and b.active;

  if branch_count <> pg_catalog.cardinality(target_branch_ids) then
    raise exception 'one or more target branches are invalid or inactive' using errcode = '22023';
  end if;

  -- Upsert training_memberships record
  insert into public.training_memberships(
    organization_id,
    user_id,
    account_name,
    active,
    created_by,
    updated_by,
    training_role,
    credential_version,
    created_at,
    updated_at
  )
  values (
    target_organization_id,
    target_user_id,
    coalesce(nullif(pg_catalog.btrim(target_profile.full_name), ''), 'Training Supervisor'),
    true,
    actor_user_id,
    actor_user_id,
    'training_supervisor',
    gen_random_uuid(),
    now(),
    now()
  )
  on conflict (organization_id, user_id)
  do update set
    active = true,
    training_role = 'training_supervisor',
    credential_version = gen_random_uuid(),
    updated_by = actor_user_id,
    updated_at = now();

  -- Replace branch associations atomically
  delete from public.training_membership_branches
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.training_membership_branches(organization_id, user_id, branch_id, created_at, updated_at)
  select target_organization_id, target_user_id, branch_id, now(), now()
  from unnest(target_branch_ids) as branch_id;

  -- Audit log
  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    action,
    details
  )
  values (
    target_organization_id,
    actor_user_id,
    target_user_id,
    'training_supervisor_granted',
    pg_catalog.jsonb_build_object(
      'access_type', 'training_supervisor',
      'branch_count', pg_catalog.cardinality(target_branch_ids),
      'branch_ids', to_jsonb(target_branch_ids)
    )
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

-- 6. Training Supervisor Operations: Suspend
create or replace function public.suspend_internal_admin_training_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_membership public.training_memberships%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations org
    where org.id = target_organization_id
      and org.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  select * into found_membership
  from public.training_memberships tm
  where tm.organization_id = target_organization_id
    and tm.user_id = target_user_id
  for update;

  if found_membership.user_id is null then
    raise exception 'training supervisor assignment not found' using errcode = 'P0002';
  end if;

  -- Suspend and rotate credential_version to invalidate active sessions immediately
  update public.training_memberships
  set active = false,
      credential_version = gen_random_uuid(),
      updated_by = actor_user_id,
      updated_at = now()
  where organization_id = target_organization_id
    and user_id = target_user_id;

  -- Audit log
  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    action,
    details
  )
  values (
    target_organization_id,
    actor_user_id,
    target_user_id,
    'training_supervisor_suspended',
    pg_catalog.jsonb_build_object(
      'access_type', 'training_supervisor',
      'previous_active', found_membership.active
    )
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

-- 7. Training Supervisor Operations: Reactivate
create or replace function public.reactivate_internal_admin_training_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  target_branch_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_membership public.training_memberships%rowtype;
  branch_count integer;
  effective_branch_ids uuid[];
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations org
    where org.id = target_organization_id
      and org.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  select * into found_membership
  from public.training_memberships tm
  where tm.organization_id = target_organization_id
    and tm.user_id = target_user_id
  for update;

  if found_membership.user_id is null then
    raise exception 'training supervisor assignment not found' using errcode = 'P0002';
  end if;

  -- Check mutual exclusivity: cannot reactivate if user is currently an active branch manager
  if exists (
    select 1
    from public.branch_memberships bm
    join public.branches b on b.id = bm.branch_id
    where b.organization_id = target_organization_id
      and bm.user_id = target_user_id
      and bm.role = 'branch_manager'
      and bm.active
  ) then
    raise exception 'account holds an active supervisor role; transition must be explicitly demoted or revoked first'
      using errcode = '23514';
  end if;

  if target_branch_ids is not null and pg_catalog.cardinality(target_branch_ids) > 0 then
    select count(*)::integer into branch_count
    from public.branches b
    where b.organization_id = target_organization_id
      and b.id = any(target_branch_ids)
      and b.active;

    if branch_count <> pg_catalog.cardinality(target_branch_ids) then
      raise exception 'one or more target branches are invalid or inactive' using errcode = '22023';
    end if;

    delete from public.training_membership_branches
    where organization_id = target_organization_id
      and user_id = target_user_id;

    insert into public.training_membership_branches(organization_id, user_id, branch_id, created_at, updated_at)
    select target_organization_id, target_user_id, branch_id, now(), now()
    from unnest(target_branch_ids) as branch_id;

    effective_branch_ids := target_branch_ids;
  else
    select coalesce(pg_catalog.array_agg(branch_id), array[]::uuid[]) into effective_branch_ids
    from public.training_membership_branches
    where organization_id = target_organization_id
      and user_id = target_user_id;

    if pg_catalog.cardinality(effective_branch_ids) = 0 then
      raise exception 'cannot reactivate training supervisor without assigned branches' using errcode = '22023';
    end if;
  end if;

  update public.training_memberships
  set active = true,
      credential_version = gen_random_uuid(),
      updated_by = actor_user_id,
      updated_at = now()
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    action,
    details
  )
  values (
    target_organization_id,
    actor_user_id,
    target_user_id,
    'training_supervisor_reactivated',
    pg_catalog.jsonb_build_object(
      'access_type', 'training_supervisor',
      'branch_count', pg_catalog.cardinality(effective_branch_ids)
    )
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

-- 8. Training Supervisor Operations: Revoke
create or replace function public.revoke_internal_admin_training_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  found_membership public.training_memberships%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations org
    where org.id = target_organization_id
      and org.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  select * into found_membership
  from public.training_memberships tm
  where tm.organization_id = target_organization_id
    and tm.user_id = target_user_id
  for update;

  if found_membership.user_id is null then
    raise exception 'training supervisor assignment not found' using errcode = 'P0002';
  end if;

  -- Remove all assigned branches
  delete from public.training_membership_branches
  where organization_id = target_organization_id
    and user_id = target_user_id;

  -- Mark inactive and rotate credential_version
  update public.training_memberships
  set active = false,
      credential_version = gen_random_uuid(),
      updated_by = actor_user_id,
      updated_at = now()
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    action,
    details
  )
  values (
    target_organization_id,
    actor_user_id,
    target_user_id,
    'training_supervisor_revoked',
    pg_catalog.jsonb_build_object(
      'access_type', 'training_supervisor'
    )
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

-- 9. Training Supervisor Operations: Reassign Branches
create or replace function public.reassign_internal_admin_training_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  target_branch_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  branch_count integer;
  found_membership public.training_memberships%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations org
    where org.id = target_organization_id
      and org.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if target_user_id is null or target_branch_ids is null or pg_catalog.cardinality(target_branch_ids) = 0 then
    raise exception 'invalid branch reassignment parameters' using errcode = '22023';
  end if;

  select * into found_membership
  from public.training_memberships tm
  where tm.organization_id = target_organization_id
    and tm.user_id = target_user_id
  for update;

  if found_membership.user_id is null then
    raise exception 'training supervisor assignment not found' using errcode = 'P0002';
  end if;

  select count(*)::integer into branch_count
  from public.branches b
  where b.organization_id = target_organization_id
    and b.id = any(target_branch_ids)
    and b.active;

  if branch_count <> pg_catalog.cardinality(target_branch_ids) then
    raise exception 'one or more target branches are invalid or inactive' using errcode = '22023';
  end if;

  delete from public.training_membership_branches
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.training_membership_branches(organization_id, user_id, branch_id, created_at, updated_at)
  select target_organization_id, target_user_id, branch_id, now(), now()
  from unnest(target_branch_ids) as branch_id;

  update public.training_memberships
  set credential_version = gen_random_uuid(),
      updated_by = actor_user_id,
      updated_at = now()
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    action,
    details
  )
  values (
    target_organization_id,
    actor_user_id,
    target_user_id,
    'training_supervisor_reassigned',
    pg_catalog.jsonb_build_object(
      'access_type', 'training_supervisor',
      'branch_count', pg_catalog.cardinality(target_branch_ids),
      'branch_ids', to_jsonb(target_branch_ids)
    )
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

-- 10. Training Supervisor Session Revocation & Credential Version Verification
create or replace function public.establish_training_supervisor_session(
  actor_user_id uuid
)
returns table(
  user_id uuid,
  account_name text,
  email text,
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  active boolean,
  training_role text,
  credential_version uuid,
  branches jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership_row public.training_memberships%rowtype;
begin
  if actor_user_id is null then
    raise exception 'training supervisor access denied' using errcode = '42501';
  end if;

  select tm.* into membership_row
  from public.training_memberships tm
  join public.organizations org on org.id = tm.organization_id
  join public.profiles p on p.id = tm.user_id
  where tm.user_id = actor_user_id
    and tm.training_role = 'training_supervisor'
    and tm.active
    and org.active
    and p.disabled_at is null
    and not p.must_change_password
  order by tm.created_at
  limit 1;

  if membership_row.user_id is null then
    raise exception 'training supervisor access denied' using errcode = '42501';
  end if;

  return query
  select
    membership_row.user_id,
    membership_row.account_name,
    u.email::text,
    org.id,
    org.name,
    org.name_ar,
    membership_row.active,
    membership_row.training_role,
    membership_row.credential_version,
    coalesce(
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'id', b.id,
            'name', b.name,
            'name_ar', b.name_ar,
            'code', b.code,
            'active', b.active
          )
          order by b.name, b.id
        )
        from public.training_membership_branches tmb
        join public.branches b on b.id = tmb.branch_id and b.organization_id = tmb.organization_id
        where tmb.organization_id = membership_row.organization_id
          and tmb.user_id = membership_row.user_id
          and b.active
      ),
      '[]'::jsonb
    ) as branches
  from public.organizations org
  join auth.users u on u.id = membership_row.user_id
  where org.id = membership_row.organization_id;
end;
$$;

create or replace function public.get_training_supervisor_context(
  actor_user_id uuid,
  p_expected_credential_version uuid
)
returns table(
  user_id uuid,
  account_name text,
  email text,
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  active boolean,
  training_role text,
  credential_version uuid,
  branches jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership_row public.training_memberships%rowtype;
begin
  if actor_user_id is null or p_expected_credential_version is null then
    raise exception 'credential version is required' using errcode = '42501';
  end if;

  select tm.* into membership_row
  from public.training_memberships tm
  join public.organizations org on org.id = tm.organization_id
  join public.profiles p on p.id = tm.user_id
  where tm.user_id = actor_user_id
    and tm.training_role = 'training_supervisor'
    and tm.active
    and org.active
    and p.disabled_at is null
    and not p.must_change_password
  order by tm.created_at
  limit 1;

  if membership_row.user_id is null then
    raise exception 'training supervisor access denied' using errcode = '42501';
  end if;

  if membership_row.credential_version is distinct from p_expected_credential_version then
    raise exception 'training supervisor session has been revoked' using errcode = '42501';
  end if;

  return query
  select
    membership_row.user_id,
    membership_row.account_name,
    u.email::text,
    org.id,
    org.name,
    org.name_ar,
    membership_row.active,
    membership_row.training_role,
    membership_row.credential_version,
    coalesce(
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'id', b.id,
            'name', b.name,
            'name_ar', b.name_ar,
            'code', b.code,
            'active', b.active
          )
          order by b.name, b.id
        )
        from public.training_membership_branches tmb
        join public.branches b on b.id = tmb.branch_id and b.organization_id = tmb.organization_id
        where tmb.organization_id = membership_row.organization_id
          and tmb.user_id = membership_row.user_id
          and b.active
      ),
      '[]'::jsonb
    ) as branches
  from public.organizations org
  join auth.users u on u.id = membership_row.user_id
  where org.id = membership_row.organization_id;
end;
$$;

-- 11. Security Grants: strictly service-role-only EXECUTE, all others revoked
-- Disable legacy unversioned get_training_account_context
do $legacy_guard$
begin
  if pg_catalog.to_regprocedure('public.get_training_account_context(uuid)') is not null then
    revoke all on function public.get_training_account_context(uuid) from public, anon, authenticated, service_role;
  end if;
end;
$legacy_guard$;

revoke all on function public.list_internal_admin_access_assignments(uuid, uuid, uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.grant_internal_admin_training_supervisor(uuid, uuid, uuid, uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.suspend_internal_admin_training_supervisor(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.reactivate_internal_admin_training_supervisor(uuid, uuid, uuid, uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.revoke_internal_admin_training_supervisor(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.reassign_internal_admin_training_supervisor(uuid, uuid, uuid, uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.establish_training_supervisor_session(uuid) from public, anon, authenticated, service_role;
revoke all on function public.get_training_supervisor_context(uuid, uuid) from public, anon, authenticated, service_role;

grant execute on function public.list_internal_admin_access_assignments(uuid, uuid, uuid, text, text) to service_role;
grant execute on function public.grant_internal_admin_training_supervisor(uuid, uuid, uuid, uuid[]) to service_role;
grant execute on function public.suspend_internal_admin_training_supervisor(uuid, uuid, uuid) to service_role;
grant execute on function public.reactivate_internal_admin_training_supervisor(uuid, uuid, uuid, uuid[]) to service_role;
grant execute on function public.revoke_internal_admin_training_supervisor(uuid, uuid, uuid) to service_role;
grant execute on function public.reassign_internal_admin_training_supervisor(uuid, uuid, uuid, uuid[]) to service_role;
grant execute on function public.establish_training_supervisor_session(uuid) to service_role;
grant execute on function public.get_training_supervisor_context(uuid, uuid) to service_role;

commit;
