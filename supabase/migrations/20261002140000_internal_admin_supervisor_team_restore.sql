-- Restore one explicitly selected Supervisor branch and its unambiguous historical
-- operational team without reopening historical assignment rows.

create or replace function public.deactivate_internal_admin_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  target_branch_id uuid;
  active_branch_count integer;
  closed_assignments jsonb := '[]'::jsonb;
  changed_at timestamptz := now();
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists (
      select 1
      from public.organizations organization
      where organization.id = target_organization_id
        and organization.active
    )
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  with locked_memberships as (
    select membership.branch_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and branch.active
      and membership.user_id = target_user_id
      and membership.role = 'branch_manager'
      and membership.active
    for update of membership
  )
  select count(*)::integer, (pg_catalog.array_agg(branch_id order by branch_id))[1]
  into active_branch_count, target_branch_id
  from locked_memberships;

  if active_branch_count = 0 then
    raise exception 'internal admin access denied' using errcode = '42501';
  elsif active_branch_count <> 1 then
    raise exception 'supervisor active branch state conflict' using errcode = '23514';
  end if;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'assignment_id', assignment.id,
    'operational_team_id', assignment.operational_team_id,
    'assignment_role', assignment.assignment_role
  ) order by assignment.created_at, assignment.id), '[]'::jsonb)
  into closed_assignments
  from public.branch_operational_team_supervisors assignment
  where assignment.organization_id = target_organization_id
    and assignment.branch_id = target_branch_id
    and assignment.supervisor_user_id = target_user_id
    and assignment.active;

  update public.branch_operational_team_supervisors assignment
  set active = false,
      valid_to = greatest(assignment.valid_from, private.phase4a_business_date(branch.timezone)),
      updated_at = changed_at
  from public.branches branch
  where branch.id = target_branch_id
    and assignment.organization_id = target_organization_id
    and assignment.branch_id = target_branch_id
    and assignment.supervisor_user_id = target_user_id
    and assignment.active;

  update public.branch_supervisor_teams team
  set active = false,
      updated_at = changed_at
  where team.organization_id = target_organization_id
    and team.branch_id = target_branch_id
    and team.supervisor_user_id = target_user_id
    and team.active;

  update public.branch_memberships membership
  set active = false,
      updated_at = changed_at
  where membership.branch_id = target_branch_id
    and membership.user_id = target_user_id
    and membership.role = 'branch_manager'
    and membership.active;

  if not found then
    raise exception 'supervisor access changed' using errcode = '40001';
  end if;

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
    target_user_id,
    target_branch_id,
    'user_disabled',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'new_status', 'inactive',
      'branch_id', target_branch_id,
      'closed_team_assignments', closed_assignments
    )
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, false, changed_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id;
end;
$$;

create or replace function public.reactivate_internal_admin_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  target_branch_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  target_branch public.branches%rowtype;
  target_membership public.branch_memberships%rowtype;
  historical_assignment public.branch_operational_team_supervisors%rowtype;
  restored_assignment public.branch_operational_team_supervisors%rowtype;
  backup_historical_assignment public.branch_operational_team_supervisors%rowtype;
  backup_active_assignment public.branch_operational_team_supervisors%rowtype;
  backup_restored_assignment public.branch_operational_team_supervisors%rowtype;
  candidate_team_count integer := 0;
  primary_candidate_count integer := 0;
  membership_count integer := 0;
  other_active_branch_count integer := 0;
  latest_transfer_branch_id uuid;
  latest_revocation_branch_id uuid;
  latest_revocation_has_branch boolean := false;
  latest_branch_revocation_details jsonb;
  restored_team_assignments jsonb := '[]'::jsonb;
  restore_business_date date;
  changed_at timestamptz := now();
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists (
      select 1
      from public.organizations organization
      where organization.id = target_organization_id
        and organization.active
    )
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(target_organization_id::text || ':' || target_user_id::text || ':supervisor-access-restore', 0)
  );

  select branch.*
  into target_branch
  from public.branches branch
  where branch.id = target_branch_id
    and branch.organization_id = target_organization_id
    and branch.active
  for update;

  if target_branch.id is null then
    raise exception 'supervisor restore branch unavailable' using errcode = '42501';
  end if;

  select membership.*
  into target_membership
  from public.branch_memberships membership
  where membership.branch_id = target_branch_id
    and membership.user_id = target_user_id
  for update;

  if target_membership.branch_id is null or target_membership.role <> 'branch_manager' then
    raise exception 'supervisor restore branch unavailable' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id
  ) then
    raise exception 'supervisor unavailable' using errcode = 'P0002';
  end if;

  with locked_other_memberships as (
    select membership.branch_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and membership.user_id = target_user_id
      and membership.role = 'branch_manager'
      and membership.active
      and membership.branch_id <> target_branch_id
    for update of membership
  )
  select count(*)::integer
  into other_active_branch_count
  from locked_other_memberships;

  if other_active_branch_count <> 0 then
    raise exception 'supervisor active branch state conflict' using errcode = '23514';
  end if;

  select audit.branch_id
  into latest_transfer_branch_id
  from public.account_management_audit_logs audit
  where audit.organization_id = target_organization_id
    and audit.target_user_id = target_user_id
    and audit.action = 'branch_assignment_added'
    and audit.details ? 'from_branch_id'
  order by audit.created_at desc, audit.id desc
  limit 1;

  if latest_transfer_branch_id is not null and latest_transfer_branch_id <> target_branch_id then
    raise exception 'supervisor restore branch conflicts with latest transfer' using errcode = '23514';
  end if;

  select audit.branch_id, audit.branch_id is not null
  into latest_revocation_branch_id, latest_revocation_has_branch
  from public.account_management_audit_logs audit
  where audit.organization_id = target_organization_id
    and audit.target_user_id = target_user_id
    and audit.action = 'user_disabled'
    and audit.details->>'role' = 'branch_manager'
  order by audit.created_at desc, audit.id desc
  limit 1;

  if latest_transfer_branch_id is null
    and latest_revocation_has_branch
    and latest_revocation_branch_id <> target_branch_id
  then
    raise exception 'supervisor restore branch conflicts with latest revocation' using errcode = '23514';
  end if;

  if not latest_revocation_has_branch then
    select count(*)::integer
    into membership_count
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and membership.user_id = target_user_id
      and membership.role = 'branch_manager';

    if membership_count <> 1 and latest_transfer_branch_id is null then
      raise exception 'supervisor restore branch is ambiguous' using errcode = '23514';
    end if;
  end if;

  select audit.details
  into latest_branch_revocation_details
  from public.account_management_audit_logs audit
  where audit.organization_id = target_organization_id
    and audit.target_user_id = target_user_id
    and audit.branch_id = target_branch_id
    and audit.action = 'user_disabled'
    and audit.details->>'role' = 'branch_manager'
  order by audit.created_at desc, audit.id desc
  limit 1;

  select assignment.*
  into restored_assignment
  from public.branch_operational_team_supervisors assignment
  join public.branch_operational_teams team on team.id = assignment.operational_team_id
  where assignment.organization_id = target_organization_id
    and assignment.branch_id = target_branch_id
    and assignment.supervisor_user_id = target_user_id
    and assignment.active
    and team.active
  order by case assignment.assignment_role when 'primary' then 0 else 1 end,
    assignment.created_at desc,
    assignment.id
  limit 1
  for update of assignment, team;

  if restored_assignment.id is null then
    select count(distinct assignment.operational_team_id)::integer
    into primary_candidate_count
    from public.branch_operational_team_supervisors assignment
    join public.branch_operational_teams team on team.id = assignment.operational_team_id
    where assignment.organization_id = target_organization_id
      and assignment.branch_id = target_branch_id
      and assignment.supervisor_user_id = target_user_id
      and not assignment.active
      and assignment.assignment_role = 'primary'
      and team.organization_id = target_organization_id
      and team.branch_id = target_branch_id
      and team.active;

    if primary_candidate_count > 1 then
      raise exception 'supervisor historical team is ambiguous' using errcode = '23514';
    elsif primary_candidate_count = 1 then
      select assignment.*
      into historical_assignment
      from public.branch_operational_team_supervisors assignment
      join public.branch_operational_teams team on team.id = assignment.operational_team_id
      where assignment.organization_id = target_organization_id
        and assignment.branch_id = target_branch_id
        and assignment.supervisor_user_id = target_user_id
        and not assignment.active
        and assignment.assignment_role = 'primary'
        and team.active
      order by assignment.valid_to desc nulls last, assignment.updated_at desc, assignment.created_at desc, assignment.id
      limit 1;
    else
      select count(distinct assignment.operational_team_id)::integer
      into candidate_team_count
      from public.branch_operational_team_supervisors assignment
      join public.branch_operational_teams team on team.id = assignment.operational_team_id
      where assignment.organization_id = target_organization_id
        and assignment.branch_id = target_branch_id
        and assignment.supervisor_user_id = target_user_id
        and not assignment.active
        and team.organization_id = target_organization_id
        and team.branch_id = target_branch_id
        and team.active;

      if candidate_team_count > 1 then
        raise exception 'supervisor historical team is ambiguous' using errcode = '23514';
      elsif candidate_team_count = 1 then
        select assignment.*
        into historical_assignment
        from public.branch_operational_team_supervisors assignment
        join public.branch_operational_teams team on team.id = assignment.operational_team_id
        where assignment.organization_id = target_organization_id
          and assignment.branch_id = target_branch_id
          and assignment.supervisor_user_id = target_user_id
          and not assignment.active
          and team.active
        order by assignment.valid_to desc nulls last, assignment.updated_at desc, assignment.created_at desc, assignment.id
        limit 1;
      end if;
    end if;

    if historical_assignment.id is not null then
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(historical_assignment.operational_team_id::text || ':primary-supervisor', 0)
      );

      perform 1
      from public.branch_operational_teams team
      where team.id = historical_assignment.operational_team_id
        and team.organization_id = target_organization_id
        and team.branch_id = target_branch_id
        and team.active
      for update;

      if not found then
        raise exception 'supervisor historical team unavailable' using errcode = '23514';
      end if;

      perform 1
      from public.branch_operational_team_supervisors assignment
      where assignment.operational_team_id = historical_assignment.operational_team_id
        and assignment.assignment_role = 'primary'
        and assignment.active
      for update;

      if found then
        raise exception 'operational team already has active primary supervisor' using errcode = '23505';
      end if;
    end if;
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = changed_at
  where profiles.id = target_user_id;

  update public.branch_memberships membership
  set active = true,
      updated_at = changed_at
  where membership.branch_id = target_branch_id
    and membership.user_id = target_user_id
    and membership.role = 'branch_manager';

  restore_business_date := private.phase4a_business_date(target_branch.timezone);

  if restored_assignment.id is null and historical_assignment.id is not null then
    insert into public.branch_operational_team_supervisors(
      organization_id,
      branch_id,
      operational_team_id,
      supervisor_user_id,
      assignment_role,
      active,
      valid_from,
      valid_to,
      created_by
    )
    values(
      target_organization_id,
      target_branch_id,
      historical_assignment.operational_team_id,
      target_user_id,
      historical_assignment.assignment_role,
      true,
      restore_business_date,
      null,
      actor_user_id
    )
    returning * into restored_assignment;
  end if;

  if restored_assignment.id is not null then
    restored_team_assignments := restored_team_assignments || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'assignment_id', restored_assignment.id,
        'operational_team_id', restored_assignment.operational_team_id,
        'assignment_role', restored_assignment.assignment_role,
        'historical_assignment_id', historical_assignment.id
      )
    );
  end if;

  for backup_historical_assignment in
    select assignment.*
    from pg_catalog.jsonb_to_recordset(
      case
        when pg_catalog.jsonb_typeof(latest_branch_revocation_details->'closed_team_assignments') = 'array'
          then latest_branch_revocation_details->'closed_team_assignments'
        else '[]'::jsonb
      end
    ) as revoked(assignment_id uuid, operational_team_id uuid, assignment_role text)
    join public.branch_operational_team_supervisors assignment
      on assignment.id = revoked.assignment_id
     and assignment.operational_team_id = revoked.operational_team_id
     and assignment.assignment_role = revoked.assignment_role
    join public.branch_operational_teams team
      on team.id = assignment.operational_team_id
    where revoked.assignment_role = 'backup'
      and assignment.organization_id = target_organization_id
      and assignment.branch_id = target_branch_id
      and assignment.supervisor_user_id = target_user_id
      and assignment.assignment_role = 'backup'
      and not assignment.active
      and team.organization_id = target_organization_id
      and team.branch_id = target_branch_id
      and team.active
    order by assignment.operational_team_id, assignment.id
    for update of assignment, team
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(backup_historical_assignment.operational_team_id::text || ':supervisor-assignment', 0)
    );

    backup_active_assignment := null;
    select assignment.*
    into backup_active_assignment
    from public.branch_operational_team_supervisors assignment
    where assignment.operational_team_id = backup_historical_assignment.operational_team_id
      and assignment.supervisor_user_id = target_user_id
      and assignment.active
    for update;

    if backup_active_assignment.id is not null
      and backup_active_assignment.assignment_role <> 'backup'
    then
      raise exception 'supervisor team assignment already exists' using errcode = '23505';
    end if;

    if backup_active_assignment.id is null then
      insert into public.branch_operational_team_supervisors(
        organization_id,
        branch_id,
        operational_team_id,
        supervisor_user_id,
        assignment_role,
        active,
        valid_from,
        valid_to,
        created_by
      )
      values(
        target_organization_id,
        target_branch_id,
        backup_historical_assignment.operational_team_id,
        target_user_id,
        'backup',
        true,
        restore_business_date,
        null,
        actor_user_id
      )
      returning * into backup_restored_assignment;
    else
      backup_restored_assignment := backup_active_assignment;
    end if;

    restored_team_assignments := restored_team_assignments || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'assignment_id', backup_restored_assignment.id,
        'operational_team_id', backup_restored_assignment.operational_team_id,
        'assignment_role', backup_restored_assignment.assignment_role,
        'historical_assignment_id', backup_historical_assignment.id
      )
    );
  end loop;

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
    target_user_id,
    target_branch_id,
    'user_enabled',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'new_status', 'active',
      'branch_id', target_branch_id,
      'restored_operational_team_id', restored_assignment.operational_team_id,
      'new_assignment_id', restored_assignment.id,
      'historical_assignment_id', historical_assignment.id,
      'restored_team_assignments', restored_team_assignments,
      'idempotent', historical_assignment.id is null and restored_assignment.id is not null
    )
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, true, changed_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id;
end;
$$;

create or replace function public.reactivate_internal_admin_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  resolved_branch_id uuid;
  active_membership_count integer;
  membership_count integer;
begin
  select count(*)::integer,
    (pg_catalog.array_agg(membership.branch_id order by membership.branch_id))[1]
  into active_membership_count, resolved_branch_id
  from public.branch_memberships membership
  join public.branches branch on branch.id = membership.branch_id
  where branch.organization_id = target_organization_id
    and branch.active
    and membership.user_id = target_user_id
    and membership.role = 'branch_manager'
    and membership.active;

  if active_membership_count = 0 then
    select count(*)::integer,
      (pg_catalog.array_agg(membership.branch_id order by membership.branch_id))[1]
    into membership_count, resolved_branch_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and branch.active
      and membership.user_id = target_user_id
      and membership.role = 'branch_manager';

    if membership_count <> 1 then
      raise exception 'explicit supervisor restore branch required' using errcode = '22023';
    end if;
  elsif active_membership_count <> 1 then
    raise exception 'explicit supervisor restore branch required' using errcode = '22023';
  end if;

  return query
    select *
    from public.reactivate_internal_admin_supervisor(
      actor_user_id,
      target_organization_id,
      target_user_id,
      resolved_branch_id
    );
end;
$$;

revoke all on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid, uuid)
  to service_role;

revoke all on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid)
  to service_role;

revoke all on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid)
  to service_role;
