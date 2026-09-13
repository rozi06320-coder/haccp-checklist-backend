-- Transfer active operational assignment to target branch and safely upsert/reactivate supervisor membership.

create or replace function public.promote_managed_operational_staff_supervisor_training(
  actor_user_id uuid,
  target_organization_id uuid,
  target_staff_id uuid,
  new_supervisor_user_id uuid,
  new_supervisor_full_name text,
  new_supervisor_full_name_ar text,
  target_branch_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  training_row public.operational_staff_supervisor_training%rowtype;
  staff_row public.operational_staff%rowtype;
  assignment_row public.operational_staff_assignments%rowtype;
  target_branch_row public.branches%rowtype;
  target_membership_row public.branch_memberships%rowtype;
  resolved_target_branch_id uuid;
  established_target_branch_id uuid;
  other_active_count integer;
  other_active_branch_id uuid;
  active_branch_count integer;
  current_branch_id uuid;
  clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_supervisor_full_name), '[[:space:]]+', ' ', 'g');
  clean_name_ar text := private.clean_optional_master_name(new_supervisor_full_name_ar);
  changed_rows integer;
  v_constraint_name text;
  v_message_text text;
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

    select coalesce(
      (
        select (audit.details->>'target_branch_id')::uuid
        from public.account_management_audit_logs audit
        where audit.organization_id = target_organization_id
          and audit.target_user_id = new_supervisor_user_id
          and audit.action = 'operational_staff_supervisor_training_promoted'
          and (audit.details->>'training_id')::uuid = training_row.id
        order by audit.created_at desc
        limit 1
      ),
      (
        select membership.branch_id
        from public.branch_memberships membership
        join public.branches branch on branch.id = membership.branch_id
        where membership.user_id = new_supervisor_user_id
          and membership.role = 'branch_manager'
          and membership.active
          and branch.organization_id = target_organization_id
        order by membership.updated_at desc
        limit 1
      )
    ) into established_target_branch_id;

    if established_target_branch_id is null then
      raise exception 'supervisor promotion established branch indeterminate' using errcode = '23514';
    end if;

    if target_branch_id is not null and target_branch_id <> established_target_branch_id then
      raise exception 'supervisor promotion target branch conflict' using errcode = '40001';
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

  resolved_target_branch_id := coalesce(target_branch_id, staff_row.branch_id);

  select branch.* into strict target_branch_row
  from public.branches branch
  where branch.id = resolved_target_branch_id
    and branch.organization_id = target_organization_id
    and branch.active;

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

  with locked_active_memberships as (
    select membership.branch_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and membership.user_id = new_supervisor_user_id
      and membership.branch_id <> resolved_target_branch_id
      and membership.active
    for update of membership
  )
  select count(*)::integer, (pg_catalog.array_agg(branch_id order by branch_id::text))[1]
  into other_active_count, other_active_branch_id
  from locked_active_memberships;

  if other_active_count > 1 then
    raise exception 'supervisor multiple active branch memberships conflict' using errcode = '23514';
  elsif other_active_count = 1 then
    if other_active_branch_id = staff_row.branch_id then
      update public.branch_memberships membership
      set active = false,
          updated_at = now()
      where membership.branch_id = staff_row.branch_id
        and membership.user_id = new_supervisor_user_id
        and membership.active;
    else
      raise exception 'supervisor active branch state conflict' using errcode = '23514';
    end if;
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

  select * into target_membership_row
  from public.branch_memberships
  where branch_id = resolved_target_branch_id
    and user_id = new_supervisor_user_id
  for update;

  if target_membership_row.branch_id is null then
    insert into public.branch_memberships(branch_id, user_id, role, active, updated_at)
    values(resolved_target_branch_id, new_supervisor_user_id, 'branch_manager', true, now());
  elsif not target_membership_row.active then
    update public.branch_memberships
    set role = 'branch_manager',
        active = true,
        updated_at = now()
    where branch_id = resolved_target_branch_id
      and user_id = new_supervisor_user_id;
  elsif target_membership_row.role = 'branch_manager' then
    update public.branch_memberships
    set updated_at = now()
    where branch_id = resolved_target_branch_id
      and user_id = new_supervisor_user_id;
  else
    raise exception 'target branch membership conflicts with supervisor access'
      using errcode = '23514', constraint = 'branch_memberships_role_check';
  end if;

  with active_memberships_after as (
    select membership.branch_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.organizations organization on organization.id = branch.organization_id
    where branch.organization_id = target_organization_id
      and membership.user_id = new_supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
      and branch.active
      and organization.active
  )
  select count(*)::integer, (pg_catalog.array_agg(branch_id order by branch_id::text))[1]
  into active_branch_count, current_branch_id
  from active_memberships_after;

  if active_branch_count <> 1 or current_branch_id <> resolved_target_branch_id then
    raise exception 'supervisor active branch state conflict' using errcode = '23514';
  end if;

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
    resolved_target_branch_id,
    'operational_staff_supervisor_training_promoted',
    pg_catalog.jsonb_build_object(
      'operational_staff_id', target_staff_id,
      'training_id', training_row.id,
      'closed_assignment_id', assignment_row.id,
      'origin_branch_id', staff_row.branch_id,
      'target_branch_id', resolved_target_branch_id
    )
  );

  return private.operational_staff_supervisor_training_json(training_row.id);
exception
  when unique_violation then
    get stacked diagnostics
      v_constraint_name = constraint_name,
      v_message_text = message_text;
    if v_constraint_name is not null and v_constraint_name <> '' then
      raise exception '%', coalesce(nullif(v_message_text, ''), 'supervisor promotion conflict')
        using errcode = '23505', constraint = v_constraint_name;
    else
      raise exception '%', coalesce(nullif(v_message_text, ''), 'supervisor promotion conflict')
        using errcode = '23505';
    end if;
  when no_data_found or too_many_rows then
    raise exception 'supervisor promotion denied' using errcode = '42501';
end
$$;

revoke all on function public.promote_managed_operational_staff_supervisor_training(uuid, uuid, uuid, uuid, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.promote_managed_operational_staff_supervisor_training(uuid, uuid, uuid, uuid, text, text, uuid)
  to service_role;

notify pgrst, 'reload schema';
