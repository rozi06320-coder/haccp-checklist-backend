begin;

alter table public.purchase_request_items
  add column if not exists vendor_name text,
  add column if not exists purchased_quantity numeric,
  add column if not exists actual_unit_cost numeric(12,2),
  add column if not exists actual_total_cost numeric(12,2),
  add column if not exists purchasing_notes text;

alter table public.purchase_request_items
  add constraint purchase_request_items_vendor_name_check
    check (vendor_name is null or (vendor_name = pg_catalog.btrim(vendor_name) and pg_catalog.length(vendor_name) between 1 and 120)),
  add constraint purchase_request_items_purchased_quantity_check
    check (purchased_quantity is null or purchased_quantity > 0),
  add constraint purchase_request_items_actual_unit_cost_check
    check (actual_unit_cost is null or actual_unit_cost >= 0),
  add constraint purchase_request_items_actual_total_cost_check
    check (actual_total_cost is null or actual_total_cost >= 0),
  add constraint purchase_request_items_actual_cost_breakdown_check
    check (
      purchased_quantity is null
      or actual_unit_cost is null
      or actual_total_cost is null
      or actual_total_cost = pg_catalog.round(purchased_quantity * actual_unit_cost, 2)
    ),
  add constraint purchase_request_items_purchasing_notes_check
    check (purchasing_notes is null or pg_catalog.length(purchasing_notes) <= 1000);

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
        'purchased_quantity', item.purchased_quantity,
        'actual_unit_cost', item.actual_unit_cost,
        'actual_total_cost', item.actual_total_cost,
        'purchasing_notes', item.purchasing_notes
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
  v_detail jsonb;
  v_item_id uuid;
  v_vendor text;
  v_purchased_quantity numeric;
  v_actual_unit_cost numeric;
  v_actual_total_cost numeric;
  v_notes text;
  money_pattern constant text := '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$';
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
    if purchase_details is null
      or jsonb_typeof(purchase_details) <> 'array'
      or jsonb_array_length(purchase_details) = 0
      or jsonb_array_length(purchase_details) > 50 then
      raise exception 'purchase details required' using errcode = '22023';
    end if;

    for v_detail in select value from jsonb_array_elements(purchase_details)
    loop
      begin
        v_item_id := (v_detail->>'item_id')::uuid;
      exception when others then
        raise exception 'invalid purchase detail item' using errcode = '22023';
      end;

      v_vendor := nullif(pg_catalog.btrim(coalesce(v_detail->>'vendor_name', '')), '');
      v_notes := nullif(pg_catalog.btrim(coalesce(v_detail->>'purchasing_notes', '')), '');

      if v_vendor is null or pg_catalog.length(v_vendor) > 120 then
        raise exception 'invalid purchase detail vendor' using errcode = '22023';
      end if;
      if v_notes is not null and pg_catalog.length(v_notes) > 1000 then
        raise exception 'invalid purchase detail notes' using errcode = '22023';
      end if;
      if nullif(v_detail->>'actual_total_cost', '') is null or (v_detail->>'actual_total_cost') !~ money_pattern then
        raise exception 'invalid purchase detail total' using errcode = '22023';
      end if;

      v_actual_total_cost := (v_detail->>'actual_total_cost')::numeric;
      v_actual_unit_cost := null;
      v_purchased_quantity := null;

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
        and v_actual_total_cost <> pg_catalog.round(v_purchased_quantity * v_actual_unit_cost, 2) then
        raise exception 'invalid purchase detail total' using errcode = '22023';
      end if;

      update public.purchase_request_items item
      set vendor_name = v_vendor,
          purchased_quantity = v_purchased_quantity,
          actual_unit_cost = v_actual_unit_cost,
          actual_total_cost = v_actual_total_cost,
          purchasing_notes = v_notes
      where item.id = v_item_id
        and item.purchase_request_id = v_request.id;

      if not found then
        raise exception 'purchase detail item not found' using errcode = '42501';
      end if;
    end loop;

    if exists (
      select 1
      from public.purchase_request_items item
      where item.purchase_request_id = v_request.id
        and (item.vendor_name is null or item.actual_total_cost is null)
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

create function public.list_purchasing_purchase_logs(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  payment_status_filter text default null,
  date_from_filter date default null,
  date_to_filter date default null,
  search_filter text default null
)
returns table(
  id uuid,
  branch_id uuid,
  branch_name text,
  category text,
  item_name text,
  quantity numeric,
  amount numeric,
  before_tax_amount numeric,
  tax_amount numeric,
  vendor_name text,
  purchase_date date,
  notes text,
  payment_status text,
  reimbursement_note text,
  reimbursed_at timestamptz,
  reimbursed_by uuid,
  invoice_storage_path text,
  invoice_original_name text,
  invoice_number text,
  created_by uuid,
  created_by_name text,
  created_at timestamptz,
  updated_at timestamptz,
  revision bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  clean_search text := nullif(pg_catalog.btrim(coalesce(search_filter, '')), '');
begin
  if not private.has_active_purchasing_membership(actor_user_id, target_organization_id) then
    raise exception 'purchasing purchase log access denied' using errcode = '42501';
  end if;

  if payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed') then
    raise exception 'invalid purchase log payment status' using errcode = '22023';
  end if;

  if date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter then
    raise exception 'invalid purchase log date range' using errcode = '22023';
  end if;

  return query
  select
    log.id,
    log.branch_id,
    branch.name,
    log.category,
    log.item_name,
    log.quantity,
    log.amount,
    log.before_tax_amount,
    log.tax_amount,
    log.vendor_name,
    log.purchase_date,
    log.notes,
    log.payment_status,
    log.reimbursement_note,
    log.reimbursed_at,
    log.reimbursed_by,
    log.invoice_storage_path,
    log.invoice_original_name,
    log.invoice_number,
    log.created_by,
    creator.full_name,
    log.created_at,
    log.updated_at,
    log.revision
  from public.branch_purchase_logs log
  join public.branches branch
    on branch.id = log.branch_id
   and branch.organization_id = target_organization_id
   and branch.active
  join public.organizations organization
    on organization.id = branch.organization_id
   and organization.active
  left join public.profiles creator
    on creator.id = log.created_by
  where log.organization_id = target_organization_id
    and log.deleted_at is null
    and (branch_filter is null or log.branch_id = branch_filter)
    and (payment_status_filter is null or log.payment_status = payment_status_filter)
    and (date_from_filter is null or log.purchase_date >= date_from_filter)
    and (date_to_filter is null or log.purchase_date <= date_to_filter)
    and (
      clean_search is null
      or log.item_name ilike '%' || clean_search || '%'
      or log.vendor_name ilike '%' || clean_search || '%'
      or coalesce(log.invoice_number, '') ilike '%' || clean_search || '%'
      or branch.name ilike '%' || clean_search || '%'
      or coalesce(branch.code, '') ilike '%' || clean_search || '%'
    )
  order by log.purchase_date desc, log.created_at desc, log.id desc
  limit 500;
end
$function$;

revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text) from public, anon, authenticated;

grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) to service_role;
grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) to service_role;
grant execute on function public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text) to service_role;

commit;
