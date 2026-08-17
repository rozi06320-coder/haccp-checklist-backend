-- Operational-team assignment is provisioning metadata. Permit it to be created
-- while the new Supervisor is still under the mandatory password-change gate;
-- runtime reads and writes continue to require must_change_password=false.
create or replace function private.validate_branch_operational_team_supervisor()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.branch_operational_teams team
    join public.branches branch on branch.id=team.branch_id
    join public.organizations organization on organization.id=team.organization_id
    join public.branch_memberships membership on membership.branch_id=team.branch_id
    join public.profiles profile on profile.id=membership.user_id
    where team.id=new.operational_team_id and team.branch_id=new.branch_id
      and team.organization_id=new.organization_id and membership.user_id=new.supervisor_user_id
      and membership.role='branch_manager'
      and (not new.active or (team.active and branch.active and organization.active and membership.active
        and profile.disabled_at is null))
  ) then raise exception 'invalid operational team supervisor scope' using errcode='23514'; end if;
  return new;
end $$;

-- Branch dashboard authorization comes from active branch membership. Legacy team
-- rows are retained only as compatibility attribution for tables not yet migrated.
create or replace function private.phase2_branch_context(actor uuid,target_branch uuid)
returns table(organization_id uuid,branch_id uuid,legacy_team_id uuid,business_date date,branch_name text,branch_code text,actor_name text)
language sql stable security definer set search_path='' as $$
  select b.organization_id,b.id,t.id,private.phase4a_business_date(b.timezone),b.name,b.code,p.full_name
  from public.profiles p
  join public.branch_memberships m on m.user_id=p.id and m.branch_id=target_branch and m.role='branch_manager' and m.active
  join public.branches b on b.id=m.branch_id and b.active
  join public.organizations o on o.id=b.organization_id and o.active
  join lateral (
    select legacy.id from public.branch_supervisor_teams legacy
    where legacy.branch_id=b.id and legacy.organization_id=b.organization_id
      and legacy.supervisor_user_id=p.id
    order by legacy.active desc,legacy.created_at,legacy.id limit 1
  ) t on true
  where p.id=actor and p.disabled_at is null and not p.must_change_password
$$;

revoke all on function private.phase2_branch_context(uuid,uuid) from public,anon,authenticated;
grant execute on function private.phase2_branch_context(uuid,uuid) to service_role;
