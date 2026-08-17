create function public.update_internal_admin_organization(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_organization_name text,
  p_organization_name_ar text
) returns table(id uuid, name text, name_ar text, slug text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_organization_name, '')), '\s+', ' ', 'g');
  normalized_name_ar text := private.clean_optional_master_name(p_organization_name_ar);
  updated_organization public.organizations%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  if length(normalized_name) = 0 or length(normalized_name) > 120 then
    raise exception 'invalid organization update request' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.organizations organization
    where organization.id <> p_organization_id
      and pg_catalog.lower(pg_catalog.btrim(organization.name)) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'organization already exists' using errcode = '23505';
  end if;

  update public.organizations organization
  set name = normalized_name,
      name_ar = normalized_name_ar,
      updated_at = now()
  where organization.id = p_organization_id
  returning * into updated_organization;

  return query
  select updated_organization.id,
    updated_organization.name,
    updated_organization.name_ar,
    updated_organization.slug,
    updated_organization.active;
end;
$$;

create function public.deactivate_internal_admin_organization(
  p_actor_user_id uuid,
  p_organization_id uuid
) returns table(id uuid, name text, name_ar text, slug text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_organization public.organizations%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  update public.organizations organization
  set active = false,
      updated_at = now()
  where organization.id = p_organization_id
  returning * into updated_organization;

  if updated_organization.id is null then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  return query
  select updated_organization.id,
    updated_organization.name,
    updated_organization.name_ar,
    updated_organization.slug,
    updated_organization.active;
end;
$$;

create function public.reactivate_internal_admin_organization(
  p_actor_user_id uuid,
  p_organization_id uuid
) returns table(id uuid, name text, name_ar text, slug text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_organization public.organizations%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  update public.organizations organization
  set active = true,
      updated_at = now()
  where organization.id = p_organization_id
  returning * into updated_organization;

  if updated_organization.id is null then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  return query
  select updated_organization.id,
    updated_organization.name,
    updated_organization.name_ar,
    updated_organization.slug,
    updated_organization.active;
end;
$$;

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
  timezone text,
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
    select branch.id, branch.name, branch.name_ar, branch.code, branch.timezone, branch.active, branch.logo_path
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    where branch.organization_id = target_organization_id
    order by branch.active desc, pg_catalog.lower(branch.name), branch.id
    limit 500;
end;
$$;

create function public.update_internal_admin_branch(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid,
  p_branch_name text,
  p_branch_name_ar text,
  p_branch_timezone text
) returns table(id uuid, organization_id uuid, name text, name_ar text, code text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_name, '')), '\s+', ' ', 'g');
  normalized_name_ar text := private.clean_optional_master_name(p_branch_name_ar);
  normalized_timezone text := pg_catalog.btrim(coalesce(p_branch_timezone, ''));
  updated_branch public.branches%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  if length(normalized_name) = 0
    or length(normalized_name) > 120
    or length(normalized_timezone) = 0
    or length(normalized_timezone) > 80
    or not exists (select 1 from pg_catalog.pg_timezone_names zone where zone.name = normalized_timezone)
  then
    raise exception 'invalid branch update request' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.branches branch
    where branch.id = p_branch_id
      and branch.organization_id = p_organization_id
  ) then
    raise exception 'branch unavailable' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.branches branch
    where branch.organization_id = p_organization_id
      and branch.id <> p_branch_id
      and pg_catalog.lower(pg_catalog.btrim(branch.name)) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'branch already exists' using errcode = '23505';
  end if;

  update public.branches branch
  set name = normalized_name,
      name_ar = normalized_name_ar,
      timezone = normalized_timezone,
      updated_at = now()
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
  returning * into updated_branch;

  return query
  select updated_branch.id,
    updated_branch.organization_id,
    updated_branch.name,
    updated_branch.name_ar,
    updated_branch.code,
    updated_branch.timezone,
    updated_branch.active;
end;
$$;

create function public.deactivate_internal_admin_branch(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid
) returns table(id uuid, organization_id uuid, name text, name_ar text, code text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_branch public.branches%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  update public.branches branch
  set active = false,
      updated_at = now()
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
  returning * into updated_branch;

  if updated_branch.id is null then
    raise exception 'branch unavailable' using errcode = 'P0002';
  end if;

  return query
  select updated_branch.id,
    updated_branch.organization_id,
    updated_branch.name,
    updated_branch.name_ar,
    updated_branch.code,
    updated_branch.timezone,
    updated_branch.active;
end;
$$;

create function public.reactivate_internal_admin_branch(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid
) returns table(id uuid, organization_id uuid, name text, name_ar text, code text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_branch public.branches%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  update public.branches branch
  set active = true,
      updated_at = now()
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
  returning * into updated_branch;

  if updated_branch.id is null then
    raise exception 'branch unavailable' using errcode = 'P0002';
  end if;

  return query
  select updated_branch.id,
    updated_branch.organization_id,
    updated_branch.name,
    updated_branch.name_ar,
    updated_branch.code,
    updated_branch.timezone,
    updated_branch.active;
end;
$$;

revoke all on function public.update_internal_admin_organization(uuid,uuid,text,text) from public, anon, authenticated;
revoke all on function public.deactivate_internal_admin_organization(uuid,uuid) from public, anon, authenticated;
revoke all on function public.reactivate_internal_admin_organization(uuid,uuid) from public, anon, authenticated;
revoke all on function public.list_internal_admin_branches(uuid,uuid) from public, anon, authenticated;
revoke all on function public.update_internal_admin_branch(uuid,uuid,uuid,text,text,text) from public, anon, authenticated;
revoke all on function public.deactivate_internal_admin_branch(uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.reactivate_internal_admin_branch(uuid,uuid,uuid) from public, anon, authenticated;

grant execute on function public.update_internal_admin_organization(uuid,uuid,text,text) to service_role;
grant execute on function public.deactivate_internal_admin_organization(uuid,uuid) to service_role;
grant execute on function public.reactivate_internal_admin_organization(uuid,uuid) to service_role;
grant execute on function public.list_internal_admin_branches(uuid,uuid) to service_role;
grant execute on function public.update_internal_admin_branch(uuid,uuid,uuid,text,text,text) to service_role;
grant execute on function public.deactivate_internal_admin_branch(uuid,uuid,uuid) to service_role;
grant execute on function public.reactivate_internal_admin_branch(uuid,uuid,uuid) to service_role;
