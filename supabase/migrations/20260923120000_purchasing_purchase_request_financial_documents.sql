begin;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'purchase-request-attachments',
  'purchase-request-attachments',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp','application/pdf']
)
on conflict (id) do update
set public = false,
  file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf'];

alter table public.purchase_request_items
  add column if not exists invoice_number text,
  add column if not exists before_tax_amount numeric(12,2),
  add column if not exists tax_amount numeric(12,2),
  add column if not exists total_amount numeric(12,2);

update public.purchase_request_items
set total_amount = actual_total_cost
where total_amount is null
  and actual_total_cost is not null;

alter table public.purchase_request_items
  drop constraint if exists purchase_request_items_actual_cost_breakdown_check,
  add constraint purchase_request_items_invoice_number_check
    check (invoice_number is null or (invoice_number = pg_catalog.btrim(invoice_number) and pg_catalog.length(invoice_number) between 1 and 120)),
  add constraint purchase_request_items_before_tax_amount_check
    check (before_tax_amount is null or before_tax_amount >= 0),
  add constraint purchase_request_items_tax_amount_check
    check (tax_amount is null or tax_amount >= 0),
  add constraint purchase_request_items_total_amount_check
    check (total_amount is null or total_amount >= 0),
  add constraint purchase_request_items_tax_breakdown_check
    check (
      (before_tax_amount is null and tax_amount is null)
      or (
        before_tax_amount is not null
        and tax_amount is not null
        and total_amount is not null
        and total_amount = before_tax_amount + tax_amount
      )
    ),
  add constraint purchase_request_items_unit_cost_breakdown_check
    check (
      purchased_quantity is null
      or actual_unit_cost is null
      or (
        before_tax_amount is not null
        and before_tax_amount = pg_catalog.round(purchased_quantity * actual_unit_cost, 2)
      )
    ),
  add constraint purchase_request_items_total_alias_check
    check (actual_total_cost is null or total_amount is null or actual_total_cost = total_amount);

create table if not exists public.purchase_request_item_attachments (
  id uuid primary key default gen_random_uuid(),
  purchase_request_item_id uuid not null references public.purchase_request_items(id) on delete cascade,
  storage_path text not null check (pg_catalog.length(pg_catalog.btrim(storage_path)) between 1 and 260),
  original_filename text check (original_filename is null or pg_catalog.length(original_filename) <= 180),
  mime_type text check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  size_bytes bigint check (size_bytes is null or size_bytes > 0),
  position integer not null default 1 check (position between 1 and 3),
  created_at timestamptz not null default now(),
  unique (purchase_request_item_id, position)
);

create index if not exists purchase_request_item_attachments_item_idx
  on public.purchase_request_item_attachments (purchase_request_item_id, position);

alter table public.purchase_request_item_attachments enable row level security;
revoke all on public.purchase_request_item_attachments from public, anon, authenticated;

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
        'actual_unit_cost', item.actual_unit_cost,
        'actual_total_cost', coalesce(item.total_amount, item.actual_total_cost),
        'before_tax_amount', item.before_tax_amount,
        'tax_amount', item.tax_amount,
        'total_amount', coalesce(item.total_amount, item.actual_total_cost),
        'purchasing_notes', item.purchasing_notes,
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
      where item.purchase_request_id = row_data.id
    ), '[]'::jsonb)
  )
  from public.branches branch
  left join public.profiles requester
    on requester.id = row_data.requested_by
  where branch.id = row_data.branch_id;
$function$;

create or replace function private.apply_purchasing_purchase_request_details(
  request_row public.purchase_requests,
  purchase_details jsonb,
  require_complete boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_detail jsonb;
  v_attachment jsonb;
  v_item_id uuid;
  v_vendor text;
  v_invoice_number text;
  v_purchased_quantity numeric;
  v_actual_unit_cost numeric;
  v_actual_total_cost numeric;
  v_before_tax_amount numeric;
  v_tax_amount numeric;
  v_total_amount numeric;
  v_notes text;
  v_attachment_position integer;
  money_pattern constant text := '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$';
begin
  if purchase_details is null
    or jsonb_typeof(purchase_details) <> 'array'
    or jsonb_array_length(purchase_details) = 0
    or jsonb_array_length(purchase_details) > 50 then
    raise exception 'purchase details required' using errcode = '22023';
  end if;

  if exists (
    select 1
    from (
      select detail.value->>'item_id' as item_id
      from jsonb_array_elements(purchase_details) as detail(value)
      group by detail.value->>'item_id'
      having count(*) > 1
    ) duplicate_items
  ) then
    raise exception 'duplicate purchase detail item' using errcode = '22023';
  end if;

  for v_detail in select value from jsonb_array_elements(purchase_details)
  loop
    begin
      v_item_id := (v_detail->>'item_id')::uuid;
    exception when others then
      raise exception 'invalid purchase detail item' using errcode = '22023';
    end;

    v_vendor := nullif(pg_catalog.btrim(coalesce(v_detail->>'vendor_name', '')), '');
    v_invoice_number := nullif(pg_catalog.btrim(coalesce(v_detail->>'invoice_number', '')), '');
    v_notes := nullif(pg_catalog.btrim(coalesce(v_detail->>'purchasing_notes', '')), '');
    v_purchased_quantity := null;
    v_actual_unit_cost := null;
    v_actual_total_cost := null;
    v_before_tax_amount := null;
    v_tax_amount := null;
    v_total_amount := null;

    if require_complete and v_vendor is null then
      raise exception 'invalid purchase detail vendor' using errcode = '22023';
    end if;
    if v_vendor is not null and pg_catalog.length(v_vendor) > 120 then
      raise exception 'invalid purchase detail vendor' using errcode = '22023';
    end if;
    if v_invoice_number is not null and pg_catalog.length(v_invoice_number) > 120 then
      raise exception 'invalid purchase detail invoice number' using errcode = '22023';
    end if;
    if v_notes is not null and pg_catalog.length(v_notes) > 1000 then
      raise exception 'invalid purchase detail notes' using errcode = '22023';
    end if;

    if nullif(v_detail->>'total_amount', '') is not null then
      if (v_detail->>'total_amount') !~ money_pattern then
        raise exception 'invalid purchase detail total' using errcode = '22023';
      end if;
      v_total_amount := (v_detail->>'total_amount')::numeric;
    elsif nullif(v_detail->>'actual_total_cost', '') is not null then
      if (v_detail->>'actual_total_cost') !~ money_pattern then
        raise exception 'invalid purchase detail total' using errcode = '22023';
      end if;
      v_total_amount := (v_detail->>'actual_total_cost')::numeric;
    end if;
    v_actual_total_cost := v_total_amount;

    if require_complete and v_total_amount is null then
      raise exception 'invalid purchase detail total' using errcode = '22023';
    end if;

    if nullif(v_detail->>'before_tax_amount', '') is not null then
      if (v_detail->>'before_tax_amount') !~ money_pattern then
        raise exception 'invalid purchase detail before tax' using errcode = '22023';
      end if;
      v_before_tax_amount := (v_detail->>'before_tax_amount')::numeric;
    end if;
    if nullif(v_detail->>'tax_amount', '') is not null then
      if (v_detail->>'tax_amount') !~ money_pattern then
        raise exception 'invalid purchase detail tax' using errcode = '22023';
      end if;
      v_tax_amount := (v_detail->>'tax_amount')::numeric;
    end if;
    if (v_before_tax_amount is not null or v_tax_amount is not null)
      and (v_before_tax_amount is null or v_tax_amount is null or v_total_amount is null or v_before_tax_amount + v_tax_amount <> v_total_amount) then
      raise exception 'invalid purchase detail tax breakdown' using errcode = '22023';
    end if;

    if nullif(v_detail->>'actual_unit_cost', '') is not null then
      if (v_detail->>'actual_unit_cost') !~ money_pattern then
        raise exception 'invalid purchase detail unit cost' using errcode = '22023';
      end if;
      v_actual_unit_cost := (v_detail->>'actual_unit_cost')::numeric;
    end if;

    if nullif(v_detail->>'purchased_quantity', '') is not null then
      begin
        v_purchased_quantity := (v_detail->>'purchased_quantity')::numeric;
      exception when others then
        raise exception 'invalid purchase detail quantity' using errcode = '22023';
      end;
      if v_purchased_quantity <= 0 then
        raise exception 'invalid purchase detail quantity' using errcode = '22023';
      end if;
    end if;

    if v_purchased_quantity is not null
      and v_actual_unit_cost is not null
      and (v_before_tax_amount is null or v_before_tax_amount <> pg_catalog.round(v_purchased_quantity * v_actual_unit_cost, 2)) then
      raise exception 'invalid purchase detail before tax' using errcode = '22023';
    end if;

    update public.purchase_request_items item
    set vendor_name = v_vendor,
        invoice_number = v_invoice_number,
        purchased_quantity = v_purchased_quantity,
        actual_unit_cost = v_actual_unit_cost,
        actual_total_cost = v_actual_total_cost,
        before_tax_amount = v_before_tax_amount,
        tax_amount = v_tax_amount,
        total_amount = v_total_amount,
        purchasing_notes = v_notes
    where item.id = v_item_id
      and item.purchase_request_id = request_row.id;

    if not found then
      raise exception 'purchase detail item not found' using errcode = '42501';
    end if;

    if v_detail ? 'attachments' then
      if jsonb_typeof(v_detail->'attachments') <> 'array'
        or jsonb_array_length(v_detail->'attachments') > 3 then
        raise exception 'invalid purchase detail attachments' using errcode = '22023';
      end if;

      delete from public.purchase_request_item_attachments
      where purchase_request_item_id = v_item_id;

      v_attachment_position := 0;
      for v_attachment in select value from jsonb_array_elements(v_detail->'attachments')
      loop
        v_attachment_position := v_attachment_position + 1;
        insert into public.purchase_request_item_attachments(
          id,
          purchase_request_item_id,
          storage_path,
          original_filename,
          mime_type,
          size_bytes,
          position
        )
        values (
          coalesce(nullif(v_attachment->>'id', '')::uuid, gen_random_uuid()),
          v_item_id,
          nullif(pg_catalog.btrim(coalesce(v_attachment->>'storage_path', '')), ''),
          nullif(pg_catalog.btrim(coalesce(v_attachment->>'original_filename', '')), ''),
          nullif(pg_catalog.btrim(coalesce(v_attachment->>'mime_type', '')), ''),
          nullif(v_attachment->>'size_bytes', '')::bigint,
          coalesce(nullif(v_attachment->>'position', '')::integer, v_attachment_position)
        );
      end loop;
    end if;
  end loop;
end
$function$;

create or replace function public.save_purchasing_purchase_request_details(
  actor_user_id uuid,
  target_organization_id uuid,
  target_request_id uuid,
  purchase_details jsonb
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

  if v_request.status <> 'processing' then
    raise exception 'purchase request details can only be saved while processing' using errcode = '22023';
  end if;

  perform private.apply_purchasing_purchase_request_details(v_request, purchase_details, false);

  update public.purchase_requests
  set updated_at = now()
  where id = v_request.id
  returning * into v_request;

  return jsonb_build_object('purchase_request', private.purchase_request_json(v_request));
end
$function$;

create or replace function public.set_purchasing_purchase_request_status(
  actor_user_id uuid,
  target_organization_id uuid,
  target_request_id uuid,
  next_status text,
  purchase_details jsonb
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

  if next_status = 'purchased' then
    if purchase_details is not null then
      perform private.apply_purchasing_purchase_request_details(v_request, purchase_details, true);
    end if;

    if exists (
      select 1
      from public.purchase_request_items item
      where item.purchase_request_id = v_request.id
        and (item.vendor_name is null or coalesce(item.total_amount, item.actual_total_cost) is null)
    ) then
      raise exception 'purchase details incomplete' using errcode = '22023';
    end if;
  end if;

  update public.purchase_requests
  set status = next_status,
      updated_at = now()
  where id = v_request.id
  returning * into v_request;

  return jsonb_build_object('purchase_request', private.purchase_request_json(v_request));
end
$function$;

create or replace function public.set_purchasing_purchase_request_status(
  actor_user_id uuid,
  target_organization_id uuid,
  target_request_id uuid,
  next_status text
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select public.set_purchasing_purchase_request_status(
    actor_user_id,
    target_organization_id,
    target_request_id,
    next_status,
    null::jsonb
  );
$function$;

revoke all on function private.purchase_request_json(public.purchase_requests) from public, anon, authenticated;
revoke all on function private.apply_purchasing_purchase_request_details(public.purchase_requests, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.save_purchasing_purchase_request_details(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) from public, anon, authenticated;

grant execute on function public.save_purchasing_purchase_request_details(uuid, uuid, uuid, jsonb) to service_role;
grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) to service_role;
grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) to service_role;

commit;
