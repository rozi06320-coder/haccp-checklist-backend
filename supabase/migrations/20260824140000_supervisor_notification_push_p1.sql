alter table public.notifications
  drop column if exists push_sent_at,
  drop column if exists push_last_attempt_at;

drop index if exists public.notifications_supervisor_push_pending_idx;

create table if not exists public.supervisor_notification_push_deliveries (
  notification_id uuid not null references public.notifications(id) on delete cascade,
  push_subscription_id uuid not null references public.push_subscriptions(id) on delete cascade,
  first_attempted_at timestamptz null,
  last_attempted_at timestamptz null,
  sent_at timestamptz null,
  attempt_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(notification_id, push_subscription_id),
  constraint supervisor_notification_push_deliveries_attempt_count_check check (attempt_count >= 0 and attempt_count <= 1000000),
  constraint supervisor_notification_push_deliveries_attempt_order_check check (
    first_attempted_at is null
    or last_attempted_at is null
    or first_attempted_at <= last_attempted_at
  )
);

alter table public.supervisor_notification_push_deliveries enable row level security;
revoke all on table public.supervisor_notification_push_deliveries from public, anon, authenticated, service_role;

create index if not exists supervisor_notification_push_deliveries_pending_idx
  on public.supervisor_notification_push_deliveries(notification_id, created_at)
  where sent_at is null;
create index if not exists supervisor_notification_push_deliveries_subscription_idx
  on public.supervisor_notification_push_deliveries(push_subscription_id, sent_at);

drop trigger if exists supervisor_notification_push_deliveries_set_updated_at on public.supervisor_notification_push_deliveries;
create trigger supervisor_notification_push_deliveries_set_updated_at
before update on public.supervisor_notification_push_deliveries
for each row execute function private.set_updated_at();

create or replace function private.actor_has_active_supervisor_notification_scope(actor_user_id uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from private.supervisor_notification_branch_scope(actor_user_id)
  );
$$;

create or replace function public.register_supervisor_push_subscription(
  actor_user_id uuid,
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default null
)
returns table(
  id uuid,
  user_id uuid,
  endpoint text,
  disabled_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_endpoint text := pg_catalog.btrim(coalesce(p_endpoint, ''));
  clean_p256dh text := pg_catalog.btrim(coalesce(p_p256dh, ''));
  clean_auth text := pg_catalog.btrim(coalesce(p_auth, ''));
  clean_user_agent text := nullif(pg_catalog.btrim(coalesce(p_user_agent, '')), '');
  existing public.push_subscriptions%rowtype;
begin
  if not private.actor_has_active_supervisor_notification_scope(actor_user_id) then
    raise exception 'supervisor push access denied' using errcode = '42501';
  end if;

  if pg_catalog.length(clean_endpoint) < 12
    or pg_catalog.length(clean_endpoint) > 4096
    or clean_endpoint !~ '^https://'
    or pg_catalog.length(clean_p256dh) < 16
    or pg_catalog.length(clean_p256dh) > 512
    or clean_p256dh !~ '^[A-Za-z0-9_-]+$'
    or pg_catalog.length(clean_auth) < 8
    or pg_catalog.length(clean_auth) > 256
    or clean_auth !~ '^[A-Za-z0-9_-]+$'
    or (clean_user_agent is not null and pg_catalog.length(clean_user_agent) > 512) then
    raise exception 'invalid push subscription' using errcode = '22023';
  end if;

  select subscription.* into existing
  from public.push_subscriptions subscription
  where subscription.endpoint = clean_endpoint
  for update;

  if existing.id is not null and existing.user_id <> actor_user_id then
    raise exception 'push subscription endpoint already exists' using errcode = '23505';
  end if;

  if existing.id is null then
    insert into public.push_subscriptions(user_id, endpoint, p256dh, auth, user_agent, last_seen_at, disabled_at)
    values(actor_user_id, clean_endpoint, clean_p256dh, clean_auth, clean_user_agent, now(), null)
    returning push_subscriptions.id, push_subscriptions.user_id, push_subscriptions.endpoint, push_subscriptions.disabled_at
    into id, user_id, endpoint, disabled_at;
  else
    update public.push_subscriptions subscription
    set p256dh = clean_p256dh,
        auth = clean_auth,
        user_agent = clean_user_agent,
        last_seen_at = now(),
        disabled_at = null
    where subscription.id = existing.id
    returning subscription.id, subscription.user_id, subscription.endpoint, subscription.disabled_at
    into id, user_id, endpoint, disabled_at;
  end if;

  return next;
end;
$$;

create or replace function private.supervisor_notification_all_branch_scope()
returns table(
  organization_id uuid,
  branch_id uuid,
  branch_name text,
  branch_code text,
  branch_timezone text
)
language sql stable security definer set search_path = '' as $$
  select distinct branch.organization_id,
    branch.id,
    branch.name,
    branch.code,
    branch.timezone
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id and organization.active
  where branch.active
    and exists (
      select 1
      from private.supervisor_notification_recipients(branch.id) recipient
      where recipient.organization_id = branch.organization_id
    );
$$;

create or replace function public.list_supervisor_notification_push_deliveries(
  as_of timestamptz default pg_catalog.statement_timestamp()
)
returns table(
  notification_id uuid,
  subscription_id uuid,
  recipient_user_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  organization_id uuid,
  branch_id uuid,
  business_date date,
  notification_type text,
  checklist_type text,
  rule_key text,
  severity text,
  payload jsonb,
  created_at timestamptz
)
language plpgsql security definer set search_path = '' as $$
declare
  branch_scope record;
begin
  for branch_scope in
    select * from private.supervisor_notification_all_branch_scope()
  loop
    perform private.evaluate_supervisor_notification_branch(branch_scope, as_of);
  end loop;

  insert into public.supervisor_notification_push_deliveries(notification_id, push_subscription_id)
  select notification.id, subscription.id
  from public.notifications notification
  join public.push_subscriptions subscription
    on subscription.user_id = notification.recipient_user_id
   and subscription.disabled_at is null
  where notification.resolved_at is null
  on conflict on constraint supervisor_notification_push_deliveries_pkey do nothing;

  return query
    select notification.id,
      subscription.id,
      notification.recipient_user_id,
      subscription.endpoint,
      subscription.p256dh,
      subscription.auth,
      notification.organization_id,
      notification.branch_id,
      notification.business_date,
      notification.notification_type,
      rule.checklist_type,
      rule.rule_key,
      notification.severity,
      notification.payload,
      notification.created_at
    from public.notifications notification
    join public.notification_rules rule on rule.id = notification.rule_id
    join public.supervisor_notification_push_deliveries delivery
      on delivery.notification_id = notification.id
    join public.push_subscriptions subscription
      on subscription.id = delivery.push_subscription_id
     and subscription.user_id = notification.recipient_user_id
     and subscription.disabled_at is null
    where notification.resolved_at is null
      and delivery.sent_at is null
    order by notification.created_at, notification.id, subscription.updated_at desc
    limit 500;
end;
$$;

create or replace function public.mark_supervisor_notification_push_attempted(
  target_notification_id uuid,
  target_subscription_id uuid,
  target_endpoint text
)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  changed_rows integer;
begin
  update public.supervisor_notification_push_deliveries delivery
  set first_attempted_at = coalesce(delivery.first_attempted_at, now()),
      last_attempted_at = now(),
      attempt_count = least(delivery.attempt_count + 1, 1000000)
  from public.notifications notification
  join public.push_subscriptions subscription
    on subscription.id = target_subscription_id
   and subscription.endpoint = pg_catalog.btrim(coalesce(target_endpoint, ''))
   and subscription.user_id = notification.recipient_user_id
  where delivery.notification_id = target_notification_id
    and delivery.push_subscription_id = target_subscription_id
    and notification.id = delivery.notification_id
    and notification.resolved_at is null
    and subscription.disabled_at is null
    and delivery.sent_at is null;
  get diagnostics changed_rows = row_count;
  return changed_rows = 1;
end;
$$;

create or replace function public.mark_supervisor_notification_push_sent(
  target_notification_id uuid,
  target_subscription_id uuid,
  target_endpoint text
)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  changed_rows integer;
begin
  update public.supervisor_notification_push_deliveries delivery
  set first_attempted_at = coalesce(delivery.first_attempted_at, now()),
      last_attempted_at = now(),
      sent_at = coalesce(delivery.sent_at, now()),
      attempt_count = case
        when delivery.attempt_count < 1 then 1
        else delivery.attempt_count
      end
  from public.notifications notification
  join public.push_subscriptions subscription
    on subscription.id = target_subscription_id
   and subscription.endpoint = pg_catalog.btrim(coalesce(target_endpoint, ''))
   and subscription.user_id = notification.recipient_user_id
  where delivery.notification_id = target_notification_id
    and delivery.push_subscription_id = target_subscription_id
    and notification.id = delivery.notification_id;
  get diagnostics changed_rows = row_count;
  return changed_rows = 1;
end;
$$;

revoke all on function private.actor_has_active_supervisor_notification_scope(uuid) from public, anon, authenticated;
revoke all on function private.supervisor_notification_all_branch_scope() from public, anon, authenticated;
revoke all on function public.register_supervisor_push_subscription(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.list_supervisor_notification_push_deliveries(timestamptz) from public, anon, authenticated;
revoke all on function public.mark_supervisor_notification_push_attempted(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.mark_supervisor_notification_push_sent(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.register_supervisor_push_subscription(uuid, text, text, text, text) to service_role;
grant execute on function public.list_supervisor_notification_push_deliveries(timestamptz) to service_role;
grant execute on function public.mark_supervisor_notification_push_attempted(uuid, uuid, text) to service_role;
grant execute on function public.mark_supervisor_notification_push_sent(uuid, uuid, text) to service_role;
