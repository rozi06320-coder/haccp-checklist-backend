drop function if exists public.list_internal_admin_branch_teams(uuid, uuid);
drop function if exists public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text[]);

create function public.list_internal_admin_branch_teams(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  team_id uuid,
  organization_id uuid,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_email text,
  supervisor_role text,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
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
      team.organization_id,
      team.company_name,
      branch.id,
      branch.name,
      branch.code,
      team.supervisor_user_id,
      profile.full_name,
      auth_user.email::text,
      membership.role,
      team.active,
      count(assignment.id) filter (where assignment.active),
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'staff_id', staff.id,
            'display_name', staff.display_name,
            'company_name', staff.company_name,
            'staff_code', staff.staff_code,
            'employment_status', staff.employment_status,
            'assignment_id', assignment.id,
            'operational_roles', assignment.operational_roles
          )
          order by lower(staff.display_name), staff.id
        ) filter (where assignment.id is not null and staff.id is not null),
        '[]'::jsonb
      )
    from public.branch_supervisor_teams team
    join public.branches branch on branch.id = team.branch_id
    join public.profiles profile on profile.id = team.supervisor_user_id
    join auth.users auth_user on auth_user.id = team.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id = team.branch_id
      and membership.user_id = team.supervisor_user_id
      and membership.role = 'branch_manager'
    left join public.operational_staff_assignments assignment
      on assignment.supervisor_team_id = team.id
      and assignment.active
    left join public.operational_staff staff
      on staff.id = assignment.operational_staff_id
    where team.organization_id = target_organization_id
      and branch.organization_id = target_organization_id
    group by team.id, team.organization_id, team.company_name, branch.id, branch.name, branch.code,
      team.supervisor_user_id, profile.full_name, auth_user.email, membership.role, team.active
    order by coalesce(team.company_name, ''), branch.name, profile.full_name, auth_user.email, team.id
    limit 500;
end;
$$;

create function public.create_internal_admin_branch_team_staff(
  actor_user_id uuid,
  target_organization_id uuid,
  target_team_id uuid,
  new_display_name text,
  new_company_name text,
  new_staff_code text,
  new_operational_roles text[]
)
returns table(staff_id uuid, assignment_id uuid, duplicate_name_warning boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  created_staff uuid;
  created_assignment uuid;
  clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(new_display_name, '')), '[[:space:]]+', ' ', 'g');
  clean_company_name text := private.clean_operational_staff_company_name(new_company_name);
  clean_code text := private.clean_operational_staff_code(new_staff_code);
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  select team.*
    into strict target_team
  from public.branch_supervisor_teams team
  join public.branches branch on branch.id = team.branch_id
  join public.organizations organization on organization.id = team.organization_id
  where team.id = target_team_id
    and team.organization_id = target_organization_id
    and team.active
    and branch.active
    and organization.active
  for update;

  if length(clean_name) not between 1 and 120
    or length(coalesce(clean_company_name, '')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or not private.operational_roles_are_valid(new_operational_roles)
  then
    raise exception 'invalid branch team staff request' using errcode = '22023';
  end if;

  insert into public.operational_staff(organization_id, branch_id, display_name, company_name, staff_code, created_by)
  values(target_team.organization_id, target_team.branch_id, clean_name, clean_company_name, clean_code, actor_user_id)
  returning id into created_staff;

  insert into public.operational_staff_assignments(
    organization_id,
    branch_id,
    operational_staff_id,
    supervisor_team_id,
    operational_roles
  )
  values(
    target_team.organization_id,
    target_team.branch_id,
    created_staff,
    target_team.id,
    new_operational_roles
  )
  returning id into created_assignment;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    target_team.organization_id,
    actor_user_id,
    target_team.supervisor_user_id,
    target_team.branch_id,
    'operational_staff_created',
    jsonb_build_object(
      'team_id', target_team.id,
      'operational_staff_id', created_staff,
      'assignment_id', created_assignment,
      'operational_roles', new_operational_roles
    )
  );

  return query select created_staff, created_assignment, exists(
    select 1
    from public.operational_staff staff
    where staff.organization_id = target_team.organization_id
      and staff.branch_id = target_team.branch_id
      and staff.id <> created_staff
      and staff.employment_status = 'active'
      and staff.normalized_name = private.normalize_operational_staff_name(clean_name)
  );
exception when no_data_found or too_many_rows then
  raise exception 'invalid branch team staff request' using errcode = '22023';
end;
$$;

revoke all on function public.list_internal_admin_branch_teams(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.list_internal_admin_branch_teams(uuid, uuid) to service_role;
grant execute on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text[]) to service_role;
