-- Same-branch employee moves are authorized by the employee's current source team.
-- Submitted Hygiene snapshots remain immutable history and no longer block the move.

create or replace function public.move_operational_staff_team(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  expected_assignment_id uuid,target_operational_team_id uuid)
returns table(staff_id uuid,assignment_id uuid,operational_team_id uuid)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; old_assignment public.operational_staff_assignments%rowtype;
 target_team public.branch_operational_teams%rowtype; created_assignment uuid; current_business_date date; prior_duty text;
begin
  select * into strict staff_row from public.operational_staff
    where id=target_staff_id and branch_id=target_branch_id for update;
  select * into strict old_assignment from public.operational_staff_assignments
    where operational_staff_id=target_staff_id and active for update;
  if old_assignment.id<>expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  select * into strict target_team from public.branch_operational_teams
    where id=target_operational_team_id and branch_id=target_branch_id
      and organization_id=staff_row.organization_id and active for update;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,old_assignment.operational_team_id)
    or target_team.legacy_supervisor_team_id is null or staff_row.employment_status<>'active'
  then raise exception 'staff move denied' using errcode='42501'; end if;
  if old_assignment.operational_team_id=target_team.id
  then raise exception 'staff already belongs to team' using errcode='23505'; end if;
  select private.phase4a_business_date(branch.timezone) into strict current_business_date
  from public.branches branch where branch.id=target_branch_id and branch.active;
  select duty.duty_status into prior_duty from public.operational_staff_duty_statuses duty
    where duty.assignment_id=old_assignment.id and duty.duty_date=current_business_date;
  update public.operational_staff_assignments
  set active=false,valid_to=current_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='team_move'
  where id=old_assignment.id;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from,created_by_user_id)
  values(staff_row.organization_id,target_branch_id,target_staff_id,target_team.legacy_supervisor_team_id,
    target_team.id,old_assignment.operational_roles,current_business_date,actor_user_id)
  returning id into created_assignment;
  if prior_duty is not null then
    insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
    values(staff_row.organization_id,target_branch_id,target_staff_id,created_assignment,current_business_date,prior_duty,actor_user_id);
  end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(staff_row.organization_id,actor_user_id,target_branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',target_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active',
      'operational_roles',old_assignment.operational_roles));
  return query select target_staff_id,created_assignment,target_team.id;
exception when no_data_found or too_many_rows then raise exception 'staff move denied' using errcode='42501';
end $$;

revoke all on function public.move_operational_staff_team(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.move_operational_staff_team(uuid,uuid,uuid,uuid,uuid)
  to service_role;
