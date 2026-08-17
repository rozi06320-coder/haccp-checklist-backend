create or replace function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_branch_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  branch_id uuid;
  changed_rows integer;
  created_team_id uuid;
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
      must_change_password = true,
      disabled_at = null
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.branch_memberships (branch_id, user_id, role)
  select item, p_new_user_id, 'branch_manager'
  from pg_catalog.unnest(p_branch_ids) as item;

  insert into public.account_management_audit_logs (
    organization_id, actor_user_id, target_user_id, action, details
  ) values (
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'user_created',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'branch_count', pg_catalog.cardinality(p_branch_ids)
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

    insert into public.branch_supervisor_teams (
      organization_id,
      branch_id,
      supervisor_user_id
    ) values (
      p_organization_id,
      branch_id,
      p_new_user_id
    )
    returning id into created_team_id;

    insert into public.account_management_audit_logs (
      organization_id,
      actor_user_id,
      target_user_id,
      branch_id,
      action,
      details
    ) values (
      p_organization_id,
      p_actor_user_id,
      p_new_user_id,
      branch_id,
      'supervisor_team_assigned',
      pg_catalog.jsonb_build_object(
        'team_id', created_team_id,
        'new_status', 'active'
      )
    );
  end loop;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create function public.list_internal_admin_branches(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  name text,
  code text,
  active boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select branch.id, branch.name, branch.code, branch.active
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    where branch.organization_id = target_organization_id
      and organization.active
    order by branch.active desc, pg_catalog.lower(branch.name), branch.id
    limit 500;
end;
$$;

create function public.list_internal_admin_supervisors(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  branches jsonb,
  disabled boolean,
  must_change_password boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select profile.id, profile.full_name, auth_user.email::text,
      coalesce(jsonb_agg(distinct jsonb_build_object(
        'id', branch.id,
        'name', branch.name,
        'code', branch.code
      )) filter (where branch.id is not null), '[]'::jsonb) as branches,
      profile.disabled_at is not null as disabled,
      profile.must_change_password,
      profile.created_at
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where branch.organization_id = target_organization_id
      and membership.role = 'branch_manager'
    group by profile.id, profile.full_name, auth_user.email, profile.disabled_at, profile.must_change_password, profile.created_at
    order by profile.disabled_at is not null, pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

create function public.deactivate_internal_admin_supervisor(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns table(
  id uuid,
  full_name text,
  email text,
  disabled boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where membership.user_id = target_user_id
      and membership.role = 'branch_manager'
      and branch.organization_id = target_organization_id
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.profiles
  set disabled_at = coalesce(disabled_at, now()),
      updated_at = now()
  where id = target_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'user_disabled',
    pg_catalog.jsonb_build_object('role', 'branch_manager')
  );

  return query
    select profile.id, profile.full_name, auth_user.email::text,
      profile.disabled_at is not null as disabled, profile.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = target_user_id;
end;
$$;

revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) from public, anon, authenticated;
revoke all on function public.list_internal_admin_branches(uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_internal_admin_supervisors(uuid, uuid) from public, anon, authenticated;
revoke all on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) to service_role;
grant execute on function public.list_internal_admin_branches(uuid, uuid) to service_role;
grant execute on function public.list_internal_admin_supervisors(uuid, uuid) to service_role;
grant execute on function public.deactivate_internal_admin_supervisor(uuid, uuid, uuid) to service_role;
