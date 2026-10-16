begin;
select plan(12);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values ('00000000-0000-0000-0000-000000000000','6e100000-0000-4000-8000-000000000001','authenticated','authenticated','training-preview-admin@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Training Preview Admin',must_change_password=false where id='6e100000-0000-4000-8000-000000000001';
insert into public.internal_admin_memberships(user_id,active) values('6e100000-0000-4000-8000-000000000001',true);

create temporary table preview_scope as
select course.organization_id,course.id as course_id,version.id as version_id
from public.training_courses course
join public.training_course_versions version on version.course_id=course.id and version.organization_id=course.organization_id
where course.course_key='baladiyah-food-safety-hygiene' and version.version_number=1;

select is((select count(*)::integer from public.get_internal_admin_training_draft_preview('6e100000-0000-4000-8000-000000000001',(select organization_id from preview_scope),(select course_id from preview_scope),(select version_id from preview_scope))),19,'preview returns nineteen ordered lesson rows');
select is((select count(*)::integer from public.get_internal_admin_training_draft_preview('6e100000-0000-4000-8000-000000000001',(select organization_id from preview_scope),(select course_id from preview_scope),(select version_id from preview_scope)) where module_position<=9),18,'preview returns eighteen instructional lessons');
select is((select count(distinct module_id)::integer from public.get_internal_admin_training_draft_preview('6e100000-0000-4000-8000-000000000001',(select organization_id from preview_scope),(select course_id from preview_scope),(select version_id from preview_scope)) where module_position<=9),9,'preview returns nine instructional chapters');
select is((select count(*)::integer from public.get_internal_admin_training_draft_preview('6e100000-0000-4000-8000-000000000001',(select organization_id from preview_scope),(select course_id from preview_scope),(select version_id from preview_scope)) where lesson_type='quiz'),1,'preview returns one final assessment');
select is((select question_count from public.get_internal_admin_training_draft_preview('6e100000-0000-4000-8000-000000000001',(select organization_id from preview_scope),(select course_id from preview_scope),(select version_id from preview_scope)) where lesson_type='quiz'),27,'assessment summary reports twenty-seven questions');
select is((select pass_threshold_bps from public.get_internal_admin_training_draft_preview('6e100000-0000-4000-8000-000000000001',(select organization_id from preview_scope),(select course_id from preview_scope),(select version_id from preview_scope)) where lesson_type='quiz'),8000,'assessment summary reports the 80 percent threshold');
select ok((select lesson_content_i18n is null from public.get_internal_admin_training_draft_preview('6e100000-0000-4000-8000-000000000001',(select organization_id from preview_scope),(select course_id from preview_scope),(select version_id from preview_scope)) where lesson_type='quiz'),'quiz questions, answers, and explanations are not returned');
select is((select count(*)::integer from private.training_image_slot_requirements((select organization_id from preview_scope),(select version_id from preview_scope))),40,'forty image slots remain intact');
select ok(has_function_privilege('service_role','public.get_internal_admin_training_draft_preview(uuid,uuid,uuid,uuid)','execute'),'service role can execute preview RPC');
select ok(not has_function_privilege('authenticated','public.get_internal_admin_training_draft_preview(uuid,uuid,uuid,uuid)','execute'),'authenticated cannot execute preview RPC directly');
select ok(not has_function_privilege('anon','public.get_internal_admin_training_draft_preview(uuid,uuid,uuid,uuid)','execute'),'anon cannot execute preview RPC directly');
select ok(position('storage_object_path' in pg_get_functiondef('public.get_internal_admin_training_draft_preview(uuid,uuid,uuid,uuid)'::regprocedure))=0,'preview RPC does not expose private Storage coordinates');

select * from finish();
rollback;
