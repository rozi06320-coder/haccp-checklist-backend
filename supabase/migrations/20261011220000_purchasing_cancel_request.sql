begin;

alter table public.purchase_requests
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete restrict;

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
    'cancelled_at', row_data.cancelled_at,
    'cancelled_by', row_data.cancelled_by,
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

create or replace function public.cancel_purchasing_purchase_request(
  actor_user_id uuid,
  target_organization_id uuid,
  target_request_id uuid
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

  select request.*
  into v_request
  from public.purchase_requests request
  where request.id = target_request_id
    and request.organization_id = target_organization_id
  for update;

  if v_request.id is null then
    raise exception 'purchase request not found' using errcode = '42501';
  end if;

  if v_request.status = 'cancelled' then
    return jsonb_build_object('purchase_request', private.purchase_request_json(v_request));
  end if;

  if v_request.status not in ('submitted', 'processing') then
    raise exception 'purchase request cannot be cancelled' using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.branch_purchase_logs purchase_log
    where purchase_log.source_purchase_request_id = v_request.id
       or exists (
         select 1
         from public.purchase_request_items item
         where item.purchase_request_id = v_request.id
           and item.id = purchase_log.source_purchase_request_item_id
       )
  ) then
    raise exception 'purchase request has accounting history' using errcode = '55000';
  end if;

  update public.purchase_requests request
  set status = 'cancelled',
      cancelled_at = statement_timestamp(),
      cancelled_by = actor_user_id,
      updated_at = statement_timestamp()
  where request.id = v_request.id
  returning request.* into v_request;

  return jsonb_build_object('purchase_request', private.purchase_request_json(v_request));
end
$function$;

revoke all on function private.purchase_request_json(public.purchase_requests) from public, anon, authenticated;
revoke all on function public.cancel_purchasing_purchase_request(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.cancel_purchasing_purchase_request(uuid, uuid, uuid) to service_role;

commit;
