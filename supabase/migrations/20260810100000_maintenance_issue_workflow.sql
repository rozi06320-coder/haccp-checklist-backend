create table if not exists public.maintenance_issues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  supervisor_team_id uuid not null references public.branch_supervisor_teams(id) on delete restrict,
  title text not null,
  category text not null,
  priority text not null,
  status text not null default 'new',
  description text null,
  location text null,
  reported_by uuid not null references public.profiles(id) on delete restrict,
  assigned_to uuid null references public.profiles(id) on delete set null,
  resolved_at timestamptz null,
  closed_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint maintenance_issues_category_check check (category in ('equipment','plumbing','electrical','refrigeration','building','other')),
  constraint maintenance_issues_priority_check check (priority in ('low','normal','high','urgent')),
  constraint maintenance_issues_status_check check (status in ('new','in_progress','waiting_parts','resolved','closed')),
  constraint maintenance_issues_title_check check (title = pg_catalog.btrim(title) and length(title) between 1 and 120),
  constraint maintenance_issues_description_check check (description is null or (description = pg_catalog.btrim(description) and length(description) between 1 and 2000)),
  constraint maintenance_issues_location_check check (location is null or (location = pg_catalog.btrim(location) and length(location) between 1 and 160))
);

create table if not exists public.maintenance_issue_updates (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.maintenance_issues(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  status text not null,
  note text null,
  updated_by uuid null references public.profiles(id) on delete set null,
  updated_by_access_user_id uuid null references public.maintenance_access_users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint maintenance_issue_updates_status_check check (status in ('new','in_progress','waiting_parts','resolved','closed')),
  constraint maintenance_issue_updates_note_check check (note is null or (note = pg_catalog.btrim(note) and length(note) between 1 and 2000)),
  constraint maintenance_issue_updates_actor_check check (updated_by is not null or updated_by_access_user_id is not null)
);

create index if not exists maintenance_issues_org_status_idx on public.maintenance_issues(organization_id, status, created_at desc);
create index if not exists maintenance_issues_branch_created_idx on public.maintenance_issues(branch_id, created_at desc);
create index if not exists maintenance_issue_updates_issue_created_idx on public.maintenance_issue_updates(issue_id, created_at);

drop trigger if exists maintenance_issues_set_updated_at on public.maintenance_issues;
create trigger maintenance_issues_set_updated_at
before update on public.maintenance_issues
for each row execute function private.set_updated_at();

alter table public.maintenance_issues enable row level security;
alter table public.maintenance_issue_updates enable row level security;
revoke all on table public.maintenance_issues from public, anon, authenticated, service_role;
revoke all on table public.maintenance_issue_updates from public, anon, authenticated, service_role;
grant select on table public.maintenance_issues to authenticated;
grant select on table public.maintenance_issue_updates to authenticated;

create or replace function private.clean_maintenance_text(value text, required boolean default false, max_length integer default 120)
returns text
language plpgsql
immutable
as $$
declare cleaned text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(value,'')), '[[:space:]]+', ' ', 'g'), '');
begin
  if required and cleaned is null then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;
  if cleaned is not null and length(cleaned) > max_length then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;
  return cleaned;
end;
$$;

create or replace function private.require_supervisor_maintenance_team(actor_user_id uuid, target_branch_id uuid)
returns public.branch_supervisor_teams
language plpgsql
security definer
set search_path=public, private
as $$
declare target_team public.branch_supervisor_teams%rowtype;
begin
  select team.* into target_team
  from public.branch_supervisor_teams team
  join public.branches branch on branch.id = team.branch_id and branch.active
  join public.organizations organization on organization.id = team.organization_id and organization.active
  join public.branch_memberships membership on membership.branch_id = team.branch_id
    and membership.user_id = actor_user_id
    and membership.role = 'branch_manager'
    and membership.active
  where team.branch_id = target_branch_id
    and team.supervisor_user_id = actor_user_id
    and team.active
  order by team.created_at desc
  limit 1;
  if target_team.id is null then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  return target_team;
end;
$$;

create or replace function private.actor_can_maintain_organization(actor_user_id uuid, access_user_id uuid, target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select (
    actor_user_id is not null
    and private.actor_has_active_maintenance_membership(actor_user_id, target_organization_id)
  ) or exists (
    select 1
    from public.maintenance_access_users access_user
    join public.organizations organization on organization.id = access_user.organization_id
    where access_user.id = access_user_id
      and access_user.organization_id = target_organization_id
      and access_user.active
      and organization.active
  );
$$;

create or replace function private.maintenance_issue_transition_allowed(old_status text, new_status text)
returns boolean
language sql
immutable
as $$
  select old_status = new_status
    or (old_status = 'new' and new_status in ('in_progress','waiting_parts','resolved'))
    or (old_status = 'in_progress' and new_status in ('waiting_parts','resolved'))
    or (old_status = 'waiting_parts' and new_status in ('in_progress','resolved'))
    or (old_status = 'resolved' and new_status in ('closed','in_progress'));
$$;

create or replace function public.create_supervisor_maintenance_issue(actor_user_id uuid, target_branch_id uuid, payload jsonb)
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
  target_team public.branch_supervisor_teams%rowtype;
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  saved public.maintenance_issues%rowtype;
begin
  target_team := private.require_supervisor_maintenance_team(actor_user_id, target_branch_id);
  if clean_category not in ('equipment','plumbing','electrical','refrigeration','building','other')
    or clean_priority not in ('low','normal','high','urgent') then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;

  insert into public.maintenance_issues(
    organization_id, branch_id, supervisor_team_id, title, category, priority, status,
    description, location, reported_by
  ) values (
    target_team.organization_id, target_team.branch_id, target_team.id, clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id
  )
  returning * into saved;

  insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by)
  values(saved.id, saved.organization_id, saved.status, 'Issue reported.', actor_user_id);

  return query
    select saved.id, saved.organization_id, saved.branch_id, branch.name, saved.title, saved.category,
      saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
      reporter.full_name, saved.assigned_to, saved.created_at, saved.updated_at
    from public.branches branch
    left join public.profiles reporter on reporter.id = saved.reported_by
    where branch.id = saved.branch_id;
end;
$$;

create or replace function public.list_supervisor_maintenance_issues(actor_user_id uuid, target_branch_id uuid)
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
declare target_team public.branch_supervisor_teams%rowtype;
begin
  target_team := private.require_supervisor_maintenance_team(actor_user_id, target_branch_id);
  return query
    select issue.id, issue.organization_id, issue.branch_id, branch.name, issue.title,
      issue.category, issue.priority, issue.status, issue.description, issue.location,
      issue.reported_by, reporter.full_name, issue.assigned_to, issue.created_at, issue.updated_at
    from public.maintenance_issues issue
    join public.branches branch on branch.id = issue.branch_id
    left join public.profiles reporter on reporter.id = issue.reported_by
    where issue.supervisor_team_id = target_team.id
    order by issue.created_at desc
    limit 500;
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
    select issue.id, issue.organization_id, issue.branch_id, branch.name, issue.title,
      issue.category, issue.priority, issue.status, issue.description, issue.location,
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
    join public.branches branch on branch.id = issue.branch_id
    left join public.profiles reporter on reporter.id = issue.reported_by
    where (target_organization_id is null or issue.organization_id = target_organization_id)
      and private.actor_can_maintain_organization(actor_user_id, access_user_id, issue.organization_id)
    order by issue.created_at desc
    limit 1000;
end;
$$;

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
  select * into saved from public.maintenance_issues where id = target_issue_id for update;
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

revoke all on function private.clean_maintenance_text(text, boolean, integer) from public, anon, authenticated;
revoke all on function private.require_supervisor_maintenance_team(uuid, uuid) from public, anon, authenticated;
revoke all on function private.actor_can_maintain_organization(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function private.maintenance_issue_transition_allowed(text, text) from public, anon, authenticated;
grant execute on function private.clean_maintenance_text(text, boolean, integer) to service_role;
grant execute on function private.require_supervisor_maintenance_team(uuid, uuid) to service_role;
grant execute on function private.actor_can_maintain_organization(uuid, uuid, uuid) to service_role;
grant execute on function private.maintenance_issue_transition_allowed(text, text) to service_role;
revoke all on function public.create_supervisor_maintenance_issue(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.list_supervisor_maintenance_issues(uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_maintenance_issues(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue(uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.create_supervisor_maintenance_issue(uuid, uuid, jsonb) to service_role;
grant execute on function public.list_supervisor_maintenance_issues(uuid, uuid) to service_role;
grant execute on function public.list_maintenance_issues(uuid, uuid, uuid) to service_role;
grant execute on function public.update_maintenance_issue(uuid, uuid, uuid, text, text) to service_role;
