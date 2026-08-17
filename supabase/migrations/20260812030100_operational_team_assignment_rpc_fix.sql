-- Qualify the team status column because `active` is also an output column.
create or replace function public.assign_operational_team_supervisor(actor_user_id uuid,target_organization_id uuid,
  target_operational_team_id uuid,target_supervisor_user_id uuid,new_assignment_role text)
returns table(id uuid,operational_team_id uuid,supervisor_user_id uuid,assignment_role text,active boolean)
language plpgsql security definer set search_path = '' as $$
declare team public.branch_operational_teams%rowtype; created public.branch_operational_team_supervisors%rowtype;
begin
  select * into strict team from public.branch_operational_teams
  where branch_operational_teams.id=target_operational_team_id
    and branch_operational_teams.organization_id=target_organization_id
    and branch_operational_teams.active
  for update;
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or new_assignment_role not in('primary','backup')
  then raise exception 'operational team assignment denied' using errcode='42501'; end if;
  insert into public.branch_operational_team_supervisors(organization_id,branch_id,operational_team_id,
    supervisor_user_id,assignment_role,created_by)
  values(team.organization_id,team.branch_id,team.id,target_supervisor_user_id,new_assignment_role,actor_user_id)
  returning * into created;
  return query select created.id,created.operational_team_id,created.supervisor_user_id,created.assignment_role,created.active;
exception when no_data_found or too_many_rows then raise exception 'operational team assignment denied' using errcode='42501';
end $$;

revoke all on function public.assign_operational_team_supervisor(uuid,uuid,uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.assign_operational_team_supervisor(uuid,uuid,uuid,uuid,text)
  to service_role;
