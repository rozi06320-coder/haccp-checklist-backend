-- Phase 1B: lease-safe Organization Manager push delivery and the first
-- transactional event producer. Delivery remains controlled by a server-only
-- runtime flag; this migration does not schedule or send network requests.

create or replace function private.browser_push_endpoint_is_allowed(p_endpoint text)
returns boolean
language sql
immutable
strict
security definer
set search_path = ''
as $$
  select p_endpoint = pg_catalog.btrim(p_endpoint)
    and pg_catalog.length(p_endpoint) between 12 and 4096
    and p_endpoint ~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*push\.apple\.com|([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*notify\.windows\.com)/[^@#\\[:space:][:cntrl:]]+$';
$$;

-- Fail closed for the root-only provider paths accepted by the original SQL
-- expression. Preserve every row and its ownership/key history.
update public.push_subscriptions subscription
set disabled_at = coalesce(subscription.disabled_at, statement_timestamp())
where subscription.disabled_at is null
  and not private.browser_push_endpoint_is_allowed(subscription.endpoint);

-- The database producer is independently gated from the network worker. Merely
-- applying this migration cannot create manager notification backlog.
create table private.organization_manager_push_producer_config (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  activation_cutoff timestamptz,
  updated_at timestamptz not null default statement_timestamp(),
  check ((not enabled and activation_cutoff is null) or (enabled and activation_cutoff is not null))
);
insert into private.organization_manager_push_producer_config(singleton, enabled) values (true, false);
revoke all on private.organization_manager_push_producer_config from public, anon, authenticated, service_role;

alter table public.organization_manager_push_deliveries
  drop constraint organization_manager_push_deliveries_terminal_check;
alter table public.organization_manager_push_deliveries
  add constraint organization_manager_push_deliveries_terminal_check check(
    (state='terminal' and terminal_reason in(
      'recipient_ineligible','retry_exhausted','endpoint_expired','delivery_rejected',
      'subscription_disabled','producer_disabled'
    )) or (state<>'terminal' and terminal_reason is null)
  );

create function private.organization_manager_push_producer_enabled(p_created_at timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  -- activation_cutoff is applied atomically to existing queue rows by the
  -- configuration function. New rows in a long-running transaction may have
  -- transaction-timestamp created_at values older than that cutoff.
  select config.enabled
  from private.organization_manager_push_producer_config config where config.singleton;
$$;

create function private.configure_organization_manager_push_producer(
  p_enabled boolean,
  p_activation_cutoff timestamptz default null
)
returns table(enabled boolean, activation_cutoff timestamptz, terminalized_count bigint)
language plpgsql security definer set search_path = '' as $$
declare
  cutoff timestamptz;
  affected bigint;
begin
  if p_enabled is null then raise exception 'invalid manager push producer configuration' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('organization-manager-push-producer',0));
  cutoff := case when p_enabled then coalesce(p_activation_cutoff, statement_timestamp()) else null end;
  if cutoff is not null and cutoff > statement_timestamp() then
    raise exception 'invalid manager push producer cutoff' using errcode='22023';
  end if;
  update private.organization_manager_push_producer_config config
    set enabled=p_enabled, activation_cutoff=cutoff, updated_at=statement_timestamp()
    where config.singleton;
  update public.organization_manager_push_deliveries delivery
    set state='terminal',terminal_reason='producer_disabled',lease_token=null,leased_by=null,
      lease_expires_at=null,updated_at=statement_timestamp()
    from public.organization_manager_notifications notification
    where notification.id=delivery.notification_id
      and notification.event_type='maintenance_issue_created'
      and delivery.state in('pending','retry','sending')
      and (not p_enabled or notification.created_at < cutoff);
  get diagnostics affected = row_count;
  return query select p_enabled,cutoff,affected;
end;
$$;

revoke all on function private.organization_manager_push_producer_enabled(timestamptz) from public,anon,authenticated,service_role;
revoke all on function private.configure_organization_manager_push_producer(boolean,timestamptz) from public,anon,authenticated,service_role;

create or replace function public.disable_organization_manager_push_subscription(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_endpoint text
)
returns table(id uuid, user_id uuid, endpoint text, disabled_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_subscription_id uuid;
begin
  perform private.assert_active_organization_manager(p_actor_user_id, p_organization_id);
  if p_endpoint is null
    or p_endpoint <> pg_catalog.btrim(p_endpoint)
    or pg_catalog.length(p_endpoint) not between 12 and 4096 then
    raise exception 'invalid manager push subscription' using errcode = '22023';
  end if;

  select subscription.id
  into target_subscription_id
  from public.push_subscriptions subscription
  where subscription.user_id = p_actor_user_id
    and subscription.endpoint = p_endpoint
  for update;

  update public.organization_manager_push_deliveries delivery
  set state = 'terminal',
      terminal_reason = 'subscription_disabled',
      lease_token = null,
      leased_by = null,
      lease_expires_at = null,
      updated_at = statement_timestamp()
  where delivery.push_subscription_id = target_subscription_id
    and delivery.state in ('pending', 'retry', 'sending');

  return query
  update public.push_subscriptions subscription
  set disabled_at = coalesce(subscription.disabled_at, statement_timestamp()),
      last_seen_at = statement_timestamp()
  where subscription.id = target_subscription_id
  returning subscription.id, subscription.user_id, subscription.endpoint, subscription.disabled_at;
end;
$$;

create or replace function public.claim_organization_manager_push_deliveries(
  p_worker_id uuid,
  p_limit integer default 50,
  p_lease_seconds integer default 60
)
returns table(
  delivery_id uuid,
  lease_token uuid,
  notification_id uuid,
  subscription_id uuid,
  recipient_user_id uuid,
  organization_id uuid,
  event_type text,
  source_type text,
  source_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  attempt_count integer,
  lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_worker_id is null
    or p_limit not between 1 and 100
    or p_lease_seconds not between 30 and 300 then
    raise exception 'invalid manager push claim' using errcode = '22023';
  end if;

  update public.organization_manager_push_deliveries delivery
  set state = case when delivery.attempt_count >= 5 then 'terminal' else 'retry' end,
      next_attempt_at = case when delivery.attempt_count >= 5 then delivery.next_attempt_at else statement_timestamp() end,
      terminal_reason = case when delivery.attempt_count >= 5 then 'retry_exhausted' else null end,
      lease_token = null,
      leased_by = null,
      lease_expires_at = null,
      updated_at = statement_timestamp()
  where delivery.state = 'sending'
    and delivery.lease_expires_at <= statement_timestamp();

  update public.organization_manager_push_deliveries delivery
  set state = 'terminal',
      terminal_reason = 'subscription_disabled',
      lease_token = null,
      leased_by = null,
      lease_expires_at = null,
      updated_at = statement_timestamp()
  where delivery.state in ('pending', 'retry')
    and (
      delivery.push_subscription_id is null
      or not exists (
        select 1
        from public.push_subscriptions subscription
        where subscription.id = delivery.push_subscription_id
          and subscription.disabled_at is null
          and private.browser_push_endpoint_is_allowed(subscription.endpoint)
      )
    );

  update public.organization_manager_push_deliveries delivery
  set state = 'terminal',
      terminal_reason = 'recipient_ineligible',
      lease_token = null,
      leased_by = null,
      lease_expires_at = null,
      updated_at = statement_timestamp()
  from public.organization_manager_notifications notification
  where notification.id = delivery.notification_id
    and delivery.state in ('pending', 'retry')
    and not exists (
      select 1
      from public.organization_memberships membership
      join public.organizations organization on organization.id = membership.organization_id
      join public.profiles profile on profile.id = membership.user_id
      where membership.user_id = notification.recipient_user_id
        and membership.organization_id = notification.organization_id
        and membership.role = 'organization_manager'
        and membership.active
        and organization.active
        and profile.disabled_at is null
        and not profile.must_change_password
    );

  return query
  with candidates as materialized (
    select delivery.id
    from public.organization_manager_push_deliveries delivery
    join public.organization_manager_notifications notification on notification.id = delivery.notification_id
    join public.push_subscriptions subscription on subscription.id = delivery.push_subscription_id
    join public.organization_memberships membership
      on membership.user_id = notification.recipient_user_id
      and membership.organization_id = notification.organization_id
      and membership.role = 'organization_manager'
      and membership.active
    join public.organizations organization
      on organization.id = notification.organization_id
      and organization.active
    join public.profiles profile
      on profile.id = notification.recipient_user_id
      and profile.disabled_at is null
      and not profile.must_change_password
    where delivery.state in ('pending', 'retry')
      and delivery.next_attempt_at <= statement_timestamp()
      and delivery.attempt_count < 5
      and subscription.disabled_at is null
      and private.browser_push_endpoint_is_allowed(subscription.endpoint)
    order by delivery.next_attempt_at, delivery.created_at, delivery.id
    for update of delivery skip locked
    limit p_limit
  ), claimed as (
    update public.organization_manager_push_deliveries delivery
    set state = 'sending',
        attempt_count = delivery.attempt_count + 1,
        lease_token = gen_random_uuid(),
        leased_by = p_worker_id,
        lease_expires_at = statement_timestamp() + pg_catalog.make_interval(secs => p_lease_seconds),
        updated_at = statement_timestamp()
    from candidates
    where delivery.id = candidates.id
    returning delivery.*
  )
  select claimed.id,
    claimed.lease_token,
    notification.id,
    subscription.id,
    notification.recipient_user_id,
    notification.organization_id,
    notification.event_type,
    notification.source_type,
    notification.source_id,
    subscription.endpoint,
    subscription.p256dh,
    subscription.auth,
    claimed.attempt_count,
    claimed.lease_expires_at
  from claimed
  join public.organization_manager_notifications notification on notification.id = claimed.notification_id
  join public.push_subscriptions subscription on subscription.id = claimed.push_subscription_id
  order by claimed.created_at, claimed.id;
end;
$$;

create function public.authorize_organization_manager_push_delivery(
  p_delivery_id uuid,
  p_lease_token uuid
)
returns table(
  authorized boolean,
  delivery_id uuid,
  notification_id uuid,
  event_type text,
  endpoint text,
  p256dh text,
  auth text,
  topic text,
  lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  subscription_id uuid;
  subscription public.push_subscriptions%rowtype;
  delivery public.organization_manager_push_deliveries%rowtype;
  notification public.organization_manager_notifications%rowtype;
  eligible boolean;
  producer_allowed boolean := true;
begin
  if p_delivery_id is null or p_lease_token is null then
    raise exception 'invalid manager push authorization' using errcode = '22023';
  end if;

  select candidate.push_subscription_id
  into subscription_id
  from public.organization_manager_push_deliveries candidate
  where candidate.id = p_delivery_id;

  if subscription_id is not null then
    select candidate.*
    into subscription
    from public.push_subscriptions candidate
    where candidate.id = subscription_id
    for update;
  end if;

  select candidate.*
  into delivery
  from public.organization_manager_push_deliveries candidate
  where candidate.id = p_delivery_id
  for update;

  if delivery.id is not null then
    select source.*
    into notification
    from public.organization_manager_notifications source
    where source.id = delivery.notification_id;
  end if;

  if delivery.id is null
    or delivery.state <> 'sending'
    or delivery.lease_token <> p_lease_token
    or delivery.lease_expires_at <= statement_timestamp() then
    raise exception 'manager push lease is not active' using errcode = '55000';
  end if;

  eligible := exists (
    select 1
    from public.organization_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.user_id = notification.recipient_user_id
      and membership.organization_id = notification.organization_id
      and membership.role = 'organization_manager'
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );

  if notification.event_type = 'maintenance_issue_created'
    and not coalesce(private.organization_manager_push_producer_enabled(notification.created_at), false) then
    producer_allowed := false;
  end if;

  if not producer_allowed
    or not eligible
    or subscription.id is null
    or subscription.id is distinct from delivery.push_subscription_id
    or subscription.user_id <> notification.recipient_user_id
    or subscription.disabled_at is not null
    or not private.browser_push_endpoint_is_allowed(subscription.endpoint) then
    update public.organization_manager_push_deliveries candidate
    set state = 'terminal',
        terminal_reason = case
          when not producer_allowed then 'producer_disabled'
          when not eligible then 'recipient_ineligible'
          else 'subscription_disabled'
        end,
        lease_token = null,
        leased_by = null,
        lease_expires_at = null,
        updated_at = statement_timestamp()
    where candidate.id = delivery.id;

    return query select false, delivery.id, notification.id, notification.event_type,
      null::text, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;

  return query select true,
    delivery.id,
    notification.id,
    notification.event_type,
    subscription.endpoint,
    subscription.p256dh,
    subscription.auth,
    pg_catalog.replace(notification.id::text, '-', ''),
    delivery.lease_expires_at;
end;
$$;

create or replace function public.complete_organization_manager_push_delivery(
  p_delivery_id uuid,
  p_lease_token uuid,
  p_result text,
  p_http_status integer default null
)
returns table(delivery_id uuid, state text, next_attempt_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  subscription_id uuid;
  delivery public.organization_manager_push_deliveries%rowtype;
  next_state text;
  next_time timestamptz;
begin
  if p_delivery_id is null
    or p_lease_token is null
    or p_result not in ('sent', 'retry', 'terminal')
    or (p_http_status is not null and p_http_status not between 100 and 599) then
    raise exception 'invalid manager push completion' using errcode = '22023';
  end if;

  select candidate.push_subscription_id
  into subscription_id
  from public.organization_manager_push_deliveries candidate
  where candidate.id = p_delivery_id;

  if subscription_id is not null then
    perform 1
    from public.push_subscriptions subscription
    where subscription.id = subscription_id
    for update;
  end if;

  select candidate.*
  into delivery
  from public.organization_manager_push_deliveries candidate
  where candidate.id = p_delivery_id
  for update;

  if delivery.id is null
    or delivery.state <> 'sending'
    or delivery.lease_token <> p_lease_token
    or delivery.lease_expires_at <= statement_timestamp() then
    raise exception 'manager push lease is not active' using errcode = '55000';
  end if;

  if p_http_status in (404, 410) then
    update public.push_subscriptions subscription
    set disabled_at = coalesce(subscription.disabled_at, statement_timestamp())
    where subscription.id = delivery.push_subscription_id;

    update public.organization_manager_push_deliveries candidate
    set state = 'terminal',
        terminal_reason = 'subscription_disabled',
        lease_token = null,
        leased_by = null,
        lease_expires_at = null,
        updated_at = statement_timestamp()
    where candidate.push_subscription_id = delivery.push_subscription_id
      and candidate.id <> delivery.id
      and candidate.state in ('pending', 'retry');
    next_state := 'terminal';
  elsif p_result = 'retry' and delivery.attempt_count >= 5 then
    next_state := 'terminal';
  else
    next_state := p_result;
  end if;

  next_time := case
    when next_state = 'retry' then statement_timestamp() + pg_catalog.make_interval(
      secs => case
        when (30 * pg_catalog.power(2, delivery.attempt_count - 1))::integer > 3600 then 3600
        else (30 * pg_catalog.power(2, delivery.attempt_count - 1))::integer
      end
    )
    else delivery.next_attempt_at
  end;

  return query
  update public.organization_manager_push_deliveries candidate
  set state = next_state,
      next_attempt_at = next_time,
      lease_token = null,
      leased_by = null,
      lease_expires_at = null,
      last_http_status = p_http_status,
      terminal_reason = case
        when next_state = 'terminal' then case
          when p_http_status in (404, 410) then 'endpoint_expired'
          when delivery.attempt_count >= 5 then 'retry_exhausted'
          else 'delivery_rejected'
        end
        else null
      end,
      sent_at = case when next_state = 'sent' then statement_timestamp() else null end,
      updated_at = statement_timestamp()
  where candidate.id = delivery.id
  returning candidate.id, candidate.state, candidate.next_attempt_at;
end;
$$;

create function private.enqueue_organization_manager_maintenance_issue()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient record;
begin
  if not coalesce(private.organization_manager_push_producer_enabled(new.created_at), false) then
    return new;
  end if;
  for recipient in
    select distinct membership.user_id
    from public.organization_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.organization_id = new.organization_id
      and membership.role = 'organization_manager'
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  loop
    perform public.create_organization_manager_notification(
      new.organization_id,
      recipient.user_id,
      'maintenance_issue_created',
      'maintenance_issue',
      new.id,
      'maintenance-issue:' || new.id::text
    );
  end loop;
  return new;
end;
$$;

create trigger organization_manager_maintenance_issue_notification
after insert on public.maintenance_issues
for each row
execute function private.enqueue_organization_manager_maintenance_issue();

revoke all on function private.browser_push_endpoint_is_allowed(text) from public, anon, authenticated, service_role;
revoke all on function private.enqueue_organization_manager_maintenance_issue() from public, anon, authenticated, service_role;
revoke all on function public.authorize_organization_manager_push_delivery(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.disable_organization_manager_push_subscription(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.claim_organization_manager_push_deliveries(uuid, integer, integer) from public, anon, authenticated, service_role;
revoke all on function public.complete_organization_manager_push_delivery(uuid, uuid, text, integer) from public, anon, authenticated, service_role;

grant execute on function public.authorize_organization_manager_push_delivery(uuid, uuid) to service_role;
grant execute on function public.disable_organization_manager_push_subscription(uuid, uuid, text) to service_role;
grant execute on function public.claim_organization_manager_push_deliveries(uuid, integer, integer) to service_role;
grant execute on function public.complete_organization_manager_push_delivery(uuid, uuid, text, integer) to service_role;
