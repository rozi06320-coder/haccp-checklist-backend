-- Phase 2 contract for Maintenance payment method and responsible person.
-- Phase 1 already added nullable columns and constraints. This migration keeps
-- existing function names/signatures where possible, adds responsible-aware
-- update overloads, and preserves payment_status semantics.

create or replace function private.clean_maintenance_payment_method(candidate text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.nullif(pg_catalog.btrim(coalesce(candidate, '')), '');
begin
  if cleaned is null then
    return null;
  end if;
  if cleaned not in ('cash', 'credit_card', 'pay_later') then
    raise exception 'invalid maintenance payment method' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

create or replace function private.clean_maintenance_responsible_person(candidate text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.nullif(pg_catalog.btrim(coalesce(candidate, '')), '');
begin
  if cleaned is null then
    return null;
  end if;
  if pg_catalog.char_length(cleaned) > 100 then
    raise exception 'invalid maintenance responsible person' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

drop function if exists public.update_maintenance_issue(uuid,uuid,uuid,text,text);
drop function if exists public.update_maintenance_issue(uuid,uuid,uuid,text,text,text);
drop function if exists public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb);
drop function if exists public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb,text);
drop function if exists public.create_supervisor_maintenance_issue(uuid,uuid,jsonb);
drop function if exists public.create_supervisor_maintenance_issue_with_photo(uuid,uuid,jsonb);
drop function if exists public.create_manager_office_maintenance_issue(uuid,uuid,jsonb);
drop function if exists public.create_manager_office_maintenance_issue_with_photo(uuid,uuid,jsonb);
drop function if exists public.list_supervisor_maintenance_issues(uuid,uuid);
drop function if exists public.list_maintenance_issues(uuid,uuid,uuid);
drop function if exists public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date);
drop function if exists public.list_maintenance_purchase_logs(uuid,uuid);
drop function if exists public.create_maintenance_purchase_log(uuid,uuid,jsonb);
drop function if exists public.reimburse_maintenance_purchase_log(uuid,uuid,text);
drop function if exists public.list_maintenance_purchase_history(uuid,text);
drop function if exists public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date,text);

create or replace function public.list_supervisor_maintenance_issues(actor_user_id uuid,target_branch_id uuid)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz
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
      issue.reported_by,reporter.full_name,issue.assigned_to,issue.responsible_person_name,
      issue.created_at,issue.updated_at
    from public.maintenance_issues issue
    join public.branches branch on branch.id=issue.branch_id and branch.organization_id=context.organization_id
    left join public.profiles reporter on reporter.id=issue.reported_by
    where issue.organization_id=context.organization_id
      and issue.branch_id=context.branch_id
    order by issue.created_at desc
    limit 500;
end;
$$;

create or replace function public.list_maintenance_issues(actor_user_id uuid, access_user_id uuid, target_organization_id uuid)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz,
  updates jsonb
)
language plpgsql
security definer
set search_path=''
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
      issue.reported_by, reporter.full_name, issue.assigned_to, issue.responsible_person_name,
      issue.created_at, issue.updated_at,
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
  responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
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
    issue.title,issue.category,issue.priority,issue.status,issue.description,issue.location,
    issue.reported_by,reporter.full_name,issue.responsible_person_name,issue.created_at,issue.updated_at,
    coalesce((select jsonb_agg(jsonb_build_object('id',update_row.id,'status',update_row.status,'note',update_row.note,'updated_by',update_row.updated_by,'updated_by_access_user_id',update_row.updated_by_access_user_id,'updated_by_name',coalesce(updater.full_name,access_updater.display_name),'created_at',update_row.created_at) order by update_row.created_at) from public.maintenance_issue_updates update_row left join public.profiles updater on updater.id=update_row.updated_by left join public.maintenance_access_users access_updater on access_updater.id=update_row.updated_by_access_user_id where update_row.issue_id=issue.id and update_row.organization_id=target_organization_id),'[]'::jsonb)
  from public.maintenance_issues issue left join public.branches branch on branch.id=issue.branch_id left join public.profiles reporter on reporter.id=issue.reported_by
  where issue.organization_id=target_organization_id and (branch_filter is null or issue.branch_id=branch_filter) and (status_filter is null or issue.status=status_filter) and (priority_filter is null or issue.priority=priority_filter) and (category_filter is null or issue.category=category_filter) and (date_from_filter is null or issue.created_at::date>=date_from_filter) and (date_to_filter is null or issue.created_at::date<=date_to_filter) and (issue.location_scope='office' or branch.id is not null)
  order by issue.created_at desc;
end;
$$;

create or replace function public.create_supervisor_maintenance_issue(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path=''
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  clean_responsible text := private.clean_maintenance_responsible_person(payload->>'responsible_person_name');
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
  insert into public.maintenance_issues as issue(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by, assigned_to, responsible_person_name, idempotency_key
  ) values (
    requested_id, target_team.organization_id, target_team.branch_id, target_team.id, 'branch', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, null, clean_responsible, request_idempotency_key
  )
  on conflict ((issue.organization_id), (issue.idempotency_key)) where issue.idempotency_key is not null do nothing
  returning * into saved;
  if saved.id is null and request_idempotency_key is not null then
    select * into saved from public.maintenance_issues issue where issue.organization_id = target_team.organization_id and issue.idempotency_key = request_idempotency_key;
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
      reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
    from public.branches branch left join public.profiles reporter on reporter.id = saved.reported_by
    where branch.id = saved.branch_id;
end;
$$;

create or replace function public.create_supervisor_maintenance_issue_with_photo(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path=''
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
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
  attachments := private.clean_maintenance_issue_attachment_array(case when coalesce(jsonb_typeof(payload->'before_photos'), 'null') = 'array' then payload->'before_photos' when coalesce(jsonb_typeof(payload->'before_photo'), 'null') = 'object' then jsonb_build_array(payload->'before_photo') else '[]'::jsonb end,'issue');
  if jsonb_array_length(attachments) = 0 then
    raise exception 'invalid maintenance issue payload' using errcode='22023';
  end if;
  insert into public.maintenance_issues as issue(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by, assigned_to, responsible_person_name, idempotency_key
  ) values (
    requested_id, target_team.organization_id, target_team.branch_id, target_team.id, 'branch', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, null, clean_responsible, request_idempotency_key
  )
  on conflict ((issue.organization_id), (issue.idempotency_key)) where issue.idempotency_key is not null do nothing
  returning * into saved;
  if saved.id is null and request_idempotency_key is not null then
    select * into saved from public.maintenance_issues issue where issue.organization_id = target_team.organization_id and issue.idempotency_key = request_idempotency_key;
  end if;
  if saved.id is null then
    raise exception 'maintenance issue idempotency replay failed' using errcode='23505';
  end if;
  if saved.id = requested_id then
    for attachment in select value from jsonb_array_elements(attachments) loop
      attachment_position := attachment_position + 1;
      insert into public.maintenance_issue_attachments(id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path, original_filename, mime_type, size_bytes, uploaded_by, attachment_position)
      values ((attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'issue', attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type', (attachment->>'size_bytes')::bigint, actor_user_id, attachment_position);
    end loop;
    insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by)
    values(saved.id, saved.organization_id, saved.status, 'Issue reported.', actor_user_id);
  end if;
  return query
    select saved.id, saved.organization_id, saved.branch_id, branch.name, saved.title, saved.category,
      saved.priority, saved.status, saved.description, saved.location, saved.reported_by,
      reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
    from public.branches branch left join public.profiles reporter on reporter.id = saved.reported_by
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
  responsible_person_name text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
declare
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  clean_responsible text := private.clean_maintenance_responsible_person(payload->>'responsible_person_name');
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

  insert into public.maintenance_issues as issue(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by, assigned_to, responsible_person_name, idempotency_key
  ) values (
    requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, null, clean_responsible, request_idempotency_key
  )
  on conflict ((issue.organization_id), (issue.idempotency_key)) where issue.idempotency_key is not null do nothing
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
      reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
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
  responsible_person_name text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
declare
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(nullif(payload->>'category',''), 'other');
  clean_priority text := coalesce(nullif(payload->>'priority',''), 'normal');
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

  insert into public.maintenance_issues as issue(
    id, organization_id, branch_id, supervisor_team_id, location_scope, title, category, priority, status,
    description, location, reported_by, assigned_to, responsible_person_name, idempotency_key
  ) values (
    requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
    clean_priority, 'new', clean_description, clean_location, actor_user_id, null, clean_responsible, request_idempotency_key
  )
  on conflict ((issue.organization_id), (issue.idempotency_key)) where issue.idempotency_key is not null do nothing
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
      reporter.full_name, saved.assigned_to, saved.responsible_person_name, saved.created_at, saved.updated_at
    from public.profiles reporter
    where reporter.id = saved.reported_by;
end;
$$;

create or replace function public.update_maintenance_issue(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path=''
as $$
declare
  existing_responsible text;
begin
  select issue.responsible_person_name
    into existing_responsible
    from public.maintenance_issues issue
    where issue.id = target_issue_id;

  return query
    select * from public.update_maintenance_issue(actor_user_id, access_user_id, target_issue_id, new_status, new_note, existing_responsible);
end;
$$;

create or replace function public.update_maintenance_issue(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text, new_responsible_person_name text
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path=''
as $$
declare
  saved public.maintenance_issues%rowtype;
  clean_status text := coalesce(nullif(new_status,''), '');
  clean_note text := private.clean_maintenance_text(new_note, false, 2000);
  clean_responsible text := private.clean_maintenance_responsible_person(new_responsible_person_name);
begin
  select * into saved from public.maintenance_issues issue where issue.id = target_issue_id for update;
  if saved.id is null or not private.actor_can_maintain_organization(actor_user_id, access_user_id, saved.organization_id) then
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
      responsible_person_name = clean_responsible,
      resolved_at = case when clean_status = 'resolved' then coalesce(issue.resolved_at, now()) when clean_status = 'in_progress' then null else issue.resolved_at end,
      closed_at = case when clean_status = 'closed' then coalesce(issue.closed_at, now()) else issue.closed_at end
  where issue.id = target_issue_id
  returning * into saved;
  insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by, updated_by_access_user_id)
  values(saved.id, saved.organization_id, saved.status, clean_note, actor_user_id, access_user_id);
  return query
    select listed.* from public.list_maintenance_issues(actor_user_id, access_user_id, saved.organization_id) listed where listed.id = target_issue_id;
end;
$$;

create or replace function public.update_maintenance_issue_with_repair_photo(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text, repair_photo jsonb
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path=''
as $$
declare
  existing_responsible text;
begin
  select issue.responsible_person_name
    into existing_responsible
    from public.maintenance_issues issue
    where issue.id = target_issue_id;

  return query
    select * from public.update_maintenance_issue_with_repair_photo(actor_user_id, access_user_id, target_issue_id, new_status, new_note, repair_photo, existing_responsible);
end;
$$;

create or replace function public.update_maintenance_issue_with_repair_photo(
  actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text, repair_photo jsonb, new_responsible_person_name text
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  assigned_to uuid, responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path=''
as $$
declare
  saved public.maintenance_issues%rowtype;
  clean_status text := coalesce(nullif(new_status,''), '');
  clean_note text := private.clean_maintenance_text(new_note, false, 2000);
  clean_responsible text := private.clean_maintenance_responsible_person(new_responsible_person_name);
  attachments jsonb;
  attachment jsonb;
  attachment_position integer := 0;
begin
  select * into saved from public.maintenance_issues issue where issue.id = target_issue_id for update;
  if saved.id is null or not private.actor_can_maintain_organization(actor_user_id, access_user_id, saved.organization_id) then
    raise exception 'maintenance issue access denied' using errcode='42501';
  end if;
  if saved.status = 'closed' then
    raise exception 'maintenance issue is closed' using errcode='23514';
  end if;
  if clean_status <> 'resolved' or not private.maintenance_issue_transition_allowed(saved.status, clean_status) then
    raise exception 'invalid maintenance issue transition' using errcode='22023';
  end if;
  attachments := private.clean_maintenance_issue_attachment_array(case when coalesce(jsonb_typeof(repair_photo), 'null') = 'array' then repair_photo when coalesce(jsonb_typeof(repair_photo), 'null') = 'object' then jsonb_build_array(repair_photo) else '[]'::jsonb end,'repair');
  if jsonb_array_length(attachments) = 0 then
    raise exception 'repair photo required to resolve maintenance issue' using errcode='22023';
  end if;
  for attachment in select value from jsonb_array_elements(attachments) loop
    attachment_position := attachment_position + 1;
    insert into public.maintenance_issue_attachments(id, maintenance_issue_id, organization_id, branch_id, attachment_type, storage_path, original_filename, mime_type, size_bytes, uploaded_by, uploaded_by_access_user_id, attachment_position)
    values ((attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'repair', attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type', (attachment->>'size_bytes')::bigint, actor_user_id, access_user_id, attachment_position);
  end loop;
  update public.maintenance_issues issue
  set status = clean_status,
      responsible_person_name = clean_responsible,
      resolved_at = coalesce(issue.resolved_at, now()),
      closed_at = issue.closed_at
  where issue.id = target_issue_id
  returning * into saved;
  insert into public.maintenance_issue_updates(issue_id, organization_id, status, note, updated_by, updated_by_access_user_id)
  values(saved.id, saved.organization_id, saved.status, clean_note, actor_user_id, access_user_id);
  return query
    select listed.* from public.list_maintenance_issues(actor_user_id, access_user_id, saved.organization_id) listed where listed.id = target_issue_id;
end;
$$;

create or replace function public.list_maintenance_purchase_logs(actor_user_id uuid,target_issue_id uuid)
returns table(id uuid,branch_id uuid,purchase_type text,purchase_scope text,destination text,category text,item_name text,quantity numeric,unit text,amount numeric,vendor_name text,purchase_date date,notes text,payment_status text,payment_method text,reimbursement_note text,reimbursed_at timestamptz,receipt_storage_path text,receipt_original_name text,attachments jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=''
as $$
declare
  issue public.maintenance_issues%rowtype;
begin
  issue:=private.require_maintenance_purchase_issue(actor_user_id,target_issue_id);
  return query
    select p.id,p.branch_id,p.purchase_type,p.purchase_scope,p.destination,p.category,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.payment_method,p.reimbursement_note,p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    where p.maintenance_issue_id=issue.id and p.purchase_type='issue'
    order by p.purchase_date desc,p.created_at desc;
end;
$$;

create or replace function public.create_maintenance_purchase_log(actor_user_id uuid,target_issue_id uuid,payload jsonb)
returns table(id uuid,organization_id uuid,branch_id uuid,maintenance_issue_id uuid,purchase_type text,purchase_scope text,destination text,category text,maintenance_user_id uuid,item_name text,quantity numeric,unit text,amount numeric,vendor_name text,purchase_date date,notes text,payment_status text,payment_method text,reimbursement_note text,reimbursed_at timestamptz,receipt_storage_path text,receipt_original_name text,attachments jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=''
as $$
declare
  issue public.maintenance_issues%rowtype;
  item text:=private.clean_purchase_text(payload->>'item_name',null,120);
  vendor text:=private.clean_purchase_text(payload->>'vendor_name','N/A',120);
  notes_value text:=private.clean_purchase_text(payload->>'notes',null,2000);
  path text:=private.clean_purchase_text(payload->>'receipt_storage_path',null,260);
  filename text:=private.clean_purchase_text(payload->>'receipt_original_name',null,180);
  purchase_unit text:=private.clean_purchase_text(payload->>'unit',null,20);
  requested_scope text:=private.clean_purchase_text(payload->>'purchase_scope',null,20);
  requested_destination text:=private.clean_purchase_text(payload->>'destination',null,120);
  requested_branch_id uuid;
  requested_type text:=private.clean_purchase_text(payload->>'purchase_type',null,20);
  requested_payment_method text:=private.clean_maintenance_payment_method(payload->>'payment_method');
  purchase_id uuid;
  target_organization uuid;
  target_branch uuid;
  saved_type text;
  saved_scope text;
  saved_destination text;
  purchase_category text:=private.clean_purchase_text(payload->>'category',null,40);
  qty numeric;
  cost numeric;
  day date;
  attachment_count integer;
  attachment jsonb;
  attachment_position integer;
  attachment_path text;
  attachment_name text;
  attachment_mime text;
  attachment_size bigint;
begin
  begin
    purchase_id:=coalesce(nullif(payload->>'purchase_id','')::uuid,gen_random_uuid());
    requested_branch_id:=nullif(payload->>'branch_id','')::uuid;
    qty:=(payload->>'quantity')::numeric;
    cost:=(payload->>'amount')::numeric;
    day:=(payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid maintenance purchase payload' using errcode='22023';
  end;
  if item is null or qty<=0 or cost<0 or day is null or purchase_unit not in ('pcs','meter','kg','box','bag','roll','set','liter','other')
    or purchase_category not in ('spare_parts','tools_equipment','electrical','plumbing','hvac_refrigeration','kitchen_equipment','fuel_petrol','transportation','technician_contractor','building_facility','safety_equipment','it_network','general_supplies','other') then
    raise exception 'invalid maintenance purchase payload' using errcode='22023';
  end if;
  if target_issue_id is not null then
    if requested_type is not null and requested_type<>'issue' then raise exception 'invalid maintenance purchase payload' using errcode='22023'; end if;
    issue:=private.require_maintenance_purchase_issue(actor_user_id,target_issue_id);
    target_organization:=issue.organization_id;
    saved_type:='issue';
    if issue.location_scope='office' or issue.branch_id is null then saved_scope:='office'; target_branch:=null; saved_destination:='Office'; else saved_scope:='branch'; target_branch:=issue.branch_id; saved_destination:=null; end if;
  else
    if coalesce(requested_type,'general')<>'general' or (requested_scope is not null and requested_scope<>'other') or requested_branch_id is not null or requested_destination is null then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end if;
    target_organization:=private.require_single_maintenance_purchase_organization(actor_user_id);
    target_branch:=null; saved_type:='general'; saved_scope:='other'; saved_destination:=requested_destination;
  end if;
  if coalesce(jsonb_typeof(payload->'attachments'),'array')<>'array' then raise exception 'invalid maintenance purchase payload' using errcode='22023'; end if;
  attachment_count:=jsonb_array_length(coalesce(payload->'attachments','[]'::jsonb));
  if attachment_count>3 then raise exception 'too many maintenance purchase attachments' using errcode='22023'; end if;
  if attachment_count>0 then
    path:=coalesce(path,private.clean_purchase_text(payload->'attachments'->0->>'storage_path',null,260));
    filename:=coalesce(filename,private.clean_purchase_text(payload->'attachments'->0->>'original_filename',null,180));
  end if;
  insert into public.maintenance_purchase_logs(id,organization_id,branch_id,maintenance_issue_id,purchase_type,purchase_scope,destination,category,maintenance_user_id,item_name,quantity,unit,amount,vendor_name,purchase_date,notes,payment_method,receipt_storage_path,receipt_original_name)
  values(purchase_id,target_organization,target_branch,target_issue_id,saved_type,saved_scope,saved_destination,purchase_category,actor_user_id,item,qty,purchase_unit,cost,vendor,day,notes_value,requested_payment_method,path,filename);
  for attachment, attachment_position in
    select value, ordinality::integer from jsonb_array_elements(coalesce(payload->'attachments','[]'::jsonb)) with ordinality
  loop
    begin
      attachment_path:=private.clean_purchase_text(attachment->>'storage_path',null,260);
      attachment_name:=private.clean_purchase_text(attachment->>'original_filename',null,180);
      attachment_mime:=private.clean_purchase_text(attachment->>'mime_type',null,80);
      attachment_size:=(attachment->>'size_bytes')::bigint;
    exception when others then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end;
    if attachment_path is null or attachment_position not between 1 and 3 or attachment_mime not in ('image/jpeg','image/png','image/webp','application/pdf') or attachment_size<=0 or attachment_size>5242880 then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end if;
    insert into public.maintenance_purchase_attachments(id,purchase_id,organization_id,branch_id,storage_path,original_filename,mime_type,size_bytes,position,uploaded_by)
    values(coalesce(nullif(attachment->>'id','')::uuid,gen_random_uuid()),purchase_id,target_organization,target_branch,attachment_path,attachment_name,attachment_mime,attachment_size,attachment_position,actor_user_id);
  end loop;
  return query
    select p.id,p.organization_id,p.branch_id,p.maintenance_issue_id,p.purchase_type,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.payment_method,p.reimbursement_note,p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    where p.id=purchase_id;
end;
$$;

create or replace function public.reimburse_maintenance_purchase_log(actor_user_id uuid,target_purchase_id uuid,new_note text)
returns table(id uuid,organization_id uuid,branch_id uuid,maintenance_issue_id uuid,purchase_type text,purchase_scope text,destination text,category text,maintenance_user_id uuid,item_name text,quantity numeric,unit text,amount numeric,vendor_name text,purchase_date date,notes text,payment_status text,payment_method text,reimbursement_note text,reimbursed_at timestamptz,receipt_storage_path text,receipt_original_name text,attachments jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=''
as $$
declare
  clean_note text:=private.clean_purchase_text(new_note,null,500);
  changed_id uuid;
begin
  update public.maintenance_purchase_logs p
    set payment_status='reimbursed',reimbursement_note=clean_note,reimbursed_at=coalesce(p.reimbursed_at,now())
    where p.id=target_purchase_id and p.payment_status='unpaid' and private.actor_can_maintain_organization(actor_user_id,null,p.organization_id)
    returning p.id into changed_id;
  if changed_id is null then raise exception 'maintenance purchase access denied' using errcode='42501'; end if;
  return query
    select p.id,p.organization_id,p.branch_id,p.maintenance_issue_id,p.purchase_type,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.payment_method,p.reimbursement_note,p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    where p.id=changed_id;
end;
$$;

create or replace function public.list_maintenance_purchase_history(actor_user_id uuid,purchase_type_filter text)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, maintenance_issue_id uuid, purchase_type text,
  issue_title text, issue_category text, issue_status text, responsible_person_name text, purchase_scope text, destination text,
  category text, maintenance_user_id uuid, maintenance_user_name text, item_name text, quantity numeric,
  unit text, amount numeric, vendor_name text, purchase_date date, notes text, payment_status text, payment_method text,
  reimbursement_note text, reimbursed_at timestamptz, receipt_storage_path text, receipt_original_name text,
  attachments jsonb, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path=''
as $$
begin
  if purchase_type_filter not in ('issue','general') then raise exception 'maintenance purchase history access denied' using errcode='42501'; end if;
  if not private.actor_has_active_maintenance_membership(actor_user_id,null) then raise exception 'maintenance purchase history access denied' using errcode='42501'; end if;
  return query
    select p.id,p.organization_id,p.branch_id,case when p.purchase_scope='branch' then branch.name when p.purchase_scope='office' then 'Office' else p.destination end,
      p.maintenance_issue_id,p.purchase_type,issue.title,issue.category,issue.status,issue.responsible_person_name,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,
      profile.full_name,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.payment_method,p.reimbursement_note,
      p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    left join public.maintenance_issues issue on issue.id=p.maintenance_issue_id
    left join public.branches branch on branch.id=p.branch_id
    left join public.profiles profile on profile.id=p.maintenance_user_id
    where p.purchase_type=purchase_type_filter
      and exists(select 1 from public.maintenance_memberships membership join public.organizations organization on organization.id=membership.organization_id join public.profiles actor_profile on actor_profile.id=membership.user_id where membership.user_id=actor_user_id and membership.organization_id=p.organization_id and membership.active and organization.active and actor_profile.disabled_at is null and not actor_profile.must_change_password)
    order by p.purchase_date desc,p.created_at desc
    limit 1000;
end;
$$;

create or replace function public.list_managed_maintenance_purchases(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  issue_status_filter text default null, payment_status_filter text default null,
  vendor_filter text default null, date_from_filter date default null, date_to_filter date default null,
  purchase_type_filter text default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, maintenance_issue_id uuid, purchase_type text,
  issue_title text, issue_category text, issue_status text, responsible_person_name text, purchase_scope text, destination text,
  category text, maintenance_user_id uuid, maintenance_user_name text, item_name text, quantity numeric,
  unit text, amount numeric, vendor_name text, purchase_date date, notes text, payment_status text, payment_method text,
  reimbursement_note text, reimbursed_at timestamptz, receipt_storage_path text, receipt_original_name text,
  attachments jsonb, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path=''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or (branch_filter is not null and not exists(select 1 from public.branches b where b.id=branch_filter and b.organization_id=target_organization_id))
    or (issue_status_filter is not null and issue_status_filter not in ('new','in_progress','waiting_parts','resolved','closed'))
    or (payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed'))
    or (purchase_type_filter is not null and purchase_type_filter not in ('issue','general'))
    or (date_from_filter is not null and date_to_filter is not null and date_from_filter>date_to_filter) then
    raise exception 'maintenance purchase access denied' using errcode='42501';
  end if;
  return query
    select p.id,p.organization_id,p.branch_id,case when p.purchase_scope='branch' then branch.name when p.purchase_scope='office' then 'Office' else p.destination end,
      p.maintenance_issue_id,p.purchase_type,issue.title,issue.category,issue.status,issue.responsible_person_name,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,
      profile.full_name,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.payment_method,p.reimbursement_note,
      p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    left join public.maintenance_issues issue on issue.id=p.maintenance_issue_id
    left join public.branches branch on branch.id=p.branch_id
    left join public.profiles profile on profile.id=p.maintenance_user_id
    where p.organization_id=target_organization_id and (branch_filter is null or p.branch_id=branch_filter) and (purchase_type_filter is null or p.purchase_type=purchase_type_filter) and (issue_status_filter is null or issue.status=issue_status_filter) and (payment_status_filter is null or p.payment_status=payment_status_filter) and (vendor_filter is null or p.vendor_name ilike '%'||vendor_filter||'%') and (date_from_filter is null or p.purchase_date>=date_from_filter) and (date_to_filter is null or p.purchase_date<=date_to_filter)
    order by p.purchase_date desc,p.created_at desc
    limit 1000;
end;
$$;

revoke all on function private.clean_maintenance_payment_method(text) from public, anon, authenticated, service_role;
revoke all on function private.clean_maintenance_responsible_person(text) from public, anon, authenticated, service_role;
revoke all on function public.list_supervisor_maintenance_issues(uuid,uuid) from public, anon, authenticated;
revoke all on function public.list_maintenance_issues(uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) from public, anon, authenticated;
revoke all on function public.create_supervisor_maintenance_issue(uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.create_supervisor_maintenance_issue_with_photo(uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue(uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.create_manager_office_maintenance_issue_with_photo(uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue(uuid,uuid,uuid,text,text) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue(uuid,uuid,uuid,text,text,text) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.list_maintenance_purchase_logs(uuid,uuid) from public, anon, authenticated;
revoke all on function public.create_maintenance_purchase_log(uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.reimburse_maintenance_purchase_log(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.list_maintenance_purchase_history(uuid,text) from public, anon, authenticated;
revoke all on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date,text) from public, anon, authenticated;

grant execute on function public.list_supervisor_maintenance_issues(uuid,uuid) to service_role;
grant execute on function public.list_maintenance_issues(uuid,uuid,uuid) to service_role;
grant execute on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) to service_role;
grant execute on function public.create_supervisor_maintenance_issue(uuid,uuid,jsonb) to service_role;
grant execute on function public.create_supervisor_maintenance_issue_with_photo(uuid,uuid,jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue(uuid,uuid,jsonb) to service_role;
grant execute on function public.create_manager_office_maintenance_issue_with_photo(uuid,uuid,jsonb) to service_role;
grant execute on function public.update_maintenance_issue(uuid,uuid,uuid,text,text) to service_role;
grant execute on function public.update_maintenance_issue(uuid,uuid,uuid,text,text,text) to service_role;
grant execute on function public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb) to service_role;
grant execute on function public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb,text) to service_role;
grant execute on function public.list_maintenance_purchase_logs(uuid,uuid) to service_role;
grant execute on function public.create_maintenance_purchase_log(uuid,uuid,jsonb) to service_role;
grant execute on function public.reimburse_maintenance_purchase_log(uuid,uuid,text) to service_role;
grant execute on function public.list_maintenance_purchase_history(uuid,text) to service_role;
grant execute on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date,text) to service_role;
