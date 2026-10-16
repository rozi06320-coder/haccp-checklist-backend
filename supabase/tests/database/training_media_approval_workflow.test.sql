begin;
select plan(29);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
 ('00000000-0000-0000-0000-000000000000','7a100000-0000-4000-8000-000000000001','authenticated','authenticated','training-review-admin@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','7a100000-0000-4000-8000-000000000002','authenticated','authenticated','training-review-user@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Training Review Admin',must_change_password=false where id='7a100000-0000-4000-8000-000000000001';
update public.profiles set full_name='Training Review User',must_change_password=false where id='7a100000-0000-4000-8000-000000000002';
insert into public.internal_admin_memberships(user_id,active) values('7a100000-0000-4000-8000-000000000001',true);

create temporary table review_scope as
select course.organization_id,course.id as course_id,version.id as version_id
from public.training_courses course
join public.training_course_versions version on version.course_id=course.id and version.organization_id=course.organization_id
where course.course_key='baladiyah-food-safety-hygiene' and version.version_number=1;

select has_column('public','training_media_assets','reviewed_at','review timestamp exists');
select has_column('public','training_media_assets','reviewed_by','review actor exists');
select has_column('public','training_media_assets','rejection_reason','rejection reason exists');
select has_column('public','training_media_assets','revision','optimistic revision exists');
select col_default_is('public','training_media_assets','revision','1','media revision starts at one');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.training_media_assets'::regclass),'media RLS remains enabled');
select ok(not has_table_privilege('service_role','public.training_media_assets','select'),'service role has no direct table read');
select ok(has_function_privilege('service_role','public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text)','execute'),'review RPC is granted to service role');
select ok(not has_function_privilege('authenticated','public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text)','execute') and not has_function_privilege('anon','public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text)','execute'),'browser roles cannot execute review RPC');

select throws_ok(format($call$select * from public.review_internal_admin_training_media(
 '7a100000-0000-4000-8000-000000000002',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',1,'approved',null)$call$,
 (select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),
 '42501','Training media access denied','non-admin review is denied');
select throws_ok(format($call$select * from public.review_internal_admin_training_media(
 '7a100000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000099',%L,%L,'7a500000-0000-4000-8000-000000000001',1,'approved',null)$call$,
 (select course_id from review_scope),(select version_id from review_scope)),
 'P0002','Training course version not found','cross-organization review is denied');
select throws_ok(format($call$select * from public.review_internal_admin_training_media(
 '7a100000-0000-4000-8000-000000000001',%L,%L,'7a400000-0000-4000-8000-000000000099','7a500000-0000-4000-8000-000000000001',1,'approved',null)$call$,
 (select organization_id from review_scope),(select course_id from review_scope)),
 'P0002','Training course version not found','cross-version review is denied');

select lives_ok(format($call$select * from public.register_internal_admin_training_media(
 '7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001','personal-hygiene-handwashing-wet',
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',%L,
 100,1280,720,repeat('a',64),'image/webp',100,repeat('b',64))$call$,
 (select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope),
 'organizations/'||(select organization_id from review_scope)||'/courses/'||(select course_id from review_scope)||'/versions/'||(select version_id from review_scope)||'/assets/7a500000-0000-4000-8000-000000000001/7a600000-0000-4000-8000-000000000001.webp'),
 'submitted slot image is registered');
select ok((select approval_status='submitted' and revision=1 and reviewed_at is null and reviewed_by is null and rejection_reason is null from public.training_media_assets where id='7a500000-0000-4000-8000-000000000001'),'new upload has an unreviewed revision-one state');
select ok((select revision=1 and media_alt_i18n->>'en'='Wet hands' and rejection_reason is null from public.list_internal_admin_training_image_slots('7a100000-0000-4000-8000-000000000001',(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)) where media_id='7a500000-0000-4000-8000-000000000001'),'slot read model exposes safe review fields and actual alt text');
select throws_ok(format($call$select * from public.review_internal_admin_training_media('7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',1,'rejected','')$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'22023','Invalid Training media review','rejection requires a reason');
select lives_ok(format($call$select * from public.review_internal_admin_training_media('7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',1,'rejected','Operational subject is unclear.')$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'submitted image can be rejected');
select ok((select approval_status='rejected' and revision=2 and reviewed_at is not null and reviewed_by='7a100000-0000-4000-8000-000000000001' and rejection_reason='Operational subject is unclear.' from public.training_media_assets where id='7a500000-0000-4000-8000-000000000001'),'rejection records actor, time, reason, and revision');
select throws_ok(format($call$select * from public.review_internal_admin_training_media('7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',1,'approved',null)$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'40001','Training media review is stale','stale concurrent review is rejected');

select lives_ok(format($call$select * from public.replace_internal_admin_training_media(
 '7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',%L,
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',
 '{"en":"Wet hands","ar":"بلل اليدين","id":"Basahi tangan","hi":"हाथ गीले करें","fil":"Basain ang kamay"}',
 101,1280,720,repeat('c',64),'image/webp',101,repeat('d',64))$call$,
 (select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope),
 'organizations/'||(select organization_id from review_scope)||'/courses/'||(select course_id from review_scope)||'/versions/'||(select version_id from review_scope)||'/assets/7a500000-0000-4000-8000-000000000001/7a600000-0000-4000-8000-000000000002.webp'),
 'rejected image can be replaced');
select ok((select approval_status='submitted' and revision=3 and reviewed_at is null and reviewed_by is null and rejection_reason is null from public.training_media_assets where id='7a500000-0000-4000-8000-000000000001'),'replacement resets review state and increments revision');
select lives_ok(format($call$select * from public.review_internal_admin_training_media('7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',3,'approved',null)$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'submitted replacement can be approved');
select ok((select approval_status='approved' and revision=4 and reviewed_at is not null and reviewed_by='7a100000-0000-4000-8000-000000000001' and rejection_reason is null from public.training_media_assets where id='7a500000-0000-4000-8000-000000000001'),'approval records audit metadata without changing the image metadata');
select throws_ok(format($call$select * from public.review_internal_admin_training_media('7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',3,'rejected','Changed decision')$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'40001','Training media review is stale','second review with the consumed revision is rejected');
select throws_ok(format($call$select * from public.validate_internal_admin_training_media_for_publish('7a100000-0000-4000-8000-000000000001',%L,%L,%L)$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'55000','Training media publication validation failed','missing media still blocks publication');

insert into public.training_media_assets(
 id,organization_id,course_version_id,asset_key,media_type,title_i18n,alt_i18n,storage_object_path,mime_type,
 byte_size,width,height,sha256,source_mime_type,source_byte_size,source_sha256,approval_status,status,reviewed_at,reviewed_by
)
select md5('review-media-'||slot.asset_key)::uuid,scope.organization_id,scope.version_id,slot.asset_key,'image',slot.expected_alt_i18n,slot.expected_alt_i18n,
 'organizations/'||scope.organization_id||'/courses/'||scope.course_id||'/versions/'||scope.version_id||'/assets/'||md5('review-media-'||slot.asset_key)::uuid||'/'||md5('review-object-'||slot.asset_key)::uuid||'.webp',
 'image/webp',100,1280,720,encode(digest(slot.asset_key,'sha256'),'hex'),'image/webp',100,encode(digest('source-'||slot.asset_key,'sha256'),'hex'),'approved','ready',statement_timestamp(),'7a100000-0000-4000-8000-000000000001'
from review_scope scope cross join private.training_image_slot_requirements(scope.organization_id,scope.version_id) slot
where slot.asset_key<>'personal-hygiene-handwashing-wet';

select lives_ok(format($call$select * from public.validate_internal_admin_training_media_for_publish('7a100000-0000-4000-8000-000000000001',%L,%L,%L)$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'forty audited approvals satisfy publication validation');
select lives_ok(format($call$update public.training_course_versions set status='published',published_at=statement_timestamp(),published_by='7a100000-0000-4000-8000-000000000001' where id=%L$call$,(select version_id from review_scope)),'fully reviewed version can publish');
select throws_ok(format($call$select * from public.review_internal_admin_training_media('7a100000-0000-4000-8000-000000000001',%L,%L,%L,'7a500000-0000-4000-8000-000000000001',4,'rejected','No longer editable')$call$,(select organization_id from review_scope),(select course_id from review_scope),(select version_id from review_scope)),'55000','Training course version is immutable','published media review is denied');
select is((select count(*)::integer from public.training_media_assets where course_version_id=(select version_id from review_scope)),40,'review workflow does not create duplicate media rows');

select * from finish();
rollback;
