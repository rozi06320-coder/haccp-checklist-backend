begin;
select plan(19);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',email,'{}','{}',now(),now()
from (values
 ('3b100000-0000-4000-8000-000000000001'::uuid,'training-media-admin@example.invalid'),
 ('3b100000-0000-4000-8000-000000000002'::uuid,'training-media-user@example.invalid')
) users(id,email);
update public.profiles set full_name='Training Media Test',must_change_password=false where id::text like '3b100000-%';
insert into public.internal_admin_memberships(user_id,active) values('3b100000-0000-4000-8000-000000000001',true);
insert into public.organizations(id,name,slug) values
 ('3b200000-0000-4000-8000-000000000001','Training Media Org A','training-media-org-a'),
 ('3b200000-0000-4000-8000-000000000002','Training Media Org B','training-media-org-b');
insert into public.training_courses(id,organization_id,course_key) values
 ('3b300000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','media-a'),
 ('3b300000-0000-4000-8000-000000000002','3b200000-0000-4000-8000-000000000002','media-b');
insert into public.training_course_versions(id,organization_id,course_id,version_number,default_locale,supported_locales,title_i18n) values
 ('3b400000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001',1,'en',array['en','ar','id','hi','fil'],'{"en":"Course A"}'),
 ('3b400000-0000-4000-8000-000000000002','3b200000-0000-4000-8000-000000000002','3b300000-0000-4000-8000-000000000002',1,'en',array['en','ar','id','hi','fil'],'{"en":"Course B"}');
insert into public.training_modules(id,organization_id,course_version_id,stable_key,position,metadata)
values('3b700000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','module',1,
 '{"photo_requirements":[{"asset_key":"photo","lesson_key":"lesson","placement":"overview-hero","alt_i18n":{"en":"Alt","ar":"بديل","id":"Alt","hi":"वैकल्पिक","fil":"Alt"}}]}');
insert into public.training_lessons(id,organization_id,course_version_id,module_id,stable_key,position,lesson_type,content_i18n)
values('3b800000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','3b700000-0000-4000-8000-000000000001','lesson',1,'reading',
 '{"en":{"image_slots":[{"asset_key":"photo","placement":"overview-hero","slot_position":1,"label":"Alt"}]},"ar":{"image_slots":[{"asset_key":"photo","placement":"overview-hero","slot_position":1,"label":"بديل"}]},"id":{"image_slots":[{"asset_key":"photo","placement":"overview-hero","slot_position":1,"label":"Alt"}]},"hi":{"image_slots":[{"asset_key":"photo","placement":"overview-hero","slot_position":1,"label":"वैकल्पिक"}]},"fil":{"image_slots":[{"asset_key":"photo","placement":"overview-hero","slot_position":1,"label":"Alt"}]}}');

select ok(exists(select 1 from storage.buckets where id='training-media' and not public and file_size_limit=5242880 and allowed_mime_types=array['image/webp']),'private WebP-only bucket is configured');
select ok((select relrowsecurity from pg_class where oid='public.training_media_assets'::regclass),'media table has RLS enabled');
select ok(not has_table_privilege('service_role','public.training_media_assets','select'),'service role has no direct table SELECT');
select ok(not has_table_privilege('authenticated','public.training_media_assets','insert'),'authenticated has no direct table INSERT');
select ok(has_function_privilege('service_role','public.register_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,text,integer,integer,integer,text,text,integer,text)','execute'),'service role can execute register RPC');
select ok(not has_function_privilege('authenticated','public.register_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,text,integer,integer,integer,text,text,integer,text)','execute'),'authenticated cannot execute register RPC');
select throws_ok($$select * from public.register_internal_admin_training_media(
 '3b100000-0000-4000-8000-000000000002','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','3b500000-0000-4000-8000-000000000001','photo',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 'organizations/3b200000-0000-4000-8000-000000000001/courses/3b300000-0000-4000-8000-000000000001/versions/3b400000-0000-4000-8000-000000000001/assets/3b500000-0000-4000-8000-000000000001/3b600000-0000-4000-8000-000000000001.webp',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$$,'42501','Training media access denied','non-admin registration is denied');
select throws_ok($$select * from public.register_internal_admin_training_media(
 '3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000002','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','3b500000-0000-4000-8000-000000000001','photo',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 'organizations/3b200000-0000-4000-8000-000000000002/courses/3b300000-0000-4000-8000-000000000001/versions/3b400000-0000-4000-8000-000000000001/assets/3b500000-0000-4000-8000-000000000001/3b600000-0000-4000-8000-000000000001.webp',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$$,'P0002','Training course version not found','mismatched organization/version is denied');
select lives_ok($$select * from public.register_internal_admin_training_media(
 '3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','3b500000-0000-4000-8000-000000000001','photo',
 '{"en":"Title","ar":"عنوان","id":"Judul","hi":"शीर्षक","fil":"Pamagat"}','{"en":"Alt","ar":"بديل","id":"Alt","hi":"वैकल्पिक","fil":"Alt"}',
 'organizations/3b200000-0000-4000-8000-000000000001/courses/3b300000-0000-4000-8000-000000000001/versions/3b400000-0000-4000-8000-000000000001/assets/3b500000-0000-4000-8000-000000000001/3b600000-0000-4000-8000-000000000001.webp',100,1280,720,repeat('a',64),'image/png',200,repeat('b',64))$$,'admin can register draft media');
select is((select approval_status from public.training_media_assets where id='3b500000-0000-4000-8000-000000000001'),'submitted','new media starts submitted');
select throws_like($$insert into public.training_media_assets(id,organization_id,course_version_id,asset_key,media_type,title_i18n,alt_i18n,storage_object_path,mime_type,byte_size,width,height,sha256,source_mime_type,source_byte_size,source_sha256,approval_status)
 values('3b500000-0000-4000-8000-000000000002','3b200000-0000-4000-8000-000000000002','3b400000-0000-4000-8000-000000000001','cross','image','{}','{}','organizations/3b200000-0000-4000-8000-000000000002/courses/3b300000-0000-4000-8000-000000000002/versions/3b400000-0000-4000-8000-000000000001/assets/3b500000-0000-4000-8000-000000000002/3b600000-0000-4000-8000-000000000002.webp','image/webp',1,1,1,repeat('a',64),'image/png',1,repeat('b',64),'submitted')$$,'%violates foreign key constraint%','cross-org table insert is rejected');
select throws_like($$select * from public.register_internal_admin_training_media(
 '3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','3b500000-0000-4000-8000-000000000003','photo',
 '{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}',
 'organizations/3b200000-0000-4000-8000-000000000001/courses/3b300000-0000-4000-8000-000000000001/versions/3b400000-0000-4000-8000-000000000001/assets/3b500000-0000-4000-8000-000000000003/3b600000-0000-4000-8000-000000000003.webp',100,1280,720,repeat('c',64),'image/png',200,repeat('d',64))$$,'%duplicate key value violates unique constraint "training_media_assets_version_asset_key_key"%','asset key is unique per version');
select throws_ok($$select * from public.validate_internal_admin_training_media_for_publish('3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001')$$,'55000','Training media publication validation failed','publication rejects unapproved referenced media');
select throws_ok($$select * from public.retire_internal_admin_training_media('3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','3b500000-0000-4000-8000-000000000001')$$,'55000','Required Training image slots must be replaced, not removed','referenced draft media cannot be removed');
update public.training_media_assets set approval_status='approved' where id='3b500000-0000-4000-8000-000000000001';
select lives_ok($$select * from public.validate_internal_admin_training_media_for_publish('3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001')$$,'approved references pass DB publication validation');
select is((select count(*) from public.list_internal_admin_training_media('3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001')),1::bigint,'draft list returns scoped media');
select lives_ok($$update public.training_course_versions set status='published',published_at=statement_timestamp(),published_by='3b100000-0000-4000-8000-000000000001',content_hash='test' where id='3b400000-0000-4000-8000-000000000001'$$,'draft version can be published for immutability test');
select throws_ok($$update public.training_media_assets set title_i18n='{"en":"Changed"}' where id='3b500000-0000-4000-8000-000000000001'$$,'55000','Published or retired Training media is immutable','published media metadata is immutable');
select throws_ok($$select * from public.update_internal_admin_training_media_metadata('3b100000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','3b400000-0000-4000-8000-000000000001','3b500000-0000-4000-8000-000000000001','{"en":"T","ar":"T","id":"T","hi":"T","fil":"T"}','{"en":"A","ar":"A","id":"A","hi":"A","fil":"A"}')$$,'55000','Training course version is immutable','published mutation RPC is rejected');

select * from finish();
rollback;
