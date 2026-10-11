begin;

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
  v_purchased_unit text;
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
    v_purchased_unit := null;
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

    v_purchased_unit := nullif(pg_catalog.btrim(coalesce(v_detail->>'purchased_unit', '')), '');
    if v_purchased_unit is not null and pg_catalog.length(v_purchased_unit) > 40 then
      raise exception 'invalid purchase detail unit' using errcode = '22023';
    end if;
    if (v_purchased_quantity is null and v_purchased_unit is not null)
      or (v_purchased_quantity is not null and v_purchased_unit is null) then
      raise exception 'invalid purchase detail quantity unit' using errcode = '22023';
    end if;

    update public.purchase_request_items item
    set vendor_name = v_vendor,
        invoice_number = v_invoice_number,
        purchased_quantity = v_purchased_quantity,
        purchased_unit = v_purchased_unit,
        actual_unit_cost = item.actual_unit_cost,
        actual_total_cost = case when v_actual_total_cost is null then item.actual_total_cost else v_actual_total_cost end,
        before_tax_amount = case when v_before_tax_amount is null then item.before_tax_amount else v_before_tax_amount end,
        tax_amount = case when v_tax_amount is null then item.tax_amount else v_tax_amount end,
        total_amount = case when v_total_amount is null then item.total_amount else v_total_amount end,
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
  v_category text;
  v_item public.purchase_request_items;
  v_log_before public.branch_purchase_logs;
  v_log_after public.branch_purchase_logs;
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
      perform private.apply_purchasing_purchase_request_details(v_request, purchase_details, false);
    end if;

    v_category := case v_request.category
      when 'stationary' then 'stationery'
      when 'kitchen' then 'kitchen'
      else 'other'
    end;

    for v_item in
      select *
      from public.purchase_request_items item
      where item.purchase_request_id = v_request.id
      order by item.sort_order, item.id
      for update
    loop
      if v_item.vendor_name is null
        or coalesce(v_item.total_amount, v_item.actual_total_cost) is null
        or coalesce(v_item.total_amount, v_item.actual_total_cost) <= 0 then
        continue;
      end if;

      insert into public.branch_purchase_logs(
        organization_id,
        branch_id,
        supervisor_team_id,
        category,
        item_name,
        quantity,
        amount,
        before_tax_amount,
        tax_amount,
        vendor_name,
        purchase_date,
        notes,
        payment_status,
        reimbursement_note,
        reimbursed_at,
        reimbursed_by,
        invoice_storage_path,
        invoice_original_name,
        invoice_number,
        source_type,
        source_purchase_request_id,
        source_purchase_request_item_id,
        created_by
      )
      values(
        v_request.organization_id,
        v_request.branch_id,
        null,
        v_category,
        v_item.item_name,
        coalesce(v_item.purchased_quantity, v_item.quantity),
        coalesce(v_item.total_amount, v_item.actual_total_cost),
        v_item.before_tax_amount,
        v_item.tax_amount,
        v_item.vendor_name,
        (statement_timestamp() at time zone 'Asia/Riyadh')::date,
        v_item.purchasing_notes,
        'unpaid',
        null,
        null,
        null,
        null,
        null,
        v_item.invoice_number,
        'central_purchasing',
        v_request.id,
        v_item.id,
        actor_user_id
      )
      on conflict (source_purchase_request_item_id)
      where source_type = 'central_purchasing' and source_purchase_request_item_id is not null
      do nothing;

      if not found then
        select * into v_log_before
        from public.branch_purchase_logs log
        where log.source_type = 'central_purchasing'
          and log.source_purchase_request_item_id = v_item.id
        for update;

        if v_log_before.source_purchase_request_id <> v_request.id
          or v_log_before.organization_id <> v_request.organization_id
          or v_log_before.branch_id <> v_request.branch_id
          or v_log_before.payment_status not in ('unpaid', 'reimbursed') then
          raise exception 'purchase log conflicts with current workflow state' using errcode = '40001';
        end if;

        update public.branch_purchase_logs log
        set category = v_category,
            item_name = v_item.item_name,
            quantity = coalesce(v_item.purchased_quantity, v_item.quantity),
            amount = coalesce(v_item.total_amount, v_item.actual_total_cost),
            before_tax_amount = v_item.before_tax_amount,
            tax_amount = v_item.tax_amount,
            vendor_name = v_item.vendor_name,
            purchase_date = (statement_timestamp() at time zone 'Asia/Riyadh')::date,
            notes = v_item.purchasing_notes,
            invoice_number = v_item.invoice_number,
            revision = log.revision + 1
        where log.id = v_log_before.id
        returning * into v_log_after;

        insert into public.branch_purchase_log_events(
          purchase_log_id,
          organization_id,
          branch_id,
          event_type,
          actor_user_id,
          reason_code,
          reason_note,
          old_values,
          new_values
        )
        values(
          v_log_after.id,
          v_log_after.organization_id,
          v_log_after.branch_id,
          'edited',
          actor_user_id,
          'correction',
          null,
          private.branch_purchase_log_snapshot(v_log_before),
          private.branch_purchase_log_snapshot(v_log_after)
        );
      end if;
    end loop;
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

revoke all on function private.apply_purchasing_purchase_request_details(public.purchase_requests, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) from public, anon, authenticated;

grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) to service_role;
grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) to service_role;

commit;
