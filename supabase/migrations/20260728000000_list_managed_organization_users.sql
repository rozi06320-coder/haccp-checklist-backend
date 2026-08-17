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
      auth_user.email::text as email,
      membership.role,
      profile.disabled_at is not null as disabled,
      profile.must_change_password,
      profile.created_at,
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', branch.id,
          'name', branch.name,
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
        or auth_user.email ilike '%' || normalized_search || '%'
      )
    group by profile.id, profile.full_name, auth_user.email, membership.role,
      profile.disabled_at, profile.must_change_password, profile.created_at
  ),
  counted as (
    select account.*, pg_catalog.count(*) over () as matching_count
    from organization_accounts account
  )
  select
    account.id,
    account.full_name,
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

comment on function public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text) is
  'Service-role-only bounded organization account listing. Revalidates the exact active manager actor and returns an allowlisted projection.';
