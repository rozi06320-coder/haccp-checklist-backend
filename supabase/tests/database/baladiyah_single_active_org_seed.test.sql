begin;
select plan(26);

select is(
  (select count(*)::integer from public.organizations where active),
  1,
  'migration target has exactly one active organization'
);

savepoint zero_active_organizations;
update public.organizations set active = false where active;
select throws_ok(
  $$select * from private.seed_baladiyah_single_active_organization()$$,
  '55000',
  'Baladiyah draft seed requires exactly one active organization; found 0',
  'zero active organizations fail closed'
);
rollback to zero_active_organizations;

savepoint multiple_active_organizations;
insert into public.organizations(id, name, slug, active)
values ('4c100000-0000-4000-8000-000000000002', 'Second Active Organization', 'second-active-organization', true);
select throws_ok(
  $$select * from private.seed_baladiyah_single_active_organization()$$,
  '55000',
  'Baladiyah draft seed requires exactly one active organization; found 2',
  'multiple active organizations fail closed'
);
rollback to multiple_active_organizations;

select throws_ok(
  $$select * from private.seed_baladiyah_single_active_organization()$$,
  '55000',
  'Existing Baladiyah course/version conflicts with the approved draft manifest',
  'historical seed cannot overwrite the normalized successor draft'
);

select is(
  (select count(*)::integer from public.training_courses
   where course_key = 'baladiyah-food-safety-hygiene'),
  1,
  'exactly one Baladiyah course exists'
);

select is(
  (select count(*)::integer
   from public.training_course_versions version
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  1,
  'exactly one Baladiyah version exists'
);

select is(
  (select version.status
   from public.training_course_versions version
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  'draft',
  'version 1 remains draft'
);

select ok(
  (select version.published_at is null and version.published_by is null
          and version.retired_at is null and version.retired_by is null
   from public.training_course_versions version
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  'draft has no publication or retirement lifecycle timestamps'
);

select is(
  (select version.supported_locales
   from public.training_course_versions version
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  array['en','ar','id','hi','fil']::text[],
  'all five locales are preserved'
);

select is(
  (select count(*)::integer
   from public.training_modules module
   join public.training_course_versions version on version.id = module.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  10,
  'nine instructional modules and the final assessment module exist'
);

select is(
  (select count(*)::integer
   from public.training_lessons lesson
   join public.training_course_versions version on version.id = lesson.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  19,
  'eighteen instructional lessons and one final quiz exist'
);

select is(
  (select count(*)::integer
   from public.training_media_assets asset
   join public.training_course_versions version on version.id = asset.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  0,
  'no media rows are fabricated'
);

select is(
  (select array_agg(module.stable_key order by module.position)
   from public.training_modules module
   join public.training_course_versions version on version.id = module.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  array[
    'personal-hygiene-health',
    'cleaning-sanitation',
    'contamination-foodborne-illness-prevention',
    'safe-food-handling',
    'food-receiving',
    'storage-temperature-control',
    'cooking-holding-reheating',
    'waste-management',
    'pest-prevention-escalation',
    'final-assessment'
  ]::text[],
  'all expected module stable keys are present in order'
);

select is(
  (select count(*)::integer from (
    select module.id
    from public.training_modules module
    join public.training_course_versions version on version.id = module.course_version_id
    join public.training_courses course on course.id = version.course_id
    join public.training_lessons lesson on lesson.module_id = module.id
    where course.course_key = 'baladiyah-food-safety-hygiene'
    group by module.id
    having (
      module.stable_key <> 'final-assessment'
      and array_agg(lesson.stable_key order by lesson.position)
        <> array['overview','practical-photo-guide']::text[]
    ) or (
      module.stable_key = 'final-assessment'
      and array_agg(lesson.stable_key order by lesson.position)
        <> array['final-quiz']::text[]
    )
  ) invalid_module),
  0,
  'instructional and final-assessment modules have the expected lesson keys'
);

select is(
  (select sum(jsonb_array_length(module.metadata -> 'photo_requirements'))::integer
   from public.training_modules module
   join public.training_course_versions version on version.id = module.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  40,
  'all forty photo requirements are preserved'
);

select is(
  (select count(distinct photo ->> 'asset_key')::integer
   from public.training_modules module
   cross join lateral jsonb_array_elements(module.metadata -> 'photo_requirements') photo
   join public.training_course_versions version on version.id = module.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  40,
  'all forty required asset keys are unique'
);

select is(
  (select count(*)::integer
   from public.training_lessons lesson
   cross join lateral jsonb_path_query(lesson.content_i18n, '$.**.asset_key') reference(value)
   join public.training_course_versions version on version.id = lesson.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'
     and not exists (
       select 1
       from public.training_modules module
       cross join lateral jsonb_array_elements(module.metadata -> 'photo_requirements') photo
       where module.course_version_id = version.id
         and photo ->> 'asset_key' = trim(both '"' from reference.value::text)
     )),
  0,
  'every lesson image reference belongs to the forty-photo requirement manifest'
);

select is(
  (select count(*)::integer
   from public.training_lessons lesson
   join public.training_course_versions version on version.id = lesson.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'
     and lesson.lesson_type = 'video'),
  0,
  'no video lessons are seeded'
);

select ok(
  not has_function_privilege('service_role', 'private.seed_baladiyah_single_active_organization()', 'execute')
  and not has_function_privilege('authenticated', 'private.seed_baladiyah_single_active_organization()', 'execute')
  and not has_function_privilege('anon', 'private.seed_baladiyah_single_active_organization()', 'execute'),
  'seed helper remains owner-only'
);

savepoint wrong_organization_course;
insert into public.organizations(id, name, slug, active)
values ('4c100000-0000-4000-8000-000000000003', 'Inactive Conflict Organization', 'inactive-conflict-organization', false);
insert into public.training_courses(organization_id, course_key)
values ('4c100000-0000-4000-8000-000000000003', 'baladiyah-food-safety-hygiene');
select throws_ok(
  $$select * from private.seed_baladiyah_single_active_organization()$$,
  '55000',
  'Baladiyah course key already belongs to a different organization',
  'same course key in another organization fails closed'
);
rollback to wrong_organization_course;

savepoint conflicting_content;
update public.training_lessons
set content_i18n = jsonb_set(content_i18n, '{en,image_slots}', '[]'::jsonb)
where id = (
  select lesson.id
  from public.training_lessons lesson
  join public.training_course_versions version on version.id = lesson.course_version_id
  join public.training_courses course on course.id = version.course_id
  where course.course_key = 'baladiyah-food-safety-hygiene'
    and lesson.stable_key = 'overview'
  order by lesson.id
  limit 1
);
select throws_ok(
  $$select private.restructure_baladiyah_final_assessment()$$,
  '55000',
  'Baladiyah final assessment target has drifted',
  'final-assessment successor helper fails closed when learner bindings drift'
);
rollback to conflicting_content;

select is(
  (select count(*)::integer from public.training_courses
   where course_key = 'baladiyah-food-safety-hygiene'),
  1,
  'idempotency and conflict checks never duplicate the course'
);

select is(
  (select count(*)::integer
   from public.training_lessons lesson
   join public.training_course_versions version on version.id = lesson.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  19,
  'idempotency and conflict checks never duplicate lessons'
);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values (
  '00000000-0000-0000-0000-000000000000',
  '4c200000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'baladiyah-seed-admin@example.invalid',
  '{}',
  '{}',
  now(),
  now()
);
update public.profiles
set full_name = 'Baladiyah Seed Admin', must_change_password = false
where id = '4c200000-0000-4000-8000-000000000001';
insert into public.internal_admin_memberships(user_id, active)
values ('4c200000-0000-4000-8000-000000000001', true);

select throws_ok(
  format(
    'select * from public.validate_internal_admin_training_media_for_publish(%L,%L,%L,%L)',
    '4c200000-0000-4000-8000-000000000001',
    (select organization_id from public.training_courses where course_key = 'baladiyah-food-safety-hygiene'),
    (select id from public.training_courses where course_key = 'baladiyah-food-safety-hygiene'),
    (select version.id from public.training_course_versions version
     join public.training_courses course on course.id = version.course_id
     where course.course_key = 'baladiyah-food-safety-hygiene')
  ),
  '55000',
  'Training media publication validation failed',
  'publication validation remains fail-closed while referenced media is missing'
);

select is(
  (select revision
   from public.training_course_versions version
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'),
  2::bigint,
  'draft revision records the final-assessment successor'
);

select is(
  (select count(*)::integer
   from public.training_lessons lesson
   join public.training_course_versions version on version.id = lesson.course_version_id
   join public.training_courses course on course.id = version.course_id
   where course.course_key = 'baladiyah-food-safety-hygiene'
     and (
       not (lesson.title_i18n ?& array['en','ar','id','hi','fil'])
       or not (lesson.objective_i18n ?& array['en','ar','id','hi','fil'])
       or not (lesson.content_i18n ?& array['en','ar','id','hi','fil'])
     )),
  0,
  'all lesson localization objects retain the five locales'
);

select * from finish();
rollback;
