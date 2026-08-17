create or replace function public.list_managed_maintenance_issues(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  status_filter text default null, priority_filter text default null, category_filter text default null,
  date_from_filter date default null, date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (branch_filter is not null and not exists (select 1 from public.branches managed_branch where managed_branch.id=branch_filter and managed_branch.organization_id=target_organization_id))
    or status_filter is not null and status_filter not in ('new','in_progress','waiting_parts','resolved','closed')
    or priority_filter is not null and priority_filter not in ('low','normal','high','urgent')
    or category_filter is not null and category_filter not in ('equipment','plumbing','electrical','refrigeration','building','other')
    or date_from_filter is not null and date_to_filter is not null and date_from_filter>date_to_filter then
    raise exception 'managed maintenance issue access denied' using errcode='42501';
  end if;
  return query
  select issue.id,issue.organization_id,issue.branch_id,branch.name,issue.title,issue.category,issue.priority,issue.status,issue.description,issue.location,issue.reported_by,reporter.full_name,issue.created_at,issue.updated_at,
    coalesce((select jsonb_agg(jsonb_build_object('id',update_row.id,'status',update_row.status,'note',update_row.note,'updated_by',update_row.updated_by,'updated_by_access_user_id',update_row.updated_by_access_user_id,'updated_by_name',coalesce(updater.full_name,access_updater.display_name),'created_at',update_row.created_at) order by update_row.created_at) from public.maintenance_issue_updates update_row left join public.profiles updater on updater.id=update_row.updated_by left join public.maintenance_access_users access_updater on access_updater.id=update_row.updated_by_access_user_id where update_row.issue_id=issue.id and update_row.organization_id=target_organization_id),'[]'::jsonb)
  from public.maintenance_issues issue join public.branches branch on branch.id=issue.branch_id left join public.profiles reporter on reporter.id=issue.reported_by
  where issue.organization_id=target_organization_id and (branch_filter is null or issue.branch_id=branch_filter) and (status_filter is null or issue.status=status_filter) and (priority_filter is null or issue.priority=priority_filter) and (category_filter is null or issue.category=category_filter) and (date_from_filter is null or issue.created_at::date>=date_from_filter) and (date_to_filter is null or issue.created_at::date<=date_to_filter)
  order by issue.created_at desc;
end;
$$;
revoke all on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) from public,anon,authenticated;
grant execute on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) to service_role;
