alter table public.organizations
  add column if not exists name_ar text;

alter table public.branches
  add column if not exists name_ar text;

alter table public.profiles
  add column if not exists full_name_ar text;

alter table public.organizations
  drop constraint if exists organizations_name_ar_format;

alter table public.organizations
  add constraint organizations_name_ar_format
  check (
    name_ar is null
    or (
      name_ar = pg_catalog.regexp_replace(pg_catalog.btrim(name_ar), '[[:space:]]+', ' ', 'g')
      and length(name_ar) between 1 and 120
    )
  );

alter table public.branches
  drop constraint if exists branches_name_ar_format;

alter table public.branches
  add constraint branches_name_ar_format
  check (
    name_ar is null
    or (
      name_ar = pg_catalog.regexp_replace(pg_catalog.btrim(name_ar), '[[:space:]]+', ' ', 'g')
      and length(name_ar) between 1 and 120
    )
  );

alter table public.profiles
  drop constraint if exists profiles_full_name_ar_format;

alter table public.profiles
  add constraint profiles_full_name_ar_format
  check (
    full_name_ar is null
    or (
      full_name_ar = pg_catalog.regexp_replace(pg_catalog.btrim(full_name_ar), '[[:space:]]+', ' ', 'g')
      and length(full_name_ar) between 1 and 120
    )
  );

create or replace function private.clean_optional_master_name(value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(value, '')), '[[:space:]]+', ' ', 'g'), '')
$$;

drop function if exists public.create_internal_admin_organization(uuid, text);
drop function if exists public.create_internal_admin_organization(uuid, text, text);

create function public.create_internal_admin_organization(
  actor_user_id uuid,
  organization_name text,
  organization_name_ar text
)
returns table(id uuid, name text, name_ar text, slug text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(organization_name, '')), '\s+', ' ', 'g');
  normalized_name_ar text := private.clean_optional_master_name(organization_name_ar);
  base_slug text;
  candidate_slug text;
  suffix int := 0;
  created public.organizations%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or length(normalized_name) = 0
    or length(normalized_name) > 120
  then
    raise exception 'invalid organization creation request' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.organizations organization
    where pg_catalog.lower(pg_catalog.btrim(organization.name)) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'organization already exists' using errcode = '23505';
  end if;

  base_slug := pg_catalog.regexp_replace(pg_catalog.lower(normalized_name), '[^a-z0-9]+', '-', 'g');
  base_slug := pg_catalog.regexp_replace(base_slug, '(^-+|-+$)', '', 'g');
  if base_slug = '' then
    base_slug := 'organization';
  end if;

  loop
    candidate_slug := case when suffix = 0 then base_slug else base_slug || '-' || suffix::text end;
    exit when not exists (select 1 from public.organizations organization where organization.slug = candidate_slug);
    suffix := suffix + 1;
    if suffix > 999 then
      raise exception 'organization slug generation failed' using errcode = '54000';
    end if;
  end loop;

  insert into public.organizations(name, name_ar, slug, active)
  values(normalized_name, normalized_name_ar, candidate_slug, true)
  returning * into created;

  return query select created.id, created.name, created.name_ar, created.slug, created.active;
end;
$$;

revoke all on function public.create_internal_admin_organization(uuid,text,text) from public, anon, authenticated;
grant execute on function public.create_internal_admin_organization(uuid,text,text) to service_role;

create function public.create_internal_admin_organization(
  actor_user_id uuid,
  organization_name text
)
returns table(id uuid, name text, slug text, active boolean)
language sql
security definer
set search_path = ''
as $$
  select created.id, created.name, created.slug, created.active
  from public.create_internal_admin_organization(actor_user_id, organization_name, null) as created
$$;

revoke all on function public.create_internal_admin_organization(uuid,text) from public, anon, authenticated;
grant execute on function public.create_internal_admin_organization(uuid,text) to service_role;

drop function if exists public.list_internal_admin_organizations(uuid);

create function public.list_internal_admin_organizations(actor_user_id uuid)
returns table(id uuid, name text, name_ar text, active boolean, logo_path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'organization list access denied' using errcode = '42501';
  end if;

  return query
  select organization.id, organization.name, organization.name_ar, organization.active, organization.logo_path
  from public.organizations organization
  order by organization.name, organization.id
  limit 200;
end;
$$;

revoke all on function public.list_internal_admin_organizations(uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_organizations(uuid) to service_role;

drop function if exists public.create_managed_branch(uuid, uuid, text, text, boolean);
drop function if exists public.create_managed_branch(uuid, uuid, text, text, boolean, text);

create function public.create_managed_branch(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_name text,
  branch_timezone text,
  branch_active boolean,
  branch_name_ar text
) returns table(id uuid, name text, name_ar text, code text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(branch_name, '')), '\s+', ' ', 'g');
  normalized_name_ar text := private.clean_optional_master_name(branch_name_ar);
  normalized_timezone text := pg_catalog.btrim(coalesce(branch_timezone, 'Asia/Riyadh'));
  candidate_code text;
  suffix int := 0;
  created_branch public.branches%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or length(normalized_name) = 0
    or length(normalized_name) > 120
    or length(normalized_timezone) = 0
    or length(normalized_timezone) > 80
    or not exists (select 1 from pg_catalog.pg_timezone_names zone where zone.name = normalized_timezone)
  then
    raise exception 'invalid branch creation request' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.branches branch
    where branch.organization_id = target_organization_id
      and pg_catalog.lower(pg_catalog.btrim(branch.name)) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'branch already exists' using errcode = '23505';
  end if;

  loop
    candidate_code := private.branch_code_candidate(normalized_name, suffix);
    exit when not exists (
      select 1
      from public.branches branch
      where branch.organization_id = target_organization_id
        and branch.code = candidate_code
    );
    suffix := suffix + 1;
    if suffix > 999 then
      raise exception 'branch code generation failed' using errcode = '54000';
    end if;
  end loop;

  insert into public.branches(organization_id, name, name_ar, code, timezone, active)
  values(target_organization_id, normalized_name, normalized_name_ar, candidate_code, normalized_timezone, coalesce(branch_active, true))
  returning * into created_branch;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    created_branch.id,
    'branch_created',
    pg_catalog.jsonb_build_object('branch_name', created_branch.name, 'branch_code', created_branch.code)
  );

  return query select created_branch.id, created_branch.name, created_branch.name_ar, created_branch.code, created_branch.timezone, created_branch.active;
end;
$$;

revoke all on function public.create_managed_branch(uuid,uuid,text,text,boolean,text) from public, anon, authenticated;
grant execute on function public.create_managed_branch(uuid,uuid,text,text,boolean,text) to service_role;

create function public.create_managed_branch(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_name text,
  branch_timezone text default 'Asia/Riyadh',
  branch_active boolean default true
) returns table(id uuid, name text, code text, timezone text, active boolean)
language sql
security definer
set search_path = ''
as $$
  select created.id, created.name, created.code, created.timezone, created.active
  from public.create_managed_branch(actor_user_id, target_organization_id, branch_name, branch_timezone, branch_active, null) as created
$$;

revoke all on function public.create_managed_branch(uuid,uuid,text,text,boolean) from public, anon, authenticated;
grant execute on function public.create_managed_branch(uuid,uuid,text,text,boolean) to service_role;

drop function if exists public.list_internal_admin_branches(uuid, uuid);
create function public.list_internal_admin_branches(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  name text,
  name_ar text,
  code text,
  active boolean,
  logo_path text
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
    select branch.id, branch.name, branch.name_ar, branch.code, branch.active, branch.logo_path
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    where branch.organization_id = target_organization_id
      and organization.active
    order by branch.active desc, pg_catalog.lower(branch.name), branch.id
    limit 500;
end;
$$;

revoke all on function public.list_internal_admin_branches(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_branches(uuid, uuid) to service_role;

drop function if exists public.list_internal_admin_supervisors(uuid, uuid);

create function public.list_internal_admin_supervisors(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  full_name_ar text,
  email text,
  branches jsonb,
  active boolean,
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
    select profile.id, profile.full_name, profile.full_name_ar, auth_user.email::text,
      coalesce(jsonb_agg(distinct jsonb_build_object(
        'id', branch.id,
        'name', branch.name,
        'name_ar', branch.name_ar,
        'code', branch.code,
        'active', membership.active
      )) filter (where branch.id is not null), '[]'::jsonb) as branches,
      coalesce(pg_catalog.bool_or(membership.active), false) as active,
      profile.disabled_at is not null as disabled,
      profile.must_change_password,
      profile.created_at
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where branch.organization_id = target_organization_id
      and membership.role = 'branch_manager'
    group by profile.id, profile.full_name, profile.full_name_ar, auth_user.email, profile.disabled_at, profile.must_change_password, profile.created_at
    order by coalesce(pg_catalog.bool_or(membership.active), false) desc,
      profile.disabled_at is not null,
      pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

revoke all on function public.list_internal_admin_supervisors(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_supervisors(uuid, uuid) to service_role;

drop function if exists public.list_internal_admin_organization_managers(uuid, uuid);

create function public.list_internal_admin_organization_managers(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  full_name_ar text,
  email text,
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  active boolean,
  must_change_password boolean,
  disabled boolean,
  created_at timestamptz,
  updated_at timestamptz
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
    select profile.id, profile.full_name, profile.full_name_ar, auth_user.email::text,
      organization.id, organization.name, organization.name_ar, membership.active,
      profile.must_change_password,
      profile.disabled_at is not null as disabled,
      profile.created_at,
      membership.updated_at
    from public.organization_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.role = 'organization_manager'
    order by membership.active desc, profile.disabled_at is not null,
      pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

revoke all on function public.list_internal_admin_organization_managers(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_organization_managers(uuid, uuid) to service_role;

drop function if exists public.list_internal_admin_branch_teams(uuid, uuid);

create function public.list_internal_admin_branch_teams(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  team_id uuid,
  organization_id uuid,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_name_ar text,
  supervisor_email text,
  supervisor_role text,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = target_organization_id
      and organization.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select
      team.id,
      team.organization_id,
      team.company_name,
      branch.id,
      branch.name,
      branch.name_ar,
      branch.code,
      team.supervisor_user_id,
      profile.full_name,
      profile.full_name_ar,
      auth_user.email::text,
      membership.role,
      team.active,
      count(assignment.id) filter (where assignment.active),
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'staff_id', staff.id,
            'display_name', staff.display_name,
            'company_name', staff.company_name,
            'staff_code', staff.staff_code,
            'employment_status', staff.employment_status,
            'assignment_id', assignment.id,
            'operational_roles', assignment.operational_roles
          )
          order by pg_catalog.lower(staff.display_name), staff.id
        ) filter (where staff.id is not null and assignment.active),
        '[]'::jsonb
      ) as staff
    from public.branch_supervisor_teams team
    join public.branches branch on branch.id = team.branch_id
    join public.profiles profile on profile.id = team.supervisor_user_id
    join auth.users auth_user on auth_user.id = team.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id = team.branch_id
      and membership.user_id = team.supervisor_user_id
      and membership.role = 'branch_manager'
    left join public.operational_staff_assignments assignment on assignment.supervisor_team_id = team.id
    left join public.operational_staff staff on staff.id = assignment.operational_staff_id
    where team.organization_id = target_organization_id
      and branch.organization_id = target_organization_id
    group by team.id, team.organization_id, team.company_name, branch.id, branch.name, branch.name_ar, branch.code,
      team.supervisor_user_id, profile.full_name, profile.full_name_ar, auth_user.email, membership.role, team.active
    order by coalesce(team.company_name, ''), branch.name, profile.full_name, auth_user.email, team.id
    limit 500;
end;
$$;

revoke all on function public.list_internal_admin_branch_teams(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_branch_teams(uuid, uuid) to service_role;

drop function if exists public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text);

create function public.list_managed_organization_users(
  actor_user_id uuid,
  target_organization_id uuid,
  requested_page integer default 1,
  requested_page_size integer default 20,
  search_term text default null,
  role_filter text default null,
  branch_filter uuid default null,
  lifecycle_filter text default null
)
returns table (
  id uuid,
  full_name text,
  full_name_ar text,
  email text,
  role text,
  branches jsonb,
  disabled boolean,
  must_change_password boolean,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_search text := nullif(pg_catalog.btrim(search_term), '');
begin
  if actor_user_id is null
    or target_organization_id is null
    or requested_page < 1
    or requested_page_size < 1
    or requested_page_size > 50
    or pg_catalog.length(coalesce(search_term, '')) > 120
    or (role_filter is not null and role_filter not in ('staff', 'branch_manager'))
    or (lifecycle_filter is not null and lifecycle_filter not in ('active', 'password_change_required', 'disabled'))
  then
    raise exception 'invalid listing input' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.organization_memberships membership
    join public.profiles actor_profile on actor_profile.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.user_id = actor_user_id
      and membership.role = 'organization_manager'
      and actor_profile.disabled_at is null
      and not actor_profile.must_change_password
  ) then
    raise exception 'listing denied' using errcode = '42501';
  end if;

  if branch_filter is not null and not exists (
    select 1
    from public.branches branch
    where branch.id = branch_filter
      and branch.organization_id = target_organization_id
  ) then
    raise exception 'invalid listing input' using errcode = '22023';
  end if;

  return query
  with organization_accounts as (
    select
      profile.id,
      profile.full_name,
      profile.full_name_ar,
      auth_user.email::text as email,
      membership.role,
      profile.disabled_at is not null as disabled,
      profile.must_change_password,
      profile.created_at,
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', branch.id,
          'name', branch.name,
          'name_ar', branch.name_ar,
          'code', branch.code
        )
        order by branch.name, branch.id
      ) as branches
    from public.branch_memberships membership
    join public.branches branch
      on branch.id = membership.branch_id
      and branch.organization_id = target_organization_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = profile.id
    where (role_filter is null or membership.role = role_filter)
      and (branch_filter is null or exists (
        select 1
        from public.branch_memberships filtered_membership
        join public.branches filtered_branch
          on filtered_branch.id = filtered_membership.branch_id
        where filtered_membership.user_id = membership.user_id
          and filtered_membership.role = membership.role
          and filtered_branch.organization_id = target_organization_id
          and filtered_branch.id = branch_filter
      ))
      and (
        lifecycle_filter is null
        or (lifecycle_filter = 'active' and profile.disabled_at is null and not profile.must_change_password)
        or (lifecycle_filter = 'password_change_required' and profile.disabled_at is null and profile.must_change_password)
        or (lifecycle_filter = 'disabled' and profile.disabled_at is not null)
      )
      and (
        normalized_search is null
        or profile.full_name ilike '%' || normalized_search || '%'
        or profile.full_name_ar ilike '%' || normalized_search || '%'
        or auth_user.email ilike '%' || normalized_search || '%'
      )
    group by profile.id, profile.full_name, profile.full_name_ar, auth_user.email, membership.role,
      profile.disabled_at, profile.must_change_password, profile.created_at
  ),
  counted as (
    select account.*, pg_catalog.count(*) over () as matching_count
    from organization_accounts account
  )
  select
    account.id,
    account.full_name,
    account.full_name_ar,
    account.email,
    account.role,
    account.branches,
    account.disabled,
    account.must_change_password,
    account.created_at,
    account.matching_count
  from counted account
  order by pg_catalog.lower(coalesce(account.full_name, '')), account.id
  limit requested_page_size
  offset ((requested_page - 1)::bigint * requested_page_size::bigint);
end;
$$;

revoke all on function public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)
  to service_role;

drop function if exists public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]);
drop function if exists public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text);

create function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_branch_ids uuid[],
  p_full_name_ar text
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
  normalized_full_name_ar text := private.clean_optional_master_name(p_full_name_ar);
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
    created_team_id := null;

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
    on conflict do nothing
    returning id into created_team_id;

    if created_team_id is not null then
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
    end if;
  end loop;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text) to service_role;

create function public.finalize_provisioned_supervisor(
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
  select public.finalize_provisioned_supervisor(p_actor_user_id, p_organization_id, p_new_user_id, p_full_name, p_branch_ids, null)
$$;

revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) to service_role;

drop function if exists public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text);
drop function if exists public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text);

create function public.finalize_provisioned_organization_manager(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_full_name_ar text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
  normalized_full_name_ar text := private.clean_optional_master_name(p_full_name_ar);
begin
  if p_full_name is null or pg_catalog.btrim(p_full_name) = '' or pg_catalog.length(pg_catalog.btrim(p_full_name)) > 120 then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;

  if not private.is_internal_admin(p_actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = p_organization_id and organization.active)
  then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  update public.profiles
  set full_name = pg_catalog.regexp_replace(pg_catalog.btrim(p_full_name), '\s+', ' ', 'g'),
      full_name_ar = normalized_full_name_ar,
      must_change_password = true,
      disabled_at = null,
      updated_at = now()
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.organization_memberships(organization_id, user_id, role, active)
  values(p_organization_id, p_new_user_id, 'organization_manager', true)
  on conflict(organization_id, user_id) do update
    set role = 'organization_manager',
        active = true,
        updated_at = now();

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'user_created',
    pg_catalog.jsonb_build_object('role', 'organization_manager', 'new_status', 'active')
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

revoke all on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text, text) to service_role;

create function public.finalize_provisioned_organization_manager(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.finalize_provisioned_organization_manager(p_actor_user_id, p_organization_id, p_new_user_id, p_full_name, null)
$$;

revoke all on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.finalize_provisioned_organization_manager(uuid, uuid, uuid, text) to service_role;
