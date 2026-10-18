-- Harden Phase 3B lesson mutations without changing the lower-assurance
-- Branch PIN + Employee Code identity model. Existing completed history is
-- preserved; these rules apply to subsequent learner mutations.

create or replace function public.start_training_lesson(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_enrollment_id uuid,
  target_lesson_id uuid
)
returns setof public.training_lesson_progress
language plpgsql
security definer
set search_path = ''
as $$
declare
  enrollment public.training_enrollments%rowtype;
  selected_lesson public.training_lessons%rowtype;
  saved public.training_lesson_progress%rowtype;
  target_sequence integer;
  next_sequence integer;
begin
  enrollment := private.assert_training_progress_enrollment(
    target_organization_id,
    target_branch_id,
    target_employee_id,
    target_enrollment_id
  );

  -- Serialize all lesson transitions for one enrollment. The unique
  -- enrollment/lesson key remains the final duplicate-write guard.
  perform 1
  from public.training_enrollments locked
  where locked.id = enrollment.id
  for update;

  -- Revalidate after acquiring the lock so prerequisite and publication
  -- changes cannot be missed while this mutation was waiting.
  enrollment := private.assert_training_progress_enrollment(
    target_organization_id,
    target_branch_id,
    target_employee_id,
    target_enrollment_id
  );

  select lesson.*
  into selected_lesson
  from public.training_lessons lesson
  where lesson.id = target_lesson_id
    and lesson.organization_id = enrollment.organization_id
    and lesson.course_version_id = enrollment.course_version_id
    and lesson.required
    and lesson.lesson_type <> 'quiz';

  if selected_lesson.id is null then
    raise exception 'Training lesson is unavailable' using errcode = 'P0002';
  end if;

  select progress.*
  into saved
  from public.training_lesson_progress progress
  where progress.enrollment_id = enrollment.id
    and progress.lesson_id = selected_lesson.id
  for update;

  -- Starting an already completed lesson is a safe idempotent replay. It must
  -- not alter the original start or completion timestamps.
  if saved.id is not null and saved.status = 'completed' then
    return next saved;
    return;
  end if;

  with ordered_lessons as (
    select
      lesson.id,
      row_number() over (
        order by module.position, lesson.position, module.id, lesson.id
      )::integer as sequence
    from public.training_modules module
    join public.training_lessons lesson
      on lesson.module_id = module.id
     and lesson.course_version_id = module.course_version_id
     and lesson.organization_id = module.organization_id
    where module.organization_id = enrollment.organization_id
      and module.course_version_id = enrollment.course_version_id
      and lesson.required
      and lesson.lesson_type <> 'quiz'
  )
  select ordered.sequence
  into target_sequence
  from ordered_lessons ordered
  where ordered.id = selected_lesson.id;

  with ordered_lessons as (
    select
      lesson.id,
      row_number() over (
        order by module.position, lesson.position, module.id, lesson.id
      )::integer as sequence
    from public.training_modules module
    join public.training_lessons lesson
      on lesson.module_id = module.id
     and lesson.course_version_id = module.course_version_id
     and lesson.organization_id = module.organization_id
    where module.organization_id = enrollment.organization_id
      and module.course_version_id = enrollment.course_version_id
      and lesson.required
      and lesson.lesson_type <> 'quiz'
  )
  select min(ordered.sequence)
  into next_sequence
  from ordered_lessons ordered
  left join public.training_lesson_progress progress
    on progress.enrollment_id = enrollment.id
   and progress.lesson_id = ordered.id
  where progress.status is distinct from 'completed';

  if target_sequence is null or next_sequence is null or target_sequence <> next_sequence then
    raise exception 'Training lessons must be completed in order' using errcode = '55000';
  end if;

  insert into public.training_lesson_progress(
    organization_id,
    enrollment_id,
    employee_id,
    course_version_id,
    lesson_id
  ) values (
    enrollment.organization_id,
    enrollment.id,
    enrollment.employee_id,
    enrollment.course_version_id,
    selected_lesson.id
  )
  on conflict on constraint training_lesson_progress_enrollment_lesson_key do nothing;

  update public.training_enrollments target
  set started_at = coalesce(target.started_at, statement_timestamp()),
      last_accessed_lesson_id = selected_lesson.id,
      last_accessed_at = statement_timestamp()
  where target.id = enrollment.id;

  select progress.*
  into saved
  from public.training_lesson_progress progress
  where progress.enrollment_id = enrollment.id
    and progress.lesson_id = selected_lesson.id;

  return next saved;
end;
$$;

create or replace function public.complete_training_lesson(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_enrollment_id uuid,
  target_lesson_id uuid
)
returns setof public.training_lesson_progress
language plpgsql
security definer
set search_path = ''
as $$
declare
  enrollment public.training_enrollments%rowtype;
  selected_lesson public.training_lessons%rowtype;
  saved public.training_lesson_progress%rowtype;
  target_sequence integer;
  next_sequence integer;
begin
  enrollment := private.assert_training_progress_enrollment(
    target_organization_id,
    target_branch_id,
    target_employee_id,
    target_enrollment_id
  );

  perform 1
  from public.training_enrollments locked
  where locked.id = enrollment.id
  for update;

  enrollment := private.assert_training_progress_enrollment(
    target_organization_id,
    target_branch_id,
    target_employee_id,
    target_enrollment_id
  );

  select lesson.*
  into selected_lesson
  from public.training_lessons lesson
  where lesson.id = target_lesson_id
    and lesson.organization_id = enrollment.organization_id
    and lesson.course_version_id = enrollment.course_version_id
    and lesson.required
    and lesson.lesson_type <> 'quiz';

  if selected_lesson.id is null then
    raise exception 'Training lesson is unavailable' using errcode = 'P0002';
  end if;

  select progress.*
  into saved
  from public.training_lesson_progress progress
  where progress.enrollment_id = enrollment.id
    and progress.lesson_id = selected_lesson.id
  for update;

  -- Completion is idempotent, but an absent progress row is no longer turned
  -- directly into completed progress.
  if saved.id is not null and saved.status = 'completed' then
    return next saved;
    return;
  end if;

  if saved.id is null or saved.status <> 'in_progress' then
    raise exception 'Training lesson must be started before completion' using errcode = '55000';
  end if;

  with ordered_lessons as (
    select
      lesson.id,
      row_number() over (
        order by module.position, lesson.position, module.id, lesson.id
      )::integer as sequence
    from public.training_modules module
    join public.training_lessons lesson
      on lesson.module_id = module.id
     and lesson.course_version_id = module.course_version_id
     and lesson.organization_id = module.organization_id
    where module.organization_id = enrollment.organization_id
      and module.course_version_id = enrollment.course_version_id
      and lesson.required
      and lesson.lesson_type <> 'quiz'
  )
  select ordered.sequence
  into target_sequence
  from ordered_lessons ordered
  where ordered.id = selected_lesson.id;

  with ordered_lessons as (
    select
      lesson.id,
      row_number() over (
        order by module.position, lesson.position, module.id, lesson.id
      )::integer as sequence
    from public.training_modules module
    join public.training_lessons lesson
      on lesson.module_id = module.id
     and lesson.course_version_id = module.course_version_id
     and lesson.organization_id = module.organization_id
    where module.organization_id = enrollment.organization_id
      and module.course_version_id = enrollment.course_version_id
      and lesson.required
      and lesson.lesson_type <> 'quiz'
  )
  select min(ordered.sequence)
  into next_sequence
  from ordered_lessons ordered
  left join public.training_lesson_progress progress
    on progress.enrollment_id = enrollment.id
   and progress.lesson_id = ordered.id
  where progress.status is distinct from 'completed';

  if target_sequence is null or next_sequence is null or target_sequence <> next_sequence then
    raise exception 'Training lessons must be completed in order' using errcode = '55000';
  end if;

  update public.training_lesson_progress progress
  set status = 'completed',
      completed_at = statement_timestamp()
  where progress.id = saved.id
    and progress.status = 'in_progress'
  returning progress.* into saved;

  if saved.id is null then
    raise exception 'Training lesson progress changed concurrently' using errcode = '40001';
  end if;

  update public.training_enrollments target
  set last_accessed_lesson_id = selected_lesson.id,
      last_accessed_at = statement_timestamp()
  where target.id = enrollment.id;

  return next saved;
end;
$$;

revoke all on function public.start_training_lesson(uuid,uuid,uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.complete_training_lesson(uuid,uuid,uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.start_training_lesson(uuid,uuid,uuid,uuid,uuid)
  to service_role;
grant execute on function public.complete_training_lesson(uuid,uuid,uuid,uuid,uuid)
  to service_role;

comment on function public.start_training_lesson(uuid,uuid,uuid,uuid,uuid) is
  'Starts only the next required instructional lesson for the lower-assurance Branch PIN plus Employee Code learner scope.';
comment on function public.complete_training_lesson(uuid,uuid,uuid,uuid,uuid) is
  'Completes only an explicitly started next required instructional lesson; repeated completion preserves the first server timestamp.';
