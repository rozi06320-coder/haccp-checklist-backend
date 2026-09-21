begin;

alter table public.branch_purchase_logs
  alter column supervisor_team_id drop not null;

-- Purchase Log is branch-owned. Legacy supervisor-team rows are retained only as
-- optional historical attribution for rows created before the modern branch
-- membership/canonical operational-team model.
create or replace function private.purchase_log_branch_context(actor uuid,target_branch uuid)
returns table(
  organization_id uuid,
  branch_id uuid,
  legacy_team_id uuid,
  business_date date,
  branch_name text,
  branch_code text,
  actor_name text
)
language sql
stable
security definer
set search_path=''
as $$
  select b.organization_id,b.id,t.id,private.phase4a_business_date(b.timezone),b.name,b.code,p.full_name
  from public.profiles p
  join public.branch_memberships m
    on m.user_id=p.id
   and m.branch_id=target_branch
   and m.role='branch_manager'
   and m.active
  join public.branches b on b.id=m.branch_id and b.active
  join public.organizations o on o.id=b.organization_id and o.active
  left join lateral (
    select legacy.id
    from public.branch_supervisor_teams legacy
    where legacy.branch_id=b.id
      and legacy.organization_id=b.organization_id
      and legacy.supervisor_user_id=p.id
    order by legacy.active desc,legacy.created_at,legacy.id
    limit 1
  ) t on true
  where p.id=actor
    and p.disabled_at is null
    and not p.must_change_password
$$;

revoke all on function private.purchase_log_branch_context(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function private.purchase_log_branch_context(uuid,uuid) to service_role;

drop function public.list_branch_purchase_logs(uuid, uuid);

create function public.list_branch_purchase_logs(actor_user_id uuid,target_branch_id uuid)
returns table(
  id uuid,branch_id uuid,branch_name text,category text,item_name text,quantity numeric,
  amount numeric,before_tax_amount numeric,tax_amount numeric,
  vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,
  reimbursed_at timestamptz,reimbursed_by uuid,invoice_storage_path text,invoice_original_name text,
  invoice_number text,created_by uuid,created_at timestamptz,updated_at timestamptz,revision bigint
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
    l.invoice_original_name,l.invoice_number,l.created_by,l.created_at,l.updated_at,l.revision
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
  if clean_category not in('stationery','kitchen','equipment','food_item') or clean_status not in('unpaid','reimbursed') then
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
 if clean_category not in('stationery','kitchen','equipment','food_item') then
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

revoke all on function public.list_branch_purchase_logs(uuid,uuid) from public, anon, authenticated;
grant execute on function public.list_branch_purchase_logs(uuid,uuid) to service_role;
revoke all on function public.create_branch_purchase_log(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.create_branch_purchase_log(uuid,uuid,jsonb) to service_role;
revoke all on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.update_branch_purchase_log_payment_status(uuid,uuid,uuid,text,text) to service_role;
revoke all on function public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb) from public, anon, authenticated;
grant execute on function public.update_branch_purchase_log(uuid,uuid,uuid,bigint,text,jsonb) to service_role;
revoke all on function public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text) from public, anon, authenticated;
grant execute on function public.soft_delete_branch_purchase_log(uuid,uuid,uuid,bigint,text,text) to service_role;

commit;
