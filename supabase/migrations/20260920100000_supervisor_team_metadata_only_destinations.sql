create or replace function public.get_supervisor_operational_team(actor_user_id uuid,target_branch_id uuid,requested_date date)
returns table(team_id uuid,team_name text,team_active boolean,can_write boolean,assignment_role text,
  company_name text,staff_id uuid,display_name text,staff_company_name text,staff_code text,country_code text,
  iqama_number text,iqama_expiry_date date,phone_number text,email text,employment_status text,
  assignment_id uuid,operational_roles text[],duty_status text)
language plpgsql security definer set search_path = '' as $$
begin
  perform private.apply_due_operational_staff_team_moves(target_branch_id);
  if requested_date is null or not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'team access denied' using errcode='42501'; end if;
  return query
  select team.id,team.name,team.active,
    case when actor_assignment.id is null then false else private.actor_can_write_operational_team(actor_user_id,target_branch_id,team.id) end,
    actor_assignment.assignment_role,
    case when actor_assignment.id is null then null else coalesce(legacy.company_name,organization.name) end,
    staff.id,staff.display_name,staff.company_name,staff.staff_code,staff.country_code,staff.iqama_number,staff.iqama_expiry_date,
    staff.phone_number,staff.email,staff.employment_status,assignment.id,assignment.operational_roles,
    case when assignment.id is null then null else coalesce(duty.duty_status,'on_duty') end
  from public.branch_operational_teams team
  join public.organizations organization on organization.id=team.organization_id
  left join public.branch_supervisor_teams legacy on legacy.id=team.legacy_supervisor_team_id
  left join public.branch_operational_team_supervisors actor_assignment
    on actor_assignment.operational_team_id=team.id and actor_assignment.supervisor_user_id=actor_user_id and actor_assignment.active
  left join public.operational_staff_assignments assignment
    on actor_assignment.id is not null and assignment.operational_team_id=team.id and assignment.active
  left join public.operational_staff staff on staff.id=assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id=assignment.id and duty.duty_date=requested_date
  where team.branch_id=target_branch_id and team.active
  order by case actor_assignment.assignment_role when 'primary' then 0 when 'backup' then 1 else 2 end,
    team.normalized_name,pg_catalog.lower(staff.display_name),staff.id;
end $$;
