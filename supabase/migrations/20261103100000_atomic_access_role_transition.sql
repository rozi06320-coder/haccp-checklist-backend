-- Forward-only additive migration for atomic Internal Admin role transition
-- Compatible with Access Management Phase 1 (commit 1e352ee)
-- Uses authoritative public.training_memberships and public.training_membership_branches
-- Reuses private.enforce_access_assignment_mutual_exclusivity()

begin;

-- Preflight check to ensure idempotency and prevent duplicate application
do $preflight$
begin
  if pg_catalog.to_regprocedure('public.transition_internal_admin_access_role(uuid,uuid,uuid,text,text,uuid,uuid[],jsonb)') is not null then
    raise exception 'atomic access role transition is already installed' using errcode = '42710';
  end if;
end
$preflight$;

-- 1. Preserve all 51 existing account_management_audit_logs action values and append 'user_role_transitioned'
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
      'supervisor_demoted_to_staff',
      -- New action for atomic cross-role transitions
      'user_role_transitioned'
    )
  );

-- 2. Atomic Transition RPC
create or replace function public.transition_internal_admin_access_role(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  source_role text,
  target_role text,
  target_branch_id uuid default null,
  target_branch_ids uuid[] default null,
  target_team_assignments jsonb default null
)
returns table(
  user_id uuid,
  previous_role text,
  new_role text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  is_admin boolean;
  target_profile record;
  active_supervisor_count integer;
  active_training_count integer;
  branch_count integer;
  resolved_branch_ids uuid[];
  assigned_branch_id uuid;
  applied_team_count integer := 0;
  new_credential_version uuid := gen_random_uuid();
begin
  -- 1. Authorization: Validate actor is Internal Admin
  select private.is_internal_admin(actor_user_id) into is_admin;
  if not coalesce(is_admin, false) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  -- 2. Validate active organization
  if not exists (
    select 1
    from public.organizations org
    where org.id = target_organization_id
      and org.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  -- 3. Concurrency Protection: Serialize concurrent transitions on target user
  perform pg_advisory_xact_lock(hashtext('user_role_transition_' || target_user_id::text));

  -- 4. Validate and lock target profile
  select * into target_profile
  from public.profiles p
  where p.id = target_user_id
  for update;

  if target_profile.id is null then
    raise exception 'target user profile not found' using errcode = 'P0002';
  end if;

  -- 5. Validate source and target role pair
  if source_role not in ('supervisor', 'training_supervisor')
    or target_role not in ('supervisor', 'training_supervisor')
    or source_role = target_role
  then
    raise exception 'invalid role transition pair' using errcode = '22023';
  end if;

  -- 6. Resolve target branch IDs from either target_branch_ids or target_branch_id
  if target_branch_ids is not null and pg_catalog.cardinality(target_branch_ids) > 0 then
    resolved_branch_ids := target_branch_ids;
  elsif target_branch_id is not null then
    resolved_branch_ids := array[target_branch_id];
  else
    resolved_branch_ids := null;
  end if;

  if resolved_branch_ids is null or pg_catalog.cardinality(resolved_branch_ids) = 0 then
    raise exception 'target branch is required for transition' using errcode = '22023';
  end if;

  if pg_catalog.cardinality(resolved_branch_ids) > 50 then
    raise exception 'too many target branches specified (maximum 50)' using errcode = '22023';
  end if;

  -- Verify no duplicate branch IDs
  if (
    select pg_catalog.count(*) <> pg_catalog.count(distinct item)
    from pg_catalog.unnest(resolved_branch_ids) as item
  ) then
    raise exception 'duplicate target branches not allowed' using errcode = '22023';
  end if;

  -- Verify all target branches belong to the organization and are active
  select count(*)::integer into branch_count
  from public.branches b
  where b.organization_id = target_organization_id
    and b.id = any(resolved_branch_ids)
    and b.active;

  if branch_count <> pg_catalog.cardinality(resolved_branch_ids) then
    raise exception 'one or more target branches are invalid or inactive' using errcode = '22023';
  end if;

  -- Case A: Supervisor -> Training Supervisor
  if source_role = 'supervisor' and target_role = 'training_supervisor' then
    -- Verify user is currently an active supervisor in this organization
    select count(*) into active_supervisor_count
    from public.branch_memberships bm
    join public.branches b on b.id = bm.branch_id
    where bm.user_id = target_user_id
      and b.organization_id = target_organization_id
      and bm.role = 'branch_manager'
      and bm.active;

    if active_supervisor_count = 0 then
      raise exception 'transition conflict: user is not an active supervisor' using errcode = '23514';
    end if;

    -- Step 1: Deactivate branch_manager memberships in target organization
    -- Setting active = false removes active supervisor status before training membership is activated,
    -- satisfying private.enforce_access_assignment_mutual_exclusivity()
    update public.branch_memberships bm
    set active = false, updated_at = now()
    from public.branches b
    where b.id = bm.branch_id
      and b.organization_id = target_organization_id
      and bm.user_id = target_user_id
      and bm.role = 'branch_manager'
      and bm.active;

    -- Step 2: Deactivate active team supervisor assignments (preserve history with valid_to)
    update public.branch_operational_team_supervisors assignment
    set active = false,
        valid_to = greatest(assignment.valid_from, current_date),
        updated_at = now()
    where assignment.organization_id = target_organization_id
      and assignment.supervisor_user_id = target_user_id
      and assignment.active;

    -- Step 3: Deactivate legacy supervisor teams
    update public.branch_supervisor_teams team
    set active = false, updated_at = now()
    where team.organization_id = target_organization_id
      and team.supervisor_user_id = target_user_id
      and team.active;

    -- Step 4: Upsert training_memberships using existing authoritative table
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
      new_credential_version,
      now(),
      now()
    )
    on conflict on constraint training_memberships_pkey
    do update set
      active = true,
      training_role = 'training_supervisor',
      credential_version = new_credential_version,
      updated_by = actor_user_id,
      updated_at = now();

    -- Step 5: Replace branch associations in public.training_membership_branches
    delete from public.training_membership_branches
    where training_membership_branches.organization_id = target_organization_id
      and training_membership_branches.user_id = target_user_id;

    insert into public.training_membership_branches(organization_id, user_id, branch_id, created_at, updated_at)
    select target_organization_id, target_user_id, branch_id, now(), now()
    from unnest(resolved_branch_ids) as branch_id;

    -- Step 6: Log audit record without credential_version or secrets
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
      'user_role_transitioned',
      pg_catalog.jsonb_build_object(
        'from_role', 'supervisor',
        'to_role', 'training_supervisor',
        'branch_count', pg_catalog.cardinality(resolved_branch_ids),
        'branch_ids', to_jsonb(resolved_branch_ids)
      )
    );

  -- Case B: Training Supervisor -> Supervisor
  elsif source_role = 'training_supervisor' and target_role = 'supervisor' then
    -- Verify user is currently an active training supervisor in this organization
    select count(*) into active_training_count
    from public.training_memberships tm
    where tm.organization_id = target_organization_id
      and tm.user_id = target_user_id
      and tm.training_role = 'training_supervisor'
      and tm.active;

    if active_training_count = 0 then
      raise exception 'transition conflict: user is not an active training supervisor' using errcode = '23514';
    end if;

    -- Step 1: Remove all assigned branches from public.training_membership_branches
    delete from public.training_membership_branches
    where training_membership_branches.organization_id = target_organization_id
      and training_membership_branches.user_id = target_user_id;

    -- Step 2: Mark training_memberships inactive and rotate credential_version
    -- Inactivating training_memberships first satisfies exclusivity check before activating branch_memberships
    update public.training_memberships
    set active = false,
        credential_version = new_credential_version,
        updated_by = actor_user_id,
        updated_at = now()
    where training_memberships.organization_id = target_organization_id
      and training_memberships.user_id = target_user_id;

    -- Step 3: Activate branch_manager membership for target branches
    foreach assigned_branch_id in array resolved_branch_ids loop
      insert into public.branch_memberships(
        branch_id,
        user_id,
        role,
        active,
        created_at,
        updated_at
      )
      values (
        assigned_branch_id,
        target_user_id,
        'branch_manager',
        true,
        now(),
        now()
      )
      on conflict on constraint branch_memberships_pkey
      do update set
        active = true,
        role = 'branch_manager',
        updated_at = now();
    end loop;

    -- Step 4: Apply optional operational team assignments if specified
    if target_team_assignments is not null
      and pg_catalog.jsonb_typeof(target_team_assignments) = 'array'
      and pg_catalog.jsonb_array_length(target_team_assignments) > 0
    then
      applied_team_count := private.apply_internal_admin_supervisor_team_assignments(
        actor_user_id,
        target_organization_id,
        target_user_id,
        resolved_branch_ids,
        target_team_assignments
      );
    end if;

    -- Step 5: Ensure target profile is enabled
    update public.profiles
    set disabled_at = null,
        updated_at = now()
    where id = target_user_id;

    -- Step 6: Log audit record without credential_version or secrets
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
      'user_role_transitioned',
      pg_catalog.jsonb_build_object(
        'from_role', 'training_supervisor',
        'to_role', 'supervisor',
        'branch_count', pg_catalog.cardinality(resolved_branch_ids),
        'branch_ids', to_jsonb(resolved_branch_ids),
        'applied_team_count', applied_team_count
      )
    );

  end if;

  return query
  select target_user_id, source_role, target_role, now();
end;
$$;

-- Security hardening: revoke public execution, grant strictly to service_role
revoke all on function public.transition_internal_admin_access_role(uuid, uuid, uuid, text, text, uuid, uuid[], jsonb) from public, anon, authenticated, service_role;
grant execute on function public.transition_internal_admin_access_role(uuid, uuid, uuid, text, text, uuid, uuid[], jsonb) to service_role;

commit;
