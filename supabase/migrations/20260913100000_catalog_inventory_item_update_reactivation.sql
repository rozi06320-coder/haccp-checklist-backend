-- Migration: catalog_inventory_item_update_reactivation
-- Supports updating name, unit, and is_active (reactivation/archiving) on branch_inventory_catalog_items.
-- Hardens item creation against archived duplicate collisions.
-- Preserves identical RPC signatures, service-role privileges, search_path, and payload conventions.

create or replace function public.update_branch_catalog_inventory_item(
  actor_user_id uuid,
  target_branch_id uuid,
  target_inventory_item_id uuid,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  clean_name text := private.clean_catalog_text(payload->>'name', 120);
  clean_unit text := coalesce(nullif(payload->>'unit', ''), 'pcs');
  raw_is_active jsonb := coalesce(payload->'is_active', payload->'isActive');
  new_is_active boolean;
  target_item public.branch_inventory_catalog_items%rowtype;
  conflicting_item public.branch_inventory_catalog_items%rowtype;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);

  if clean_unit not in ('pcs','kg','g','L','ml') then
    raise exception 'invalid inventory item payload' using errcode = '22023';
  end if;

  select item.* into target_item
  from public.branch_inventory_catalog_items item
  where item.id = target_inventory_item_id and item.branch_id = target_branch.id;

  if target_item.id is null then
    raise exception 'inventory item unavailable' using errcode = 'P0002';
  end if;

  if raw_is_active is not null and pg_catalog.jsonb_typeof(raw_is_active) <> 'null' then
    if pg_catalog.jsonb_typeof(raw_is_active) <> 'boolean' then
      raise exception 'invalid inventory item payload' using errcode = '22023';
    end if;
    new_is_active := (raw_is_active #>> '{}')::boolean;
  else
    new_is_active := target_item.is_active;
  end if;

  if new_is_active then
    select item.* into conflicting_item
    from public.branch_inventory_catalog_items item
    where item.branch_id = target_branch.id
      and item.id <> target_item.id
      and item.is_active
      and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name)
    limit 1;
    if conflicting_item.id is not null then
      raise exception 'inventory item unit conflict' using errcode = '23505';
    end if;
  end if;

  update public.branch_inventory_catalog_items item
  set name = clean_name,
      unit = clean_unit,
      is_active = new_is_active
  where item.id = target_item.id;

  return private.branch_catalog_payload(target_branch.id);
end;
$$;

create or replace function public.create_branch_catalog_inventory_item(
  actor_user_id uuid,
  target_branch_id uuid,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  clean_name text := private.clean_catalog_text(payload->>'name', 120);
  clean_unit text := coalesce(nullif(payload->>'unit', ''), 'pcs');
  target_item public.branch_inventory_catalog_items%rowtype;
  existing_item public.branch_inventory_catalog_items%rowtype;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);

  if clean_unit not in ('pcs','kg','g','L','ml') then
    raise exception 'invalid inventory item payload' using errcode = '22023';
  end if;

  select item.* into existing_item
  from public.branch_inventory_catalog_items item
  where item.branch_id = target_branch.id
    and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name)
  order by item.is_active desc, item.created_at asc
  limit 1;

  if existing_item.id is not null then
    if existing_item.is_active then
      raise exception 'inventory item already exists' using errcode = '23505';
    else
      raise exception 'archived inventory item already exists' using errcode = '23505';
    end if;
  end if;

  insert into public.branch_inventory_catalog_items(organization_id, branch_id, name, unit, kind)
  values (target_branch.organization_id, target_branch.id, clean_name, clean_unit, 'ingredient')
  returning * into target_item;

  return private.branch_catalog_payload(target_branch.id);
end;
$$;

revoke all on function public.update_branch_catalog_inventory_item(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.update_branch_catalog_inventory_item(uuid, uuid, uuid, jsonb) to service_role;

revoke all on function public.create_branch_catalog_inventory_item(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.create_branch_catalog_inventory_item(uuid, uuid, jsonb) to service_role;
