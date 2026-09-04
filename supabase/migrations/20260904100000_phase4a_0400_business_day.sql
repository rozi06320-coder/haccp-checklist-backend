-- Move the branch-local operational business-day rollover from 03:00 to 04:00.
-- Fixed Cold Storage slot deadlines remain unchanged; only date partitioning
-- and business-day-close reporting move to 04:00.

create or replace function private.phase4a_business_date_at(tz text, as_of timestamptz)
returns date
language sql
stable
strict
security definer
set search_path = ''
as $$
  select ((as_of at time zone tz) - interval '4 hours')::date
$$;
revoke all on function private.phase4a_business_date_at(text,timestamptz) from public, anon, authenticated;
grant execute on function private.phase4a_business_date_at(text,timestamptz) to service_role;

create or replace function private.phase4a_business_date(tz text)
returns date
language sql
stable
strict
security definer
set search_path = ''
as $$
  select private.phase4a_business_date_at(tz, pg_catalog.statement_timestamp())
$$;
revoke all on function private.phase4a_business_date(text) from public, anon, authenticated;
grant execute on function private.phase4a_business_date(text) to service_role;

create or replace function private.management_branch_closed(
  branch_timezone text,
  as_of timestamptz default pg_catalog.statement_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select extract(hour from as_of at time zone branch_timezone) >= 4
$$;
revoke all on function private.management_branch_closed(text,timestamptz) from public, anon, authenticated;

create or replace function private.cold_storage_master_first_eligible_slot(
  branch_timezone text,
  equipment_created_at timestamptz
)
returns table(first_eligible_business_date date, first_eligible_slot text)
language sql
stable
strict
security definer
set search_path = ''
as $$
  with local_equipment as (
    select equipment_created_at at time zone branch_timezone as local_created_at
  ),
  calculated as (
    select
      local_created_at::time as local_time,
      (local_created_at - interval '4 hours')::date as created_business_date
    from local_equipment
  )
  select
    case
      when local_time >= time '02:00' and local_time < time '04:00'
        then created_business_date + 1
      else created_business_date
    end,
    case
      when local_time >= time '04:00' and local_time < time '12:00' then '12:00'
      when local_time >= time '12:00' and local_time < time '20:00' then '20:00'
      when local_time >= time '20:00' or local_time < time '02:00' then '02:00'
      else '12:00'
    end
  from calculated
$$;
revoke all on function private.cold_storage_master_first_eligible_slot(text,timestamptz) from public, anon, authenticated;
grant execute on function private.cold_storage_master_first_eligible_slot(text,timestamptz) to service_role;

do $business_day_0400$
declare
  target regprocedure;
  definition text;
  updated_definition text;
begin
  target := pg_catalog.to_regprocedure('private.managed_financial_closing_operations_summary(uuid,uuid,timestamptz)');
  if target is null then raise exception 'managed financial closing summary is missing' using errcode = '42883'; end if;
  definition := pg_catalog.pg_get_functiondef(target);
  updated_definition := pg_catalog.replace(definition, 'time ''03:00''', 'time ''04:00''');
  if updated_definition = definition then raise exception 'financial closing 03:00 boundary not found' using errcode = '22023'; end if;
  execute updated_definition;

  target := pg_catalog.to_regprocedure('private.phase4a_managed_missed_issue_rows(uuid)');
  if target is null then raise exception 'managed checklist missed-issue helper is missing' using errcode = '42883'; end if;
  definition := pg_catalog.pg_get_functiondef(target);
  updated_definition := pg_catalog.replace(definition, '03:00', '04:00');
  if updated_definition = definition then raise exception 'managed checklist 03:00 boundary not found' using errcode = '22023'; end if;
  execute updated_definition;

  target := pg_catalog.to_regprocedure('private.oil_tracking_managed_missed_issue_rows(uuid)');
  if target is null then raise exception 'managed oil missed-issue helper is missing' using errcode = '42883'; end if;
  definition := pg_catalog.pg_get_functiondef(target);
  updated_definition := pg_catalog.replace(definition, 'time ''03:00''', 'time ''04:00''');
  if updated_definition = definition then raise exception 'managed oil 03:00 boundary not found' using errcode = '22023'; end if;
  execute updated_definition;

  target := pg_catalog.to_regprocedure('private.sales_tracking_managed_issue_rows(uuid)');
  if target is null then raise exception 'managed sales issue helper is missing' using errcode = '42883'; end if;
  definition := pg_catalog.pg_get_functiondef(target);
  updated_definition := pg_catalog.replace(definition, '>= 3 closed', '>= 4 closed');
  updated_definition := pg_catalog.replace(updated_definition, '03:00', '04:00');
  if updated_definition = definition then raise exception 'managed sales 03:00 boundary not found' using errcode = '22023'; end if;
  execute updated_definition;

  target := pg_catalog.to_regprocedure('public.get_phase4a_management_overview(uuid,uuid)');
  if target is null then raise exception 'management overview is missing' using errcode = '42883'; end if;
  definition := pg_catalog.pg_get_functiondef(target);
  updated_definition := pg_catalog.replace(definition, '>= 3 sales_tracking_closed', '>= 4 sales_tracking_closed');
  if updated_definition = definition then raise exception 'management overview 03:00 boundary not found' using errcode = '22023'; end if;
  execute updated_definition;

  -- These functions are present only when the configurable Cold Storage chain
  -- has been installed. Supersede its business-day partition without changing
  -- the fixed final-slot close at 03:00.
  target := pg_catalog.to_regprocedure('private.cold_storage_slot_occurrence_local(date,text)');
  if target is not null then
    definition := pg_catalog.pg_get_functiondef(target);
    updated_definition := pg_catalog.replace(definition, 'target_slot::time < time ''03:00''', 'target_slot::time < time ''04:00''');
    if updated_definition = definition then raise exception 'configurable slot date partition not found' using errcode = '22023'; end if;
    execute updated_definition;
  end if;

  target := pg_catalog.to_regprocedure('private.cold_storage_schedule_context_at(uuid,timestamptz)');
  if target is not null then
    definition := pg_catalog.pg_get_functiondef(target);
    updated_definition := pg_catalog.replace(definition, 'local_as_of - interval ''3 hours''', 'local_as_of - interval ''4 hours''');
    if updated_definition = definition then raise exception 'configurable schedule business date not found' using errcode = '22023'; end if;
    execute updated_definition;
  end if;

  target := pg_catalog.to_regprocedure('private.cold_storage_slot_order(text)');
  if target is not null and pg_catalog.strpos(pg_catalog.pg_get_functiondef(target), 'slot::time < time ''03:00''') > 0 then
    definition := pg_catalog.pg_get_functiondef(target);
    updated_definition := pg_catalog.replace(definition, 'slot::time < time ''03:00''', 'slot::time < time ''04:00''');
    execute updated_definition;
  end if;

  target := pg_catalog.to_regprocedure('private.cold_storage_master_first_eligible_slot(uuid,timestamptz)');
  if target is not null then
    definition := pg_catalog.pg_get_functiondef(target);
    updated_definition := pg_catalog.replace(definition, 'local_created - interval ''3 hours''', 'local_created - interval ''4 hours''');
    if updated_definition = definition then raise exception 'configurable equipment business date not found' using errcode = '22023'; end if;
    execute updated_definition;
  end if;
end
$business_day_0400$;
