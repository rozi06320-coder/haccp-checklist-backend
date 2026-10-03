-- Persist one Beef Production day without validating or writing Item Usage.

create or replace function public.create_inventory_beef_production_row(
  actor_user_id uuid,
  target_branch_id uuid,
  production_date date,
  row_values jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  ctx record;
  target_production_date date;
  target_inventory_month date;
  target_report public.inventory_items_reports%rowtype;
  settings public.branch_inventory_items_settings%rowtype;
  parsed_russian_kg numeric;
  parsed_australian_kg numeric;
  parsed_fat_kg numeric;
  parsed_ready_patty numeric;
  parsed_hunch_sauce_kg numeric;
  parsed_wastage_grams numeric;
begin
  select * into strict ctx
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  if production_date is null then
    raise exception 'inventory beef production date is required' using errcode = '22023';
  end if;
  target_production_date := production_date;
  target_inventory_month := pg_catalog.date_trunc('month', target_production_date)::date;

  if pg_catalog.jsonb_typeof(row_values) <> 'object'
    or not row_values ?& array[
      'russian_kg', 'australian_kg', 'fat_kg', 'ready_patty', 'hunch_sauce_kg', 'wastage_grams'
    ]
    or exists (
      select 1
      from pg_catalog.jsonb_object_keys(row_values) as key_name
      where key_name <> all(array[
        'russian_kg', 'australian_kg', 'fat_kg', 'ready_patty', 'hunch_sauce_kg', 'wastage_grams'
      ])
    )
  then
    raise exception 'invalid inventory beef row values' using errcode = '22023';
  end if;

  parsed_russian_kg := private.inventory_items_numeric_field(row_values, 'russian_kg');
  parsed_australian_kg := private.inventory_items_numeric_field(row_values, 'australian_kg');
  parsed_fat_kg := private.inventory_items_numeric_field(row_values, 'fat_kg');
  parsed_ready_patty := private.inventory_items_numeric_field(row_values, 'ready_patty');
  parsed_hunch_sauce_kg := private.inventory_items_numeric_field(row_values, 'hunch_sauce_kg');
  parsed_wastage_grams := private.inventory_items_numeric_field(row_values, 'wastage_grams');

  perform private.lock_inventory_items_month(target_branch_id, target_inventory_month);

  select * into target_report
  from public.inventory_items_reports report
  where report.organization_id = ctx.organization_id
    and report.branch_id = ctx.branch_id
    and report.inventory_month = target_inventory_month
  for update;

  if target_report.id is null then
    insert into public.inventory_items_reports(
      organization_id,
      branch_id,
      supervisor_user_id,
      supervisor_team_id,
      business_date,
      inventory_month,
      state,
      branch_name_snapshot,
      supervisor_name_snapshot,
      supervisor_team_name_snapshot
    ) values (
      ctx.organization_id,
      ctx.branch_id,
      actor_user_id,
      ctx.team_id,
      ctx.business_date,
      target_inventory_month,
      'draft',
      ctx.branch_name,
      ctx.supervisor_name,
      ctx.supervisor_name || ' Team'
    )
    returning * into target_report;
  elsif target_report.state <> 'draft' then
    raise exception 'inventory month already submitted' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.inventory_beef_production_rows beef
    where beef.report_id = target_report.id
      and beef.production_date = target_production_date
  ) then
    raise exception 'inventory beef production date already exists' using errcode = '23505';
  end if;

  select * into settings
  from public.branch_inventory_items_settings branch_settings
  where branch_settings.organization_id = ctx.organization_id
    and branch_settings.branch_id = ctx.branch_id;

  insert into public.inventory_beef_production_rows(
    report_id,
    production_date,
    russian_kg,
    australian_kg,
    fat_kg,
    ready_patty,
    hunch_sauce_kg,
    wastage_grams,
    created_by,
    updated_by_user_id,
    russian_label_snapshot,
    australian_label_snapshot,
    hunch_sauce_label_snapshot
  ) values (
    target_report.id,
    target_production_date,
    parsed_russian_kg,
    parsed_australian_kg,
    parsed_fat_kg,
    parsed_ready_patty,
    parsed_hunch_sauce_kg,
    parsed_wastage_grams,
    actor_user_id,
    null,
    coalesce(settings.beef_russian_label, 'Russian kg'),
    coalesce(settings.beef_australian_label, 'Australian kg'),
    coalesce(settings.beef_hunch_sauce_label, 'Hunch sauce kg')
  );

  update public.inventory_items_reports report
  set updated_at = pg_catalog.clock_timestamp()
  where report.id = target_report.id;

  return private.inventory_items_state_json(actor_user_id, target_branch_id, target_inventory_month);
exception
  when no_data_found or too_many_rows then
    raise exception 'inventory beef create denied' using errcode = '42501';
end $$;

revoke all on function public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)
  from public, anon, authenticated;
grant execute on function public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)
  to service_role;
