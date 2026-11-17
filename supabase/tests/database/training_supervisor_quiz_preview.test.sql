begin;
select plan(17);

select has_function('public','get_training_supervisor_baladiyah_quiz_preview',array['uuid','uuid','text'],'read-only preview RPC exists');
select ok((select prosecdef from pg_catalog.pg_proc where oid='public.get_training_supervisor_baladiyah_quiz_preview(uuid,uuid,text)'::regprocedure),'preview RPC is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=""'] from pg_catalog.pg_proc where oid='public.get_training_supervisor_baladiyah_quiz_preview(uuid,uuid,text)'::regprocedure),'preview RPC has empty search_path');
select ok(has_function_privilege('service_role','public.get_training_supervisor_baladiyah_quiz_preview(uuid,uuid,text)','execute'),'service_role can execute preview RPC');
select ok(not has_function_privilege('anon','public.get_training_supervisor_baladiyah_quiz_preview(uuid,uuid,text)','execute'),'anon cannot execute preview RPC');
select ok(not has_function_privilege('authenticated','public.get_training_supervisor_baladiyah_quiz_preview(uuid,uuid,text)','execute'),'authenticated cannot execute preview RPC');
create temporary table quiz_attempt_snapshot as select count(*)::integer as total from public.training_quiz_attempts;

-- Use a synthetic account in the single disposable Baladiyah organization. The
-- transaction rolls back all fixtures and never changes published content.
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','9f100000-0000-4000-8000-000000000001','authenticated','authenticated','quiz-preview@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Quiz Preview Supervisor', disabled_at=null, must_change_password=false
where id='9f100000-0000-4000-8000-000000000001';
insert into public.training_memberships(organization_id,user_id,account_name,active,created_by,updated_by,training_role,credential_version)
select id,'9f100000-0000-4000-8000-000000000001','Quiz Preview Supervisor',true,'9f100000-0000-4000-8000-000000000001','9f100000-0000-4000-8000-000000000001','training_supervisor','9f200000-0000-4000-8000-000000000001'
from public.organizations where active order by id limit 1;
-- The disposable Baladiyah seed is draft-only. Promote this synthetic fixture
-- inside the test transaction. The production publication gate is bypassed
-- only for this synthetic row and is restored before assertions continue.
alter table public.training_course_versions disable trigger training_course_versions_01_manifest_binding_guard;
alter table public.training_course_versions disable trigger training_course_versions_02_manifest_publication_gate;
alter table public.training_course_versions disable trigger training_course_versions_05_media_publication;
update public.training_course_versions version
set status='published', published_at=now(), published_by='9f100000-0000-4000-8000-000000000001',
    publication_fingerprint=coalesce(version.content_hash, repeat('a',64))
from public.training_courses course
where version.course_id=course.id and course.course_key='baladiyah-food-safety-hygiene' and version.version_number=1;
alter table public.training_course_versions enable trigger training_course_versions_01_manifest_binding_guard;
alter table public.training_course_versions enable trigger training_course_versions_02_manifest_publication_gate;
alter table public.training_course_versions enable trigger training_course_versions_05_media_publication;
select ok(
  (select count(*) > 0 from public.training_course_versions version join public.training_courses course on course.id=version.course_id where version.status='published' and course.course_key='baladiyah-food-safety-hygiene')
  and (select count(*)=3 from pg_trigger t where t.tgname in ('training_course_versions_01_manifest_binding_guard','training_course_versions_02_manifest_publication_gate','training_course_versions_05_media_publication') and t.tgenabled='O'),
  'published Baladiyah fixture exists and publication triggers are restored'
);

select is((select count(*)::integer from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','en')),27,'English preview returns exactly 27 questions');
select is((select count(*)::integer from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','ar')),27,'Arabic preview returns exactly 27 questions');
select is((select count(*)::integer from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','id')),27,'Indonesian preview returns exactly 27 questions');
select is((select count(*)::integer from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','hi')),27,'Hindi preview returns exactly 27 questions');
select is((select count(*)::integer from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','fil')),27,'Filipino preview returns exactly 27 questions');
select is((select count(*)::integer from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','en') where options::text ilike '%correct_option_key%'),0,'options contain no correctness metadata');
select is((select count(*)::integer from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','en') where options::text ilike '%answer_key%' or options::text ilike '%explanation%'),0,'preview contains no answer keys or grading metadata');
select throws_ok($$select * from public.get_training_supervisor_baladiyah_quiz_preview('9f300000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','en')$$,'42501','training supervisor access denied','unknown actor is rejected');
select throws_ok($$select * from public.get_training_supervisor_baladiyah_quiz_preview('9f100000-0000-4000-8000-000000000001','9f200000-0000-4000-8000-000000000001','xx')$$,'22023','invalid locale: must be one of en, ar, id, hi, fil','unsupported locale is rejected');
select is((select count(*)::integer from public.training_quiz_attempts), (select total from quiz_attempt_snapshot), 'learner assessment records remain unchanged');

select * from finish();
rollback;
