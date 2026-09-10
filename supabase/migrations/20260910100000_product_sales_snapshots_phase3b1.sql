create table if not exists public.branch_product_sales_daily_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  business_date date not null,
  revision bigint not null default 1,
  created_by_user_id uuid not null references public.profiles(id) on delete restrict,
  updated_by_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_product_sales_daily_reports_revision_check check (revision >= 1),
  constraint branch_product_sales_daily_reports_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_product_sales_daily_reports_branch_date_key unique (branch_id, business_date),
  constraint branch_product_sales_daily_reports_scope_key unique (id, organization_id, branch_id, business_date)
);

create table if not exists public.branch_product_sales (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.branch_product_sales_daily_reports(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  business_date date not null,
  product_id uuid not null references public.branch_product_catalog_products(id) on delete restrict,
  product_name_snapshot text not null,
  inventory_behavior_snapshot text not null,
  product_unit_snapshot text null,
  quantity numeric not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_product_sales_quantity_check check (quantity >= 0),
  constraint branch_product_sales_product_name_snapshot_check check (product_name_snapshot = pg_catalog.regexp_replace(pg_catalog.btrim(product_name_snapshot), '[[:space:]]+', ' ', 'g') and length(product_name_snapshot) between 1 and 120),
  constraint branch_product_sales_behavior_snapshot_check check (inventory_behavior_snapshot in ('recipe','standalone_stock','non_stock')),
  constraint branch_product_sales_unit_snapshot_check check (product_unit_snapshot is null or product_unit_snapshot in ('pcs','kg','g','L','ml')),
  constraint branch_product_sales_report_scope_fk foreign key (report_id, organization_id, branch_id, business_date) references public.branch_product_sales_daily_reports(id, organization_id, branch_id, business_date) on delete cascade,
  constraint branch_product_sales_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_product_sales_product_fk foreign key (branch_id, product_id) references public.branch_product_catalog_products(branch_id, id) on delete restrict,
  constraint branch_product_sales_report_product_key unique (report_id, product_id),
  constraint branch_product_sales_branch_date_product_key unique (branch_id, business_date, product_id),
  constraint branch_product_sales_scope_key unique (id, report_id, organization_id, branch_id, business_date, product_id)
);

create table if not exists public.branch_product_sales_usage_snapshots (
  id uuid primary key default gen_random_uuid(),
  product_sale_id uuid not null references public.branch_product_sales(id) on delete cascade,
  report_id uuid not null references public.branch_product_sales_daily_reports(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  business_date date not null,
  product_id uuid not null references public.branch_product_catalog_products(id) on delete restrict,
  product_name_snapshot text not null,
  inventory_behavior_snapshot text not null,
  inventory_item_id uuid not null references public.branch_inventory_catalog_items(id) on delete restrict,
  inventory_item_name_snapshot text not null,
  inventory_item_unit_snapshot text not null,
  quantity_per_sale_snapshot numeric not null,
  sales_quantity_snapshot numeric not null,
  total_usage_quantity numeric not null,
  recipe_mapping_id uuid null references public.branch_product_usage_mappings(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint branch_product_sales_usage_product_name_snapshot_check check (product_name_snapshot = pg_catalog.regexp_replace(pg_catalog.btrim(product_name_snapshot), '[[:space:]]+', ' ', 'g') and length(product_name_snapshot) between 1 and 120),
  constraint branch_product_sales_usage_behavior_snapshot_check check (inventory_behavior_snapshot in ('recipe','standalone_stock')),
  constraint branch_product_sales_usage_item_name_snapshot_check check (inventory_item_name_snapshot = pg_catalog.regexp_replace(pg_catalog.btrim(inventory_item_name_snapshot), '[[:space:]]+', ' ', 'g') and length(inventory_item_name_snapshot) between 1 and 120),
  constraint branch_product_sales_usage_item_unit_snapshot_check check (inventory_item_unit_snapshot in ('pcs','kg','g','L','ml')),
  constraint branch_product_sales_usage_quantity_per_sale_check check (quantity_per_sale_snapshot > 0),
  constraint branch_product_sales_usage_sales_quantity_check check (sales_quantity_snapshot >= 0),
  constraint branch_product_sales_usage_total_usage_check check (total_usage_quantity >= 0),
  constraint branch_product_sales_usage_report_scope_fk foreign key (report_id, organization_id, branch_id, business_date) references public.branch_product_sales_daily_reports(id, organization_id, branch_id, business_date) on delete cascade,
  constraint branch_product_sales_usage_sale_scope_fk foreign key (product_sale_id, report_id, organization_id, branch_id, business_date, product_id) references public.branch_product_sales(id, report_id, organization_id, branch_id, business_date, product_id) on delete cascade,
  constraint branch_product_sales_usage_branch_org_fk foreign key (branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint branch_product_sales_usage_product_fk foreign key (branch_id, product_id) references public.branch_product_catalog_products(branch_id, id) on delete restrict,
  constraint branch_product_sales_usage_inventory_item_fk foreign key (branch_id, inventory_item_id) references public.branch_inventory_catalog_items(branch_id, id) on delete restrict,
  constraint branch_product_sales_usage_sale_item_key unique (product_sale_id, inventory_item_id)
);

create index if not exists branch_product_sales_daily_reports_branch_date_idx
on public.branch_product_sales_daily_reports(branch_id, business_date desc);

create index if not exists branch_product_sales_report_idx
on public.branch_product_sales(report_id, product_id);

create index if not exists branch_product_sales_branch_date_idx
on public.branch_product_sales(branch_id, business_date, product_id);

create index if not exists branch_product_sales_usage_report_idx
on public.branch_product_sales_usage_snapshots(report_id, inventory_item_id);

create index if not exists branch_product_sales_usage_branch_date_item_idx
on public.branch_product_sales_usage_snapshots(branch_id, business_date, inventory_item_id);

drop trigger if exists branch_product_sales_daily_reports_set_updated_at on public.branch_product_sales_daily_reports;
create trigger branch_product_sales_daily_reports_set_updated_at
before update on public.branch_product_sales_daily_reports
for each row execute function private.set_updated_at();

drop trigger if exists branch_product_sales_set_updated_at on public.branch_product_sales;
create trigger branch_product_sales_set_updated_at
before update on public.branch_product_sales
for each row execute function private.set_updated_at();

alter table public.branch_product_sales_daily_reports enable row level security;
alter table public.branch_product_sales enable row level security;
alter table public.branch_product_sales_usage_snapshots enable row level security;

revoke all on table public.branch_product_sales_daily_reports, public.branch_product_sales, public.branch_product_sales_usage_snapshots from public, anon, authenticated, service_role;
grant select on table public.branch_product_sales_daily_reports, public.branch_product_sales, public.branch_product_sales_usage_snapshots to authenticated, service_role;

create policy branch_product_sales_daily_reports_select_authorized
on public.branch_product_sales_daily_reports for select to authenticated
using (private.has_branch_access(branch_id));

create policy branch_product_sales_select_authorized
on public.branch_product_sales for select to authenticated
using (private.has_branch_access(branch_id));

create policy branch_product_sales_usage_snapshots_select_authorized
on public.branch_product_sales_usage_snapshots for select to authenticated
using (private.has_branch_access(branch_id));

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
      ) order by pg_catalog.lower(sale.product_name_snapshot), sale.product_id)
      from public.branch_product_sales sale
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
      ) order by pg_catalog.lower(usage.product_name_snapshot), pg_catalog.lower(usage.inventory_item_name_snapshot), usage.id)
      from public.branch_product_sales_usage_snapshots usage
      where usage.report_id = report.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'product sales access denied' using errcode = '42501';
end;
$$;

create or replace function public.get_branch_product_sales(actor_user_id uuid, target_branch_id uuid, target_business_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return private.branch_product_sales_payload(actor_user_id, target_branch_id, target_business_date);
end;
$$;

create or replace function public.save_branch_product_sales(
  actor_user_id uuid,
  target_branch_id uuid,
  target_business_date date,
  expected_revision bigint,
  sales jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_product_sales_daily_reports%rowtype;
  sale_row jsonb;
  parsed_product_id uuid;
  parsed_quantity numeric;
  submitted_count integer;
  changed boolean := false;
begin
  select * into strict ctx from private.phase2_branch_context(actor_user_id, target_branch_id);
  if target_business_date is null then
    raise exception 'product sales business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'product sales future business date denied' using errcode = '22023';
  end if;
  if coalesce(expected_revision, -1) < 0 then
    raise exception 'invalid product sales revision' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(sales, '[]'::jsonb)) <> 'array' then
    raise exception 'invalid product sales payload' using errcode = '22023';
  end if;

  drop table if exists pg_temp.branch_product_sales_stage;
  drop table if exists pg_temp.branch_product_sales_existing;

  create temp table branch_product_sales_stage(
    product_id uuid primary key,
    quantity numeric not null check (quantity >= 0)
  ) on commit drop;

  for sale_row in select * from pg_catalog.jsonb_array_elements(coalesce(sales, '[]'::jsonb)) loop
    if jsonb_typeof(sale_row) <> 'object' then
      raise exception 'invalid product sales payload' using errcode = '22023';
    end if;
    begin
      parsed_product_id := (sale_row->>'product_id')::uuid;
      parsed_quantity := (sale_row->>'quantity')::numeric;
    exception when others then
      raise exception 'invalid product sales payload' using errcode = '22023';
    end;
    if parsed_product_id is null or parsed_quantity is null or parsed_quantity < 0 then
      raise exception 'invalid product sales quantity' using errcode = '22023';
    end if;
    begin
      insert into branch_product_sales_stage(product_id, quantity)
      values (parsed_product_id, parsed_quantity);
    exception when unique_violation then
      raise exception 'duplicate product sale' using errcode = '23505';
    end;
  end loop;

  select count(*) into submitted_count from branch_product_sales_stage;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(ctx.organization_id::text || ':' || ctx.branch_id::text || ':' || target_business_date::text || ':product_sales', 0)
  );

  select * into report
  from public.branch_product_sales_daily_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date
  for update;

  if report.id is null and coalesce(expected_revision, 0) <> 0 then
    raise exception 'product sales changed' using errcode = '40001';
  end if;
  if report.id is not null and expected_revision <> report.revision then
    raise exception 'product sales changed' using errcode = '40001';
  end if;
  if report.id is null and submitted_count = 0 then
    return private.branch_product_sales_payload(actor_user_id, target_branch_id, target_business_date);
  end if;

  create temp table branch_product_sales_existing on commit drop as
  select sale.id, sale.product_id, sale.inventory_behavior_snapshot, sale.quantity
  from public.branch_product_sales sale
  where sale.report_id = report.id;

  if exists (
    select 1
    from branch_product_sales_stage stage
    left join branch_product_sales_existing existing
      on existing.product_id = stage.product_id
    left join public.branch_product_catalog_products product
      on product.id = stage.product_id
     and product.organization_id = ctx.organization_id
     and product.branch_id = ctx.branch_id
     and product.is_active
     and product.inventory_behavior in ('recipe','standalone_stock','non_stock')
    where existing.id is null
      and product.id is null
  ) then
    raise exception 'product sale product unavailable' using errcode = '42501';
  end if;

  if exists (
    select 1
    from branch_product_sales_stage stage
    left join branch_product_sales_existing existing
      on existing.product_id = stage.product_id
    join public.branch_product_catalog_products product
      on product.id = stage.product_id
     and product.organization_id = ctx.organization_id
     and product.branch_id = ctx.branch_id
     and product.is_active
    where existing.id is null
      and product.inventory_behavior = 'recipe'
      and not exists (
        select 1 from public.branch_product_usage_mappings mapping
        where mapping.organization_id = ctx.organization_id
          and mapping.branch_id = ctx.branch_id
          and mapping.product_id = product.id
      )
  ) then
    raise exception 'recipe product has no inventory mappings' using errcode = '22023';
  end if;

  if exists (
    select 1
    from branch_product_sales_stage stage
    left join branch_product_sales_existing existing
      on existing.product_id = stage.product_id
    join public.branch_product_catalog_products product
      on product.id = stage.product_id
     and product.organization_id = ctx.organization_id
     and product.branch_id = ctx.branch_id
     and product.is_active
    left join public.branch_inventory_catalog_items item
      on item.id = product.standalone_inventory_item_id
     and item.organization_id = ctx.organization_id
     and item.branch_id = ctx.branch_id
     and item.kind = 'standalone_stock'
    where existing.id is null
      and product.inventory_behavior = 'standalone_stock'
      and item.id is null
  ) then
    raise exception 'standalone product inventory item unavailable' using errcode = '22023';
  end if;

  if exists (
    select 1
    from branch_product_sales_stage stage
    join branch_product_sales_existing existing
      on existing.product_id = stage.product_id
    where existing.inventory_behavior_snapshot = 'recipe'
      and not exists (
        select 1
        from public.branch_product_sales_usage_snapshots usage
        where usage.product_sale_id = existing.id
      )
  ) then
    raise exception 'product sales frozen usage snapshot missing' using errcode = '22000';
  end if;

  if exists (
    select 1
    from branch_product_sales_stage stage
    join branch_product_sales_existing existing
      on existing.product_id = stage.product_id
    where existing.inventory_behavior_snapshot = 'standalone_stock'
      and (
        select count(*) from public.branch_product_sales_usage_snapshots usage
        where usage.product_sale_id = existing.id
      ) <> 1
  ) then
    raise exception 'product sales frozen usage snapshot missing' using errcode = '22000';
  end if;

  if exists (
    select 1
    from branch_product_sales_stage stage
    join branch_product_sales_existing existing
      on existing.product_id = stage.product_id
    where existing.inventory_behavior_snapshot = 'non_stock'
      and exists (
        select 1
        from public.branch_product_sales_usage_snapshots usage
        where usage.product_sale_id = existing.id
      )
  ) then
    raise exception 'product sales frozen usage snapshot corrupt' using errcode = '22000';
  end if;

  if report.id is null then
    changed := submitted_count > 0;
  else
    changed := exists (
      select 1
      from branch_product_sales_stage stage
      left join public.branch_product_sales existing
        on existing.report_id = report.id
       and existing.product_id = stage.product_id
      where existing.id is null
        or existing.quantity <> stage.quantity
    );
  end if;

  if not changed then
    return private.branch_product_sales_payload(actor_user_id, target_branch_id, target_business_date);
  end if;

  if report.id is null then
    insert into public.branch_product_sales_daily_reports(
      organization_id, branch_id, business_date, revision, created_by_user_id, updated_by_user_id
    ) values (
      ctx.organization_id, ctx.branch_id, target_business_date, 1, actor_user_id, actor_user_id
    ) returning * into report;
  else
    update public.branch_product_sales_daily_reports existing
    set revision = existing.revision + 1,
        updated_by_user_id = actor_user_id,
        updated_at = now()
    where existing.id = report.id
    returning * into report;
  end if;

  update public.branch_product_sales sale
  set quantity = stage.quantity,
      updated_at = now()
  from branch_product_sales_stage stage
  where sale.report_id = report.id
    and sale.product_id = stage.product_id
    and sale.quantity <> stage.quantity;

  insert into public.branch_product_sales(
    report_id, organization_id, branch_id, business_date, product_id,
    product_name_snapshot, inventory_behavior_snapshot, product_unit_snapshot, quantity
  )
  select report.id, ctx.organization_id, ctx.branch_id, target_business_date, product.id,
    product.name, product.inventory_behavior, product.unit, stage.quantity
  from branch_product_sales_stage stage
  join public.branch_product_catalog_products product
    on product.id = stage.product_id
   and product.organization_id = ctx.organization_id
   and product.branch_id = ctx.branch_id
   and product.is_active
  left join branch_product_sales_existing existing
    on existing.product_id = stage.product_id
  where existing.id is null;

  update public.branch_product_sales_usage_snapshots usage
  set sales_quantity_snapshot = sale.quantity,
      total_usage_quantity = usage.quantity_per_sale_snapshot * sale.quantity
  from public.branch_product_sales sale
  join branch_product_sales_stage stage
    on stage.product_id = sale.product_id
  where usage.product_sale_id = sale.id
    and sale.report_id = report.id
    and sale.inventory_behavior_snapshot in ('recipe','standalone_stock');

  insert into public.branch_product_sales_usage_snapshots(
    product_sale_id, report_id, organization_id, branch_id, business_date, product_id,
    product_name_snapshot, inventory_behavior_snapshot, inventory_item_id,
    inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity_per_sale_snapshot,
    sales_quantity_snapshot, total_usage_quantity, recipe_mapping_id
  )
  select sale.id, report.id, ctx.organization_id, ctx.branch_id, target_business_date, sale.product_id,
    sale.product_name_snapshot, sale.inventory_behavior_snapshot, item.id,
    item.name, item.unit, mapping.quantity, sale.quantity, sale.quantity * mapping.quantity, mapping.id
  from public.branch_product_sales sale
  join public.branch_product_usage_mappings mapping
    on mapping.organization_id = ctx.organization_id
   and mapping.branch_id = ctx.branch_id
   and mapping.product_id = sale.product_id
  join public.branch_inventory_catalog_items item
    on item.organization_id = ctx.organization_id
   and item.branch_id = ctx.branch_id
   and item.id = mapping.inventory_item_id
  where sale.report_id = report.id
    and sale.inventory_behavior_snapshot = 'recipe'
    and exists (
      select 1 from branch_product_sales_stage stage
      where stage.product_id = sale.product_id
    )
    and not exists (
      select 1 from public.branch_product_sales_usage_snapshots existing_usage
      where existing_usage.product_sale_id = sale.id
    );

  insert into public.branch_product_sales_usage_snapshots(
    product_sale_id, report_id, organization_id, branch_id, business_date, product_id,
    product_name_snapshot, inventory_behavior_snapshot, inventory_item_id,
    inventory_item_name_snapshot, inventory_item_unit_snapshot, quantity_per_sale_snapshot,
    sales_quantity_snapshot, total_usage_quantity, recipe_mapping_id
  )
  select sale.id, report.id, ctx.organization_id, ctx.branch_id, target_business_date, sale.product_id,
    sale.product_name_snapshot, sale.inventory_behavior_snapshot, item.id,
    item.name, item.unit, 1, sale.quantity, sale.quantity, null
  from public.branch_product_sales sale
  join public.branch_product_catalog_products product
    on product.organization_id = ctx.organization_id
   and product.branch_id = ctx.branch_id
   and product.id = sale.product_id
  join public.branch_inventory_catalog_items item
    on item.organization_id = ctx.organization_id
   and item.branch_id = ctx.branch_id
   and item.id = product.standalone_inventory_item_id
   and item.kind = 'standalone_stock'
  where sale.report_id = report.id
    and sale.inventory_behavior_snapshot = 'standalone_stock'
    and exists (
      select 1 from branch_product_sales_stage stage
      where stage.product_id = sale.product_id
    )
    and not exists (
      select 1 from public.branch_product_sales_usage_snapshots existing_usage
      where existing_usage.product_sale_id = sale.id
    );

  return private.branch_product_sales_payload(actor_user_id, target_branch_id, target_business_date);
exception
  when no_data_found or too_many_rows then
    raise exception 'product sales access denied' using errcode = '42501';
end;
$$;

revoke all on function private.branch_product_sales_payload(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.get_branch_product_sales(uuid, uuid, date), public.save_branch_product_sales(uuid, uuid, date, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.get_branch_product_sales(uuid, uuid, date), public.save_branch_product_sales(uuid, uuid, date, bigint, jsonb) to service_role;
