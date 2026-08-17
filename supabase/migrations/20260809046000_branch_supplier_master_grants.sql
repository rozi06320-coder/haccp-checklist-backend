grant select on table public.branch_suppliers to service_role;
revoke all on function public.list_branch_supplier_receivings(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_branch_supplier_receivings(uuid, uuid) to service_role;

create or replace function public.create_branch_supplier_receiving(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns setof public.branch_supplier_receivings
language plpgsql
security definer
set search_path=public, private
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  target_supplier public.branch_suppliers%rowtype;
  clean_category text := payload->>'category';
  clean_supplier_en text := private.clean_supplier_receiving_text(payload->>'supplier_name_en', null, 120);
  clean_supplier_ar text := private.clean_supplier_receiving_text(payload->>'supplier_name_ar', null, 120);
  clean_unit text := private.clean_supplier_receiving_text(payload->>'unit', null, 40);
  clean_notes text := private.clean_supplier_receiving_text(payload->>'notes', null, 2000);
  clean_photo_path text := private.clean_supplier_receiving_text(payload->>'photo_storage_path', null, 260);
  clean_photo_name text := private.clean_supplier_receiving_text(payload->>'photo_original_name', null, 180);
  requested_supplier_id uuid;
  parsed_quantity numeric;
begin
  target_team := private.require_supervisor_supplier_receiving_team(actor_user_id, target_branch_id);
  if clean_category not in ('raw','frozen','juice') or clean_unit is null then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end if;
  begin
    parsed_quantity := (payload->>'quantity')::numeric;
    requested_supplier_id := nullif(payload->>'supplier_id','')::uuid;
  exception when others then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end;
  if parsed_quantity <= 0 then
    raise exception 'invalid supplier receiving payload' using errcode='22023';
  end if;

  if requested_supplier_id is not null then
    select supplier.* into target_supplier
    from public.branch_suppliers supplier
    where supplier.id = requested_supplier_id
      and supplier.supervisor_team_id = target_team.id
      and supplier.branch_id = target_team.branch_id
    limit 1;
    if target_supplier.id is null then
      raise exception 'supplier receiving access denied' using errcode='42501';
    end if;
    if target_supplier.supplier_name_ar is null and clean_supplier_ar is not null then
      update public.branch_suppliers supplier
      set supplier_name_ar = clean_supplier_ar
      where supplier.id = target_supplier.id
      returning * into target_supplier;
    end if;
  else
    if clean_supplier_en is null then
      raise exception 'invalid supplier receiving payload' using errcode='22023';
    end if;
    target_supplier := private.upsert_branch_supplier_for_team(target_team, actor_user_id, clean_supplier_en, clean_supplier_ar);
  end if;

  return query
  insert into public.branch_supplier_receivings(
    organization_id, branch_id, supervisor_team_id, supplier_id, category, supplier_name_en,
    supplier_name_ar, quantity, unit, notes, photo_storage_path, photo_original_name, created_by
  ) values (
    target_team.organization_id, target_team.branch_id, target_team.id, target_supplier.id, clean_category,
    target_supplier.supplier_name_en, coalesce(clean_supplier_ar, target_supplier.supplier_name_ar),
    parsed_quantity, clean_unit, clean_notes, clean_photo_path, clean_photo_name, actor_user_id
  )
  returning *;
end;
$$;
