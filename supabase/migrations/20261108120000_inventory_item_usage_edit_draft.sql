begin;

-- Draft Item Usage edits are deliberately separate from the full-month draft
-- writer.  Existing identity/history protections remain in force; only the
-- quantity column can be changed through the RPC below.
do $preflight$
begin
  if pg_catalog.to_regclass('public.inventory_items_reports') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_items') is null
    or pg_catalog.to_regclass('public.inventory_item_usage_day_values') is null
    or pg_catalog.to_regprocedure('private.inventory_items_actor_context(uuid,uuid)') is null
    or pg_catalog.to_regprocedure('private.lock_inventory_items_month(uuid,date)') is null
  then
    raise exception 'Inventory Item Usage edit prerequisites are missing' using errcode='42P01';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_trigger trigger_row
    where trigger_row.tgrelid='public.inventory_item_usage_day_values'::regclass
      and trigger_row.tgname='inventory_item_usage_day_values_immutable'
      and not trigger_row.tgisinternal
  ) then
    raise exception 'Inventory Item Usage immutable trigger is missing' using errcode='55000';
  end if;
end
$preflight$;

create table public.inventory_item_usage_edit_audits (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  report_id uuid not null
    references public.inventory_items_reports(id) on delete restrict,
  item_id uuid not null
    references public.inventory_item_usage_items(id) on delete restrict,
  actor_user_id uuid not null
    references auth.users(id) on delete restrict,
  idempotency_key uuid not null unique,
  expected_report_updated_at timestamptz not null,
  old_usage jsonb not null,
  new_usage jsonb not null,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  constraint inventory_item_usage_edit_audits_branch_org_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint inventory_item_usage_edit_audits_old_usage_object_check
    check (pg_catalog.jsonb_typeof(old_usage) = 'object'),
  constraint inventory_item_usage_edit_audits_new_usage_object_check
    check (pg_catalog.jsonb_typeof(new_usage) = 'object')
);

create index inventory_item_usage_edit_audits_item_idx
  on public.inventory_item_usage_edit_audits(item_id, created_at desc);

alter table public.inventory_item_usage_edit_audits enable row level security;
revoke all on table public.inventory_item_usage_edit_audits
  from public, anon, authenticated, service_role;

-- The marker is set only by the SECURITY DEFINER edit function.  Ordinary
-- UPDATE/DELETE statements, including service-role table access, continue to
-- hit the immutable-history guard.
create or replace function private.protect_inventory_usage_day_value()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  edit_actor uuid;
  edit_item uuid;
begin
  if tg_op = 'UPDATE'
    and old.id is not distinct from new.id
    and old.item_id is not distinct from new.item_id
    and old.day_number is not distinct from new.day_number
    and old.created_at is not distinct from new.created_at
    and old.created_by is not distinct from new.created_by
    and new.quantity >= 0
  then
    begin
      edit_actor := nullif(pg_catalog.current_setting('app.inventory_usage_edit_actor', true), '')::uuid;
      edit_item := nullif(pg_catalog.current_setting('app.inventory_usage_edit_item', true), '')::uuid;
    exception when invalid_text_representation then
      edit_actor := null;
      edit_item := null;
    end;

    if edit_actor is not null
      and edit_item = new.item_id
      and exists (
        select 1
        from public.inventory_item_usage_items item
        join public.inventory_items_reports report on report.id = item.report_id
        join lateral private.inventory_items_actor_context(edit_actor, report.branch_id) actor
          on actor.organization_id = report.organization_id
          and actor.branch_id = report.branch_id
        where item.id = new.item_id
          and report.state = 'draft'
      )
    then
      return new;
    end if;
  end if;

  if tg_op <> 'INSERT' then
    raise exception 'saved inventory item day is immutable' using errcode = '23505';
  end if;
  if not exists (
    select 1
    from public.inventory_item_usage_items item
    join public.inventory_items_reports report on report.id = item.report_id
    where item.id = new.item_id and report.state = 'draft'
  ) then
    raise exception 'inventory month is closed' using errcode = '23505';
  end if;
  return new;
end
$function$;

revoke all on function private.protect_inventory_usage_day_value()
  from public, anon, authenticated, service_role;

create or replace function public.update_inventory_item_usage_entry(
  actor_user_id uuid,
  target_branch_id uuid,
  target_item_usage_id uuid,
  expected_report_updated_at timestamptz,
  expected_usage jsonb,
  new_usage jsonb,
  idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  ctx record;
  target_item public.inventory_item_usage_items%rowtype;
  target_report public.inventory_items_reports%rowtype;
  prior_audit public.inventory_item_usage_edit_audits%rowtype;
  target_inventory_month date;
  current_usage jsonb;
  normalized_expected jsonb := '{}'::jsonb;
  normalized_new jsonb := '{}'::jsonb;
  usage_key text;
  usage_value jsonb;
  parsed_quantity numeric;
begin
  if actor_user_id is null or target_branch_id is null or target_item_usage_id is null
    or expected_report_updated_at is null or idempotency_key is null
    or pg_catalog.jsonb_typeof(expected_usage) <> 'object'
    or pg_catalog.jsonb_typeof(new_usage) <> 'object'
  then
    raise exception 'invalid Item Usage edit request' using errcode='22023';
  end if;

  select * into strict ctx
  from private.inventory_items_actor_context(actor_user_id, target_branch_id);

  -- Serialize reuse of an idempotency key even if callers target different rows.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(idempotency_key::text, 0)
  );

  select item.* into strict target_item
  from public.inventory_item_usage_items item
  join public.inventory_items_reports report on report.id = item.report_id
  where item.id = target_item_usage_id
    and report.organization_id = ctx.organization_id
    and report.branch_id = ctx.branch_id;

  select report.inventory_month into strict target_inventory_month
  from public.inventory_items_reports report
  where report.id = target_item.report_id
    and report.organization_id = ctx.organization_id
    and report.branch_id = ctx.branch_id;

  perform private.lock_inventory_items_month(target_branch_id, target_inventory_month);

  select * into strict target_report
  from public.inventory_items_reports report
  where report.id = target_item.report_id
    and report.organization_id = ctx.organization_id
    and report.branch_id = ctx.branch_id
  for update;

  select * into prior_audit
  from public.inventory_item_usage_edit_audits audit
  where audit.idempotency_key = update_inventory_item_usage_entry.idempotency_key
  for update;

  for usage_key, usage_value in select key, value from pg_catalog.jsonb_each(new_usage) loop
    if usage_key !~ '^(?:[1-9]|[12][0-9]|3[01])$' then
      raise exception 'invalid new Item Usage day' using errcode='22023';
    end if;
    parsed_quantity := private.inventory_items_numeric_field(
      pg_catalog.jsonb_build_object('quantity', usage_value), 'quantity');
    normalized_new := normalized_new || pg_catalog.jsonb_build_object(usage_key, parsed_quantity);
  end loop;

  if prior_audit.id is not null then
    if prior_audit.organization_id is distinct from ctx.organization_id
      or prior_audit.branch_id is distinct from ctx.branch_id
      or prior_audit.item_id is distinct from target_item.id
      or prior_audit.actor_user_id is distinct from actor_user_id
      or prior_audit.expected_report_updated_at is distinct from expected_report_updated_at
      or prior_audit.new_usage is distinct from normalized_new
    then
      raise exception 'idempotency key was already used for a different edit' using errcode='40001';
    end if;
    return private.inventory_items_state_json(actor_user_id, target_branch_id, target_report.inventory_month);
  end if;

  if target_item.deleted_at is not null then
    raise exception 'deleted inventory item cannot be edited' using errcode='23505';
  end if;
  if target_report.state <> 'draft' then
    raise exception 'inventory month already submitted' using errcode='23505';
  end if;
  if target_report.inventory_month > pg_catalog.date_trunc('month', ctx.business_date)::date then
    raise exception 'future inventory month cannot be edited' using errcode='22023';
  end if;
  if target_report.updated_at is distinct from expected_report_updated_at then
    raise exception 'Item Usage changed after confirmation' using errcode='40001';
  end if;

  select coalesce(
    pg_catalog.jsonb_object_agg(value.day_number::text, pg_catalog.to_jsonb(value.quantity)
      order by value.day_number), '{}'::jsonb
  ) into current_usage
  from public.inventory_item_usage_day_values value
  where value.item_id = target_item.id;

  for usage_key, usage_value in select key, value from pg_catalog.jsonb_each(expected_usage) loop
    if usage_key !~ '^(?:[1-9]|[12][0-9]|3[01])$' then
      raise exception 'invalid expected Item Usage day' using errcode='22023';
    end if;
    parsed_quantity := private.inventory_items_numeric_field(
      pg_catalog.jsonb_build_object('quantity', usage_value), 'quantity');
    normalized_expected := normalized_expected || pg_catalog.jsonb_build_object(usage_key, parsed_quantity);
  end loop;

  if normalized_expected is distinct from current_usage then
    raise exception 'Item Usage changed after confirmation' using errcode='40001';
  end if;

  if (select count(*) from pg_catalog.jsonb_object_keys(normalized_new))
      <> (select count(*) from pg_catalog.jsonb_object_keys(current_usage))
    or exists (
      select 1 from pg_catalog.jsonb_object_keys(current_usage) current_key
      where not (normalized_new ? current_key)
    )
  then
    raise exception 'Item Usage day keys are immutable' using errcode='22023';
  end if;

  perform pg_catalog.set_config('app.inventory_usage_edit_actor', actor_user_id::text, true);
  perform pg_catalog.set_config('app.inventory_usage_edit_item', target_item.id::text, true);
  for usage_key, usage_value in select key, value from pg_catalog.jsonb_each(normalized_new) loop
    update public.inventory_item_usage_day_values value
    set quantity = (usage_value #>> '{}')::numeric
    where value.item_id = target_item.id and value.day_number = usage_key::integer;
    if not found then
      raise exception 'Item Usage day key is missing' using errcode='40001';
    end if;
  end loop;
  perform pg_catalog.set_config('app.inventory_usage_edit_actor', '', true);
  perform pg_catalog.set_config('app.inventory_usage_edit_item', '', true);

  insert into public.inventory_item_usage_edit_audits(
    organization_id, branch_id, report_id, item_id, actor_user_id,
    idempotency_key, expected_report_updated_at, old_usage, new_usage
  ) values (
    ctx.organization_id, ctx.branch_id, target_report.id, target_item.id, actor_user_id,
    idempotency_key, expected_report_updated_at, current_usage, normalized_new
  );

  update public.inventory_items_reports report
  set updated_at = pg_catalog.statement_timestamp()
  where report.id = target_report.id;

  return private.inventory_items_state_json(actor_user_id, target_branch_id, target_report.inventory_month);
exception
  when no_data_found or too_many_rows then
    raise exception 'Inventory Item Usage edit denied' using errcode='42501';
end
$function$;

revoke all on function public.update_inventory_item_usage_entry(uuid,uuid,uuid,timestamptz,jsonb,jsonb,uuid)
  from public, anon, authenticated;
grant execute on function public.update_inventory_item_usage_entry(uuid,uuid,uuid,timestamptz,jsonb,jsonb,uuid)
  to service_role;

commit;
