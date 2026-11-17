-- Read-only Training Supervisor quiz question preview.
-- Gated to active training_memberships with training_role='training_supervisor' and
-- credential version verification via get_training_supervisor_context.
-- Never returns correct_option_key, answer keys, explanation_i18n, or any grading metadata.

create or replace function public.get_training_supervisor_baladiyah_quiz_preview(
  p_actor_user_id uuid,
  p_expected_credential_version uuid,
  p_locale text
)
returns table(
  question_number integer,
  question_key text,
  prompt text,
  options jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_membership public.training_memberships%rowtype;
  v_quiz public.training_lessons%rowtype;
  v_safe_questions jsonb;
  v_q jsonb;
  v_idx integer := 0;
begin
  -- 1. Guard: reject null inputs immediately.
  if p_actor_user_id is null or p_expected_credential_version is null or p_locale is null then
    raise exception 'training supervisor access denied' using errcode = '42501';
  end if;

  -- 2. Verify active Training Supervisor membership with matching credential version.
  --    Joins organizations and profiles to ensure the account itself is not suspended.
  select tm.*
    into v_membership
    from public.training_memberships tm
    join public.organizations org on org.id = tm.organization_id
    join public.profiles p on p.id = tm.user_id
   where tm.user_id = p_actor_user_id
     and tm.training_role = 'training_supervisor'
     and tm.active
     and tm.credential_version = p_expected_credential_version
     and org.active
     and p.disabled_at is null
     and not p.must_change_password;

  if v_membership.user_id is null then
    raise exception 'training supervisor access denied' using errcode = '42501';
  end if;

  -- 3. Validate locale against the five supported Baladiyah languages.
  if p_locale not in ('en', 'ar', 'id', 'hi', 'fil') then
    raise exception 'invalid locale: must be one of en, ar, id, hi, fil' using errcode = '22023';
  end if;

  -- 4. Locate the published final-quiz lesson for this organization's Baladiyah course.
  --    Uses version_number = 1 (the single Baladiyah version) and the final_assessment module role.
  select lesson.*
    into v_quiz
    from public.training_courses course
    join public.training_course_versions version
      on version.organization_id = course.organization_id
     and version.course_id = course.id
    join public.training_modules module
      on module.organization_id = version.organization_id
     and module.course_version_id = version.id
    join public.training_lessons lesson
      on lesson.organization_id = module.organization_id
     and lesson.course_version_id = module.course_version_id
     and lesson.module_id = module.id
   where course.organization_id = v_membership.organization_id
     and course.course_key = 'baladiyah-food-safety-hygiene'
     and version.version_number = 1
     and version.status = 'published'
     and module.metadata->>'module_role' = 'final_assessment'
     and lesson.lesson_type = 'quiz'
     and lesson.required
   limit 1;

  if v_quiz.id is null then
    raise exception 'Baladiyah final quiz is unavailable for this organization' using errcode = 'P0002';
  end if;

  -- 5. Use the existing private helper to strip answer keys and return safe question shapes.
  v_safe_questions := private.training_safe_quiz_questions(v_quiz, p_locale);

  if jsonb_typeof(v_safe_questions) <> 'array' then
    raise exception 'Quiz content is unavailable or malformed' using errcode = '55000';
  end if;

  -- 6. Return questions with 1-based numbering. Never exposes correct_option_key,
  --    explanation_i18n, answer_key_by_question, or storage_object_path.
  for v_q in select value from jsonb_array_elements(v_safe_questions)
  loop
    v_idx := v_idx + 1;
    question_number := v_idx;
    question_key := v_q->>'question_key';
    prompt := v_q->>'prompt';
    options := v_q->'options';
    return next;
  end loop;
end;
$$;

-- Lock down execution: only service_role (the backend) may call this function.
-- Revoke from public, anon, authenticated, and service_role first so the grant is idempotent.
revoke all on function public.get_training_supervisor_baladiyah_quiz_preview(uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.get_training_supervisor_baladiyah_quiz_preview(uuid, uuid, text)
  to service_role;

comment on function public.get_training_supervisor_baladiyah_quiz_preview(uuid, uuid, text) is
  'Read-only preview of the Baladiyah final quiz questions for authorized Training Supervisors. '
  'Verifies active training_memberships with training_role=''training_supervisor'' and credential '
  'version before returning question prompts and options. '
  'NEVER returns correct_option_key, answer keys, explanation_i18n, or any grading metadata. '
  'Restricted to service_role execution only.';
