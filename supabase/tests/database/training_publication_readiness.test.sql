begin;
select plan(13);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
 ('00000000-0000-0000-0000-000000000000','8e100000-0000-4000-8000-000000000001','authenticated','authenticated','readiness-admin@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','8e100000-0000-4000-8000-000000000002','authenticated','authenticated','readiness-user@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Readiness Admin',must_change_password=false where id='8e100000-0000-4000-8000-000000000001';
update public.profiles set full_name='Readiness User',must_change_password=false where id='8e100000-0000-4000-8000-000000000002';
insert into public.internal_admin_memberships(user_id,active) values('8e100000-0000-4000-8000-000000000001',true);
create temporary table readiness_scope as select course.organization_id,course.id course_id,version.id version_id from public.training_courses course join public.training_course_versions version on version.course_id=course.id and version.organization_id=course.organization_id where course.course_key='baladiyah-food-safety-hygiene' and version.version_number=1;

select ok(has_function_privilege('service_role','public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid)','execute'),'service role can execute readiness');
select ok(not has_function_privilege('authenticated','public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid)','execute') and not has_function_privilege('anon','public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid)','execute'),'browser roles cannot execute readiness');
select throws_ok(format($call$select * from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000002',%L,%L,%L)$call$,(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope)),'42501','Training media access denied','non-admin denied');
select throws_ok(format($call$select * from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001','8e200000-0000-4000-8000-000000000099',%L,%L)$call$,(select course_id from readiness_scope),(select version_id from readiness_scope)),'P0002','Training course version not found','cross-organization denied');
select is((select instructional_lesson_count from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001',(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope))),18,'eighteen instructional lessons validated');
select is((select quiz_question_count from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001',(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope))),27,'twenty-seven quiz questions validated');
select is((select required_image_count from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001',(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope))),40,'forty slots validated');
select is((select missing_image_count from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001',(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope))),40,'missing images are counted');
select is((select approved_image_count from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001',(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope))),0,'submitted or missing images are not approved');
select ok((select locale_structure_complete and curriculum_valid from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001',(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope))),'curriculum and locale structure are valid');
select ok((select translation_review_status->>'en'='pending' and translation_review_status->>'ar'='pending' and review_workflow_available from public.get_internal_admin_training_publication_readiness('8e100000-0000-4000-8000-000000000001',(select organization_id from readiness_scope),(select course_id from readiness_scope),(select version_id from readiness_scope))),'real review workflow reports pending without fabricating approval');
select is((select status from public.training_course_versions where id=(select version_id from readiness_scope)),'draft','inspection leaves version draft');
select is((select count(*)::integer from public.training_media_assets where course_version_id=(select version_id from readiness_scope)),0,'inspection creates no media rows');
select * from finish();
rollback;
