alter table public.maintenance_purchase_logs
  add column if not exists idempotency_key uuid,
  add column if not exists request_hash text,
  add column if not exists reimbursed_by uuid references public.profiles(id) on delete restrict;

alter table public.maintenance_purchase_logs
  drop constraint if exists maintenance_purchase_logs_request_hash_check;
alter table public.maintenance_purchase_logs
  add constraint maintenance_purchase_logs_request_hash_check check (
    (idempotency_key is null and request_hash is null)
    or (idempotency_key is not null and request_hash ~ '^[0-9a-f]{64}$')
  );

create unique index maintenance_purchase_issue_idempotency_key_idx
on public.maintenance_purchase_logs(organization_id, maintenance_issue_id, idempotency_key)
where purchase_type = 'issue' and idempotency_key is not null;

create unique index maintenance_purchase_general_idempotency_key_idx
on public.maintenance_purchase_logs(organization_id, idempotency_key)
where purchase_type = 'general' and idempotency_key is not null;

create table if not exists public.maintenance_purchase_events (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.maintenance_purchase_logs(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  event_type text not null,
  previous_payment_status text not null,
  new_payment_status text not null,
  actor_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  constraint maintenance_purchase_events_type_check check (event_type = 'reimbursed'),
  constraint maintenance_purchase_events_status_check check (
    previous_payment_status = 'unpaid' and new_payment_status = 'reimbursed'
  ),
  constraint maintenance_purchase_events_one_reimbursement_key unique(purchase_id, event_type)
);

create index if not exists maintenance_purchase_events_org_created_idx
on public.maintenance_purchase_events(organization_id, created_at desc);

alter table public.maintenance_purchase_events enable row level security;
revoke all on table public.maintenance_purchase_events from public, anon, authenticated, service_role;

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

create or replace function public.resolve_maintenance_purchase_scope(
  actor_user_id uuid,
  target_issue_id uuid
)
returns table(organization_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare issue public.maintenance_issues%rowtype;
begin
  if target_issue_id is not null then
    issue := private.require_maintenance_purchase_issue(actor_user_id, target_issue_id);
    return query select issue.organization_id;
  else
    return query select private.require_single_maintenance_purchase_organization(actor_user_id);
  end if;
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
  attachment_path text;
  attachment_name text;
  attachment_mime text;
  attachment_size bigint;
  saved public.maintenance_purchase_logs%rowtype;
  inserted boolean := false;
begin
  begin
    purchase_id := coalesce(nullif(payload->>'purchase_id', '')::uuid, gen_random_uuid());
    requested_branch_id := nullif(payload->>'branch_id', '')::uuid;
    request_idempotency_key := nullif(payload->>'idempotency_key', '')::uuid;
    qty := (payload->>'quantity')::numeric;
    cost := (payload->>'amount')::numeric;
    day := (payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid maintenance purchase payload' using errcode = '22023';
  end;

  request_fingerprint := nullif(payload->>'request_hash', '');
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
        coalesce(nullif(attachment->>'id', '')::uuid, gen_random_uuid()), purchase_id,
        target_organization, target_branch, attachment_path, attachment_name,
        attachment_mime, attachment_size, attachment_position, actor_user_id
      );
    end loop;
  end if;

  return next private.maintenance_purchase_json(saved);
end;
$$;

create or replace function public.reimburse_maintenance_purchase_log_v2(
  actor_user_id uuid,
  target_purchase_id uuid,
  new_note text
)
returns setof jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_note text := private.clean_purchase_text(new_note, null, 500);
  purchase public.maintenance_purchase_logs%rowtype;
begin
  select purchase_row.* into purchase
  from public.maintenance_purchase_logs purchase_row
  where purchase_row.id = target_purchase_id
  for update;

  if purchase.id is null
    or not private.actor_can_maintain_organization(actor_user_id, null, purchase.organization_id) then
    raise exception 'maintenance purchase access denied' using errcode = '42501';
  end if;
  if purchase.payment_status <> 'unpaid' then
    raise exception 'maintenance purchase already reimbursed' using errcode = '40001';
  end if;

  update public.maintenance_purchase_logs purchase_row
  set payment_status = 'reimbursed',
      reimbursement_note = clean_note,
      reimbursed_at = statement_timestamp(),
      reimbursed_by = actor_user_id
  where purchase_row.id = purchase.id
  returning * into purchase;

  insert into public.maintenance_purchase_events(
    purchase_id, organization_id, event_type, previous_payment_status,
    new_payment_status, actor_user_id
  ) values (
    purchase.id, purchase.organization_id, 'reimbursed', 'unpaid', 'reimbursed', actor_user_id
  );

  return next private.maintenance_purchase_json(purchase);
end;
$$;

create or replace function public.reimburse_maintenance_purchase_log(
  actor_user_id uuid, target_purchase_id uuid, new_note text
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, maintenance_issue_id uuid, purchase_type text,
  purchase_scope text, destination text, category text, maintenance_user_id uuid, item_name text,
  quantity numeric, unit text, amount numeric, vendor_name text, purchase_date date, notes text,
  payment_status text, payment_method text, reimbursement_note text, reimbursed_at timestamptz,
  receipt_storage_path text, receipt_original_name text, attachments jsonb,
  created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare result jsonb;
begin
  select value into result
  from public.reimburse_maintenance_purchase_log_v2(actor_user_id, target_purchase_id, new_note) value;
  return query select record.*
  from jsonb_to_record(result) as record(
    id uuid, organization_id uuid, branch_id uuid, maintenance_issue_id uuid, purchase_type text,
    purchase_scope text, destination text, category text, maintenance_user_id uuid, item_name text,
    quantity numeric, unit text, amount numeric, vendor_name text, purchase_date date, notes text,
    payment_status text, payment_method text, reimbursement_note text, reimbursed_at timestamptz,
    receipt_storage_path text, receipt_original_name text, attachments jsonb,
    created_at timestamptz, updated_at timestamptz
  );
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

drop trigger if exists maintenance_purchase_financial_immutability on public.maintenance_purchase_logs;
create trigger maintenance_purchase_financial_immutability
before update on public.maintenance_purchase_logs
for each row execute function private.enforce_maintenance_purchase_financial_immutability();

create or replace function private.enforce_reimbursed_maintenance_purchase_attachment_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and exists (
    select 1 from public.maintenance_purchase_logs purchase
    where purchase.id = old.purchase_id and purchase.payment_status = 'reimbursed'
  ) then
    raise exception 'reimbursed maintenance purchase evidence is immutable' using errcode = '55000';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and exists (
    select 1 from public.maintenance_purchase_logs purchase
    where purchase.id = new.purchase_id and purchase.payment_status = 'reimbursed'
  ) then
    raise exception 'reimbursed maintenance purchase evidence is immutable' using errcode = '55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists maintenance_purchase_attachment_financial_immutability
on public.maintenance_purchase_attachments;
create trigger maintenance_purchase_attachment_financial_immutability
before insert or update or delete on public.maintenance_purchase_attachments
for each row execute function private.enforce_reimbursed_maintenance_purchase_attachment_immutability();

create or replace function public.get_maintenance_purchase_history_page(
  actor_user_id uuid,
  purchase_type_filter text default null,
  requested_page integer default 1,
  requested_page_size integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  total_rows bigint;
  purchases jsonb;
begin
  if purchase_type_filter is not null and purchase_type_filter not in ('issue', 'general', 'all') then
    raise exception 'invalid maintenance purchase history filter' using errcode = '22023';
  end if;
  if requested_page < 1 or requested_page_size < 1 or requested_page_size > 200 then
    raise exception 'invalid maintenance purchase pagination' using errcode = '22023';
  end if;
  if not private.actor_has_active_maintenance_membership(actor_user_id, null) then
    raise exception 'maintenance purchase history access denied' using errcode = '42501';
  end if;

  select count(*) into total_rows
  from public.maintenance_purchase_logs purchase_row
  where (purchase_type_filter is null or purchase_type_filter = 'all' or purchase_row.purchase_type = purchase_type_filter)
    and exists (
      select 1
      from public.maintenance_memberships membership
      join public.organizations organization on organization.id = membership.organization_id
      join public.profiles profile on profile.id = membership.user_id
      where membership.user_id = actor_user_id
        and membership.organization_id = purchase_row.organization_id
        and membership.active and organization.active
        and profile.disabled_at is null and not profile.must_change_password
    );

  select coalesce(jsonb_agg(
    private.maintenance_purchase_json(page.purchase)
    || jsonb_build_object(
      'branch_name', case
        when (page.purchase).purchase_scope = 'branch' then page.branch_name
        when (page.purchase).purchase_scope = 'office' then 'Office'
        else (page.purchase).destination
      end,
      'issue_title', page.issue_title,
      'issue_category', page.issue_category,
      'issue_status', page.issue_status,
      'responsible_person_name', page.responsible_person_name,
      'maintenance_user_name', page.maintenance_user_name
    ) order by (page.purchase).purchase_date desc, (page.purchase).created_at desc, (page.purchase).id
  ), '[]'::jsonb) into purchases
  from (
    select purchase_row as purchase, branch.name as branch_name, issue.title as issue_title,
      issue.category as issue_category, issue.status as issue_status,
      issue.responsible_person_name, profile.full_name as maintenance_user_name
    from public.maintenance_purchase_logs purchase_row
    left join public.branches branch on branch.id = purchase_row.branch_id
    left join public.maintenance_issues issue on issue.id = purchase_row.maintenance_issue_id
    left join public.profiles profile on profile.id = purchase_row.maintenance_user_id
    where (purchase_type_filter is null or purchase_type_filter = 'all' or purchase_row.purchase_type = purchase_type_filter)
      and exists (
        select 1
        from public.maintenance_memberships membership
        join public.organizations organization on organization.id = membership.organization_id
        join public.profiles actor_profile on actor_profile.id = membership.user_id
        where membership.user_id = actor_user_id
          and membership.organization_id = purchase_row.organization_id
          and membership.active and organization.active
          and actor_profile.disabled_at is null and not actor_profile.must_change_password
      )
    order by purchase_row.purchase_date desc, purchase_row.created_at desc, purchase_row.id
    limit requested_page_size
    offset (requested_page - 1) * requested_page_size
  ) page;

  return jsonb_build_object(
    'maintenance_purchases', purchases,
    'page', requested_page,
    'page_size', requested_page_size,
    'total_count', total_rows,
    'has_more', requested_page * requested_page_size < total_rows
  );
end;
$$;

create or replace function public.get_managed_maintenance_purchase_receipt_metadata(
  actor_user_id uuid,
  target_organization_id uuid,
  target_purchase_id uuid,
  target_attachment_id uuid default null
)
returns table(storage_path text, original_filename text)
language plpgsql
security definer
set search_path = ''
as $$
declare purchase public.maintenance_purchase_logs%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'managed maintenance purchase access denied' using errcode = '42501';
  end if;
  select purchase_row.* into purchase
  from public.maintenance_purchase_logs purchase_row
  where purchase_row.id = target_purchase_id
    and purchase_row.organization_id = target_organization_id;
  if purchase.id is null then return; end if;

  if target_attachment_id is not null then
    return query
      select attachment.storage_path, attachment.original_filename
      from public.maintenance_purchase_attachments attachment
      where attachment.id = target_attachment_id
        and attachment.purchase_id = purchase.id
        and attachment.organization_id = target_organization_id;
  else
    return query
      select coalesce(attachment.storage_path, purchase.receipt_storage_path),
        coalesce(attachment.original_filename, purchase.receipt_original_name)
      from (select 1) seed
      left join lateral (
        select item.storage_path, item.original_filename
        from public.maintenance_purchase_attachments item
        where item.purchase_id = purchase.id
          and item.organization_id = target_organization_id
        order by item.position
        limit 1
      ) attachment on true
      where coalesce(attachment.storage_path, purchase.receipt_storage_path) is not null;
  end if;
end;
$$;

revoke all on function private.maintenance_purchase_json(public.maintenance_purchase_logs) from public, anon, authenticated, service_role;
revoke all on function private.enforce_maintenance_purchase_financial_immutability() from public, anon, authenticated, service_role;
revoke all on function private.enforce_reimbursed_maintenance_purchase_attachment_immutability() from public, anon, authenticated, service_role;
revoke all on function public.resolve_maintenance_purchase_scope(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_maintenance_purchase_log_v2(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.reimburse_maintenance_purchase_log_v2(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.get_maintenance_purchase_history_page(uuid, text, integer, integer) from public, anon, authenticated;
revoke all on function public.get_managed_maintenance_purchase_receipt_metadata(uuid, uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.resolve_maintenance_purchase_scope(uuid, uuid) to service_role;
grant execute on function public.create_maintenance_purchase_log_v2(uuid, uuid, jsonb) to service_role;
grant execute on function public.reimburse_maintenance_purchase_log_v2(uuid, uuid, text) to service_role;
grant execute on function public.get_maintenance_purchase_history_page(uuid, text, integer, integer) to service_role;
grant execute on function public.get_managed_maintenance_purchase_receipt_metadata(uuid, uuid, uuid, uuid) to service_role;
