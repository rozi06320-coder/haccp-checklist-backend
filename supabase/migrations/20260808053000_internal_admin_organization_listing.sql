create or replace function public.list_internal_admin_organizations(actor_user_id uuid)
returns table(id uuid, name text, active boolean, logo_path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'organization list access denied' using errcode = '42501';
  end if;

  return query
  select organization.id, organization.name, organization.active, organization.logo_path
  from public.organizations organization
  order by organization.name, organization.id
  limit 200;
end;
$$;

revoke all on function public.list_internal_admin_organizations(uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_organizations(uuid) to service_role;
