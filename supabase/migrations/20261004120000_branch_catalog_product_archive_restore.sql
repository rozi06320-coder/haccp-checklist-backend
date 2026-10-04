create or replace function public.archive_branch_catalog_product(
  actor_user_id uuid,
  target_branch_id uuid,
  target_product_id uuid,
  expected_updated_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  target_product public.branch_product_catalog_products%rowtype;
begin
  if expected_updated_at is null then
    raise exception 'expected product timestamp is required' using errcode = '22004';
  end if;

  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);
  perform private.lock_branch_catalog(target_branch.organization_id, target_branch.id);

  select product.* into target_product
  from public.branch_product_catalog_products product
  where product.id = target_product_id
    and product.organization_id = target_branch.organization_id
    and product.branch_id = target_branch.id
  for update;

  if target_product.id is null then
    raise exception 'catalog product unavailable' using errcode = 'P0002';
  end if;
  if target_product.updated_at <> expected_updated_at then
    raise exception 'catalog product changed' using errcode = '40001';
  end if;
  if not target_product.is_active then
    raise exception 'catalog product already archived' using errcode = '23505';
  end if;

  delete from public.branch_product_usage_mappings mapping
  where mapping.organization_id = target_branch.organization_id
    and mapping.branch_id = target_branch.id
    and mapping.product_id = target_product.id;

  update public.branch_product_catalog_products product
  set is_active = false,
      display_order = null
  where product.id = target_product.id;

  return private.branch_catalog_payload(target_branch.id);
end;
$$;

create or replace function public.create_branch_catalog_product(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  clean_name text := private.clean_catalog_text(payload->>'name', 120);
  behavior text := payload->>'inventory_behavior';
  product_unit text := coalesce(nullif(payload->>'unit', ''), 'pcs');
  recipe_rows jsonb := coalesce(payload->'recipe_rows', '[]'::jsonb);
  target_product public.branch_product_catalog_products%rowtype;
  target_item public.branch_inventory_catalog_items%rowtype;
  recipe_row jsonb;
  seen_items uuid[] := array[]::uuid[];
  archived_product_ids uuid[];
  next_display_order integer;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);
  perform private.lock_branch_catalog(target_branch.organization_id, target_branch.id);

  if clean_name is null
    or jsonb_typeof(recipe_rows) <> 'array'
    or behavior not in ('recipe','standalone_stock','non_stock')
    or (behavior = 'standalone_stock' and (product_unit not in ('pcs','kg','g','L','ml') or jsonb_array_length(recipe_rows) > 0))
    or (behavior = 'non_stock' and (payload->>'unit' is not null or jsonb_array_length(recipe_rows) > 0))
    or (behavior = 'recipe' and payload->>'unit' is not null)
  then
    raise exception 'invalid product payload' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.branch_product_catalog_products product
    where product.organization_id = target_branch.organization_id
      and product.branch_id = target_branch.id
      and product.is_active
      and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(product.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name)
  ) then
    raise exception 'product already exists' using errcode = '23505';
  end if;

  select array_agg(product.id order by product.created_at desc, product.id)
  into archived_product_ids
  from public.branch_product_catalog_products product
  where product.organization_id = target_branch.organization_id
    and product.branch_id = target_branch.id
    and not product.is_active
    and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(product.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name);

  if coalesce(cardinality(archived_product_ids), 0) > 1 then
    raise exception 'multiple archived products match this name' using errcode = '23505';
  end if;

  if behavior = 'standalone_stock' then
    target_item := private.resolve_branch_catalog_inventory_item(target_branch, clean_name, product_unit, 'standalone_stock');
  end if;

  select coalesce(max(product.display_order), 0) + 1
  into next_display_order
  from public.branch_product_catalog_products product
  where product.organization_id = target_branch.organization_id
    and product.branch_id = target_branch.id
    and product.is_active;

  if coalesce(cardinality(archived_product_ids), 0) = 1 then
    select product.* into target_product
    from public.branch_product_catalog_products product
    where product.id = archived_product_ids[1]
    for update;

    delete from public.branch_product_usage_mappings mapping
    where mapping.organization_id = target_branch.organization_id
      and mapping.branch_id = target_branch.id
      and mapping.product_id = target_product.id;

    update public.branch_product_catalog_products product
    set name = clean_name,
        inventory_behavior = behavior,
        unit = case when behavior = 'standalone_stock' then product_unit else null end,
        standalone_inventory_item_id = case when behavior = 'standalone_stock' then target_item.id else null end,
        is_active = true,
        display_order = next_display_order
    where product.id = target_product.id
    returning * into target_product;
  else
    insert into public.branch_product_catalog_products(
      organization_id,
      branch_id,
      name,
      inventory_behavior,
      unit,
      standalone_inventory_item_id,
      display_order
    )
    values (
      target_branch.organization_id,
      target_branch.id,
      clean_name,
      behavior,
      case when behavior = 'standalone_stock' then product_unit else null end,
      case when behavior = 'standalone_stock' then target_item.id else null end,
      next_display_order
    )
    returning * into target_product;
  end if;

  if behavior = 'recipe' then
    for recipe_row in select * from jsonb_array_elements(recipe_rows) loop
      if recipe_row ? 'inventory_item_id' and nullif(recipe_row->>'inventory_item_id', '') is not null then
        select item.* into target_item
        from public.branch_inventory_catalog_items item
        where item.id = (recipe_row->>'inventory_item_id')::uuid
          and item.branch_id = target_branch.id
          and item.organization_id = target_branch.organization_id
          and item.is_active
          and item.kind = 'ingredient';
        if target_item.id is null then
          raise exception 'inventory item unavailable' using errcode = '22023';
        end if;
      else
        target_item := private.resolve_branch_catalog_inventory_item(
          target_branch,
          recipe_row->>'ingredient',
          coalesce(nullif(recipe_row->>'unit', ''), 'pcs'),
          'ingredient'
        );
      end if;

      if target_item.id = any(seen_items) then
        raise exception 'duplicate recipe inventory item' using errcode = '23505';
      end if;
      seen_items := array_append(seen_items, target_item.id);

      insert into public.branch_product_usage_mappings(
        organization_id,
        branch_id,
        product_id,
        inventory_item_id,
        quantity
      )
      values (
        target_branch.organization_id,
        target_branch.id,
        target_product.id,
        target_item.id,
        (recipe_row->>'quantity')::numeric
      );
    end loop;
  end if;

  return private.branch_catalog_payload(target_branch.id);
end;
$$;

revoke all on function public.archive_branch_catalog_product(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.archive_branch_catalog_product(uuid, uuid, uuid, timestamptz) to service_role;

revoke all on function public.create_branch_catalog_product(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.create_branch_catalog_product(uuid, uuid, jsonb) to service_role;
