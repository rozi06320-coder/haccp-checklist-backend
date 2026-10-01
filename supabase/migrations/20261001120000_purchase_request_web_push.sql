create table public.purchase_request_creation_idempotency (
  actor_user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key uuid not null,
  request_hash text not null,
  purchase_request_id uuid not null references public.purchase_requests(id) on delete cascade,
  response_json jsonb not null,
  created_at timestamptz not null default now(),
  primary key (actor_user_id, idempotency_key),
  constraint purchase_request_creation_idempotency_hash_check
    check (request_hash ~ '^[0-9a-f]{64}$')
);

create index purchase_request_creation_idempotency_request_idx
  on public.purchase_request_creation_idempotency(purchase_request_id);

alter table public.purchase_request_creation_idempotency enable row level security;
revoke all on table public.purchase_request_creation_idempotency from public, anon, authenticated, service_role;

create function public.create_supervisor_purchase_request(
  actor_user_id uuid,
  target_branch_id uuid,
  idempotency_key uuid,
  request_hash text,
  request_category text,
  request_notes text,
  request_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_scope record;
  v_existing public.purchase_request_creation_idempotency%rowtype;
  v_request public.purchase_requests%rowtype;
  v_item jsonb;
  v_index integer := 0;
  v_name text;
  v_quantity numeric;
  v_unit text;
  v_notes text;
  v_response jsonb;
begin
  select * into v_scope
  from private.purchase_request_actor_branch_scope(actor_user_id, target_branch_id);

  if v_scope.branch_id is null then
    raise exception 'purchase request branch access denied' using errcode = '42501';
  end if;

  if idempotency_key is null
    or request_hash is null
    or request_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid purchase request idempotency' using errcode = '22023';
  end if;

  if request_category not in ('stationary','kitchen','other') then
    raise exception 'invalid purchase request category' using errcode = '22023';
  end if;

  if request_items is null
    or jsonb_typeof(request_items) <> 'array'
    or jsonb_array_length(request_items) = 0
    or jsonb_array_length(request_items) > 50 then
    raise exception 'purchase request requires items' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(actor_user_id::text || ':' || idempotency_key::text || ':purchase_request', 0)
  );

  select * into v_existing
  from public.purchase_request_creation_idempotency existing
  where existing.actor_user_id = create_supervisor_purchase_request.actor_user_id
    and existing.idempotency_key = create_supervisor_purchase_request.idempotency_key;

  if v_existing.actor_user_id is not null then
    if v_existing.request_hash <> request_hash then
      raise exception 'purchase request idempotency conflict' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'created', false,
      'purchase_request', v_existing.response_json->'purchase_request'
    );
  end if;

  insert into public.purchase_requests (
    organization_id,
    branch_id,
    requested_by,
    category,
    notes
  ) values (
    v_scope.organization_id,
    v_scope.branch_id,
    actor_user_id,
    request_category,
    nullif(pg_catalog.btrim(coalesce(request_notes, '')), '')
  )
  returning * into v_request;

  for v_item in select value from pg_catalog.jsonb_array_elements(request_items)
  loop
    v_index := v_index + 1;
    v_name := nullif(pg_catalog.btrim(coalesce(v_item->>'name', '')), '');
    v_quantity := nullif(pg_catalog.btrim(coalesce(v_item->>'quantity', '')), '')::numeric;
    v_unit := nullif(pg_catalog.btrim(coalesce(v_item->>'unit', '')), '');
    v_notes := nullif(pg_catalog.btrim(coalesce(v_item->>'notes', '')), '');

    if v_name is null or pg_catalog.length(v_name) > 160 or v_quantity <= 0 then
      raise exception 'invalid purchase request item' using errcode = '22023';
    end if;

    insert into public.purchase_request_items (
      purchase_request_id,
      item_name,
      quantity,
      unit,
      notes,
      sort_order
    ) values (
      v_request.id,
      v_name,
      v_quantity,
      v_unit,
      v_notes,
      v_index
    );
  end loop;

  v_response := jsonb_build_object('purchase_request', private.purchase_request_json(v_request));

  insert into public.purchase_request_creation_idempotency(
    actor_user_id,
    idempotency_key,
    request_hash,
    purchase_request_id,
    response_json
  ) values (
    actor_user_id,
    idempotency_key,
    request_hash,
    v_request.id,
    v_response
  );

  return jsonb_build_object(
    'created', true,
    'purchase_request', v_response->'purchase_request'
  );
end
$function$;

create function public.register_purchasing_push_subscription(
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
as $function$
declare
  clean_endpoint text := pg_catalog.btrim(coalesce(p_endpoint, ''));
  clean_p256dh text := pg_catalog.btrim(coalesce(p_p256dh, ''));
  clean_auth text := pg_catalog.btrim(coalesce(p_auth, ''));
  clean_user_agent text := nullif(pg_catalog.btrim(coalesce(p_user_agent, '')), '');
  existing public.push_subscriptions%rowtype;
begin
  if not exists (
    select 1
    from public.purchasing_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.user_id = actor_user_id
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  ) then
    raise exception 'purchasing push access denied' using errcode = '42501';
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
end
$function$;

create function public.list_purchase_request_push_subscriptions(
  target_request_id uuid
)
returns table(
  subscription_id uuid,
  user_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  organization_id uuid,
  branch_id uuid,
  branch_name text,
  category text,
  request_created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  target record;
begin
  select request.id,
         request.organization_id,
         request.branch_id,
         branch.name as branch_name,
         request.category,
         request.created_at
  into target
  from public.purchase_requests request
  join public.organizations organization
    on organization.id = request.organization_id
   and organization.active
  join public.branches branch on branch.id = request.branch_id
  where request.id = target_request_id;

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
      target.branch_name,
      target.category,
      target.created_at
    from public.purchasing_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    join public.push_subscriptions subscription on subscription.user_id = membership.user_id
    where membership.organization_id = target.organization_id
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
      and subscription.disabled_at is null
    order by subscription.endpoint, subscription.updated_at desc;
end
$function$;

revoke all on function public.create_supervisor_purchase_request(uuid, uuid, uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.register_purchasing_push_subscription(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.list_purchase_request_push_subscriptions(uuid) from public, anon, authenticated;

grant execute on function public.create_supervisor_purchase_request(uuid, uuid, uuid, text, text, text, jsonb) to service_role;
grant execute on function public.register_purchasing_push_subscription(uuid, text, text, text, text) to service_role;
grant execute on function public.list_purchase_request_push_subscriptions(uuid) to service_role;
