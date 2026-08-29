create or replace function public.transfer_branch_supervisor_access(
  actor_user_id uuid,
  target_organization_id uuid,
  target_supervisor_user_id uuid,
  expected_from_branch_id uuid,
  target_branch_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  branches jsonb,
  team_assignments jsonb,
  active boolean,
  disabled boolean,
  must_change_password boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  active_branch_count integer;
  current_branch_id uuid;
  closed_team_assignment_count integer := 0;
  closed_legacy_team_count integer := 0;
  transfer_timestamp timestamptz := now();
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists (
      select 1
      from public.organizations organization
      where organization.id = target_organization_id
        and organization.active
    )
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if expected_from_branch_id = target_branch_id then
    raise exception 'target branch must differ from source branch' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.branches branch
    where branch.id = expected_from_branch_id
      and branch.organization_id = target_organization_id
  ) then
    raise exception 'source branch unavailable' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from public.branches branch
    where branch.id = target_branch_id
      and branch.organization_id = target_organization_id
      and branch.active
  ) then
    raise exception 'target branch unavailable' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from public.profiles profile
    where profile.id = target_supervisor_user_id
      and profile.disabled_at is null
  ) then
    raise exception 'supervisor unavailable' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and membership.user_id = target_supervisor_user_id
      and membership.role = 'branch_manager'
  ) then
    raise exception 'supervisor unavailable' using errcode = 'P0002';
  end if;

  with locked_active_memberships as (
    select membership.branch_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.organizations organization on organization.id = branch.organization_id
    where branch.organization_id = target_organization_id
      and membership.user_id = target_supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
      and branch.active
      and organization.active
    for update of membership
  )
  select count(*)::integer, (pg_catalog.array_agg(branch_id order by branch_id::text))[1]
  into active_branch_count, current_branch_id
  from locked_active_memberships;

  if active_branch_count <> 1 then
    raise exception 'supervisor active branch state conflict' using errcode = '23514';
  end if;

  if current_branch_id <> expected_from_branch_id then
    raise exception 'supervisor branch assignment changed' using errcode = '40001';
  end if;

  perform 1
  from public.branch_memberships membership
  where membership.branch_id = target_branch_id
    and membership.user_id = target_supervisor_user_id
  for update;

  if exists (
    select 1
    from public.branch_memberships membership
    where membership.branch_id = target_branch_id
      and membership.user_id = target_supervisor_user_id
      and membership.active
      and membership.role <> 'branch_manager'
  ) then
    raise exception 'target branch membership conflicts with supervisor access' using errcode = '23514';
  end if;

  update public.branch_operational_team_supervisors assignment
  set active = false,
      valid_to = greatest(assignment.valid_from, current_date),
      updated_at = transfer_timestamp
  where assignment.organization_id = target_organization_id
    and assignment.branch_id = expected_from_branch_id
    and assignment.supervisor_user_id = target_supervisor_user_id
    and assignment.active;
  get diagnostics closed_team_assignment_count = row_count;

  update public.branch_supervisor_teams team
  set active = false,
      updated_at = transfer_timestamp
  where team.organization_id = target_organization_id
    and team.branch_id = expected_from_branch_id
    and team.supervisor_user_id = target_supervisor_user_id
    and team.active;
  get diagnostics closed_legacy_team_count = row_count;

  update public.branch_memberships membership
  set active = false,
      updated_at = transfer_timestamp
  where membership.branch_id = expected_from_branch_id
    and membership.user_id = target_supervisor_user_id
    and membership.role = 'branch_manager'
    and membership.active;

  if not found then
    raise exception 'supervisor branch assignment changed' using errcode = '40001';
  end if;

  insert into public.branch_memberships(branch_id, user_id, role, active, updated_at)
  values(target_branch_id, target_supervisor_user_id, 'branch_manager', true, transfer_timestamp)
  on conflict on constraint branch_memberships_pkey do update
    set role = 'branch_manager',
        active = true,
        updated_at = transfer_timestamp;

  with active_memberships_after as (
    select membership.branch_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.organizations organization on organization.id = branch.organization_id
    where branch.organization_id = target_organization_id
      and membership.user_id = target_supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
      and branch.active
      and organization.active
  )
  select count(*)::integer, (pg_catalog.array_agg(branch_id order by branch_id::text))[1]
  into active_branch_count, current_branch_id
  from active_memberships_after;

  if active_branch_count <> 1 or current_branch_id <> target_branch_id then
    raise exception 'supervisor active branch state conflict' using errcode = '23514';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_supervisor_user_id,
    expected_from_branch_id,
    'branch_assignment_removed',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'from_branch_id', expected_from_branch_id,
      'to_branch_id', target_branch_id,
      'supervisor_user_id', target_supervisor_user_id,
      'transferred_at', transfer_timestamp,
      'closed_team_assignment_count', closed_team_assignment_count,
      'closed_legacy_team_count', closed_legacy_team_count
    )
  );

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_supervisor_user_id,
    target_branch_id,
    'branch_assignment_added',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'from_branch_id', expected_from_branch_id,
      'to_branch_id', target_branch_id,
      'supervisor_user_id', target_supervisor_user_id,
      'transferred_at', transfer_timestamp
    )
  );

  return query
    select profile.id,
      profile.full_name,
      auth_user.email::text,
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', branch.id,
          'name', branch.name,
          'name_ar', branch.name_ar,
          'code', branch.code,
          'active', membership.active
        ) order by pg_catalog.lower(branch.name), branch.id)
        from public.branch_memberships membership
        join public.branches branch on branch.id = membership.branch_id
        join public.organizations organization on organization.id = branch.organization_id
        where branch.organization_id = target_organization_id
          and membership.user_id = profile.id
          and membership.role = 'branch_manager'
          and membership.active
          and branch.active
          and organization.active
      ), '[]'::jsonb),
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'team_id', team.id,
          'team_name', team.name,
          'branch_id', team.branch_id,
          'branch_name', team_branch.name,
          'branch_name_ar', team_branch.name_ar,
          'assignment_role', assignment.assignment_role,
          'active', assignment.active
        ) order by pg_catalog.lower(team_branch.name), pg_catalog.lower(team.name), assignment.assignment_role)
        from public.branch_operational_team_supervisors assignment
        join public.branch_operational_teams team on team.id = assignment.operational_team_id
        join public.branches team_branch on team_branch.id = assignment.branch_id
        where assignment.organization_id = target_organization_id
          and assignment.supervisor_user_id = profile.id
          and assignment.active
      ), '[]'::jsonb),
      true,
      profile.disabled_at is not null,
      profile.must_change_password,
      transfer_timestamp
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_supervisor_user_id;
exception
  when unique_violation then
    raise exception 'supervisor branch transfer conflict' using errcode = '23505';
end;
$$;

revoke all on function public.transfer_branch_supervisor_access(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.transfer_branch_supervisor_access(uuid, uuid, uuid, uuid, uuid) to service_role;

comment on function public.transfer_branch_supervisor_access(uuid, uuid, uuid, uuid, uuid) is
  'Transfers one Branch Supervisor account between active branches in the same organization while preserving historical branch/team/staff records.';
