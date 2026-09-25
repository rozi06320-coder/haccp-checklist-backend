-- Internal Admin Phase 1: same-branch Operational Staff reassignment between Operational Teams.
-- This moves the active staff assignment; it does not create a direct staff-supervisor relationship.

create function public.reassign_internal_admin_operational_staff_team(
  p_actor_user_id uuid,
  p_target_organization_id uuid,
  p_target_operational_staff_id uuid,
  p_destination_operational_team_id uuid,
  p_expected_current_assignment_id uuid
)
returns table(
  staff_id uuid,
  previous_assignment_id uuid,
  new_assignment_id uuid,
  previous_operational_team_id uuid,
  destination_operational_team_id uuid,
  move_status text,
  scheduled_move_id uuid,
  effective_business_date date
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  staff_row public.operational_staff%rowtype;
  old_assignment public.operational_staff_assignments%rowtype;
  target_team public.branch_operational_teams%rowtype;
  existing_move public.operational_staff_scheduled_team_moves%rowtype;
  created_assignment uuid;
  created_move uuid;
  current_business_date date;
  prior_duty text;
  source_recorded boolean;
  destination_submitted boolean;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access denied' using errcode='42501';
  end if;

  select * into staff_row
  from public.operational_staff staff
  where staff.id=p_target_operational_staff_id
    and staff.organization_id=p_target_organization_id
  for update;
  if not found then
    raise exception 'staff reassignment denied' using errcode='42501';
  end if;

  select private.phase4a_business_date(branch.timezone) into current_business_date
  from public.branches branch
  where branch.id=staff_row.branch_id
    and branch.organization_id=p_target_organization_id
    and branch.active;
  if not found then
    raise exception 'staff reassignment denied' using errcode='42501';
  end if;

  perform private.apply_due_operational_staff_team_moves(staff_row.branch_id,p_target_organization_id);

  select * into old_assignment
  from public.operational_staff_assignments assignment
  where assignment.operational_staff_id=p_target_operational_staff_id
    and assignment.organization_id=p_target_organization_id
    and assignment.active
  for update;
  if not found or old_assignment.id<>p_expected_current_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  if old_assignment.branch_id<>staff_row.branch_id then
    raise exception 'staff reassignment denied' using errcode='42501';
  end if;

  select * into target_team
  from public.branch_operational_teams team
  where team.id=p_destination_operational_team_id
    and team.organization_id=p_target_organization_id
  for update;
  if not found then
    raise exception 'invalid destination team' using errcode='22023';
  end if;
  if target_team.branch_id<>staff_row.branch_id then
    raise exception 'cross-branch staff reassignment denied' using errcode='42501';
  end if;
  if not target_team.active or target_team.legacy_supervisor_team_id is null or staff_row.employment_status<>'active' then
    raise exception 'staff reassignment conflicts with current team data' using errcode='23514';
  end if;
  if old_assignment.operational_team_id=target_team.id then
    raise exception 'staff already belongs to team' using errcode='23505';
  end if;
  if not exists(
    select 1
    from public.branch_operational_team_supervisors supervisor_assignment
    join public.profiles profile on profile.id=supervisor_assignment.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id=supervisor_assignment.branch_id
     and membership.user_id=supervisor_assignment.supervisor_user_id
     and membership.role='branch_manager'
    join public.branches branch
      on branch.id=supervisor_assignment.branch_id
     and branch.organization_id=supervisor_assignment.organization_id
    join public.organizations organization on organization.id=supervisor_assignment.organization_id
    where supervisor_assignment.operational_team_id=target_team.id
      and supervisor_assignment.organization_id=p_target_organization_id
      and supervisor_assignment.branch_id=staff_row.branch_id
      and supervisor_assignment.active
      and supervisor_assignment.valid_from<=current_business_date
      and (supervisor_assignment.valid_to is null or supervisor_assignment.valid_to>=current_business_date)
      and profile.disabled_at is null
      and not profile.must_change_password
      and membership.active
      and branch.active
      and organization.active
  ) then
    raise exception 'destination team has no active supervisor' using errcode='23514';
  end if;

  select * into existing_move
  from public.operational_staff_scheduled_team_moves move
  where move.operational_staff_id=p_target_operational_staff_id
    and move.status='pending'
  for update;
  if found then
    if existing_move.source_assignment_id=p_expected_current_assignment_id
      and existing_move.destination_operational_team_id=target_team.id
    then
      return query select p_target_operational_staff_id,old_assignment.id,null::uuid,old_assignment.operational_team_id,
        target_team.id,'scheduled'::text,existing_move.id,existing_move.effective_business_date;
      return;
    end if;
    raise exception 'staff pending move already exists' using errcode='23505';
  end if;

  if old_assignment.operational_team_id::text<target_team.id::text then
    perform private.lock_operational_team_hygiene(staff_row.branch_id,old_assignment.operational_team_id,current_business_date);
    perform private.lock_operational_team_hygiene(staff_row.branch_id,target_team.id,current_business_date);
  else
    perform private.lock_operational_team_hygiene(staff_row.branch_id,target_team.id,current_business_date);
    perform private.lock_operational_team_hygiene(staff_row.branch_id,old_assignment.operational_team_id,current_business_date);
  end if;

  select exists(
    select 1
    from public.hygiene_staff_snapshots snapshot
    join public.checklist_submissions submission on submission.id=snapshot.submission_id
    where snapshot.operational_staff_id=p_target_operational_staff_id
      and submission.organization_id=p_target_organization_id
      and submission.branch_id=staff_row.branch_id
      and submission.operational_team_id=old_assignment.operational_team_id
      and submission.business_date=current_business_date
      and submission.checklist_type='staff_hygiene'
      and submission.state='submitted'
  ) into source_recorded;
  select exists(
    select 1
    from public.checklist_submissions submission
    where submission.organization_id=p_target_organization_id
      and submission.branch_id=staff_row.branch_id
      and submission.operational_team_id=target_team.id
      and submission.business_date=current_business_date
      and submission.checklist_type='staff_hygiene'
      and submission.state='submitted'
  ) into destination_submitted;

  if source_recorded or destination_submitted then
    insert into public.operational_staff_scheduled_team_moves(organization_id,branch_id,operational_staff_id,
      source_assignment_id,source_operational_team_id,destination_operational_team_id,requested_by_user_id,
      requested_business_date,effective_business_date)
    values(p_target_organization_id,staff_row.branch_id,p_target_operational_staff_id,old_assignment.id,
      old_assignment.operational_team_id,target_team.id,p_actor_user_id,current_business_date,current_business_date+1)
    returning id into created_move;

    insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(p_target_organization_id,p_actor_user_id,staff_row.branch_id,'operational_staff_assignment_updated',
      pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',p_target_operational_staff_id,
        'assignment_id',old_assignment.id,'previous_status','active','new_status','scheduled',
        'operational_roles',old_assignment.operational_roles,'source_branch_id',staff_row.branch_id,
        'source_team_id',old_assignment.operational_team_id,'destination_branch_id',staff_row.branch_id,
        'destination_team_id',target_team.id,'scheduled_move_id',created_move,'move_status','scheduled',
        'effective_business_date',current_business_date+1));

    return query select p_target_operational_staff_id,old_assignment.id,null::uuid,old_assignment.operational_team_id,
      target_team.id,'scheduled'::text,created_move,current_business_date+1;
    return;
  end if;

  select duty.duty_status into prior_duty
  from public.operational_staff_duty_statuses duty
  where duty.assignment_id=old_assignment.id
    and duty.duty_date=current_business_date;

  update public.operational_staff_assignments assignment
  set active=false,
      valid_to=current_business_date,
      closed_at=now(),
      closed_by_user_id=p_actor_user_id,
      closure_reason='team_move'
  where assignment.id=old_assignment.id;

  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from,created_by_user_id)
  values(p_target_organization_id,staff_row.branch_id,p_target_operational_staff_id,target_team.legacy_supervisor_team_id,
    target_team.id,old_assignment.operational_roles,current_business_date,p_actor_user_id)
  returning id into created_assignment;

  if prior_duty is not null then
    insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,
      duty_date,duty_status,set_by)
    values(p_target_organization_id,staff_row.branch_id,p_target_operational_staff_id,created_assignment,
      current_business_date,prior_duty,p_actor_user_id);
  end if;

  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(p_target_organization_id,p_actor_user_id,staff_row.branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',p_target_operational_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active',
      'operational_roles',old_assignment.operational_roles,'source_branch_id',staff_row.branch_id,
      'source_team_id',old_assignment.operational_team_id,'destination_branch_id',staff_row.branch_id,
      'destination_team_id',target_team.id,'closure_reason','team_move','move_status','applied',
      'effective_business_date',current_business_date));

  return query select p_target_operational_staff_id,old_assignment.id,created_assignment,
    old_assignment.operational_team_id,target_team.id,'applied'::text,null::uuid,current_business_date;
end
$$;

revoke all on function public.reassign_internal_admin_operational_staff_team(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.reassign_internal_admin_operational_staff_team(uuid,uuid,uuid,uuid,uuid)
  to service_role;

notify pgrst, 'reload schema';
