begin;

alter table public.branch_purchase_logs
  add column if not exists source_type text,
  add column if not exists source_purchase_request_id uuid,
  add column if not exists source_purchase_request_item_id uuid;

alter table public.branch_purchase_logs
  drop constraint if exists branch_purchase_logs_category_check,
  add constraint branch_purchase_logs_category_check
    check (category in ('stationery','kitchen','equipment','food_item','other')),
  drop constraint if exists branch_purchase_logs_source_type_check,
  add constraint branch_purchase_logs_source_type_check
    check (source_type is null or source_type in ('central_purchasing')),
  drop constraint if exists branch_purchase_logs_source_pair_check,
  add constraint branch_purchase_logs_source_pair_check
    check (
      source_type is null
      or (source_purchase_request_id is not null and source_purchase_request_item_id is not null)
    ),
  drop constraint if exists branch_purchase_logs_source_request_fkey,
  add constraint branch_purchase_logs_source_request_fkey
    foreign key (source_purchase_request_id) references public.purchase_requests(id) on delete restrict,
  drop constraint if exists branch_purchase_logs_source_request_item_fkey,
  add constraint branch_purchase_logs_source_request_item_fkey
    foreign key (source_purchase_request_item_id) references public.purchase_request_items(id) on delete restrict;

drop index if exists branch_purchase_logs_central_purchasing_item_key;
create unique index branch_purchase_logs_central_purchasing_item_key
  on public.branch_purchase_logs(source_purchase_request_item_id)
  where source_type = 'central_purchasing'
    and source_purchase_request_item_id is not null;

create index if not exists branch_purchase_logs_source_request_idx
  on public.branch_purchase_logs(source_purchase_request_id)
  where source_type = 'central_purchasing';

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
        'purchase_log_id', log.id,
        'purchase_log_payment_status', log.payment_status,
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

drop function if exists public.list_branch_purchase_logs(uuid, uuid);

create function public.list_branch_purchase_logs(actor_user_id uuid,target_branch_id uuid)
returns table(
  id uuid,branch_id uuid,branch_name text,category text,item_name text,quantity numeric,
  amount numeric,before_tax_amount numeric,tax_amount numeric,
  vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,
  reimbursed_at timestamptz,reimbursed_by uuid,invoice_storage_path text,invoice_original_name text,
  invoice_number text,source_type text,source_purchase_request_id uuid,source_purchase_request_item_id uuid,
  created_by uuid,created_at timestamptz,updated_at timestamptz,revision bigint
)
language plpgsql
security definer
set search_path=''
as $$
declare
  c record;
begin
  select * into strict c from private.purchase_log_branch_context(actor_user_id,target_branch_id);
  return query
  select l.id,l.branch_id,b.name,l.category,l.item_name,l.quantity,l.amount,
    l.before_tax_amount,l.tax_amount,l.vendor_name,l.purchase_date,l.notes,
    l.payment_status,l.reimbursement_note,l.reimbursed_at,l.reimbursed_by,l.invoice_storage_path,
    l.invoice_original_name,l.invoice_number,l.source_type,l.source_purchase_request_id,l.source_purchase_request_item_id,
    l.created_by,l.created_at,l.updated_at,l.revision
  from public.branch_purchase_logs l
  join public.branches b on b.id=l.branch_id
  where l.organization_id=c.organization_id
    and l.branch_id=c.branch_id
    and l.deleted_at is null
  order by l.purchase_date desc,l.created_at desc;
exception when no_data_found or too_many_rows then
  raise exception 'purchase log access denied' using errcode='42501';
end
$$;

create or replace function public.create_branch_purchase_log(actor_user_id uuid,target_branch_id uuid,payload jsonb)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
  c record;
  clean_category text:=payload->>'category';
  clean_item text:=private.clean_purchase_text(payload->>'item_name',null,120);
  clean_vendor text:=private.clean_purchase_text(payload->>'vendor_name','N/A',120);
  clean_notes text:=private.clean_purchase_text(payload->>'notes',null,2000);
  clean_status text:=coalesce(nullif(payload->>'payment_status',''),'unpaid');
  clean_note text:=private.clean_purchase_text(payload->>'reimbursement_note',null,500);
  clean_path text:=private.clean_purchase_text(payload->>'invoice_storage_path',null,260);
  clean_name text:=private.clean_purchase_text(payload->>'invoice_original_name',null,180);
  clean_invoice_number text:=private.clean_purchase_text(payload->>'invoice_number',null,120);
  money_pattern constant text := '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$';
  raw_before text:=nullif(payload->>'before_tax_amount','');
  raw_tax text:=nullif(payload->>'tax_amount','');
  raw_amount text:=nullif(payload->>'amount','');
  q numeric;
  before_amount numeric;
  tax_amount_value numeric;
  amount_value numeric;
  has_breakdown boolean:=false;
  d date;
begin
  select * into strict c from private.purchase_log_branch_context(actor_user_id,target_branch_id);
  if clean_category not in('stationery','kitchen','equipment','food_item','other') or clean_status not in('unpaid','reimbursed') then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;

  begin
    q:=(payload->>'quantity')::numeric;
    d:=(payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end;
  if q<=0 or d is null then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;

  if raw_before is not null or raw_tax is not null then
    if raw_before is null or raw_tax is null then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    has_breakdown:=true;
  elsif raw_amount is not null then
    if raw_amount !~ money_pattern then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    amount_value:=raw_amount::numeric;
  else
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;

  if has_breakdown then
    if raw_before !~ money_pattern or raw_tax !~ money_pattern then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    before_amount:=raw_before::numeric;
    tax_amount_value:=raw_tax::numeric;
    amount_value:=before_amount+tax_amount_value;
  end if;
  if amount_value>9999999999.99 then
    raise exception 'invalid purchase log payload' using errcode='22023';
  end if;

  if has_breakdown and raw_amount is not null then
    if raw_amount !~ money_pattern then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
    amount_value:=raw_amount::numeric;
    if amount_value<>before_amount+tax_amount_value then
      raise exception 'invalid purchase log payload' using errcode='22023';
    end if;
  end if;

  return query insert into public.branch_purchase_logs(
    organization_id,branch_id,supervisor_team_id,category,item_name,quantity,amount,
    before_tax_amount,tax_amount,vendor_name,purchase_date,notes,payment_status,
    reimbursement_note,reimbursed_at,reimbursed_by,invoice_storage_path,invoice_original_name,
    invoice_number,created_by
  )
  values(
    c.organization_id,c.branch_id,c.legacy_team_id,clean_category,clean_item,q,amount_value,
    before_amount,tax_amount_value,clean_vendor,d,clean_notes,clean_status,
    clean_note,case when clean_status='reimbursed' then now() end,
    case when clean_status='reimbursed' then actor_user_id end,
    clean_path,clean_name,clean_invoice_number,actor_user_id
  )
  returning *;
exception when no_data_found or too_many_rows then
  raise exception 'purchase log access denied' using errcode='42501';
end
$$;

create or replace function public.update_branch_purchase_log_payment_status(actor_user_id uuid,target_branch_id uuid,target_purchase_log_id uuid,new_payment_status text,new_reimbursement_note text)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
 c record;
 existing public.branch_purchase_logs;
 updated public.branch_purchase_logs;
 clean_status text:=coalesce(nullif(new_payment_status,''),'unpaid');
 clean_note text:=private.clean_purchase_text(new_reimbursement_note,null,500);
begin
 select * into c from private.purchase_log_branch_context(actor_user_id,target_branch_id);
 if not found then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if clean_status not in('unpaid','reimbursed') then
  raise exception 'invalid payment status' using errcode='22023';
 end if;
 select * into existing from public.branch_purchase_logs l
 where l.id=target_purchase_log_id and l.organization_id=c.organization_id and l.branch_id=c.branch_id
 for update;
 if not found or existing.deleted_at is not null then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 update public.branch_purchase_logs l
 set payment_status=clean_status,
     reimbursement_note=clean_note,
     reimbursed_at=case when clean_status='reimbursed' then coalesce(l.reimbursed_at,statement_timestamp()) else null end,
     reimbursed_by=case when clean_status='reimbursed' then coalesce(l.reimbursed_by,actor_user_id) else null end,
     revision=l.revision+1
 where l.id=existing.id
 returning * into updated;
 insert into public.branch_purchase_log_events(purchase_log_id,organization_id,branch_id,event_type,actor_user_id,reason_code,reason_note,old_values,new_values)
 values(updated.id,updated.organization_id,updated.branch_id,'payment_status_changed',actor_user_id,'payment_status_change',null,private.branch_purchase_log_snapshot(existing),private.branch_purchase_log_snapshot(updated));
 return next updated;
end
$$;

create or replace function public.update_branch_purchase_log(
  actor_user_id uuid,target_branch_id uuid,target_purchase_log_id uuid,
  expected_revision bigint,correction_reason text,payload jsonb
)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
 c record;
 existing public.branch_purchase_logs;
 updated public.branch_purchase_logs;
 clean_reason text:=private.clean_purchase_reason(correction_reason);
 clean_category text:=payload->>'category';
 clean_item text:=private.clean_purchase_text(payload->>'item_name',null,120);
 clean_vendor text:=private.clean_purchase_text(payload->>'vendor_name','N/A',120);
 clean_notes text:=private.clean_purchase_text(payload->>'notes',null,2000);
 clean_invoice_number text:=private.clean_purchase_text(payload->>'invoice_number',null,120);
 money_pattern constant text := '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$';
 raw_before text:=nullif(payload->>'before_tax_amount','');
 raw_tax text:=nullif(payload->>'tax_amount','');
 raw_amount text:=nullif(payload->>'amount','');
 q numeric;
 before_amount numeric;
 tax_amount_value numeric;
 amount_value numeric;
 d date;
begin
 select * into c from private.purchase_log_branch_context(actor_user_id,target_branch_id);
 if not found then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if clean_reason is null or length(clean_reason)<10 or length(clean_reason)>500 then
  raise exception 'invalid purchase log correction reason' using errcode='22023';
 end if;
 if expected_revision is null or expected_revision<1 then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 if exists(select 1 from jsonb_object_keys(payload) as key where key not in('category','item_name','quantity','amount','before_tax_amount','tax_amount','vendor_name','purchase_date','invoice_number','notes')) then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 if clean_category not in('stationery','kitchen','equipment','food_item','other') then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 begin
  q:=(payload->>'quantity')::numeric;
  d:=(payload->>'purchase_date')::date;
 exception when others then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end;
 if q<=0 or d is null then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 if raw_before is null or raw_tax is null or raw_before !~ money_pattern or raw_tax !~ money_pattern then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 before_amount:=raw_before::numeric;
 tax_amount_value:=raw_tax::numeric;
 amount_value:=before_amount+tax_amount_value;
 if amount_value>9999999999.99 then
  raise exception 'invalid purchase log payload' using errcode='22023';
 end if;
 if raw_amount is not null then
  if raw_amount !~ money_pattern or raw_amount::numeric<>amount_value then
   raise exception 'invalid purchase log payload' using errcode='22023';
  end if;
 end if;
 select * into existing from public.branch_purchase_logs l
 where l.id=target_purchase_log_id and l.organization_id=c.organization_id and l.branch_id=c.branch_id
 for update;
 if not found or existing.deleted_at is not null then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if existing.source_type='central_purchasing' then
  raise exception 'central purchasing purchase logs are source managed' using errcode='55000';
 end if;
 if existing.revision<>expected_revision then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 if existing.payment_status<>'unpaid' then
  raise exception 'reimbursed purchase logs are read only' using errcode='55000';
 end if;
 update public.branch_purchase_logs l
 set category=clean_category,item_name=clean_item,quantity=q,amount=amount_value,
     before_tax_amount=before_amount,tax_amount=tax_amount_value,vendor_name=clean_vendor,
     purchase_date=d,invoice_number=clean_invoice_number,notes=clean_notes,revision=l.revision+1
 where l.id=existing.id
 returning * into updated;
 insert into public.branch_purchase_log_events(purchase_log_id,organization_id,branch_id,event_type,actor_user_id,reason_code,reason_note,old_values,new_values)
 values(updated.id,updated.organization_id,updated.branch_id,'edited',actor_user_id,'correction',clean_reason,private.branch_purchase_log_snapshot(existing),private.branch_purchase_log_snapshot(updated));
 return next updated;
end
$$;

create or replace function public.soft_delete_branch_purchase_log(
  actor_user_id uuid,target_branch_id uuid,target_purchase_log_id uuid,
  expected_revision bigint,delete_reason text,delete_reason_note text
)
returns setof public.branch_purchase_logs
language plpgsql
security definer
set search_path=''
as $$
declare
 c record;
 existing public.branch_purchase_logs;
 updated public.branch_purchase_logs;
 clean_reason text:=nullif(delete_reason,'');
 clean_note text:=private.clean_purchase_reason(delete_reason_note);
begin
 select * into c from private.purchase_log_branch_context(actor_user_id,target_branch_id);
 if not found then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if clean_reason not in('duplicate','wrong_entry','purchase_cancelled','other') then
  raise exception 'invalid delete reason' using errcode='22023';
 end if;
 if clean_note is not null and length(clean_note)>500 then
  raise exception 'invalid delete reason' using errcode='22023';
 end if;
 if clean_reason='other' and (clean_note is null or length(clean_note)<10) then
  raise exception 'invalid delete reason' using errcode='22023';
 end if;
 if expected_revision is null or expected_revision<1 then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 select * into existing from public.branch_purchase_logs l
 where l.id=target_purchase_log_id and l.organization_id=c.organization_id and l.branch_id=c.branch_id
 for update;
 if not found or existing.deleted_at is not null then
  raise exception 'purchase log access denied' using errcode='42501';
 end if;
 if existing.source_type='central_purchasing' then
  raise exception 'central purchasing purchase logs are source managed' using errcode='55000';
 end if;
 if existing.revision<>expected_revision then
  raise exception 'purchase log changed' using errcode='40001';
 end if;
 if existing.payment_status<>'unpaid' then
  raise exception 'reimbursed purchase logs are read only' using errcode='55000';
 end if;
 update public.branch_purchase_logs l
 set deleted_at=statement_timestamp(),deleted_by=actor_user_id,delete_reason=clean_reason,
     delete_reason_note=clean_note,revision=l.revision+1
 where l.id=existing.id
 returning * into updated;
 insert into public.branch_purchase_log_events(purchase_log_id,organization_id,branch_id,event_type,actor_user_id,reason_code,reason_note,old_values,new_values)
 values(updated.id,updated.organization_id,updated.branch_id,'soft_deleted',actor_user_id,clean_reason,clean_note,private.branch_purchase_log_snapshot(existing),private.branch_purchase_log_snapshot(updated));
 return next updated;
end
$$;

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
      perform private.apply_purchasing_purchase_request_details(v_request, purchase_details, true);
    end if;

    if exists (
      select 1
      from public.purchase_request_items item
      where item.purchase_request_id = v_request.id
        and (
          item.vendor_name is null
          or coalesce(item.total_amount, item.actual_total_cost) is null
        )
    ) then
      raise exception 'purchase details incomplete' using errcode = '22023';
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
      where source_type='central_purchasing' and source_purchase_request_item_id is not null
      do nothing;

      if not found then
        select * into v_log_before
        from public.branch_purchase_logs log
        where log.source_type='central_purchasing'
          and log.source_purchase_request_item_id=v_item.id
        for update;

        if v_log_before.source_purchase_request_id<>v_request.id
          or v_log_before.organization_id<>v_request.organization_id
          or v_log_before.branch_id<>v_request.branch_id
          or v_log_before.payment_status not in ('unpaid','reimbursed') then
          raise exception 'purchase log conflicts with current workflow state' using errcode='40001';
        end if;

        update public.branch_purchase_logs log
        set category=v_category,
            item_name=v_item.item_name,
            quantity=coalesce(v_item.purchased_quantity, v_item.quantity),
            amount=coalesce(v_item.total_amount, v_item.actual_total_cost),
            before_tax_amount=v_item.before_tax_amount,
            tax_amount=v_item.tax_amount,
            vendor_name=v_item.vendor_name,
            purchase_date=(statement_timestamp() at time zone 'Asia/Riyadh')::date,
            notes=v_item.purchasing_notes,
            invoice_number=v_item.invoice_number,
            revision=log.revision+1
        where log.id=v_log_before.id
        returning * into v_log_after;

        insert into public.branch_purchase_log_events(purchase_log_id,organization_id,branch_id,event_type,actor_user_id,reason_code,reason_note,old_values,new_values)
        values(v_log_after.id,v_log_after.organization_id,v_log_after.branch_id,'edited',actor_user_id,'correction',null,private.branch_purchase_log_snapshot(v_log_before),private.branch_purchase_log_snapshot(v_log_after));
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

drop function if exists public.list_managed_purchase_logs(uuid, uuid, uuid, text, text, date, date);

create function public.list_managed_purchase_logs(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  category_filter text default null,
  payment_status_filter text default null,
  date_from_filter date default null,
  date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, supervisor_team_id uuid, branch_name text,
  category text, item_name text, quantity numeric, amount numeric, before_tax_amount numeric,
  tax_amount numeric, vendor_name text, purchase_date date, notes text, payment_status text,
  reimbursement_note text, reimbursed_at timestamptz, reimbursed_by uuid, invoice_storage_path text,
  invoice_original_name text, invoice_number text, source_type text, source_purchase_request_id uuid,
  source_purchase_request_item_id uuid, created_by uuid, created_by_name text, created_at timestamptz,
  updated_at timestamptz, revision bigint
)
language plpgsql
security definer
set search_path=''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (branch_filter is not null and not exists (
      select 1 from public.branches managed_branch
      where managed_branch.id = branch_filter and managed_branch.organization_id = target_organization_id
    ))
    or category_filter is not null and category_filter not in ('stationery','kitchen','equipment','food_item','other')
    or payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed')
    or date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter then
    raise exception 'managed purchase log access denied' using errcode = '42501';
  end if;

  return query
  select log.id, log.organization_id, log.branch_id, log.supervisor_team_id, branch.name,
    log.category, log.item_name, log.quantity, log.amount, log.before_tax_amount,
    log.tax_amount, log.vendor_name, log.purchase_date, log.notes, log.payment_status,
    log.reimbursement_note, log.reimbursed_at, log.reimbursed_by, log.invoice_storage_path,
    log.invoice_original_name, log.invoice_number, log.source_type, log.source_purchase_request_id,
    log.source_purchase_request_item_id, log.created_by, creator.full_name, log.created_at,
    log.updated_at, log.revision
  from public.branch_purchase_logs log
  join public.branches branch on branch.id = log.branch_id
  left join public.profiles creator on creator.id = log.created_by
  where log.organization_id = target_organization_id
    and log.deleted_at is null
    and (branch_filter is null or log.branch_id = branch_filter)
    and (category_filter is null or log.category = category_filter)
    and (payment_status_filter is null or log.payment_status = payment_status_filter)
    and (date_from_filter is null or log.purchase_date >= date_from_filter)
    and (date_to_filter is null or log.purchase_date <= date_to_filter)
  order by log.purchase_date desc, log.created_at desc;
end
$$;

drop function if exists public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text);

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
  source_type text,
  source_purchase_request_id uuid,
  source_purchase_request_item_id uuid,
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
    log.source_type,
    log.source_purchase_request_id,
    log.source_purchase_request_item_id,
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

revoke all on function private.purchase_request_json(public.purchase_requests) from public, anon, authenticated;
revoke all on function private.apply_purchasing_purchase_request_details(public.purchase_requests, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.list_branch_purchase_logs(uuid,uuid) from public, anon, authenticated;
revoke all on function public.create_branch_purchase_log(uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text) from public, anon, authenticated;
revoke all on function public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb) from public, anon, authenticated;
revoke all on function public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.list_managed_purchase_logs(uuid, uuid, uuid, text, text, date, date) from public, anon, authenticated;
revoke all on function public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text) from public, anon, authenticated;

grant execute on function public.list_branch_purchase_logs(uuid,uuid) to service_role;
grant execute on function public.create_branch_purchase_log(uuid,uuid,jsonb) to service_role;
grant execute on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text) to service_role;
grant execute on function public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb) to service_role;
grant execute on function public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text) to service_role;
grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text, jsonb) to service_role;
grant execute on function public.set_purchasing_purchase_request_status(uuid, uuid, uuid, text) to service_role;
grant execute on function public.list_managed_purchase_logs(uuid, uuid, uuid, text, text, date, date) to service_role;
grant execute on function public.list_purchasing_purchase_logs(uuid, uuid, uuid, text, date, date, text) to service_role;

commit;
