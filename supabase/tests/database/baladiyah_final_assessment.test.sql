begin;
select plan(31);

create temporary table final_scope as
select course.organization_id, course.id as course_id, version.id as version_id
from public.training_courses course
join public.training_course_versions version
  on version.course_id = course.id
 and version.organization_id = course.organization_id
where course.course_key = 'baladiyah-food-safety-hygiene'
  and version.version_number = 1;

select is((select count(*)::integer from final_scope), 1, 'exactly one Baladiyah Version 1 is in scope');
select ok((select status = 'draft' and published_at is null and published_by is null and retired_at is null and retired_by is null
           from public.training_course_versions where id = (select version_id from final_scope)),
          'Version 1 remains an unpublished and unretired draft');
select is((select revision from public.training_course_versions where id = (select version_id from final_scope)), 2::bigint,
          'Version 1 revision is two');
select is((select content_hash from public.training_course_versions where id = (select version_id from final_scope)),
          '9bfb8467b8a43dc61db87833d0532403d14ecc6d3f63cb57e37582ea32d634d3',
          'Version 1 has the deterministic final-assessment hash');

select is((select count(*)::integer from public.training_modules where course_version_id = (select version_id from final_scope)), 10,
          'ten total modules exist');
select is((select count(*)::integer from public.training_modules where course_version_id = (select version_id from final_scope) and position <= 9), 9,
          'nine instructional modules remain');
select is((select count(*)::integer from public.training_lessons where course_version_id = (select version_id from final_scope)), 19,
          'nineteen total lessons exist');
select is((select count(*)::integer from public.training_lessons where course_version_id = (select version_id from final_scope) and lesson_type <> 'quiz'), 18,
          'eighteen instructional lessons remain');
select is((select count(*)::integer from public.training_lessons where course_version_id = (select version_id from final_scope) and lesson_type = 'reading'), 9,
          'nine overview lessons remain');
select is((select count(*)::integer from public.training_lessons where course_version_id = (select version_id from final_scope) and lesson_type = 'key_points'), 9,
          'nine practical lessons remain');
select is((select count(*)::integer from public.training_lessons where course_version_id = (select version_id from final_scope) and lesson_type = 'quiz'), 1,
          'exactly one quiz lesson exists');

select ok((select position = 10 and category_key is null and metadata = '{"module_role":"final_assessment"}'::jsonb
           from public.training_modules
           where course_version_id = (select version_id from final_scope) and stable_key = 'final-assessment'),
          'final-assessment module has the exact role and position');
select ok((select lesson.position = 1 and lesson.lesson_type = 'quiz' and lesson.required
                    and lesson.pass_threshold_bps = 8000 and lesson.max_attempts is null
                    and lesson.retry_delay_seconds = 0 and lesson.metadata ->> 'assessment_scope' = 'course'
           from public.training_lessons lesson
           join public.training_modules module on module.id = lesson.module_id
           where lesson.course_version_id = (select version_id from final_scope)
             and module.stable_key = 'final-assessment' and lesson.stable_key = 'final-quiz'),
          'final quiz has the exact assessment configuration');

select is((select jsonb_array_length(content_i18n -> 'en' -> 'questions')
           from public.training_lessons where course_version_id = (select version_id from final_scope) and stable_key = 'final-quiz'), 27,
          'final quiz contains twenty-seven English questions');
select is((select count(distinct question.value ->> 'stable_key')::integer
           from public.training_lessons lesson
           cross join lateral jsonb_array_elements(lesson.content_i18n -> 'en' -> 'questions') question(value)
           where lesson.course_version_id = (select version_id from final_scope) and lesson.stable_key = 'final-quiz'), 27,
          'all twenty-seven question keys are unique');
select is((select count(*)::integer
           from public.training_lessons lesson
           cross join unnest(array['en','ar','id','hi','fil']) locale
           where lesson.course_version_id = (select version_id from final_scope) and lesson.stable_key = 'final-quiz'
             and jsonb_array_length(lesson.content_i18n -> locale -> 'questions') = 27), 5,
          'all five locales contain twenty-seven questions');
select is((select count(*)::integer
           from public.training_lessons lesson
           cross join lateral jsonb_object_keys(lesson.metadata -> 'answer_key_by_question') answer(question_key)
           where lesson.course_version_id = (select version_id from final_scope) and lesson.stable_key = 'final-quiz'), 27,
          'all twenty-seven answer keys are retained in sensitive metadata');
select is((select jsonb_array_length(metadata -> 'question_provenance')
           from public.training_lessons where course_version_id = (select version_id from final_scope) and stable_key = 'final-quiz'), 27,
          'all twenty-seven provenance records are retained');
select is((select jsonb_array_length(metadata -> 'question_groups')
           from public.training_lessons where course_version_id = (select version_id from final_scope) and stable_key = 'final-quiz'), 9,
          'nine source-module question groups are retained');
select is((select count(*)::integer
           from public.training_lessons lesson
           cross join lateral jsonb_array_elements(lesson.metadata -> 'question_groups') grouping(value)
           where lesson.course_version_id = (select version_id from final_scope) and lesson.stable_key = 'final-quiz'
             and jsonb_array_length(grouping.value -> 'question_keys') = 3), 9,
          'every source module contributes exactly three questions');
select is((select count(*)::integer from public.training_lessons lesson
           where lesson.course_version_id = (select version_id from final_scope)
             and jsonb_path_exists(lesson.content_i18n, '$.**.correct_option_key')), 0,
          'correct option keys do not appear in learner-facing content');

select ok(not (21 * 10000 >= 27 * 8000), 'twenty-one of twenty-seven fails the integer threshold');
select ok(22 * 10000 >= 27 * 8000, 'twenty-two of twenty-seven passes the integer threshold');
select is((select count(*)::integer from private.training_image_slot_requirements((select organization_id from final_scope),(select version_id from final_scope))), 40,
          'all forty required image slots remain');
select is((select count(distinct module_id)::integer from private.training_image_slot_requirements((select organization_id from final_scope),(select version_id from final_scope))), 9,
          'image slots remain grouped under the nine instructional modules');
select ok(private.training_image_slot_bindings_valid((select organization_id from final_scope),(select version_id from final_scope)),
          'all image-slot learner bindings remain valid');
select is((select count(*)::integer from private.training_image_slot_requirements((select organization_id from final_scope),(select version_id from final_scope)) where module_key = 'final-assessment'), 0,
          'the final assessment introduces no image slot');

create temporary table media_before_rerun as
select coalesce(jsonb_agg(to_jsonb(asset) order by asset.id), '[]'::jsonb) as snapshot
from public.training_media_assets asset
where asset.course_version_id = (select version_id from final_scope);
select lives_ok($$select private.restructure_baladiyah_final_assessment()$$,
                'an exact target rerun is idempotent');
select is((select coalesce(jsonb_agg(to_jsonb(asset) order by asset.id), '[]'::jsonb)
           from public.training_media_assets asset where asset.course_version_id = (select version_id from final_scope)),
          (select snapshot from media_before_rerun),
          'an idempotent rerun leaves media rows untouched');

savepoint unexpected_target_drift;
update public.training_lessons
set content_i18n = jsonb_set(content_i18n, '{en,questions,0,prompt}', '"drift"'::jsonb)
where course_version_id = (select version_id from final_scope) and stable_key = 'final-quiz';
select throws_ok($$select private.restructure_baladiyah_final_assessment()$$, '55000',
                 'Baladiyah final assessment target has drifted',
                 'unexpected target drift fails closed');
rollback to unexpected_target_drift;

select ok(not has_function_privilege('service_role','private.restructure_baladiyah_final_assessment()','execute')
          and not has_function_privilege('authenticated','private.restructure_baladiyah_final_assessment()','execute')
          and not has_function_privilege('anon','private.restructure_baladiyah_final_assessment()','execute'),
          'migration helper remains owner-only');

select * from finish();
rollback;
