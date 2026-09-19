-- Supervisor Lifecycle Phase 1: Unassigned Supervisor & Primary Vacant
-- 1. Updates list_managed_supervisor_teams to query canonical branch_operational_teams
--    with LEFT JOIN on primary supervisor. When vacant, supervisor_user_id is NULL,
--    active is TRUE, and operational_staff_count accurately reflects active staff.
-- 2. Updates get_supervisor_operational_team to only return teams where the actor
--    has an active assignment (primary or backup), preventing staff leakage to unassigned supervisors.

create or replace function public.list_managed_supervisor_teams(actor_user_id uuid, target_organization_id uuid)
returns table(
  team_id uuid,
  branch_id uuid,
  branch_name text,
  supervisor_user_id uuid,
  supervisor_name text,
  active boolean,
  operational_staff_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
  then
    raise exception 'listing denied' using errcode = '42501';
  end if;

  return query
  select
    team.id,
    branch.id,
    branch.name,
    primary_sup.supervisor_user_id,
    profile.full_name,
    team.active,
    count(distinct staff.id) filter (where staff.id is not null)
  from public.branch_operational_teams team
  join public.branches branch on branch.id = team.branch_id
  left join public.branch_operational_team_supervisors primary_sup
    on primary_sup.operational_team_id = team.id
   and primary_sup.active
   and primary_sup.assignment_role = 'primary'
  left join public.profiles profile on profile.id = primary_sup.supervisor_user_id
  left join public.operational_staff_assignments assignment
    on assignment.operational_team_id = team.id
   and assignment.active
  left join public.operational_staff staff
    on staff.id = assignment.operational_staff_id
   and staff.employment_status = 'active'
  where team.organization_id = target_organization_id
  group by
    team.id,
    branch.id,
    branch.name,
    primary_sup.supervisor_user_id,
    profile.full_name,
    team.active
  order by
    branch.name,
    coalesce(profile.full_name, ''),
    team.id
  limit 500;
end $$;

revoke all on function public.list_managed_supervisor_teams(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_managed_supervisor_teams(uuid, uuid) to service_role;

create or replace function public.get_supervisor_operational_team(actor_user_id uuid, target_branch_id uuid, requested_date date)
returns table(
  team_id uuid,
  team_name text,
  team_active boolean,
  can_write boolean,
  assignment_role text,
  company_name text,
  staff_id uuid,
  display_name text,
  staff_company_name text,
  staff_code text,
  country_code text,
  iqama_number text,
  iqama_expiry_date date,
  phone_number text,
  email text,
  employment_status text,
  assignment_id uuid,
  operational_roles text[],
  duty_status text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.apply_due_operational_staff_team_moves(target_branch_id);
  if requested_date is null or not private.actor_can_read_operational_branch(actor_user_id, target_branch_id)
  then
    raise exception 'team access denied' using errcode = '42501';
  end if;

  return query
  select
    team.id,
    team.name,
    team.active,
    private.actor_can_write_operational_team(actor_user_id, target_branch_id, team.id),
    actor_assignment.assignment_role,
    coalesce(legacy.company_name, organization.name),
    staff.id,
    staff.display_name,
    staff.company_name,
    staff.staff_code,
    staff.country_code,
    staff.iqama_number,
    staff.iqama_expiry_date,
    staff.phone_number,
    staff.email,
    staff.employment_status,
    assignment.id,
    assignment.operational_roles,
    coalesce(duty.duty_status, 'on_duty')
  from public.branch_operational_teams team
  join public.organizations organization on organization.id = team.organization_id
  left join public.branch_supervisor_teams legacy on legacy.id = team.legacy_supervisor_team_id
  join public.branch_operational_team_supervisors actor_assignment
    on actor_assignment.operational_team_id = team.id
   and actor_assignment.supervisor_user_id = actor_user_id
   and actor_assignment.active
  left join public.operational_staff_assignments assignment
    on assignment.operational_team_id = team.id
   and assignment.active
  left join public.operational_staff staff on staff.id = assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id = assignment.id
   and duty.duty_date = requested_date
  where team.branch_id = target_branch_id
    and team.active
  order by
    case actor_assignment.assignment_role when 'primary' then 0 when 'backup' then 1 else 2 end,
    team.normalized_name,
    pg_catalog.lower(staff.display_name),
    staff.id;
end $$;

revoke all on function public.get_supervisor_operational_team(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.get_supervisor_operational_team(uuid, uuid, date) to service_role;
