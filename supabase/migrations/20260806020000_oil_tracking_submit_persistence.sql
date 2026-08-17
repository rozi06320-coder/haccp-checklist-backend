-- Phase 2 Oil Tracking persistence: opening/closing submit, idempotency, and issues.

create table if not exists public.oil_tracking_submission_idempotency (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  section text not null check (section in ('opening','closing')),
  idempotency_key uuid not null,
  request_hash text not null,
  submission_id uuid references public.oil_tracking_submissions(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key(actor_user_id, section, idempotency_key),
  constraint oil_tracking_idempotency_hash_check check (length(request_hash) = 64)
);

alter table public.oil_tracking_submissions
  add constraint oil_tracking_submissions_id_org_branch_key
  unique(id, organization_id, branch_id);

-- checklist_issues cannot safely be reused here in Phase 2: it is constrained to
-- checklist_submissions children. Oil Tracking has its own submission parent.
create table if not exists public.oil_tracking_issues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id uuid not null,
  source_submission_id uuid not null,
  fryer_result_id uuid not null,
  section text not null,
  status text not null default 'new',
  fryer_id text not null,
  fryer_label_snapshot text not null,
  title text not null,
  remark text not null,
  tpm_status text,
  created_at timestamptz not null default now()
);
create index if not exists oil_tracking_issues_source_idx on public.oil_tracking_issues(source_submission_id);
create index if not exists oil_tracking_issues_org_status_idx on public.oil_tracking_issues(organization_id, status, created_at desc);

create function private.oil_tracking_tpm_status(tpm numeric)
returns text language sql immutable security invoker set search_path = '' as $$
  select case
    when tpm is null or tpm < 21 then 'good'
    when tpm < 22 then 'nearing_end'
    when tpm < 25 then 'filtering_required'
    else 'change_discard'
  end;
$$;
revoke all on function private.oil_tracking_tpm_status(numeric) from public, anon, authenticated;

create function private.validate_oil_tracking_opening(rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb; active_count integer := 0;
begin
  perform private.validate_oil_tracking_rows(rows);
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    if (row_value ->> 'in_use_today')::boolean then
      active_count := active_count + 1;
      if row_value ->> 'oil_status' not in ('new_oil','filtered_oil')
        or private.oil_tracking_numeric_field(row_value, 'opening_temperature_c') is null
        or row_value ->> 'opening_status' not in ('pass','fail')
        or (row_value ->> 'opening_status' = 'fail' and length(pg_catalog.btrim(coalesce(row_value ->> 'opening_note', ''))) = 0)
      then
        raise exception 'invalid oil tracking opening' using errcode = '22023';
      end if;
    end if;
  end loop;
  if active_count = 0 then
    raise exception 'invalid oil tracking opening' using errcode = '22023';
  end if;
end $$;
revoke all on function private.validate_oil_tracking_opening(jsonb) from public, anon, authenticated;

create function private.validate_oil_tracking_closing(rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare row_value jsonb; active_count integer := 0; tpm numeric;
begin
  perform private.validate_oil_tracking_rows(rows);
  for row_value in select value from pg_catalog.jsonb_array_elements(rows) loop
    if (row_value ->> 'in_use_today')::boolean then
      active_count := active_count + 1;
      tpm := private.oil_tracking_numeric_field(row_value, 'closing_tpm_percent');
      if tpm is null or (tpm >= 21 and length(pg_catalog.btrim(coalesce(row_value ->> 'closing_note', ''))) = 0) then
        raise exception 'invalid oil tracking closing' using errcode = '22023';
      end if;
    end if;
  end loop;
  if active_count = 0 then
    raise exception 'invalid oil tracking closing' using errcode = '22023';
  end if;
end $$;
revoke all on function private.validate_oil_tracking_closing(jsonb) from public, anon, authenticated;

create function private.oil_tracking_row_set_matches(submission uuid, rows jsonb)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select array_agg(fryer_id order by fryer_id)
    from public.oil_tracking_fryer_results
    where submission_id = submission
  ), array[]::text[]) = coalesce((
    select array_agg(pg_catalog.btrim(value ->> 'fryer_id') order by pg_catalog.btrim(value ->> 'fryer_id'))
    from pg_catalog.jsonb_array_elements(rows)
  ), array[]::text[]);
$$;
revoke all on function private.oil_tracking_row_set_matches(uuid,jsonb) from public, anon, authenticated;

create function private.replace_oil_tracking_rows(submission_id uuid, rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.oil_tracking_fryer_results r where r.submission_id = replace_oil_tracking_rows.submission_id;
  insert into public.oil_tracking_fryer_results(
    submission_id, fryer_id, fryer_label_snapshot, fryer_short_label_snapshot,
    in_use_today, oil_status, opening_temperature_c, opening_status,
    opening_note, closing_tpm_percent, closing_note
  )
  select submission_id,
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
end $$;
revoke all on function private.replace_oil_tracking_rows(uuid,jsonb) from public, anon, authenticated;

create function private.merge_oil_tracking_rows(submission_id uuid, rows jsonb, submitted_section text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.oil_tracking_row_set_matches(submission_id, rows) then
    raise exception 'submitted oil tracking row set is immutable' using errcode = '23505';
  end if;
  update public.oil_tracking_fryer_results r set
    fryer_label_snapshot = case when submitted_section = 'none' then pg_catalog.btrim(row_value ->> 'fryer_label_snapshot') else r.fryer_label_snapshot end,
    fryer_short_label_snapshot = case when submitted_section = 'none' then pg_catalog.btrim(row_value ->> 'fryer_short_label_snapshot') else r.fryer_short_label_snapshot end,
    in_use_today = case when submitted_section = 'none' then (row_value ->> 'in_use_today')::boolean else r.in_use_today end,
    oil_status = case when submitted_section <> 'opening' then row_value ->> 'oil_status' else r.oil_status end,
    opening_temperature_c = case when submitted_section <> 'opening' then private.oil_tracking_numeric_field(row_value, 'opening_temperature_c') else r.opening_temperature_c end,
    opening_status = case when submitted_section <> 'opening' then row_value ->> 'opening_status' else r.opening_status end,
    opening_note = case when submitted_section <> 'opening' then coalesce(row_value ->> 'opening_note', '') else r.opening_note end,
    closing_tpm_percent = case when submitted_section <> 'closing' then private.oil_tracking_numeric_field(row_value, 'closing_tpm_percent') else r.closing_tpm_percent end,
    closing_note = case when submitted_section <> 'closing' then coalesce(row_value ->> 'closing_note', '') else r.closing_note end
  from pg_catalog.jsonb_array_elements(rows) entry(row_value)
  where r.submission_id = merge_oil_tracking_rows.submission_id
    and r.fryer_id = pg_catalog.btrim(row_value ->> 'fryer_id');
end $$;
revoke all on function private.merge_oil_tracking_rows(uuid,jsonb,text) from public, anon, authenticated;

create function private.upsert_oil_tracking_submission(
  actor_user_id uuid,
  target_branch_id uuid,
  rows jsonb
) returns public.oil_tracking_submissions
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare c record; submission public.oil_tracking_submissions%rowtype;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  insert into public.oil_tracking_submissions(
    organization_id, branch_id, supervisor_user_id, supervisor_team_id, business_date, state,
    branch_name_snapshot, supervisor_name_snapshot, team_name_snapshot
  ) values (
    c.organization_id, c.branch_id, actor_user_id, c.team_id, c.business_date, 'draft',
    c.branch_name, c.supervisor_name, c.supervisor_name || ' Team'
  )
  on conflict(branch_id, supervisor_team_id, business_date) do update set
    branch_name_snapshot = excluded.branch_name_snapshot,
    supervisor_name_snapshot = excluded.supervisor_name_snapshot,
    team_name_snapshot = excluded.team_name_snapshot
  returning * into submission;

  if exists(select 1 from public.oil_tracking_fryer_results r where r.submission_id = submission.id) then
    if submission.opening_submitted_at is not null and submission.closing_submitted_at is not null then
      if not private.oil_tracking_row_set_matches(submission.id, rows) then
        raise exception 'submitted oil tracking row set is immutable' using errcode = '23505';
      end if;
    elsif submission.opening_submitted_at is not null then
      perform private.merge_oil_tracking_rows(submission.id, rows, 'opening');
    elsif submission.closing_submitted_at is not null then
      perform private.merge_oil_tracking_rows(submission.id, rows, 'closing');
    else
      perform private.replace_oil_tracking_rows(submission.id, rows);
    end if;
  else
    perform private.replace_oil_tracking_rows(submission.id, rows);
  end if;
  return submission;
exception
  when no_data_found or too_many_rows then
    raise exception 'oil tracking operation denied' using errcode = '42501';
end $$;
revoke all on function private.upsert_oil_tracking_submission(uuid,uuid,jsonb) from public, anon, authenticated;

create or replace function public.save_oil_tracking_draft(actor_user_id uuid, target_branch_id uuid, rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.validate_oil_tracking_rows(rows);
  perform private.upsert_oil_tracking_submission(actor_user_id, target_branch_id, rows);
  return public.get_oil_tracking_current_state(actor_user_id, target_branch_id);
end $$;

create function private.oil_tracking_current_result(actor_user_id uuid, target_branch_id uuid, submission_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select public.get_oil_tracking_current_state(actor_user_id, target_branch_id)
    || pg_catalog.jsonb_build_object(
      'submission_id', submission_id,
      'issue_count', (
        select count(*) from public.oil_tracking_issues issue
        where issue.source_submission_id = submission_id
      )
    );
$$;
revoke all on function private.oil_tracking_current_result(uuid,uuid,uuid) from public, anon, authenticated;

create function public.submit_oil_tracking_opening(
  actor_user_id uuid,
  target_branch_id uuid,
  idempotency_key uuid,
  request_hash text,
  rows jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare submission public.oil_tracking_submissions%rowtype; prior record;
begin
  if length(request_hash) <> 64 then
    raise exception 'invalid oil tracking opening' using errcode = '22023';
  end if;
  perform private.validate_oil_tracking_opening(rows);
  insert into public.oil_tracking_submission_idempotency(actor_user_id, section, idempotency_key, request_hash)
  values(actor_user_id, 'opening', idempotency_key, request_hash)
  on conflict do nothing;
  select * into strict prior from public.oil_tracking_submission_idempotency x
  where x.actor_user_id = submit_oil_tracking_opening.actor_user_id
    and x.section = 'opening'
    and x.idempotency_key = submit_oil_tracking_opening.idempotency_key
  for update;
  if prior.request_hash <> request_hash then
    raise exception 'idempotency conflict' using errcode = '23505';
  end if;
  if prior.submission_id is not null then
    return private.oil_tracking_current_result(actor_user_id, target_branch_id, prior.submission_id);
  end if;
  submission := private.upsert_oil_tracking_submission(actor_user_id, target_branch_id, rows);
  select * into strict submission from public.oil_tracking_submissions where id = submission.id for update;
  if submission.opening_submitted_at is not null then
    raise exception 'opening already submitted' using errcode = '23505';
  end if;
  update public.oil_tracking_submissions set
    opening_submitted_at = now(),
    state = case when closing_submitted_at is null then 'draft' else 'submitted' end
  where id = submission.id returning * into submission;
  insert into public.oil_tracking_issues(
    organization_id, branch_id, source_submission_id, fryer_result_id, section,
    fryer_id, fryer_label_snapshot, title, remark
  )
  select submission.organization_id, submission.branch_id, submission.id, r.id, 'opening',
    r.fryer_id, r.fryer_label_snapshot, 'Opening oil check failed', r.opening_note
  from public.oil_tracking_fryer_results r
  where r.submission_id = submission.id and r.in_use_today and r.opening_status = 'fail';
  update public.oil_tracking_submission_idempotency set submission_id = submission.id
  where oil_tracking_submission_idempotency.actor_user_id = submit_oil_tracking_opening.actor_user_id
    and oil_tracking_submission_idempotency.section = 'opening'
    and oil_tracking_submission_idempotency.idempotency_key = submit_oil_tracking_opening.idempotency_key;
  return private.oil_tracking_current_result(actor_user_id, target_branch_id, submission.id);
exception
  when no_data_found or too_many_rows then
    raise exception 'oil tracking opening denied' using errcode = '42501';
end $$;

create function public.submit_oil_tracking_closing(
  actor_user_id uuid,
  target_branch_id uuid,
  idempotency_key uuid,
  request_hash text,
  rows jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare submission public.oil_tracking_submissions%rowtype; prior record;
begin
  if length(request_hash) <> 64 then
    raise exception 'invalid oil tracking closing' using errcode = '22023';
  end if;
  perform private.validate_oil_tracking_closing(rows);
  insert into public.oil_tracking_submission_idempotency(actor_user_id, section, idempotency_key, request_hash)
  values(actor_user_id, 'closing', idempotency_key, request_hash)
  on conflict do nothing;
  select * into strict prior from public.oil_tracking_submission_idempotency x
  where x.actor_user_id = submit_oil_tracking_closing.actor_user_id
    and x.section = 'closing'
    and x.idempotency_key = submit_oil_tracking_closing.idempotency_key
  for update;
  if prior.request_hash <> request_hash then
    raise exception 'idempotency conflict' using errcode = '23505';
  end if;
  if prior.submission_id is not null then
    return private.oil_tracking_current_result(actor_user_id, target_branch_id, prior.submission_id);
  end if;
  submission := private.upsert_oil_tracking_submission(actor_user_id, target_branch_id, rows);
  select * into strict submission from public.oil_tracking_submissions where id = submission.id for update;
  if submission.closing_submitted_at is not null then
    raise exception 'closing already submitted' using errcode = '23505';
  end if;
  update public.oil_tracking_submissions set
    closing_submitted_at = now(),
    state = case when opening_submitted_at is null then 'draft' else 'submitted' end
  where id = submission.id returning * into submission;
  insert into public.oil_tracking_issues(
    organization_id, branch_id, source_submission_id, fryer_result_id, section,
    fryer_id, fryer_label_snapshot, title, remark, tpm_status
  )
  select submission.organization_id, submission.branch_id, submission.id, r.id, 'closing',
    r.fryer_id, r.fryer_label_snapshot,
    case private.oil_tracking_tpm_status(r.closing_tpm_percent)
      when 'nearing_end' then 'Closing TPM nearing oil end of life'
      when 'filtering_required' then 'Closing TPM filtering required'
      else 'Closing TPM oil change or discard required'
    end,
    r.closing_note,
    private.oil_tracking_tpm_status(r.closing_tpm_percent)
  from public.oil_tracking_fryer_results r
  where r.submission_id = submission.id
    and r.in_use_today
    and private.oil_tracking_tpm_status(r.closing_tpm_percent) <> 'good';
  update public.oil_tracking_submission_idempotency set submission_id = submission.id
  where oil_tracking_submission_idempotency.actor_user_id = submit_oil_tracking_closing.actor_user_id
    and oil_tracking_submission_idempotency.section = 'closing'
    and oil_tracking_submission_idempotency.idempotency_key = submit_oil_tracking_closing.idempotency_key;
  return private.oil_tracking_current_result(actor_user_id, target_branch_id, submission.id);
exception
  when no_data_found or too_many_rows then
    raise exception 'oil tracking closing denied' using errcode = '42501';
end $$;

alter table public.oil_tracking_submission_idempotency enable row level security;
alter table public.oil_tracking_issues enable row level security;

revoke all on public.oil_tracking_submission_idempotency, public.oil_tracking_issues from anon, authenticated;
revoke all on function public.submit_oil_tracking_opening(uuid,uuid,uuid,text,jsonb),
  public.submit_oil_tracking_closing(uuid,uuid,uuid,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.submit_oil_tracking_opening(uuid,uuid,uuid,text,jsonb),
  public.submit_oil_tracking_closing(uuid,uuid,uuid,text,jsonb)
  to service_role;
