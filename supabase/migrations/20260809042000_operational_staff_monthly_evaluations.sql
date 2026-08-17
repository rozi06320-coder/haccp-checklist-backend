create table if not exists public.operational_staff_monthly_evaluations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  supervisor_team_id uuid not null references public.branch_supervisor_teams(id) on delete restrict,
  operational_staff_id uuid not null references public.operational_staff(id) on delete restrict,
  evaluation_month date not null,
  evaluator_name text,
  status text not null default 'draft',
  average_score numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_monthly_evaluations_team_staff_month_key unique (supervisor_team_id, operational_staff_id, evaluation_month),
  constraint operational_staff_monthly_evaluations_month_start_check check (evaluation_month = date_trunc('month', evaluation_month)::date),
  constraint operational_staff_monthly_evaluations_status_check check (status in ('draft','completed')),
  constraint operational_staff_monthly_evaluations_evaluator_check check (evaluator_name is null or (evaluator_name=pg_catalog.btrim(evaluator_name) and length(evaluator_name) between 1 and 120)),
  constraint operational_staff_monthly_evaluations_average_check check (average_score is null or (average_score >= 1 and average_score <= 5))
);

create table if not exists public.operational_staff_monthly_evaluation_scores (
  id uuid primary key default gen_random_uuid(),
  evaluation_id uuid not null references public.operational_staff_monthly_evaluations(id) on delete cascade,
  section text not null,
  factor_key text not null,
  factor_label text not null,
  rating integer,
  comment text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_monthly_scores_unique_factor unique (evaluation_id, section, factor_key),
  constraint operational_staff_monthly_scores_rating_check check (rating is null or rating between 1 and 5),
  constraint operational_staff_monthly_scores_section_check check (section=pg_catalog.btrim(section) and length(section) between 1 and 80),
  constraint operational_staff_monthly_scores_key_check check (factor_key=pg_catalog.btrim(factor_key) and length(factor_key) between 1 and 120),
  constraint operational_staff_monthly_scores_label_check check (factor_label=pg_catalog.btrim(factor_label) and length(factor_label) between 1 and 160),
  constraint operational_staff_monthly_scores_comment_check check (comment is null or (comment=pg_catalog.btrim(comment) and length(comment) between 1 and 2000))
);

drop trigger if exists operational_staff_monthly_evaluations_set_updated_at on public.operational_staff_monthly_evaluations;
create trigger operational_staff_monthly_evaluations_set_updated_at
before update on public.operational_staff_monthly_evaluations
for each row execute function private.set_updated_at();

drop trigger if exists operational_staff_monthly_scores_set_updated_at on public.operational_staff_monthly_evaluation_scores;
create trigger operational_staff_monthly_scores_set_updated_at
before update on public.operational_staff_monthly_evaluation_scores
for each row execute function private.set_updated_at();

alter table public.operational_staff_monthly_evaluations enable row level security;
alter table public.operational_staff_monthly_evaluation_scores enable row level security;

revoke all on table public.operational_staff_monthly_evaluations, public.operational_staff_monthly_evaluation_scores
  from public, anon, authenticated, service_role;
grant select on table public.operational_staff_monthly_evaluations, public.operational_staff_monthly_evaluation_scores
  to authenticated;

create or replace function private.clean_monthly_evaluation_text(value text, max_length integer)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare cleaned text := nullif(pg_catalog.btrim(value), '');
begin
  if cleaned is not null and length(cleaned) > max_length then
    raise exception 'invalid monthly evaluation text' using errcode='22023';
  end if;
  return cleaned;
end;
$$;

create or replace function private.monthly_evaluation_scores(scores jsonb, completed boolean)
returns table(section text, factor_key text, factor_label text, rating integer, comment text)
language plpgsql
immutable
set search_path = ''
as $$
declare item jsonb;
declare clean_section text;
declare clean_key text;
declare clean_label text;
declare raw_rating text;
declare parsed_rating integer;
declare clean_comment text;
begin
  if jsonb_typeof(scores) <> 'array' or jsonb_array_length(scores) < 1 or jsonb_array_length(scores) > 100 then
    raise exception 'invalid monthly evaluation scores' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(scores) loop
    clean_section := private.clean_monthly_evaluation_text(item->>'section',80);
    clean_key := private.clean_monthly_evaluation_text(item->>'factor_key',120);
    clean_label := private.clean_monthly_evaluation_text(item->>'factor_label',160);
    clean_comment := private.clean_monthly_evaluation_text(item->>'comment',2000);
    raw_rating := nullif(pg_catalog.btrim(item->>'rating'), '');
    if clean_section is null or clean_key is null or clean_label is null then
      raise exception 'invalid monthly evaluation scores' using errcode='22023';
    end if;
    if raw_rating is null or raw_rating = 'null' then
      parsed_rating := null;
    else
      begin
        parsed_rating := raw_rating::integer;
      exception when invalid_text_representation then
        raise exception 'invalid monthly evaluation rating' using errcode='22023';
      end;
      if parsed_rating not between 1 and 5 or raw_rating !~ '^[1-5]$' then
        raise exception 'invalid monthly evaluation rating' using errcode='22023';
      end if;
    end if;
    if completed and parsed_rating is null then
      raise exception 'completed monthly evaluation requires all ratings' using errcode='23514';
    end if;
    section := clean_section;
    factor_key := clean_key;
    factor_label := clean_label;
    rating := parsed_rating;
    comment := clean_comment;
    return next;
  end loop;
end;
$$;

create or replace function public.list_operational_staff_monthly_evaluations(actor_user_id uuid, target_branch_id uuid, requested_month date)
returns table(
  id uuid,
  operational_staff_id uuid,
  evaluation_month date,
  evaluator_name text,
  status text,
  average_score numeric,
  scores jsonb,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare target_team public.branch_supervisor_teams%rowtype;
begin
  if requested_month is null or requested_month <> date_trunc('month', requested_month)::date then
    raise exception 'invalid evaluation month' using errcode='22023';
  end if;
  select team.* into strict target_team
  from public.branch_supervisor_teams team
  where team.supervisor_user_id=actor_user_id and team.branch_id=target_branch_id and team.active;
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,target_team.id) then
    raise exception 'monthly evaluation access denied' using errcode='42501';
  end if;
  return query
  select evaluation.id, evaluation.operational_staff_id, evaluation.evaluation_month,
    evaluation.evaluator_name, evaluation.status, evaluation.average_score,
    coalesce(jsonb_agg(jsonb_build_object(
      'section', score.section,
      'factor_key', score.factor_key,
      'factor_label', score.factor_label,
      'rating', score.rating,
      'comment', score.comment
    ) order by score.section, score.factor_key) filter (where score.id is not null), '[]'::jsonb),
    evaluation.updated_at
  from public.operational_staff_monthly_evaluations evaluation
  join public.operational_staff_assignments assignment
    on assignment.supervisor_team_id=target_team.id
    and assignment.operational_staff_id=evaluation.operational_staff_id
    and assignment.active
  left join public.operational_staff_monthly_evaluation_scores score
    on score.evaluation_id=evaluation.id
  where evaluation.supervisor_team_id=target_team.id
    and evaluation.evaluation_month=requested_month
  group by evaluation.id
  order by evaluation.updated_at desc, evaluation.id;
exception when no_data_found or too_many_rows then
  raise exception 'monthly evaluation access denied' using errcode='42501';
end;
$$;

create or replace function public.save_operational_staff_monthly_evaluation(
  actor_user_id uuid,
  target_branch_id uuid,
  target_staff_id uuid,
  requested_month date,
  new_evaluator_name text,
  score_payload jsonb,
  new_status text
)
returns table(
  id uuid,
  operational_staff_id uuid,
  evaluation_month date,
  evaluator_name text,
  status text,
  average_score numeric,
  scores jsonb,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare target_team public.branch_supervisor_teams%rowtype;
declare saved_id uuid;
declare computed_average numeric;
declare clean_evaluator text := private.clean_monthly_evaluation_text(new_evaluator_name,120);
declare completed boolean := new_status = 'completed';
begin
  if requested_month is null or requested_month <> date_trunc('month', requested_month)::date
    or new_status not in ('draft','completed')
  then raise exception 'invalid monthly evaluation' using errcode='22023'; end if;

  if to_regclass('pg_temp.monthly_score_payload') is not null then
    drop table monthly_score_payload;
  end if;
  create temporary table monthly_score_payload(
    section text,
    factor_key text,
    factor_label text,
    rating integer,
    comment text
  ) on commit drop;
  insert into monthly_score_payload
  select parsed.section, parsed.factor_key, parsed.factor_label, parsed.rating, parsed.comment
  from private.monthly_evaluation_scores(score_payload, completed) parsed;

  select case when count(rating) = 0 then null else round(avg(rating)::numeric, 2) end
  into computed_average
  from monthly_score_payload;

  select team.* into strict target_team
  from public.branch_supervisor_teams team
  where team.supervisor_user_id=actor_user_id and team.branch_id=target_branch_id and team.active;

  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,target_team.id)
    or not exists (
      select 1
      from public.operational_staff staff
      join public.operational_staff_assignments assignment
        on assignment.operational_staff_id=staff.id
        and assignment.supervisor_team_id=target_team.id
        and assignment.active
      where staff.id=target_staff_id
        and staff.branch_id=target_branch_id
        and staff.organization_id=target_team.organization_id
        and staff.employment_status='active'
    )
  then raise exception 'monthly evaluation access denied' using errcode='42501'; end if;

  insert into public.operational_staff_monthly_evaluations(
    organization_id, branch_id, supervisor_team_id, operational_staff_id,
    evaluation_month, evaluator_name, status, average_score
  )
  values (
    target_team.organization_id, target_branch_id, target_team.id,
    target_staff_id,
    requested_month,
    clean_evaluator, new_status, computed_average
  )
  on conflict on constraint operational_staff_monthly_evaluations_team_staff_month_key do update set
    evaluator_name=excluded.evaluator_name,
    status=excluded.status,
    average_score=excluded.average_score,
    updated_at=now()
  returning operational_staff_monthly_evaluations.id into saved_id;

  delete from public.operational_staff_monthly_evaluation_scores
  where evaluation_id=saved_id;
  insert into public.operational_staff_monthly_evaluation_scores(evaluation_id, section, factor_key, factor_label, rating, comment)
  select saved_id, payload.section, payload.factor_key, payload.factor_label, payload.rating, payload.comment
  from monthly_score_payload payload;

  return query
  select evaluation.id, evaluation.operational_staff_id, evaluation.evaluation_month,
    evaluation.evaluator_name, evaluation.status, evaluation.average_score,
    coalesce(jsonb_agg(jsonb_build_object(
      'section', score.section,
      'factor_key', score.factor_key,
      'factor_label', score.factor_label,
      'rating', score.rating,
      'comment', score.comment
    ) order by score.section, score.factor_key) filter (where score.id is not null), '[]'::jsonb),
    evaluation.updated_at
  from public.operational_staff_monthly_evaluations evaluation
  left join public.operational_staff_monthly_evaluation_scores score on score.evaluation_id=evaluation.id
  where evaluation.id=saved_id
  group by evaluation.id;
exception when no_data_found or too_many_rows then
  raise exception 'monthly evaluation access denied' using errcode='42501';
end;
$$;

revoke all on function public.list_operational_staff_monthly_evaluations(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.list_operational_staff_monthly_evaluations(uuid, uuid, date) to service_role;
grant execute on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) to service_role;
