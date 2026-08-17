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

revoke all on function public.register_maintenance_push_subscription(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.register_maintenance_push_subscription(uuid, text, text, text, text) to service_role;
