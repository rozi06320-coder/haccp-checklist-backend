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
  v_request public.purchase_requests;
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

  select *
  into v_request
  from public.purchase_requests
  where id = v_scope.request_id
    and branch_id = v_scope.branch_id
    and organization_id = v_scope.organization_id
  for update;

  if not found then
    raise exception 'purchase request not found' using errcode = '42501';
  end if;

  if v_request.status not in ('submitted','processing') then
    raise exception 'purchase request product photo is locked' using errcode = '55000';
  end if;

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
  v_request public.purchase_requests;
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
  into v_request
  from public.purchase_requests
  where id = v_scope.request_id
    and branch_id = v_scope.branch_id
    and organization_id = v_scope.organization_id
  for update;

  if not found then
    raise exception 'purchase request not found' using errcode = '42501';
  end if;

  if v_request.status not in ('submitted','processing') then
    raise exception 'purchase request product photo is locked' using errcode = '55000';
  end if;

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

revoke all on function public.set_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.clear_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.set_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid, jsonb) to service_role;
grant execute on function public.clear_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) to service_role;
