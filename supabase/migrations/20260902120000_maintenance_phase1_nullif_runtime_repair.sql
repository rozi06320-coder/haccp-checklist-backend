-- Repair Phase 1 Maintenance runtime calls that resolve NULLIF as a function
-- under an empty search_path. Keep the existing signatures and behavior.

create or replace function private.create_maintenance_issue_core(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid,
  target_location_scope text,
  payload jsonb,
  require_before_photo boolean
)
returns public.maintenance_issues
language plpgsql
security definer
set search_path = ''
as $$
declare
  authorized record;
  clean_title text := private.clean_maintenance_text(payload->>'title', true, 120);
  clean_category text := coalesce(
    case when payload->>'category' = '' then null else payload->>'category' end,
    'other'
  );
  clean_priority text := coalesce(
    case when payload->>'priority' = '' then null else payload->>'priority' end,
    'normal'
  );
  clean_description text := private.clean_maintenance_text(payload->>'description', false, 2000);
  clean_location text := private.clean_maintenance_text(payload->>'location', false, 160);
  clean_responsible text := private.clean_maintenance_responsible_person(payload->>'responsible_person_name');
  requested_id uuid;
  request_idempotency_key uuid := private.maintenance_issue_idempotency_key(payload);
  attachments jsonb;
  attachment jsonb;
  attachment_position integer := 0;
  saved public.maintenance_issues%rowtype;
begin
  if target_location_scope = 'branch' then
    select * into authorized
    from private.require_supervisor_maintenance_branch(actor_user_id, target_branch_id);
    if authorized.branch_id is null then
      raise exception 'maintenance issue access denied' using errcode = '42501';
    end if;
    target_organization_id := authorized.organization_id;
    target_branch_id := authorized.branch_id;
  elsif target_location_scope = 'office' then
    if target_organization_id is null
      or not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
      raise exception 'maintenance issue access denied' using errcode = '42501';
    end if;
    target_branch_id := null;
  else
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end if;

  if clean_category not in ('equipment', 'plumbing', 'electrical', 'refrigeration', 'building', 'other')
    or clean_priority not in ('low', 'normal', 'high', 'urgent') then
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end if;

  begin
    requested_id := coalesce(
      case
        when payload->>'issue_id' is null or payload->>'issue_id' = '' then null
        else (payload->>'issue_id')::uuid
      end,
      gen_random_uuid()
    );
  exception when others then
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end;

  attachments := private.clean_maintenance_issue_attachment_array(
    case
      when coalesce(jsonb_typeof(payload->'before_photos'), 'null') = 'array' then payload->'before_photos'
      when coalesce(jsonb_typeof(payload->'before_photo'), 'null') = 'object' then jsonb_build_array(payload->'before_photo')
      else '[]'::jsonb
    end,
    'issue'
  );
  if require_before_photo and jsonb_array_length(attachments) = 0 then
    raise exception 'invalid maintenance issue payload' using errcode = '22023';
  end if;

  if target_location_scope = 'branch' then
    insert into public.maintenance_issues as issue(
      id, organization_id, branch_id, supervisor_team_id, location_scope, title, category,
      priority, status, description, location, reported_by, assigned_to,
      responsible_person_name, idempotency_key
    ) values (
      requested_id, target_organization_id, target_branch_id, null, 'branch', clean_title,
      clean_category, clean_priority, 'new', clean_description, clean_location, actor_user_id,
      null, clean_responsible, request_idempotency_key
    )
    on conflict (organization_id, branch_id, idempotency_key)
      where location_scope = 'branch' and idempotency_key is not null
      do nothing
    returning * into saved;

    if saved.id is null and request_idempotency_key is not null then
      select * into saved
      from public.maintenance_issues issue
      where issue.location_scope = 'branch'
        and issue.organization_id = target_organization_id
        and issue.branch_id = target_branch_id
        and issue.idempotency_key = request_idempotency_key;
    end if;
  else
    insert into public.maintenance_issues as issue(
      id, organization_id, branch_id, supervisor_team_id, location_scope, title, category,
      priority, status, description, location, reported_by, assigned_to,
      responsible_person_name, idempotency_key
    ) values (
      requested_id, target_organization_id, null, null, 'office', clean_title, clean_category,
      clean_priority, 'new', clean_description, clean_location, actor_user_id, null,
      clean_responsible, request_idempotency_key
    )
    on conflict (organization_id, idempotency_key)
      where location_scope = 'office' and idempotency_key is not null
      do nothing
    returning * into saved;

    if saved.id is null and request_idempotency_key is not null then
      select * into saved
      from public.maintenance_issues issue
      where issue.location_scope = 'office'
        and issue.organization_id = target_organization_id
        and issue.idempotency_key = request_idempotency_key;
    end if;
  end if;

  if saved.id is null then
    raise exception 'maintenance issue idempotency replay failed' using errcode = '23505';
  end if;

  if saved.id = requested_id then
    for attachment in select value from jsonb_array_elements(attachments) loop
      attachment_position := attachment_position + 1;
      insert into public.maintenance_issue_attachments(
        id, maintenance_issue_id, organization_id, branch_id, attachment_type,
        storage_path, original_filename, mime_type, size_bytes, uploaded_by, attachment_position
      ) values (
        (attachment->>'id')::uuid, saved.id, saved.organization_id, saved.branch_id, 'issue',
        attachment->>'storage_path', attachment->>'original_filename', attachment->>'mime_type',
        (attachment->>'size_bytes')::bigint, actor_user_id, attachment_position
      );
    end loop;

    insert into public.maintenance_issue_updates(
      issue_id, organization_id, status, note, updated_by, update_kind
    ) values (
      saved.id, saved.organization_id, saved.status, 'Issue reported.', actor_user_id, 'status_update'
    );
  end if;

  return saved;
end;
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
    or purchase_unit not in ('pcs', 'meter', 'kg', 'box', 'bag', 'roll', 'set', 'liter', 'other')
    or purchase_category not in (
      'spare_parts', 'tools_equipment', 'electrical', 'plumbing', 'hvac_refrigeration',
      'kitchen_equipment', 'fuel_petrol', 'transportation', 'technician_contractor',
      'building_facility', 'safety_equipment', 'it_network', 'general_supplies', 'other'
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
    if coalesce(requested_type, 'general') <> 'general'
      or (requested_scope is not null and requested_scope <> 'other')
      or requested_branch_id is not null
      or requested_destination is null then
      raise exception 'invalid maintenance purchase payload' using errcode = '22023';
    end if;
    target_organization := private.require_single_maintenance_purchase_organization(actor_user_id);
    target_branch := null;
    saved_type := 'general';
    saved_scope := 'other';
    saved_destination := requested_destination;
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
      purchase_id, target_organization, null, null, saved_type, saved_scope, saved_destination,
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
