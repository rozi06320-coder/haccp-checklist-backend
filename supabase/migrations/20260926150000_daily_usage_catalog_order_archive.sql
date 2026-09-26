alter table public.branch_product_catalog_products
  add column if not exists display_order integer;

with ranked as (
  select
    product.id,
    row_number() over (
      partition by product.branch_id
      order by pg_catalog.lower(product.name), product.id
    )::integer as position
  from public.branch_product_catalog_products product
  where product.is_active
)
update public.branch_product_catalog_products product
set display_order = ranked.position
from ranked
where ranked.id = product.id
  and product.display_order is null;

alter table public.branch_product_catalog_products
  add constraint branch_product_catalog_products_display_order_check
  check (display_order is null or display_order > 0);

create index if not exists branch_product_catalog_products_branch_order_idx
on public.branch_product_catalog_products(branch_id, is_active, display_order, name, id);

create or replace function private.lock_branch_catalog(target_organization_id uuid, target_branch_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(target_organization_id::text || ':' || target_branch_id::text || ':branch_catalog', 0)
  );
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
        'display_order', product.display_order,
        'created_at', product.created_at,
        'updated_at', product.updated_at
      ) order by product.display_order asc nulls last, pg_catalog.lower(product.name), product.id)
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

create or replace function public.archive_branch_catalog_inventory_item(
  actor_user_id uuid,
  target_branch_id uuid,
  target_inventory_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  target_item public.branch_inventory_catalog_items%rowtype;
  blocking_products jsonb;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);
  perform private.lock_branch_catalog(target_branch.organization_id, target_branch.id);

  select item.* into target_item
  from public.branch_inventory_catalog_items item
  where item.id = target_inventory_item_id
    and item.branch_id = target_branch.id
  for update;

  if target_item.id is null then
    raise exception 'inventory item unavailable' using errcode = 'P0002';
  end if;

  if target_item.kind <> 'ingredient' then
    raise exception 'only ingredients can be archived' using errcode = '22023';
  end if;

  if not target_item.is_active then
    raise exception 'inventory item unavailable' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', product.id, 'name', product.name)
    order by product.display_order asc nulls last, pg_catalog.lower(product.name), product.id), '[]'::jsonb)
  into blocking_products
  from public.branch_product_usage_mappings mapping
  join public.branch_product_catalog_products product
    on product.id = mapping.product_id
   and product.branch_id = target_branch.id
   and product.organization_id = target_branch.organization_id
   and product.is_active
  where mapping.organization_id = target_branch.organization_id
    and mapping.branch_id = target_branch.id
    and mapping.inventory_item_id = target_item.id;

  if jsonb_array_length(blocking_products) > 0 then
    raise exception 'ingredient is used by active products'
      using errcode = '23505',
            detail = blocking_products::text;
  end if;

  update public.branch_inventory_catalog_items item
  set is_active = false,
      updated_at = now()
  where item.id = target_item.id;

  return private.branch_catalog_payload(target_branch.id);
end;
$$;

create or replace function public.reorder_branch_catalog_products(
  actor_user_id uuid,
  target_branch_id uuid,
  ordered_product_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  submitted_count integer;
  distinct_submitted_count integer;
  active_count integer;
begin
  target_branch := private.require_branch_catalog_scope(actor_user_id, target_branch_id);

  if ordered_product_ids is null then
    raise exception 'product order required' using errcode = '22023';
  end if;

  perform private.lock_branch_catalog(target_branch.organization_id, target_branch.id);

  select
    count(*)::integer,
    count(distinct submitted.product_id)::integer
  into submitted_count, distinct_submitted_count
  from unnest(ordered_product_ids) with ordinality as submitted(product_id, ordinality);

  if submitted_count <> distinct_submitted_count then
    raise exception 'duplicate product id in order' using errcode = '23505';
  end if;

  perform 1
  from public.branch_product_catalog_products product
  where product.organization_id = target_branch.organization_id
    and product.branch_id = target_branch.id
    and product.is_active
  order by product.id
  for update;

  select count(*)::integer into active_count
  from public.branch_product_catalog_products product
  where product.organization_id = target_branch.organization_id
    and product.branch_id = target_branch.id
    and product.is_active;

  if submitted_count <> active_count then
    raise exception 'product order must include every active product' using errcode = '22023';
  end if;

  if exists (
    select 1
    from unnest(ordered_product_ids) with ordinality as stage(product_id, display_order)
    left join public.branch_product_catalog_products product
      on product.id = stage.product_id
     and product.organization_id = target_branch.organization_id
     and product.branch_id = target_branch.id
     and product.is_active
    where product.id is null
  ) then
    raise exception 'product order contains unavailable product' using errcode = '42501';
  end if;

  update public.branch_product_catalog_products product
  set display_order = stage.display_order,
      updated_at = now()
  from (
    select submitted.product_id, submitted.ordinality::integer as display_order
    from unnest(ordered_product_ids) with ordinality as submitted(product_id, ordinality)
  ) stage
  where product.id = stage.product_id
    and product.organization_id = target_branch.organization_id
    and product.branch_id = target_branch.id
    and product.is_active;

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
  perform private.lock_branch_catalog(target_branch.organization_id, target_branch.id);

  if jsonb_typeof(coalesce(recipe_rows, '[]'::jsonb)) <> 'array' then
    raise exception 'invalid recipe payload' using errcode = '22023';
  end if;

  select product.* into target_product
  from public.branch_product_catalog_products product
  where product.id = target_product_id
    and product.organization_id = target_branch.organization_id
    and product.branch_id = target_branch.id
  for update;

  if target_product.id is null or not target_product.is_active or target_product.inventory_behavior <> 'recipe' then
    raise exception 'product unavailable' using errcode = '22023';
  end if;

  create temp table branch_catalog_recipe_stage(
    inventory_item_id uuid primary key,
    quantity numeric not null check(quantity > 0)
  ) on commit drop;

  for recipe_row in select * from jsonb_array_elements(coalesce(recipe_rows, '[]'::jsonb)) loop
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
    insert into branch_catalog_recipe_stage(inventory_item_id, quantity)
    values (target_item.id, (recipe_row->>'quantity')::numeric);
  end loop;

  perform 1
  from public.branch_inventory_catalog_items item
  join branch_catalog_recipe_stage stage on stage.inventory_item_id = item.id
  where item.organization_id = target_branch.organization_id
    and item.branch_id = target_branch.id
    and item.is_active
    and item.kind = 'ingredient'
  order by item.id
  for update;

  if exists (
    select 1
    from branch_catalog_recipe_stage stage
    left join public.branch_inventory_catalog_items item
      on item.id = stage.inventory_item_id
     and item.organization_id = target_branch.organization_id
     and item.branch_id = target_branch.id
     and item.is_active
     and item.kind = 'ingredient'
    where item.id is null
  ) then
    raise exception 'inventory item unavailable' using errcode = '22023';
  end if;

  delete from public.branch_product_usage_mappings mapping
  where mapping.product_id = target_product.id;

  insert into public.branch_product_usage_mappings(organization_id, branch_id, product_id, inventory_item_id, quantity)
  select target_branch.organization_id, target_branch.id, target_product.id, stage.inventory_item_id, stage.quantity
  from branch_catalog_recipe_stage stage;

  return private.branch_catalog_payload(target_branch.id);
end;
$$;

create or replace function private.branch_product_sales_payload(actor_user_id uuid, target_branch_id uuid, target_business_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_product_sales_daily_reports%rowtype;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if target_business_date is null then
    raise exception 'product sales business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'product sales future business date denied' using errcode = '22023';
  end if;

  select * into report
  from public.branch_product_sales_daily_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'organization_id', ctx.organization_id,
    'branch_id', ctx.branch_id,
    'business_date', target_business_date,
    'current_business_date', ctx.business_date,
    'revision', coalesce(report.revision, 0),
    'created_at', report.created_at,
    'updated_at', report.updated_at,
    'sales', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', sale.id,
        'product_id', sale.product_id,
        'product_name_snapshot', sale.product_name_snapshot,
        'inventory_behavior_snapshot', sale.inventory_behavior_snapshot,
        'product_unit_snapshot', sale.product_unit_snapshot,
        'quantity', sale.quantity,
        'created_at', sale.created_at,
        'updated_at', sale.updated_at
      ) order by product.display_order asc nulls last, pg_catalog.lower(sale.product_name_snapshot), sale.product_id)
      from public.branch_product_sales sale
      left join public.branch_product_catalog_products product
        on product.id = sale.product_id
       and product.branch_id = sale.branch_id
      where sale.report_id = report.id
    ), '[]'::jsonb),
    'usage_snapshots', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', usage.id,
        'product_sale_id', usage.product_sale_id,
        'product_id', usage.product_id,
        'product_name_snapshot', usage.product_name_snapshot,
        'inventory_behavior_snapshot', usage.inventory_behavior_snapshot,
        'inventory_item_id', usage.inventory_item_id,
        'inventory_item_name_snapshot', usage.inventory_item_name_snapshot,
        'inventory_item_unit_snapshot', usage.inventory_item_unit_snapshot,
        'quantity_per_sale_snapshot', usage.quantity_per_sale_snapshot,
        'sales_quantity_snapshot', usage.sales_quantity_snapshot,
        'total_usage_quantity', usage.total_usage_quantity,
        'recipe_mapping_id', usage.recipe_mapping_id,
        'created_at', usage.created_at
      ) order by product.display_order asc nulls last, pg_catalog.lower(usage.product_name_snapshot), pg_catalog.lower(usage.inventory_item_name_snapshot), usage.id)
      from public.branch_product_sales_usage_snapshots usage
      left join public.branch_product_catalog_products product
        on product.id = usage.product_id
       and product.branch_id = usage.branch_id
      where usage.report_id = report.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'product sales access denied' using errcode = '42501';
end;
$$;

create or replace function public.list_managed_product_sales_usage(
  actor_user_id uuid,
  target_organization_id uuid,
  from_date date,
  to_date date,
  target_branch_id uuid default null,
  target_inventory_item_id uuid default null,
  requested_page integer default 1,
  requested_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  page_offset integer;
  result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'managed product sales usage access denied' using errcode = '42501';
  end if;
  if target_branch_id is not null and not exists (
    select 1 from public.branches b
    where b.id = target_branch_id and b.organization_id = target_organization_id and b.active
  ) then
    raise exception 'managed product sales usage access denied' using errcode = '42501';
  end if;
  if target_inventory_item_id is not null and not exists (
    select 1 from public.branch_inventory_catalog_items item
    where item.id = target_inventory_item_id and item.organization_id = target_organization_id
  ) then
    raise exception 'managed product sales usage access denied' using errcode = '42501';
  end if;
  if from_date is null or to_date is null then
    raise exception 'date range required' using errcode = '22004';
  end if;
  if from_date > to_date then
    raise exception 'invalid date range' using errcode = '22023';
  end if;
  if (to_date - from_date) > 90 then
    raise exception 'date range exceeds maximum of 90 days' using errcode = '22023';
  end if;
  if requested_page < 1 or requested_page_size not between 1 and 100 then
    raise exception 'invalid pagination parameters' using errcode = '22023';
  end if;

  page_offset := (requested_page - 1) * requested_page_size;

  with usage_items as (
    select
      usage.id as usage_id,
      usage.business_date,
      usage.branch_id,
      branch.name as branch_name,
      usage.product_id,
      usage.product_name_snapshot,
      product.display_order as product_display_order,
      sale.product_unit_snapshot,
      usage.inventory_behavior_snapshot,
      usage.inventory_item_id,
      usage.inventory_item_name_snapshot,
      usage.inventory_item_unit_snapshot,
      usage.sales_quantity_snapshot as sales_quantity,
      usage.quantity_per_sale_snapshot,
      usage.total_usage_quantity,
      report.revision as report_revision,
      report.created_at as report_created_at,
      report.updated_at as report_updated_at,
      count(*) over() as total_count,
      row_number() over(
        order by usage.business_date desc, branch.name asc, product.display_order asc nulls last, pg_catalog.lower(usage.product_name_snapshot) asc, pg_catalog.lower(usage.inventory_item_name_snapshot) asc, usage.id desc
      ) as row_num
    from public.branch_product_sales_usage_snapshots usage
    join public.branch_product_sales sale
      on sale.id = usage.product_sale_id
    join public.branch_product_sales_daily_reports report
      on report.id = usage.report_id
    join public.branches branch
      on branch.id = usage.branch_id
    left join public.branch_product_catalog_products product
      on product.id = usage.product_id
     and product.branch_id = usage.branch_id
    where usage.organization_id = target_organization_id
      and usage.business_date >= from_date
      and usage.business_date <= to_date
      and (target_branch_id is null or usage.branch_id = target_branch_id)
      and (target_inventory_item_id is null or usage.inventory_item_id = target_inventory_item_id)
  )
  select pg_catalog.jsonb_build_object(
    'rows', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'business_date', u.business_date,
          'branch_id', u.branch_id,
          'branch_name', u.branch_name,
          'product_id', u.product_id,
          'product_name_snapshot', u.product_name_snapshot,
          'product_display_order', u.product_display_order,
          'product_unit_snapshot', u.product_unit_snapshot,
          'inventory_behavior_snapshot', u.inventory_behavior_snapshot,
          'inventory_item_id', u.inventory_item_id,
          'inventory_item_name_snapshot', u.inventory_item_name_snapshot,
          'inventory_item_unit_snapshot', u.inventory_item_unit_snapshot,
          'sales_quantity', u.sales_quantity,
          'quantity_per_sale_snapshot', u.quantity_per_sale_snapshot,
          'total_usage_quantity', u.total_usage_quantity,
          'report_revision', u.report_revision,
          'report_created_at', u.report_created_at,
          'report_updated_at', u.report_updated_at
        ) order by u.row_num
      )
      from usage_items u
      where u.row_num > page_offset and u.row_num <= (page_offset + requested_page_size)
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total_rows', coalesce((select max(u.total_count) from usage_items u), 0),
    'total_pages', case
      when coalesce((select max(u.total_count) from usage_items u), 0) = 0 then 0
      else ceil((select max(u.total_count) from usage_items u)::numeric / requested_page_size)::integer
    end,
    'from_date', from_date,
    'to_date', to_date
  ) into result;

  return result;
end;
$$;

revoke all on function private.lock_branch_catalog(uuid, uuid) from public, anon, authenticated;
revoke all on function public.save_branch_product_usage_mappings(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.archive_branch_catalog_inventory_item(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.reorder_branch_catalog_products(uuid, uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.save_branch_product_usage_mappings(uuid, uuid, uuid, jsonb) to service_role;
grant execute on function public.archive_branch_catalog_inventory_item(uuid, uuid, uuid) to service_role;
grant execute on function public.reorder_branch_catalog_products(uuid, uuid, uuid[]) to service_role;
