-- Extend the existing Maintenance Purchase Log row for Vendor / Service expenses.
-- This migration is intentionally additive: no rows are rewritten or backfilled.

alter table public.maintenance_purchase_logs
  add constraint maintenance_purchase_type_contract_v2_check check (
    (purchase_type = 'issue' and maintenance_issue_id is not null)
    or (purchase_type = 'general' and maintenance_issue_id is null)
  ) not valid,
  add constraint maintenance_purchase_unit_contract_v2_check check (
    unit in ('pcs', 'meter', 'kg', 'box', 'bag', 'roll', 'set', 'liter', 'other', 'service')
  ) not valid,
  add constraint maintenance_purchase_category_contract_v2_check check (
    category in (
      'spare_parts', 'tools_equipment', 'electrical', 'plumbing', 'hvac_refrigeration',
      'kitchen_equipment', 'fuel_petrol', 'transportation', 'technician_contractor',
      'building_facility', 'safety_equipment', 'it_network', 'general_supplies', 'other',
      'service'
    )
  ) not valid,
  add constraint maintenance_purchase_general_scope_canonical_check check (
    purchase_type <> 'general'
    or (
      maintenance_issue_id is null
      and (
        (purchase_scope = 'branch' and branch_id is not null and destination is null)
        or (purchase_scope = 'office' and branch_id is null and destination = 'Office')
        or (purchase_scope = 'other' and branch_id is null and destination is not null)
      )
    )
  ) not valid,
  add constraint maintenance_purchase_service_shape_check check (
    (category <> 'service' and unit <> 'service')
    or (
      purchase_type = 'general'
      and category = 'service'
      and unit = 'service'
      and quantity = 1
      and pg_catalog.upper(vendor_name) <> 'N/A'
    )
  ) not valid;

alter table public.maintenance_purchase_logs
  validate constraint maintenance_purchase_type_contract_v2_check;
alter table public.maintenance_purchase_logs
  validate constraint maintenance_purchase_unit_contract_v2_check;
alter table public.maintenance_purchase_logs
  validate constraint maintenance_purchase_category_contract_v2_check;
alter table public.maintenance_purchase_logs
  validate constraint maintenance_purchase_general_scope_canonical_check;
alter table public.maintenance_purchase_logs
  validate constraint maintenance_purchase_service_shape_check;

alter table public.maintenance_purchase_logs
  drop constraint maintenance_purchase_type_check,
  drop constraint maintenance_purchase_unit_check,
  drop constraint maintenance_purchase_category_check;

alter table public.maintenance_purchase_logs
  rename constraint maintenance_purchase_type_contract_v2_check to maintenance_purchase_type_check;
alter table public.maintenance_purchase_logs
  rename constraint maintenance_purchase_unit_contract_v2_check to maintenance_purchase_unit_check;
alter table public.maintenance_purchase_logs
  rename constraint maintenance_purchase_category_contract_v2_check to maintenance_purchase_category_check;

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
begin
  begin
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
    cost := (payload->>'amount')::numeric;
    day := (payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid maintenance purchase payload' using errcode = '22023';
  end;

  request_fingerprint := case
    when payload->>'request_hash' = '' then null
    else payload->>'request_hash'
  end;
  if request_idempotency_key is null then request_fingerprint := null; end if;
  if request_idempotency_key is not null and request_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid maintenance purchase idempotency payload' using errcode = '22023';
  end if;
  if item is null or qty <= 0 or cost < 0 or day is null
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
      vendor_name, purchase_date, notes, payment_method, receipt_storage_path,
      receipt_original_name, idempotency_key, request_hash
    ) values (
      purchase_id, target_organization, target_branch, target_issue_id, saved_type, saved_scope,
      saved_destination, purchase_category, actor_user_id, item, qty, purchase_unit, cost,
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
      vendor_name, purchase_date, notes, payment_method, receipt_storage_path,
      receipt_original_name, idempotency_key, request_hash
    ) values (
      purchase_id, target_organization, target_branch, null, saved_type, saved_scope, saved_destination,
      purchase_category, actor_user_id, item, qty, purchase_unit, cost, vendor, day, notes_value,
      requested_payment_method, path, filename, request_idempotency_key, request_fingerprint
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

revoke all on function public.create_maintenance_purchase_log_v2(uuid, uuid, jsonb)
from public, anon, authenticated;
grant execute on function public.create_maintenance_purchase_log_v2(uuid, uuid, jsonb)
to service_role;
