-- Migration: 20260913130000_catalog_inventory_item_merge.sql
-- Safe duplicate ingredient merge / typo resolution RPC

create or replace function public.merge_branch_catalog_inventory_item(
  actor_user_id uuid,
  target_branch_id uuid,
  duplicate_inventory_item_id uuid,
  target_inventory_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  source_item public.branch_inventory_catalog_items%rowtype;
  target_item public.branch_inventory_catalog_items%rowtype;
  conflicting_product_name text;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);

  if duplicate_inventory_item_id is null or target_inventory_item_id is null then
    raise exception 'item identifiers required' using errcode = '22023';
  end if;

  if duplicate_inventory_item_id = target_inventory_item_id then
    raise exception 'cannot merge item into itself' using errcode = '22023';
  end if;

  -- Load duplicate source item
  select * into source_item
  from public.branch_inventory_catalog_items item
  where item.id = duplicate_inventory_item_id;

  if not found or source_item.branch_id <> target_branch.id or source_item.organization_id <> target_branch.organization_id then
    raise exception 'duplicate inventory item branch access denied' using errcode = '42501';
  end if;

  -- Load canonical target item
  select * into target_item
  from public.branch_inventory_catalog_items item
  where item.id = target_inventory_item_id;

  if not found or target_item.branch_id <> target_branch.id or target_item.organization_id <> target_branch.organization_id then
    raise exception 'target inventory item branch access denied' using errcode = '42501';
  end if;

  -- Both items must be ingredients
  if source_item.kind <> 'ingredient' or target_item.kind <> 'ingredient' then
    raise exception 'only ingredient items can be merged' using errcode = '22023';
  end if;

  -- Target canonical item must be active
  if not target_item.is_active then
    raise exception 'cannot merge into inactive target item' using errcode = '22023';
  end if;

  -- Units must be compatible
  if source_item.unit <> target_item.unit then
    raise exception 'inventory item unit mismatch' using errcode = '22023';
  end if;

  -- Safe collision handling:
  -- Check if any recipe currently maps BOTH source duplicate and target canonical items.
  -- Rejecting with 23505 requires the supervisor to review the recipe and resolve the collision manually,
  -- ensuring no quantities are silently dropped, altered, or doubled.
  select p.name into conflicting_product_name
  from public.branch_product_usage_mappings mb
  join public.branch_product_usage_mappings ma
    on ma.product_id = mb.product_id
   and ma.organization_id = target_branch.organization_id
   and ma.branch_id = target_branch.id
   and ma.inventory_item_id = target_item.id
  join public.branch_product_catalog_products p
    on p.id = mb.product_id
  where mb.organization_id = target_branch.organization_id
    and mb.branch_id = target_branch.id
    and mb.inventory_item_id = source_item.id
  limit 1;

  if conflicting_product_name is not null then
    raise exception 'recipe collision in product: %', conflicting_product_name using errcode = '23505';
  end if;

  -- Reassign current recipe mappings from source duplicate to canonical target
  update public.branch_product_usage_mappings
  set inventory_item_id = target_item.id,
      updated_at = pg_catalog.now()
  where organization_id = target_branch.organization_id
    and branch_id = target_branch.id
    and inventory_item_id = source_item.id;

  -- Note: Standalone products require kind = 'standalone_stock' (enforced by
  -- private.enforce_product_inventory_behavior_consistency). Since both source
  -- and target items are validated as kind = 'ingredient', no standalone product
  -- references can exist or be reassigned.

  -- Archive duplicate source item (do not delete to preserve historical FKs)
  update public.branch_inventory_catalog_items
  set is_active = false,
      updated_at = pg_catalog.now()
  where id = source_item.id;

  -- Guarantees:
  -- 1. branch_product_sales_usage_snapshots is NOT updated (historical snapshots remain intact)
  -- 2. branch_daily_waste_entries is NOT updated (historical waste entries remain intact)
  -- 3. branch_daily_inventory_entries is NOT updated (historical inventory counts remain intact)
  -- 4. No new UUID is created

  return private.branch_catalog_payload(target_branch.id);
end;
$$;

revoke all on function public.merge_branch_catalog_inventory_item(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.merge_branch_catalog_inventory_item(uuid, uuid, uuid, uuid) to service_role;
