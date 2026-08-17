create function public.get_maintenance_access_user_credentials(
  organization_identifier text,
  access_display_name text
)
returns table(
  organization_id uuid,
  organization_name text,
  access_user_id uuid,
  display_name text,
  pin_hash bytea,
  salt bytea,
  kdf_version smallint,
  cost integer,
  block_size integer,
  parallelization integer,
  credential_version uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_org text := pg_catalog.lower(pg_catalog.btrim(coalesce(organization_identifier, '')));
  clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(access_display_name, '')), '\s+', ' ', 'g');
  matched_org uuid;
begin
  if length(clean_org) = 0 or length(clean_org) > 120 or length(clean_name) = 0 or length(clean_name) > 120 then
    return;
  end if;

  with candidates as (
    select organization.id
    from public.organizations organization
    where organization.active
      and (
        organization.id::text = clean_org
        or pg_catalog.lower(organization.slug) = clean_org
        or pg_catalog.lower(pg_catalog.btrim(organization.name)) = clean_org
      )
  )
  select case when count(*) = 1 then (array_agg(id))[1] else null::uuid end into matched_org
  from candidates;

  if matched_org is null then
    return;
  end if;

  return query
    select organization.id, organization.name, access.id, access.display_name,
      access.pin_hash, access.salt, access.kdf_version, access.cost,
      access.block_size, access.parallelization, access.credential_version
    from public.maintenance_access_users access
    join public.organizations organization on organization.id = access.organization_id and organization.active
    where access.organization_id = matched_org
      and access.active
      and pg_catalog.lower(access.display_name) = pg_catalog.lower(clean_name)
    order by access.id
    limit 1;
end;
$$;

create function public.validate_maintenance_access_grant(
  target_organization_id uuid,
  target_access_user_id uuid,
  target_credential_version uuid
)
returns table(
  organization_id uuid,
  organization_name text,
  access_user_id uuid,
  display_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
    select organization.id, organization.name, access.id, access.display_name
    from public.maintenance_access_users access
    join public.organizations organization on organization.id = access.organization_id and organization.active
    where access.organization_id = target_organization_id
      and access.id = target_access_user_id
      and access.credential_version = target_credential_version
      and access.active
    limit 1;
end;
$$;

revoke all on function public.get_maintenance_access_user_credentials(text, text) from public, anon, authenticated;
revoke all on function public.validate_maintenance_access_grant(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.get_maintenance_access_user_credentials(text, text) to service_role;
grant execute on function public.validate_maintenance_access_grant(uuid, uuid, uuid) to service_role;
