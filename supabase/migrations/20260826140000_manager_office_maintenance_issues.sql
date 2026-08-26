alter table public.maintenance_issues
  add column if not exists location_scope text not null default 'branch';

do $$
begin
  alter table public.maintenance_issues
    add constraint maintenance_issues_location_scope_check
    check (location_scope in ('branch','office'));
exception when duplicate_object then null;
end $$;

alter table public.maintenance_issues alter column branch_id drop not null;
alter table public.maintenance_issues alter column supervisor_team_id drop not null;

do $$
begin
  alter table public.maintenance_issues
    add constraint maintenance_issues_scope_required_fields_check
    check (
      (location_scope = 'branch' and branch_id is not null and supervisor_team_id is not null)
      or (location_scope = 'office' and branch_id is null and supervisor_team_id is null)
    );
exception when duplicate_object then null;
end $$;

alter table public.maintenance_issue_attachments alter column branch_id drop not null;

create or replace function private.actor_can_view_maintenance_issue(actor_user_id uuid, access_user_id uuid, target_issue public.maintenance_issues)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select private.actor_can_maintain_organization(actor_user_id, access_user_id, target_issue.organization_id)
    or (
      target_issue.location_scope = 'branch'
      and exists (
        select 1
        from public.profiles profile
        join public.branch_memberships membership on membership.user_id = profile.id
        join public.branches branch on branch.id = membership.branch_id
        join public.organizations organization on organization.id = branch.organization_id
        join public.branch_supervisor_teams team on team.branch_id = branch.id
          and team.organization_id = branch.organization_id
          and team.supervisor_user_id = profile.id
          and team.active
        where profile.id = actor_user_id
          and profile.disabled_at is null
          and not profile.must_change_password
          and membership.branch_id = target_issue.branch_id
          and membership.role = 'branch_manager'
          and membership.active
          and branch.id = target_issue.branch_id
          and branch.organization_id = target_issue.organization_id
          and branch.active
          and organization.active
      )
    );
$$;

create or replace function private.enforce_maintenance_issue_attachment_scope()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  issue public.maintenance_issues%rowtype;
begin
  select i.* into issue from public.maintenance_issues i where i.id = new.maintenance_issue_id;
  if issue.id is null or issue.organization_id <> new.organization_id or issue.branch_id is distinct from new.branch_id then
    raise exception 'invalid maintenance issue attachment scope' using errcode='23514';
  end if;
  if new.uploaded_by is not null and new.uploaded_by_access_user_id is not null then
    raise exception 'invalid maintenance issue attachment actor' using errcode='23514';
  end if;
  return new;
end;
$$;

create or replace function public.list_maintenance_issues(actor_user_id uuid, access_user_id uuid, target_organization_id uuid)
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
begin
  if target_organization_id is not null
    and not private.actor_can_maintain_organization(actor_user_id, access_user_id, target_organization_id) then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  return query
    select issue.id, issue.organization_id, issue.branch_id,
      case when issue.location_scope = 'office' then 'Office' else branch.name end,
      issue.title, issue.category, issue.priority, issue.status, issue.description, issue.location,
      issue.reported_by, reporter.full_name, issue.assigned_to, issue.created_at, issue.updated_at,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', update_row.id,
          'status', update_row.status,
          'note', update_row.note,
          'updated_by', update_row.updated_by,
          'updated_by_access_user_id', update_row.updated_by_access_user_id,
          'updated_by_name', coalesce(updater.full_name, access_updater.display_name),
          'created_at', update_row.created_at
        ) order by update_row.created_at)
        from public.maintenance_issue_updates update_row
        left join public.profiles updater on updater.id = update_row.updated_by
        left join public.maintenance_access_users access_updater on access_updater.id = update_row.updated_by_access_user_id
        where update_row.issue_id = issue.id
      ), '[]'::jsonb) as updates
    from public.maintenance_issues issue
    left join public.branches branch on branch.id = issue.branch_id
    left join public.profiles reporter on reporter.id = issue.reported_by
    where (target_organization_id is null or issue.organization_id = target_organization_id)
      and private.actor_can_maintain_organization(actor_user_id, access_user_id, issue.organization_id)
      and (issue.location_scope = 'office' or branch.id is not null)
    order by issue.created_at desc
    limit 1000;
end;
$$;

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
  select issue.id,issue.organization_id,issue.branch_id,
    case when issue.location_scope='office' then 'Office' else branch.name end,
    issue.title,issue.category,issue.priority,issue.status,issue.description,issue.location,issue.reported_by,reporter.full_name,issue.created_at,issue.updated_at,
    coalesce((select jsonb_agg(jsonb_build_object('id',update_row.id,'status',update_row.status,'note',update_row.note,'updated_by',update_row.updated_by,'updated_by_access_user_id',update_row.updated_by_access_user_id,'updated_by_name',coalesce(updater.full_name,access_updater.display_name),'created_at',update_row.created_at) order by update_row.created_at) from public.maintenance_issue_updates update_row left join public.profiles updater on updater.id=update_row.updated_by left join public.maintenance_access_users access_updater on access_updater.id=update_row.updated_by_access_user_id where update_row.issue_id=issue.id and update_row.organization_id=target_organization_id),'[]'::jsonb)
  from public.maintenance_issues issue left join public.branches branch on branch.id=issue.branch_id left join public.profiles reporter on reporter.id=issue.reported_by
  where issue.organization_id=target_organization_id and (branch_filter is null or issue.branch_id=branch_filter) and (status_filter is null or issue.status=status_filter) and (priority_filter is null or issue.priority=priority_filter) and (category_filter is null or issue.category=category_filter) and (date_from_filter is null or issue.created_at::date>=date_from_filter) and (date_to_filter is null or issue.created_at::date<=date_to_filter) and (issue.location_scope='office' or branch.id is not null)
  order by issue.created_at desc;
end;
$$;

create or replace function public.create_manager_office_maintenance_issue(
  actor_user_id uuid,
  target_organization_id uuid,
  payload jsonb
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
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=public, private
as $$
declare
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  saved public.maintenance_issues%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'managed maintenance issue access denied' using errcode='42501';
  end if;
  if clean_category not in ('equipment','plumbing','electrical','refrigeration','building','other')
    or clean_priority not in ('low','normal','high','urgent') then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;

  insert into public.maintenance_issues(
    organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by
  ) values (
    target_organization_id, null, null, 'office', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id
  )
  returning * into saved;

  insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by)
  values(saved.id, saved.organization_id, saved.status, 'Office issue reported.', actor_user_id);

  return query
    select saved.id, saved.organization_id, null::uuid, 'Office'::text, saved.title, saved.category,
      saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
      reporter.full_name, saved.assigned_to, saved.created_at, saved.updated_at
    from public.profiles reporter
    where reporter.id = saved.reported_by;
end;
$$;

create or replace function public.create_manager_office_maintenance_issue_with_photo(
  actor_user_id uuid,
  target_organization_id uuid,
  payload jsonb
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
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=public, private
as $$
declare
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  requested_id uuid;
  attachment jsonb;
  saved public.maintenance_issues%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'managed maintenance issue access denied' using errcode='42501';
  end if;
  if clean_category not in ('equipment','plumbing','electrical','refrigeration','building','other')
    or clean_priority not in ('low','normal','high','urgent')
    or coalesce(jsonb_typeof(payload->'before_photo'),'null') <> 'object' then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;
  begin
    requested_id := coalesce(nullif(payload->>'issue_id','')::uuid, gen_random_uuid());
  exception when others then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end;
  attachment := private.clean_maintenance_issue_attachment(payload->'before_photo', 'issue');

  insert into public.maintenance_issues(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by
  ) values (
    requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id
  )
  returning * into saved;

  insert into public.maintenance_issue_attachments(
    id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path,
    original_filename, mime_type, size_bytes, uploaded_by
  ) values (
    (attachment->>'id')::uuid, saved.id, saved.organization_id, null, 'issue',
    attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
    (attachment->>'size_bytes')::bigint, actor_user_id
  );

  insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by)
  values(saved.id, saved.organization_id, saved.status, 'Office issue reported.', actor_user_id);

  return query
    select saved.id, saved.organization_id, null::uuid, 'Office'::text, saved.title, saved.category,
      saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
      reporter.full_name, saved.assigned_to, saved.created_at, saved.updated_at
    from public.profiles reporter
    where reporter.id = saved.reported_by;
end;
$$;

create or replace function public.list_maintenance_issue_push_subscriptions(
  target_issue_id uuid
)
returns table(
  subscription_id uuid,
  user_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  organization_id uuid,
  branch_id uuid,
  organization_name text,
  branch_name text,
  issue_title text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target record;
begin
  select issue.id,
         issue.organization_id,
         issue.branch_id,
         issue.title,
         organization.name as organization_name,
         case when issue.location_scope = 'office' then 'Office' else branch.name end as branch_name
    into target
  from public.maintenance_issues issue
  join public.organizations organization on organization.id = issue.organization_id and organization.active
  left join public.branches branch on branch.id = issue.branch_id
  where issue.id = target_issue_id
    and (issue.location_scope = 'office' or (branch.id is not null and branch.active));

  if target.id is null then
    return;
  end if;

  return query
    select distinct on (subscription.endpoint)
      subscription.id,
      subscription.user_id,
      subscription.endpoint,
      subscription.p256dh,
      subscription.auth,
      target.organization_id,
      target.branch_id,
      target.organization_name,
      target.branch_name,
      target.title
    from public.maintenance_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    join public.push_subscriptions subscription on subscription.user_id = membership.user_id
    where membership.organization_id = target.organization_id
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
      and subscription.disabled_at is null
    order by subscription.endpoint, subscription.updated_at desc;
end;
$$;

revoke all on function private.actor_can_view_maintenance_issue(uuid, uuid, public.maintenance_issues) from public, anon, authenticated;
revoke all on function private.enforce_maintenance_issue_attachment_scope() from public, anon, authenticated;
revoke all on function public.list_maintenance_issues(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue_with_photo(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.list_maintenance_issue_push_subscriptions(uuid) from public, anon, authenticated;

grant execute on function private.actor_can_view_maintenance_issue(uuid, uuid, public.maintenance_issues) to service_role;
grant execute on function private.enforce_maintenance_issue_attachment_scope() to service_role;
grant execute on function public.list_maintenance_issues(uuid, uuid, uuid) to service_role;
grant execute on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) to service_role;
grant execute on function public.create_manager_office_maintenance_issue(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue_with_photo(uuid, uuid, jsonb) to service_role;
grant execute on function public.list_maintenance_issue_push_subscriptions(uuid) to service_role;
