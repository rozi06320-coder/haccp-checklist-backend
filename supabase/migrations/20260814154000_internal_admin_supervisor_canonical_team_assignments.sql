create or replace function private.apply_internal_admin_supervisor_team_assignments(
  actor_user_id uuid,
  target_organization_id uuid,
  target_supervisor_user_id uuid,
  target_branch_ids uuid[],
  target_team_assignments jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  entry jsonb;
  team_id_text text;
  team_id uuid;
  assignment_role text;
  team_ids uuid[] := array[]::uuid[];
  team_roles text[] := array[]::text[];
  valid_team_count integer;
  inserted_count integer := 0;
  last_row_count integer;
begin
  if pg_catalog.jsonb_typeof(coalesce(target_team_assignments, '[]'::jsonb)) is distinct from 'array' then
    raise exception 'invalid supervisor team assignment' using errcode = '22023';
  end if;

  for entry in select value from pg_catalog.jsonb_array_elements(coalesce(target_team_assignments, '[]'::jsonb)) loop
    if pg_catalog.jsonb_typeof(entry) is distinct from 'object' then
      raise exception 'invalid supervisor team assignment' using errcode = '22023';
    end if;

    team_id_text := entry->>'operational_team_id';
    assignment_role := entry->>'assignment_role';

    if team_id_text is null
      or team_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or assignment_role not in ('primary', 'backup')
    then
      raise exception 'invalid supervisor team assignment' using errcode = '22023';
    end if;

    team_id := team_id_text::uuid;
    if array_position(team_ids, team_id) is not null then
      raise exception 'invalid supervisor team assignment' using errcode = '22023';
    end if;

    team_ids := array_append(team_ids, team_id);
    team_roles := array_append(team_roles, assignment_role);
  end loop;

  if coalesce(pg_catalog.array_length(team_ids, 1), 0) = 0
    or pg_catalog.array_length(team_ids, 1) > 50
  then
    raise exception 'invalid supervisor team assignment' using errcode = '22023';
  end if;

  select count(*) into valid_team_count
  from public.branch_operational_teams team
  where team.id = any(team_ids)
    and team.organization_id = target_organization_id
    and team.branch_id = any(target_branch_ids)
    and team.active;

  if valid_team_count <> pg_catalog.array_length(team_ids, 1) then
    raise exception 'invalid supervisor team assignment' using errcode = '23514';
  end if;

  for index_value in 1..pg_catalog.array_length(team_ids, 1) loop
    if team_roles[index_value] = 'primary'
      and exists (
        select 1
        from public.branch_operational_team_supervisors assignment
        where assignment.operational_team_id = team_ids[index_value]
          and assignment.assignment_role = 'primary'
          and assignment.active
          and assignment.supervisor_user_id <> target_supervisor_user_id
      )
    then
      raise exception 'primary supervisor already assigned' using errcode = '23505';
    end if;

    if exists (
      select 1
      from public.branch_operational_team_supervisors assignment
      where assignment.operational_team_id = team_ids[index_value]
        and assignment.supervisor_user_id = target_supervisor_user_id
        and assignment.active
        and assignment.assignment_role <> team_roles[index_value]
    ) then
      raise exception 'supervisor team assignment already exists' using errcode = '23505';
    end if;

    insert into public.branch_operational_team_supervisors(
      organization_id,
      branch_id,
      operational_team_id,
      supervisor_user_id,
      assignment_role,
      created_by
    )
    select
      team.organization_id,
      team.branch_id,
      team.id,
      target_supervisor_user_id,
      team_roles[index_value],
      actor_user_id
    from public.branch_operational_teams team
    where team.id = team_ids[index_value]
      and not exists (
        select 1
        from public.branch_operational_team_supervisors existing
        where existing.operational_team_id = team.id
          and existing.supervisor_user_id = target_supervisor_user_id
          and existing.active
          and existing.assignment_role = team_roles[index_value]
      );

    get diagnostics last_row_count = row_count;
    inserted_count := inserted_count + last_row_count;
  end loop;

  return inserted_count;
end;
$$;

create or replace function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_branch_ids uuid[],
  p_full_name_ar text,
  p_team_assignments jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  branch_id uuid;
  changed_rows integer;
  normalized_full_name_ar text := private.clean_optional_master_name(p_full_name_ar);
  assignment_count integer;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;
  if p_full_name is null or pg_catalog.btrim(p_full_name) = '' or pg_catalog.length(pg_catalog.btrim(p_full_name)) > 120 then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;
  if p_branch_ids is null or pg_catalog.cardinality(p_branch_ids) = 0 then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.count(distinct item)
    from pg_catalog.unnest(p_branch_ids) as item
  ) then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.cardinality(p_branch_ids)
    from public.branches branch
    where branch.id = any(p_branch_ids)
      and branch.organization_id = p_organization_id
      and branch.active
  ) then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;

  update public.profiles
  set full_name = pg_catalog.regexp_replace(pg_catalog.btrim(p_full_name), '\s+', ' ', 'g'),
      full_name_ar = normalized_full_name_ar,
      must_change_password = false,
      disabled_at = null
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.branch_memberships (branch_id, user_id, role, active)
  select item, p_new_user_id, 'branch_manager', true
  from pg_catalog.unnest(p_branch_ids) as item
  on conflict on constraint branch_memberships_pkey do update
    set role = 'branch_manager',
        active = true,
        updated_at = now();

  assignment_count := private.apply_internal_admin_supervisor_team_assignments(
    p_actor_user_id,
    p_organization_id,
    p_new_user_id,
    p_branch_ids,
    p_team_assignments
  );

  insert into public.account_management_audit_logs (
    organization_id, actor_user_id, target_user_id, action, details
  ) values (
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'user_created',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'branch_count', pg_catalog.cardinality(p_branch_ids),
      'operational_team_assignment_count', assignment_count
    )
  );

  foreach branch_id in array p_branch_ids loop
    insert into public.account_management_audit_logs (
      organization_id, actor_user_id, target_user_id, branch_id, action, details
    ) values (
      p_organization_id,
      p_actor_user_id,
      p_new_user_id,
      branch_id,
      'branch_assignment_added',
      pg_catalog.jsonb_build_object('role', 'branch_manager')
    );
  end loop;

  update public.profiles
  set must_change_password = true,
      updated_at = now()
  where id = p_new_user_id;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create or replace function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_branch_ids uuid[],
  p_full_name_ar text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.finalize_provisioned_supervisor(
    p_actor_user_id,
    p_organization_id,
    p_new_user_id,
    p_full_name,
    p_branch_ids,
    p_full_name_ar,
    '[]'::jsonb
  )
$$;

create or replace function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_branch_ids uuid[]
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.finalize_provisioned_supervisor(
    p_actor_user_id,
    p_organization_id,
    p_new_user_id,
    p_full_name,
    p_branch_ids,
    null,
    '[]'::jsonb
  )
$$;

drop function if exists public.grant_existing_branch_supervisor(uuid, uuid, text, uuid[], jsonb);

create function public.grant_existing_branch_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_email text,
  target_branch_ids uuid[],
  target_team_assignments jsonb
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
declare
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(target_email));
  target_auth_user auth.users%rowtype;
  assigned_branch_id uuid;
  assignment_count integer;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if normalized_email is null or normalized_email = '' or pg_catalog.length(normalized_email) > 254 then
    raise exception 'invalid existing user email' using errcode = '22023';
  end if;
  if target_branch_ids is null or pg_catalog.cardinality(target_branch_ids) = 0 then
    raise exception 'invalid branch assignment' using errcode = '22023';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.count(distinct item)
    from pg_catalog.unnest(target_branch_ids) as item
  ) then
    raise exception 'invalid branch assignment' using errcode = '22023';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.cardinality(target_branch_ids)
    from public.branches branch
    where branch.id = any(target_branch_ids)
      and branch.organization_id = target_organization_id
      and branch.active
  ) then
    raise exception 'invalid branch assignment' using errcode = '22023';
  end if;

  select auth_user.* into target_auth_user
  from auth.users auth_user
  where pg_catalog.lower(auth_user.email::text) = normalized_email
  limit 1;

  if target_auth_user.id is null then
    raise exception 'existing user not found' using errcode = 'P0002';
  end if;
  if not exists(select 1 from public.profiles profile where profile.id = target_auth_user.id and not profile.must_change_password) then
    raise exception 'existing profile not found' using errcode = 'P0002';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_auth_user.id;

  foreach assigned_branch_id in array target_branch_ids loop
    insert into public.branch_memberships(branch_id, user_id, role, active)
    values(assigned_branch_id, target_auth_user.id, 'branch_manager', true)
    on conflict on constraint branch_memberships_pkey do update
      set role = 'branch_manager',
          active = true,
          updated_at = now();
  end loop;

  assignment_count := private.apply_internal_admin_supervisor_team_assignments(
    actor_user_id,
    target_organization_id,
    target_auth_user.id,
    target_branch_ids,
    target_team_assignments
  );

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_auth_user.id,
    'user_enabled',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'branch_count', pg_catalog.cardinality(target_branch_ids),
      'operational_team_assignment_count', assignment_count
    )
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, true, now()
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_auth_user.id;
end;
$$;

create or replace function public.grant_existing_branch_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_email text,
  target_branch_ids uuid[]
)
returns table(
  id uuid,
  full_name text,
  email text,
  active boolean,
  updated_at timestamptz
)
language sql
security definer
set search_path = ''
as $$
  select *
  from public.grant_existing_branch_supervisor(
    actor_user_id,
    target_organization_id,
    target_email,
    target_branch_ids,
    '[]'::jsonb
  )
$$;

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
declare
  changed_rows integer;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.branch_memberships membership
  set active = false,
      updated_at = now()
  from public.branches branch
  where branch.id = membership.branch_id
    and branch.organization_id = target_organization_id
    and membership.user_id = target_user_id
    and membership.role = 'branch_manager';
  get diagnostics changed_rows = row_count;

  if changed_rows = 0 then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.branch_operational_team_supervisors assignment
  set active = false,
      valid_to = greatest(assignment.valid_from, current_date),
      updated_at = now()
  where assignment.organization_id = target_organization_id
    and assignment.supervisor_user_id = target_user_id
    and assignment.active;

  update public.branch_supervisor_teams team
  set active = false,
      updated_at = now()
  where team.organization_id = target_organization_id
    and team.supervisor_user_id = target_user_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_disabled',
    pg_catalog.jsonb_build_object('role', 'branch_manager', 'new_status', 'inactive')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, false, now()
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
declare
  changed_rows integer;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.branch_memberships membership
  set active = true,
      updated_at = now()
  from public.branches branch
  where branch.id = membership.branch_id
    and branch.organization_id = target_organization_id
    and branch.active
    and membership.user_id = target_user_id
    and membership.role = 'branch_manager';
  get diagnostics changed_rows = row_count;

  if changed_rows = 0 then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.profiles
  set disabled_at = null,
      updated_at = now()
  where profiles.id = target_user_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_enabled',
    pg_catalog.jsonb_build_object('role', 'branch_manager', 'new_status', 'active')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text, true, now()
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id;
end;
$$;

revoke all on function private.apply_internal_admin_supervisor_team_assignments(uuid, uuid, uuid, uuid[], jsonb) from public, anon, authenticated;
grant execute on function private.apply_internal_admin_supervisor_team_assignments(uuid, uuid, uuid, uuid[], jsonb) to service_role;

revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb) from public, anon, authenticated;
revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) from public, anon, authenticated;
revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb) to service_role;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) to service_role;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) to service_role;

revoke all on function public.grant_existing_branch_supervisor(uuid, uuid, text, uuid[], jsonb) from public, anon, authenticated;
revoke all on function public.grant_existing_branch_supervisor(uuid, uuid, text, uuid[]) from public, anon, authenticated;
grant execute on function public.grant_existing_branch_supervisor(uuid, uuid, text, uuid[], jsonb) to service_role;
grant execute on function public.grant_existing_branch_supervisor(uuid, uuid, text, uuid[]) to service_role;

revoke all on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) to service_role;
grant execute on function public.reactivate_internal_admin_supervisor(uuid, uuid, uuid) to service_role;
