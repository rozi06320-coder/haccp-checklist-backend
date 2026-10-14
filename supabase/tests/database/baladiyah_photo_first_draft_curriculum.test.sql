begin;
select plan(33);

insert into public.organizations(id, name, slug, active)
values('2f100000-0000-4000-8000-000000000001', 'Baladiyah Draft Test', 'baladiyah-draft-test', true);

select lives_ok(
  $$select * from private.seed_baladiyah_food_safety_hygiene_draft('2f100000-0000-4000-8000-000000000001')$$,
  'owner can seed the organization-scoped draft curriculum'
);

select is(
  (select count(*)::integer from public.training_courses
   where organization_id='2f100000-0000-4000-8000-000000000001'
     and course_key='baladiyah-food-safety-hygiene'),
  1,
  'exactly one Baladiyah course is seeded'
);

select is(
  (select count(*)::integer
   from public.training_course_versions version
   join public.training_courses course on course.id=version.course_id
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'
     and version.version_number=1
     and version.status='draft'),
  1,
  'exactly one draft version 1 is seeded'
);

select ok(
  (select version.published_at is null and version.published_by is null
   from public.training_course_versions version
   join public.training_courses course on course.id=version.course_id
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'),
  'draft version is not published'
);

select is(
  (select version.supported_locales
   from public.training_course_versions version
   join public.training_courses course on course.id=version.course_id
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'),
  array['en','ar','id','hi','fil']::text[],
  'version declares the five required locales'
);

select is(
  (select count(*)::integer
   from public.training_modules module
   join public.training_courses course on course.id=(select version.course_id from public.training_course_versions version where version.id=module.course_version_id)
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'),
  9,
  'draft contains nine modules'
);

select is(
  (select count(*)::integer
   from public.training_lessons lesson
   join public.training_course_versions version on version.id=lesson.course_version_id
   join public.training_courses course on course.id=version.course_id
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'),
  27,
  'draft contains 27 lessons'
);

select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.lesson_type='reading'),9,'draft contains nine reading lessons');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.lesson_type='key_points'),9,'draft contains nine practical key-point lessons');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.lesson_type='quiz'),9,'draft contains nine quiz lessons');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.lesson_type='video'),0,'draft contains zero video lessons');

select is(
  (select array_agg(module.position order by module.position)
   from public.training_modules module
   join public.training_course_versions version on version.id=module.course_version_id
   join public.training_courses course on course.id=version.course_id
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'),
  array[1,2,3,4,5,6,7,8,9],
  'module positions are contiguous'
);

select is(
  (select count(*)::integer from (
    select lesson.module_id
    from public.training_lessons lesson
    join public.training_course_versions version on version.id=lesson.course_version_id
    join public.training_courses course on course.id=version.course_id
    where course.organization_id='2f100000-0000-4000-8000-000000000001'
      and course.course_key='baladiyah-food-safety-hygiene'
    group by lesson.module_id
    having array_agg(lesson.position order by lesson.position) <> array[1,2,3]
  ) invalid_modules),
  0,
  'every module has lesson positions 1 through 3'
);

select is(
  (select count(*)::integer
   from public.training_modules module
   join public.training_course_versions version on version.id=module.course_version_id
   join public.training_courses course on course.id=version.course_id
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'
     and not (module.title_i18n ?& array['en','ar','id','hi','fil'])
  ),0,'all module titles contain five locales');

select is(
  (select count(*)::integer
   from public.training_lessons lesson
   join public.training_course_versions version on version.id=lesson.course_version_id
   join public.training_courses course on course.id=version.course_id
   where course.organization_id='2f100000-0000-4000-8000-000000000001'
     and course.course_key='baladiyah-food-safety-hygiene'
     and (not (lesson.title_i18n ?& array['en','ar','id','hi','fil'])
       or not (lesson.objective_i18n ?& array['en','ar','id','hi','fil'])
       or not (lesson.content_i18n ?& array['en','ar','id','hi','fil']))
  ),0,'all lessons contain five locale objects');

select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and (lesson.content_i18n::text||lesson.metadata::text) ~* '(https?://|"poster"|"playback")'),0,'lessons contain no external media URL or fake video metadata');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.content_i18n::text ~* 'still applies when the restaurant is busy'),0,'duplicated generic quiz question is absent');
select is((select count(*)::integer from public.training_modules module join public.training_course_versions version on version.id=module.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and module.stable_key='restaurant-safety'),0,'Restaurant Safety is absent');
select is((select count(*)::integer from public.training_modules module join public.training_course_versions version on version.id=module.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and module.stable_key='contamination-foodborne-illness-prevention' and module.metadata->'source_module_ids'='["food-contamination","foodborne-illness"]'::jsonb),1,'merged module retains both source IDs');
select is((select count(*)::integer from public.training_modules module join public.training_course_versions version on version.id=module.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and module.position<=2 and module.metadata->>'default_provenance_classification'='baladiyah_explicit'),2,'first two modules are explicitly classified');
select is((select count(*)::integer from public.training_modules module join public.training_course_versions version on version.id=module.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and module.position>=3 and module.metadata->>'default_provenance_classification'='existing_training_supporting'),7,'remaining modules are classified as supporting');
select is((select count(*)::integer from public.training_modules module join public.training_course_versions version on version.id=module.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and jsonb_array_length(module.metadata->'provenance_facts')=0),0,'every module has fact provenance');
select is((select sum(jsonb_array_length(module.metadata->'photo_requirements'))::integer from public.training_modules module join public.training_course_versions version on version.id=module.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene'),34,'draft defines 34 photo requirements');
select is((select count(*)::integer from public.training_modules module cross join lateral jsonb_array_elements(module.metadata->'photo_requirements') photo join public.training_course_versions version on version.id=module.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and (photo->>'approval_status'<>'needed' or not (photo->'alt_i18n' ?& array['en','ar','id','hi','fil']) or photo::text ~* 'https?://')),0,'all photo requirements need approval, have five-language alt text, and have no URL');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.lesson_type='quiz' and jsonb_array_length(lesson.content_i18n->'en'->'questions') between 3 and 5),9,'every quiz has three to five questions');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.lesson_type='quiz' and lesson.pass_threshold_bps=8000),9,'all quiz thresholds are 80 percent');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene' and lesson.lesson_type<>'quiz' and lesson.minimum_engagement_seconds=0),18,'all reading and practical lessons have zero minimum engagement');
select ok(not has_function_privilege('service_role','private.seed_baladiyah_food_safety_hygiene_draft(uuid)','execute'),'service role cannot execute the seed helper');
select ok(not has_function_privilege('authenticated','private.seed_baladiyah_food_safety_hygiene_draft(uuid)','execute'),'authenticated cannot execute the seed helper');
select ok(not has_function_privilege('anon','private.seed_baladiyah_food_safety_hygiene_draft(uuid)','execute'),'anon cannot execute the seed helper');

select lives_ok(
  $$select * from private.seed_baladiyah_food_safety_hygiene_draft('2f100000-0000-4000-8000-000000000001')$$,
  'draft seed is idempotent for an unchanged manifest'
);

select is((select count(*)::integer from public.training_courses where organization_id='2f100000-0000-4000-8000-000000000001' and course_key='baladiyah-food-safety-hygiene'),1,'idempotent seed preserves one course');
select is((select count(*)::integer from public.training_lessons lesson join public.training_course_versions version on version.id=lesson.course_version_id join public.training_courses course on course.id=version.course_id where course.organization_id='2f100000-0000-4000-8000-000000000001' and course.course_key='baladiyah-food-safety-hygiene'),27,'idempotent seed preserves 27 lessons');

select * from finish();
rollback;
