create or replace function private.has_organization_access(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_organization_manager(target_organization_id)
  or exists (
    select 1
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    join public.branch_memberships membership on membership.branch_id = branch.id
    where branch.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.role in ('staff', 'branch_manager')
      and membership.active
      and branch.active
      and organization.active
  )
  or exists (
    select 1
    from public.maintenance_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );
$$;

revoke all on function private.has_organization_access(uuid) from public, anon, authenticated;
grant execute on function private.has_organization_access(uuid) to authenticated;
