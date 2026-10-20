begin;
select plan(53);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
 ('00000000-0000-0000-0000-000000000000','9a100000-0000-4000-8000-000000000001','authenticated','authenticated','phase3a-submitter@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','9a100000-0000-4000-8000-000000000002','authenticated','authenticated','phase3a-reviewer@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','9a100000-0000-4000-8000-000000000003','authenticated','authenticated','phase3a-publisher@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','9a100000-0000-4000-8000-000000000004','authenticated','authenticated','phase3a-user@example.invalid','{}','{}',now(),now());
update public.profiles set must_change_password=false where id::text like '9a100000-0000-4000-8000-00000000000%';
insert into public.internal_admin_memberships(user_id,active) values
 ('9a100000-0000-4000-8000-000000000001',true),
 ('9a100000-0000-4000-8000-000000000002',true),
 ('9a100000-0000-4000-8000-000000000003',true);

create temporary table phase3a_scope as
select course.organization_id,course.id course_id,version.id version_id
from public.training_courses course
join public.training_course_versions version
  on version.course_id=course.id and version.organization_id=course.organization_id
where course.course_key='baladiyah-food-safety-hygiene' and version.version_number=1;

select has_table('public','training_publication_review_submissions','review submissions exist');
select has_table('public','training_publication_review_events','review events exist');
select has_table('public','training_media_review_events','media audit events exist');
select has_table('public','training_content_contributor_events','content contributor history exists');
select has_table('public','training_media_contributor_events','media contributor history exists');
select has_table('public','training_publication_submission_contributors','submission contributor snapshots exist');
select has_table('public','training_storage_verification_runs','storage verification runs exist');
select has_table('public','training_storage_verification_items','storage verification evidence exists');
select has_table('public','training_publication_lifecycle_events','publication lifecycle events exist');
select ok((select bool_and(relrowsecurity) from pg_catalog.pg_class where oid in(
  'public.training_publication_review_submissions'::regclass,
  'public.training_content_contributor_events'::regclass,
  'public.training_media_contributor_events'::regclass,
  'public.training_publication_review_events'::regclass,
  'public.training_publication_submission_contributors'::regclass,
  'public.training_media_review_events'::regclass,
  'public.training_storage_verification_runs'::regclass,
  'public.training_storage_verification_items'::regclass,
  'public.training_publication_lifecycle_events'::regclass
)),'all new tables have RLS enabled');
select ok(not has_table_privilege('service_role','public.training_publication_review_events','select')
  and not has_table_privilege('authenticated','public.training_publication_review_events','select'),
  'audit tables have no direct service or browser reads');
select ok(not has_function_privilege('service_role','public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)','execute')
  and not has_function_privilege('service_role','public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb)','execute')
  and has_function_privilege('service_role','public.begin_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)','execute')
  and not has_function_privilege('authenticated','public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)','execute'),
  'Storage completion and publication fail closed while begin remains service-role only');
select is((select count(*)::integer from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname in('public','private')
    and procedure.proname in(
      'submit_internal_admin_training_version_for_review','review_internal_admin_training_version',
      'revoke_internal_admin_training_version_approval','begin_internal_admin_training_storage_verification',
      'complete_internal_admin_training_storage_verification','publish_internal_admin_training_course_version',
      'retire_internal_admin_training_course_version','activate_internal_admin_restaurant_training_program',
      'retire_internal_admin_training_program'
    ) and procedure.prosecdef and procedure.proconfig @> array['search_path=""']),9,
  'all Phase 3A mutation RPCs are SECURITY DEFINER with empty search_path');

insert into public.training_media_assets(
  id,organization_id,course_version_id,asset_key,media_type,title_i18n,alt_i18n,
  storage_object_path,mime_type,byte_size,width,height,sha256,source_mime_type,
  source_byte_size,source_sha256,approval_status,status,created_by,updated_by
)
select md5('phase3a-media-'||slot.asset_key)::uuid,scope.organization_id,scope.version_id,
  slot.asset_key,'image',slot.expected_alt_i18n,slot.expected_alt_i18n,
  'organizations/'||scope.organization_id||'/courses/'||scope.course_id||'/versions/'||scope.version_id||
    '/assets/'||md5('phase3a-media-'||slot.asset_key)::uuid||'/00000000-0000-4000-8000-'||
    substring(md5('phase3a-object-'||slot.asset_key) from 1 for 12)||'.webp',
  'image/webp',100,1280,720,encode(digest('stored-'||slot.asset_key,'sha256'),'hex'),
  'image/webp',100,encode(digest('source-'||slot.asset_key,'sha256'),'hex'),
  'submitted','ready','9a100000-0000-4000-8000-000000000001','9a100000-0000-4000-8000-000000000001'
from phase3a_scope scope
cross join private.training_image_slot_requirements(scope.organization_id,scope.version_id) slot;

select throws_ok(format($call$select * from public.review_internal_admin_training_media(
  '9a100000-0000-4000-8000-000000000001',%L,%L,%L,%L,1,'approved',null)$call$,
  (select organization_id from phase3a_scope),(select course_id from phase3a_scope),(select version_id from phase3a_scope),
  (select id from public.training_media_assets where course_version_id=(select version_id from phase3a_scope) order by asset_key limit 1)),
  '42501','Training media self-approval is forbidden','uploader cannot approve their own media');
select throws_ok(format($call$select * from public.review_internal_admin_training_media(
  '9a100000-0000-4000-8000-000000000004',%L,%L,%L,%L,1,'approved',null)$call$,
  (select organization_id from phase3a_scope),(select course_id from phase3a_scope),(select version_id from phase3a_scope),
  (select id from public.training_media_assets where course_version_id=(select version_id from phase3a_scope) order by asset_key limit 1)),
  '42501','Training media access denied','non-admin cannot approve media');

do $approve_media$
declare asset record;
begin
  for asset in select * from public.training_media_assets
    where course_version_id=(select version_id from phase3a_scope) order by asset_key
  loop
    perform * from public.review_internal_admin_training_media(
      '9a100000-0000-4000-8000-000000000002',asset.organization_id,
      (select course_id from phase3a_scope),asset.course_version_id,asset.id,asset.revision,'approved',null
    );
  end loop;
end;
$approve_media$;

select is((select count(*)::integer from public.training_media_review_events where decision='approved'),40,
  'forty immutable independent media approvals are recorded');
select ok((select bool_and(actor_user_id<>uploader_user_id) from public.training_media_review_events where decision='approved'),
  'every media approval is independent from its uploader');
select throws_ok(format($call$update public.training_media_review_events set reason='tamper' where organization_id=%L$call$,
  (select organization_id from phase3a_scope)),'55000','Training audit records are immutable','media approval history cannot be changed');

update public.training_modules module set
  title_i18n=jsonb_set(module.title_i18n,'{en}','"Temporary earlier contributor edit"'),
  updated_by='9a100000-0000-4000-8000-000000000003'
where module.course_version_id=(select version_id from phase3a_scope) and module.position=1;
-- Restore from the canonical preview's known module-one value without losing
-- the immutable earlier-contributor event.
update public.training_modules module set
  title_i18n='{"ar":"النظافة الشخصية والصحة","en":"Personal Hygiene & Health","hi":"व्यक्तिगत स्वच्छता और स्वास्थ्य","id":"Kebersihan Pribadi & Kesehatan","fil":"Personal na Kalinisan at Kalusugan"}'::jsonb,
  updated_by='9a100000-0000-4000-8000-000000000001'
where module.course_version_id=(select version_id from phase3a_scope) and module.position=1;

create temporary table first_review as
select scope.*,private.training_publication_content_fingerprint(scope.organization_id,scope.course_id,scope.version_id) fingerprint
from phase3a_scope scope;
select lives_ok(format($call$select * from public.submit_internal_admin_training_version_for_review(
  '9a100000-0000-4000-8000-000000000001',%L,%L,%L,2,%L,'9a200000-0000-4000-8000-000000000001')$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),(select fingerprint from first_review)),
  'explicit author attestation submits the exact version fingerprint');
select throws_ok(format($call$select * from public.submit_internal_admin_training_version_for_review(
  '9a100000-0000-4000-8000-000000000001',%L,%L,%L,2,%L,'9a200000-0000-4000-8000-000000000001')$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),(select fingerprint from first_review)),
  '55000','Training review submission was already recorded','submission action replay is rejected');

create temporary table first_submission as select * from public.training_publication_review_submissions
where action_request_id='9a200000-0000-4000-8000-000000000001';
select throws_ok(format($call$select * from public.review_internal_admin_training_version(
  '9a100000-0000-4000-8000-000000000001',%L,%L,%L,%L,2,%L,'content',null,'approved',null,
  '9a300000-0000-4000-8000-000000000001')$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),
  (select id from first_submission),(select fingerprint from first_review)),
  '42501','Training self-approval is forbidden','content submitter cannot approve their own submission');
select ok(exists(select 1 from public.training_publication_submission_contributors
  where submission_id=(select id from first_submission)
    and contributor_user_id='9a100000-0000-4000-8000-000000000003'),
  'submission snapshot retains an earlier modifier after a later admin update');
select throws_ok(format($call$select * from public.review_internal_admin_training_version(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,%L,2,%L,'content',null,'approved',null,
  '9a300000-0000-4000-8000-000000000002')$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),
  (select id from first_submission),(select fingerprint from first_review)),
  '42501','Training self-approval is forbidden','earlier modifier cannot approve after another administrator updates the item');
select throws_ok(format($call$select * from public.review_internal_admin_training_version(
  '9a100000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001',%L,%L,%L,2,%L,
  'content',null,'approved',null,'9a300000-0000-4000-8000-000000000003')$call$,
  (select course_id from first_review),(select version_id from first_review),(select id from first_submission),(select fingerprint from first_review)),
  'P0002','Training course version not found','review cannot cross organization scope');

do $approve_first_review$
declare item record; request_number integer := 1;
begin
  for item in select * from (values
    ('content'::text,null::text),('internal_regulatory',null),('translation','en'),('translation','ar'),
    ('translation','id'),('translation','hi'),('translation','fil')) approval(review_type,locale)
  loop
    perform * from public.review_internal_admin_training_version(
      '9a100000-0000-4000-8000-000000000002',(select organization_id from first_review),
      (select course_id from first_review),(select version_id from first_review),(select id from first_submission),
      2,(select fingerprint from first_review),item.review_type,item.locale,'approved',null,
      ('9a310000-0000-4000-8000-'||lpad(request_number::text,12,'0'))::uuid
    );
    request_number := request_number+1;
  end loop;
end;
$approve_first_review$;

select is((select count(*)::integer from public.training_publication_review_events where submission_id=(select id from first_submission) and decision='approved'),7,
  'content, internal material, and all five translations are independently approved');
select throws_ok(format($call$select * from public.review_internal_admin_training_version(
  '9a100000-0000-4000-8000-000000000002',%L,%L,%L,%L,2,%L,'content',null,'approved',null,
  '9a300000-0000-4000-8000-000000000099')$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),
  (select id from first_submission),(select fingerprint from first_review)),
  '55000','Training review decision was already recorded','duplicate approval is rejected');
select lives_ok(format($call$select * from public.revoke_internal_admin_training_version_approval(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,%L,'content',null,'superseded review',
  '9a330000-0000-4000-8000-000000000001')$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),
  (select id from first_submission)),'active approval can be revoked once under the version lock');
select throws_ok(format($call$select * from public.revoke_internal_admin_training_version_approval(
  '9a100000-0000-4000-8000-000000000002',%L,%L,%L,%L,'content',null,'duplicate revocation',
  '9a330000-0000-4000-8000-000000000002')$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),
  (select id from first_submission)),'55000','Training approval is not active','duplicate revocation is rejected');

select * from public.update_internal_admin_training_media_metadata(
  '9a100000-0000-4000-8000-000000000001',(select organization_id from first_review),
  (select course_id from first_review),(select version_id from first_review),
  (select id from public.training_media_assets where course_version_id=(select version_id from first_review) order by asset_key limit 1),
  (select title_i18n from public.training_media_assets where course_version_id=(select version_id from first_review) order by asset_key limit 1),
  jsonb_set((select alt_i18n from public.training_media_assets where course_version_id=(select version_id from first_review) order by asset_key limit 1),'{en}','"Changed exact byte binding"')
);
select ok((select approval_status='submitted' and reviewed_by is null
  from public.training_media_assets where course_version_id=(select version_id from first_review) order by asset_key limit 1),
  'approved media metadata can be changed only by returning it to submitted');
select is((select content_review_status from public.get_internal_admin_training_publication_readiness(
  '9a100000-0000-4000-8000-000000000003',(select organization_id from first_review),
  (select course_id from first_review),(select version_id from first_review))),'pending',
  'a relevant content change invalidates the prior fingerprint approvals');

select lives_ok(format($call$select * from public.review_internal_admin_training_media(
  '9a100000-0000-4000-8000-000000000002',%L,%L,%L,%L,
  (select revision from public.training_media_assets where id=%L),'approved',null)$call$,
  (select organization_id from first_review),(select course_id from first_review),(select version_id from first_review),
  (select id from public.training_media_assets where course_version_id=(select version_id from first_review) order by asset_key limit 1),
  (select id from public.training_media_assets where course_version_id=(select version_id from first_review) order by asset_key limit 1)),
  'changed media is independently reapproved');

create temporary table final_review as
select scope.*,private.training_publication_content_fingerprint(scope.organization_id,scope.course_id,scope.version_id) fingerprint
from phase3a_scope scope;
select lives_ok(format($call$select * from public.submit_internal_admin_training_version_for_review(
  '9a100000-0000-4000-8000-000000000001',%L,%L,%L,2,%L,'9a200000-0000-4000-8000-000000000002')$call$,
  (select organization_id from final_review),(select course_id from final_review),(select version_id from final_review),(select fingerprint from final_review)),
  'changed fingerprint requires a new review submission');
create temporary table final_submission as select * from public.training_publication_review_submissions
where action_request_id='9a200000-0000-4000-8000-000000000002';

do $approve_final_review$
declare item record; request_number integer := 1;
begin
  for item in select * from (values
    ('content'::text,null::text),('internal_regulatory',null),('translation','en'),('translation','ar'),
    ('translation','id'),('translation','hi'),('translation','fil')) approval(review_type,locale)
  loop
    perform * from public.review_internal_admin_training_version(
      '9a100000-0000-4000-8000-000000000002',(select organization_id from final_review),
      (select course_id from final_review),(select version_id from final_review),(select id from final_submission),
      2,(select fingerprint from final_review),item.review_type,item.locale,'approved',null,
      ('9a320000-0000-4000-8000-'||lpad(request_number::text,12,'0'))::uuid
    );
    request_number := request_number+1;
  end loop;
end;
$approve_final_review$;

select ok((select review_workflow_available and content_review_status='approved'
  and regulatory_review_status='approved' and translation_review_status->>'fil'='approved'
  and image_database_ready from public.get_internal_admin_training_publication_readiness(
    '9a100000-0000-4000-8000-000000000003',(select organization_id from final_review),
    (select course_id from final_review),(select version_id from final_review))),
  'readiness exposes current reviews and independently audited media');

create temporary table verification_candidates as
select * from public.begin_internal_admin_training_storage_verification(
  '9a100000-0000-4000-8000-000000000003',(select organization_id from final_review),
  (select course_id from final_review),(select version_id from final_review),(select id from final_submission),
  2,(select fingerprint from final_review),'9a400000-0000-4000-8000-000000000001');
select is((select count(*)::integer from verification_candidates),40,
  'storage verification challenge binds all forty exact private objects');
select throws_ok(format($call$select * from public.complete_internal_admin_training_storage_verification(
  '9a100000-0000-4000-8000-000000000003',%L,%L,'9a400000-0000-4000-8000-000000000099',%L::jsonb)$call$,
  (select organization_id from final_review),(select verification_run_id from verification_candidates limit 1),
  (select jsonb_agg(jsonb_build_object('media_id',media_id,'sha256',expected_sha256,'byte_size',expected_byte_size,'width',expected_width,'height',expected_height))::text from verification_candidates)),
  '55000','Training storage verification is invalid or expired','forged challenge nonce is rejected');
select throws_ok(format($call$select * from public.complete_internal_admin_training_storage_verification(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,%L::jsonb)$call$,
  (select organization_id from final_review),(select verification_run_id from verification_candidates limit 1),
  (select challenge_nonce from verification_candidates limit 1),
  (select jsonb_agg(jsonb_build_object('media_id',media_id,'sha256',case when sequence=1 then repeat('f',64) else expected_sha256 end,'byte_size',expected_byte_size,'width',expected_width,'height',expected_height))::text
   from (select candidate.*,row_number() over(order by media_id) sequence from verification_candidates candidate) numbered)),
  '55000','Training storage object evidence does not match','forged object hash is rejected');
create temporary table echo_attempt as
select format($call$select * from public.complete_internal_admin_training_storage_verification(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,%L::jsonb)$call$,
  (select organization_id from final_review),(select verification_run_id from verification_candidates limit 1),
  (select challenge_nonce from verification_candidates limit 1),
  (select jsonb_agg(jsonb_build_object('media_id',media_id,'sha256',expected_sha256,'byte_size',expected_byte_size,'width',expected_width,'height',expected_height))::text from verification_candidates)
) statement;
grant select on echo_attempt to service_role;
set local role service_role;
select throws_ok((select statement from echo_attempt),'42501',
  'permission denied for function complete_internal_admin_training_storage_verification',
  'general service role cannot self-attest by echoing the expected manifest');
reset role;
select lives_ok(format($call$select * from public.complete_internal_admin_training_storage_verification(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,%L::jsonb)$call$,
  (select organization_id from final_review),(select verification_run_id from verification_candidates limit 1),
  (select challenge_nonce from verification_candidates limit 1),
  (select jsonb_agg(jsonb_build_object('media_id',media_id,'sha256',expected_sha256,'byte_size',expected_byte_size,'width',expected_width,'height',expected_height))::text from verification_candidates)),
  'fresh exact Storage observations complete the challenge');

-- Phase 3C owns the outer manifest gate. This Phase 3A regression deliberately
-- bypasses only that trigger while exercising the unchanged Phase 3A publisher.
alter table public.training_course_versions disable trigger training_course_versions_02_manifest_publication_gate;
select lives_ok(format($call$select * from public.publish_internal_admin_training_course_version(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,%L,%L,2,%L,
  '9a500000-0000-4000-8000-000000000001')$call$,
  (select organization_id from final_review),(select course_id from final_review),(select version_id from final_review),
  (select id from final_submission),(select verification_run_id from verification_candidates limit 1),(select fingerprint from final_review)),
  'atomic publication succeeds only after all exact approvals and fresh Storage evidence');
alter table public.training_course_versions enable trigger training_course_versions_02_manifest_publication_gate;
select ok((select status='published' and publication_fingerprint=(select fingerprint from final_review)
  from public.training_course_versions where id=(select version_id from final_review)),
  'published version retains its approved fingerprint');
select is((select private.training_publication_content_fingerprint(organization_id,course_id,id)
  from public.training_course_versions where id=(select version_id from final_review)),
  (select fingerprint from final_review),'approved fingerprint is reproducible after content-hash publication transition');
select throws_ok(format($call$update public.training_course_versions set publication_fingerprint=%L where id=%L$call$,
  repeat('0',64),(select version_id from final_review)),
  '55000','Published Training course version content is immutable','publication fingerprint cannot change after publication');
select is((select count(*)::integer from public.training_publication_lifecycle_events where event_type='published'),1,
  'publication creates one immutable lifecycle event');
select throws_ok(format($call$select * from public.publish_internal_admin_training_course_version(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,%L,%L,2,%L,
  '9a500000-0000-4000-8000-000000000001')$call$,
  (select organization_id from final_review),(select course_id from final_review),(select version_id from final_review),
  (select id from final_submission),(select verification_run_id from verification_candidates limit 1),(select fingerprint from final_review)),
  '55000','Training course version is immutable','publication replay cannot double-publish');

select lives_ok(format($call$select * from public.provision_internal_admin_restaurant_training_program(
  '9a100000-0000-4000-8000-000000000003',%L,
  '{"en":"Restaurant Training","ar":"تدريب المطعم","id":"Pelatihan Restoran","hi":"रेस्तरां प्रशिक्षण","fil":"Pagsasanay sa Restaurant"}',
  '{"en":"Required learning","ar":"التعلم المطلوب","id":"Pembelajaran wajib","hi":"आवश्यक प्रशिक्षण","fil":"Kinakailangang pagsasanay"}',
  '{"en":"Baladiyah","ar":"البلدية","id":"Baladiyah","hi":"बलदिया","fil":"Baladiyah"}',
  '{"en":"Restaurant SOP","ar":"إجراءات تشغيل المطعم","id":"SOP Restoran","hi":"रेस्तरां एसओपी","fil":"SOP ng Restaurant"}')$call$,
  (select organization_id from final_review)),'exact two-course Restaurant Training draft is provisioned');
create temporary table program_scope as select * from public.training_programs
where organization_id=(select organization_id from final_review) and program_key='restaurant-training';
select lives_ok(format($call$select * from public.activate_internal_admin_restaurant_training_program(
  '9a100000-0000-4000-8000-000000000003',%L,%L,'9a600000-0000-4000-8000-000000000001')$call$,
  (select organization_id from final_review),(select id from program_scope)),
  'program activates with published Baladiyah first and unpublished dependent SOP second');
select ok((select status='active' from public.training_programs where id=(select id from program_scope))
  and (select count(*)=2 from public.training_program_courses where program_id=(select id from program_scope))
  and not exists(select 1 from public.training_course_versions version join public.training_courses course on course.id=version.course_id
    where course.organization_id=(select organization_id from final_review) and course.course_key='restaurant-sop' and version.status='published'),
  'activation preserves the exact ordered two-course invariant without publishing SOP');
select throws_ok(format($call$select * from public.retire_internal_admin_training_course_version(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,'planned replacement',
  '9a700000-0000-4000-8000-000000000001')$call$,
  (select organization_id from final_review),(select course_id from final_review),(select version_id from final_review)),
  '55000','An active Training program still requires this course','active program prevents unsafe course retirement');

select lives_ok(format($call$select * from public.retire_internal_admin_training_program(
  '9a100000-0000-4000-8000-000000000003',%L,%L,'planned program replacement',
  '9a610000-0000-4000-8000-000000000001')$call$,
  (select organization_id from final_review),(select id from program_scope)),
  'Internal Admin can retire an idle active Training program through an audited RPC');
select is((select count(*)::integer from public.training_publication_lifecycle_events where event_type='program_retired'),1,
  'program retirement creates one immutable lifecycle event');
select lives_ok(format($call$select * from public.retire_internal_admin_training_course_version(
  '9a100000-0000-4000-8000-000000000003',%L,%L,%L,'planned replacement',
  '9a700000-0000-4000-8000-000000000002')$call$,
  (select organization_id from final_review),(select course_id from final_review),(select version_id from final_review)),
  'completed/no-enrollment published version can retire without deleting history');
select ok((select status='retired' and retired_by='9a100000-0000-4000-8000-000000000003'
  from public.training_course_versions where id=(select version_id from final_review))
  and (select count(*)=1 from public.training_publication_lifecycle_events where event_type='retired'),
  'safe retirement records immutable actor, fingerprint, reason, and timestamp');
select throws_ok(format($call$delete from public.training_publication_lifecycle_events where organization_id=%L$call$,
  (select organization_id from final_review)),'55000','Training audit records are immutable','publication history cannot be deleted');

select * from finish();
rollback;
