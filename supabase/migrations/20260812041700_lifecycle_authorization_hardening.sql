create or replace function private.is_organization_manager(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_memberships membership
    join public.organizations organization
      on organization.id = membership.organization_id
    join public.profiles profile
      on profile.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.role = 'organization_manager'
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );
$$;

create or replace function private.has_branch_access(target_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch
      on branch.id = membership.branch_id
    join public.organizations organization
      on organization.id = branch.organization_id
    join public.profiles profile
      on profile.id = membership.user_id
    where membership.branch_id = target_branch_id
      and membership.user_id = auth.uid()
      and membership.role in ('staff', 'branch_manager')
      and membership.active
      and branch.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  )
  or exists (
    select 1
    from public.branches branch
    where branch.id = target_branch_id
      and branch.active
      and private.is_organization_manager(branch.organization_id)
  );
$$;

create or replace function private.actor_manages_active_organization(actor uuid, target_organization uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles profile
    join public.organization_memberships membership
      on membership.user_id = profile.id
    join public.organizations organization
      on organization.id = membership.organization_id
    where profile.id = actor
      and profile.disabled_at is null
      and not profile.must_change_password
      and membership.organization_id = target_organization
      and membership.role = 'organization_manager'
      and membership.active
      and organization.active
  );
$$;

revoke all on function private.is_organization_manager(uuid),
  private.has_branch_access(uuid),
  private.actor_manages_active_organization(uuid, uuid)
  from public, anon, authenticated;

grant execute on function private.is_organization_manager(uuid),
  private.has_branch_access(uuid)
  to authenticated;
