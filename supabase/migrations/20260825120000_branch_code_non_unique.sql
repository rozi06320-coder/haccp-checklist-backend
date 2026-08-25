alter table public.branches
  drop constraint if exists branches_organization_code_key;

drop index if exists public.branches_organization_code_key;

create or replace function public.create_managed_branch(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  branch_city text,
  branch_area text,
  branch_address text,
  branch_timezone text default 'Asia/Riyadh',
  branch_active boolean default true
) returns table(id uuid, name text, name_ar text, code text, city text, area text, address text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(branch_name, '')), '\s+', ' ', 'g');
  normalized_name_ar text := private.clean_optional_master_name(branch_name_ar);
  normalized_code text := pg_catalog.upper(pg_catalog.btrim(coalesce(branch_code, '')));
  normalized_city text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(branch_city, '')), '\s+', ' ', 'g');
  normalized_area text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(branch_area, '')), '\s+', ' ', 'g'), '');
  normalized_address text := nullif(pg_catalog.btrim(coalesce(branch_address, '')), '');
  normalized_timezone text := pg_catalog.btrim(coalesce(branch_timezone, 'Asia/Riyadh'));
  created_branch public.branches%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or length(normalized_name) = 0
    or length(normalized_name) > 120
    or length(normalized_code) = 0
    or length(normalized_code) > 120
    or normalized_code !~ '^[A-Z0-9-]+$'
    or length(normalized_city) = 0
    or length(normalized_city) > 120
    or (normalized_area is not null and length(normalized_area) > 120)
    or (normalized_address is not null and length(normalized_address) > 240)
    or length(normalized_timezone) = 0
    or length(normalized_timezone) > 80
    or not exists (select 1 from pg_catalog.pg_timezone_names zone where zone.name = normalized_timezone)
  then
    raise exception 'invalid branch creation request' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.branches branch
    where branch.organization_id = target_organization_id
      and pg_catalog.lower(pg_catalog.btrim(branch.name)) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'branch already exists' using errcode = '23505';
  end if;

  insert into public.branches(organization_id, name, name_ar, code, city, area, address, timezone, active)
  values(target_organization_id, normalized_name, normalized_name_ar, normalized_code, normalized_city, normalized_area, normalized_address, normalized_timezone, coalesce(branch_active, true))
  returning * into created_branch;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
  values(target_organization_id, actor_user_id, created_branch.id, 'branch_created', pg_catalog.jsonb_build_object('branch_name', created_branch.name, 'branch_code', created_branch.code, 'city', created_branch.city, 'area', created_branch.area, 'address', created_branch.address));

  return query select created_branch.id, created_branch.name, created_branch.name_ar, created_branch.code, created_branch.city, created_branch.area, created_branch.address, created_branch.timezone, created_branch.active;
end;
$$;

create or replace function public.create_internal_admin_branch(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_name text,
  p_branch_name_ar text,
  p_branch_code text,
  p_branch_city text,
  p_branch_area text,
  p_branch_address text,
  p_branch_timezone text default 'Asia/Riyadh',
  p_branch_active boolean default true
) returns table(id uuid, organization_id uuid, name text, name_ar text, code text, city text, area text, address text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_name, '')), '\s+', ' ', 'g');
  normalized_name_ar text := private.clean_optional_master_name(p_branch_name_ar);
  normalized_code text := pg_catalog.upper(pg_catalog.btrim(coalesce(p_branch_code, '')));
  normalized_city text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_city, '')), '\s+', ' ', 'g');
  normalized_area text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_area, '')), '\s+', ' ', 'g'), '');
  normalized_address text := nullif(pg_catalog.btrim(coalesce(p_branch_address, '')), '');
  normalized_timezone text := pg_catalog.btrim(coalesce(p_branch_timezone, 'Asia/Riyadh'));
  created_branch public.branches%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  if not exists (select 1 from public.organizations organization where organization.id = p_organization_id and organization.active) then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  if length(normalized_name) = 0
    or length(normalized_name) > 120
    or length(normalized_code) = 0
    or length(normalized_code) > 120
    or normalized_code !~ '^[A-Z0-9-]+$'
    or length(normalized_city) = 0
    or length(normalized_city) > 120
    or (normalized_area is not null and length(normalized_area) > 120)
    or (normalized_address is not null and length(normalized_address) > 240)
    or length(normalized_timezone) = 0
    or length(normalized_timezone) > 80
    or not exists (select 1 from pg_catalog.pg_timezone_names zone where zone.name = normalized_timezone)
  then
    raise exception 'invalid branch creation request' using errcode = '22023';
  end if;

  if exists (select 1 from public.branches branch where branch.organization_id = p_organization_id and pg_catalog.lower(pg_catalog.btrim(branch.name)) = pg_catalog.lower(normalized_name)) then
    raise exception 'branch already exists' using errcode = '23505';
  end if;

  insert into public.branches(organization_id, name, name_ar, code, city, area, address, timezone, active)
  values(p_organization_id, normalized_name, normalized_name_ar, normalized_code, normalized_city, normalized_area, normalized_address, normalized_timezone, coalesce(p_branch_active, true))
  returning * into created_branch;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
  values(p_organization_id, p_actor_user_id, created_branch.id, 'branch_created', pg_catalog.jsonb_build_object('branch_name', created_branch.name, 'branch_code', created_branch.code, 'city', created_branch.city, 'area', created_branch.area, 'address', created_branch.address));

  return query select created_branch.id, created_branch.organization_id, created_branch.name, created_branch.name_ar, created_branch.code, created_branch.city, created_branch.area, created_branch.address, created_branch.timezone, created_branch.active;
end;
$$;

create or replace function public.update_internal_admin_branch(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid,
  p_branch_name text,
  p_branch_name_ar text,
  p_branch_code text,
  p_branch_city text,
  p_branch_area text,
  p_branch_address text,
  p_branch_timezone text
) returns table(id uuid, organization_id uuid, name text, name_ar text, code text, city text, area text, address text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_name, '')), '\s+', ' ', 'g');
  normalized_name_ar text := private.clean_optional_master_name(p_branch_name_ar);
  normalized_code text := pg_catalog.upper(pg_catalog.btrim(coalesce(p_branch_code, '')));
  normalized_city text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_city, '')), '\s+', ' ', 'g');
  normalized_area text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_area, '')), '\s+', ' ', 'g'), '');
  normalized_address text := nullif(pg_catalog.btrim(coalesce(p_branch_address, '')), '');
  normalized_timezone text := pg_catalog.btrim(coalesce(p_branch_timezone, ''));
  updated_branch public.branches%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'internal admin access required' using errcode = '42501';
  end if;

  if not exists (select 1 from public.organizations organization where organization.id = p_organization_id) then
    raise exception 'organization unavailable' using errcode = 'P0002';
  end if;

  if length(normalized_name) = 0
    or length(normalized_name) > 120
    or length(normalized_code) = 0
    or length(normalized_code) > 120
    or normalized_code !~ '^[A-Z0-9-]+$'
    or length(normalized_city) = 0
    or length(normalized_city) > 120
    or (normalized_area is not null and length(normalized_area) > 120)
    or (normalized_address is not null and length(normalized_address) > 240)
    or length(normalized_timezone) = 0
    or length(normalized_timezone) > 80
    or not exists (select 1 from pg_catalog.pg_timezone_names zone where zone.name = normalized_timezone)
  then
    raise exception 'invalid branch update request' using errcode = '22023';
  end if;

  if not exists (select 1 from public.branches branch where branch.id = p_branch_id and branch.organization_id = p_organization_id) then
    raise exception 'branch unavailable' using errcode = 'P0002';
  end if;

  if exists (select 1 from public.branches branch where branch.organization_id = p_organization_id and branch.id <> p_branch_id and pg_catalog.lower(pg_catalog.btrim(branch.name)) = pg_catalog.lower(normalized_name)) then
    raise exception 'branch already exists' using errcode = '23505';
  end if;

  update public.branches branch
  set name = normalized_name,
      name_ar = normalized_name_ar,
      code = normalized_code,
      city = normalized_city,
      area = normalized_area,
      address = normalized_address,
      timezone = normalized_timezone,
      updated_at = now()
  where branch.id = p_branch_id
    and branch.organization_id = p_organization_id
  returning * into updated_branch;

  return query select updated_branch.id, updated_branch.organization_id, updated_branch.name, updated_branch.name_ar, updated_branch.code, updated_branch.city, updated_branch.area, updated_branch.address, updated_branch.timezone, updated_branch.active;
end;
$$;
