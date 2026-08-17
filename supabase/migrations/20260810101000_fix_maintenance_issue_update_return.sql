create or replace function public.update_maintenance_issue(
  actor_user_id uuid,
  access_user_id uuid,
  target_issue_id uuid,
  new_status text,
  new_note text
)
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
  updated_at timestamptz,
  updates jsonb
)
language plpgsql
security definer
set search_path=public, private
as $$
declare
  saved public.maintenance_issues%rowtype;
  clean_status text := coalesce(nullif(new_status,''), '');
  clean_note text := private.clean_maintenance_text(new_note, false, 2000);
begin
  select * into saved from public.maintenance_issues where maintenance_issues.id = target_issue_id for update;
  if saved.id is null then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  if not private.actor_can_maintain_organization(actor_user_id, access_user_id, saved.organization_id) then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  if saved.status = 'closed' then
    raise exception 'maintenance issue is closed' using errcode='23514';
  end if;
  if clean_status not in ('new','in_progress','waiting_parts','resolved','closed')
    or not private.maintenance_issue_transition_allowed(saved.status, clean_status) then
    raise exception 'invalid maintenance issue transition' using errcode='22023';
  end if;

  update public.maintenance_issues issue
  set status = clean_status,
      resolved_at = case when clean_status = 'resolved' then coalesce(issue.resolved_at, now()) when clean_status = 'in_progress' then null else issue.resolved_at end,
      closed_at = case when clean_status = 'closed' then coalesce(issue.closed_at, now()) else issue.closed_at end
  where issue.id = target_issue_id
  returning * into saved;

  insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by, updated_by_access_user_id)
  values(saved.id, saved.organization_id, saved.status, clean_note, actor_user_id, access_user_id);

  return query
    select listed.*
    from public.list_maintenance_issues(actor_user_id, access_user_id, saved.organization_id) listed
    where listed.id = target_issue_id;
end;
$$;

revoke all on function public.update_maintenance_issue(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.update_maintenance_issue(uuid, uuid, uuid, text, text) to service_role;
