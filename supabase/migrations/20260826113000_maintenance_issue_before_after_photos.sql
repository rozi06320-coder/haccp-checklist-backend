insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values('maintenance-issue-photos','maintenance-issue-photos',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

create table if not exists public.maintenance_issue_attachments(
  id uuid primary key default gen_random_uuid(),
  maintenance_issue_id uuid not null references public.maintenance_issues(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  attachment_type text not null,
  storage_path text not null,
  original_filename text null,
  mime_type text not null,
  size_bytes bigint not null,
  uploaded_by uuid null references public.profiles(id) on delete restrict,
  uploaded_by_access_user_id uuid null references public.maintenance_access_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint maintenance_issue_attachments_type_check check(attachment_type in ('issue','repair')),
  constraint maintenance_issue_attachments_actor_check check(uploaded_by is not null or uploaded_by_access_user_id is not null),
  constraint maintenance_issue_attachments_path_check check(storage_path ~ '^maintenance/[0-9a-fA-F-]{36}/(issue|repair)/[^/]{1,180}$'),
  constraint maintenance_issue_attachments_filename_check check(original_filename is null or (original_filename=pg_catalog.btrim(original_filename) and length(original_filename) between 1 and 180)),
  constraint maintenance_issue_attachments_mime_check check(mime_type in ('image/jpeg','image/png','image/webp')),
  constraint maintenance_issue_attachments_size_check check(size_bytes > 0 and size_bytes <= 5242880),
  constraint maintenance_issue_attachments_one_per_type_key unique(maintenance_issue_id, attachment_type),
  constraint maintenance_issue_attachments_storage_path_key unique(storage_path)
);

create index if not exists maintenance_issue_attachments_issue_idx on public.maintenance_issue_attachments(maintenance_issue_id, attachment_type);
create index if not exists maintenance_issue_attachments_scope_idx on public.maintenance_issue_attachments(organization_id, branch_id);

create or replace function private.actor_can_view_maintenance_issue(actor_user_id uuid, access_user_id uuid, target_issue public.maintenance_issues)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select private.actor_can_maintain_organization(actor_user_id, access_user_id, target_issue.organization_id)
    or exists (
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
  if issue.id is null or issue.organization_id <> new.organization_id or issue.branch_id <> new.branch_id then
    raise exception 'invalid maintenance issue attachment scope' using errcode='23514';
  end if;
  if new.uploaded_by is not null and new.uploaded_by_access_user_id is not null then
    raise exception 'invalid maintenance issue attachment actor' using errcode='23514';
  end if;
  return new;
end;
$$;

drop trigger if exists maintenance_issue_attachment_scope_check on public.maintenance_issue_attachments;
create trigger maintenance_issue_attachment_scope_check
before insert or update on public.maintenance_issue_attachments
for each row execute function private.enforce_maintenance_issue_attachment_scope();

alter table public.maintenance_issue_attachments enable row level security;
drop policy if exists maintenance_issue_attachments_service_read on public.maintenance_issue_attachments;
create policy maintenance_issue_attachments_service_read
on public.maintenance_issue_attachments
for select
to service_role
using (true);

drop policy if exists maintenance_issue_attachments_service_write on public.maintenance_issue_attachments;
create policy maintenance_issue_attachments_service_write
on public.maintenance_issue_attachments
for all
to service_role
using (true)
with check (true);

revoke all on table public.maintenance_issue_attachments from public, anon, authenticated;
grant select, insert, update, delete on table public.maintenance_issue_attachments to service_role;
revoke all on function private.actor_can_view_maintenance_issue(uuid, uuid, public.maintenance_issues) from public, anon, authenticated;
revoke all on function private.enforce_maintenance_issue_attachment_scope() from public, anon, authenticated;
grant execute on function private.actor_can_view_maintenance_issue(uuid, uuid, public.maintenance_issues) to service_role;
grant execute on function private.enforce_maintenance_issue_attachment_scope() to service_role;

create or replace function private.clean_maintenance_issue_attachment(payload jsonb, expected_type text)
returns jsonb
language plpgsql
volatile
set search_path=''
as $$
declare
  clean_path text := nullif(pg_catalog.btrim(coalesce(payload->>'storage_path','')), '');
  clean_name text := nullif(pg_catalog.btrim(coalesce(payload->>'original_filename','')), '');
  clean_mime text := nullif(pg_catalog.btrim(coalesce(payload->>'mime_type','')), '');
  clean_size bigint;
begin
  begin
    clean_size := (payload->>'size_bytes')::bigint;
  exception when others then
    raise exception 'invalid maintenance issue attachment payload' using errcode='22023';
  end;
  if expected_type not in ('issue','repair')
    or clean_path is null
    or clean_path !~ ('^maintenance/[0-9a-fA-F-]{36}/'||expected_type||'/[^/]{1,180}$')
    or clean_mime not in ('image/jpeg','image/png','image/webp')
    or clean_size <= 0
    or clean_size > 5242880
    or (clean_name is not null and length(clean_name) > 180) then
    raise exception 'invalid maintenance issue attachment payload' using errcode='22023';
  end if;
  return jsonb_build_object(
    'id', coalesce(nullif(payload->>'id','')::uuid, gen_random_uuid()),
    'storage_path', clean_path,
    'original_filename', clean_name,
    'mime_type', clean_mime,
    'size_bytes', clean_size
  );
end;
$$;

create or replace function public.list_maintenance_issue_attachments(
  actor_user_id uuid,
  access_user_id uuid,
  target_issue_ids uuid[]
)
returns table(
  id uuid,
  maintenance_issue_id uuid,
  attachment_type text,
  storage_path text,
  original_filename text,
  mime_type text,
  size_bytes bigint,
  created_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
begin
  if target_issue_ids is null or cardinality(target_issue_ids) > 1000 then
    raise exception 'invalid maintenance issue attachment payload' using errcode='22023';
  end if;
  return query
    select attachment.id, attachment.maintenance_issue_id, attachment.attachment_type, attachment.storage_path,
      attachment.original_filename, attachment.mime_type, attachment.size_bytes, attachment.created_at
    from public.maintenance_issue_attachments attachment
    join public.maintenance_issues issue on issue.id = attachment.maintenance_issue_id
    where issue.id = any(target_issue_ids)
      and private.actor_can_view_maintenance_issue(actor_user_id, access_user_id, issue)
    order by attachment.created_at;
end;
$$;

create or replace function public.create_supervisor_maintenance_issue_with_photo(
  actor_user_id uuid,
  target_branch_id uuid,
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
  target_team public.branch_supervisor_teams%rowtype;
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  requested_id uuid;
  attachment jsonb;
  saved public.maintenance_issues%rowtype;
begin
  target_team := private.require_supervisor_maintenance_team(actor_user_id, target_branch_id);
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
    id, organization_id, branch_id, supervisor_team_id, title, category, priority, status,
    description, location, reported_by
  ) values (
    requested_id, target_team.organization_id, target_team.branch_id, target_team.id, clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id
  )
  returning * into saved;

  insert into public.maintenance_issue_attachments(
    id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path,
    original_filename, mime_type, size_bytes, uploaded_by
  ) values (
    (attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'issue',
    attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
    (attachment->>'size_bytes')::bigint, actor_user_id
  );

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
  select * into saved from public.maintenance_issues issue where issue.id = target_issue_id for update;
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
  if clean_status = 'resolved' and not exists (
    select 1 from public.maintenance_issue_attachments attachment
    where attachment.maintenance_issue_id = saved.id
      and attachment.attachment_type = 'repair'
  ) then
    raise exception 'repair photo required to resolve maintenance issue' using errcode='22023';
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

create or replace function public.update_maintenance_issue_with_repair_photo(
  actor_user_id uuid,
  access_user_id uuid,
  target_issue_id uuid,
  new_status text,
  new_note text,
  repair_photo jsonb
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
  attachment jsonb;
begin
  select * into saved from public.maintenance_issues issue where issue.id = target_issue_id for update;
  if saved.id is null then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  if not private.actor_can_maintain_organization(actor_user_id, access_user_id, saved.organization_id) then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  if saved.status = 'closed' then
    raise exception 'maintenance issue is closed' using errcode='23514';
  end if;
  if clean_status <> 'resolved'
    or not private.maintenance_issue_transition_allowed(saved.status, clean_status)
    or coalesce(jsonb_typeof(repair_photo),'null') <> 'object' then
    raise exception 'invalid maintenance issue transition' using errcode='22023';
  end if;
  attachment := private.clean_maintenance_issue_attachment(repair_photo, 'repair');

  insert into public.maintenance_issue_attachments(
    id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path,
    original_filename, mime_type, size_bytes, uploaded_by, uploaded_by_access_user_id
  ) values (
    (attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'repair',
    attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
    (attachment->>'size_bytes')::bigint, actor_user_id, access_user_id
  );

  update public.maintenance_issues issue
  set status = clean_status,
      resolved_at = coalesce(issue.resolved_at, now()),
      closed_at = issue.closed_at
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

revoke all on function private.clean_maintenance_issue_attachment(jsonb, text) from public, anon, authenticated;
revoke all on function public.list_maintenance_issue_attachments(uuid, uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.create_supervisor_maintenance_issue_with_photo(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue(uuid, uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue_with_repair_photo(uuid, uuid, uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function private.clean_maintenance_issue_attachment(jsonb, text) to service_role;
grant execute on function public.list_maintenance_issue_attachments(uuid, uuid, uuid[]) to service_role;
grant execute on function public.create_supervisor_maintenance_issue_with_photo(uuid, uuid, jsonb) to service_role;
grant execute on function public.update_maintenance_issue(uuid, uuid, uuid, text, text) to service_role;
grant execute on function public.update_maintenance_issue_with_repair_photo(uuid, uuid, uuid, text, text, jsonb) to service_role;
