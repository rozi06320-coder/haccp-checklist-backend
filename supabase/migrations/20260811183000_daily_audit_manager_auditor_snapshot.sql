-- Preserve the Organization Manager profile name as the Daily Audit auditor snapshot.
drop function public.get_organization_manager_daily_audit_credentials(uuid, uuid);

create function public.get_organization_manager_daily_audit_credentials(actor_user_id uuid,target_branch_id uuid)
returns table(organization_id uuid,manager_user_id uuid,display_name text,pin_hash bytea,salt bytea,kdf_version smallint,cost integer,block_size integer,parallelization integer,credential_version uuid)
language plpgsql security definer set search_path=''
as $$
begin
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,null) then
    raise exception 'access denied' using errcode='42501';
  end if;
  return query
    select credential.organization_id,credential.manager_user_id,
      coalesce(nullif(btrim(profile.full_name),''),'Organization Manager') as display_name,
      credential.pin_hash,credential.salt,credential.kdf_version,credential.cost,
      credential.block_size,credential.parallelization,credential.credential_version
    from private.organization_manager_daily_audit_pins credential
    join public.branches branch on branch.organization_id=credential.organization_id and branch.id=target_branch_id and branch.active
    join public.organizations organization on organization.id=credential.organization_id and organization.active
    join public.organization_memberships membership
      on membership.organization_id=credential.organization_id and membership.user_id=credential.manager_user_id
      and membership.role='organization_manager'
    join public.profiles profile on profile.id=credential.manager_user_id
      and profile.disabled_at is null and not profile.must_change_password
    order by credential.manager_user_id;
end $$;

revoke all on function public.get_organization_manager_daily_audit_credentials(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_organization_manager_daily_audit_credentials(uuid,uuid) to service_role;
