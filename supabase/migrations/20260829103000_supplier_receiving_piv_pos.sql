alter table public.branch_supplier_receivings
add column if not exists piv_pos text null;

alter table public.branch_supplier_receivings
drop constraint if exists branch_supplier_receivings_piv_pos_check;

alter table public.branch_supplier_receivings
add constraint branch_supplier_receivings_piv_pos_check
check (
  piv_pos is null
  or (
    piv_pos = pg_catalog.btrim(piv_pos)
    and char_length(piv_pos) <= 100
  )
);

drop function if exists public.list_branch_supplier_receivings(uuid, uuid);
create or replace function public.list_branch_supplier_receivings(actor_user_id uuid,target_branch_id uuid)
returns table(id uuid,branch_id uuid,branch_name text,supplier_id uuid,category text,supplier_name_en text,supplier_name_ar text,piv_pos text,quantity numeric,unit text,notes text,photo_storage_path text,photo_original_name text,created_by uuid,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=''as $$declare c record;begin select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);return query select r.id,r.branch_id,b.name,r.supplier_id,r.category,r.supplier_name_en,r.supplier_name_ar,r.piv_pos,r.quantity,r.unit,r.notes,r.photo_storage_path,r.photo_original_name,r.created_by,r.created_at,r.updated_at from public.branch_supplier_receivings r join public.branches b on b.id=r.branch_id where r.organization_id=c.organization_id and r.branch_id=c.branch_id order by r.created_at desc;exception when no_data_found or too_many_rows then raise exception'supplier receiving access denied'using errcode='42501';end$$;

create or replace function public.create_branch_supplier_receiving(actor_user_id uuid,target_branch_id uuid,payload jsonb)
returns setof public.branch_supplier_receivings language plpgsql security definer set search_path=''as $$declare c record;s public.branch_suppliers%rowtype;category text:=payload->>'category';supplier_en text:=private.clean_supplier_receiving_text(payload->>'supplier_name_en',null,120);supplier_ar text:=private.clean_supplier_receiving_text(payload->>'supplier_name_ar',null,120);piv_pos_value text:=nullif(pg_catalog.btrim(coalesce(payload->>'piv_pos','')),'');unit_value text:=private.clean_supplier_receiving_text(payload->>'unit',null,40);notes_value text:=private.clean_supplier_receiving_text(payload->>'notes',null,2000);photo_path text:=private.clean_supplier_receiving_text(payload->>'photo_storage_path',null,260);photo_name text:=private.clean_supplier_receiving_text(payload->>'photo_original_name',null,180);supplier_uuid uuid;q numeric;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);if category not in('raw','frozen','juice')or unit_value is null or char_length(coalesce(piv_pos_value,''))>100 then raise exception'invalid supplier receiving payload'using errcode='22023';end if;begin q:=(payload->>'quantity')::numeric;supplier_uuid:=nullif(payload->>'supplier_id','')::uuid;exception when others then raise exception'invalid supplier receiving payload'using errcode='22023';end;if q<=0 then raise exception'invalid supplier receiving payload'using errcode='22023';end if;
 if supplier_uuid is not null then select*into s from public.branch_suppliers x where x.id=supplier_uuid and x.organization_id=c.organization_id and x.branch_id=c.branch_id;if s.id is null then raise exception'supplier receiving access denied'using errcode='42501';end if;if s.supplier_name_ar is null and supplier_ar is not null then update public.branch_suppliers set supplier_name_ar=supplier_ar where id=s.id returning*into s;end if;else if supplier_en is null then raise exception'invalid supplier receiving payload'using errcode='22023';end if;s:=private.upsert_branch_supplier_for_branch(c.organization_id,c.branch_id,c.legacy_team_id,actor_user_id,supplier_en,supplier_ar);end if;
 return query insert into public.branch_supplier_receivings(organization_id,branch_id,supervisor_team_id,supplier_id,category,supplier_name_en,supplier_name_ar,piv_pos,quantity,unit,notes,photo_storage_path,photo_original_name,created_by)values(c.organization_id,c.branch_id,c.legacy_team_id,s.id,category,s.supplier_name_en,coalesce(supplier_ar,s.supplier_name_ar),piv_pos_value,q,unit_value,notes_value,photo_path,photo_name,actor_user_id)returning*;
exception when no_data_found or too_many_rows then raise exception'supplier receiving access denied'using errcode='42501';end$$;

drop function if exists public.list_managed_supplier_receivings(uuid, uuid, uuid, text, uuid, date, date);
create or replace function public.list_managed_supplier_receivings(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  category_filter text default null,
  supplier_filter uuid default null,
  date_from_filter date default null,
  date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, supervisor_team_id uuid, branch_name text,
  supplier_id uuid, category text, supplier_name_en text, supplier_name_ar text, piv_pos text,
  quantity numeric, unit text, notes text, photo_storage_path text, photo_original_name text,
  created_by uuid, created_by_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (branch_filter is not null and not exists (
      select 1 from public.branches managed_branch
      where managed_branch.id = branch_filter and managed_branch.organization_id = target_organization_id
    ))
    or (supplier_filter is not null and not exists (
      select 1 from public.branch_suppliers managed_supplier
      where managed_supplier.id = supplier_filter and managed_supplier.organization_id = target_organization_id
        and (branch_filter is null or managed_supplier.branch_id = branch_filter)
    ))
    or category_filter is not null and category_filter not in ('raw','frozen','juice')
    or date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter then
    raise exception 'managed supplier receiving access denied' using errcode = '42501';
  end if;

  return query
  select receiving.id, receiving.organization_id, receiving.branch_id, receiving.supervisor_team_id,
    branch.name, receiving.supplier_id, receiving.category, receiving.supplier_name_en,
    receiving.supplier_name_ar, receiving.piv_pos, receiving.quantity, receiving.unit, receiving.notes,
    receiving.photo_storage_path, receiving.photo_original_name, receiving.created_by,
    creator.full_name, receiving.created_at, receiving.updated_at
  from public.branch_supplier_receivings receiving
  join public.branches branch on branch.id = receiving.branch_id
  left join public.profiles creator on creator.id = receiving.created_by
  where receiving.organization_id = target_organization_id
    and (branch_filter is null or receiving.branch_id = branch_filter)
    and (category_filter is null or receiving.category = category_filter)
    and (supplier_filter is null or receiving.supplier_id = supplier_filter)
    and (date_from_filter is null or (receiving.created_at at time zone 'Asia/Riyadh')::date >= date_from_filter)
    and (date_to_filter is null or (receiving.created_at at time zone 'Asia/Riyadh')::date <= date_to_filter)
  order by receiving.created_at desc;
end;
$$;

revoke all on function public.list_branch_supplier_receivings(uuid,uuid)from public,anon,authenticated;
revoke all on function public.create_branch_supplier_receiving(uuid,uuid,jsonb)from public,anon,authenticated;
revoke all on function public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date) from public, anon, authenticated;
grant execute on function public.list_branch_supplier_receivings(uuid,uuid)to service_role;
grant execute on function public.create_branch_supplier_receiving(uuid,uuid,jsonb)to service_role;
grant execute on function public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date) to service_role;
