create table public.purchase_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete restrict,
  requested_by uuid not null references auth.users(id) on delete restrict,
  category text not null check (category in ('stationary','kitchen','other')),
  status text not null default 'submitted' check (status in ('submitted','processing','purchased','received','cancelled')),
  notes text check (notes is null or pg_catalog.length(notes) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.purchase_request_items (
  id uuid primary key default gen_random_uuid(),
  purchase_request_id uuid not null references public.purchase_requests(id) on delete cascade,
  item_name text not null check (pg_catalog.length(pg_catalog.btrim(item_name)) between 1 and 160),
  quantity numeric not null check (quantity > 0),
  unit text check (unit is null or pg_catalog.length(pg_catalog.btrim(unit)) between 1 and 40),
  notes text check (notes is null or pg_catalog.length(notes) <= 1000),
  sort_order integer not null check (sort_order > 0),
  created_at timestamptz not null default now()
);

create index purchase_requests_org_status_created_idx
  on public.purchase_requests (organization_id, status, created_at desc);

create index purchase_requests_branch_created_idx
  on public.purchase_requests (branch_id, created_at desc);

create index purchase_request_items_request_order_idx
  on public.purchase_request_items (purchase_request_id, sort_order);

alter table public.purchase_requests enable row level security;
alter table public.purchase_request_items enable row level security;

revoke all on public.purchase_requests from public, anon, authenticated;
revoke all on public.purchase_request_items from public, anon, authenticated;

create or replace function private.purchase_request_actor_branch_scope(
  actor_user_id uuid,
  target_branch_id uuid
)
returns table(organization_id uuid, branch_id uuid)
language sql
stable
security definer
set search_path = ''
as $function$
  select branch.organization_id, branch.id
  from public.branch_memberships membership
  join public.branches branch
    on branch.id = membership.branch_id
  join public.organizations organization
    on organization.id = branch.organization_id
  join public.profiles profile
    on profile.id = membership.user_id
  where membership.user_id = actor_user_id
    and membership.branch_id = target_branch_id
    and membership.role = 'branch_manager'
    and membership.active
    and branch.active
    and organization.active
    and profile.disabled_at is null
    and not profile.must_change_password;
$function$;

create or replace function private.purchase_request_json(row_data public.purchase_requests)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select jsonb_build_object(
    'id', row_data.id,
    'organization_id', row_data.organization_id,
    'branch_id', row_data.branch_id,
    'branch_name', branch.name,
    'branch_code', branch.code,
    'requested_by', row_data.requested_by,
    'requested_by_name', requester.full_name,
    'category', row_data.category,
    'status', row_data.status,
    'notes', row_data.notes,
    'created_at', row_data.created_at,
    'updated_at', row_data.updated_at,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', item.id,
        'purchase_request_id', item.purchase_request_id,
        'item_name', item.item_name,
        'quantity', item.quantity,
        'unit', item.unit,
        'notes', item.notes,
        'sort_order', item.sort_order,
        'created_at', item.created_at
      ) order by item.sort_order, item.id)
      from public.purchase_request_items item
      where item.purchase_request_id = row_data.id
    ), '[]'::jsonb)
  )
  from public.branches branch
  left join public.profiles requester
    on requester.id = row_data.requested_by
  where branch.id = row_data.branch_id;
$function$;

create or replace function public.create_supervisor_purchase_request(
  actor_user_id uuid,
  target_branch_id uuid,
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
  v_request public.purchase_requests;
  v_item jsonb;
  v_index integer := 0;
  v_name text;
  v_quantity numeric;
  v_unit text;
  v_notes text;
begin
  select * into v_scope
  from private.purchase_request_actor_branch_scope(actor_user_id, target_branch_id);

  if v_scope.branch_id is null then
    raise exception 'purchase request branch access denied' using errcode = '42501';
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

  for v_item in select value from jsonb_array_elements(request_items)
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

  return jsonb_build_object('purchase_request', private.purchase_request_json(v_request));
end
$function$;

create or replace function public.list_supervisor_purchase_requests(
  actor_user_id uuid,
  target_branch_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_scope record;
begin
  select * into v_scope
  from private.purchase_request_actor_branch_scope(actor_user_id, target_branch_id);

  if v_scope.branch_id is null then
    raise exception 'purchase request branch access denied' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'purchase_requests',
    coalesce((
      select jsonb_agg(private.purchase_request_json(request) order by request.created_at desc, request.id desc)
      from (
        select *
        from public.purchase_requests
        where branch_id = target_branch_id
        order by created_at desc, id desc
        limit 100
      ) request
    ), '[]'::jsonb)
  );
end
$function$;

create or replace function public.list_purchasing_purchase_requests(
  actor_user_id uuid,
  target_organization_id uuid,
  status_filter text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if not private.has_active_purchasing_membership(actor_user_id, target_organization_id) then
    raise exception 'purchasing access denied' using errcode = '42501';
  end if;

  if status_filter is not null and status_filter not in ('submitted','processing','purchased') then
    raise exception 'invalid purchase request status filter' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'purchase_requests',
    coalesce((
      select jsonb_agg(private.purchase_request_json(request) order by request.created_at desc, request.id desc)
      from (
        select *
        from public.purchase_requests
        where organization_id = target_organization_id
          and (status_filter is null or status = status_filter)
        order by created_at desc, id desc
        limit 500
      ) request
    ), '[]'::jsonb)
  );
end
$function$;

create or replace function public.set_purchasing_purchase_request_status(
  actor_user_id uuid,
  target_organization_id uuid,
  target_request_id uuid,
  next_status text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_request public.purchase_requests;
begin
  if not private.has_active_purchasing_membership(actor_user_id, target_organization_id) then
    raise exception 'purchasing access denied' using errcode = '42501';
  end if;

  select *
  into v_request
  from public.purchase_requests
  where id = target_request_id
    and organization_id = target_organization_id
  for update;

  if v_request.id is null then
    raise exception 'purchase request not found' using errcode = '42501';
  end if;

  if not (
    (v_request.status = 'submitted' and next_status = 'processing')
    or (v_request.status = 'processing' and next_status = 'purchased')
  ) then
    raise exception 'invalid purchase request status transition' using errcode = '22023';
  end if;

  update public.purchase_requests
  set status = next_status,
      updated_at = now()
  where id = v_request.id
  returning * into v_request;

  return jsonb_build_object('purchase_request', private.purchase_request_json(v_request));
end
$function$;

revoke all on function private.purchase_request_actor_branch_scope(uuid, uuid) from public, anon, authenticated;
revoke all on function private.purchase_request_json(public.purchase_requests) from public, anon, authenticated;
revoke all on function public.create_supervisor_purchase_request(uuid, uuid, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.list_supervisor_purchase_requests(uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_purchasing_purchase_requests(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) from public, anon, authenticated;

grant execute on function public.create_supervisor_purchase_request(uuid, uuid, text, text, jsonb) to service_role;
grant execute on function public.list_supervisor_purchase_requests(uuid, uuid) to service_role;
grant execute on function public.list_purchasing_purchase_requests(uuid, uuid, text) to service_role;
grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) to service_role;
