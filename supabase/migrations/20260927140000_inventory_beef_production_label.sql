-- Branch-scoped display labels for Supervisor Inventory Items Beef Production fields.
-- Display configuration only; immutable inventory rows and historical reports are untouched.

create table if not exists public.branch_inventory_items_settings (
  branch_id uuid primary key,
  organization_id uuid not null,
  beef_russian_label text,
  beef_australian_label text,
  beef_hunch_sauce_label text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete restrict,
  constraint branch_inventory_items_settings_branch_fkey
    foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete cascade,
  constraint branch_inventory_items_settings_beef_russian_label_check check (
    beef_russian_label is null
    or (
      beef_russian_label = pg_catalog.btrim(beef_russian_label)
      and pg_catalog.length(beef_russian_label) between 1 and 120
    )
  ),
  constraint branch_inventory_items_settings_beef_australian_label_check check (
    beef_australian_label is null
    or (
      beef_australian_label = pg_catalog.btrim(beef_australian_label)
      and pg_catalog.length(beef_australian_label) between 1 and 120
    )
  ),
  constraint branch_inventory_items_settings_beef_hunch_sauce_label_check check (
    beef_hunch_sauce_label is null
    or (
      beef_hunch_sauce_label = pg_catalog.btrim(beef_hunch_sauce_label)
      and pg_catalog.length(beef_hunch_sauce_label) between 1 and 120
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
    'beef_production_labels', pg_catalog.jsonb_build_object(
      'russian_label', settings.beef_russian_label,
      'australian_label', settings.beef_australian_label,
      'hunch_sauce_label', settings.beef_hunch_sauce_label
    ),
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

create or replace function public.update_inventory_beef_production_field_labels(
  actor_user_id uuid,
  target_branch_id uuid,
  russian_label text,
  australian_label text,
  hunch_sauce_label text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ctx record;
  clean_russian text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(russian_label, '')), '[[:space:]]+', ' ', 'g'), '');
  clean_australian text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(australian_label, '')), '[[:space:]]+', ' ', 'g'), '');
  clean_hunch_sauce text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(hunch_sauce_label, '')), '[[:space:]]+', ' ', 'g'), '');
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  if pg_catalog.length(coalesce(clean_russian, '')) > 120
    or pg_catalog.length(coalesce(clean_australian, '')) > 120
    or pg_catalog.length(coalesce(clean_hunch_sauce, '')) > 120 then
    raise exception 'invalid beef production field labels' using errcode = '22023';
  end if;

  insert into public.branch_inventory_items_settings(
    branch_id, organization_id, beef_russian_label, beef_australian_label, beef_hunch_sauce_label, updated_at, updated_by
  ) values (
    ctx.branch_id, ctx.organization_id, clean_russian, clean_australian, clean_hunch_sauce, pg_catalog.now(), actor_user_id
  )
  on conflict(branch_id) do update set
    organization_id = excluded.organization_id,
    beef_russian_label = excluded.beef_russian_label,
    beef_australian_label = excluded.beef_australian_label,
    beef_hunch_sauce_label = excluded.beef_hunch_sauce_label,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  return pg_catalog.jsonb_build_object(
    'beef_production_labels', pg_catalog.jsonb_build_object(
      'russian_label', clean_russian,
      'australian_label', clean_australian,
      'hunch_sauce_label', clean_hunch_sauce
    )
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory label update denied' using errcode = '42501';
end $$;

revoke all on function public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)
  from public, anon, authenticated;
grant execute on function public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)
  to service_role;
