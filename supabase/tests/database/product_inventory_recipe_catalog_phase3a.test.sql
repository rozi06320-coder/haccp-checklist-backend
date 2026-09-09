begin;
create table if not exists public.branch_inventory_catalog_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  name text not null,
  unit text not null,
  kind text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_inventory_catalog_items_name_check check (name = pg_catalog.regexp_replace(pg_catalog.btrim(name), '[[:space:]]+', ' ', 'g') and length(name) between 1 and 120),
  constraint branch_inventory_catalog_items_unit_check check (unit in ('pcs','kg','g','L','ml')),
  constraint branch_inventory_catalog_items_kind_check check (kind in ('ingredient','standalone_stock')),
  constraint branch_inventory_catalog_items_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_inventory_catalog_items_branch_id_key unique (branch_id, id)
);

create table if not exists public.branch_product_catalog_products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  name text not null,
  inventory_behavior text not null,
  unit text null,
  standalone_inventory_item_id uuid null references public.branch_inventory_catalog_items(id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_product_catalog_products_name_check check (name = pg_catalog.regexp_replace(pg_catalog.btrim(name), '[[:space:]]+', ' ', 'g') and length(name) between 1 and 120),
  constraint branch_product_catalog_products_behavior_check check (inventory_behavior in ('recipe','standalone_stock','non_stock')),
  constraint branch_product_catalog_products_unit_check check (unit is null or unit in ('pcs','kg','g','L','ml')),
  constraint branch_product_catalog_products_standalone_check check (
    (inventory_behavior = 'standalone_stock' and standalone_inventory_item_id is not null and unit is not null)
    or (inventory_behavior in ('recipe','non_stock') and standalone_inventory_item_id is null and unit is null)
  ),
  constraint branch_product_catalog_products_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_product_catalog_products_branch_id_key unique (branch_id, id),
  constraint branch_product_catalog_products_standalone_item_fk foreign key (branch_id, standalone_inventory_item_id) references public.branch_inventory_catalog_items(branch_id, id) on delete restrict
);

create table if not exists public.branch_product_usage_mappings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  product_id uuid not null references public.branch_product_catalog_products(id) on delete cascade,
  inventory_item_id uuid not null references public.branch_inventory_catalog_items(id) on delete restrict,
  quantity numeric not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_product_usage_mappings_quantity_check check (quantity > 0),
  constraint branch_product_usage_mappings_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_product_usage_mappings_product_fk foreign key (branch_id, product_id) references public.branch_product_catalog_products(branch_id, id) on delete cascade,
  constraint branch_product_usage_mappings_inventory_item_fk foreign key (branch_id, inventory_item_id) references public.branch_inventory_catalog_items(branch_id, id) on delete restrict
);

create unique index if not exists branch_inventory_catalog_items_active_name_key
on public.branch_inventory_catalog_items(branch_id, pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(name), '[[:space:]]+', ' ', 'g')))
where is_active;

create unique index if not exists branch_product_catalog_products_active_name_key
on public.branch_product_catalog_products(branch_id, pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(name), '[[:space:]]+', ' ', 'g')))
where is_active;

create unique index if not exists branch_product_usage_mappings_product_item_key
on public.branch_product_usage_mappings(product_id, inventory_item_id);

create index if not exists branch_product_catalog_products_branch_idx on public.branch_product_catalog_products(branch_id, is_active, name);
create index if not exists branch_inventory_catalog_items_branch_idx on public.branch_inventory_catalog_items(branch_id, is_active, name);
create index if not exists branch_product_usage_mappings_branch_idx on public.branch_product_usage_mappings(branch_id, product_id);

drop trigger if exists branch_inventory_catalog_items_set_updated_at on public.branch_inventory_catalog_items;
create trigger branch_inventory_catalog_items_set_updated_at
before update on public.branch_inventory_catalog_items
for each row execute function private.set_updated_at();

drop trigger if exists branch_product_catalog_products_set_updated_at on public.branch_product_catalog_products;
create trigger branch_product_catalog_products_set_updated_at
before update on public.branch_product_catalog_products
for each row execute function private.set_updated_at();

drop trigger if exists branch_product_usage_mappings_set_updated_at on public.branch_product_usage_mappings;
create trigger branch_product_usage_mappings_set_updated_at
before update on public.branch_product_usage_mappings
for each row execute function private.set_updated_at();

create or replace function private.enforce_product_catalog_behavior_and_kind()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_kind text;
begin
  if NEW.standalone_inventory_item_id is not null then
    select item.kind into target_kind
    from public.branch_inventory_catalog_items item
    where item.id = NEW.standalone_inventory_item_id and item.branch_id = NEW.branch_id;

    if target_kind is null or target_kind <> 'standalone_stock' then
      raise exception 'standalone product must reference standalone_stock inventory item' using errcode = '22023';
    end if;
  end if;

  if TG_OP = 'UPDATE' and NEW.inventory_behavior <> 'recipe' and exists (
    select 1 from public.branch_product_usage_mappings mapping
    where mapping.product_id = NEW.id
  ) then
    raise exception 'cannot change behavior of product with recipe mappings' using errcode = '22023';
  end if;

  return NEW;
end;
$$;

create or replace function private.enforce_inventory_item_kind_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if NEW.kind <> OLD.kind and exists (
    select 1 from public.branch_product_catalog_products product
    where product.standalone_inventory_item_id = NEW.id
  ) then
    raise exception 'cannot change kind of inventory item referenced by standalone product' using errcode = '23505';
  end if;
  return NEW;
end;
$$;

create or replace function private.enforce_recipe_mapping_product_behavior()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_behavior text;
begin
  select product.inventory_behavior into target_behavior
  from public.branch_product_catalog_products product
  where product.id = NEW.product_id and product.branch_id = NEW.branch_id;

  if target_behavior is null or target_behavior <> 'recipe' then
    raise exception 'recipe usage mappings can only be created for recipe products' using errcode = '22023';
  end if;
  return NEW;
end;
$$;

drop trigger if exists branch_product_catalog_products_enforce_behavior on public.branch_product_catalog_products;
create trigger branch_product_catalog_products_enforce_behavior
before insert or update on public.branch_product_catalog_products
for each row execute function private.enforce_product_catalog_behavior_and_kind();

drop trigger if exists branch_inventory_catalog_items_enforce_kind on public.branch_inventory_catalog_items;
create trigger branch_inventory_catalog_items_enforce_kind
before update on public.branch_inventory_catalog_items
for each row execute function private.enforce_inventory_item_kind_immutability();

drop trigger if exists branch_product_usage_mappings_enforce_behavior on public.branch_product_usage_mappings;
create trigger branch_product_usage_mappings_enforce_behavior
before insert or update on public.branch_product_usage_mappings
for each row execute function private.enforce_recipe_mapping_product_behavior();

alter table public.branch_inventory_catalog_items enable row level security;
alter table public.branch_product_catalog_products enable row level security;
alter table public.branch_product_usage_mappings enable row level security;

revoke all on table public.branch_inventory_catalog_items, public.branch_product_catalog_products, public.branch_product_usage_mappings from public, anon, authenticated, service_role;
grant select on table public.branch_inventory_catalog_items, public.branch_product_catalog_products, public.branch_product_usage_mappings to authenticated, service_role;

create policy branch_inventory_catalog_items_select_authorized
on public.branch_inventory_catalog_items for select to authenticated
using (private.has_branch_access(branch_id));

create policy branch_product_catalog_products_select_authorized
on public.branch_product_catalog_products for select to authenticated
using (private.has_branch_access(branch_id));

create policy branch_product_usage_mappings_select_authorized
on public.branch_product_usage_mappings for select to authenticated
using (private.has_branch_access(branch_id));

create or replace function private.clean_catalog_text(value text, max_length integer default 120)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare cleaned text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(value, '')), '[[:space:]]+', ' ', 'g'), '');
begin
  if cleaned is null or length(cleaned) > max_length then
    raise exception 'invalid catalog text' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

create or replace function private.require_branch_catalog_scope(actor_user_id uuid, target_branch_id uuid)
returns public.branches
language plpgsql
security definer
set search_path = ''
as $$
declare target_branch public.branches%rowtype;
begin
  select branch.* into target_branch
  from public.branches branch
  join public.profiles profile on profile.id = actor_user_id
  join public.branch_memberships membership on membership.branch_id = branch.id and membership.user_id = actor_user_id
  where branch.id = target_branch_id
    and branch.active
    and profile.disabled_at is null
    and not profile.must_change_password
    and membership.active
    and membership.role = 'branch_manager'
  limit 1;

  if target_branch.id is null then
    raise exception 'catalog access denied' using errcode = '42501';
  end if;

  return target_branch;
end;
$$;

create or replace function private.branch_catalog_payload(target_branch_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', product.id,
        'branch_id', product.branch_id,
        'name', product.name,
        'inventory_behavior', product.inventory_behavior,
        'unit', product.unit,
        'standalone_inventory_item_id', product.standalone_inventory_item_id,
        'is_active', product.is_active,
        'created_at', product.created_at,
        'updated_at', product.updated_at
      ) order by product.is_active desc, pg_catalog.lower(product.name), product.id)
      from public.branch_product_catalog_products product
      where product.branch_id = target_branch_id
    ), '[]'::jsonb),
    'inventory_items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', item.id,
        'branch_id', item.branch_id,
        'name', item.name,
        'unit', item.unit,
        'kind', item.kind,
        'is_active', item.is_active,
        'created_at', item.created_at,
        'updated_at', item.updated_at
      ) order by item.is_active desc, pg_catalog.lower(item.name), item.id)
      from public.branch_inventory_catalog_items item
      where item.branch_id = target_branch_id
    ), '[]'::jsonb),
    'product_usage_mappings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', mapping.id,
        'product_id', mapping.product_id,
        'inventory_item_id', mapping.inventory_item_id,
        'quantity', mapping.quantity,
        'created_at', mapping.created_at,
        'updated_at', mapping.updated_at
      ) order by mapping.product_id, mapping.inventory_item_id)
      from public.branch_product_usage_mappings mapping
      where mapping.branch_id = target_branch_id
    ), '[]'::jsonb)
  );
$$;

create or replace function private.resolve_branch_catalog_inventory_item(
  target_branch public.branches,
  item_name text,
  item_unit text,
  item_kind text default 'ingredient'
)
returns public.branch_inventory_catalog_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_name text := private.clean_catalog_text(item_name, 120);
  target_item public.branch_inventory_catalog_items%rowtype;
  conflicting_item public.branch_inventory_catalog_items%rowtype;
begin
  if item_unit not in ('pcs','kg','g','L','ml') or item_kind not in ('ingredient','standalone_stock') then
    raise exception 'invalid inventory item payload' using errcode = '22023';
  end if;

  select item.* into conflicting_item
  from public.branch_inventory_catalog_items item
  where item.branch_id = target_branch.id
    and item.is_active
    and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name)
  limit 1;

  if conflicting_item.id is not null and conflicting_item.unit <> item_unit then
    raise exception 'inventory item unit conflict' using errcode = '23505';
  end if;

  if conflicting_item.id is not null then
    return conflicting_item;
  end if;

  insert into public.branch_inventory_catalog_items(organization_id, branch_id, name, unit, kind)
  values (target_branch.organization_id, target_branch.id, clean_name, item_unit, item_kind)
  returning * into target_item;

  return target_item;
end;
$$;

create or replace function public.list_branch_catalog(actor_user_id uuid, target_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare target_branch public.branches%rowtype;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);
  return private.branch_catalog_payload(target_branch.id);
end;
$$;

create or replace function public.create_branch_catalog_inventory_item(actor_user_id uuid, target_branch_id uuid, payload jsonb)
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
  where item.branch_id = target_branch.id and item.is_active
    and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name)
  limit 1;
  if existing_item.id is not null then
    raise exception 'inventory item already exists' using errcode = '23505';
  end if;
  insert into public.branch_inventory_catalog_items(organization_id, branch_id, name, unit, kind)
  values (target_branch.organization_id, target_branch.id, clean_name, clean_unit, 'ingredient')
  returning * into target_item;
  return private.branch_catalog_payload(target_branch.id);
end;
$$;

create or replace function public.update_branch_catalog_inventory_item(actor_user_id uuid, target_branch_id uuid, target_inventory_item_id uuid, payload jsonb)
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
  conflicting_item public.branch_inventory_catalog_items%rowtype;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);
  if clean_unit not in ('pcs','kg','g','L','ml') then
    raise exception 'invalid inventory item payload' using errcode = '22023';
  end if;
  select item.* into target_item from public.branch_inventory_catalog_items item where item.id = target_inventory_item_id and item.branch_id = target_branch.id and item.is_active;
  if target_item.id is null then raise exception 'inventory item unavailable' using errcode = 'P0002'; end if;
  select item.* into conflicting_item
  from public.branch_inventory_catalog_items item
  where item.branch_id = target_branch.id and item.id <> target_item.id and item.is_active
    and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(item.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name)
  limit 1;
  if conflicting_item.id is not null then raise exception 'inventory item unit conflict' using errcode = '23505'; end if;
  update public.branch_inventory_catalog_items item set name = clean_name, unit = clean_unit where item.id = target_item.id;
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
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);
  if behavior not in ('recipe','standalone_stock','non_stock')
    or (behavior = 'standalone_stock' and (product_unit is null or product_unit not in ('pcs','kg','g','L','ml') or jsonb_array_length(recipe_rows) > 0))
    or (behavior = 'non_stock' and (payload->>'unit' is not null or jsonb_array_length(recipe_rows) > 0))
    or (behavior = 'recipe' and (payload->>'unit' is not null or jsonb_typeof(recipe_rows) <> 'array'))
  then
    raise exception 'invalid product payload' using errcode = '22023';
  end if;
  if exists (select 1 from public.branch_product_catalog_products product where product.branch_id = target_branch.id and product.is_active and pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(product.name), '[[:space:]]+', ' ', 'g')) = pg_catalog.lower(clean_name)) then
    raise exception 'product already exists' using errcode = '23505';
  end if;
  if behavior = 'standalone_stock' then
    target_item := private.resolve_branch_catalog_inventory_item(target_branch, clean_name, product_unit, 'standalone_stock');
  end if;
  insert into public.branch_product_catalog_products(organization_id, branch_id, name, inventory_behavior, unit, standalone_inventory_item_id)
  values (target_branch.organization_id, target_branch.id, clean_name, behavior, case when behavior = 'standalone_stock' then product_unit else null end, case when behavior = 'standalone_stock' then target_item.id else null end)
  returning * into target_product;
  if behavior = 'recipe' then
    for recipe_row in select * from jsonb_array_elements(recipe_rows) loop
      target_item := private.resolve_branch_catalog_inventory_item(target_branch, recipe_row->>'ingredient', coalesce(nullif(recipe_row->>'unit', ''), 'pcs'), 'ingredient');
      if target_item.id = any(seen_items) then raise exception 'duplicate recipe inventory item' using errcode = '23505'; end if;
      seen_items := array_append(seen_items, target_item.id);
      insert into public.branch_product_usage_mappings(organization_id, branch_id, product_id, inventory_item_id, quantity)
      values (target_branch.organization_id, target_branch.id, target_product.id, target_item.id, (recipe_row->>'quantity')::numeric);
    end loop;
  end if;
  return private.branch_catalog_payload(target_branch.id);
end;
$$;

create or replace function public.save_branch_product_usage_mappings(actor_user_id uuid, target_branch_id uuid, target_product_id uuid, recipe_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  target_product public.branch_product_catalog_products%rowtype;
  target_item public.branch_inventory_catalog_items%rowtype;
  recipe_row jsonb;
  seen_items uuid[] := array[]::uuid[];
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);
  if jsonb_typeof(coalesce(recipe_rows, '[]'::jsonb)) <> 'array' then raise exception 'invalid recipe payload' using errcode = '22023'; end if;
  select product.* into target_product from public.branch_product_catalog_products product where product.id = target_product_id and product.branch_id = target_branch.id and product.is_active;
  if target_product.id is null or target_product.inventory_behavior <> 'recipe' then raise exception 'product unavailable' using errcode = '22023'; end if;
  create temp table branch_catalog_recipe_stage(inventory_item_id uuid primary key, quantity numeric not null check(quantity > 0)) on commit drop;
  for recipe_row in select * from jsonb_array_elements(coalesce(recipe_rows, '[]'::jsonb)) loop
    target_item := private.resolve_branch_catalog_inventory_item(target_branch, recipe_row->>'ingredient', coalesce(nullif(recipe_row->>'unit', ''), 'pcs'), 'ingredient');
    if target_item.id = any(seen_items) then raise exception 'duplicate recipe inventory item' using errcode = '23505'; end if;
    seen_items := array_append(seen_items, target_item.id);
    insert into branch_catalog_recipe_stage(inventory_item_id, quantity) values (target_item.id, (recipe_row->>'quantity')::numeric);
  end loop;
  delete from public.branch_product_usage_mappings mapping where mapping.product_id = target_product.id;
  insert into public.branch_product_usage_mappings(organization_id, branch_id, product_id, inventory_item_id, quantity)
  select target_branch.organization_id, target_branch.id, target_product.id, stage.inventory_item_id, stage.quantity from branch_catalog_recipe_stage stage;
  return private.branch_catalog_payload(target_branch.id);
end;
$$;

revoke all on function private.clean_catalog_text(text, integer), private.require_branch_catalog_scope(uuid, uuid), private.branch_catalog_payload(uuid), private.resolve_branch_catalog_inventory_item(public.branches, text, text, text), private.enforce_product_catalog_behavior_and_kind(), private.enforce_inventory_item_kind_immutability(), private.enforce_recipe_mapping_product_behavior() from public, anon, authenticated;
revoke all on function public.list_branch_catalog(uuid, uuid), public.create_branch_catalog_inventory_item(uuid, uuid, jsonb), public.update_branch_catalog_inventory_item(uuid, uuid, uuid, jsonb), public.create_branch_catalog_product(uuid, uuid, jsonb), public.save_branch_product_usage_mappings(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.list_branch_catalog(uuid, uuid), public.create_branch_catalog_inventory_item(uuid, uuid, jsonb), public.update_branch_catalog_inventory_item(uuid, uuid, uuid, jsonb), public.create_branch_catalog_product(uuid, uuid, jsonb), public.save_branch_product_usage_mappings(uuid, uuid, uuid, jsonb) to service_role;


select plan(36);

-- 1. Migration applies successfully: tables exist
select has_table('public', 'branch_product_catalog_products', 'products table exists');
select has_table('public', 'branch_inventory_catalog_items', 'inventory items table exists');
select has_table('public', 'branch_product_usage_mappings', 'product usage mappings table exists');

-- 2. RLS enabled on all three tables
select ok((select rowsecurity from pg_tables where schemaname = 'public' and tablename = 'branch_product_catalog_products'), 'RLS enabled on products');
select ok((select rowsecurity from pg_tables where schemaname = 'public' and tablename = 'branch_inventory_catalog_items'), 'RLS enabled on inventory items');
select ok((select rowsecurity from pg_tables where schemaname = 'public' and tablename = 'branch_product_usage_mappings'), 'RLS enabled on mappings');

-- Setup test tenants and users
insert into public.organizations(id, name, slug) values
  ('d0000000-0000-4000-8000-000000000001', 'Org A', 'org-a-cat'),
  ('d0000000-0000-4000-8000-000000000002', 'Org B', 'org-b-cat')
on conflict (id) do nothing;

insert into public.branches(id, organization_id, name, code, city, timezone, active) values
  ('d1000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001', 'Branch A1', 'BR-A1', 'Riyadh', 'Asia/Riyadh', true),
  ('d1000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000001', 'Branch A2', 'BR-A2', 'Riyadh', 'Asia/Riyadh', true),
  ('d1000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000002', 'Branch B1', 'BR-B1', 'Dubai', 'Asia/Riyadh', true)
on conflict (id) do nothing;

insert into auth.users(id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('d2000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000000', 'authenticated', 'authenticated', 'sup-a1@cat.test', '{}', '{}', now(), now()),
  ('d2000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000000', 'authenticated', 'authenticated', 'sup-a2@cat.test', '{}', '{}', now(), now()),
  ('d2000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000000', 'authenticated', 'authenticated', 'mgr-a@cat.test', '{}', '{}', now(), now())
on conflict (id) do nothing;

insert into public.profiles(id, full_name, must_change_password) values
  ('d2000000-0000-4000-8000-000000000001', 'Supervisor A1', false),
  ('d2000000-0000-4000-8000-000000000002', 'Supervisor A2', false),
  ('d2000000-0000-4000-8000-000000000003', 'Manager A', false)
on conflict (id) do update set must_change_password = false, disabled_at = null;

insert into public.branch_memberships(branch_id, user_id, role, active) values
  ('d1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', 'branch_manager', true),
  ('d1000000-0000-4000-8000-000000000002', 'd2000000-0000-4000-8000-000000000002', 'branch_manager', true)
on conflict (branch_id, user_id) do update set role = excluded.role, active = true;

insert into public.organization_memberships(organization_id, user_id, role) values
  ('d0000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000003', 'organization_manager')
on conflict (organization_id, user_id) do nothing;

-- 3. Anonymous user cannot read catalogs (table select revoked)
set local role anon;
select throws_ok(
  $$select count(*) from public.branch_product_catalog_products$$,
  '42501',
  null,
  'anonymous user cannot read products table'
);

-- Reset role to service_role to invoke RPCs for testing
set local role service_role;

-- 5. Branch manager cannot access another branch RPC
select throws_ok(
  $$select public.list_branch_catalog('d2000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000002')$$,
  '42501',
  'catalog access denied',
  'supervisor A1 cannot list catalog for branch A2'
);

-- 6. Organization manager cannot mutate branch catalog
select throws_ok(
  $$select public.create_branch_catalog_inventory_item('d2000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', '{"name":"Flour","unit":"kg"}'::jsonb)$$,
  '42501',
  'catalog access denied',
  'org manager cannot mutate branch catalog'
);

-- 7 & 8. Create Recipe Product with Bread 1 pcs, Beef Patty 1 pcs, Cheese 1 pcs - rows persist atomically
select lives_ok(
  $$select public.create_branch_catalog_product(
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    jsonb_build_object(
      'name', 'Smoky Burger',
      'inventory_behavior', 'recipe',
      'recipe_rows', jsonb_build_array(
        jsonb_build_object('ingredient', 'Bread', 'quantity', 1, 'unit', 'pcs'),
        jsonb_build_object('ingredient', 'Beef Patty', 'quantity', 1, 'unit', 'pcs'),
        jsonb_build_object('ingredient', 'Cheese', 'quantity', 1, 'unit', 'pcs')
      )
    )
  )$$,
  'create recipe product Smoky Burger succeeds'
);

select is((select count(*)::int from public.branch_product_catalog_products where name = 'Smoky Burger' and branch_id = 'd1000000-0000-4000-8000-000000000001'), 1, 'Smoky Burger product persisted');
select is((select count(*)::int from public.branch_inventory_catalog_items where branch_id = 'd1000000-0000-4000-8000-000000000001' and name in ('Bread', 'Beef Patty', 'Cheese')), 3, '3 recipe ingredients persisted');
select is((select count(*)::int from public.branch_product_usage_mappings where branch_id = 'd1000000-0000-4000-8000-000000000001'), 3, '3 usage mappings persisted');

-- 4. Authenticated branch manager can read own branch via RLS
set local role authenticated;
set local "request.jwt.claim.sub" to 'd2000000-0000-4000-8000-000000000001';
select is((select count(*)::int from public.branch_product_catalog_products where branch_id = 'd1000000-0000-4000-8000-000000000001'), 1, 'supervisor A1 can read own branch products via RLS');
select is((select count(*)::int from public.branch_product_catalog_products where branch_id = 'd1000000-0000-4000-8000-000000000002'), 0, 'supervisor A1 cannot read branch A2 products via RLS');

set local role service_role;

-- 9. Failed ingredient/mapping validation rolls back whole product creation
select throws_ok(
  $$select public.create_branch_catalog_product(
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    jsonb_build_object(
      'name', 'Failed Burger',
      'inventory_behavior', 'recipe',
      'recipe_rows', jsonb_build_array(
        jsonb_build_object('ingredient', 'Sauce', 'quantity', 1, 'unit', 'invalid_unit')
      )
    )
  )$$,
  '22023',
  null,
  'invalid unit in recipe row rolls back'
);
select is((select count(*)::int from public.branch_product_catalog_products where name = 'Failed Burger'), 0, 'Failed Burger product was not created');

-- 10. Same Bread reused for second Product
select lives_ok(
  $$select public.create_branch_catalog_product(
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    jsonb_build_object(
      'name', 'Double Smoky Burger',
      'inventory_behavior', 'recipe',
      'recipe_rows', jsonb_build_array(
        jsonb_build_object('ingredient', 'Bread', 'quantity', 1, 'unit', 'pcs'),
        jsonb_build_object('ingredient', 'Beef Patty', 'quantity', 2, 'unit', 'pcs')
      )
    )
  )$$,
  'create second recipe product succeeds'
);
select is((select count(*)::int from public.branch_inventory_catalog_items where branch_id = 'd1000000-0000-4000-8000-000000000001' and name = 'Bread'), 1, 'Bread inventory item reused, not duplicated');

-- 11. Duplicate recipe inventory item rejected
select throws_ok(
  $$select public.create_branch_catalog_product(
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    jsonb_build_object(
      'name', 'Triple Burger',
      'inventory_behavior', 'recipe',
      'recipe_rows', jsonb_build_array(
        jsonb_build_object('ingredient', 'Bread', 'quantity', 1, 'unit', 'pcs'),
        jsonb_build_object('ingredient', 'Bread', 'quantity', 2, 'unit', 'pcs')
      )
    )
  )$$,
  '23505',
  'duplicate recipe inventory item',
  'duplicate recipe rows with same item are rejected'
);

-- Set role to postgres to test physical table checks & FK constraints directly
set local role postgres;

-- 12. Quantity <= 0 rejected by physical check constraint
select throws_ok(
  $$insert into public.branch_product_usage_mappings(organization_id, branch_id, product_id, inventory_item_id, quantity) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001',
     (select id from public.branch_product_catalog_products where name = 'Smoky Burger'),
     (select id from public.branch_inventory_catalog_items where name = 'Bread' and branch_id = 'd1000000-0000-4000-8000-000000000001'),
     0)$$,
  '23514',
  null,
  'quantity <= 0 rejected by check constraint'
);

-- 13. Tenant integrity: branch A Product -> branch B InventoryItem fails at DB level
insert into public.branch_inventory_catalog_items(organization_id, branch_id, name, unit, kind) values
  ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000002', 'Branch A2 Item', 'pcs', 'standalone_stock');

select throws_ok(
  $$insert into public.branch_product_catalog_products(organization_id, branch_id, name, inventory_behavior, unit, standalone_inventory_item_id) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Cross Product', 'standalone_stock', 'pcs',
     (select id from public.branch_inventory_catalog_items where name = 'Branch A2 Item'))$$,
  '22023',
  'standalone product must reference standalone_stock inventory item',
  'standalone product referencing item in different branch rejected by branch kind trigger'
);

-- 14. Tenant integrity: direct cross-branch ProductUsageMapping fails at DB level
select throws_ok(
  $$insert into public.branch_product_usage_mappings(organization_id, branch_id, product_id, inventory_item_id, quantity) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001',
     (select id from public.branch_product_catalog_products where name = 'Smoky Burger'),
     (select id from public.branch_inventory_catalog_items where name = 'Branch A2 Item'),
     1)$$,
  '23503',
  null,
  'usage mapping referencing item in different branch rejected by composite foreign key'
);

-- 15. Tenant integrity: mismatched organization_id / branch_id fails at DB level
select throws_ok(
  $$insert into public.branch_inventory_catalog_items(organization_id, branch_id, name, unit, kind) values
    ('d0000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'Wrong Org Item', 'pcs', 'ingredient')$$,
  '23503',
  null,
  'mismatched organization_id / branch_id rejected by composite branch_org foreign key'
);

set local role service_role;

-- 16. Standalone stock creates linked standalone item
select lives_ok(
  $$select public.create_branch_catalog_product(
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    jsonb_build_object(
      'name', 'Bottled Water',
      'inventory_behavior', 'standalone_stock',
      'unit', 'pcs'
    )
  )$$,
  'create standalone stock product succeeds'
);
select is((select kind from public.branch_inventory_catalog_items where name = 'Bottled Water' and branch_id = 'd1000000-0000-4000-8000-000000000001'), 'standalone_stock', 'standalone product created standalone_stock kind inventory item');

set local role postgres;

-- 17. Standalone Product cannot point to ingredient-kind InventoryItem
select throws_ok(
  $$insert into public.branch_product_catalog_products(organization_id, branch_id, name, inventory_behavior, unit, standalone_inventory_item_id) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Fake Standalone', 'standalone_stock', 'pcs',
     (select id from public.branch_inventory_catalog_items where name = 'Bread' and branch_id = 'd1000000-0000-4000-8000-000000000001'))$$,
  '22023',
  'standalone product must reference standalone_stock inventory item',
  'standalone product cannot reference ingredient item'
);

set local role service_role;

-- 18 & 19. Non-stock and standalone_stock cannot have recipe mappings
select lives_ok(
  $$select public.create_branch_catalog_product(
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    jsonb_build_object(
      'name', 'Service Fee',
      'inventory_behavior', 'non_stock'
    )
  )$$,
  'create non-stock product succeeds'
);

set local role postgres;

select throws_ok(
  $$insert into public.branch_product_usage_mappings(organization_id, branch_id, product_id, inventory_item_id, quantity) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001',
     (select id from public.branch_product_catalog_products where name = 'Service Fee'),
     (select id from public.branch_inventory_catalog_items where name = 'Bread' and branch_id = 'd1000000-0000-4000-8000-000000000001'),
     1)$$,
  '22023',
  'recipe usage mappings can only be created for recipe products',
  'non-stock product cannot have recipe mappings'
);

select throws_ok(
  $$insert into public.branch_product_usage_mappings(organization_id, branch_id, product_id, inventory_item_id, quantity) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001',
     (select id from public.branch_product_catalog_products where name = 'Bottled Water'),
     (select id from public.branch_inventory_catalog_items where name = 'Bread' and branch_id = 'd1000000-0000-4000-8000-000000000001'),
     1)$$,
  '22023',
  'recipe usage mappings can only be created for recipe products',
  'standalone stock product cannot have recipe mappings'
);

-- 20. Recipe cannot have standalone_inventory_item_id
select throws_ok(
  $$insert into public.branch_product_catalog_products(organization_id, branch_id, name, inventory_behavior, unit, standalone_inventory_item_id) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Hybrid Burger', 'recipe', null,
     (select id from public.branch_inventory_catalog_items where name = 'Bottled Water' and branch_id = 'd1000000-0000-4000-8000-000000000001'))$$,
  '23514',
  null,
  'recipe product cannot have standalone_inventory_item_id'
);

set local role service_role;

-- 21 & 22. Atomicity: force failure on final recipe row and confirm no partial state remains
select throws_ok(
  $$select public.create_branch_catalog_product(
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    jsonb_build_object(
      'name', 'Atomicity Fail Product',
      'inventory_behavior', 'recipe',
      'recipe_rows', jsonb_build_array(
        jsonb_build_object('ingredient', 'Fresh Lettuce', 'quantity', 1, 'unit', 'pcs'),
        jsonb_build_object('ingredient', 'Tomato', 'quantity', 1, 'unit', 'bad_unit')
      )
    )
  )$$,
  '22023',
  null,
  'recipe creation failure on second item rolls back'
);
select is((select count(*)::int from public.branch_product_catalog_products where name = 'Atomicity Fail Product'), 0, 'failed product not in DB');
select is((select count(*)::int from public.branch_inventory_catalog_items where name = 'Fresh Lettuce'), 0, 'first item Fresh Lettuce not in DB (atomically rolled back)');

-- 23 & 24. Raw table privileges: authenticated direct INSERT / UPDATE denied
set local role authenticated;
set local "request.jwt.claim.sub" to 'd2000000-0000-4000-8000-000000000001';

select throws_ok(
  $$insert into public.branch_inventory_catalog_items(organization_id, branch_id, name, unit, kind) values
    ('d0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Raw Insert', 'pcs', 'ingredient')$$,
  '42501',
  null,
  'authenticated direct INSERT denied on branch_inventory_catalog_items'
);

select throws_ok(
  $$update public.branch_inventory_catalog_items set name = 'Hacked' where name = 'Bread'$$,
  '42501',
  null,
  'authenticated direct UPDATE denied on branch_inventory_catalog_items'
);

select * from finish();
rollback;
