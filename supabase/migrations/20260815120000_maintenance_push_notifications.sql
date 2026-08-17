create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  disabled_at timestamptz null,
  constraint push_subscriptions_endpoint_check check (endpoint = pg_catalog.btrim(endpoint) and pg_catalog.length(endpoint) between 12 and 4096),
  constraint push_subscriptions_p256dh_check check (p256dh = pg_catalog.btrim(p256dh) and pg_catalog.length(p256dh) between 16 and 512),
  constraint push_subscriptions_auth_check check (auth = pg_catalog.btrim(auth) and pg_catalog.length(auth) between 8 and 256),
  constraint push_subscriptions_user_agent_check check (user_agent is null or (user_agent = pg_catalog.btrim(user_agent) and pg_catalog.length(user_agent) between 1 and 512))
);

alter table public.push_subscriptions enable row level security;
revoke all on table public.push_subscriptions from public, anon, authenticated, service_role;

create unique index push_subscriptions_endpoint_key on public.push_subscriptions(endpoint);
create index push_subscriptions_active_user_idx on public.push_subscriptions(user_id) where disabled_at is null;

create trigger push_subscriptions_set_updated_at
before update on public.push_subscriptions
for each row execute function private.set_updated_at();

create or replace function public.register_maintenance_push_subscription(
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
  if not private.actor_has_active_maintenance_membership(actor_user_id, null) then
    raise exception 'maintenance push access denied' using errcode = '42501';
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

  insert into public.push_subscriptions(user_id, endpoint, p256dh, auth, user_agent, last_seen_at, disabled_at)
  values(actor_user_id, clean_endpoint, clean_p256dh, clean_auth, clean_user_agent, now(), null)
  on conflict(endpoint) do update
    set p256dh = excluded.p256dh,
        auth = excluded.auth,
        user_agent = excluded.user_agent,
        last_seen_at = now(),
        disabled_at = null
  returning push_subscriptions.id, push_subscriptions.user_id, push_subscriptions.endpoint, push_subscriptions.disabled_at
  into id, user_id, endpoint, disabled_at;

  return next;
end;
$$;

create or replace function public.disable_maintenance_push_subscription(
  actor_user_id uuid,
  p_endpoint text
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
begin
  if clean_endpoint = '' then
    raise exception 'invalid push subscription' using errcode = '22023';
  end if;

  update public.push_subscriptions subscription
  set disabled_at = coalesce(subscription.disabled_at, now()),
      last_seen_at = now()
  where subscription.user_id = actor_user_id
    and subscription.endpoint = clean_endpoint
  returning subscription.id, subscription.user_id, subscription.endpoint, subscription.disabled_at
  into id, user_id, endpoint, disabled_at;

  if id is not null then
    return next;
  end if;
end;
$$;

create or replace function public.list_maintenance_issue_push_subscriptions(
  target_issue_id uuid
)
returns table(
  subscription_id uuid,
  user_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  organization_id uuid,
  branch_id uuid,
  organization_name text,
  branch_name text,
  issue_title text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target record;
begin
  select issue.id,
         issue.organization_id,
         issue.branch_id,
         issue.title,
         organization.name as organization_name,
         branch.name as branch_name
    into target
  from public.maintenance_issues issue
  join public.organizations organization on organization.id = issue.organization_id and organization.active
  join public.branches branch on branch.id = issue.branch_id
  where issue.id = target_issue_id;

  if target.id is null then
    return;
  end if;

  return query
    select distinct on (subscription.endpoint)
      subscription.id,
      subscription.user_id,
      subscription.endpoint,
      subscription.p256dh,
      subscription.auth,
      target.organization_id,
      target.branch_id,
      target.organization_name,
      target.branch_name,
      target.title
    from public.maintenance_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    join public.push_subscriptions subscription on subscription.user_id = membership.user_id
    where membership.organization_id = target.organization_id
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
      and subscription.disabled_at is null
    order by subscription.endpoint, subscription.updated_at desc;
end;
$$;

create or replace function public.disable_push_subscription_delivery(
  target_subscription_id uuid,
  target_endpoint text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  update public.push_subscriptions subscription
  set disabled_at = coalesce(subscription.disabled_at, now())
  where subscription.id = target_subscription_id
    and subscription.endpoint = pg_catalog.btrim(coalesce(target_endpoint, ''));
  get diagnostics changed_rows = row_count;
  return changed_rows = 1;
end;
$$;

revoke all on function public.register_maintenance_push_subscription(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.disable_maintenance_push_subscription(uuid, text) from public, anon, authenticated;
revoke all on function public.list_maintenance_issue_push_subscriptions(uuid) from public, anon, authenticated;
revoke all on function public.disable_push_subscription_delivery(uuid, text) from public, anon, authenticated;
grant execute on function public.register_maintenance_push_subscription(uuid, text, text, text, text) to service_role;
grant execute on function public.disable_maintenance_push_subscription(uuid, text) to service_role;
grant execute on function public.list_maintenance_issue_push_subscriptions(uuid) to service_role;
grant execute on function public.disable_push_subscription_delivery(uuid, text) to service_role;
