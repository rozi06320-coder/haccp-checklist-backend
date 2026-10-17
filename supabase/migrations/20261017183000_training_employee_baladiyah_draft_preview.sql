-- Explicit, read-only employee preview for the reviewed Baladiyah v1 draft.
-- This does not relax the published curriculum or enrollment boundaries.

create or replace function private.assert_training_employee_baladiyah_preview_contract(
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns void
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
  if not exists (
    select 1
    from public.training_courses course
    join public.training_course_versions version
      on version.organization_id = course.organization_id
     and version.course_id = course.id
    where course.organization_id = target_organization_id
      and course.id = target_course_id
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
    raise exception 'Training employee preview contract changed' using errcode = '55000';
  end if;

  if (select count(*) from public.training_modules module where module.organization_id = target_organization_id and module.course_version_id = target_course_version_id) <> 10
     or (select count(*) from public.training_lessons lesson where lesson.organization_id = target_organization_id and lesson.course_version_id = target_course_version_id) <> 19
     or (select count(*) from public.training_lessons lesson where lesson.organization_id = target_organization_id and lesson.course_version_id = target_course_version_id and lesson.lesson_type in ('reading','key_points') and lesson.required) <> 18
     or (select count(*) from public.training_lessons lesson where lesson.organization_id = target_organization_id and lesson.course_version_id = target_course_version_id and lesson.lesson_type = 'quiz' and lesson.required and lesson.pass_threshold_bps = 8000) <> 1
     or exists (
       select 1 from public.training_modules module
       where module.organization_id = target_organization_id
         and module.course_version_id = target_course_version_id
         and (
           (module.position between 1 and 9 and (
             (select count(*) from public.training_lessons lesson where lesson.module_id = module.id) <> 2
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
     or (select count(distinct requirement.asset_key) from private.training_image_slot_requirements(target_organization_id, target_course_version_id) requirement) <> 40
  then
    raise exception 'Training employee preview structure changed' using errcode = '55000';
  end if;

  foreach locale in array expected_locales loop
    if exists (
      select 1 from public.training_modules module
      where module.organization_id = target_organization_id
        and module.course_version_id = target_course_version_id
        and (nullif(btrim(module.title_i18n ->> locale), '') is null or nullif(btrim(module.description_i18n ->> locale), '') is null)
    ) or exists (
      select 1 from public.training_lessons lesson
      where lesson.organization_id = target_organization_id
        and lesson.course_version_id = target_course_version_id
        and (nullif(btrim(lesson.title_i18n ->> locale), '') is null or nullif(btrim(lesson.objective_i18n ->> locale), '') is null or jsonb_typeof(lesson.content_i18n -> locale) <> 'object')
    ) then
      raise exception 'Training employee preview locale contract changed' using errcode = '55000';
    end if;
  end loop;

  if exists (
    select 1 from public.training_lessons lesson
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and lesson.lesson_type <> 'quiz'
      and exists (
        select 1 from unnest(expected_locales) locale_name
        where jsonb_typeof(lesson.content_i18n -> locale_name -> 'items') <> 'array'
           or jsonb_typeof(lesson.content_i18n -> locale_name -> 'image_slots') <> 'array'
      )
  ) or exists (
    select 1 from public.training_lessons lesson
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and lesson.lesson_type = 'quiz'
      and (
        (select count(*) from jsonb_object_keys(lesson.metadata -> 'answer_key_by_question')) <> 27
        or jsonb_path_exists(lesson.content_i18n, '$.**.correct_option_key')
        or exists (
          select 1 from unnest(expected_locales) locale_name
          where jsonb_typeof(lesson.content_i18n -> locale_name -> 'questions') <> 'array'
             or jsonb_array_length(lesson.content_i18n -> locale_name -> 'questions') <> 27
             or exists (select 1 from jsonb_array_elements(lesson.content_i18n -> locale_name -> 'questions') question where question ? 'correct_option_key')
        )
      )
  ) then
    raise exception 'Training employee preview content contract changed' using errcode = '55000';
  end if;
end;
$$;

create or replace function public.get_training_employee_baladiyah_draft_preview(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid
)
returns table(
  course_id uuid,
  course_version_id uuid,
  version_number integer,
  version_status text,
  revision bigint,
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
  pass_threshold_bps integer,
  image_slots jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected_course_id uuid;
  selected_version_id uuid;
begin
  perform private.assert_training_progress_actor(target_organization_id, target_branch_id, target_employee_id);

  select course.id, version.id
    into selected_course_id, selected_version_id
  from public.training_courses course
  join public.training_course_versions version
    on version.organization_id = course.organization_id and version.course_id = course.id
  where course.organization_id = target_organization_id
    and course.course_key = 'baladiyah-food-safety-hygiene'
    and version.version_number = 1;

  if selected_course_id is null or selected_version_id is null then
    raise exception 'Training employee preview is unavailable' using errcode = 'P0002';
  end if;

  perform private.assert_training_employee_baladiyah_preview_contract(target_organization_id, selected_course_id, selected_version_id);

  return query
  select
    course.id, version.id, version.version_number, version.status, version.revision,
    version.default_locale, version.supported_locales, version.title_i18n, version.description_i18n,
    module.id, module.stable_key, module.position, module.title_i18n, module.description_i18n,
    lesson.id, lesson.stable_key, lesson.position, lesson.lesson_type, lesson.required,
    lesson.title_i18n, lesson.objective_i18n,
    case when lesson.lesson_type = 'quiz' then null else lesson.content_i18n end,
    case when lesson.lesson_type = 'quiz' then 27 else null end,
    lesson.pass_threshold_bps,
    case when lesson.lesson_type = 'quiz' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'asset_key', requirement.asset_key,
        'placement', requirement.placement,
        'slot_position', requirement.slot_position,
        'expected_alt_i18n', requirement.expected_alt_i18n,
        'media_id', case when media.status = 'ready' and media.approval_status = 'approved' then media.id else null end,
        'width', case when media.status = 'ready' and media.approval_status = 'approved' then media.width else null end,
        'height', case when media.status = 'ready' and media.approval_status = 'approved' then media.height else null end
      ) order by requirement.slot_position)
      from private.training_image_slot_requirements(target_organization_id, selected_version_id) requirement
      left join public.training_media_assets media
        on media.organization_id = target_organization_id
       and media.course_version_id = selected_version_id
       and media.asset_key = requirement.asset_key
       and media.status = 'ready'
      where requirement.lesson_id = lesson.id
    ), '[]'::jsonb) end
  from public.training_courses course
  join public.training_course_versions version on version.organization_id = course.organization_id and version.course_id = course.id
  join public.training_modules module on module.organization_id = version.organization_id and module.course_version_id = version.id
  join public.training_lessons lesson on lesson.organization_id = version.organization_id and lesson.course_version_id = version.id and lesson.module_id = module.id
  where course.id = selected_course_id and version.id = selected_version_id
  order by module.position, lesson.position;
end;
$$;

create or replace function public.authorize_training_employee_baladiyah_draft_preview_media(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_media_id uuid
)
returns table(storage_bucket text, storage_object_path text, mime_type text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected_course_id uuid;
  selected_version_id uuid;
begin
  perform private.assert_training_progress_actor(target_organization_id, target_branch_id, target_employee_id);
  select course.id, version.id into selected_course_id, selected_version_id
  from public.training_courses course
  join public.training_course_versions version on version.organization_id = course.organization_id and version.course_id = course.id
  where course.organization_id = target_organization_id
    and course.course_key = 'baladiyah-food-safety-hygiene'
    and version.version_number = 1;
  perform private.assert_training_employee_baladiyah_preview_contract(target_organization_id, selected_course_id, selected_version_id);

  return query
  select media.storage_bucket, media.storage_object_path, media.mime_type
  from public.training_media_assets media
  where media.id = target_media_id
    and media.organization_id = target_organization_id
    and media.course_version_id = selected_version_id
    and media.status = 'ready'
    and media.approval_status = 'approved'
    and media.mime_type = 'image/webp'
    and exists (
      select 1 from private.training_image_slot_requirements(target_organization_id, selected_version_id) requirement
      where requirement.asset_key = media.asset_key
    );
end;
$$;

revoke all on function private.assert_training_employee_baladiyah_preview_contract(uuid,uuid,uuid) from public, anon, authenticated, service_role;
revoke all on function public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid) from public, anon, authenticated, service_role;
revoke all on function public.authorize_training_employee_baladiyah_draft_preview_media(uuid,uuid,uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid) to service_role;
grant execute on function public.authorize_training_employee_baladiyah_draft_preview_media(uuid,uuid,uuid,uuid) to service_role;

comment on function public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid) is
  'Returns the exact read-only Baladiyah v1 draft preview to a revalidated legacy Training employee; excludes quiz bodies, answers, explanations, and Storage coordinates.';
