insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values('branding-assets', 'branding-assets', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict(id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

alter table public.organizations
  add column if not exists logo_path text null;

alter table public.branches
  add column if not exists logo_path text null;

alter table public.organizations
  drop constraint if exists organizations_logo_path_check,
  add constraint organizations_logo_path_check
  check (
    logo_path is null
    or (
      length(logo_path) between 20 and 500
      and logo_path = btrim(logo_path)
      and logo_path ~ ('^organizations/' || id::text || '/logo/[0-9a-fA-F-]{36}\.(jpg|png|webp)$')
    )
  );

alter table public.branches
  drop constraint if exists branches_logo_path_check,
  add constraint branches_logo_path_check
  check (
    logo_path is null
    or (
      length(logo_path) between 20 and 500
      and logo_path = btrim(logo_path)
      and logo_path ~ ('^branches/' || id::text || '/logo/[0-9a-fA-F-]{36}\.(jpg|png|webp)$')
    )
  );

create index if not exists organizations_logo_path_idx on public.organizations(logo_path) where logo_path is not null;
create index if not exists branches_logo_path_idx on public.branches(logo_path) where logo_path is not null;

create or replace function public.update_internal_admin_organization_logo(
  actor_user_id uuid,
  target_organization_id uuid,
  object_path text
)
returns table(id uuid, name text, logo_path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated public.organizations%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or object_path is null
    or length(object_path) not between 20 and 500
    or object_path <> btrim(object_path)
    or object_path !~ ('^organizations/' || target_organization_id::text || '/logo/[0-9a-fA-F-]{36}\.(jpg|png|webp)$')
  then
    raise exception 'invalid branding request' using errcode = '42501';
  end if;

  update public.organizations organization
  set logo_path = object_path,
      updated_at = now()
  where organization.id = target_organization_id
    and organization.active
  returning * into updated;

  if updated.id is null then
    raise exception 'invalid branding request' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, action, details)
  values(target_organization_id, actor_user_id, 'organization_logo_updated', jsonb_build_object('logo_configured', true));

  return query select updated.id, updated.name, updated.logo_path;
end;
$$;

create or replace function public.update_internal_admin_branch_logo(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid,
  object_path text
)
returns table(id uuid, organization_id uuid, name text, logo_path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated public.branches%rowtype;
begin
  if not private.is_internal_admin(actor_user_id)
    or object_path is null
    or length(object_path) not between 20 and 500
    or object_path <> btrim(object_path)
    or object_path !~ ('^branches/' || target_branch_id::text || '/logo/[0-9a-fA-F-]{36}\.(jpg|png|webp)$')
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'invalid branding request' using errcode = '42501';
  end if;

  update public.branches branch
  set logo_path = object_path,
      updated_at = now()
  where branch.id = target_branch_id
    and branch.organization_id = target_organization_id
    and branch.active
  returning * into updated;

  if updated.id is null then
    raise exception 'invalid branding request' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
  values(target_organization_id, actor_user_id, target_branch_id, 'branch_logo_updated', jsonb_build_object('logo_configured', true));

  return query select updated.id, updated.organization_id, updated.name, updated.logo_path;
end;
$$;

create or replace function public.get_management_organization_branding(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(organization_id uuid, organization_logo_path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'branding read denied' using errcode = '42501';
  end if;

  return query
    select organization.id, organization.logo_path
    from public.organizations organization
    where organization.id = target_organization_id
      and organization.active;
end;
$$;

create or replace function public.get_supervisor_branch_branding(
  actor_user_id uuid,
  target_branch_id uuid
)
returns table(branch_id uuid, organization_id uuid, branch_logo_path text, organization_logo_path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.profiles profile
    join public.branch_memberships membership on membership.user_id = profile.id
    join public.branches branch on branch.id = membership.branch_id
    join public.organizations organization on organization.id = branch.organization_id
    where profile.id = actor_user_id
      and profile.disabled_at is null
      and not profile.must_change_password
      and membership.branch_id = target_branch_id
      and membership.role = 'branch_manager'
      and membership.active
      and branch.active
      and organization.active
  ) then
    raise exception 'branding read denied' using errcode = '42501';
  end if;

  return query
    select branch.id, organization.id, branch.logo_path, organization.logo_path
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    where branch.id = target_branch_id
      and branch.active
      and organization.active;
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
    select branch.id, branch.name, branch.code, branch.active, branch.logo_path
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    where branch.organization_id = target_organization_id
      and organization.active
    order by branch.active desc, pg_catalog.lower(branch.name), branch.id
    limit 500;
end;
$$;

revoke all on function public.update_internal_admin_organization_logo(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.update_internal_admin_branch_logo(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.get_management_organization_branding(uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_supervisor_branch_branding(uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_internal_admin_branches(uuid, uuid) from public, anon, authenticated;
grant execute on function public.update_internal_admin_organization_logo(uuid, uuid, text) to service_role;
grant execute on function public.update_internal_admin_branch_logo(uuid, uuid, uuid, text) to service_role;
grant execute on function public.get_management_organization_branding(uuid, uuid) to service_role;
grant execute on function public.get_supervisor_branch_branding(uuid, uuid) to service_role;
grant execute on function public.list_internal_admin_branches(uuid, uuid) to service_role;
