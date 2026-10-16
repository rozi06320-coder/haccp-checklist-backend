-- Read-only Internal Admin preview for the exact Baladiyah v1 draft contract.
-- Quiz answer metadata and private Storage coordinates are deliberately excluded.

create or replace function public.get_internal_admin_training_draft_preview(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns table(
  organization_id uuid,
  course_id uuid,
  course_key text,
  course_version_id uuid,
  version_number integer,
  version_status text,
  revision bigint,
  content_hash text,
  default_locale text,
  supported_locales text[],
  course_title_i18n jsonb,
  course_description_i18n jsonb,
  module_id uuid,
  module_key text,
  module_position integer,
  module_title_i18n jsonb,
  module_description_i18n jsonb,
  lesson_id uuid,
  lesson_key text,
  lesson_position integer,
  lesson_type text,
  required boolean,
  lesson_title_i18n jsonb,
  lesson_objective_i18n jsonb,
  lesson_content_i18n jsonb,
  question_count integer,
  pass_threshold_bps integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  expected_locales constant text[] := array['en','ar','id','hi','fil']::text[];
  expected_hash constant text := '9bfb8467b8a43dc61db87833d0532403d14ecc6d3f63cb57e37582ea32d634d3';
  locale text;
begin
  perform private.assert_internal_admin_training_draft(
    actor_user_id,
    target_organization_id,
    target_course_id,
    target_course_version_id
  );

  if not exists (
    select 1
    from public.training_courses course
    join public.training_course_versions version
      on version.course_id = course.id
     and version.organization_id = course.organization_id
    where course.id = target_course_id
      and course.organization_id = target_organization_id
      and course.course_key = 'baladiyah-food-safety-hygiene'
      and course.status = 'active'
      and version.id = target_course_version_id
      and version.version_number = 1
      and version.status = 'draft'
      and version.revision = 2
      and version.content_hash = expected_hash
      and version.default_locale = 'en'
      and version.supported_locales = expected_locales
      and version.published_at is null
      and version.retired_at is null
  ) then
    raise exception 'Training draft preview contract changed' using errcode = '55000';
  end if;

  if (select count(*) from public.training_modules counted_module where counted_module.organization_id = target_organization_id and counted_module.course_version_id = target_course_version_id) <> 10
     or (select count(*) from public.training_lessons counted_lesson where counted_lesson.organization_id = target_organization_id and counted_lesson.course_version_id = target_course_version_id) <> 19
     or (select count(*) from public.training_lessons counted_lesson where counted_lesson.organization_id = target_organization_id and counted_lesson.course_version_id = target_course_version_id and counted_lesson.lesson_type = 'reading' and counted_lesson.required) <> 9
     or (select count(*) from public.training_lessons counted_lesson where counted_lesson.organization_id = target_organization_id and counted_lesson.course_version_id = target_course_version_id and counted_lesson.lesson_type = 'key_points' and counted_lesson.required) <> 9
     or (select count(*) from public.training_lessons counted_lesson where counted_lesson.organization_id = target_organization_id and counted_lesson.course_version_id = target_course_version_id and counted_lesson.lesson_type = 'quiz' and counted_lesson.required) <> 1
     or exists (
       select 1
       from public.training_modules module
       where module.organization_id = target_organization_id
         and module.course_version_id = target_course_version_id
         and (
           (module.position between 1 and 9 and (
             module.stable_key = 'final-assessment'
             or (select count(*) from public.training_lessons lesson where lesson.module_id = module.id) <> 2
             or not exists (select 1 from public.training_lessons lesson where lesson.module_id = module.id and lesson.position = 1 and lesson.stable_key = 'overview' and lesson.lesson_type = 'reading' and lesson.required)
             or not exists (select 1 from public.training_lessons lesson where lesson.module_id = module.id and lesson.position = 2 and lesson.stable_key = 'practical-photo-guide' and lesson.lesson_type = 'key_points' and lesson.required)
           ))
           or (module.position = 10 and (
             module.stable_key <> 'final-assessment'
             or module.metadata ->> 'module_role' <> 'final_assessment'
             or (select count(*) from public.training_lessons lesson where lesson.module_id = module.id) <> 1
             or not exists (select 1 from public.training_lessons lesson where lesson.module_id = module.id and lesson.position = 1 and lesson.stable_key = 'final-quiz' and lesson.lesson_type = 'quiz' and lesson.required and lesson.pass_threshold_bps = 8000 and lesson.max_attempts is null and lesson.retry_delay_seconds = 0)
           ))
           or module.position not between 1 and 10
         )
     )
     or not private.training_image_slot_bindings_valid(target_organization_id, target_course_version_id)
     or (select count(*) from private.training_image_slot_requirements(target_organization_id, target_course_version_id)) <> 40
     or (select count(distinct asset_key) from private.training_image_slot_requirements(target_organization_id, target_course_version_id)) <> 40
  then
    raise exception 'Training draft preview structure changed' using errcode = '55000';
  end if;

  foreach locale in array expected_locales loop
    if exists (
      select 1
      from public.training_modules module
      where module.organization_id = target_organization_id
        and module.course_version_id = target_course_version_id
        and (
          nullif(btrim(module.title_i18n ->> locale), '') is null
          or nullif(btrim(module.description_i18n ->> locale), '') is null
        )
    ) or exists (
      select 1
      from public.training_lessons lesson
      where lesson.organization_id = target_organization_id
        and lesson.course_version_id = target_course_version_id
        and (
          nullif(btrim(lesson.title_i18n ->> locale), '') is null
          or nullif(btrim(lesson.objective_i18n ->> locale), '') is null
          or jsonb_typeof(lesson.content_i18n -> locale) <> 'object'
        )
    ) then
      raise exception 'Training draft preview locale contract changed' using errcode = '55000';
    end if;
  end loop;

  if exists (
    select 1
    from public.training_lessons lesson
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and lesson.lesson_type <> 'quiz'
      and exists (
        select 1 from unnest(expected_locales) locale_name
        where jsonb_typeof(lesson.content_i18n -> locale_name -> 'items') <> 'array'
           or jsonb_typeof(lesson.content_i18n -> locale_name -> 'image_slots') <> 'array'
      )
  ) or exists (
    select 1
    from public.training_lessons lesson
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and lesson.lesson_type = 'quiz'
      and (
        (select count(*) from jsonb_object_keys(lesson.metadata -> 'answer_key_by_question')) <> 27
        or jsonb_array_length(lesson.metadata -> 'question_provenance') <> 27
        or jsonb_array_length(lesson.metadata -> 'question_groups') <> 9
        or not (lesson.metadata -> 'answer_key_by_question' ?& array(
          select question ->> 'stable_key'
          from jsonb_array_elements(lesson.content_i18n -> 'en' -> 'questions') question
        ))
        or jsonb_path_exists(lesson.content_i18n, '$.**.correct_option_key')
        or exists (
          select 1 from unnest(expected_locales) locale_name
          where jsonb_typeof(lesson.content_i18n -> locale_name -> 'questions') <> 'array'
             or jsonb_array_length(lesson.content_i18n -> locale_name -> 'questions') <> 27
             or (select count(distinct question ->> 'stable_key') from jsonb_array_elements(lesson.content_i18n -> locale_name -> 'questions') question) <> 27
             or (select array_agg(question.value ->> 'stable_key' order by question.ordinality) from jsonb_array_elements(lesson.content_i18n -> locale_name -> 'questions') with ordinality question(value,ordinality))
                is distinct from
                (select array_agg(question.value ->> 'stable_key' order by question.ordinality) from jsonb_array_elements(lesson.content_i18n -> 'en' -> 'questions') with ordinality question(value,ordinality))
             or exists (select 1 from jsonb_array_elements(lesson.content_i18n -> locale_name -> 'questions') question where question ? 'correct_option_key')
        )
      )
  ) then
    raise exception 'Training draft preview content contract changed' using errcode = '55000';
  end if;

  return query
  select
    version.organization_id,
    course.id,
    course.course_key,
    version.id,
    version.version_number,
    version.status,
    version.revision,
    version.content_hash,
    version.default_locale,
    version.supported_locales,
    version.title_i18n,
    version.description_i18n,
    module.id,
    module.stable_key,
    module.position,
    module.title_i18n,
    module.description_i18n,
    lesson.id,
    lesson.stable_key,
    lesson.position,
    lesson.lesson_type,
    lesson.required,
    lesson.title_i18n,
    lesson.objective_i18n,
    case when lesson.lesson_type = 'quiz' then null else lesson.content_i18n end,
    case when lesson.lesson_type = 'quiz' then 27 else null end,
    lesson.pass_threshold_bps
  from public.training_courses course
  join public.training_course_versions version
    on version.course_id = course.id
   and version.organization_id = course.organization_id
  join public.training_modules module
    on module.course_version_id = version.id
   and module.organization_id = version.organization_id
  join public.training_lessons lesson
    on lesson.module_id = module.id
   and lesson.course_version_id = version.id
   and lesson.organization_id = version.organization_id
  where course.id = target_course_id
    and course.organization_id = target_organization_id
    and version.id = target_course_version_id
  order by module.position, lesson.position;
end;
$$;

revoke all on function public.get_internal_admin_training_draft_preview(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_internal_admin_training_draft_preview(uuid,uuid,uuid,uuid) to service_role;

comment on function public.get_internal_admin_training_draft_preview(uuid,uuid,uuid,uuid) is
  'Returns the exact read-only Baladiyah draft preview contract to the service-role backend; excludes answers, explanations, and storage coordinates.';
