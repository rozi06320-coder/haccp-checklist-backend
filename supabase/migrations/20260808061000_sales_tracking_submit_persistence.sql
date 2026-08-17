-- Phase 1B Sales Tracking submit: submit once per branch-local business day.

create table public.sales_tracking_submission_idempotency (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  report_id uuid not null references public.sales_tracking_reports(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key(actor_user_id, idempotency_key)
);
create index sales_tracking_submission_idempotency_report_idx
  on public.sales_tracking_submission_idempotency(report_id);

create function private.replace_sales_tracking_rows(report_id uuid, sales_rows jsonb, cash_rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.sales_tracking_sales_rows where report_id = replace_sales_tracking_rows.report_id;
  delete from public.sales_tracking_cash_rows where report_id = replace_sales_tracking_rows.report_id;

  insert into public.sales_tracking_sales_rows(
    report_id, entry_date, actual_cash, actual_credit, pos_cash, pos_credit, online_delivery, remarks
  )
  select replace_sales_tracking_rows.report_id,
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
  select replace_sales_tracking_rows.report_id,
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
end $$;
revoke all on function private.replace_sales_tracking_rows(uuid,jsonb,jsonb) from public, anon, authenticated;

create or replace function public.save_sales_tracking_draft(actor_user_id uuid, target_branch_id uuid, sales_rows jsonb, cash_rows jsonb)
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
  where public.sales_tracking_reports.state <> 'submitted'
  returning * into report;

  if report.id is null then
    return public.get_sales_tracking_current_state(actor_user_id, target_branch_id);
  end if;

  perform private.replace_sales_tracking_rows(report.id, sales_rows, cash_rows);
  return public.get_sales_tracking_current_state(actor_user_id, target_branch_id);
exception
  when no_data_found or too_many_rows then
    raise exception 'sales tracking draft denied' using errcode = '42501';
end $$;

create function public.submit_sales_tracking(actor_user_id uuid, target_branch_id uuid, idempotency_key uuid, request_hash text, sales_rows jsonb, cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  ctx record;
  report public.sales_tracking_reports%rowtype;
  existing_idempotency public.sales_tracking_submission_idempotency%rowtype;
  row_count integer;
begin
  if request_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid sales tracking request hash' using errcode = '22023';
  end if;

  select * into strict ctx from private.phase4a_actor_context(actor_user_id, target_branch_id);
  perform private.validate_sales_tracking_sales_rows(sales_rows);
  perform private.validate_sales_tracking_cash_rows(cash_rows);
  perform private.validate_sales_tracking_entry_dates(sales_rows, ctx.business_date);
  perform private.validate_sales_tracking_entry_dates(cash_rows, ctx.business_date);

  row_count := pg_catalog.jsonb_array_length(sales_rows) + pg_catalog.jsonb_array_length(cash_rows);
  if row_count < 1 then
    raise exception 'sales tracking submit requires rows' using errcode = '22023';
  end if;

  select * into existing_idempotency
  from public.sales_tracking_submission_idempotency entry
  where entry.actor_user_id = submit_sales_tracking.actor_user_id
    and entry.idempotency_key = submit_sales_tracking.idempotency_key;

  if existing_idempotency.actor_user_id is not null then
    if existing_idempotency.request_hash <> submit_sales_tracking.request_hash then
      raise exception 'sales tracking idempotency conflict' using errcode = '23505';
    end if;
    select * into strict report
    from public.sales_tracking_reports r
    where r.id = existing_idempotency.report_id
      and r.organization_id = ctx.organization_id
      and r.branch_id = ctx.branch_id
      and r.supervisor_user_id = actor_user_id
      and r.business_date = ctx.business_date
      and r.state = 'submitted';
    return public.get_sales_tracking_current_state(actor_user_id, target_branch_id);
  end if;

  select * into report
  from public.sales_tracking_reports r
  where r.organization_id = ctx.organization_id
    and r.branch_id = ctx.branch_id
    and r.supervisor_user_id = actor_user_id
    and r.business_date = ctx.business_date
  order by r.updated_at desc, r.id
  limit 1
  for update;

  if report.id is not null and report.state = 'submitted' then
    raise exception 'sales tracking already submitted' using errcode = '23505';
  end if;

  insert into public.sales_tracking_reports(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state, submitted_at,
    branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot
  ) values (
    ctx.organization_id, ctx.branch_id, actor_user_id, ctx.team_id, ctx.business_date, 'submitted', now(),
    ctx.branch_name, ctx.supervisor_name, ctx.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_user_id, business_date) do update set
    state = 'submitted',
    submitted_at = now(),
    supervisor_team_id = excluded.supervisor_team_id,
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    supervisor_team_name_snapshot = excluded.supervisor_team_name_snapshot
  where public.sales_tracking_reports.state <> 'submitted'
  returning * into report;

  if report.id is null then
    raise exception 'sales tracking already submitted' using errcode = '23505';
  end if;

  perform private.replace_sales_tracking_rows(report.id, sales_rows, cash_rows);

  insert into public.sales_tracking_submission_idempotency(actor_user_id, idempotency_key, request_hash, report_id)
  values(actor_user_id, idempotency_key, request_hash, report.id);

  return public.get_sales_tracking_current_state(actor_user_id, target_branch_id);
exception
  when no_data_found or too_many_rows then
    raise exception 'sales tracking submit denied' using errcode = '42501';
end $$;

alter table public.sales_tracking_submission_idempotency enable row level security;
revoke all on public.sales_tracking_submission_idempotency from anon, authenticated;
revoke all on function public.submit_sales_tracking(uuid,uuid,uuid,text,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.submit_sales_tracking(uuid,uuid,uuid,text,jsonb,jsonb)
  to service_role;
