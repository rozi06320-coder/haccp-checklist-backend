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
  supplier_id uuid, category text, supplier_name_en text, supplier_name_ar text,
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
    receiving.supplier_name_ar, receiving.quantity, receiving.unit, receiving.notes,
    receiving.photo_storage_path, receiving.photo_original_name, receiving.created_by,
    creator.full_name, receiving.created_at, receiving.updated_at
  from public.branch_supplier_receivings receiving
  join public.branches branch on branch.id = receiving.branch_id
  left join public.profiles creator on creator.id = receiving.created_by
  where receiving.organization_id = target_organization_id
    and (branch_filter is null or receiving.branch_id = branch_filter)
    and (category_filter is null or receiving.category = category_filter)
    and (supplier_filter is null or receiving.supplier_id = supplier_filter)
    and (date_from_filter is null or receiving.created_at::date >= date_from_filter)
    and (date_to_filter is null or receiving.created_at::date <= date_to_filter)
  order by receiving.created_at desc;
end;
$$;

revoke all on function public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date) from public, anon, authenticated;
grant execute on function public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date) to service_role;
