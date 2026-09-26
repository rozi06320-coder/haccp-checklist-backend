-- Internal Admin: replace an Operational Team primary supervisor.
-- Staff remain assigned to the same Operational Team; this migration does not
-- update operational_staff_assignments.

create or replace function public.reassign_internal_admin_operational_staff_team(
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
begin
  raise exception 'staff reassignment endpoint has been retired' using errcode = '0A000';
end
$$;

revoke all on function public.reassign_internal_admin_operational_staff_team(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated,service_role;

drop function if exists public.list_internal_admin_branch_teams(uuid, uuid);

create function public.list_internal_admin_branch_teams(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  team_id uuid,
  organization_id uuid,
  team_name text,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  current_primary_assignment_id uuid,
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
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select
      row.team_id,
      row.organization_id,
      row.team_name,
      row.company_name,
      row.branch_id,
      row.branch_name,
      row.branch_name_ar,
      row.branch_code,
      primary_assignment.id as current_primary_assignment_id,
      row.supervisor_user_id,
      row.supervisor_name,
      row.supervisor_name_ar,
      row.supervisor_email,
      row.supervisor_role,
      row.backup_supervisors,
      row.active,
      row.operational_staff_count,
      row.staff
    from public.branch_operational_teams team
    cross join lateral private.internal_admin_operational_team_row(team.id) row
    left join public.branch_operational_team_supervisors primary_assignment
      on primary_assignment.operational_team_id = team.id
     and primary_assignment.assignment_role = 'primary'
     and primary_assignment.active
    where team.organization_id = target_organization_id
    order by row.branch_name, row.team_name, row.team_id
    limit 500;
end;
$$;

revoke all on function public.list_internal_admin_branch_teams(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_branch_teams(uuid, uuid) to service_role;

create function public.change_internal_admin_operational_team_primary_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_operational_team_id uuid,
  destination_supervisor_user_id uuid,
  expected_current_primary_assignment_id uuid
)
returns table(
  operational_team_id uuid,
  branch_id uuid,
  previous_primary_assignment_id uuid,
  new_primary_assignment_id uuid,
  previous_supervisor_user_id uuid,
  new_supervisor_user_id uuid,
  effective_business_date date
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  target_team public.branch_operational_teams%rowtype;
  branch_row public.branches%rowtype;
  current_primary public.branch_operational_team_supervisors%rowtype;
  destination_existing public.branch_operational_team_supervisors%rowtype;
  inserted_primary public.branch_operational_team_supervisors%rowtype;
  current_business_date date;
  closed_at timestamptz := now();
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode='42501';
  end if;

  select * into target_team
  from public.branch_operational_teams team
  where team.id = target_operational_team_id
    and team.organization_id = target_organization_id
  for update;
  if not found then
    raise exception 'operational team supervisor change denied' using errcode='42501';
  end if;
  if not target_team.active then
    raise exception 'operational team is inactive' using errcode='23514';
  end if;

  select * into branch_row
  from public.branches branch
  where branch.id = target_team.branch_id
    and branch.organization_id = target_organization_id
  for update;
  if not found or not branch_row.active then
    raise exception 'operational team supervisor change denied' using errcode='42501';
  end if;
  current_business_date := private.phase4a_business_date(branch_row.timezone);

  select * into current_primary
  from public.branch_operational_team_supervisors assignment
  where assignment.operational_team_id = target_team.id
    and assignment.organization_id = target_organization_id
    and assignment.branch_id = target_team.branch_id
    and assignment.assignment_role = 'primary'
    and assignment.active
  for update;
  if not found then
    raise exception 'operational team primary supervisor unavailable' using errcode='23514';
  end if;
  if current_primary.id <> expected_current_primary_assignment_id then
    raise exception 'operational team primary supervisor changed' using errcode='40001';
  end if;
  if current_primary.supervisor_user_id = destination_supervisor_user_id then
    raise exception 'destination supervisor is already primary' using errcode='23505';
  end if;

  perform 1
  from public.profiles profile
  join public.branch_memberships membership
    on membership.user_id = profile.id
   and membership.branch_id = target_team.branch_id
   and membership.role = 'branch_manager'
   and membership.active
  where profile.id = destination_supervisor_user_id
    and profile.disabled_at is null
    and not profile.must_change_password
  for update of profile, membership;
  if not found then
    raise exception 'destination supervisor unavailable' using errcode='23514';
  end if;

  select * into destination_existing
  from public.branch_operational_team_supervisors assignment
  where assignment.operational_team_id = target_team.id
    and assignment.supervisor_user_id = destination_supervisor_user_id
    and assignment.active
  for update;

  if found and destination_existing.assignment_role = 'primary' then
    raise exception 'destination supervisor is already primary' using errcode='23505';
  end if;

  if found then
    update public.branch_operational_team_supervisors assignment
    set active = false,
        valid_to = greatest(assignment.valid_from, current_business_date),
        updated_at = closed_at
    where assignment.id = destination_existing.id;
  end if;

  update public.branch_operational_team_supervisors assignment
  set active = false,
      valid_to = greatest(assignment.valid_from, current_business_date),
      updated_at = closed_at
  where assignment.id = current_primary.id;

  insert into public.branch_operational_team_supervisors(
    organization_id,
    branch_id,
    operational_team_id,
    supervisor_user_id,
    assignment_role,
    valid_from,
    created_by
  )
  values(
    target_organization_id,
    target_team.branch_id,
    target_team.id,
    destination_supervisor_user_id,
    'primary',
    current_business_date,
    actor_user_id
  )
  returning * into inserted_primary;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    current_primary.supervisor_user_id,
    target_team.branch_id,
    'supervisor_team_deactivated',
    pg_catalog.jsonb_build_object(
      'team_id', target_team.id,
      'assignment_id', current_primary.id,
      'previous_status', 'active',
      'new_status', 'inactive',
      'source_branch_id', target_team.branch_id,
      'source_team_id', target_team.id,
      'closure_reason', 'primary_supervisor_changed',
      'effective_business_date', current_business_date
    )
  );

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    destination_supervisor_user_id,
    target_team.branch_id,
    'supervisor_team_assigned',
    pg_catalog.jsonb_build_object(
      'team_id', target_team.id,
      'assignment_id', inserted_primary.id,
      'previous_status', 'inactive',
      'new_status', 'active',
      'destination_branch_id', target_team.branch_id,
      'destination_team_id', target_team.id,
      'effective_business_date', current_business_date
    )
  );

  return query select
    target_team.id,
    target_team.branch_id,
    current_primary.id,
    inserted_primary.id,
    current_primary.supervisor_user_id,
    destination_supervisor_user_id,
    current_business_date;
end
$$;

revoke all on function public.change_internal_admin_operational_team_primary_supervisor(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.change_internal_admin_operational_team_primary_supervisor(uuid,uuid,uuid,uuid,uuid)
  to service_role;

notify pgrst, 'reload schema';
