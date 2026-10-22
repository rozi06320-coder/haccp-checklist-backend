-- Hardening: Fail-closed event authorization for Organization Manager Web Push.
-- Non-Maintenance events must never become authorized merely because they are
-- not Maintenance. Default deny for all unsupported or un-gated event types.

create or replace function public.authorize_organization_manager_push_delivery(
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
  producer_allowed boolean := false;
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

  if notification.event_type = 'maintenance_issue_created' then
    producer_allowed := coalesce(private.organization_manager_push_producer_enabled(notification.created_at), false);
  else
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

revoke all on function public.authorize_organization_manager_push_delivery(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.authorize_organization_manager_push_delivery(uuid, uuid) to service_role;
