insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'purchase-request-product-photos',
  'purchase-request-product-photos',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

alter table public.purchase_request_items
  add column if not exists product_photo_storage_path text,
  add column if not exists product_photo_original_name text,
  add column if not exists product_photo_mime_type text,
  add column if not exists product_photo_size_bytes bigint,
  add column if not exists product_photo_uploaded_at timestamptz,
  add column if not exists product_photo_uploaded_by uuid references public.profiles(id) on delete restrict;

alter table public.purchase_request_items
  drop constraint if exists purchase_request_items_product_photo_mime_check,
  drop constraint if exists purchase_request_items_product_photo_size_check,
  drop constraint if exists purchase_request_items_product_photo_name_check,
  drop constraint if exists purchase_request_items_product_photo_path_check,
  drop constraint if exists purchase_request_items_product_photo_complete_check,
  add constraint purchase_request_items_product_photo_mime_check
    check (product_photo_mime_type is null or product_photo_mime_type in ('image/jpeg','image/png','image/webp')),
  add constraint purchase_request_items_product_photo_size_check
    check (product_photo_size_bytes is null or (product_photo_size_bytes > 0 and product_photo_size_bytes <= 5242880)),
  add constraint purchase_request_items_product_photo_name_check
    check (product_photo_original_name is null or char_length(product_photo_original_name) between 1 and 180),
  add constraint purchase_request_items_product_photo_path_check
    check (product_photo_storage_path is null or char_length(product_photo_storage_path) between 1 and 500),
  add constraint purchase_request_items_product_photo_complete_check
    check (
      (
        product_photo_storage_path is null
        and product_photo_original_name is null
        and product_photo_mime_type is null
        and product_photo_size_bytes is null
        and product_photo_uploaded_at is null
        and product_photo_uploaded_by is null
      )
      or (
        product_photo_storage_path is not null
        and product_photo_original_name is not null
        and product_photo_mime_type is not null
        and product_photo_size_bytes is not null
        and product_photo_uploaded_at is not null
        and product_photo_uploaded_by is not null
      )
    );

create or replace function private.purchase_request_item_product_photo_json(item_row public.purchase_request_items)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select case
    when item_row.product_photo_storage_path is null then null
    else jsonb_build_object(
      'storage_path', item_row.product_photo_storage_path,
      'original_filename', item_row.product_photo_original_name,
      'mime_type', item_row.product_photo_mime_type,
      'size_bytes', item_row.product_photo_size_bytes,
      'uploaded_at', item_row.product_photo_uploaded_at
    )
  end;
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
        'created_at', item.created_at,
        'vendor_name', item.vendor_name,
        'invoice_number', item.invoice_number,
        'purchased_quantity', item.purchased_quantity,
        'purchased_unit', item.purchased_unit,
        'actual_unit_cost', item.actual_unit_cost,
        'actual_total_cost', coalesce(item.total_amount, item.actual_total_cost),
        'before_tax_amount', item.before_tax_amount,
        'tax_amount', item.tax_amount,
        'total_amount', coalesce(item.total_amount, item.actual_total_cost),
        'purchasing_notes', item.purchasing_notes,
        'purchase_log_id', log.id,
        'purchase_log_payment_status', log.payment_status,
        'product_photo', private.purchase_request_item_product_photo_json(item),
        'attachments', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', attachment.id,
            'storage_path', attachment.storage_path,
            'original_filename', attachment.original_filename,
            'mime_type', attachment.mime_type,
            'size_bytes', attachment.size_bytes,
            'position', attachment.position
          ) order by attachment.position, attachment.id)
          from public.purchase_request_item_attachments attachment
          where attachment.purchase_request_item_id = item.id
        ), '[]'::jsonb)
      ) order by item.sort_order, item.id)
      from public.purchase_request_items item
      left join public.branch_purchase_logs log
        on log.source_type = 'central_purchasing'
       and log.source_purchase_request_item_id = item.id
       and log.deleted_at is null
      where item.purchase_request_id = row_data.id
    ), '[]'::jsonb)
  )
  from public.branches branch
  left join public.profiles requester
    on requester.id = row_data.requested_by
  where branch.id = row_data.branch_id;
$function$;

create or replace function public.authorize_supervisor_purchase_request_item_product_photo(
  actor_user_id uuid,
  target_branch_id uuid,
  target_request_id uuid,
  target_item_id uuid
)
returns table(organization_id uuid, branch_id uuid, request_id uuid, item_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_scope record;
  v_request public.purchase_requests;
begin
  select *
  into v_scope
  from private.purchase_request_actor_branch_scope(actor_user_id, target_branch_id);

  select *
  into v_request
  from public.purchase_requests
  where id = target_request_id
    and branch_id = target_branch_id
    and organization_id = v_scope.organization_id;

  if not found then
    raise exception 'purchase request not found' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.purchase_request_items item
    where item.id = target_item_id
      and item.purchase_request_id = target_request_id
  ) then
    raise exception 'purchase request item not found' using errcode = '42501';
  end if;

  return query select v_request.organization_id, v_request.branch_id, v_request.id, target_item_id;
end;
$function$;

create or replace function public.set_supervisor_purchase_request_item_product_photo(
  actor_user_id uuid,
  target_branch_id uuid,
  target_request_id uuid,
  target_item_id uuid,
  photo_metadata jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_scope record;
  v_item public.purchase_request_items;
  v_old_storage_path text;
  v_storage_path text := nullif(btrim(photo_metadata->>'storage_path'), '');
  v_original_name text := nullif(btrim(photo_metadata->>'original_filename'), '');
  v_mime_type text := nullif(btrim(photo_metadata->>'mime_type'), '');
  v_size_bytes bigint;
begin
  select *
  into v_scope
  from public.authorize_supervisor_purchase_request_item_product_photo(
    actor_user_id,
    target_branch_id,
    target_request_id,
    target_item_id
  );

  if v_storage_path is null or v_original_name is null or v_mime_type is null then
    raise exception 'invalid product photo metadata' using errcode = '22023';
  end if;

  if v_mime_type not in ('image/jpeg','image/png','image/webp') then
    raise exception 'invalid product photo mime type' using errcode = '22023';
  end if;

  begin
    v_size_bytes := (photo_metadata->>'size_bytes')::bigint;
  exception when others then
    raise exception 'invalid product photo size' using errcode = '22023';
  end;

  if v_size_bytes <= 0 or v_size_bytes > 5242880 then
    raise exception 'invalid product photo size' using errcode = '22023';
  end if;

  if char_length(v_storage_path) > 500 or char_length(v_original_name) > 180 then
    raise exception 'invalid product photo metadata' using errcode = '22023';
  end if;

  select *
  into v_item
  from public.purchase_request_items
  where id = v_scope.item_id
    and purchase_request_id = v_scope.request_id
  for update;

  v_old_storage_path := v_item.product_photo_storage_path;

  update public.purchase_request_items
  set product_photo_storage_path = v_storage_path,
      product_photo_original_name = v_original_name,
      product_photo_mime_type = v_mime_type,
      product_photo_size_bytes = v_size_bytes,
      product_photo_uploaded_at = now(),
      product_photo_uploaded_by = actor_user_id
  where id = v_item.id
  returning * into v_item;

  return jsonb_build_object(
    'product_photo', private.purchase_request_item_product_photo_json(v_item),
    'old_storage_path', v_old_storage_path
  );
end;
$function$;

create or replace function public.clear_supervisor_purchase_request_item_product_photo(
  actor_user_id uuid,
  target_branch_id uuid,
  target_request_id uuid,
  target_item_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_scope record;
  v_item public.purchase_request_items;
  v_old_storage_path text;
begin
  select *
  into v_scope
  from public.authorize_supervisor_purchase_request_item_product_photo(
    actor_user_id,
    target_branch_id,
    target_request_id,
    target_item_id
  );

  select *
  into v_item
  from public.purchase_request_items
  where id = v_scope.item_id
    and purchase_request_id = v_scope.request_id
  for update;

  v_old_storage_path := v_item.product_photo_storage_path;

  update public.purchase_request_items
  set product_photo_storage_path = null,
      product_photo_original_name = null,
      product_photo_mime_type = null,
      product_photo_size_bytes = null,
      product_photo_uploaded_at = null,
      product_photo_uploaded_by = null
  where id = v_item.id
  returning * into v_item;

  return jsonb_build_object(
    'product_photo', private.purchase_request_item_product_photo_json(v_item),
    'old_storage_path', v_old_storage_path
  );
end;
$function$;

revoke all on function private.purchase_request_item_product_photo_json(public.purchase_request_items) from public, anon, authenticated;
revoke all on function private.purchase_request_json(public.purchase_requests) from public, anon, authenticated;
revoke all on function public.authorize_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.set_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.clear_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.authorize_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) to service_role;
grant execute on function public.set_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid, jsonb) to service_role;
grant execute on function public.clear_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) to service_role;
