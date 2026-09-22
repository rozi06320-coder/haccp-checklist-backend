alter table public.maintenance_purchase_logs
  add column if not exists invoice_number text,
  add column if not exists before_tax_amount numeric,
  add column if not exists tax_amount numeric,
  add column if not exists total_amount numeric;

update public.maintenance_purchase_logs
set before_tax_amount = amount,
    tax_amount = 0,
    total_amount = amount
where amount is not null
  and before_tax_amount is null
  and tax_amount is null
  and total_amount is null;

alter table public.maintenance_purchase_logs
  drop constraint if exists maintenance_purchase_invoice_number_check,
  drop constraint if exists maintenance_purchase_money_breakdown_check;

alter table public.maintenance_purchase_logs
  add constraint maintenance_purchase_invoice_number_check check (
    invoice_number is null
    or (
      invoice_number = pg_catalog.btrim(invoice_number)
      and pg_catalog.length(invoice_number) between 1 and 120
    )
  ) not valid,
  add constraint maintenance_purchase_money_breakdown_check check (
    before_tax_amount is null
    and tax_amount is null
    and total_amount is null
    or (
      before_tax_amount is not null
      and tax_amount is not null
      and total_amount is not null
      and before_tax_amount >= 0
      and tax_amount >= 0
      and total_amount >= 0
      and before_tax_amount + tax_amount = total_amount
      and amount = total_amount
    )
  ) not valid;

alter table public.maintenance_purchase_logs
  validate constraint maintenance_purchase_invoice_number_check;
alter table public.maintenance_purchase_logs
  validate constraint maintenance_purchase_money_breakdown_check;

create or replace function private.maintenance_purchase_json(purchase public.maintenance_purchase_logs)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', purchase.id,
    'organization_id', purchase.organization_id,
    'branch_id', purchase.branch_id,
    'maintenance_issue_id', purchase.maintenance_issue_id,
    'purchase_type', purchase.purchase_type,
    'purchase_scope', purchase.purchase_scope,
    'destination', purchase.destination,
    'category', purchase.category,
    'maintenance_user_id', purchase.maintenance_user_id,
    'item_name', purchase.item_name,
    'quantity', purchase.quantity,
    'unit', purchase.unit,
    'amount', purchase.amount,
    'invoice_number', purchase.invoice_number,
    'before_tax_amount', purchase.before_tax_amount,
    'tax_amount', purchase.tax_amount,
    'total_amount', purchase.total_amount,
    'vendor_name', purchase.vendor_name,
    'purchase_date', purchase.purchase_date,
    'notes', purchase.notes,
    'payment_status', purchase.payment_status,
    'payment_method', purchase.payment_method,
    'reimbursement_note', purchase.reimbursement_note,
    'reimbursed_at', purchase.reimbursed_at,
    'reimbursed_by', purchase.reimbursed_by,
    'receipt_storage_path', purchase.receipt_storage_path,
    'receipt_original_name', purchase.receipt_original_name,
    'attachments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', attachment.id,
        'storage_path', attachment.storage_path,
        'original_filename', attachment.original_filename,
        'mime_type', attachment.mime_type,
        'size_bytes', attachment.size_bytes,
        'position', attachment.position
      ) order by attachment.position)
      from public.maintenance_purchase_attachments attachment
      where attachment.purchase_id = purchase.id
    ), '[]'::jsonb),
    'created_at', purchase.created_at,
    'updated_at', purchase.updated_at
  );
$$;

create or replace function public.create_maintenance_purchase_log_v2(
  actor_user_id uuid,
  target_issue_id uuid,
  payload jsonb
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  issue public.maintenance_issues%rowtype;
  item text := private.clean_purchase_text(payload->>'item_name', null, 120);
  vendor text := private.clean_purchase_text(payload->>'vendor_name', 'N/A', 120);
  invoice_no text := private.clean_purchase_text(payload->>'invoice_number', null, 120);
  notes_value text := private.clean_purchase_text(payload->>'notes', null, 2000);
  path text := private.clean_purchase_text(payload->>'receipt_storage_path', null, 260);
  filename text := private.clean_purchase_text(payload->>'receipt_original_name', null, 180);
  purchase_unit text := private.clean_purchase_text(payload->>'unit', null, 20);
  requested_scope text := private.clean_purchase_text(payload->>'purchase_scope', null, 20);
  requested_destination text := private.clean_purchase_text(payload->>'destination', null, 120);
  requested_branch_id uuid;
  requested_type text := private.clean_purchase_text(payload->>'purchase_type', null, 20);
  requested_payment_method text := private.clean_maintenance_payment_method(payload->>'payment_method');
  purchase_category text := private.clean_purchase_text(payload->>'category', null, 40);
  purchase_id uuid;
  request_idempotency_key uuid;
  request_fingerprint text;
  target_organization uuid;
  target_branch uuid;
  saved_type text;
  saved_scope text;
  saved_destination text;
  qty numeric;
  cost numeric;
  before_tax numeric;
  tax numeric;
  total numeric;
  day date;
  attachment_count integer;
  attachment jsonb;
  attachment_position integer;
  attachment_id uuid;
  attachment_path text;
  attachment_name text;
  attachment_mime text;
  attachment_size bigint;
  saved public.maintenance_purchase_logs%rowtype;
  inserted boolean := false;
  money_pattern constant text := '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$';
begin
  begin
    if (nullif(payload->>'amount', '') is not null and nullif(payload->>'amount', '') !~ money_pattern)
      or (nullif(payload->>'before_tax_amount', '') is not null and nullif(payload->>'before_tax_amount', '') !~ money_pattern)
      or (nullif(payload->>'tax_amount', '') is not null and nullif(payload->>'tax_amount', '') !~ money_pattern)
      or (nullif(payload->>'total_amount', '') is not null and nullif(payload->>'total_amount', '') !~ money_pattern) then
      raise exception 'invalid maintenance purchase payload' using errcode = '22023';
    end if;
    purchase_id := coalesce(
      case
        when payload->>'purchase_id' is null or payload->>'purchase_id' = '' then null
        else (payload->>'purchase_id')::uuid
      end,
      gen_random_uuid()
    );
    requested_branch_id := case
      when payload->>'branch_id' is null or payload->>'branch_id' = '' then null
      else (payload->>'branch_id')::uuid
    end;
    request_idempotency_key := case
      when payload->>'idempotency_key' is null or payload->>'idempotency_key' = '' then null
      else (payload->>'idempotency_key')::uuid
    end;
    qty := (payload->>'quantity')::numeric;
    cost := case when nullif(payload->>'amount', '') is null then null else (payload->>'amount')::numeric end;
    before_tax := case when nullif(payload->>'before_tax_amount', '') is null then null else (payload->>'before_tax_amount')::numeric end;
    tax := case when nullif(payload->>'tax_amount', '') is null then null else (payload->>'tax_amount')::numeric end;
    total := case when nullif(payload->>'total_amount', '') is null then null else (payload->>'total_amount')::numeric end;
    day := (payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid maintenance purchase payload' using errcode = '22023';
  end;

  if before_tax is null and tax is null and total is null and cost is not null then
    before_tax := cost;
    tax := 0;
    total := cost;
  elsif before_tax is not null and tax is not null and total is not null then
    if cost is not null and pg_catalog.round(cost, 2) <> pg_catalog.round(total, 2) then
      raise exception 'invalid maintenance purchase payload' using errcode = '22023';
    end if;
    cost := total;
  else
    raise exception 'invalid maintenance purchase payload' using errcode = '22023';
  end if;

  request_fingerprint := case
    when payload->>'request_hash' = '' then null
    else payload->>'request_hash'
  end;
  if request_idempotency_key is null then request_fingerprint := null; end if;
  if request_idempotency_key is not null and request_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid maintenance purchase idempotency payload' using errcode = '22023';
  end if;
  if item is null or qty <= 0 or cost < 0 or before_tax < 0 or tax < 0 or total < 0
    or pg_catalog.round(before_tax + tax, 2) <> pg_catalog.round(total, 2)
    or day is null
    or purchase_unit not in ('pcs', 'meter', 'kg', 'box', 'bag', 'roll', 'set', 'liter', 'other', 'service')
    or purchase_category not in (
      'spare_parts', 'tools_equipment', 'electrical', 'plumbing', 'hvac_refrigeration',
      'kitchen_equipment', 'fuel_petrol', 'transportation', 'technician_contractor',
      'building_facility', 'safety_equipment', 'it_network', 'general_supplies', 'other',
      'service'
    ) then
    raise exception 'invalid maintenance purchase payload' using errcode = '22023';
  end if;

  if target_issue_id is not null then
    if requested_type is not null and requested_type <> 'issue' then
      raise exception 'invalid maintenance purchase payload' using errcode = '22023';
    end if;
    issue := private.require_maintenance_purchase_issue(actor_user_id, target_issue_id);
    target_organization := issue.organization_id;
    target_branch := issue.branch_id;
    saved_type := 'issue';
    if issue.location_scope = 'office' or issue.branch_id is null then
      saved_scope := 'office';
      target_branch := null;
      saved_destination := 'Office';
    else
      saved_scope := 'branch';
      saved_destination := null;
    end if;
  else
    if coalesce(requested_type, 'general') <> 'general' then
      raise exception 'invalid maintenance purchase payload' using errcode = '22023';
    end if;

    target_organization := private.require_single_maintenance_purchase_organization(actor_user_id);
    saved_type := 'general';
    saved_scope := coalesce(requested_scope, 'other');

    if saved_scope = 'branch' then
      if requested_branch_id is null or requested_destination is not null then
        raise exception 'invalid maintenance purchase payload' using errcode = '22023';
      end if;
      select branch.id into target_branch
      from public.branches branch
      where branch.id = requested_branch_id
        and branch.organization_id = target_organization
        and branch.active
      for share;
      if target_branch is null then
        raise exception 'maintenance purchase access denied' using errcode = '42501';
      end if;
      saved_destination := null;
    elsif saved_scope = 'office' then
      if requested_branch_id is not null
        or (requested_destination is not null and requested_destination <> 'Office') then
        raise exception 'invalid maintenance purchase payload' using errcode = '22023';
      end if;
      target_branch := null;
      saved_destination := 'Office';
    elsif saved_scope = 'other' then
      if requested_branch_id is not null or requested_destination is null then
        raise exception 'invalid maintenance purchase payload' using errcode = '22023';
      end if;
      target_branch := null;
      saved_destination := requested_destination;
    else
      raise exception 'invalid maintenance purchase payload' using errcode = '22023';
    end if;
  end if;

  if purchase_category = 'service' or purchase_unit = 'service' then
    if saved_type <> 'general'
      or purchase_category <> 'service'
      or purchase_unit <> 'service'
      or qty <> 1
      or pg_catalog.upper(vendor) = 'N/A' then
      raise exception 'invalid maintenance purchase payload' using errcode = '22023';
    end if;
  end if;

  if coalesce(jsonb_typeof(payload->'attachments'), 'array') <> 'array' then
    raise exception 'invalid maintenance purchase payload' using errcode = '22023';
  end if;
  attachment_count := jsonb_array_length(coalesce(payload->'attachments', '[]'::jsonb));
  if attachment_count > 3 then
    raise exception 'too many maintenance purchase attachments' using errcode = '22023';
  end if;
  if attachment_count > 0 then
    path := coalesce(path, private.clean_purchase_text(payload->'attachments'->0->>'storage_path', null, 260));
    filename := coalesce(filename, private.clean_purchase_text(payload->'attachments'->0->>'original_filename', null, 180));
  end if;
  if path is not null and (
    attachment_count = 0
    or path not like 'maintenance/' || target_organization::text || '/purchases/' || purchase_id::text || '/%'
  ) then
    raise exception 'invalid maintenance purchase payload' using errcode = '22023';
  end if;

  if saved_type = 'issue' then
    insert into public.maintenance_purchase_logs as purchase(
      id, organization_id, branch_id, maintenance_issue_id, purchase_type, purchase_scope,
      destination, category, maintenance_user_id, item_name, quantity, unit, amount,
      invoice_number, before_tax_amount, tax_amount, total_amount,
      vendor_name, purchase_date, notes, payment_method, receipt_storage_path,
      receipt_original_name, idempotency_key, request_hash
    ) values (
      purchase_id, target_organization, target_branch, target_issue_id, saved_type, saved_scope,
      saved_destination, purchase_category, actor_user_id, item, qty, purchase_unit, cost,
      invoice_no, before_tax, tax, total,
      vendor, day, notes_value, requested_payment_method, path, filename,
      request_idempotency_key, request_fingerprint
    )
    on conflict (organization_id, maintenance_issue_id, idempotency_key)
      where purchase_type = 'issue' and idempotency_key is not null
      do nothing
    returning * into saved;
  else
    insert into public.maintenance_purchase_logs as purchase(
      id, organization_id, branch_id, maintenance_issue_id, purchase_type, purchase_scope,
      destination, category, maintenance_user_id, item_name, quantity, unit, amount,
      invoice_number, before_tax_amount, tax_amount, total_amount,
      vendor_name, purchase_date, notes, payment_method, receipt_storage_path,
      receipt_original_name, idempotency_key, request_hash
    ) values (
      purchase_id, target_organization, target_branch, null, saved_type, saved_scope, saved_destination,
      purchase_category, actor_user_id, item, qty, purchase_unit, cost,
      invoice_no, before_tax, tax, total,
      vendor, day, notes_value, requested_payment_method, path, filename,
      request_idempotency_key, request_fingerprint
    )
    on conflict (organization_id, idempotency_key)
      where purchase_type = 'general' and idempotency_key is not null
      do nothing
    returning * into saved;
  end if;

  inserted := saved.id is not null;
  if not inserted and request_idempotency_key is not null then
    if saved_type = 'issue' then
      select * into saved from public.maintenance_purchase_logs purchase
      where purchase.organization_id = target_organization
        and purchase.maintenance_issue_id = target_issue_id
        and purchase.purchase_type = 'issue'
        and purchase.idempotency_key = request_idempotency_key;
    else
      select * into saved from public.maintenance_purchase_logs purchase
      where purchase.organization_id = target_organization
        and purchase.purchase_type = 'general'
        and purchase.idempotency_key = request_idempotency_key;
    end if;
    if saved.id is null then
      raise exception 'maintenance purchase idempotency replay failed' using errcode = '40001';
    end if;
    if saved.request_hash is distinct from request_fingerprint then
      raise exception 'maintenance purchase idempotency payload changed' using errcode = '40001';
    end if;
  end if;

  if inserted then
    for attachment, attachment_position in
      select value, ordinality::integer
      from jsonb_array_elements(coalesce(payload->'attachments', '[]'::jsonb)) with ordinality
    loop
      begin
        attachment_id := case
          when attachment->>'id' is null or attachment->>'id' = '' then null
          else (attachment->>'id')::uuid
        end;
        attachment_path := private.clean_purchase_text(attachment->>'storage_path', null, 260);
        attachment_name := private.clean_purchase_text(attachment->>'original_filename', null, 180);
        attachment_mime := private.clean_purchase_text(attachment->>'mime_type', null, 80);
        attachment_size := (attachment->>'size_bytes')::bigint;
      exception when others then
        raise exception 'invalid maintenance purchase payload' using errcode = '22023';
      end;
      if attachment_path is null
        or attachment_path not like 'maintenance/' || target_organization::text || '/purchases/' || purchase_id::text || '/%'
        or attachment_position not between 1 and 3
        or attachment_mime not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')
        or attachment_size <= 0 or attachment_size > 5242880 then
        raise exception 'invalid maintenance purchase payload' using errcode = '22023';
      end if;
      insert into public.maintenance_purchase_attachments(
        id, purchase_id, organization_id, branch_id, storage_path, original_filename,
        mime_type, size_bytes, position, uploaded_by
      ) values (
        coalesce(attachment_id, gen_random_uuid()), purchase_id,
        target_organization, target_branch, attachment_path, attachment_name,
        attachment_mime, attachment_size, attachment_position, actor_user_id
      );
    end loop;
  end if;

  return next private.maintenance_purchase_json(saved);
end;
$$;

create or replace function private.enforce_maintenance_purchase_financial_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.payment_status = 'reimbursed' and (
    new.payment_status is distinct from old.payment_status
    or new.organization_id is distinct from old.organization_id
    or new.branch_id is distinct from old.branch_id
    or new.maintenance_issue_id is distinct from old.maintenance_issue_id
    or new.purchase_type is distinct from old.purchase_type
    or new.purchase_scope is distinct from old.purchase_scope
    or new.destination is distinct from old.destination
    or new.category is distinct from old.category
    or new.maintenance_user_id is distinct from old.maintenance_user_id
    or new.amount is distinct from old.amount
    or new.invoice_number is distinct from old.invoice_number
    or new.before_tax_amount is distinct from old.before_tax_amount
    or new.tax_amount is distinct from old.tax_amount
    or new.total_amount is distinct from old.total_amount
    or new.quantity is distinct from old.quantity
    or new.item_name is distinct from old.item_name
    or new.unit is distinct from old.unit
    or new.vendor_name is distinct from old.vendor_name
    or new.purchase_date is distinct from old.purchase_date
    or new.notes is distinct from old.notes
    or new.payment_method is distinct from old.payment_method
    or new.reimbursement_note is distinct from old.reimbursement_note
    or new.reimbursed_at is distinct from old.reimbursed_at
    or new.reimbursed_by is distinct from old.reimbursed_by
    or new.receipt_storage_path is distinct from old.receipt_storage_path
    or new.receipt_original_name is distinct from old.receipt_original_name
    or new.idempotency_key is distinct from old.idempotency_key
    or new.request_hash is distinct from old.request_hash
  ) then
    raise exception 'reimbursed maintenance purchase is immutable' using errcode = '55000';
  end if;
  if old.payment_status = 'unpaid' and new.payment_status = 'reimbursed'
    and (new.reimbursed_by is null or new.reimbursed_at is null) then
    raise exception 'invalid maintenance reimbursement attribution' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.maintenance_purchase_json(public.maintenance_purchase_logs) from public, anon, authenticated, service_role;
revoke all on function private.enforce_maintenance_purchase_financial_immutability() from public, anon, authenticated, service_role;
revoke all on function public.create_maintenance_purchase_log_v2(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.create_maintenance_purchase_log_v2(uuid, uuid, jsonb) to service_role;
