-- Phase 1 Oil Tracking persistence: draft/current-state only.
-- JSONB is used only at the RPC boundary; rows are validated before normalized storage.

create table public.oil_tracking_submissions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  supervisor_team_id uuid not null,
  business_date date not null,
  state text not null default 'draft' check (state in ('draft','submitted')),
  opening_submitted_at timestamptz,
  closing_submitted_at timestamptz,
  branch_name_snapshot text not null,
  supervisor_name_snapshot text not null,
  team_name_snapshot text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id, supervisor_team_id, business_date),
  constraint oil_tracking_submissions_branch_scope_fkey
    foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint oil_tracking_submissions_team_scope_fkey
    foreign key(supervisor_team_id, branch_id, organization_id)
    references public.branch_supervisor_teams(id, branch_id, organization_id) on delete restrict,
  constraint oil_tracking_submissions_snapshots_check check (
    branch_name_snapshot = btrim(branch_name_snapshot) and length(branch_name_snapshot) > 0
    and supervisor_name_snapshot = btrim(supervisor_name_snapshot) and length(supervisor_name_snapshot) > 0
    and team_name_snapshot = btrim(team_name_snapshot) and length(team_name_snapshot) > 0
  )
);
create index oil_tracking_submissions_team_date_idx
  on public.oil_tracking_submissions(supervisor_team_id, business_date desc);
create index oil_tracking_submissions_branch_date_idx
  on public.oil_tracking_submissions(branch_id, business_date desc);

create table public.oil_tracking_fryer_results (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.oil_tracking_submissions(id) on delete cascade,
  fryer_id text not null,
  fryer_label_snapshot text not null,
  fryer_short_label_snapshot text not null,
  in_use_today boolean not null default false,
  oil_status text not null check (oil_status in ('pending','new_oil','filtered_oil')),
  opening_temperature_c numeric,
  opening_status text not null default 'pending' check (opening_status in ('pending','pass','fail')),
  opening_note text not null default '',
  closing_tpm_percent numeric,
  closing_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(submission_id, fryer_id),
  constraint oil_tracking_fryer_results_identity_check check (
    fryer_id = btrim(fryer_id) and length(fryer_id) between 1 and 80
    and fryer_label_snapshot = btrim(fryer_label_snapshot) and length(fryer_label_snapshot) between 1 and 120
    and fryer_short_label_snapshot = btrim(fryer_short_label_snapshot) and length(fryer_short_label_snapshot) between 1 and 40
  ),
  constraint oil_tracking_fryer_results_notes_check check (
    length(opening_note) <= 2000 and length(closing_note) <= 2000
  )
);
create index oil_tracking_fryer_results_submission_idx
  on public.oil_tracking_fryer_results(submission_id, fryer_id);

create trigger oil_tracking_submissions_set_updated_at
before update on public.oil_tracking_submissions
for each row execute function private.set_updated_at();
create trigger oil_tracking_fryer_results_set_updated_at
before update on public.oil_tracking_fryer_results
for each row execute function private.set_updated_at();

create function private.oil_tracking_numeric_field(row_value jsonb, field_name text)
returns numeric language plpgsql immutable security definer set search_path = '' as $$
declare raw_value jsonb; raw_text text;
begin
  raw_value := row_value -> field_name;
  if raw_value is null or pg_catalog.jsonb_typeof(raw_value) = 'null' then
    return null;
  end if;
  if pg_catalog.jsonb_typeof(raw_value) = 'number' then
    return (raw_value #>> '{}')::numeric;
  end if;
  if pg_catalog.jsonb_typeof(raw_value) = 'string' then
    raw_text := pg_catalog.btrim(raw_value #>> '{}');
    if raw_text = '' then
      return null;
    end if;
    return raw_text::numeric;
  end if;
  raise exception 'invalid oil tracking numeric field' using errcode = '22023';
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid oil tracking numeric field' using errcode = '22023';
end $$;
revoke all on function private.oil_tracking_numeric_field(jsonb,text) from public, anon, authenticated;

create function private.validate_oil_tracking_rows(rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb;
begin
  if pg_catalog.jsonb_typeof(rows) <> 'array' or pg_catalog.jsonb_array_length(rows) > 50 then
    raise exception 'invalid oil tracking rows' using errcode = '22023';
  end if;
  if (
    select count(*) <> count(distinct value ->> 'fryer_id')
    from pg_catalog.jsonb_array_elements(rows)
  ) then
    raise exception 'duplicate oil tracking fryer' using errcode = '22023';
  end if;
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    if not (
      row_value ? 'fryer_id'
      and row_value ? 'fryer_label_snapshot'
      and row_value ? 'fryer_short_label_snapshot'
      and row_value ? 'in_use_today'
      and row_value ? 'oil_status'
      and row_value ? 'opening_status'
    )
    or pg_catalog.jsonb_typeof(row_value -> 'fryer_id') <> 'string'
    or pg_catalog.length(pg_catalog.btrim(row_value ->> 'fryer_id')) not between 1 and 80
    or pg_catalog.jsonb_typeof(row_value -> 'fryer_label_snapshot') <> 'string'
    or pg_catalog.length(pg_catalog.btrim(row_value ->> 'fryer_label_snapshot')) not between 1 and 120
    or pg_catalog.jsonb_typeof(row_value -> 'fryer_short_label_snapshot') <> 'string'
    or pg_catalog.length(pg_catalog.btrim(row_value ->> 'fryer_short_label_snapshot')) not between 1 and 40
    or pg_catalog.jsonb_typeof(row_value -> 'in_use_today') <> 'boolean'
    or row_value ->> 'oil_status' not in ('pending','new_oil','filtered_oil')
    or row_value ->> 'opening_status' not in ('pending','pass','fail')
    or pg_catalog.length(coalesce(row_value ->> 'opening_note', '')) > 2000
    or pg_catalog.length(coalesce(row_value ->> 'closing_note', '')) > 2000
    then
      raise exception 'invalid oil tracking row' using errcode = '22023';
    end if;
    perform private.oil_tracking_numeric_field(row_value, 'opening_temperature_c');
    perform private.oil_tracking_numeric_field(row_value, 'closing_tpm_percent');
  end loop;
end $$;
revoke all on function private.validate_oil_tracking_rows(jsonb) from public, anon, authenticated;

create function public.get_oil_tracking_current_state(actor_user_id uuid, target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; submission public.oil_tracking_submissions%rowtype;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  select * into submission
  from public.oil_tracking_submissions s
  where s.organization_id = c.organization_id
    and s.branch_id = c.branch_id
    and s.supervisor_team_id = c.team_id
    and s.business_date = c.business_date
  order by s.updated_at desc, s.id
  limit 1;

  return pg_catalog.jsonb_build_object(
    'submission_id', submission.id,
    'business_date', c.business_date,
    'opening_submitted_at', submission.opening_submitted_at,
    'closing_submitted_at', submission.closing_submitted_at,
    'opening_submitted', submission.opening_submitted_at is not null,
    'closing_submitted', submission.closing_submitted_at is not null,
    'rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', r.id,
        'fryer_id', r.fryer_id,
        'fryer_label_snapshot', r.fryer_label_snapshot,
        'fryer_short_label_snapshot', r.fryer_short_label_snapshot,
        'in_use_today', r.in_use_today,
        'oil_status', r.oil_status,
        'opening_temperature_c', r.opening_temperature_c,
        'opening_status', r.opening_status,
        'opening_note', r.opening_note,
        'closing_tpm_percent', r.closing_tpm_percent,
        'closing_note', r.closing_note
      ) order by r.fryer_id)
      from public.oil_tracking_fryer_results r
      where r.submission_id = submission.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'oil tracking state denied' using errcode = '42501';
end $$;

create function public.save_oil_tracking_draft(actor_user_id uuid, target_branch_id uuid, rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare c record; submission public.oil_tracking_submissions%rowtype;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  perform private.validate_oil_tracking_rows(rows);

  insert into public.oil_tracking_submissions(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state,
    branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot
  ) values (
    c.organization_id, c.branch_id, actor_user_id, c.team_id, c.business_date, 'draft',
    c.branch_name, c.supervisor_name, c.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_team_id, business_date) do update set
    state = 'draft',
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    team_name_snapshot = excluded.team_name_snapshot,
    opening_submitted_at = null,
    closing_submitted_at = null
  returning * into submission;

  delete from public.oil_tracking_fryer_results where submission_id = submission.id;
  insert into public.oil_tracking_fryer_results(
    submission_id, fryer_id, fryer_label_snapshot, fryer_short_label_snapshot,
    in_use_today, oil_status, opening_temperature_c, opening_status,
    opening_note, closing_tpm_percent, closing_note
  )
  select submission.id,
    pg_catalog.btrim(row_value ->> 'fryer_id'),
    pg_catalog.btrim(row_value ->> 'fryer_label_snapshot'),
    pg_catalog.btrim(row_value ->> 'fryer_short_label_snapshot'),
    (row_value ->> 'in_use_today')::boolean,
    row_value ->> 'oil_status',
    private.oil_tracking_numeric_field(row_value, 'opening_temperature_c'),
    row_value ->> 'opening_status',
    coalesce(row_value ->> 'opening_note', ''),
    private.oil_tracking_numeric_field(row_value, 'closing_tpm_percent'),
    coalesce(row_value ->> 'closing_note', '')
  from pg_catalog.jsonb_array_elements(rows) entry(row_value);

  return public.get_oil_tracking_current_state(actor_user_id, target_branch_id);
exception
  when no_data_found or too_many_rows then
    raise exception 'oil tracking draft denied' using errcode = '42501';
end $$;

alter table public.oil_tracking_submissions enable row level security;
alter table public.oil_tracking_fryer_results enable row level security;

revoke all on public.oil_tracking_submissions, public.oil_tracking_fryer_results from anon, authenticated;
revoke all on function public.save_oil_tracking_draft(uuid,uuid,jsonb), public.get_oil_tracking_current_state(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.save_oil_tracking_draft(uuid,uuid,jsonb), public.get_oil_tracking_current_state(uuid,uuid)
  to service_role;
