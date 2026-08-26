alter table public.maintenance_issue_attachments
  add column if not exists attachment_position integer;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'maintenance_issue_attachments'
      and column_name = 'position'
  ) then
    execute 'update public.maintenance_issue_attachments set attachment_position = "position" where attachment_position is null';
  end if;
end;
$$;

update public.maintenance_issue_attachments
set attachment_position = 1
where attachment_position is null;

alter table public.maintenance_issue_attachments
  alter column attachment_position set not null;

alter table public.maintenance_issue_attachments
  drop constraint if exists maintenance_issue_attachments_position_check;

alter table public.maintenance_issue_attachments
  add constraint maintenance_issue_attachments_position_check check(attachment_position between 1 and 3);

alter table public.maintenance_issue_attachments
  drop constraint if exists maintenance_issue_attachments_one_per_type_key;

alter table public.maintenance_issue_attachments
  drop constraint if exists maintenance_issue_attachments_issue_type_position_key;

alter table public.maintenance_issue_attachments
  add constraint maintenance_issue_attachments_issue_type_position_key unique(maintenance_issue_id, attachment_type, attachment_position);

alter table public.maintenance_issue_attachments
  drop column if exists "position";

drop index if exists maintenance_issue_attachments_issue_idx;
create index if not exists maintenance_issue_attachments_issue_idx
on public.maintenance_issue_attachments(maintenance_issue_id, attachment_type, attachment_position);

create or replace function private.enforce_maintenance_issue_attachment_limit()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if (
    select count(*)
    from public.maintenance_issue_attachments attachment
    where attachment.maintenance_issue_id = new.maintenance_issue_id
      and attachment.attachment_type = new.attachment_type
      and attachment.id <> new.id
  ) >= 3 then
    raise exception 'too many maintenance issue attachments' using errcode='22023';
  end if;
  return new;
end;
$$;

drop trigger if exists maintenance_issue_attachment_limit_check on public.maintenance_issue_attachments;
create trigger maintenance_issue_attachment_limit_check
before insert or update on public.maintenance_issue_attachments
for each row execute function private.enforce_maintenance_issue_attachment_limit();

drop function if exists public.list_maintenance_issue_attachments(uuid, uuid, uuid[]);
create function public.list_maintenance_issue_attachments(
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
  attachment_position integer,
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
      attachment.original_filename, attachment.mime_type, attachment.size_bytes, attachment.attachment_position, attachment.created_at
    from public.maintenance_issue_attachments attachment
    join public.maintenance_issues issue on issue.id = attachment.maintenance_issue_id
    where issue.id = any(target_issue_ids)
      and private.actor_can_view_maintenance_issue(actor_user_id, access_user_id, issue)
    order by attachment.maintenance_issue_id, attachment.attachment_type, attachment.attachment_position, attachment.created_at;
end;
$$;

create or replace function private.clean_maintenance_issue_attachment_array(
  payload jsonb,
  expected_type text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  item jsonb;
  cleaned jsonb := '[]'::jsonb;
begin
  if coalesce(jsonb_typeof(payload), 'null') <> 'array' or jsonb_array_length(payload) > 3 then
    raise exception 'invalid maintenance issue attachment payload' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(payload) loop
    cleaned := cleaned || private.clean_maintenance_issue_attachment(item, expected_type);
  end loop;
  return cleaned;
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
  attachments jsonb;
  attachment jsonb;
  attachment_position integer := 0;
  saved public.maintenance_issues%rowtype;
begin
  target_team := private.require_supervisor_maintenance_team(actor_user_id, target_branch_id);
  if clean_category not in ('equipment','plumbing','electrical','refrigeration','building','other')
    or clean_priority not in ('low','normal','high','urgent') then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;
  begin
    requested_id := coalesce(nullif(payload->>'issue_id','')::uuid, gen_random_uuid());
  exception when others then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end;
  attachments := private.clean_maintenance_issue_attachment_array(
    case
      when coalesce(jsonb_typeof(payload->'before_photos'), 'null') = 'array' then payload->'before_photos'
      when coalesce(jsonb_typeof(payload->'before_photo'), 'null') = 'object' then jsonb_build_array(payload->'before_photo')
      else '[]'::jsonb
    end,
    'issue'
  );
  if jsonb_array_length(attachments) = 0 then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;

  insert into public.maintenance_issues(
    id, organization_id, branch_id, supervisor_team_id, title, category, priority, status,
    description, location, reported_by
  ) values (
    requested_id, target_team.organization_id, target_team.branch_id, target_team.id, clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id
  )
  returning * into saved;

  for attachment in select value from jsonb_array_elements(attachments) loop
    attachment_position := attachment_position + 1;
    insert into public.maintenance_issue_attachments(
      id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path,
      original_filename, mime_type, size_bytes, uploaded_by, attachment_position
    ) values (
      (attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'issue',
      attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
      (attachment->>'size_bytes')::bigint, actor_user_id, attachment_position
    );
  end loop;

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
  attachments jsonb;
  attachment jsonb;
  attachment_position integer := 0;
  saved public.maintenance_issues%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'managed maintenance issue access denied' using errcode='42501';
  end if;
  if clean_category not in ('equipment','plumbing','electrical','refrigeration','building','other')
    or clean_priority not in ('low','normal','high','urgent') then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;
  begin
    requested_id := coalesce(nullif(payload->>'issue_id','')::uuid, gen_random_uuid());
  exception when others then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end;
  attachments := private.clean_maintenance_issue_attachment_array(
    case
      when coalesce(jsonb_typeof(payload->'before_photos'), 'null') = 'array' then payload->'before_photos'
      when coalesce(jsonb_typeof(payload->'before_photo'), 'null') = 'object' then jsonb_build_array(payload->'before_photo')
      else '[]'::jsonb
    end,
    'issue'
  );
  if jsonb_array_length(attachments) = 0 then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;

  insert into public.maintenance_issues(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by
  ) values (
    requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id
  )
  returning * into saved;

  for attachment in select value from jsonb_array_elements(attachments) loop
    attachment_position := attachment_position + 1;
    insert into public.maintenance_issue_attachments(
      id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path,
      original_filename, mime_type, size_bytes, uploaded_by, attachment_position
    ) values (
      (attachment->>'id')::uuid, saved.id, saved.organization_id, null, 'issue',
      attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
      (attachment->>'size_bytes')::bigint, actor_user_id, attachment_position
    );
  end loop;

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
  attachments jsonb;
  attachment jsonb;
  attachment_position integer := 0;
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
    or not private.maintenance_issue_transition_allowed(saved.status, clean_status) then
    raise exception 'invalid maintenance issue transition' using errcode='22023';
  end if;
  attachments := private.clean_maintenance_issue_attachment_array(
    case
      when coalesce(jsonb_typeof(repair_photo), 'null') = 'array' then repair_photo
      when coalesce(jsonb_typeof(repair_photo), 'null') = 'object' then jsonb_build_array(repair_photo)
      else '[]'::jsonb
    end,
    'repair'
  );
  if jsonb_array_length(attachments) = 0 then
    raise exception 'repair photo required to resolve maintenance issue' using errcode='22023';
  end if;

  for attachment in select value from jsonb_array_elements(attachments) loop
    attachment_position := attachment_position + 1;
    insert into public.maintenance_issue_attachments(
      id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path,
      original_filename, mime_type, size_bytes, uploaded_by, uploaded_by_access_user_id, attachment_position
    ) values (
      (attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'repair',
      attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
      (attachment->>'size_bytes')::bigint, actor_user_id, access_user_id, attachment_position
    );
  end loop;

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

revoke all on function private.enforce_maintenance_issue_attachment_limit() from public, anon, authenticated;
revoke all on function private.clean_maintenance_issue_attachment_array(jsonb, text) from public, anon, authenticated;
revoke all on function public.list_maintenance_issue_attachments(uuid, uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.create_supervisor_maintenance_issue_with_photo(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue_with_photo(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue_with_repair_photo(uuid, uuid, uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function private.enforce_maintenance_issue_attachment_limit() to service_role;
grant execute on function private.clean_maintenance_issue_attachment_array(jsonb, text) to service_role;
grant execute on function public.list_maintenance_issue_attachments(uuid, uuid, uuid[]) to service_role;
grant execute on function public.create_supervisor_maintenance_issue_with_photo(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue_with_photo(uuid, uuid, jsonb) to service_role;
grant execute on function public.update_maintenance_issue_with_repair_photo(uuid, uuid, uuid, text, text, jsonb) to service_role;
