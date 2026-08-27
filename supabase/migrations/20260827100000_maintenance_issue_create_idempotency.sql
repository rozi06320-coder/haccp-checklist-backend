alter table public.maintenance_issues
  add column if not exists idempotency_key uuid;

create unique index if not exists maintenance_issues_org_idempotency_key_idx
on public.maintenance_issues(organization_id, idempotency_key)
where idempotency_key is not null;

create or replace function private.maintenance_issue_idempotency_key(payload jsonb)
returns uuid
language plpgsql
immutable
as $$
declare
  raw_key text := nullif(payload->>'idempotency_key', '');
begin
  if raw_key is null then
    return null;
  end if;
  begin
    return raw_key::uuid;
  exception when others then
    raise exception 'invalid maintenance issue idempotency key' using errcode='22023';
  end;
end;
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
  requested_id uuid;
  request_idempotency_key uuid := private.maintenance_issue_idempotency_key(payload);
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

  insert into public.maintenance_issues(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by, idempotency_key
  ) values (
    requested_id, target_team.organization_id, target_team.branch_id, target_team.id, 'branch', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, request_idempotency_key
  )
  on conflict (organization_id, idempotency_key) where idempotency_key is not null do nothing
  returning * into saved;

  if saved.id is null and request_idempotency_key is not null then
    select * into saved
    from public.maintenance_issues issue
    where issue.organization_id = target_team.organization_id
      and issue.idempotency_key = request_idempotency_key;
  end if;
  if saved.id is null then
    raise exception 'maintenance issue idempotency replay failed' using errcode='23505';
  end if;

  if saved.id = requested_id then
    insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by)
    values(saved.id, saved.organization_id, saved.status, 'Issue reported.', actor_user_id);
  end if;

  return query
    select saved.id, saved.organization_id, saved.branch_id, branch.name, saved.title, saved.category,
      saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
      reporter.full_name, saved.assigned_to, saved.created_at, saved.updated_at
    from public.branches branch
    left join public.profiles reporter on reporter.id = saved.reported_by
    where branch.id = saved.branch_id;
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
  requested_id uuid;
  request_idempotency_key uuid := private.maintenance_issue_idempotency_key(payload);
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

  insert into public.maintenance_issues(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by, idempotency_key
  ) values (
    requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, request_idempotency_key
  )
  on conflict (organization_id, idempotency_key) where idempotency_key is not null do nothing
  returning * into saved;

  if saved.id is null and request_idempotency_key is not null then
    select * into saved
    from public.maintenance_issues issue
    where issue.organization_id = target_organization_id
      and issue.idempotency_key = request_idempotency_key;
  end if;
  if saved.id is null then
    raise exception 'maintenance issue idempotency replay failed' using errcode='23505';
  end if;

  if saved.id = requested_id then
    insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by)
    values(saved.id, saved.organization_id, saved.status, 'Office issue reported.', actor_user_id);
  end if;

  return query
    select saved.id, saved.organization_id, null::uuid, 'Office'::text, saved.title, saved.category,
      saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
      reporter.full_name, saved.assigned_to, saved.created_at, saved.updated_at
    from public.profiles reporter
    where reporter.id = saved.reported_by;
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
  request_idempotency_key uuid := private.maintenance_issue_idempotency_key(payload);
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
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by, idempotency_key
  ) values (
    requested_id, target_team.organization_id, target_team.branch_id, target_team.id, 'branch', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, request_idempotency_key
  )
  on conflict (organization_id, idempotency_key) where idempotency_key is not null do nothing
  returning * into saved;

  if saved.id is null and request_idempotency_key is not null then
    select * into saved
    from public.maintenance_issues issue
    where issue.organization_id = target_team.organization_id
      and issue.idempotency_key = request_idempotency_key;
  end if;
  if saved.id is null then
    raise exception 'maintenance issue idempotency replay failed' using errcode='23505';
  end if;

  if saved.id = requested_id then
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
  end if;

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
  request_idempotency_key uuid := private.maintenance_issue_idempotency_key(payload);
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
    description, location, reported_by, idempotency_key
  ) values (
    requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, request_idempotency_key
  )
  on conflict (organization_id, idempotency_key) where idempotency_key is not null do nothing
  returning * into saved;

  if saved.id is null and request_idempotency_key is not null then
    select * into saved
    from public.maintenance_issues issue
    where issue.organization_id = target_organization_id
      and issue.idempotency_key = request_idempotency_key;
  end if;
  if saved.id is null then
    raise exception 'maintenance issue idempotency replay failed' using errcode='23505';
  end if;

  if saved.id = requested_id then
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
  end if;

  return query
    select saved.id, saved.organization_id, null::uuid, 'Office'::text, saved.title, saved.category,
      saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
      reporter.full_name, saved.assigned_to, saved.created_at, saved.updated_at
    from public.profiles reporter
    where reporter.id = saved.reported_by;
end;
$$;

revoke all on function private.maintenance_issue_idempotency_key(jsonb) from public, anon, authenticated;
revoke all on function public.create_supervisor_maintenance_issue(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_supervisor_maintenance_issue_with_photo(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue_with_photo(uuid, uuid, jsonb) from public, anon, authenticated;

grant execute on function public.create_supervisor_maintenance_issue(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_supervisor_maintenance_issue_with_photo(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue_with_photo(uuid, uuid, jsonb) to service_role;
