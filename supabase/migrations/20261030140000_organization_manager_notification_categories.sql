begin;

-- Phase 2A storage/security foundation only.
-- This migration does not enqueue jobs, create notifications, run a producer,
-- schedule work, or create Web Push deliveries.

alter table public.organization_manager_notifications
  add column branch_id uuid,
  add column business_date date,
  add column category_context jsonb;

revoke all on table public.organization_manager_notifications
  from public, anon, authenticated, service_role;
revoke all on table public.organization_manager_push_deliveries
  from public, anon, authenticated, service_role;

alter table public.organization_manager_notifications
  add constraint organization_manager_notifications_branch_scope_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id)
    on delete restrict;

create index organization_manager_notifications_category_scope_idx
  on public.organization_manager_notifications(
    organization_id, branch_id, business_date, event_type, created_at desc, id desc
  );

create function private.organization_manager_category_context_valid(
  p_event_type text,
  p_context jsonb
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  item text;
  item_count integer;
begin
  if p_context is null or pg_catalog.jsonb_typeof(p_context) <> 'object'
    or p_context->>'schema_version' <> '1'
    or p_context->>'category' <> p_event_type then
    return false;
  end if;

  if p_event_type = 'sales_tracking_missing' then
    if (select count(*) from pg_catalog.jsonb_object_keys(p_context) as object_key(key_name)
        where object_key.key_name not in ('schema_version','category','evidence')) <> 0
      or (select count(*) from pg_catalog.jsonb_object_keys(p_context)) <> 3
      or p_context->>'evidence' <> 'missing' then
      return false;
    end if;
    return true;
  elsif p_event_type = 'maintenance_issue' then
    if (select count(*) from pg_catalog.jsonb_object_keys(p_context) as object_key(key_name)
        where object_key.key_name not in ('schema_version','category','issue_ids','issue_count')) <> 0
      or (select count(*) from pg_catalog.jsonb_object_keys(p_context)) <> 4
      or pg_catalog.jsonb_typeof(p_context->'issue_ids') <> 'array'
      or pg_catalog.jsonb_array_length(p_context->'issue_ids') < 1
      or p_context->>'issue_count' is null
      or p_context->>'issue_count' !~ '^[1-9][0-9]*$' then
      return false;
    end if;
    item_count := pg_catalog.jsonb_array_length(p_context->'issue_ids');
    if (p_context->>'issue_count')::integer <> item_count then return false; end if;
    if exists(
      select 1 from pg_catalog.jsonb_array_elements_text(p_context->'issue_ids') as item(item_value)
      where item.item_value is null or item.item_value !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    ) then return false; end if;
    return (select count(distinct item.item_value)=item_count
      from pg_catalog.jsonb_array_elements_text(p_context->'issue_ids') as item(item_value));
  elsif p_event_type = 'incomplete_branch_tasks' then
    if (select count(*) from pg_catalog.jsonb_object_keys(p_context) as object_key(key_name)
        where object_key.key_name not in ('schema_version','category','incomplete_modules','incomplete_count')) <> 0
      or (select count(*) from pg_catalog.jsonb_object_keys(p_context)) <> 4
      or pg_catalog.jsonb_typeof(p_context->'incomplete_modules') <> 'array'
      or pg_catalog.jsonb_array_length(p_context->'incomplete_modules') < 1
      or p_context->>'incomplete_count' is null
      or p_context->>'incomplete_count' !~ '^[1-6]$' then
      return false;
    end if;
    item_count := pg_catalog.jsonb_array_length(p_context->'incomplete_modules');
    if (p_context->>'incomplete_count')::integer <> item_count then return false; end if;
    if exists(
      select 1 from pg_catalog.jsonb_array_elements_text(p_context->'incomplete_modules') as item(item_value)
      where item.item_value is null or item.item_value not in(
        'kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking'
      )
    ) then return false; end if;
    return (select count(distinct item.item_value)=item_count
      from pg_catalog.jsonb_array_elements_text(p_context->'incomplete_modules') as item(item_value));
  end if;
  return false;
end;
$$;

create function private.organization_manager_notification_branch_date_closed(
  p_organization_id uuid,
  p_branch_id uuid,
  p_business_date date,
  p_as_of timestamptz
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  lifecycle_count bigint;
  branch_timezone text;
  branch_active boolean;
  close_at timestamptz;
begin
  if p_organization_id is null or p_branch_id is null
    or p_business_date is null or p_as_of is null then return false; end if;
  select count(*),min(lifecycle.timezone),bool_and(lifecycle.active)
    into lifecycle_count,branch_timezone,branch_active
  from public.daily_report_branch_lifecycle lifecycle
  where lifecycle.organization_id=p_organization_id
    and lifecycle.branch_id=p_branch_id
    and lifecycle.effective_from_business_date<=p_business_date
    and (lifecycle.effective_to_business_date is null
      or lifecycle.effective_to_business_date>p_business_date);
  if lifecycle_count<>1 or not branch_active or branch_timezone is null then return false; end if;
  close_at:=private.daily_business_report_branch_close_at(p_business_date,branch_timezone);
  return close_at<=p_as_of;
end;
$$;

create function private.organization_manager_category_context_scope_valid(
  p_event_type text,
  p_organization_id uuid,
  p_branch_id uuid,
  p_context jsonb
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare expected_count integer;
begin
  if not private.organization_manager_category_context_valid(p_event_type,p_context) then
    return false;
  end if;
  if p_event_type<>'maintenance_issue' then return true; end if;
  expected_count:=pg_catalog.jsonb_array_length(p_context->'issue_ids');
  return (
    select count(*)=expected_count and count(distinct issue.id)=expected_count
    from pg_catalog.jsonb_array_elements_text(p_context->'issue_ids') as item(item_value)
    join public.maintenance_issues issue
      on issue.id=item.item_value::uuid
      and issue.organization_id=p_organization_id
      and issue.branch_id=p_branch_id
      and issue.location_scope='branch'
  );
end;
$$;

alter table public.organization_manager_notifications
  drop constraint organization_manager_notifications_event_type_check;

alter table public.organization_manager_notifications
  add constraint organization_manager_notifications_event_type_check check(event_type in(
    'maintenance_issue_created','haccp_issue_submitted','hygiene_issue_submitted',
    'daily_audit_issue_submitted','cash_monitoring_submitted','financial_closing_overdue',
    'sales_tracking_missing','maintenance_issue','incomplete_branch_tasks'
  ));

alter table public.organization_manager_notifications
  add constraint organization_manager_notifications_category_context_check check(
    (
      event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      and source_type is null and source_id is null
      and branch_id is not null and business_date is not null
      and private.organization_manager_category_context_valid(event_type,category_context)
    )
    or (
      event_type not in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      and branch_id is null and business_date is null and category_context is null
    )
  );

create or replace function private.guard_organization_manager_notification_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op='DELETE' then
    raise exception 'manager notification history is immutable' using errcode='42501';
  end if;
  if new.id is distinct from old.id
    or new.organization_id is distinct from old.organization_id
    or new.recipient_user_id is distinct from old.recipient_user_id
    or new.event_type is distinct from old.event_type
    or new.source_type is distinct from old.source_type
    or new.source_id is distinct from old.source_id
    or new.branch_id is distinct from old.branch_id
    or new.business_date is distinct from old.business_date
    or new.category_context is distinct from old.category_context
    or new.occurrence_key is distinct from old.occurrence_key
    or new.created_at is distinct from old.created_at then
    raise exception 'manager notification history is immutable' using errcode='42501';
  end if;
  new.updated_at:=statement_timestamp();
  return new;
end;
$$;

create function private.reject_manager_category_push_delivery()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists(
    select 1 from public.organization_manager_notifications notification
    where notification.id=new.notification_id
      and notification.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
  ) then
    raise exception 'category notifications are in-app only' using errcode='42501';
  end if;
  return new;
end;
$$;

drop trigger if exists organization_manager_category_no_push_guard
  on public.organization_manager_push_deliveries;
create trigger organization_manager_category_no_push_guard
before insert or update of notification_id on public.organization_manager_push_deliveries
for each row execute function private.reject_manager_category_push_delivery();

create function public.create_organization_manager_category_notification(
  p_organization_id uuid,
  p_recipient_user_id uuid,
  p_event_type text,
  p_branch_id uuid,
  p_business_date date,
  p_category_context jsonb,
  p_occurrence_key text
)
returns table(notification_id uuid,created boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved_id uuid;
  existing public.organization_manager_notifications%rowtype;
  expected_key text;
begin
  perform private.assert_active_organization_manager(p_recipient_user_id,p_organization_id);
  if p_event_type not in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
    or p_branch_id is null or p_business_date is null
    or p_occurrence_key is null or p_occurrence_key<>pg_catalog.btrim(p_occurrence_key)
    or pg_catalog.length(p_occurrence_key) not between 1 and 200
    or p_occurrence_key!~'^[A-Za-z0-9:_-]+$'
    or not private.organization_manager_category_context_valid(p_event_type,p_category_context)
    or not private.organization_manager_category_context_scope_valid(
      p_event_type,p_organization_id,p_branch_id,p_category_context)
    or not exists(
      select 1 from public.branches branch
      join public.organizations organization on organization.id=branch.organization_id
      where branch.id=p_branch_id and branch.organization_id=p_organization_id and organization.active
    )
    or not private.organization_manager_notification_branch_date_closed(
      p_organization_id,p_branch_id,p_business_date,statement_timestamp()) then
    raise exception 'invalid manager notification category scope' using errcode='22023';
  end if;

  expected_key:='manager:v1:'||p_event_type||':'||p_organization_id::text||':'||p_branch_id::text||':'||p_business_date::text;
  if p_occurrence_key<>expected_key then
    raise exception 'invalid manager notification occurrence key' using errcode='22023';
  end if;

  insert into public.organization_manager_notifications(
    organization_id,recipient_user_id,event_type,source_type,source_id,
    branch_id,business_date,category_context,occurrence_key
  ) values(
    p_organization_id,p_recipient_user_id,p_event_type,null,null,
    p_branch_id,p_business_date,p_category_context,p_occurrence_key
  ) on conflict(organization_id,recipient_user_id,occurrence_key) do nothing
  returning id into saved_id;

  if saved_id is null then
    select notification.* into existing
    from public.organization_manager_notifications notification
    where notification.organization_id=p_organization_id
      and notification.recipient_user_id=p_recipient_user_id
      and notification.occurrence_key=p_occurrence_key;
    if existing.id is null
      or existing.event_type<>p_event_type
      or existing.branch_id is distinct from p_branch_id
      or existing.business_date is distinct from p_business_date
      or existing.category_context is distinct from p_category_context then
      raise exception 'manager notification occurrence conflict' using errcode='23505';
    end if;
    saved_id:=existing.id;
  end if;
  return query select saved_id,(existing.id is null) or existing.id is distinct from saved_id;
end;
$$;

-- Keep the legacy list contract intact, but fail closed for new category rows
-- until their branch-local business date has closed. A later category projection
-- will add normalized category/context fields without duplicating legacy rows.
create or replace function public.list_organization_manager_notifications(
  p_actor_user_id uuid,p_organization_id uuid,p_before timestamptz default null,p_limit integer default 50
)
returns table(
  id uuid,organization_id uuid,event_type text,source_type text,source_id uuid,
  occurrence_key text,read_at timestamptz,created_at timestamptz
)
language plpgsql stable security definer set search_path='' as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_limit not between 1 and 100 then raise exception 'invalid manager notification list' using errcode='22023'; end if;
  return query select notification.id,notification.organization_id,notification.event_type,
    notification.source_type,notification.source_id,notification.occurrence_key,
    notification.read_at,notification.created_at
  from public.organization_manager_notifications notification
  where notification.organization_id=p_organization_id
    and notification.recipient_user_id=p_actor_user_id
    and (p_before is null or notification.created_at<p_before)
    and (
      notification.event_type not in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      or private.organization_manager_notification_branch_date_closed(
        notification.organization_id,notification.branch_id,notification.business_date,statement_timestamp())
    )
  order by notification.created_at desc,notification.id desc limit p_limit;
end;
$$;

revoke all on function private.organization_manager_category_context_valid(text,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function private.organization_manager_notification_branch_date_closed(uuid,uuid,date,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function private.organization_manager_category_context_scope_valid(text,uuid,uuid,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function private.reject_manager_category_push_delivery()
  from public,anon,authenticated,service_role;
revoke all on function public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.list_organization_manager_notifications(uuid,uuid,timestamptz,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)
  to service_role;
grant execute on function public.list_organization_manager_notifications(uuid,uuid,timestamptz,integer)
  to service_role;

commit;
