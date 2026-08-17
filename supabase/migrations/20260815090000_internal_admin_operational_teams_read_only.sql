create or replace function private.internal_admin_operational_team_row(target_operational_team_id uuid)
returns table(
  team_id uuid,
  organization_id uuid,
  team_name text,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_name_ar text,
  supervisor_email text,
  supervisor_role text,
  backup_supervisors jsonb,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    team.id,
    team.organization_id,
    team.name,
    coalesce(legacy.company_name, team.name),
    branch.id,
    branch.name,
    branch.name_ar,
    branch.code,
    primary_assignment.supervisor_user_id,
    primary_profile.full_name,
    primary_profile.full_name_ar,
    primary_auth.email::text,
    case when primary_assignment.supervisor_user_id is not null then 'branch_manager'::text else null::text end,
    coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'supervisor_user_id', backup_assignment.supervisor_user_id,
        'supervisor_name', backup_profile.full_name,
        'supervisor_name_ar', backup_profile.full_name_ar,
        'supervisor_email', backup_auth.email::text,
        'assignment_role', backup_assignment.assignment_role
      ) order by pg_catalog.lower(coalesce(backup_profile.full_name, backup_auth.email::text)), backup_assignment.supervisor_user_id)
      from public.branch_operational_team_supervisors backup_assignment
      join public.profiles backup_profile on backup_profile.id = backup_assignment.supervisor_user_id
      join auth.users backup_auth on backup_auth.id = backup_assignment.supervisor_user_id
      where backup_assignment.operational_team_id = team.id
        and backup_assignment.active
        and backup_assignment.assignment_role = 'backup'
    ), '[]'::jsonb),
    team.active,
    (
      select count(*)
      from public.operational_staff_assignments assignment
      where assignment.operational_team_id = team.id
        and assignment.active
    ),
    coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'staff_id', staff.id,
        'display_name', staff.display_name,
        'company_name', staff.company_name,
        'staff_code', staff.staff_code,
        'country_code', staff.country_code,
        'employment_status', staff.employment_status,
        'assignment_id', assignment.id,
        'operational_team_id', assignment.operational_team_id,
        'operational_roles', assignment.operational_roles
      ) order by pg_catalog.lower(staff.display_name), staff.id)
      from public.operational_staff_assignments assignment
      join public.operational_staff staff on staff.id = assignment.operational_staff_id
      where assignment.operational_team_id = team.id
        and assignment.active
    ), '[]'::jsonb)
  from public.branch_operational_teams team
  join public.branches branch on branch.id = team.branch_id and branch.organization_id = team.organization_id
  left join public.branch_supervisor_teams legacy on legacy.id = team.legacy_supervisor_team_id
  left join public.branch_operational_team_supervisors primary_assignment
    on primary_assignment.operational_team_id = team.id
    and primary_assignment.active
    and primary_assignment.assignment_role = 'primary'
  left join public.profiles primary_profile on primary_profile.id = primary_assignment.supervisor_user_id
  left join auth.users primary_auth on primary_auth.id = primary_assignment.supervisor_user_id
  where team.id = target_operational_team_id
$$;

revoke all on function private.internal_admin_operational_team_row(uuid) from public, anon, authenticated;
