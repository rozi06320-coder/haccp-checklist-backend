-- Phase 1 Sales Tracking persistence: draft/current-state only.
-- JSONB is accepted only at the RPC boundary and normalized after validation.

create table public.sales_tracking_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  supervisor_team_id uuid not null,
  business_date date not null,
  state text not null default 'draft' check (state in ('draft','submitted')),
  submitted_at timestamptz,
  branch_name_snapshot text not null,
  supervisor_name_snapshot text not null,
  supervisor_team_name_snapshot text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id, supervisor_user_id, business_date),
  constraint sales_tracking_reports_branch_scope_fkey
    foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint sales_tracking_reports_team_scope_fkey
    foreign key(supervisor_team_id, branch_id, organization_id, supervisor_user_id)
    references public.branch_supervisor_teams(id, branch_id, organization_id, supervisor_user_id) on delete restrict,
  constraint sales_tracking_reports_snapshots_check check (
    branch_name_snapshot = btrim(branch_name_snapshot) and length(branch_name_snapshot) > 0
    and supervisor_name_snapshot = btrim(supervisor_name_snapshot) and length(supervisor_name_snapshot) > 0
    and supervisor_team_name_snapshot = btrim(supervisor_team_name_snapshot) and length(supervisor_team_name_snapshot) > 0
  )
);
create index sales_tracking_reports_team_date_idx
  on public.sales_tracking_reports(supervisor_team_id, business_date desc);
create index sales_tracking_reports_branch_date_idx
  on public.sales_tracking_reports(branch_id, business_date desc);

create table public.sales_tracking_sales_rows (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.sales_tracking_reports(id) on delete cascade,
  entry_date date not null,
  actual_cash numeric not null default 0 check (actual_cash >= 0),
  actual_credit numeric not null default 0 check (actual_credit >= 0),
  pos_cash numeric not null default 0 check (pos_cash >= 0),
  pos_credit numeric not null default 0 check (pos_credit >= 0),
  online_delivery numeric not null default 0 check (online_delivery >= 0),
  remarks text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(report_id, entry_date),
  constraint sales_tracking_sales_rows_remarks_check check (
    remarks is null or length(remarks) <= 2000
  )
);
create index sales_tracking_sales_rows_report_idx
  on public.sales_tracking_sales_rows(report_id, entry_date);

create table public.sales_tracking_cash_rows (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.sales_tracking_reports(id) on delete cascade,
  entry_date date not null,
  denom_1 integer not null default 0 check (denom_1 >= 0),
  denom_2 integer not null default 0 check (denom_2 >= 0),
  denom_5 integer not null default 0 check (denom_5 >= 0),
  denom_10 integer not null default 0 check (denom_10 >= 0),
  denom_20 integer not null default 0 check (denom_20 >= 0),
  denom_50 integer not null default 0 check (denom_50 >= 0),
  denom_100 integer not null default 0 check (denom_100 >= 0),
  denom_200 integer not null default 0 check (denom_200 >= 0),
  denom_500 integer not null default 0 check (denom_500 >= 0),
  remaining_cash numeric not null default 0 check (remaining_cash >= 0),
  remarks text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(report_id, entry_date),
  constraint sales_tracking_cash_rows_remarks_check check (
    remarks is null or length(remarks) <= 2000
  )
);
create index sales_tracking_cash_rows_report_idx
  on public.sales_tracking_cash_rows(report_id, entry_date);

create trigger sales_tracking_reports_set_updated_at
before update on public.sales_tracking_reports
for each row execute function private.set_updated_at();
create trigger sales_tracking_sales_rows_set_updated_at
before update on public.sales_tracking_sales_rows
for each row execute function private.set_updated_at();
create trigger sales_tracking_cash_rows_set_updated_at
before update on public.sales_tracking_cash_rows
for each row execute function private.set_updated_at();

create function private.sales_tracking_numeric_field(row_value jsonb, field_name text)
returns numeric language plpgsql immutable security definer set search_path = '' as $$
declare raw_value jsonb; raw_text text; parsed_value numeric;
begin
  raw_value := row_value -> field_name;
  if raw_value is null or pg_catalog.jsonb_typeof(raw_value) = 'null' then
    return 0;
  end if;
  if pg_catalog.jsonb_typeof(raw_value) = 'number' then
    parsed_value := (raw_value #>> '{}')::numeric;
  elsif pg_catalog.jsonb_typeof(raw_value) = 'string' then
    raw_text := pg_catalog.btrim(raw_value #>> '{}');
    if raw_text = '' then
      return 0;
    end if;
    parsed_value := raw_text::numeric;
  else
    raise exception 'invalid sales tracking numeric field' using errcode = '22023';
  end if;
  if parsed_value < 0 then
    raise exception 'invalid sales tracking numeric field' using errcode = '22023';
  end if;
  return parsed_value;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid sales tracking numeric field' using errcode = '22023';
end $$;
revoke all on function private.sales_tracking_numeric_field(jsonb,text) from public, anon, authenticated;

create function private.sales_tracking_integer_field(row_value jsonb, field_name text)
returns integer language plpgsql immutable security definer set search_path = '' as $$
declare raw_value jsonb; raw_text text; parsed_value numeric;
begin
  raw_value := row_value -> field_name;
  if raw_value is null or pg_catalog.jsonb_typeof(raw_value) = 'null' then
    return 0;
  end if;
  if pg_catalog.jsonb_typeof(raw_value) = 'number' then
    parsed_value := (raw_value #>> '{}')::numeric;
  elsif pg_catalog.jsonb_typeof(raw_value) = 'string' then
    raw_text := pg_catalog.btrim(raw_value #>> '{}');
    if raw_text = '' then
      return 0;
    end if;
    parsed_value := raw_text::numeric;
  else
    raise exception 'invalid sales tracking denomination field' using errcode = '22023';
  end if;
  if parsed_value < 0 or parsed_value <> pg_catalog.trunc(parsed_value) or parsed_value > 2147483647 then
    raise exception 'invalid sales tracking denomination field' using errcode = '22023';
  end if;
  return parsed_value::integer;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid sales tracking denomination field' using errcode = '22023';
end $$;
revoke all on function private.sales_tracking_integer_field(jsonb,text) from public, anon, authenticated;

create function private.sales_tracking_date_field(row_value jsonb, field_name text)
returns date language plpgsql immutable security definer set search_path = '' as $$
declare raw_text text; parsed_date date;
begin
  if not (row_value ? field_name) or pg_catalog.jsonb_typeof(row_value -> field_name) <> 'string' then
    raise exception 'invalid sales tracking date field' using errcode = '22023';
  end if;
  raw_text := pg_catalog.btrim(row_value ->> field_name);
  if raw_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid sales tracking date field' using errcode = '22023';
  end if;
  parsed_date := raw_text::date;
  if pg_catalog.to_char(parsed_date, 'YYYY-MM-DD') <> raw_text then
    raise exception 'invalid sales tracking date field' using errcode = '22023';
  end if;
  return parsed_date;
exception
  when datetime_field_overflow or invalid_datetime_format then
    raise exception 'invalid sales tracking date field' using errcode = '22023';
end $$;
revoke all on function private.sales_tracking_date_field(jsonb,text) from public, anon, authenticated;

create function private.validate_sales_tracking_sales_rows(rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb;
begin
  if pg_catalog.jsonb_typeof(rows) <> 'array' or pg_catalog.jsonb_array_length(rows) > 31 then
    raise exception 'invalid sales tracking sales rows' using errcode = '22023';
  end if;
  if (
    select count(*) <> count(distinct value ->> 'entry_date')
    from pg_catalog.jsonb_array_elements(rows)
  ) then
    raise exception 'duplicate sales tracking sales row' using errcode = '22023';
  end if;
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    perform private.sales_tracking_date_field(row_value, 'entry_date');
    perform private.sales_tracking_numeric_field(row_value, 'actual_cash');
    perform private.sales_tracking_numeric_field(row_value, 'actual_credit');
    perform private.sales_tracking_numeric_field(row_value, 'pos_cash');
    perform private.sales_tracking_numeric_field(row_value, 'pos_credit');
    perform private.sales_tracking_numeric_field(row_value, 'online_delivery');
    if row_value ? 'remarks'
      and pg_catalog.jsonb_typeof(row_value -> 'remarks') <> 'null'
      and (
        pg_catalog.jsonb_typeof(row_value -> 'remarks') <> 'string'
        or pg_catalog.length(pg_catalog.btrim(row_value ->> 'remarks')) > 2000
      )
    then
      raise exception 'invalid sales tracking sales row' using errcode = '22023';
    end if;
  end loop;
end $$;
revoke all on function private.validate_sales_tracking_sales_rows(jsonb) from public, anon, authenticated;

create function private.validate_sales_tracking_cash_rows(rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb;
begin
  if pg_catalog.jsonb_typeof(rows) <> 'array' or pg_catalog.jsonb_array_length(rows) > 31 then
    raise exception 'invalid sales tracking cash rows' using errcode = '22023';
  end if;
  if (
    select count(*) <> count(distinct value ->> 'entry_date')
    from pg_catalog.jsonb_array_elements(rows)
  ) then
    raise exception 'duplicate sales tracking cash row' using errcode = '22023';
  end if;
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    perform private.sales_tracking_date_field(row_value, 'entry_date');
    perform private.sales_tracking_integer_field(row_value, 'denom_1');
    perform private.sales_tracking_integer_field(row_value, 'denom_2');
    perform private.sales_tracking_integer_field(row_value, 'denom_5');
    perform private.sales_tracking_integer_field(row_value, 'denom_10');
    perform private.sales_tracking_integer_field(row_value, 'denom_20');
    perform private.sales_tracking_integer_field(row_value, 'denom_50');
    perform private.sales_tracking_integer_field(row_value, 'denom_100');
    perform private.sales_tracking_integer_field(row_value, 'denom_200');
    perform private.sales_tracking_integer_field(row_value, 'denom_500');
    perform private.sales_tracking_numeric_field(row_value, 'remaining_cash');
    if row_value ? 'remarks'
      and pg_catalog.jsonb_typeof(row_value -> 'remarks') <> 'null'
      and (
        pg_catalog.jsonb_typeof(row_value -> 'remarks') <> 'string'
        or pg_catalog.length(pg_catalog.btrim(row_value ->> 'remarks')) > 2000
      )
    then
      raise exception 'invalid sales tracking cash row' using errcode = '22023';
    end if;
  end loop;
end $$;
revoke all on function private.validate_sales_tracking_cash_rows(jsonb) from public, anon, authenticated;

create function private.validate_sales_tracking_entry_dates(rows jsonb, business_date date)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb;
begin
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    if private.sales_tracking_date_field(row_value, 'entry_date') <> business_date then
      raise exception 'sales tracking entry date mismatch' using errcode = '22023';
    end if;
  end loop;
end $$;
revoke all on function private.validate_sales_tracking_entry_dates(jsonb,date) from public, anon, authenticated;

create function public.get_sales_tracking_current_state(actor_user_id uuid, target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ctx record; report public.sales_tracking_reports%rowtype;
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  select * into report
  from public.sales_tracking_reports r
  where r.organization_id = ctx.organization_id
    and r.branch_id = ctx.branch_id
    and r.supervisor_user_id = actor_user_id
    and r.business_date = ctx.business_date
  order by r.updated_at desc, r.id
  limit 1;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'business_date', ctx.business_date,
    'state', coalesce(report.state, 'draft'),
    'submitted_at', report.submitted_at,
    'sales_rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', row.id,
        'entry_date', row.entry_date,
        'actual_cash', row.actual_cash,
        'actual_credit', row.actual_credit,
        'pos_cash', row.pos_cash,
        'pos_credit', row.pos_credit,
        'online_delivery', row.online_delivery,
        'remarks', row.remarks,
        'actual_total', row.actual_cash + row.actual_credit + row.online_delivery,
        'pos_total', row.pos_cash + row.pos_credit + row.online_delivery,
        'variance', (row.actual_cash + row.actual_credit + row.online_delivery) - (row.pos_cash + row.pos_credit + row.online_delivery)
      ) order by row.entry_date)
      from public.sales_tracking_sales_rows row
      where row.report_id = report.id
    ), '[]'::jsonb),
    'cash_rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', row.id,
        'entry_date', row.entry_date,
        'denom_1', row.denom_1,
        'denom_2', row.denom_2,
        'denom_5', row.denom_5,
        'denom_10', row.denom_10,
        'denom_20', row.denom_20,
        'denom_50', row.denom_50,
        'denom_100', row.denom_100,
        'denom_200', row.denom_200,
        'denom_500', row.denom_500,
        'remaining_cash', row.remaining_cash,
        'remarks', row.remarks,
        'cash_total', row.denom_1 + row.denom_2 * 2 + row.denom_5 * 5 + row.denom_10 * 10 + row.denom_20 * 20 + row.denom_50 * 50 + row.denom_100 * 100 + row.denom_200 * 200 + row.denom_500 * 500
      ) order by row.entry_date)
      from public.sales_tracking_cash_rows row
      where row.report_id = report.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'sales tracking state denied' using errcode = '42501';
end $$;

create function public.save_sales_tracking_draft(actor_user_id uuid, target_branch_id uuid, sales_rows jsonb, cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare ctx record; report public.sales_tracking_reports%rowtype;
begin
  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  perform private.validate_sales_tracking_sales_rows(sales_rows);
  perform private.validate_sales_tracking_cash_rows(cash_rows);
  perform private.validate_sales_tracking_entry_dates(sales_rows, ctx.business_date);
  perform private.validate_sales_tracking_entry_dates(cash_rows, ctx.business_date);

  insert into public.sales_tracking_reports(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state,
    branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot
  ) values (
    ctx.organization_id, ctx.branch_id, actor_user_id, ctx.team_id, ctx.business_date, 'draft',
    ctx.branch_name, ctx.supervisor_name, ctx.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_user_id, business_date) do update set
    state = 'draft',
    submitted_at = null,
    supervisor_team_id = excluded.supervisor_team_id,
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    supervisor_team_name_snapshot = excluded.supervisor_team_name_snapshot
  returning * into report;

  delete from public.sales_tracking_sales_rows where report_id = report.id;
  delete from public.sales_tracking_cash_rows where report_id = report.id;

  insert into public.sales_tracking_sales_rows(
    report_id, entry_date, actual_cash, actual_credit, pos_cash, pos_credit, online_delivery, remarks
  )
  select report.id,
    private.sales_tracking_date_field(row_value, 'entry_date'),
    private.sales_tracking_numeric_field(row_value, 'actual_cash'),
    private.sales_tracking_numeric_field(row_value, 'actual_credit'),
    private.sales_tracking_numeric_field(row_value, 'pos_cash'),
    private.sales_tracking_numeric_field(row_value, 'pos_credit'),
    private.sales_tracking_numeric_field(row_value, 'online_delivery'),
    nullif(pg_catalog.btrim(coalesce(row_value ->> 'remarks', '')), '')
  from pg_catalog.jsonb_array_elements(sales_rows) entry(row_value);

  insert into public.sales_tracking_cash_rows(
    report_id, entry_date, denom_1, denom_2, denom_5, denom_10, denom_20, denom_50,
    denom_100, denom_200, denom_500, remaining_cash, remarks
  )
  select report.id,
    private.sales_tracking_date_field(row_value, 'entry_date'),
    private.sales_tracking_integer_field(row_value, 'denom_1'),
    private.sales_tracking_integer_field(row_value, 'denom_2'),
    private.sales_tracking_integer_field(row_value, 'denom_5'),
    private.sales_tracking_integer_field(row_value, 'denom_10'),
    private.sales_tracking_integer_field(row_value, 'denom_20'),
    private.sales_tracking_integer_field(row_value, 'denom_50'),
    private.sales_tracking_integer_field(row_value, 'denom_100'),
    private.sales_tracking_integer_field(row_value, 'denom_200'),
    private.sales_tracking_integer_field(row_value, 'denom_500'),
    private.sales_tracking_numeric_field(row_value, 'remaining_cash'),
    nullif(pg_catalog.btrim(coalesce(row_value ->> 'remarks', '')), '')
  from pg_catalog.jsonb_array_elements(cash_rows) entry(row_value);

  return public.get_sales_tracking_current_state(actor_user_id, target_branch_id);
exception
  when no_data_found or too_many_rows then
    raise exception 'sales tracking draft denied' using errcode = '42501';
end $$;

alter table public.sales_tracking_reports enable row level security;
alter table public.sales_tracking_sales_rows enable row level security;
alter table public.sales_tracking_cash_rows enable row level security;

revoke all on public.sales_tracking_reports, public.sales_tracking_sales_rows, public.sales_tracking_cash_rows
  from anon, authenticated;
revoke all on function public.save_sales_tracking_draft(uuid,uuid,jsonb,jsonb), public.get_sales_tracking_current_state(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.save_sales_tracking_draft(uuid,uuid,jsonb,jsonb), public.get_sales_tracking_current_state(uuid,uuid)
  to service_role;
