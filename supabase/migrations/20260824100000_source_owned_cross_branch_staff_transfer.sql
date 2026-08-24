-- Cross-branch Operational Staff transfers are source-team owned.
-- Same-branch moves continue to use move_operational_staff_team unchanged.

create or replace function private.operational_audit_details_are_allowlisted(action_name text,candidate jsonb)
returns boolean language sql immutable security invoker set search_path = ''
as $$
  select action_name not in (
    'branch_shift_created','branch_shift_updated','supervisor_team_assigned','supervisor_team_deactivated',
    'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
    'operational_staff_assignment_created','operational_staff_assignment_updated',
    'operational_staff_assignment_deactivated','operational_staff_duty_changed'
  ) or not exists (
    select 1 from pg_catalog.jsonb_object_keys(candidate) key
    where key not in ('shift_id','team_id','operational_staff_id','assignment_id',
      'previous_status','new_status','operational_roles','source_branch_id','source_team_id',
      'destination_branch_id','destination_team_id','closure_reason')
  );
$$;
revoke all on function private.operational_audit_details_are_allowlisted(text,jsonb) from public,anon,authenticated;
grant execute on function private.operational_audit_details_are_allowlisted(text,jsonb) to service_role;

drop function if exists public.transfer_operational_staff_branch(uuid,uuid,uuid,uuid,uuid);

create or replace function public.list_operational_staff_transfer_destinations(
  actor_user_id uuid,
  p_source_branch_id uuid,
  p_operational_staff_id uuid,
  p_expected_assignment_id uuid
)
returns table(branch_id uuid,branch_name text,branch_code text,operational_team_id uuid,team_name text)
language plpgsql stable security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; current_assignment public.operational_staff_assignments%rowtype;
begin
  select * into strict staff_row from public.operational_staff staff
    where staff.id=p_operational_staff_id and staff.branch_id=p_source_branch_id and staff.employment_status='active';
  select * into strict current_assignment from public.operational_staff_assignments assignment
    where assignment.operational_staff_id=p_operational_staff_id and assignment.active;
  if current_assignment.id<>p_expected_assignment_id
    or current_assignment.branch_id<>staff_row.branch_id
    or current_assignment.organization_id<>staff_row.organization_id
    or not private.actor_can_write_operational_team(actor_user_id,staff_row.branch_id,current_assignment.operational_team_id)
  then raise exception 'staff transfer destinations denied' using errcode='42501'; end if;
  return query
  select branch.id,branch.name,branch.code,team.id,team.name
  from public.branches branch
  join public.branch_operational_teams team on team.branch_id=branch.id and team.organization_id=branch.organization_id
  where branch.organization_id=staff_row.organization_id and branch.active and team.active
    and branch.id<>staff_row.branch_id and team.legacy_supervisor_team_id is not null
  order by pg_catalog.lower(branch.name),pg_catalog.lower(team.name),team.id;
exception when no_data_found or too_many_rows then raise exception 'staff transfer destinations denied' using errcode='42501';
end $$;

create or replace function public.transfer_operational_staff_branch(
  actor_user_id uuid,
  p_organization_id uuid,
  p_source_branch_id uuid,
  p_operational_staff_id uuid,
  p_expected_assignment_id uuid,
  p_destination_branch_id uuid,
  p_destination_team_id uuid
)
returns table(staff_id uuid,assignment_id uuid,branch_id uuid,operational_team_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  staff_row public.operational_staff%rowtype;
  old_assignment public.operational_staff_assignments%rowtype;
  source_branch_row public.branches%rowtype;
  destination_branch_row public.branches%rowtype;
  destination_team_row public.branch_operational_teams%rowtype;
  created_assignment uuid;
  source_business_date date;
  destination_business_date date;
  prior_duty text;
begin
  select * into strict staff_row from public.operational_staff staff
    where staff.id=p_operational_staff_id and staff.organization_id=p_organization_id for update;
  select * into strict old_assignment from public.operational_staff_assignments assignment
    where assignment.operational_staff_id=p_operational_staff_id and assignment.active for update;
  if old_assignment.id<>p_expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  if staff_row.branch_id<>p_source_branch_id or old_assignment.branch_id<>staff_row.branch_id
    or old_assignment.organization_id<>staff_row.organization_id or staff_row.employment_status<>'active'
  then raise exception 'staff transfer denied' using errcode='42501'; end if;
  select * into strict source_branch_row from public.branches branch
    where branch.id=staff_row.branch_id and branch.organization_id=staff_row.organization_id and branch.active;
  select * into strict destination_branch_row from public.branches branch
    where branch.id=p_destination_branch_id and branch.organization_id=staff_row.organization_id and branch.active for update;
  if destination_branch_row.id=staff_row.branch_id then
    raise exception 'staff transfer denied' using errcode='42501';
  end if;
  select * into strict destination_team_row from public.branch_operational_teams team
    where team.id=p_destination_team_id and team.branch_id=destination_branch_row.id
      and team.organization_id=staff_row.organization_id and team.active for update;
  if destination_team_row.legacy_supervisor_team_id is null
    or not private.actor_can_write_operational_team(actor_user_id,staff_row.branch_id,old_assignment.operational_team_id)
  then raise exception 'staff transfer denied' using errcode='42501'; end if;

  source_business_date:=private.phase4a_business_date(source_branch_row.timezone);
  destination_business_date:=private.phase4a_business_date(destination_branch_row.timezone);
  perform private.lock_operational_team_hygiene(destination_branch_row.id,destination_team_row.id,destination_business_date);
  if exists (
    select 1 from public.checklist_submissions submission
    where submission.organization_id=staff_row.organization_id
      and submission.branch_id=destination_branch_row.id
      and submission.operational_team_id=destination_team_row.id
      and submission.business_date=destination_business_date
      and submission.checklist_type='staff_hygiene'
      and submission.state='submitted'
  ) then raise exception 'destination team hygiene already submitted' using errcode='23514'; end if;

  select duty.duty_status into prior_duty from public.operational_staff_duty_statuses duty
    where duty.assignment_id=old_assignment.id and duty.duty_date=source_business_date;
  update public.operational_staff_assignments
  set active=false,valid_to=source_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='branch_transfer'
  where operational_staff_assignments.id=old_assignment.id;
  update public.operational_staff set branch_id=destination_branch_row.id where operational_staff.id=p_operational_staff_id;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from,created_by_user_id)
  values(staff_row.organization_id,destination_branch_row.id,p_operational_staff_id,destination_team_row.legacy_supervisor_team_id,
    destination_team_row.id,old_assignment.operational_roles,destination_business_date,actor_user_id)
  returning id into created_assignment;
  if prior_duty is not null then
    insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
    values(staff_row.organization_id,destination_branch_row.id,p_operational_staff_id,created_assignment,destination_business_date,prior_duty,actor_user_id);
  end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(staff_row.organization_id,actor_user_id,destination_branch_row.id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',destination_team_row.id,'operational_staff_id',p_operational_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active',
      'operational_roles',old_assignment.operational_roles,'source_branch_id',source_branch_row.id,
      'source_team_id',old_assignment.operational_team_id,'destination_branch_id',destination_branch_row.id,
      'destination_team_id',destination_team_row.id,'closure_reason','branch_transfer'));
  return query select p_operational_staff_id,created_assignment,destination_branch_row.id,destination_team_row.id;
exception when no_data_found or too_many_rows then raise exception 'staff transfer denied' using errcode='42501';
end $$;

revoke all on function public.list_operational_staff_transfer_destinations(uuid,uuid,uuid,uuid),
  public.transfer_operational_staff_branch(uuid,uuid,uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.list_operational_staff_transfer_destinations(uuid,uuid,uuid,uuid),
  public.transfer_operational_staff_branch(uuid,uuid,uuid,uuid,uuid,uuid,uuid)
  to service_role;
