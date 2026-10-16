-- Phase 3C: immutable Final Quiz attempts, server-side scoring, and durable
-- course completion. This migration does not publish curriculum or enable the
-- database-backed learner feature flag.

create table public.training_quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  enrollment_id uuid not null,
  employee_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  quiz_lesson_id uuid not null,
  attempt_number integer not null,
  status text not null default 'in_progress',
  locale text not null,
  question_order text[] not null,
  question_count integer not null,
  pass_threshold_bps integer not null,
  start_idempotency_key uuid not null,
  start_request_sha256 text not null,
  submit_idempotency_key uuid,
  submit_request_sha256 text,
  correct_count integer,
  score_bps integer,
  passed boolean,
  started_at timestamptz not null default statement_timestamp(),
  submitted_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint training_quiz_attempts_id_scope_key
    unique(id, organization_id, enrollment_id, employee_id, course_version_id, quiz_lesson_id),
  constraint training_quiz_attempts_number_key unique(enrollment_id, quiz_lesson_id, attempt_number),
  constraint training_quiz_attempts_start_idempotency_key unique(enrollment_id, start_idempotency_key),
  constraint training_quiz_attempts_submit_idempotency_key unique(enrollment_id, submit_idempotency_key),
  constraint training_quiz_attempts_enrollment_scope_fkey
    foreign key(enrollment_id, organization_id, employee_id, course_version_id)
    references public.training_enrollments(id, organization_id, employee_id, course_version_id) on delete restrict,
  constraint training_quiz_attempts_course_scope_fkey
    foreign key(course_version_id, course_id, organization_id)
    references public.training_course_versions(id, course_id, organization_id) on delete restrict,
  constraint training_quiz_attempts_lesson_scope_fkey
    foreign key(quiz_lesson_id, course_version_id, organization_id)
    references public.training_lessons(id, course_version_id, organization_id) on delete restrict,
  constraint training_quiz_attempts_status_check check(status in ('in_progress','submitted')),
  constraint training_quiz_attempts_locale_check check(locale in ('en','ar','id','hi','fil')),
  constraint training_quiz_attempts_number_check check(attempt_number > 0),
  constraint training_quiz_attempts_question_check check(
    question_count > 0 and cardinality(question_order)=question_count
    and array_position(question_order,null) is null
  ),
  constraint training_quiz_attempts_threshold_check check(pass_threshold_bps between 1 and 10000),
  constraint training_quiz_attempts_hash_check check(
    start_request_sha256 ~ '^[0-9a-f]{64}$'
    and (submit_request_sha256 is null or submit_request_sha256 ~ '^[0-9a-f]{64}$')
  ),
  constraint training_quiz_attempts_submission_check check(
    (status='in_progress' and submit_idempotency_key is null and submit_request_sha256 is null
      and correct_count is null and score_bps is null and passed is null and submitted_at is null)
    or
    (status='submitted' and submit_idempotency_key is not null and submit_request_sha256 is not null
      and correct_count between 0 and question_count and score_bps between 0 and 10000
      and passed is not null and submitted_at is not null and submitted_at >= started_at)
  )
);

create unique index training_quiz_attempts_one_open_idx
  on public.training_quiz_attempts(enrollment_id, quiz_lesson_id) where status='in_progress';
create index training_quiz_attempts_employee_version_idx
  on public.training_quiz_attempts(organization_id, employee_id, course_version_id, started_at desc);
create index training_quiz_attempts_enrollment_status_idx
  on public.training_quiz_attempts(enrollment_id, status, attempt_number desc);

create table public.training_quiz_attempt_answers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  attempt_id uuid not null,
  enrollment_id uuid not null,
  employee_id uuid not null,
  course_version_id uuid not null,
  quiz_lesson_id uuid not null,
  question_key text not null,
  question_position integer not null,
  selected_option_key text not null,
  correct boolean not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint training_quiz_attempt_answers_attempt_question_key unique(attempt_id, question_key),
  constraint training_quiz_attempt_answers_attempt_position_key unique(attempt_id, question_position),
  constraint training_quiz_attempt_answers_attempt_scope_fkey
    foreign key(attempt_id, organization_id, enrollment_id, employee_id, course_version_id, quiz_lesson_id)
    references public.training_quiz_attempts(id, organization_id, enrollment_id, employee_id, course_version_id, quiz_lesson_id)
    on delete restrict,
  constraint training_quiz_attempt_answers_key_check check(
    question_position > 0 and question_key ~ '^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$'
    and selected_option_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
  )
);

create index training_quiz_attempt_answers_attempt_idx
  on public.training_quiz_attempt_answers(attempt_id, question_position);

create table public.training_course_completions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  enrollment_id uuid not null,
  employee_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  passing_attempt_id uuid not null,
  quiz_lesson_id uuid not null,
  completed_at timestamptz not null default statement_timestamp(),
  branch_id_at_completion uuid not null,
  branch_name_at_completion text not null,
  operational_team_id_at_completion uuid not null,
  operational_team_name_at_completion text not null,
  identity_method text not null default 'branch_pin_employee_code',
  compliance_identity_verified boolean not null default false,
  created_at timestamptz not null default statement_timestamp(),
  constraint training_course_completions_enrollment_key unique(enrollment_id),
  constraint training_course_completions_employee_version_key unique(organization_id, employee_id, course_version_id),
  constraint training_course_completions_passing_attempt_key unique(passing_attempt_id),
  constraint training_course_completions_enrollment_scope_fkey
    foreign key(enrollment_id, organization_id, employee_id, course_version_id)
    references public.training_enrollments(id, organization_id, employee_id, course_version_id) on delete restrict,
  constraint training_course_completions_course_scope_fkey
    foreign key(course_version_id, course_id, organization_id)
    references public.training_course_versions(id, course_id, organization_id) on delete restrict,
  constraint training_course_completions_attempt_scope_fkey
    foreign key(passing_attempt_id, organization_id, enrollment_id, employee_id, course_version_id, quiz_lesson_id)
    references public.training_quiz_attempts(id, organization_id, enrollment_id, employee_id, course_version_id, quiz_lesson_id)
    on delete restrict,
  constraint training_course_completions_branch_org_fkey
    foreign key(branch_id_at_completion, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint training_course_completions_team_scope_fkey
    foreign key(operational_team_id_at_completion, branch_id_at_completion, organization_id)
    references public.branch_operational_teams(id, branch_id, organization_id) on delete restrict,
  constraint training_course_completions_identity_check
    check(identity_method='branch_pin_employee_code' and not compliance_identity_verified),
  constraint training_course_completions_snapshot_check check(
    length(btrim(branch_name_at_completion)) between 1 and 240
    and length(btrim(operational_team_name_at_completion)) between 1 and 240)
);

create index training_course_completions_employee_idx
  on public.training_course_completions(organization_id, employee_id, completed_at desc);
create index training_course_completions_version_idx
  on public.training_course_completions(organization_id, course_version_id, completed_at desc);

alter table public.training_quiz_attempts enable row level security;
alter table public.training_quiz_attempt_answers enable row level security;
alter table public.training_course_completions enable row level security;
revoke all on table public.training_quiz_attempts from public,anon,authenticated,service_role;
revoke all on table public.training_quiz_attempt_answers from public,anon,authenticated,service_role;
revoke all on table public.training_course_completions from public,anon,authenticated,service_role;

create or replace function private.training_assert_final_quiz_unlocked(enrollment public.training_enrollments)
returns public.training_lessons
language plpgsql stable security definer set search_path='' as $$
declare quiz public.training_lessons%rowtype; required_count integer; completed_count integer;
begin
  select lesson.* into quiz
  from public.training_modules module join public.training_lessons lesson
    on lesson.module_id=module.id and lesson.course_version_id=module.course_version_id and lesson.organization_id=module.organization_id
  where module.organization_id=enrollment.organization_id and module.course_version_id=enrollment.course_version_id
    and module.metadata->>'module_role'='final_assessment'
    and lesson.lesson_type='quiz' and lesson.required
    and lesson.metadata->>'assessment_scope'='course';
  if quiz.id is null then raise exception 'Final assessment is unavailable' using errcode='55000'; end if;
  select count(*)::integer into required_count from public.training_lessons lesson
    where lesson.organization_id=enrollment.organization_id and lesson.course_version_id=enrollment.course_version_id
      and lesson.required and lesson.lesson_type<>'quiz';
  select count(*)::integer into completed_count from public.training_lesson_progress progress
    join public.training_lessons lesson on lesson.id=progress.lesson_id and lesson.course_version_id=progress.course_version_id and lesson.organization_id=progress.organization_id
    where progress.enrollment_id=enrollment.id and progress.status='completed'
      and lesson.required and lesson.lesson_type<>'quiz';
  if required_count=0 or completed_count<>required_count then
    raise exception 'Final assessment is locked' using errcode='55000';
  end if;
  return quiz;
end;
$$;

create or replace function private.training_safe_quiz_questions(quiz public.training_lessons, selected_locale text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare questions jsonb; answer_keys jsonb;
begin
  questions:=quiz.content_i18n->selected_locale->'questions';
  answer_keys:=quiz.metadata->'answer_key_by_question';
  if jsonb_typeof(questions)<>'array' or jsonb_array_length(questions)<>27
    or jsonb_typeof(answer_keys)<>'object' or (select count(*) from jsonb_object_keys(answer_keys))<>27
    or (select count(distinct item->>'stable_key') from jsonb_array_elements(questions) item)<>27
    or exists(
      select 1 from jsonb_array_elements(questions) item
      where jsonb_typeof(item->'options')<>'array' or jsonb_array_length(item->'options')<2
        or not (answer_keys ? (item->>'stable_key'))
        or not exists(select 1 from jsonb_array_elements(item->'options') option where option->>'option_key'=answer_keys->>(item->>'stable_key'))
    ) then raise exception 'Final assessment contract is invalid' using errcode='55000'; end if;
  return (select jsonb_agg(jsonb_build_object(
    'question_key',item->>'stable_key','prompt',item->>'prompt',
    'options',(select jsonb_agg(jsonb_build_object('option_key',option->>'option_key','text',option->>'text') order by ordinality)
      from jsonb_array_elements(item->'options') with ordinality options(option,ordinality))
  ) order by ordinality) from jsonb_array_elements(questions) with ordinality source(item,ordinality));
end;
$$;

create or replace function public.start_training_final_quiz_attempt(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid,
  target_locale text,target_idempotency_key uuid
)
returns table(attempt_id uuid,attempt_number integer,status text,locale text,started_at timestamptz,
  question_count integer,pass_threshold_bps integer,questions jsonb)
language plpgsql security definer set search_path='' as $$
declare enrollment public.training_enrollments%rowtype; quiz public.training_lessons%rowtype;
  existing public.training_quiz_attempts%rowtype; saved public.training_quiz_attempts%rowtype;
  safe_questions jsonb; request_hash text; next_number integer;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  perform 1 from public.training_enrollments where id=enrollment.id for update;
  quiz:=private.training_assert_final_quiz_unlocked(enrollment);
  if not exists(
    select 1 from public.training_course_versions version,
      unnest(version.supported_locales) supported(locale)
    where version.id=enrollment.course_version_id and supported.locale=target_locale
  ) then
    raise exception 'Training locale is invalid' using errcode='22023';
  end if;
  safe_questions:=private.training_safe_quiz_questions(quiz,target_locale);
  request_hash:=pg_catalog.encode(extensions.digest(jsonb_build_object('enrollment_id',enrollment.id,'quiz_lesson_id',quiz.id,'locale',target_locale)::text,'sha256'),'hex');
  select * into existing from public.training_quiz_attempts attempt
    where attempt.enrollment_id=enrollment.id and attempt.start_idempotency_key=target_idempotency_key;
  if existing.id is not null then
    if existing.start_request_sha256<>request_hash then raise exception 'Idempotency key payload conflict' using errcode='23505'; end if;
    return query select existing.id,existing.attempt_number,existing.status,existing.locale,existing.started_at,
      existing.question_count,existing.pass_threshold_bps,private.training_safe_quiz_questions(quiz,existing.locale);
    return;
  end if;
  if exists(select 1 from public.training_course_completions completion where completion.enrollment_id=enrollment.id) then
    raise exception 'Training course is already completed' using errcode='55000';
  end if;
  if exists(select 1 from public.training_quiz_attempts attempt where attempt.enrollment_id=enrollment.id and attempt.quiz_lesson_id=quiz.id and attempt.status='in_progress') then
    raise exception 'A Final Quiz attempt is already in progress' using errcode='55000';
  end if;
  select coalesce(max(attempt.attempt_number),0)+1 into next_number from public.training_quiz_attempts attempt
    where attempt.enrollment_id=enrollment.id and attempt.quiz_lesson_id=quiz.id;
  insert into public.training_quiz_attempts(
    organization_id,enrollment_id,employee_id,course_id,course_version_id,quiz_lesson_id,
    attempt_number,locale,question_order,question_count,pass_threshold_bps,start_idempotency_key,start_request_sha256
  ) values(
    enrollment.organization_id,enrollment.id,enrollment.employee_id,enrollment.course_id,enrollment.course_version_id,quiz.id,
    next_number,target_locale,array(select value->>'question_key' from jsonb_array_elements(safe_questions) value),
    jsonb_array_length(safe_questions),quiz.pass_threshold_bps,target_idempotency_key,request_hash
  ) returning * into saved;
  return query select saved.id,saved.attempt_number,saved.status,saved.locale,saved.started_at,
    saved.question_count,saved.pass_threshold_bps,safe_questions;
end;
$$;

create or replace function public.get_training_final_quiz_attempt(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid,target_attempt_id uuid
)
returns table(attempt_id uuid,attempt_number integer,status text,locale text,started_at timestamptz,
  question_count integer,pass_threshold_bps integer,questions jsonb)
language plpgsql stable security definer set search_path='' as $$
declare enrollment public.training_enrollments%rowtype; quiz public.training_lessons%rowtype; attempt public.training_quiz_attempts%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  quiz:=private.training_assert_final_quiz_unlocked(enrollment);
  select * into attempt from public.training_quiz_attempts candidate where candidate.id=target_attempt_id
    and candidate.enrollment_id=enrollment.id and candidate.employee_id=enrollment.employee_id
    and candidate.course_version_id=enrollment.course_version_id and candidate.quiz_lesson_id=quiz.id and candidate.status='in_progress';
  if attempt.id is null then raise exception 'Final Quiz attempt is unavailable' using errcode='P0002'; end if;
  return query select attempt.id,attempt.attempt_number,attempt.status,attempt.locale,attempt.started_at,
    attempt.question_count,attempt.pass_threshold_bps,private.training_safe_quiz_questions(quiz,attempt.locale);
end;
$$;

create or replace function public.get_training_final_assessment_status(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid
)
returns table(locked boolean,in_progress_attempt_id uuid,latest_attempt_number integer,latest_status text,
  latest_correct_count integer,latest_question_count integer,latest_passed boolean,latest_submitted_at timestamptz,
  completed boolean,completed_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare enrollment public.training_enrollments%rowtype; required_count integer; completed_count integer;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  select count(*)::integer into required_count from public.training_lessons lesson
    where lesson.organization_id=enrollment.organization_id and lesson.course_version_id=enrollment.course_version_id and lesson.required and lesson.lesson_type<>'quiz';
  select count(*)::integer into completed_count from public.training_lesson_progress progress
    join public.training_lessons lesson on lesson.id=progress.lesson_id and lesson.course_version_id=progress.course_version_id and lesson.organization_id=progress.organization_id
    where progress.enrollment_id=enrollment.id and progress.status='completed' and lesson.required and lesson.lesson_type<>'quiz';
  return query select required_count=0 or completed_count<>required_count,
    (select attempt.id from public.training_quiz_attempts attempt where attempt.enrollment_id=enrollment.id and attempt.status='in_progress' order by attempt.attempt_number desc limit 1),
    latest.attempt_number,latest.status,latest.correct_count,latest.question_count,latest.passed,latest.submitted_at,
    completion.id is not null,completion.completed_at
  from (select attempt.* from public.training_quiz_attempts attempt where attempt.enrollment_id=enrollment.id order by attempt.attempt_number desc limit 1) latest
  full join (select saved.* from public.training_course_completions saved where saved.enrollment_id=enrollment.id) completion on true;
  if not found then return query select required_count=0 or completed_count<>required_count,null::uuid,null::integer,null::text,null::integer,null::integer,null::boolean,null::timestamptz,false,null::timestamptz; end if;
end;
$$;

create or replace function public.submit_training_final_quiz_attempt(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid,
  target_attempt_id uuid,target_idempotency_key uuid,target_answers jsonb
)
returns table(attempt_id uuid,attempt_number integer,status text,correct_count integer,question_count integer,
  score_bps integer,passed boolean,submitted_at timestamptz,course_completed boolean,course_completed_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare enrollment public.training_enrollments%rowtype; actor record; quiz public.training_lessons%rowtype;
  attempt public.training_quiz_attempts%rowtype; request_hash text; answer_count integer; correct_total integer;
  completion public.training_course_completions%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  perform 1 from public.training_enrollments where id=enrollment.id for update;
  quiz:=private.training_assert_final_quiz_unlocked(enrollment);
  select * into attempt from public.training_quiz_attempts candidate where candidate.id=target_attempt_id
    and candidate.enrollment_id=enrollment.id and candidate.employee_id=enrollment.employee_id
    and candidate.course_version_id=enrollment.course_version_id and candidate.quiz_lesson_id=quiz.id for update;
  if attempt.id is null then raise exception 'Final Quiz attempt is unavailable' using errcode='P0002'; end if;
  if jsonb_typeof(target_answers)<>'array' then raise exception 'Final Quiz answers are invalid' using errcode='22023'; end if;
  request_hash:=pg_catalog.encode(extensions.digest(target_answers::text,'sha256'),'hex');
  if attempt.status='submitted' then
    if attempt.submit_idempotency_key=target_idempotency_key and attempt.submit_request_sha256=request_hash then
      select * into completion from public.training_course_completions saved where saved.enrollment_id=enrollment.id;
      return query select attempt.id,attempt.attempt_number,attempt.status,attempt.correct_count,attempt.question_count,
        attempt.score_bps,attempt.passed,attempt.submitted_at,completion.id is not null,completion.completed_at;
      return;
    end if;
    raise exception 'Submitted Final Quiz attempts are immutable' using errcode='23505';
  end if;
  select count(*)::integer,count(distinct answer->>'question_key')::integer into answer_count,correct_total
    from jsonb_array_elements(target_answers) answer;
  if answer_count<>attempt.question_count or correct_total<>attempt.question_count then
    raise exception 'Exactly one answer per Final Quiz question is required' using errcode='22023';
  end if;
  if exists(
    select 1 from jsonb_array_elements(target_answers) answer
    where not ((answer ? 'question_key') and (answer ? 'option_key'))
      or not ((answer->>'question_key')=any(attempt.question_order))
      or not exists(
        select 1 from jsonb_array_elements(quiz.content_i18n->'en'->'questions') question,
          jsonb_array_elements(question->'options') option
        where question->>'stable_key'=answer->>'question_key' and option->>'option_key'=answer->>'option_key'
      )
  ) then raise exception 'Final Quiz answer is invalid' using errcode='22023'; end if;
  insert into public.training_quiz_attempt_answers(
    organization_id,attempt_id,enrollment_id,employee_id,course_version_id,quiz_lesson_id,
    question_key,question_position,selected_option_key,correct
  ) select enrollment.organization_id,attempt.id,enrollment.id,enrollment.employee_id,enrollment.course_version_id,quiz.id,
    answer->>'question_key',array_position(attempt.question_order,answer->>'question_key'),answer->>'option_key',
    quiz.metadata->'answer_key_by_question'->>(answer->>'question_key')=answer->>'option_key'
  from jsonb_array_elements(target_answers) answer;
  select count(*) filter(where saved.correct)::integer into correct_total from public.training_quiz_attempt_answers saved where saved.attempt_id=attempt.id;
  update public.training_quiz_attempts target set status='submitted',submit_idempotency_key=target_idempotency_key,
    submit_request_sha256=request_hash,correct_count=correct_total,
    score_bps=(correct_total*10000)/attempt.question_count,
    passed=(correct_total*10000>=attempt.question_count*attempt.pass_threshold_bps),submitted_at=statement_timestamp()
  where target.id=attempt.id returning * into attempt;
  if attempt.passed then
    select * into actor from private.training_legacy_employee_scope(target_organization_id,target_branch_id,target_employee_id);
    insert into public.training_course_completions(
      organization_id,enrollment_id,employee_id,course_id,course_version_id,passing_attempt_id,quiz_lesson_id,
      branch_id_at_completion,branch_name_at_completion,operational_team_id_at_completion,operational_team_name_at_completion
    ) values(enrollment.organization_id,enrollment.id,enrollment.employee_id,enrollment.course_id,enrollment.course_version_id,attempt.id,quiz.id,
      actor.branch_id,actor.branch_name,actor.operational_team_id,actor.operational_team_name)
    on conflict on constraint training_course_completions_enrollment_key do nothing;
  end if;
  select * into completion from public.training_course_completions saved where saved.enrollment_id=enrollment.id;
  return query select attempt.id,attempt.attempt_number,attempt.status,attempt.correct_count,attempt.question_count,
    attempt.score_bps,attempt.passed,attempt.submitted_at,completion.id is not null,completion.completed_at;
end;
$$;

create or replace function private.training_attempt_immutability_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' or old.status='submitted' then
    raise exception 'Submitted Training attempts are immutable' using errcode='55000';
  end if;
  return new;
end;
$$;
create trigger training_quiz_attempts_05_immutable
before update or delete on public.training_quiz_attempts for each row execute function private.training_attempt_immutability_guard();

create or replace function private.training_answer_immutability_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'Training attempt answers are immutable' using errcode='55000'; end;
$$;
create trigger training_quiz_attempt_answers_05_immutable
before update or delete on public.training_quiz_attempt_answers for each row execute function private.training_answer_immutability_guard();

create or replace function private.training_completion_immutability_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'Training completion is immutable' using errcode='55000'; end;
$$;
create or replace function private.training_completion_validation_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare required_count integer; completed_count integer;
begin
  if not exists(
    select 1 from public.training_quiz_attempts attempt
    where attempt.id=new.passing_attempt_id and attempt.organization_id=new.organization_id
      and attempt.enrollment_id=new.enrollment_id and attempt.employee_id=new.employee_id
      and attempt.course_version_id=new.course_version_id and attempt.quiz_lesson_id=new.quiz_lesson_id
      and attempt.status='submitted' and attempt.passed
  ) then raise exception 'A passing Final Quiz attempt is required' using errcode='55000'; end if;
  select count(*)::integer into required_count from public.training_lessons lesson
    where lesson.organization_id=new.organization_id and lesson.course_version_id=new.course_version_id
      and lesson.required and lesson.lesson_type<>'quiz';
  select count(*)::integer into completed_count from public.training_lesson_progress progress
    join public.training_lessons lesson on lesson.id=progress.lesson_id and lesson.course_version_id=progress.course_version_id and lesson.organization_id=progress.organization_id
    where progress.enrollment_id=new.enrollment_id and progress.status='completed' and lesson.required and lesson.lesson_type<>'quiz';
  if required_count=0 or completed_count<>required_count then
    raise exception 'All required Training lessons must be completed' using errcode='55000';
  end if;
  return new;
end;
$$;
create trigger training_course_completions_01_validate
before insert on public.training_course_completions for each row execute function private.training_completion_validation_guard();
create trigger training_course_completions_05_immutable
before update or delete on public.training_course_completions for each row execute function private.training_completion_immutability_guard();

create trigger training_quiz_attempts_90_set_updated_at before update on public.training_quiz_attempts
for each row execute function private.set_updated_at();

revoke all on function private.training_assert_final_quiz_unlocked(public.training_enrollments) from public,anon,authenticated,service_role;
revoke all on function private.training_safe_quiz_questions(public.training_lessons,text) from public,anon,authenticated,service_role;
revoke all on function private.training_attempt_immutability_guard() from public,anon,authenticated,service_role;
revoke all on function private.training_answer_immutability_guard() from public,anon,authenticated,service_role;
revoke all on function private.training_completion_immutability_guard() from public,anon,authenticated,service_role;
revoke all on function private.training_completion_validation_guard() from public,anon,authenticated,service_role;
revoke all on function public.start_training_final_quiz_attempt(uuid,uuid,uuid,uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.get_training_final_quiz_attempt(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_training_final_assessment_status(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.submit_training_final_quiz_attempt(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.start_training_final_quiz_attempt(uuid,uuid,uuid,uuid,text,uuid) to service_role;
grant execute on function public.get_training_final_quiz_attempt(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.get_training_final_assessment_status(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.submit_training_final_quiz_attempt(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) to service_role;

comment on table public.training_quiz_attempts is 'Immutable-on-submission internal-learning Final Quiz attempts; Branch PIN plus employee code is lower-assurance identity.';
comment on table public.training_quiz_attempt_answers is 'Auditable per-question selections and server-computed correctness for submitted Training attempts.';
comment on table public.training_course_completions is 'Permanent first passing completion evidence for internal learning; not identity-verified compliance certification.';
