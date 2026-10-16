begin;
select plan(29);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values ('00000000-0000-0000-0000-000000000000','5d100000-0000-4000-8000-000000000001','authenticated','authenticated','training-slots-admin@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Training Slots Admin',must_change_password=false where id='5d100000-0000-4000-8000-000000000001';
insert into public.internal_admin_memberships(user_id,active) values('5d100000-0000-4000-8000-000000000001',true);

create temporary table slot_scope as
select course.organization_id,course.id as course_id,version.id as version_id
from public.training_courses course
join public.training_course_versions version on version.course_id=course.id and version.organization_id=course.organization_id
where course.course_key='baladiyah-food-safety-hygiene' and version.version_number=1;

select is((select count(*)::integer from private.training_image_slot_requirements((select organization_id from slot_scope),(select version_id from slot_scope))),40,'exactly forty slots resolve');
select is((select count(distinct asset_key)::integer from private.training_image_slot_requirements((select organization_id from slot_scope),(select version_id from slot_scope))),40,'all slot asset keys are unique');
select is((select count(distinct module_id)::integer from private.training_image_slot_requirements((select organization_id from slot_scope),(select version_id from slot_scope))),9,'slots resolve to nine modules');
select is((select count(*)::integer from private.training_image_slot_requirements((select organization_id from slot_scope),(select version_id from slot_scope)) where lesson_id is null),0,'every slot resolves to one lesson');
select ok(private.training_image_slot_bindings_valid((select organization_id from slot_scope),(select version_id from slot_scope)),'all requirements and learner bindings are aligned');
select is((select count(*)::integer from public.training_lessons lesson cross join unnest(array['en','ar','id','hi','fil']) locale cross join lateral jsonb_array_elements(coalesce(lesson.content_i18n->locale->'image_slots','[]'::jsonb)) slot(value) where lesson.course_version_id=(select version_id from slot_scope)),200,'forty bindings are present in each of five locales');
select is((select count(*)::integer from public.training_lessons lesson cross join lateral jsonb_path_query(lesson.content_i18n,'$.**.image') legacy(value) where lesson.course_version_id=(select version_id from slot_scope)),0,'legacy inline image objects are removed');
select is((select count(*)::integer from public.list_internal_admin_training_image_slots('5d100000-0000-4000-8000-000000000001',(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope))),40,'slot RPC returns exactly forty rows');
select is((select count(*)::integer from public.list_internal_admin_training_image_slots('5d100000-0000-4000-8000-000000000001',(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope)) where media_id is null and media_status is null and approval_status is null),40,'all slots initially report Missing');
select ok(has_function_privilege('service_role','public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid)','execute') and not has_function_privilege('authenticated','public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid)','execute'),'slot RPC is service-role-only');

select throws_ok(format($call$select * from public.register_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001',%L,%L,%L,'5d500000-0000-4000-8000-000000000099','arbitrary-image-key',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 %L,100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,
 (select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope),
 'organizations/'||(select organization_id from slot_scope)||'/courses/'||(select course_id from slot_scope)||'/versions/'||(select version_id from slot_scope)||'/assets/5d500000-0000-4000-8000-000000000099/5d600000-0000-4000-8000-000000000099.webp'),
 '22023','Unknown Training image slot','arbitrary registration keys are rejected');

insert into public.organizations(id,name,slug,active) values('5d200000-0000-4000-8000-000000000099','Slots Other Org','slots-other-org',false);
select throws_ok(format($call$select * from public.register_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001','5d200000-0000-4000-8000-000000000099',%L,%L,'5d500000-0000-4000-8000-000000000098','personal-hygiene-handwashing-wet',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 'organizations/5d200000-0000-4000-8000-000000000099/courses/5d300000-0000-4000-8000-000000000099/versions/5d400000-0000-4000-8000-000000000099/assets/5d500000-0000-4000-8000-000000000098/5d600000-0000-4000-8000-000000000098.webp',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,
 (select course_id from slot_scope),(select version_id from slot_scope)),
 'P0002','Training course version not found','cross-organization scope is rejected');

insert into public.training_courses(id,organization_id,course_key)
values('5d300000-0000-4000-8000-000000000099',(select organization_id from slot_scope),'other-training-course');
insert into public.training_course_versions(id,organization_id,course_id,version_number,default_locale,supported_locales,title_i18n)
values('5d400000-0000-4000-8000-000000000099',(select organization_id from slot_scope),'5d300000-0000-4000-8000-000000000099',1,'en',array['en','ar','id','hi','fil'],'{"en":"Other"}');
select throws_ok(format($call$select * from public.register_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001',%L,'5d300000-0000-4000-8000-000000000099','5d400000-0000-4000-8000-000000000099','5d500000-0000-4000-8000-000000000097','personal-hygiene-handwashing-wet',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 'organizations/00000000-0000-4000-8000-000000000000/courses/5d300000-0000-4000-8000-000000000099/versions/5d400000-0000-4000-8000-000000000099/assets/5d500000-0000-4000-8000-000000000097/5d600000-0000-4000-8000-000000000097.webp',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,(select organization_id from slot_scope)),
 '22023','Unknown Training image slot','key from another course is rejected');
select throws_ok(format($call$select * from public.register_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001',%L,%L,'5d400000-0000-4000-8000-000000000099','5d500000-0000-4000-8000-000000000096','personal-hygiene-handwashing-wet',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 'invalid',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,(select organization_id from slot_scope),(select course_id from slot_scope)),
 'P0002','Training course version not found','key from another version is rejected');
insert into public.training_courses(id,organization_id,course_key)
values('5d300000-0000-4000-8000-000000000098',(select organization_id from slot_scope),'retired-training-course');
insert into public.training_course_versions(id,organization_id,course_id,version_number,status,default_locale,supported_locales,title_i18n,published_at,published_by,retired_at,retired_by)
values('5d400000-0000-4000-8000-000000000098',(select organization_id from slot_scope),'5d300000-0000-4000-8000-000000000098',1,'retired','en',array['en'],'{"en":"Retired"}',statement_timestamp(),'5d100000-0000-4000-8000-000000000001',statement_timestamp(),'5d100000-0000-4000-8000-000000000001');
select throws_ok(format($call$select * from public.register_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001',%L,'5d300000-0000-4000-8000-000000000098','5d400000-0000-4000-8000-000000000098','5d500000-0000-4000-8000-000000000095','personal-hygiene-handwashing-wet',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 'invalid',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,(select organization_id from slot_scope)),
 '55000','Training course version is immutable','retired upload is rejected');

select lives_ok(format($call$select * from public.register_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001',%L,%L,%L,'5d500000-0000-4000-8000-000000000001','personal-hygiene-handwashing-wet',
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',
 %L,100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,
 (select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope),
 'organizations/'||(select organization_id from slot_scope)||'/courses/'||(select course_id from slot_scope)||'/versions/'||(select version_id from slot_scope)||'/assets/5d500000-0000-4000-8000-000000000001/5d600000-0000-4000-8000-000000000001.webp'),
 'server-issued slot key is accepted');
select is((select approval_status from public.training_media_assets where id='5d500000-0000-4000-8000-000000000001'),'submitted','new slot media is Submitted');
select throws_like(format($call$select * from public.register_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001',%L,%L,%L,'5d500000-0000-4000-8000-000000000002','personal-hygiene-handwashing-wet',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 %L,100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,
 (select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope),
 'organizations/'||(select organization_id from slot_scope)||'/courses/'||(select course_id from slot_scope)||'/versions/'||(select version_id from slot_scope)||'/assets/5d500000-0000-4000-8000-000000000002/5d600000-0000-4000-8000-000000000002.webp'),
 '%duplicate key value violates unique constraint "training_media_assets_version_asset_key_key"%','duplicate slot media is prevented');
select is((select count(*)::integer from public.list_internal_admin_training_image_slots('5d100000-0000-4000-8000-000000000001',(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope)) where approval_status='submitted'),1,'slot read model reports Submitted');
update public.training_media_assets set approval_status='approved',reviewed_at=statement_timestamp(),reviewed_by='5d100000-0000-4000-8000-000000000001' where id='5d500000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.list_internal_admin_training_image_slots('5d100000-0000-4000-8000-000000000001',(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope)) where approval_status='approved'),1,'slot read model reports Approved');
update public.training_media_assets set approval_status='rejected',reviewed_at=statement_timestamp(),reviewed_by='5d100000-0000-4000-8000-000000000001',rejection_reason='Operational subject is unclear.' where id='5d500000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.list_internal_admin_training_image_slots('5d100000-0000-4000-8000-000000000001',(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope)) where approval_status='rejected'),1,'slot read model reports Rejected');

select lives_ok(format($call$select * from public.replace_internal_admin_training_media(
 '5d100000-0000-4000-8000-000000000001',%L,%L,%L,'5d500000-0000-4000-8000-000000000001',%L,
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',
 101,1280,720,repeat('c',64),'image/webp',201,repeat('d',64))$call$,
 (select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope),
 'organizations/'||(select organization_id from slot_scope)||'/courses/'||(select course_id from slot_scope)||'/versions/'||(select version_id from slot_scope)||'/assets/5d500000-0000-4000-8000-000000000001/5d600000-0000-4000-8000-000000000002.webp'),
 'replacement succeeds on the occupied slot');
select ok((select asset_key='personal-hygiene-handwashing-wet' and approval_status='submitted' and reviewed_at is null and reviewed_by is null and rejection_reason is null from public.training_media_assets where id='5d500000-0000-4000-8000-000000000001'),'replacement retains the key and resets review state to Submitted');
select throws_ok(format($call$select * from public.retire_internal_admin_training_media('5d100000-0000-4000-8000-000000000001',%L,%L,%L,'5d500000-0000-4000-8000-000000000001')$call$,(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope)),'55000','Required Training image slots must be replaced, not removed','required slot media cannot be removed');
select throws_ok(format($call$select * from public.validate_internal_admin_training_media_for_publish('5d100000-0000-4000-8000-000000000001',%L,%L,%L)$call$,(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope)),'55000','Training media publication validation failed','missing and submitted slots block publication');

insert into public.training_media_assets(
 id,organization_id,course_version_id,asset_key,media_type,title_i18n,alt_i18n,storage_object_path,mime_type,
 byte_size,width,height,sha256,source_mime_type,source_byte_size,source_sha256,approval_status,status,reviewed_at,reviewed_by
)
select md5('media-'||slot.asset_key)::uuid,scope.organization_id,scope.version_id,slot.asset_key,'image',slot.expected_alt_i18n,slot.expected_alt_i18n,
 'organizations/'||scope.organization_id||'/courses/'||scope.course_id||'/versions/'||scope.version_id||'/assets/'||md5('media-'||slot.asset_key)::uuid||'/'||md5('object-'||slot.asset_key)::uuid||'.webp',
 'image/webp',100,1280,720,encode(digest(slot.asset_key,'sha256'),'hex'),'image/webp',100,encode(digest('source-'||slot.asset_key,'sha256'),'hex'),'approved','ready',statement_timestamp(),'5d100000-0000-4000-8000-000000000001'
from slot_scope scope
cross join private.training_image_slot_requirements(scope.organization_id,scope.version_id) slot
where slot.asset_key<>'personal-hygiene-handwashing-wet';
update public.training_media_assets set approval_status='approved',reviewed_at=statement_timestamp(),reviewed_by='5d100000-0000-4000-8000-000000000001',rejection_reason=null where id='5d500000-0000-4000-8000-000000000001';

select is((select referenced_asset_count from public.validate_internal_admin_training_media_for_publish('5d100000-0000-4000-8000-000000000001',(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope))),40,'forty approved assets satisfy publication media validation');
select lives_ok(format($call$update public.training_course_versions set status='published',published_at=statement_timestamp(),published_by='5d100000-0000-4000-8000-000000000001' where id=%L$call$,(select version_id from slot_scope)),'fully approved draft can publish');
select throws_ok(format($call$update public.training_lessons set content_i18n=content_i18n||'{"changed":true}'::jsonb where course_version_id=%L and stable_key='overview'$call$,(select version_id from slot_scope)),'55000','Published or retired Training content is immutable','published learner bindings are immutable');
select throws_ok(format($call$select * from public.register_internal_admin_training_media('5d100000-0000-4000-8000-000000000001',%L,%L,%L,gen_random_uuid(),'personal-hygiene-protected-cut','{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}','invalid',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$call$,(select organization_id from slot_scope),(select course_id from slot_scope),(select version_id from slot_scope)),'55000','Training course version is immutable','published upload is rejected');

select * from finish();
rollback;
