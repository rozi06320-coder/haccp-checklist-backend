-- Maintenance runtime contract hardening and branch-shared Supervisor reads.

create or replace function private.require_supervisor_maintenance_branch(actor_user_id uuid,target_branch_id uuid)
returns table(organization_id uuid,branch_id uuid)
language sql
stable
security definer
set search_path=''
as $$
  select branch.organization_id,branch.id
  from public.profiles profile
  join public.branch_memberships membership
    on membership.user_id=profile.id
   and membership.branch_id=target_branch_id
   and membership.role='branch_manager'
   and membership.active
  join public.branches branch
    on branch.id=membership.branch_id
   and branch.active
  join public.organizations organization
    on organization.id=branch.organization_id
   and organization.active
  where profile.id=actor_user_id
    and profile.disabled_at is null
    and not profile.must_change_password
$$;

create or replace function public.list_supervisor_maintenance_issues(actor_user_id uuid,target_branch_id uuid)
returns table(
  id uuid,
  organization_id uuid,
  branch_id uuid,
  branch_name text,
  title text,
  category text,
  priority text,
  status text,
  description text,
  location text,
  reported_by uuid,
  reporter_name text,
  assigned_to uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
declare
  context record;
begin
  select authorized.* into context
  from private.require_supervisor_maintenance_branch(actor_user_id,target_branch_id) authorized;
  if context.branch_id is null then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  return query
    select issue.id,issue.organization_id,issue.branch_id,branch.name,issue.title,
      issue.category,issue.priority,issue.status,issue.description,issue.location,
      issue.reported_by,reporter.full_name,issue.assigned_to,issue.created_at,issue.updated_at
    from public.maintenance_issues issue
    join public.branches branch on branch.id=issue.branch_id and branch.organization_id=context.organization_id
    left join public.profiles reporter on reporter.id=issue.reported_by
    where issue.organization_id=context.organization_id
      and issue.branch_id=context.branch_id
    order by issue.created_at desc
    limit 500;
end;
$$;

alter function private.require_supervisor_maintenance_team(uuid,uuid) set search_path='';
alter function public.create_supervisor_maintenance_issue(uuid,uuid,jsonb) set search_path='';
alter function public.list_maintenance_issues(uuid,uuid,uuid) set search_path='';
alter function public.update_maintenance_issue(uuid,uuid,uuid,text,text) set search_path='';
alter function private.require_maintenance_purchase_issue(uuid,uuid) set search_path='';
alter function public.list_maintenance_purchase_logs(uuid,uuid) set search_path='';
alter function public.create_maintenance_purchase_log(uuid,uuid,jsonb) set search_path='';
alter function public.reimburse_maintenance_purchase_log(uuid,uuid,text) set search_path='';
alter function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date) set search_path='';

revoke all on function private.require_supervisor_maintenance_branch(uuid,uuid) from public,anon,authenticated;
grant execute on function private.require_supervisor_maintenance_branch(uuid,uuid) to service_role;
revoke all on function public.list_supervisor_maintenance_issues(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_supervisor_maintenance_issues(uuid,uuid) to service_role;
