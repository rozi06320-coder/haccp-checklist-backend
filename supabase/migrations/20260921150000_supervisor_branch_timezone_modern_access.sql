create or replace function public.get_supervisor_branch_timezone(actor_user_id uuid,target_branch_id uuid)
returns table(timezone text)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'branch access denied' using errcode='42501'; end if;
  return query select branch.timezone from public.branches branch
    join public.organizations organization on organization.id=branch.organization_id
    where branch.id=target_branch_id and branch.active and organization.active;
end $$;

revoke all on function public.get_supervisor_branch_timezone(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_supervisor_branch_timezone(uuid,uuid) to service_role;
