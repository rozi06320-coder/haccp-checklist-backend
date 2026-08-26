alter table public.maintenance_purchase_logs
  alter column branch_id drop not null,
  alter column maintenance_issue_id drop not null,
  add column if not exists purchase_type text,
  add column if not exists purchase_scope text,
  add column if not exists destination text,
  add column if not exists category text;

alter table public.maintenance_purchase_attachments
  alter column branch_id drop not null;

update public.maintenance_purchase_logs p
set
  purchase_type = coalesce(p.purchase_type, 'issue'),
  purchase_scope = coalesce(p.purchase_scope, case when p.branch_id is null then 'office' else 'branch' end),
  destination = case
    when coalesce(p.purchase_scope, case when p.branch_id is null then 'office' else 'branch' end) = 'office' then coalesce(nullif(pg_catalog.btrim(p.destination), ''), 'Office')
    else p.destination
  end,
  category = coalesce(p.category, 'other')
where p.purchase_type is null
  or p.purchase_scope is null
  or p.category is null
  or (p.branch_id is null and nullif(pg_catalog.btrim(coalesce(p.destination, '')), '') is null);

alter table public.maintenance_purchase_logs
  alter column purchase_type set not null,
  alter column purchase_scope set not null,
  alter column category set not null;

alter table public.maintenance_purchase_logs
  drop constraint if exists maintenance_purchase_type_check,
  drop constraint if exists maintenance_purchase_scope_check,
  drop constraint if exists maintenance_purchase_destination_check,
  drop constraint if exists maintenance_purchase_category_check,
  add constraint maintenance_purchase_type_check check (
    (purchase_type = 'issue' and maintenance_issue_id is not null)
    or (purchase_type = 'general' and maintenance_issue_id is null and branch_id is null and purchase_scope = 'other' and destination is not null)
  ),
  add constraint maintenance_purchase_scope_check check (
    (purchase_scope = 'branch' and branch_id is not null)
    or (purchase_scope = 'office' and branch_id is null)
    or (purchase_scope = 'other' and branch_id is null and destination is not null)
  ),
  add constraint maintenance_purchase_destination_check check (
    destination is null or (destination = pg_catalog.btrim(destination) and length(destination) between 1 and 120)
  ),
  add constraint maintenance_purchase_category_check check (
    category in (
      'spare_parts','tools_equipment','electrical','plumbing','hvac_refrigeration','kitchen_equipment',
      'fuel_petrol','transportation','technician_contractor','building_facility','safety_equipment',
      'it_network','general_supplies','other'
    )
  );

create index if not exists maintenance_purchase_history_scope_idx
  on public.maintenance_purchase_logs(organization_id,purchase_scope,purchase_date desc,created_at desc);

create index if not exists maintenance_purchase_history_type_idx
  on public.maintenance_purchase_logs(organization_id,purchase_type,purchase_date desc,created_at desc);

create or replace function private.enforce_maintenance_purchase_attachment_scope()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  purchase public.maintenance_purchase_logs%rowtype;
begin
  select p.* into purchase from public.maintenance_purchase_logs p where p.id=new.purchase_id;
  if purchase.id is null
    or purchase.organization_id<>new.organization_id
    or purchase.branch_id is distinct from new.branch_id then
    raise exception 'invalid maintenance purchase attachment scope' using errcode='23514';
  end if;
  return new;
end;
$$;

create or replace function private.require_single_maintenance_purchase_organization(actor_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  target_organization uuid;
begin
  select membership.organization_id into strict target_organization
  from public.maintenance_memberships membership
  join public.organizations organization on organization.id=membership.organization_id
  join public.profiles profile on profile.id=membership.user_id
  where membership.user_id=actor_user_id
    and membership.active
    and organization.active
    and profile.disabled_at is null
    and not profile.must_change_password;
  return target_organization;
exception when no_data_found or too_many_rows then
  raise exception 'maintenance purchase access denied' using errcode='42501';
end;
$$;

drop function if exists public.list_maintenance_purchase_logs(uuid,uuid);
drop function if exists public.create_maintenance_purchase_log(uuid,uuid,jsonb);
drop function if exists public.reimburse_maintenance_purchase_log(uuid,uuid,text);
drop function if exists public.list_maintenance_purchase_history(uuid);
drop function if exists public.list_maintenance_purchase_history(uuid,text);
drop function if exists public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date);
drop function if exists public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date,text);
drop function if exists public.list_maintenance_purchase_branches(uuid);

create or replace function public.list_maintenance_purchase_branches(actor_user_id uuid)
returns table(id uuid,name text,name_ar text)
language plpgsql
security definer
set search_path=''
as $$
begin
  return query
    select branch.id,branch.name,branch.name_ar
    from public.maintenance_memberships membership
    join public.organizations organization on organization.id=membership.organization_id
    join public.profiles profile on profile.id=membership.user_id
    join public.branches branch on branch.organization_id=membership.organization_id
    where membership.user_id=actor_user_id
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
      and branch.active
    order by branch.name;
end;
$$;

create or replace function public.list_maintenance_purchase_logs(actor_user_id uuid,target_issue_id uuid)
returns table(id uuid,branch_id uuid,purchase_type text,purchase_scope text,destination text,category text,item_name text,quantity numeric,unit text,amount numeric,vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,reimbursed_at timestamptz,receipt_storage_path text,receipt_original_name text,attachments jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql
security definer
set search_path=''
as $$
declare
  issue public.maintenance_issues%rowtype;
begin
  issue:=private.require_maintenance_purchase_issue(actor_user_id,target_issue_id);
  return query
    select p.id,p.branch_id,p.purchase_type,p.purchase_scope,p.destination,p.category,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    where p.maintenance_issue_id=issue.id
      and p.purchase_type='issue'
    order by p.purchase_date desc,p.created_at desc;
end;
$$;

create or replace function public.create_maintenance_purchase_log(actor_user_id uuid,target_issue_id uuid,payload jsonb)
returns table(id uuid,organization_id uuid,branch_id uuid,maintenance_issue_id uuid,purchase_type text,purchase_scope text,destination text,category text,maintenance_user_id uuid,item_name text,quantity numeric,unit text,amount numeric,vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,reimbursed_at timestamptz,receipt_storage_path text,receipt_original_name text,attachments jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql
security definer
set search_path=''
as $$
declare
  issue public.maintenance_issues%rowtype;
  branch public.branches%rowtype;
  item text:=private.clean_purchase_text(payload->>'item_name',null,120);
  vendor text:=private.clean_purchase_text(payload->>'vendor_name','N/A',120);
  notes_value text:=private.clean_purchase_text(payload->>'notes',null,2000);
  path text:=private.clean_purchase_text(payload->>'receipt_storage_path',null,260);
  filename text:=private.clean_purchase_text(payload->>'receipt_original_name',null,180);
  purchase_unit text:=private.clean_purchase_text(payload->>'unit',null,20);
  requested_scope text:=private.clean_purchase_text(payload->>'purchase_scope',null,20);
  requested_destination text:=private.clean_purchase_text(payload->>'destination',null,120);
  requested_branch_id uuid;
  requested_type text:=private.clean_purchase_text(payload->>'purchase_type',null,20);
  purchase_id uuid;
  target_organization uuid;
  target_branch uuid;
  saved_type text;
  saved_scope text;
  saved_destination text;
  purchase_category text:=private.clean_purchase_text(payload->>'category',null,40);
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
begin
  begin
    purchase_id:=coalesce(nullif(payload->>'purchase_id','')::uuid,gen_random_uuid());
    requested_branch_id:=nullif(payload->>'branch_id','')::uuid;
    qty:=(payload->>'quantity')::numeric;
    cost:=(payload->>'amount')::numeric;
    day:=(payload->>'purchase_date')::date;
  exception when others then
    raise exception 'invalid maintenance purchase payload' using errcode='22023';
  end;

  if item is null or qty<=0 or cost<0 or day is null or purchase_unit not in ('pcs','meter','kg','box','bag','roll','set','liter','other')
    or purchase_category not in ('spare_parts','tools_equipment','electrical','plumbing','hvac_refrigeration','kitchen_equipment','fuel_petrol','transportation','technician_contractor','building_facility','safety_equipment','it_network','general_supplies','other') then
    raise exception 'invalid maintenance purchase payload' using errcode='22023';
  end if;

  if target_issue_id is not null then
    if requested_type is not null and requested_type<>'issue' then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end if;
    issue:=private.require_maintenance_purchase_issue(actor_user_id,target_issue_id);
    target_organization:=issue.organization_id;
    saved_type:='issue';
    if issue.location_scope='office' or issue.branch_id is null then
      saved_scope:='office';
      target_branch:=null;
      saved_destination:='Office';
    else
      saved_scope:='branch';
      target_branch:=issue.branch_id;
      saved_destination:=null;
    end if;
  else
    if coalesce(requested_type,'general')<>'general' then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end if;
    if requested_scope is not null and requested_scope<>'other' then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end if;
    if requested_branch_id is not null or requested_destination is null then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end if;
    target_organization:=private.require_single_maintenance_purchase_organization(actor_user_id);
    target_branch:=null;
    saved_type:='general';
    saved_scope:='other';
    saved_destination:=requested_destination;
  end if;

  if coalesce(jsonb_typeof(payload->'attachments'),'array')<>'array' then
    raise exception 'invalid maintenance purchase payload' using errcode='22023';
  end if;
  attachment_count:=jsonb_array_length(coalesce(payload->'attachments','[]'::jsonb));
  if attachment_count>3 then
    raise exception 'too many maintenance purchase attachments' using errcode='22023';
  end if;
  if attachment_count>0 then
    path:=coalesce(path,private.clean_purchase_text(payload->'attachments'->0->>'storage_path',null,260));
    filename:=coalesce(filename,private.clean_purchase_text(payload->'attachments'->0->>'original_filename',null,180));
  end if;

  insert into public.maintenance_purchase_logs(id,organization_id,branch_id,maintenance_issue_id,purchase_type,purchase_scope,destination,category,maintenance_user_id,item_name,quantity,unit,amount,vendor_name,purchase_date,notes,receipt_storage_path,receipt_original_name)
  values(purchase_id,target_organization,target_branch,target_issue_id,saved_type,saved_scope,saved_destination,purchase_category,actor_user_id,item,qty,purchase_unit,cost,vendor,day,notes_value,path,filename);

  for attachment, attachment_position in
    select value, ordinality::integer from jsonb_array_elements(coalesce(payload->'attachments','[]'::jsonb)) with ordinality
  loop
    begin
      attachment_path:=private.clean_purchase_text(attachment->>'storage_path',null,260);
      attachment_name:=private.clean_purchase_text(attachment->>'original_filename',null,180);
      attachment_mime:=private.clean_purchase_text(attachment->>'mime_type',null,80);
      attachment_size:=(attachment->>'size_bytes')::bigint;
    exception when others then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end;
    if attachment_path is null or attachment_position not between 1 and 3 or attachment_mime not in ('image/jpeg','image/png','image/webp','application/pdf') or attachment_size<=0 or attachment_size>5242880 then
      raise exception 'invalid maintenance purchase payload' using errcode='22023';
    end if;
    insert into public.maintenance_purchase_attachments(id,purchase_id,organization_id,branch_id,storage_path,original_filename,mime_type,size_bytes,position,uploaded_by)
    values(coalesce(nullif(attachment->>'id','')::uuid,gen_random_uuid()),purchase_id,target_organization,target_branch,attachment_path,attachment_name,attachment_mime,attachment_size,attachment_position,actor_user_id);
  end loop;

  return query
    select p.id,p.organization_id,p.branch_id,p.maintenance_issue_id,p.purchase_type,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    where p.id=purchase_id;
end;
$$;

create or replace function public.reimburse_maintenance_purchase_log(actor_user_id uuid,target_purchase_id uuid,new_note text)
returns table(id uuid,organization_id uuid,branch_id uuid,maintenance_issue_id uuid,purchase_type text,purchase_scope text,destination text,category text,maintenance_user_id uuid,item_name text,quantity numeric,unit text,amount numeric,vendor_name text,purchase_date date,notes text,payment_status text,reimbursement_note text,reimbursed_at timestamptz,receipt_storage_path text,receipt_original_name text,attachments jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql
security definer
set search_path=''
as $$
declare
  clean_note text:=private.clean_purchase_text(new_note,null,500);
  changed_id uuid;
begin
  update public.maintenance_purchase_logs p
    set payment_status='reimbursed',reimbursement_note=clean_note,reimbursed_at=coalesce(p.reimbursed_at,now())
    where p.id=target_purchase_id and p.payment_status='unpaid' and private.actor_can_maintain_organization(actor_user_id,null,p.organization_id)
    returning p.id into changed_id;
  if changed_id is null then
    raise exception 'maintenance purchase access denied' using errcode='42501';
  end if;
  return query
    select p.id,p.organization_id,p.branch_id,p.maintenance_issue_id,p.purchase_type,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    where p.id=changed_id;
end;
$$;

create or replace function public.list_maintenance_purchase_history(actor_user_id uuid,purchase_type_filter text)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, maintenance_issue_id uuid, purchase_type text,
  issue_title text, issue_category text, issue_status text, purchase_scope text, destination text,
  category text, maintenance_user_id uuid, maintenance_user_name text, item_name text, quantity numeric,
  unit text, amount numeric, vendor_name text, purchase_date date, notes text, payment_status text,
  reimbursement_note text, reimbursed_at timestamptz, receipt_storage_path text, receipt_original_name text,
  attachments jsonb, created_at timestamptz, updated_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
begin
  if purchase_type_filter not in ('issue','general') then
    raise exception 'maintenance purchase history access denied' using errcode='42501';
  end if;
  if not private.actor_has_active_maintenance_membership(actor_user_id,null) then
    raise exception 'maintenance purchase history access denied' using errcode='42501';
  end if;

  return query
    select p.id,p.organization_id,p.branch_id,
      case when p.purchase_scope='branch' then branch.name when p.purchase_scope='office' then 'Office' else p.destination end,
      p.maintenance_issue_id,p.purchase_type,issue.title,issue.category,issue.status,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,
      profile.full_name,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,
      p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    left join public.maintenance_issues issue on issue.id=p.maintenance_issue_id
    left join public.branches branch on branch.id=p.branch_id
    left join public.profiles profile on profile.id=p.maintenance_user_id
    where p.purchase_type=purchase_type_filter
    and exists(
      select 1
      from public.maintenance_memberships membership
      join public.organizations organization on organization.id=membership.organization_id
      join public.profiles actor_profile on actor_profile.id=membership.user_id
      where membership.user_id=actor_user_id
        and membership.organization_id=p.organization_id
        and membership.active
        and organization.active
        and actor_profile.disabled_at is null
        and not actor_profile.must_change_password
    )
    order by p.purchase_date desc,p.created_at desc
    limit 1000;
end;
$$;

create or replace function public.list_managed_maintenance_purchases(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  issue_status_filter text default null, payment_status_filter text default null,
  vendor_filter text default null, date_from_filter date default null, date_to_filter date default null,
  purchase_type_filter text default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, maintenance_issue_id uuid, purchase_type text,
  issue_title text, issue_category text, issue_status text, purchase_scope text, destination text,
  category text, maintenance_user_id uuid, maintenance_user_name text, item_name text, quantity numeric,
  unit text, amount numeric, vendor_name text, purchase_date date, notes text, payment_status text,
  reimbursement_note text, reimbursed_at timestamptz, receipt_storage_path text, receipt_original_name text,
  attachments jsonb, created_at timestamptz, updated_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or (branch_filter is not null and not exists(select 1 from public.branches b where b.id=branch_filter and b.organization_id=target_organization_id))
    or (issue_status_filter is not null and issue_status_filter not in ('new','in_progress','waiting_parts','resolved','closed'))
    or (payment_status_filter is not null and payment_status_filter not in ('unpaid','reimbursed'))
    or (purchase_type_filter is not null and purchase_type_filter not in ('issue','general'))
    or (date_from_filter is not null and date_to_filter is not null and date_from_filter>date_to_filter) then
    raise exception 'maintenance purchase access denied' using errcode='42501';
  end if;
  return query
    select p.id,p.organization_id,p.branch_id,
      case when p.purchase_scope='branch' then branch.name when p.purchase_scope='office' then 'Office' else p.destination end,
      p.maintenance_issue_id,p.purchase_type,issue.title,issue.category,issue.status,p.purchase_scope,p.destination,p.category,p.maintenance_user_id,
      profile.full_name,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,
      p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    left join public.maintenance_issues issue on issue.id=p.maintenance_issue_id
    left join public.branches branch on branch.id=p.branch_id
    left join public.profiles profile on profile.id=p.maintenance_user_id
    where p.organization_id=target_organization_id
      and (branch_filter is null or p.branch_id=branch_filter)
      and (purchase_type_filter is null or p.purchase_type=purchase_type_filter)
      and (issue_status_filter is null or issue.status=issue_status_filter)
      and (payment_status_filter is null or p.payment_status=payment_status_filter)
      and (vendor_filter is null or p.vendor_name ilike '%'||vendor_filter||'%')
      and (date_from_filter is null or p.purchase_date>=date_from_filter)
      and (date_to_filter is null or p.purchase_date<=date_to_filter)
    order by p.purchase_date desc,p.created_at desc;
end;
$$;

revoke all on function private.enforce_maintenance_purchase_attachment_scope() from public,anon,authenticated;
revoke all on function private.require_single_maintenance_purchase_organization(uuid) from public,anon,authenticated;
revoke all on function public.list_maintenance_purchase_branches(uuid) from public,anon,authenticated;
revoke all on function public.list_maintenance_purchase_logs(uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_maintenance_purchase_log(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.reimburse_maintenance_purchase_log(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.list_maintenance_purchase_history(uuid,text) from public,anon,authenticated;
revoke all on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date,text) from public,anon,authenticated;

grant execute on function private.enforce_maintenance_purchase_attachment_scope() to service_role;
grant execute on function private.require_single_maintenance_purchase_organization(uuid) to service_role;
grant execute on function public.list_maintenance_purchase_branches(uuid) to service_role;
grant execute on function public.list_maintenance_purchase_logs(uuid,uuid) to service_role;
grant execute on function public.create_maintenance_purchase_log(uuid,uuid,jsonb) to service_role;
grant execute on function public.reimburse_maintenance_purchase_log(uuid,uuid,text) to service_role;
grant execute on function public.list_maintenance_purchase_history(uuid,text) to service_role;
grant execute on function public.list_managed_maintenance_purchases(uuid,uuid,uuid,text,text,text,date,date,text) to service_role;
