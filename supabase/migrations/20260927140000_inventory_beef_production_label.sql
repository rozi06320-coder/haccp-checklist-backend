-- Branch-scoped display name for Supervisor Inventory Items Beef Production.
-- Display configuration only; immutable inventory rows and historical reports are untouched.

create table if not exists public.branch_inventory_items_settings (
  branch_id uuid primary key,
  organization_id uuid not null,
  beef_production_label text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete restrict,
  constraint branch_inventory_items_settings_branch_fkey
    foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete cascade,
  constraint branch_inventory_items_settings_beef_label_check check (
    beef_production_label is null
    or (
      beef_production_label = pg_catalog.btrim(beef_production_label)
      and pg_catalog.length(beef_production_label) between 1 and 120
    )
  )
);

alter table public.branch_inventory_items_settings enable row level security;
revoke all on public.branch_inventory_items_settings from public, anon, authenticated;

create or replace function private.inventory_items_state_json(
  p_actor_user_id uuid,
  p_target_branch_id uuid,
  p_target_inventory_month date
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ctx record;
  report public.inventory_items_reports%rowtype;
  selected_month date;
  settings public.branch_inventory_items_settings%rowtype;
begin
  select * into strict ctx from private.phase4a_actor_context(p_actor_user_id, p_target_branch_id);
  selected_month := coalesce(p_target_inventory_month, pg_catalog.date_trunc('month', ctx.business_date)::date);
  if selected_month <> pg_catalog.date_trunc('month', selected_month)::date then
    raise exception 'invalid inventory month' using errcode = '22023';
  end if;

  select * into report
  from public.inventory_items_reports r
  where r.organization_id = ctx.organization_id
    and r.branch_id = ctx.branch_id
    and r.inventory_month = selected_month;

  select * into settings
  from public.branch_inventory_items_settings branch_settings
  where branch_settings.organization_id = ctx.organization_id
    and branch_settings.branch_id = ctx.branch_id;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'business_date', ctx.business_date,
    'inventory_month', selected_month,
    'state', coalesce(report.state, 'draft'),
    'updated_at', report.updated_at,
    'submitted_at', report.submitted_at,
    'beef_production_label', settings.beef_production_label,
    'beef_rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', row.id,
        'production_date', row.production_date,
        'russian_kg', row.russian_kg,
        'australian_kg', row.australian_kg,
        'fat_kg', row.fat_kg,
        'total_kg', row.russian_kg + row.australian_kg + row.fat_kg,
        'ready_patty', row.ready_patty,
        'hunch_sauce_kg', row.hunch_sauce_kg,
        'wastage_grams', row.wastage_grams
      ) order by row.production_date)
      from public.inventory_beef_production_rows row
      where row.report_id = report.id
    ), '[]'::jsonb),
    'item_usage', pg_catalog.jsonb_build_object(
      'usage_month', coalesce((select min(item.usage_month) from public.inventory_item_usage_items item where item.report_id = report.id), selected_month),
      'items', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'id', item.id,
          'group_name', item.group_name,
          'item_name', item.item_name,
          'usage', coalesce((
            select pg_catalog.jsonb_object_agg(value.day_number::text, value.quantity order by value.day_number)
            from public.inventory_item_usage_day_values value
            where value.item_id = item.id
          ), '{}'::jsonb)
        ) order by item.sort_order, item.item_name, item.id)
        from public.inventory_item_usage_items item
        where item.report_id = report.id
      ), '[]'::jsonb)
    )
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory state denied' using errcode = '42501';
end $$;

revoke all on function private.inventory_items_state_json(uuid,uuid,date) from public, anon, authenticated;

create or replace function public.update_inventory_beef_production_label(
  actor_user_id uuid,
  target_branch_id uuid,
  requested_label text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ctx record;
  clean_label text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(requested_label, '')), '[[:space:]]+', ' ', 'g');
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  if pg_catalog.length(clean_label) < 1 or pg_catalog.length(clean_label) > 120 then
    raise exception 'invalid beef production label' using errcode = '22023';
  end if;

  insert into public.branch_inventory_items_settings(
    branch_id, organization_id, beef_production_label, updated_at, updated_by
  ) values (
    ctx.branch_id, ctx.organization_id, clean_label, pg_catalog.now(), actor_user_id
  )
  on conflict(branch_id) do update set
    organization_id = excluded.organization_id,
    beef_production_label = excluded.beef_production_label,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  return pg_catalog.jsonb_build_object('beef_production_label', clean_label);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory label update denied' using errcode = '42501';
end $$;

revoke all on function public.update_inventory_beef_production_label(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.update_inventory_beef_production_label(uuid,uuid,text)
  to service_role;
