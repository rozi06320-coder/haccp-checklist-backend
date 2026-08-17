-- Align Training Supervisor promotion with zero-team Supervisor lifecycle.

drop function if exists public.promote_managed_operational_staff_supervisor_training(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  uuid[],
  text
);

create function public.promote_managed_operational_staff_supervisor_training(
  actor_user_id uuid,
  target_organization_id uuid,
  target_staff_id uuid,
  new_supervisor_user_id uuid,
  new_supervisor_full_name text,
  new_supervisor_full_name_ar text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  training_row public.operational_staff_supervisor_training%rowtype;
  staff_row public.operational_staff%rowtype;
  assignment_row public.operational_staff_assignments%rowtype;
  clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_supervisor_full_name), '[[:space:]]+', ' ', 'g');
  clean_name_ar text := private.clean_optional_master_name(new_supervisor_full_name_ar);
  changed_rows integer;
begin
  if clean_name is null
    or pg_catalog.length(clean_name) not between 1 and 120
    or not private.actor_manages_active_organization(actor_user_id, target_organization_id)
  then
    raise exception 'supervisor promotion denied' using errcode = '42501';
  end if;

  select training.* into training_row
  from public.operational_staff_supervisor_training training
  where training.operational_staff_id = target_staff_id
    and training.organization_id = target_organization_id
    and training.status = 'promoted'
  order by training.promoted_at desc nulls last, training.started_at desc
  limit 1
  for update;

  if training_row.id is not null then
    if training_row.promoted_supervisor_user_id <> new_supervisor_user_id then
      raise exception 'supervisor promotion already completed' using errcode = '23505';
    end if;
    return private.operational_staff_supervisor_training_json(training_row.id);
  end if;

  select training.* into strict training_row
  from public.operational_staff_supervisor_training training
  where training.operational_staff_id = target_staff_id
    and training.organization_id = target_organization_id
    and training.status = 'training'
  for update;

  select staff.* into strict staff_row
  from public.operational_staff staff
  join public.branches branch
    on branch.id = staff.branch_id
   and branch.organization_id = staff.organization_id
  join public.organizations organization
    on organization.id = staff.organization_id
  where staff.id = target_staff_id
    and staff.organization_id = target_organization_id
    and staff.employment_status = 'active'
    and branch.active
    and organization.active
  for update;

  select assignment.* into strict assignment_row
  from public.operational_staff_assignments assignment
  join public.branch_operational_teams team
    on team.id = assignment.operational_team_id
   and team.active
  where assignment.operational_staff_id = target_staff_id
    and assignment.organization_id = target_organization_id
    and assignment.branch_id = staff_row.branch_id
    and assignment.active
  for update;

  if exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where membership.user_id = new_supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
      and branch.organization_id = target_organization_id
  ) then
    raise exception 'supervisor promotion already exists' using errcode = '23505';
  end if;

  update public.profiles
  set full_name = clean_name,
      full_name_ar = clean_name_ar,
      must_change_password = false,
      disabled_at = null
  where id = new_supervisor_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception 'target profile missing' using errcode = '23503';
  end if;

  insert into public.branch_memberships(branch_id, user_id, role, active)
  values(staff_row.branch_id, new_supervisor_user_id, 'branch_manager', true)
  on conflict(branch_id, user_id) do update
    set role = 'branch_manager',
        active = true,
        updated_at = now();

  update public.operational_staff_assignments
  set active = false,
      valid_to = greatest(valid_from, current_date),
      closed_at = now(),
      closed_by_user_id = actor_user_id,
      closure_reason = 'promoted_to_supervisor'
  where id = assignment_row.id;

  update public.operational_staff
  set employment_status = 'inactive',
      deactivated_at = now(),
      deactivated_by = actor_user_id
  where id = staff_row.id;

  update public.operational_staff_supervisor_training
  set status = 'promoted',
      promoted_at = now(),
      promoted_by_user_id = actor_user_id,
      promoted_supervisor_user_id = new_supervisor_user_id
  where id = training_row.id
  returning * into training_row;

  update public.profiles
  set must_change_password = true
  where id = new_supervisor_user_id;

  insert into public.account_management_audit_logs(
    organization_id,
    actor_user_id,
    target_user_id,
    branch_id,
    action,
    details
  )
  values(
    target_organization_id,
    actor_user_id,
    new_supervisor_user_id,
    staff_row.branch_id,
    'operational_staff_supervisor_training_promoted',
    pg_catalog.jsonb_build_object(
      'operational_staff_id', target_staff_id,
      'training_id', training_row.id,
      'closed_assignment_id', assignment_row.id
    )
  );

  return private.operational_staff_supervisor_training_json(training_row.id);
exception
  when unique_violation then
    raise exception 'supervisor promotion conflict' using errcode = '23505';
  when no_data_found or too_many_rows then
    raise exception 'supervisor promotion denied' using errcode = '42501';
end
$$;

revoke all on function public.promote_managed_operational_staff_supervisor_training(uuid, uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.promote_managed_operational_staff_supervisor_training(uuid, uuid, uuid, uuid, text, text)
  to service_role;
