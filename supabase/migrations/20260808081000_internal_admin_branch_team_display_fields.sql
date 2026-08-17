drop function if exists public.list_internal_admin_branch_teams(uuid, uuid);
drop function if exists public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid);

create or replace function public.list_internal_admin_branch_teams(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  team_id uuid,
  organization_id uuid,
  organization_name text,
  branch_id uuid,
  branch_name text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_email text,
  supervisor_role text,
  active boolean,
  operational_staff_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = target_organization_id
      and organization.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select
      team.id,
      organization.id,
      organization.name,
      branch.id,
      branch.name,
      branch.code,
      team.supervisor_user_id,
      profile.full_name,
      auth_user.email::text,
      membership.role,
      team.active,
      count(assignment.id) filter (where assignment.active)
    from public.branch_supervisor_teams team
    join public.organizations organization on organization.id = team.organization_id
    join public.branches branch on branch.id = team.branch_id
    join public.profiles profile on profile.id = team.supervisor_user_id
    join auth.users auth_user on auth_user.id = team.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id = team.branch_id
      and membership.user_id = team.supervisor_user_id
      and membership.role = 'branch_manager'
    left join public.operational_staff_assignments assignment on assignment.supervisor_team_id = team.id
    where team.organization_id = target_organization_id
      and branch.organization_id = target_organization_id
      and organization.id = target_organization_id
    group by team.id, organization.id, organization.name, branch.id, branch.name, branch.code,
      team.supervisor_user_id, profile.full_name, auth_user.email, membership.role, team.active
    order by organization.name, branch.name, profile.full_name, auth_user.email, team.id
    limit 500;
end;
$$;

create or replace function public.create_internal_admin_branch_team(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid,
  target_supervisor_user_id uuid
)
returns table(
  team_id uuid,
  organization_id uuid,
  organization_name text,
  branch_id uuid,
  branch_name text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_email text,
  supervisor_role text,
  active boolean,
  operational_staff_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing_team public.branch_supervisor_teams%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    where branch.id = target_branch_id
      and branch.organization_id = target_organization_id
      and branch.active
      and organization.active
  ) then
    raise exception 'invalid branch team request' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.profiles profile
    join public.branch_memberships membership on membership.user_id = profile.id
    where profile.id = target_supervisor_user_id
      and profile.disabled_at is null
      and not profile.must_change_password
      and membership.branch_id = target_branch_id
      and membership.role = 'branch_manager'
      and membership.active
  ) then
    raise exception 'invalid branch team request' using errcode = '22023';
  end if;

  select team.*
    into existing_team
  from public.branch_supervisor_teams team
  where team.organization_id = target_organization_id
    and team.branch_id = target_branch_id
    and team.supervisor_user_id = target_supervisor_user_id
  order by team.active desc, team.created_at desc, team.id
  limit 1
  for update;

  if existing_team.id is null then
    insert into public.branch_supervisor_teams(organization_id, branch_id, supervisor_user_id)
    values(target_organization_id, target_branch_id, target_supervisor_user_id)
    returning * into existing_team;
  elsif not existing_team.active then
    update public.branch_supervisor_teams
    set active = true
    where id = existing_team.id
    returning * into existing_team;
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_supervisor_user_id,
    target_branch_id,
    'supervisor_team_assigned',
    pg_catalog.jsonb_build_object('team_id', existing_team.id, 'new_status', 'active')
  );

  return query
    select
      team.id,
      organization.id,
      organization.name,
      branch.id,
      branch.name,
      branch.code,
      team.supervisor_user_id,
      profile.full_name,
      auth_user.email::text,
      membership.role,
      team.active,
      count(assignment.id) filter (where assignment.active)
    from public.branch_supervisor_teams team
    join public.organizations organization on organization.id = team.organization_id
    join public.branches branch on branch.id = team.branch_id
    join public.profiles profile on profile.id = team.supervisor_user_id
    join auth.users auth_user on auth_user.id = team.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id = team.branch_id
      and membership.user_id = team.supervisor_user_id
      and membership.role = 'branch_manager'
    left join public.operational_staff_assignments assignment on assignment.supervisor_team_id = team.id
    where team.id = existing_team.id
    group by team.id, organization.id, organization.name, branch.id, branch.name, branch.code,
      team.supervisor_user_id, profile.full_name, auth_user.email, membership.role, team.active;
end;
$$;

revoke all on function public.list_internal_admin_branch_teams(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_branch_teams(uuid, uuid) to service_role;
grant execute on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid) to service_role;
