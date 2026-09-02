alter table public.maintenance_issues
  add column if not exists revision bigint not null default 0,
  add column if not exists planned_repair_date date;

alter table public.maintenance_issues
  drop constraint if exists maintenance_issues_revision_check;
alter table public.maintenance_issues
  add constraint maintenance_issues_revision_check check (revision >= 0);

alter table public.maintenance_issues
  drop constraint if exists maintenance_issues_scope_required_fields_check;
alter table public.maintenance_issues
  add constraint maintenance_issues_scope_required_fields_check check (
    (location_scope = 'branch' and branch_id is not null)
    or (location_scope = 'office' and branch_id is null and supervisor_team_id is null)
  );

alter table public.maintenance_issue_updates
  add column if not exists update_kind text,
  add column if not exists old_planned_repair_date date,
  add column if not exists new_planned_repair_date date,
  add column if not exists change_reason text;

alter table public.maintenance_issue_updates
  alter column update_kind set default 'status_update';

alter table public.maintenance_issue_updates
  drop constraint if exists maintenance_issue_updates_kind_check;
alter table public.maintenance_issue_updates
  add constraint maintenance_issue_updates_kind_check check (
    update_kind is null or update_kind in ('status_update', 'repair_schedule_change')
  );

alter table public.maintenance_issue_updates
  drop constraint if exists maintenance_issue_updates_schedule_check;
alter table public.maintenance_issue_updates
  add constraint maintenance_issue_updates_schedule_check check (
    (coalesce(update_kind, 'status_update') = 'status_update'
      and old_planned_repair_date is null
      and new_planned_repair_date is null
      and change_reason is null)
    or
    (update_kind = 'repair_schedule_change'
      and old_planned_repair_date is distinct from new_planned_repair_date
      and (change_reason is null or (
        change_reason = pg_catalog.btrim(change_reason)
        and length(change_reason) between 1 and 500
      )))
  );

drop index if exists public.maintenance_issues_org_idempotency_key_idx;
create unique index maintenance_issues_branch_idempotency_key_idx
on public.maintenance_issues(organization_id, branch_id, idempotency_key)
where location_scope = 'branch' and idempotency_key is not null;

create unique index maintenance_issues_office_idempotency_key_idx
on public.maintenance_issues(organization_id, idempotency_key)
where location_scope = 'office' and idempotency_key is not null;

create or replace function private.actor_can_view_maintenance_issue(
  actor_user_id uuid,
  access_user_id uuid,
  target_issue public.maintenance_issues
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.actor_can_maintain_organization(actor_user_id, access_user_id, target_issue.organization_id)
    or (
      target_issue.location_scope = 'branch'
      and exists (
        select 1
        from public.profiles profile
        join public.branch_memberships membership
          on membership.user_id = profile.id
        join public.branches branch
          on branch.id = membership.branch_id
        join public.organizations organization
          on organization.id = branch.organization_id
        where profile.id = actor_user_id
          and profile.disabled_at is null
          and not profile.must_change_password
          and membership.branch_id = target_issue.branch_id
          and membership.role = 'branch_manager'
          and membership.active
          and branch.organization_id = target_issue.organization_id
          and branch.active
          and organization.active
      )
    );
$$;

create or replace function private.maintenance_issue_transition_allowed(old_status text, new_status text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select old_status = new_status
    or (old_status = 'new' and new_status in ('in_progress', 'waiting_parts', 'resolved'))
    or (old_status = 'in_progress' and new_status in ('waiting_parts', 'resolved'))
    or (old_status = 'waiting_parts' and new_status in ('in_progress', 'resolved'))
    or (old_status = 'resolved' and new_status = 'closed');
$$;

create or replace function private.maintenance_issue_updates_json(target_issue_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', update_row.id,
    'status', update_row.status,
    'note', update_row.note,
    'updated_by', update_row.updated_by,
    'updated_by_access_user_id', update_row.updated_by_access_user_id,
    'updated_by_name', coalesce(updater.full_name, access_updater.display_name),
    'update_kind', coalesce(update_row.update_kind, 'status_update'),
    'old_planned_repair_date', update_row.old_planned_repair_date,
    'new_planned_repair_date', update_row.new_planned_repair_date,
    'change_reason', update_row.change_reason,
    'created_at', update_row.created_at
  ) order by update_row.created_at, update_row.id), '[]'::jsonb)
  from public.maintenance_issue_updates update_row
  left join public.profiles updater on updater.id = update_row.updated_by
  left join public.maintenance_access_users access_updater
    on access_updater.id = update_row.updated_by_access_user_id
  where update_row.issue_id = target_issue_id;
$$;

create or replace function private.maintenance_issue_json(issue public.maintenance_issues)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', issue.id,
    'organization_id', issue.organization_id,
    'branch_id', issue.branch_id,
    'branch_name', case when issue.location_scope = 'office' then 'Office' else branch.name end,
    'title', issue.title,
    'category', issue.category,
    'priority', issue.priority,
    'status', issue.status,
    'description', issue.description,
    'location', issue.location,
    'reported_by', issue.reported_by,
    'reporter_name', reporter.full_name,
    'assigned_to', issue.assigned_to,
    'responsible_person_name', issue.responsible_person_name,
    'revision', issue.revision,
    'planned_repair_date', issue.planned_repair_date,
    'created_at', issue.created_at,
    'updated_at', issue.updated_at,
    'updates', private.maintenance_issue_updates_json(issue.id)
  )
  from (select 1) seed
  left join public.branches branch on branch.id = issue.branch_id
  left join public.profiles reporter on reporter.id = issue.reported_by;
$$;

create or replace function private.create_maintenance_issue_core(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid,
  target_location_scope text,
  payload jsonb,
  require_before_photo boolean
)
returns public.maintenance_issues
language plpgsql
security definer
set search_path = ''
as $$
declare
  authorized record;
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category', ''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority', ''), 'normal');
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  clean_responsible text := private.clean_maintenance_responsible_person(payload->>'responsible_person_name');
  requested_id uuid;
  request_idempotency_key uuid := private.maintenance_issue_idempotency_key(payload);
  attachments jsonb;
  attachment jsonb;
  attachment_position integer := 0;
  saved public.maintenance_issues%rowtype;
begin
  if target_location_scope = 'branch' then
    select * into authorized
    from private.require_supervisor_maintenance_branch(actor_user_id, target_branch_id);
    if authorized.branch_id is null then
      raise exception 'maintenance issue access denied' using errcode = '42501';
    end if;
    target_organization_id := authorized.organization_id;
    target_branch_id := authorized.branch_id;
  elsif target_location_scope = 'office' then
    if target_organization_id is null
      or not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
      raise exception 'maintenance issue access denied' using errcode = '42501';
    end if;
    target_branch_id := null;
  else
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end if;

  if clean_category not in ('equipment', 'plumbing', 'electrical', 'refrigeration', 'building', 'other')
    or clean_priority not in ('low', 'normal', 'high', 'urgent') then
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end if;

  begin
    requested_id := coalesce(nullif(payload->>'issue_id', '')::uuid, gen_random_uuid());
  exception when others then
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end;

  attachments := private.clean_maintenance_issue_attachment_array(
    case
      when coalesce(jsonb_typeof(payload->'before_photos'), 'null') = 'array' then payload->'before_photos'
      when coalesce(jsonb_typeof(payload->'before_photo'), 'null') = 'object' then jsonb_build_array(payload->'before_photo')
      else '[]'::jsonb
    end,
    'issue'
  );
  if require_before_photo and jsonb_array_length(attachments) = 0 then
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end if;

  if target_location_scope = 'branch' then
    insert into public.maintenance_issues as issue(
      id, organization_id, branch_id, supervisor_team_id, location_scope, title, category,
      priority, status, description, location, reported_by, assigned_to,
      responsible_person_name, idempotency_key
    ) values (
      requested_id, target_organization_id, target_branch_id, null, 'branch', clean_title,
      clean_category, clean_priority, 'new', clean_description, clean_location, actor_user_id,
      null, clean_responsible, request_idempotency_key
    )
    on conflict (organization_id, branch_id, idempotency_key)
      where location_scope = 'branch' and idempotency_key is not null
      do nothing
    returning * into saved;

    if saved.id is null and request_idempotency_key is not null then
      select * into saved
      from public.maintenance_issues issue
      where issue.location_scope = 'branch'
        and issue.organization_id = target_organization_id
        and issue.branch_id = target_branch_id
        and issue.idempotency_key = request_idempotency_key;
    end if;
  else
    insert into public.maintenance_issues as issue(
      id, organization_id, branch_id, supervisor_team_id, location_scope, title, category,
      priority, status, description, location, reported_by, assigned_to,
      responsible_person_name, idempotency_key
    ) values (
      requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
      clean_priority, 'new', clean_description, clean_location, actor_user_id, null,
      clean_responsible, request_idempotency_key
    )
    on conflict (organization_id, idempotency_key)
      where location_scope = 'office' and idempotency_key is not null
      do nothing
    returning * into saved;

    if saved.id is null and request_idempotency_key is not null then
      select * into saved
      from public.maintenance_issues issue
      where issue.location_scope = 'office'
        and issue.organization_id = target_organization_id
        and issue.idempotency_key = request_idempotency_key;
    end if;
  end if;

  if saved.id is null then
    raise exception 'maintenance issue idempotency replay failed' using errcode = '23505';
  end if;

  if saved.id = requested_id then
    for attachment in select value from jsonb_array_elements(attachments) loop
      attachment_position := attachment_position + 1;
      insert into public.maintenance_issue_attachments(
        id, maintenance_issue_id, organization_id, branch_id, attachment_type,
        storage_path, original_filename, mime_type, size_bytes, uploaded_by, attachment_position
      ) values (
        (attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'issue',
        attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
        (attachment->>'size_bytes')::bigint, actor_user_id, attachment_position
      );
    end loop;

    insert into public.maintenance_issue_updates(
      issue_id, organization_id, status, note, updated_by, update_kind
    ) values (
      saved.id, saved.organization_id, saved.status, 'Issue reported.', actor_user_id, 'status_update'
    );
  end if;

  return saved;
end;
$$;

create or replace function public.create_supervisor_maintenance_issue_v2(
  actor_user_id uuid,
  target_branch_id uuid,
  payload jsonb
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, null, target_branch_id, 'branch', payload, false);
  return next private.maintenance_issue_json(saved);
end;
$$;

create or replace function public.create_supervisor_maintenance_issue_with_photo_v2(
  actor_user_id uuid,
  target_branch_id uuid,
  payload jsonb
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, null, target_branch_id, 'branch', payload, true);
  return next private.maintenance_issue_json(saved);
end;
$$;

create or replace function public.create_manager_office_maintenance_issue_v2(
  actor_user_id uuid,
  target_organization_id uuid,
  payload jsonb
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, target_organization_id, null, 'office', payload, false);
  return next private.maintenance_issue_json(saved);
end;
$$;

create or replace function public.create_manager_office_maintenance_issue_with_photo_v2(
  actor_user_id uuid,
  target_organization_id uuid,
  payload jsonb
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, target_organization_id, null, 'office', payload, true);
  return next private.maintenance_issue_json(saved);
end;
$$;

create or replace function public.list_supervisor_maintenance_issues_v2(
  actor_user_id uuid,
  target_branch_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare authorized record; issue public.maintenance_issues%rowtype;
begin
  select * into authorized
  from private.require_supervisor_maintenance_branch(actor_user_id, target_branch_id);
  if authorized.branch_id is null then
    raise exception 'maintenance issue access denied' using errcode = '42501';
  end if;

  for issue in
    select issue_row.*
    from public.maintenance_issues issue_row
    where issue_row.organization_id = authorized.organization_id
      and issue_row.branch_id = authorized.branch_id
      and issue_row.location_scope = 'branch'
    order by issue_row.created_at desc
    limit 500
  loop
    return next private.maintenance_issue_json(issue);
  end loop;
end;
$$;

create or replace function public.list_maintenance_issues_v2(
  actor_user_id uuid,
  access_user_id uuid,
  target_organization_id uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare issue public.maintenance_issues%rowtype;
begin
  if target_organization_id is not null
    and not private.actor_can_maintain_organization(actor_user_id, access_user_id, target_organization_id) then
    raise exception 'maintenance issue access denied' using errcode = '42501';
  end if;

  for issue in
    select issue_row.*
    from public.maintenance_issues issue_row
    where (target_organization_id is null or issue_row.organization_id = target_organization_id)
      and private.actor_can_maintain_organization(actor_user_id, access_user_id, issue_row.organization_id)
    order by issue_row.created_at desc
    limit 1000
  loop
    return next private.maintenance_issue_json(issue);
  end loop;
end;
$$;

create or replace function public.list_managed_maintenance_issues_v2(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  status_filter text default null,
  priority_filter text default null,
  category_filter text default null,
  date_from_filter date default null,
  date_to_filter date default null
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare issue public.maintenance_issues%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (branch_filter is not null and not exists (
      select 1 from public.branches branch
      where branch.id = branch_filter and branch.organization_id = target_organization_id
    ))
    or (status_filter is not null and status_filter not in ('new', 'in_progress', 'waiting_parts', 'resolved', 'closed'))
    or (priority_filter is not null and priority_filter not in ('low', 'normal', 'high', 'urgent'))
    or (category_filter is not null and category_filter not in ('equipment', 'plumbing', 'electrical', 'refrigeration', 'building', 'other'))
    or (date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter) then
    raise exception 'managed maintenance issue access denied' using errcode = '42501';
  end if;

  for issue in
    select issue_row.*
    from public.maintenance_issues issue_row
    where issue_row.organization_id = target_organization_id
      and (branch_filter is null or issue_row.branch_id = branch_filter)
      and (status_filter is null or issue_row.status = status_filter)
      and (priority_filter is null or issue_row.priority = priority_filter)
      and (category_filter is null or issue_row.category = category_filter)
      and (date_from_filter is null or issue_row.created_at::date >= date_from_filter)
      and (date_to_filter is null or issue_row.created_at::date <= date_to_filter)
    order by issue_row.created_at desc
  loop
    return next private.maintenance_issue_json(issue);
  end loop;
end;
$$;

create or replace function private.update_maintenance_issue_core(
  actor_user_id uuid,
  access_user_id uuid,
  target_issue_id uuid,
  new_status text,
  new_note text,
  new_responsible_person_name text,
  preserve_responsible_person boolean,
  expected_revision bigint,
  enforce_revision boolean,
  new_planned_repair_date date,
  preserve_planned_repair_date boolean,
  planned_repair_change_reason text,
  repair_photos jsonb
)
returns public.maintenance_issues
language plpgsql
security definer
set search_path = ''
as $$
declare
  issue public.maintenance_issues%rowtype;
  clean_note text := private.clean_maintenance_text(new_note, false, 2000);
  clean_responsible text := private.clean_maintenance_responsible_person(new_responsible_person_name);
  clean_reason text := private.clean_maintenance_text(planned_repair_change_reason, false, 500);
  attachments jsonb := '[]'::jsonb;
  attachment jsonb;
  attachment_position integer := 0;
  actor_profile_id uuid;
  actor_access_id uuid;
  local_today date;
  schedule_changed boolean;
  old_planned_date date;
begin
  select issue_row.* into issue
  from public.maintenance_issues issue_row
  where issue_row.id = target_issue_id
  for update;

  if issue.id is null or not private.actor_can_maintain_organization(
    actor_user_id, access_user_id, issue.organization_id
  ) then
    raise exception 'maintenance issue access denied' using errcode = '42501';
  end if;
  old_planned_date := issue.planned_repair_date;
  if preserve_responsible_person then clean_responsible := issue.responsible_person_name; end if;
  if preserve_planned_repair_date then new_planned_repair_date := issue.planned_repair_date; end if;
  if enforce_revision and (expected_revision is null or expected_revision <> issue.revision) then
    raise exception 'maintenance issue changed' using errcode = '40001';
  end if;
  if issue.status = 'closed'
    or new_status not in ('new', 'in_progress', 'waiting_parts', 'resolved', 'closed')
    or not private.maintenance_issue_transition_allowed(issue.status, new_status) then
    raise exception 'invalid maintenance issue transition' using errcode = '22023';
  end if;

  if repair_photos is null then
    if new_status = 'resolved' then
      raise exception 'repair proof required to resolve maintenance issue' using errcode = '22023';
    end if;
  else
    if new_status <> 'resolved' or issue.status in ('resolved', 'closed') then
      raise exception 'invalid maintenance issue transition' using errcode = '22023';
    end if;
    attachments := private.clean_maintenance_issue_attachment_array(repair_photos, 'repair');
    if jsonb_array_length(attachments) = 0 then
      raise exception 'repair proof required to resolve maintenance issue' using errcode = '22023';
    end if;
  end if;

  if issue.branch_id is not null then
    select (statement_timestamp() at time zone branch.timezone)::date into local_today
    from public.branches branch
    where branch.id = issue.branch_id and branch.organization_id = issue.organization_id;
  else
    local_today := current_date;
  end if;
  schedule_changed := issue.planned_repair_date is distinct from new_planned_repair_date;
  if schedule_changed and new_planned_repair_date is not null and new_planned_repair_date < local_today then
    raise exception 'planned repair date is in the past' using errcode = '22023';
  end if;

  if schedule_changed and issue.planned_repair_date is not null and clean_reason is null then
    raise exception 'planned repair date change reason required' using errcode = '22023';
  end if;

  if actor_user_id is not null then actor_profile_id := actor_user_id; else actor_access_id := access_user_id; end if;

  if jsonb_array_length(attachments) > 0 then
    for attachment in select value from jsonb_array_elements(attachments) loop
      attachment_position := attachment_position + 1;
      insert into public.maintenance_issue_attachments(
        id, maintenance_issue_id, organization_id, branch_id, attachment_type,
        storage_path, original_filename, mime_type, size_bytes,
        uploaded_by, uploaded_by_access_user_id, attachment_position
      ) values (
        (attachment->>'id')::uuid, issue.id, issue.organization_id, issue.branch_id, 'repair',
        attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
        (attachment->>'size_bytes')::bigint, actor_profile_id, actor_access_id, attachment_position
      );
    end loop;
  end if;

  update public.maintenance_issues issue_row
  set status = new_status,
      responsible_person_name = clean_responsible,
      planned_repair_date = new_planned_repair_date,
      resolved_at = case when new_status = 'resolved' then statement_timestamp() else issue_row.resolved_at end,
      closed_at = case when new_status = 'closed' then statement_timestamp() else issue_row.closed_at end,
      revision = issue_row.revision + 1
  where issue_row.id = issue.id
  returning * into issue;

  insert into public.maintenance_issue_updates(
    issue_id, organization_id, status, note, updated_by, updated_by_access_user_id, update_kind
  ) values (
    issue.id, issue.organization_id, issue.status, clean_note, actor_profile_id, actor_access_id, 'status_update'
  );

  if schedule_changed then
    insert into public.maintenance_issue_updates(
      issue_id, organization_id, status, note, updated_by, updated_by_access_user_id,
      update_kind, old_planned_repair_date, new_planned_repair_date, change_reason
    ) values (
      issue.id, issue.organization_id, issue.status, null, actor_profile_id, actor_access_id,
      'repair_schedule_change', old_planned_date,
      new_planned_repair_date, clean_reason
    );
  end if;

  return issue;
end;
$$;

create or replace function public.update_maintenance_issue(
  actor_user_id uuid,
  access_user_id uuid,
  target_issue_id uuid,
  new_status text,
  new_note text,
  new_responsible_person_name text,
  expected_revision bigint,
  new_planned_repair_date date,
  planned_repair_change_reason text
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.update_maintenance_issue_core(
    actor_user_id, access_user_id, target_issue_id, new_status, new_note,
    new_responsible_person_name, false, expected_revision, true, new_planned_repair_date,
    false, planned_repair_change_reason, null
  );
  return next private.maintenance_issue_json(saved);
end;
$$;

create or replace function public.update_maintenance_issue_with_repair_photo(
  actor_user_id uuid,
  access_user_id uuid,
  target_issue_id uuid,
  new_status text,
  new_note text,
  repair_photo jsonb,
  new_responsible_person_name text,
  expected_revision bigint,
  new_planned_repair_date date,
  planned_repair_change_reason text
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.update_maintenance_issue_core(
    actor_user_id, access_user_id, target_issue_id, new_status, new_note,
    new_responsible_person_name, false, expected_revision, true, new_planned_repair_date,
    false, planned_repair_change_reason, repair_photo
  );
  return next private.maintenance_issue_json(saved);
end;
$$;

-- Rollout-compatible legacy create signatures use the corrected scoped core.
create or replace function public.create_supervisor_maintenance_issue(
  actor_user_id uuid, target_branch_id uuid, payload jsonb
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, null, target_branch_id, 'branch', payload, false);
  return query select saved.id, saved.organization_id, saved.branch_id, branch.name, saved.title,
    saved.category, saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
    reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
  from public.branches branch
  left join public.profiles reporter on reporter.id = saved.reported_by
  where branch.id = saved.branch_id;
end;
$$;

create or replace function public.create_supervisor_maintenance_issue_with_photo(
  actor_user_id uuid, target_branch_id uuid, payload jsonb
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, null, target_branch_id, 'branch', payload, true);
  return query select saved.id, saved.organization_id, saved.branch_id, branch.name, saved.title,
    saved.category, saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
    reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
  from public.branches branch
  left join public.profiles reporter on reporter.id = saved.reported_by
  where branch.id = saved.branch_id;
end;
$$;

create or replace function public.create_manager_office_maintenance_issue(
  actor_user_id uuid, target_organization_id uuid, payload jsonb
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, target_organization_id, null, 'office', payload, false);
  return query select saved.id, saved.organization_id, null::uuid, 'Office'::text, saved.title,
    saved.category, saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
    reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
  from public.profiles reporter where reporter.id = saved.reported_by;
end;
$$;

create or replace function public.create_manager_office_maintenance_issue_with_photo(
  actor_user_id uuid, target_organization_id uuid, payload jsonb
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.create_maintenance_issue_core(actor_user_id, target_organization_id, null, 'office', payload, true);
  return query select saved.id, saved.organization_id, null::uuid, 'Office'::text, saved.title,
    saved.category, saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
    reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
  from public.profiles reporter where reporter.id = saved.reported_by;
end;
$$;

-- Legacy update overloads remain temporarily, but inherit proof and reopen invariants.
create or replace function public.update_maintenance_issue(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.update_maintenance_issue_core(
    actor_user_id, access_user_id, target_issue_id, new_status, new_note, null, true,
    null, false, null, true, null, null
  );
  return query select listed.* from public.list_maintenance_issues(
    actor_user_id, access_user_id, saved.organization_id
  ) listed where listed.id = saved.id;
end;
$$;

create or replace function public.update_maintenance_issue(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text,
  new_responsible_person_name text
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.update_maintenance_issue_core(
    actor_user_id, access_user_id, target_issue_id, new_status, new_note,
    new_responsible_person_name, false, null, false, null, true, null, null
  );
  return query select listed.* from public.list_maintenance_issues(
    actor_user_id, access_user_id, saved.organization_id
  ) listed where listed.id = saved.id;
end;
$$;

create or replace function public.update_maintenance_issue_with_repair_photo(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text,
  repair_photo jsonb
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.update_maintenance_issue_core(
    actor_user_id, access_user_id, target_issue_id, new_status, new_note, null, true,
    null, false, null, true, null, repair_photo
  );
  return query select listed.* from public.list_maintenance_issues(
    actor_user_id, access_user_id, saved.organization_id
  ) listed where listed.id = saved.id;
end;
$$;

create or replace function public.update_maintenance_issue_with_repair_photo(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text,
  repair_photo jsonb, new_responsible_person_name text
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path = ''
as $$
declare saved public.maintenance_issues%rowtype;
begin
  saved := private.update_maintenance_issue_core(
    actor_user_id, access_user_id, target_issue_id, new_status, new_note,
    new_responsible_person_name, false, null, false, null, true, null, repair_photo
  );
  return query select listed.* from public.list_maintenance_issues(
    actor_user_id, access_user_id, saved.organization_id
  ) listed where listed.id = saved.id;
end;
$$;

revoke all on function private.actor_can_view_maintenance_issue(uuid, uuid, public.maintenance_issues) from public, anon, authenticated;
revoke all on function private.maintenance_issue_updates_json(uuid) from public, anon, authenticated, service_role;
revoke all on function private.maintenance_issue_json(public.maintenance_issues) from public, anon, authenticated, service_role;
revoke all on function private.create_maintenance_issue_core(uuid, uuid, uuid, text, jsonb, boolean) from public, anon, authenticated, service_role;
revoke all on function private.update_maintenance_issue_core(uuid, uuid, uuid, text, text, text, boolean, bigint, boolean, date, boolean, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.create_supervisor_maintenance_issue_v2(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_supervisor_maintenance_issue_with_photo_v2(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue_v2(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue_with_photo_v2(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.list_supervisor_maintenance_issues_v2(uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_maintenance_issues_v2(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_managed_maintenance_issues_v2(uuid, uuid, uuid, text, text, text, date, date) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue(uuid, uuid, uuid, text, text, text, bigint, date, text) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue_with_repair_photo(uuid, uuid, uuid, text, text, jsonb, text, bigint, date, text) from public, anon, authenticated;

grant execute on function public.create_supervisor_maintenance_issue_v2(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_supervisor_maintenance_issue_with_photo_v2(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue_v2(uuid, uuid, jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue_with_photo_v2(uuid, uuid, jsonb) to service_role;
grant execute on function public.list_supervisor_maintenance_issues_v2(uuid, uuid) to service_role;
grant execute on function public.list_maintenance_issues_v2(uuid, uuid, uuid) to service_role;
grant execute on function public.list_managed_maintenance_issues_v2(uuid, uuid, uuid, text, text, text, date, date) to service_role;
grant execute on function public.update_maintenance_issue(uuid, uuid, uuid, text, text, text, bigint, date, text) to service_role;
grant execute on function public.update_maintenance_issue_with_repair_photo(uuid, uuid, uuid, text, text, jsonb, text, bigint, date, text) to service_role;
