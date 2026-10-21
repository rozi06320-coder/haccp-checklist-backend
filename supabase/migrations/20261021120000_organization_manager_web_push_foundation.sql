-- Organization Manager Web Push foundation. This migration installs durable
-- history and queue primitives only; it does not schedule or send pushes.

create table public.organization_manager_notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  recipient_user_id uuid not null,
  event_type text not null,
  source_type text,
  source_id uuid,
  occurrence_key text not null,
  read_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint organization_manager_notifications_event_type_check
    check(event_type in(
      'maintenance_issue_created','haccp_issue_submitted','hygiene_issue_submitted',
      'daily_audit_issue_submitted','cash_monitoring_submitted','financial_closing_overdue'
    )),
  constraint organization_manager_notifications_source_check check(
    (source_type is null and source_id is null)
    or (source_type in('maintenance_issue','checklist_submission','sales_tracking_report','financial_closing_report') and source_id is not null)
  ),
  constraint organization_manager_notifications_occurrence_check
    check(occurrence_key=pg_catalog.btrim(occurrence_key)
      and pg_catalog.length(occurrence_key) between 1 and 200
      and occurrence_key~'^[A-Za-z0-9:_-]+$'),
  constraint organization_manager_notifications_read_check
    check(read_at is null or read_at>=created_at),
  unique(organization_id,recipient_user_id,occurrence_key)
);

create index organization_manager_notifications_recipient_idx
  on public.organization_manager_notifications(organization_id,recipient_user_id,created_at desc,id desc);
create index organization_manager_notifications_unread_idx
  on public.organization_manager_notifications(organization_id,recipient_user_id,created_at desc)
  where read_at is null;

create table public.organization_manager_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.organization_manager_notifications(id) on delete restrict,
  push_subscription_id uuid references public.push_subscriptions(id) on delete set null,
  state text not null default 'pending',
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default statement_timestamp(),
  lease_token uuid,
  leased_by uuid,
  lease_expires_at timestamptz,
  last_http_status integer,
  terminal_reason text,
  sent_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint organization_manager_push_deliveries_state_check
    check(state in('pending','sending','sent','retry','terminal')),
  constraint organization_manager_push_deliveries_attempt_check
    check(attempt_count between 0 and 5),
  constraint organization_manager_push_deliveries_http_check
    check(last_http_status is null or last_http_status between 100 and 599),
  constraint organization_manager_push_deliveries_lease_check check(
    (state='sending' and lease_token is not null and leased_by is not null and lease_expires_at is not null)
    or (state<>'sending' and lease_token is null and leased_by is null and lease_expires_at is null)
  ),
  constraint organization_manager_push_deliveries_sent_check check(
    (state='sent' and sent_at is not null and terminal_reason is null)
    or (state<>'sent' and sent_at is null)
  ),
  constraint organization_manager_push_deliveries_terminal_check check(
    (state='terminal' and terminal_reason in(
      'recipient_ineligible','retry_exhausted','endpoint_expired','delivery_rejected','subscription_disabled'
    ))
    or (state<>'terminal' and terminal_reason is null)
  )
);

create unique index organization_manager_push_deliveries_notification_subscription_key
  on public.organization_manager_push_deliveries(notification_id,push_subscription_id)
  where push_subscription_id is not null;
create index organization_manager_push_deliveries_claim_idx
  on public.organization_manager_push_deliveries(next_attempt_at,created_at,id)
  where state in('pending','retry');
create index organization_manager_push_deliveries_lease_idx
  on public.organization_manager_push_deliveries(lease_expires_at,id)
  where state='sending';

create table private.organization_manager_push_rate_limits (
  operation text not null,
  dimension text not null,
  key_hash text not null,
  bucket_started_at timestamptz not null,
  attempt_count integer not null,
  updated_at timestamptz not null default statement_timestamp(),
  primary key(operation,dimension,key_hash,bucket_started_at),
  constraint organization_manager_push_rate_operation_check
    check(operation in('register','disable','mark_read')),
  constraint organization_manager_push_rate_dimension_check
    check(dimension in('actor','organization','ip')),
  constraint organization_manager_push_rate_hash_check check(key_hash~'^[0-9a-f]{64}$'),
  constraint organization_manager_push_rate_count_check check(attempt_count>0)
);

alter table public.organization_manager_notifications enable row level security;
alter table public.organization_manager_push_deliveries enable row level security;
revoke all on table public.organization_manager_notifications from public,anon,authenticated,service_role;
revoke all on table public.organization_manager_push_deliveries from public,anon,authenticated,service_role;
revoke all on table private.organization_manager_push_rate_limits from public,anon,authenticated,service_role;

create function private.assert_active_organization_manager(
  p_actor_user_id uuid,p_organization_id uuid
)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  if p_actor_user_id is null or p_organization_id is null
    or not exists(select 1 from public.profiles profile
      where profile.id=p_actor_user_id and profile.disabled_at is null
        and not profile.must_change_password)
    or not exists(select 1 from public.organization_memberships membership
      join public.organizations organization on organization.id=membership.organization_id
      where membership.user_id=p_actor_user_id
        and membership.organization_id=p_organization_id
        and membership.role='organization_manager' and membership.active
        and organization.active)
  then
    raise exception 'manager notification access denied' using errcode='42501';
  end if;
  return true;
end;
$$;

create function private.browser_push_endpoint_is_allowed(p_endpoint text)
returns boolean language sql immutable strict security definer set search_path='' as $$
  select p_endpoint=pg_catalog.btrim(p_endpoint)
    and pg_catalog.length(p_endpoint) between 12 and 4096
    and p_endpoint!~'[[:cntrl:][:space:]]'
    and p_endpoint!~'#'
    and p_endpoint~'^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|([a-z0-9-]+\.)*push\.apple\.com|([a-z0-9-]+\.)*notify\.windows\.com)/[^@]*$';
$$;

-- Preserve legacy rows but prevent them from remaining outbound capabilities
-- when they do not identify a supported browser-vendor push service.
update public.push_subscriptions subscription
set disabled_at=coalesce(subscription.disabled_at,statement_timestamp())
where subscription.disabled_at is null
  and not private.browser_push_endpoint_is_allowed(subscription.endpoint);
alter table public.push_subscriptions
  add constraint push_subscriptions_safe_active_endpoint_check
  check(disabled_at is not null or private.browser_push_endpoint_is_allowed(endpoint)) not valid;
alter table public.push_subscriptions
  validate constraint push_subscriptions_safe_active_endpoint_check;

create function private.organization_manager_notification_source_matches(
  p_organization_id uuid,p_source_type text,p_source_id uuid
)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  if p_source_type is null and p_source_id is null then return true; end if;
  if p_source_type='maintenance_issue' then
    return exists(select 1 from public.maintenance_issues source
      where source.id=p_source_id and source.organization_id=p_organization_id);
  elsif p_source_type='checklist_submission' then
    return exists(select 1 from public.checklist_submissions source
      where source.id=p_source_id and source.organization_id=p_organization_id and source.state='submitted');
  elsif p_source_type='sales_tracking_report' then
    return exists(select 1 from public.sales_tracking_reports source
      where source.id=p_source_id and source.organization_id=p_organization_id and source.state='submitted');
  elsif p_source_type='financial_closing_report' then
    return exists(select 1 from public.financial_closing_reports source
      where source.id=p_source_id and source.organization_id=p_organization_id and source.state='submitted');
  end if;
  return false;
end;
$$;

create function private.guard_organization_manager_notification_history()
returns trigger language plpgsql security definer set search_path='' as $$
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
    or new.occurrence_key is distinct from old.occurrence_key
    or new.created_at is distinct from old.created_at
  then
    raise exception 'manager notification history is immutable' using errcode='42501';
  end if;
  new.updated_at:=statement_timestamp();
  return new;
end;
$$;

create trigger organization_manager_notifications_history_guard
before update or delete on public.organization_manager_notifications
for each row execute function private.guard_organization_manager_notification_history();

create function public.authorize_organization_manager_push_access(
  p_actor_user_id uuid,p_organization_id uuid
)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  return private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
end;
$$;

create function public.register_organization_manager_push_subscription(
  p_actor_user_id uuid,p_organization_id uuid,p_endpoint text,p_p256dh text,p_auth text,p_user_agent text default null
)
returns table(id uuid,user_id uuid,endpoint text,disabled_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare existing public.push_subscriptions%rowtype;
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if not private.browser_push_endpoint_is_allowed(p_endpoint)
    or p_p256dh is null or pg_catalog.length(p_p256dh) not between 16 and 512
      or p_p256dh!~'^[A-Za-z0-9_-]+$'
    or p_auth is null or pg_catalog.length(p_auth) not between 8 and 256
      or p_auth!~'^[A-Za-z0-9_-]+$'
    or (p_user_agent is not null and (p_user_agent<>pg_catalog.btrim(p_user_agent)
      or pg_catalog.length(p_user_agent) not between 1 and 512))
  then raise exception 'invalid manager push subscription' using errcode='22023'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_endpoint,0));
  select * into existing from public.push_subscriptions subscription
  where subscription.endpoint=p_endpoint for update;
  if existing.id is not null and existing.user_id<>p_actor_user_id then
    raise exception 'push subscription belongs to another account' using errcode='23505';
  end if;
  if existing.id is null then
    return query insert into public.push_subscriptions(user_id,endpoint,p256dh,auth,user_agent,last_seen_at,disabled_at)
      values(p_actor_user_id,p_endpoint,p_p256dh,p_auth,p_user_agent,statement_timestamp(),null)
      returning push_subscriptions.id,push_subscriptions.user_id,push_subscriptions.endpoint,push_subscriptions.disabled_at;
  else
    return query update public.push_subscriptions subscription
      set p256dh=p_p256dh,auth=p_auth,user_agent=p_user_agent,last_seen_at=statement_timestamp(),disabled_at=null
      where subscription.id=existing.id
      returning subscription.id,subscription.user_id,subscription.endpoint,subscription.disabled_at;
  end if;
end;
$$;

create function public.disable_organization_manager_push_subscription(
  p_actor_user_id uuid,p_organization_id uuid,p_endpoint text
)
returns table(id uuid,user_id uuid,endpoint text,disabled_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare target_subscription_id uuid;
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_endpoint is null or p_endpoint<>pg_catalog.btrim(p_endpoint)
    or pg_catalog.length(p_endpoint) not between 12 and 4096
  then raise exception 'invalid manager push subscription' using errcode='22023'; end if;
  select subscription.id into target_subscription_id from public.push_subscriptions subscription
    where subscription.user_id=p_actor_user_id and subscription.endpoint=p_endpoint for update;
  update public.organization_manager_push_deliveries delivery
    set state='terminal',terminal_reason='subscription_disabled',lease_token=null,leased_by=null,lease_expires_at=null,
      updated_at=statement_timestamp()
    where delivery.push_subscription_id=target_subscription_id and delivery.state in('pending','retry');
  return query update public.push_subscriptions subscription
    set disabled_at=coalesce(subscription.disabled_at,statement_timestamp()),last_seen_at=statement_timestamp()
    where subscription.id=target_subscription_id
    returning subscription.id,subscription.user_id,subscription.endpoint,subscription.disabled_at;
end;
$$;

create function public.consume_organization_manager_push_rate_limit(
  p_actor_user_id uuid,p_organization_id uuid,p_client_address_hash text,p_operation text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare bucket_start timestamptz; actor_count integer; organization_count integer; ip_count integer;
  actor_limit integer; organization_limit integer; ip_limit integer;
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_client_address_hash is null or p_client_address_hash!~'^[0-9a-f]{64}$'
    or p_operation not in('register','disable','mark_read')
  then raise exception 'invalid manager push rate limit request' using errcode='22023'; end if;
  bucket_start:=date_bin(interval '15 minutes',statement_timestamp(),timestamptz '2000-01-01 00:00:00+00');
  actor_limit:=case p_operation when'register'then 10 when'disable'then 20 else 120 end;
  organization_limit:=case p_operation when'register'then 100 when'disable'then 200 else 1200 end;
  ip_limit:=case p_operation when'register'then 30 when'disable'then 60 else 300 end;

  insert into private.organization_manager_push_rate_limits(operation,dimension,key_hash,bucket_started_at,attempt_count)
  values(p_operation,'actor',encode(extensions.digest(pg_catalog.convert_to(p_actor_user_id::text,'UTF8'),'sha256'),'hex'),bucket_start,1)
  on conflict(operation,dimension,key_hash,bucket_started_at) do update
    set attempt_count=private.organization_manager_push_rate_limits.attempt_count+1,updated_at=statement_timestamp()
  returning attempt_count into actor_count;
  insert into private.organization_manager_push_rate_limits(operation,dimension,key_hash,bucket_started_at,attempt_count)
  values(p_operation,'organization',encode(extensions.digest(pg_catalog.convert_to(p_organization_id::text,'UTF8'),'sha256'),'hex'),bucket_start,1)
  on conflict(operation,dimension,key_hash,bucket_started_at) do update
    set attempt_count=private.organization_manager_push_rate_limits.attempt_count+1,updated_at=statement_timestamp()
  returning attempt_count into organization_count;
  insert into private.organization_manager_push_rate_limits(operation,dimension,key_hash,bucket_started_at,attempt_count)
  values(p_operation,'ip',p_client_address_hash,bucket_start,1)
  on conflict(operation,dimension,key_hash,bucket_started_at) do update
    set attempt_count=private.organization_manager_push_rate_limits.attempt_count+1,updated_at=statement_timestamp()
  returning attempt_count into ip_count;
  return pg_catalog.jsonb_build_object('allowed',actor_count<=actor_limit
    and organization_count<=organization_limit and ip_count<=ip_limit);
end;
$$;

create function public.create_organization_manager_notification(
  p_organization_id uuid,p_recipient_user_id uuid,p_event_type text,
  p_source_type text,p_source_id uuid,p_occurrence_key text
)
returns table(notification_id uuid,created boolean)
language plpgsql security definer set search_path='' as $$
declare saved_id uuid; inserted boolean:=false;
begin
  perform private.assert_active_organization_manager(p_recipient_user_id,p_organization_id);
  if p_event_type not in('maintenance_issue_created','haccp_issue_submitted','hygiene_issue_submitted',
      'daily_audit_issue_submitted','cash_monitoring_submitted','financial_closing_overdue')
    or p_occurrence_key is null or p_occurrence_key<>pg_catalog.btrim(p_occurrence_key)
    or pg_catalog.length(p_occurrence_key) not between 1 and 200
    or p_occurrence_key!~'^[A-Za-z0-9:_-]+$'
    or (p_event_type<>'financial_closing_overdue' and (p_source_type is null or p_source_id is null))
    or not private.organization_manager_notification_source_matches(
      p_organization_id,p_source_type,p_source_id)
  then raise exception 'invalid manager notification' using errcode='22023'; end if;

  insert into public.organization_manager_notifications(
    organization_id,recipient_user_id,event_type,source_type,source_id,occurrence_key
  ) values(p_organization_id,p_recipient_user_id,p_event_type,p_source_type,p_source_id,p_occurrence_key)
  on conflict(organization_id,recipient_user_id,occurrence_key) do nothing
  returning id into saved_id;
  if saved_id is not null then inserted:=true; else
    select notification.id into saved_id from public.organization_manager_notifications notification
    where notification.organization_id=p_organization_id
      and notification.recipient_user_id=p_recipient_user_id
      and notification.occurrence_key=p_occurrence_key
      and notification.event_type=p_event_type
      and notification.source_type is not distinct from p_source_type
      and notification.source_id is not distinct from p_source_id;
    if saved_id is null then
      raise exception 'manager notification occurrence conflict' using errcode='23505';
    end if;
  end if;

  insert into public.organization_manager_push_deliveries(notification_id,push_subscription_id)
  select saved_id,subscription.id from public.push_subscriptions subscription
  where subscription.user_id=p_recipient_user_id and subscription.disabled_at is null
  on conflict do nothing;
  return query select saved_id,inserted;
end;
$$;

create function public.list_organization_manager_notifications(
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
  order by notification.created_at desc,notification.id desc limit p_limit;
end;
$$;

create function public.mark_organization_manager_notification_read(
  p_actor_user_id uuid,p_organization_id uuid,p_notification_id uuid
)
returns table(id uuid,read_at timestamptz)
language plpgsql security definer set search_path='' as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  return query update public.organization_manager_notifications notification
    set read_at=coalesce(notification.read_at,statement_timestamp())
    where notification.id=p_notification_id and notification.organization_id=p_organization_id
      and notification.recipient_user_id=p_actor_user_id
    returning notification.id,notification.read_at;
end;
$$;

create function public.claim_organization_manager_push_deliveries(
  p_worker_id uuid,p_limit integer default 50,p_lease_seconds integer default 60
)
returns table(
  delivery_id uuid,lease_token uuid,notification_id uuid,subscription_id uuid,
  recipient_user_id uuid,organization_id uuid,event_type text,source_type text,
  source_id uuid,endpoint text,p256dh text,auth text,attempt_count integer,lease_expires_at timestamptz
)
language plpgsql security definer set search_path='' as $$
begin
  if p_worker_id is null or p_limit not between 1 and 100 or p_lease_seconds not between 30 and 300
  then raise exception 'invalid manager push claim' using errcode='22023'; end if;

  update public.organization_manager_push_deliveries delivery
  set state=case when delivery.attempt_count>=5 then'terminal'else'retry'end,
    next_attempt_at=case when delivery.attempt_count>=5 then delivery.next_attempt_at else statement_timestamp() end,
    terminal_reason=case when delivery.attempt_count>=5 then'retry_exhausted'else null end,
    lease_token=null,leased_by=null,lease_expires_at=null,updated_at=statement_timestamp()
  where delivery.state='sending' and delivery.lease_expires_at<=statement_timestamp();

  update public.organization_manager_push_deliveries delivery
    set state='terminal',terminal_reason='recipient_ineligible',lease_token=null,leased_by=null,lease_expires_at=null,
    updated_at=statement_timestamp()
  from public.organization_manager_notifications notification
  where notification.id=delivery.notification_id and delivery.state in('pending','retry')
    and not exists(select 1 from public.organization_memberships membership
      join public.organizations organization on organization.id=membership.organization_id
      join public.profiles profile on profile.id=membership.user_id
      where membership.user_id=notification.recipient_user_id
        and membership.organization_id=notification.organization_id
        and membership.role='organization_manager' and membership.active
        and organization.active and profile.disabled_at is null and not profile.must_change_password);

  return query
  with candidates as materialized(
    select delivery.id
    from public.organization_manager_push_deliveries delivery
    join public.organization_manager_notifications notification on notification.id=delivery.notification_id
    join public.push_subscriptions subscription on subscription.id=delivery.push_subscription_id
    join public.organization_memberships membership
      on membership.user_id=notification.recipient_user_id
      and membership.organization_id=notification.organization_id
      and membership.role='organization_manager' and membership.active
    join public.organizations organization on organization.id=notification.organization_id and organization.active
    join public.profiles profile on profile.id=notification.recipient_user_id
      and profile.disabled_at is null and not profile.must_change_password
    where delivery.state in('pending','retry') and delivery.next_attempt_at<=statement_timestamp()
      and delivery.attempt_count<5 and subscription.disabled_at is null
    order by delivery.next_attempt_at,delivery.created_at,delivery.id
    for update of delivery,subscription skip locked limit p_limit
  ), claimed as(
    update public.organization_manager_push_deliveries delivery
    set state='sending',attempt_count=delivery.attempt_count+1,
      lease_token=gen_random_uuid(),leased_by=p_worker_id,
      lease_expires_at=statement_timestamp()+pg_catalog.make_interval(secs=>p_lease_seconds),
      updated_at=statement_timestamp()
    from candidates where delivery.id=candidates.id
    returning delivery.*
  )
  select claimed.id,claimed.lease_token,notification.id,subscription.id,
    notification.recipient_user_id,notification.organization_id,notification.event_type,
    notification.source_type,notification.source_id,subscription.endpoint,subscription.p256dh,
    subscription.auth,claimed.attempt_count,claimed.lease_expires_at
  from claimed
  join public.organization_manager_notifications notification on notification.id=claimed.notification_id
  join public.push_subscriptions subscription on subscription.id=claimed.push_subscription_id
  order by claimed.created_at,claimed.id;
end;
$$;

create function public.complete_organization_manager_push_delivery(
  p_delivery_id uuid,p_lease_token uuid,p_result text,p_http_status integer default null
)
returns table(delivery_id uuid,state text,next_attempt_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare delivery public.organization_manager_push_deliveries%rowtype; next_state text; next_time timestamptz;
begin
  if p_delivery_id is null or p_lease_token is null or p_result not in('sent','retry','terminal')
    or (p_http_status is not null and p_http_status not between 100 and 599)
  then raise exception 'invalid manager push completion' using errcode='22023'; end if;
  select * into delivery from public.organization_manager_push_deliveries candidate
    where candidate.id=p_delivery_id for update;
  if delivery.id is null or delivery.state<>'sending' or delivery.lease_token<>p_lease_token
    or delivery.lease_expires_at<=statement_timestamp()
  then raise exception 'manager push lease is not active' using errcode='55000'; end if;

  if p_http_status in(404,410) then
    update public.push_subscriptions subscription set disabled_at=coalesce(subscription.disabled_at,statement_timestamp())
      where subscription.id=delivery.push_subscription_id;
    next_state:='terminal';
  elsif p_result='retry' and delivery.attempt_count>=5 then next_state:='terminal';
  else next_state:=p_result; end if;
  next_time:=case when next_state='retry' then statement_timestamp()+pg_catalog.make_interval(
    secs=>case when (30*pg_catalog.power(2,delivery.attempt_count-1))::integer>3600 then 3600
      else (30*pg_catalog.power(2,delivery.attempt_count-1))::integer end)
    else delivery.next_attempt_at end;

  return query update public.organization_manager_push_deliveries candidate set
    state=next_state,next_attempt_at=next_time,lease_token=null,leased_by=null,lease_expires_at=null,
    last_http_status=p_http_status,
    terminal_reason=case when next_state='terminal' then
      case when p_http_status in(404,410) then'endpoint_expired'
        when delivery.attempt_count>=5 then'retry_exhausted'else'delivery_rejected'end
      else null end,
    sent_at=case when next_state='sent' then statement_timestamp() else null end,
    updated_at=statement_timestamp()
  where candidate.id=delivery.id
  returning candidate.id,candidate.state,candidate.next_attempt_at;
end;
$$;

revoke all on function private.assert_active_organization_manager(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.browser_push_endpoint_is_allowed(text) from public,anon,authenticated,service_role;
revoke all on function private.organization_manager_notification_source_matches(uuid,text,uuid) from public,anon,authenticated,service_role;
revoke all on function private.guard_organization_manager_notification_history() from public,anon,authenticated,service_role;

revoke all on function public.register_organization_manager_push_subscription(uuid,uuid,text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function public.authorize_organization_manager_push_access(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.disable_organization_manager_push_subscription(uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.consume_organization_manager_push_rate_limit(uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.create_organization_manager_notification(uuid,uuid,text,text,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.list_organization_manager_notifications(uuid,uuid,timestamptz,integer) from public,anon,authenticated,service_role;
revoke all on function public.mark_organization_manager_notification_read(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.claim_organization_manager_push_deliveries(uuid,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.complete_organization_manager_push_delivery(uuid,uuid,text,integer) from public,anon,authenticated,service_role;

grant execute on function public.register_organization_manager_push_subscription(uuid,uuid,text,text,text,text) to service_role;
grant execute on function public.authorize_organization_manager_push_access(uuid,uuid) to service_role;
grant execute on function public.disable_organization_manager_push_subscription(uuid,uuid,text) to service_role;
grant execute on function public.consume_organization_manager_push_rate_limit(uuid,uuid,text,text) to service_role;
grant execute on function public.create_organization_manager_notification(uuid,uuid,text,text,uuid,text) to service_role;
grant execute on function public.list_organization_manager_notifications(uuid,uuid,timestamptz,integer) to service_role;
grant execute on function public.mark_organization_manager_notification_read(uuid,uuid,uuid) to service_role;
grant execute on function public.claim_organization_manager_push_deliveries(uuid,integer,integer) to service_role;
grant execute on function public.complete_organization_manager_push_delivery(uuid,uuid,text,integer) to service_role;
