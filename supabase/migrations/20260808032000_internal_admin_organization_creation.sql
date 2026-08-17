create or replace function public.create_internal_admin_organization(
  actor_user_id uuid,
  organization_name text
)
returns table(id uuid, name text, slug text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(organization_name, '')), '\s+', ' ', 'g');
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

  insert into public.organizations(name, slug, active)
  values(normalized_name, candidate_slug, true)
  returning * into created;

  return query select created.id, created.name, created.slug, created.active;
end;
$$;

revoke all on function public.create_internal_admin_organization(uuid,text) from public, anon, authenticated;
grant execute on function public.create_internal_admin_organization(uuid,text) to service_role;
