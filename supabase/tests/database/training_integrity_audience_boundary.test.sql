begin;
select plan(20);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','ad100000-0000-4000-8000-000000000001',
  'authenticated','authenticated','integrity-audience-fixture@example.invalid','{}','{}',now(),now());

create temporary table integrity_audience_scope as
select organization.id organization_id
from public.organizations organization
order by organization.created_at,organization.id
limit 1;

insert into private.training_verifier_capabilities(id,secret_sha256,audience,active,created_at,expires_at)
values
('ad200000-0000-4000-8000-000000000001',extensions.digest(convert_to(
  'production-integrity-capability-secret-test-only-0001','UTF8'),'sha256'),
  'haccp.production.training-publication',true,statement_timestamp(),statement_timestamp()+interval '1 hour'),
('ad200000-0000-4000-8000-000000000002',extensions.digest(convert_to(
  'staging-integrity-capability-secret-test-only-00001','UTF8'),'sha256'),
  'haccp.staging.training-publication',true,statement_timestamp(),statement_timestamp()+interval '1 hour'),
('ad200000-0000-4000-8000-000000000003',extensions.digest(convert_to(
  'staging-rotated-capability-secret-test-only-000001','UTF8'),'sha256'),
  'haccp.staging.training-publication',true,statement_timestamp(),statement_timestamp()+interval '1 hour'),
('ad200000-0000-4000-8000-000000000004',extensions.digest(convert_to(
  'revoked-integrity-capability-secret-test-only-000001','UTF8'),'sha256'),
  'haccp.production.training-publication',false,statement_timestamp(),statement_timestamp()+interval '1 hour'),
('ad200000-0000-4000-8000-000000000005',extensions.digest(convert_to(
  'expired-integrity-capability-secret-test-only-000001','UTF8'),'sha256'),
  'haccp.production.training-publication',true,statement_timestamp()-interval '2 hours',
  statement_timestamp()-interval '1 hour');

insert into public.training_courses(id,organization_id,course_key,status,created_by)
select fixture.course_id,scope.organization_id,fixture.course_key,'active','ad100000-0000-4000-8000-000000000001'
from integrity_audience_scope scope
cross join (values
  ('ad300000-0000-4000-8000-000000000001'::uuid,'integrity-audience-production'),
  ('ad300000-0000-4000-8000-000000000002'::uuid,'integrity-audience-staging')
) fixture(course_id,course_key);

insert into public.training_course_versions(
  id,organization_id,course_id,version_number,status,default_locale,supported_locales,
  title_i18n,description_i18n,revision,created_by
)
select fixture.version_id,scope.organization_id,fixture.course_id,1,'draft','en',
  array['en','ar','id','hi','fil'],jsonb_build_object('en',fixture.environment_name),
  jsonb_build_object('en','Audience-bound integrity fixture'),1,
  'ad100000-0000-4000-8000-000000000001'
from integrity_audience_scope scope
cross join (values
  ('ad300000-0000-4000-8000-000000000001'::uuid,'ad400000-0000-4000-8000-000000000001'::uuid,'production'),
  ('ad300000-0000-4000-8000-000000000002'::uuid,'ad400000-0000-4000-8000-000000000002'::uuid,'staging')
) fixture(course_id,version_id,environment_name);

create temporary table integrity_audience_versions as
select scope.organization_id,fixture.environment_name,fixture.course_id,fixture.version_id,
  fixture.submission_id,fixture.run_id,fixture.request_id,fixture.manifest_id,
  fixture.audience,fixture.fingerprint
from integrity_audience_scope scope
cross join (values
  ('production','ad300000-0000-4000-8000-000000000001'::uuid,
    'ad400000-0000-4000-8000-000000000001'::uuid,
    'ad500000-0000-4000-8000-000000000001'::uuid,
    'ad600000-0000-4000-8000-000000000001'::uuid,
    'ad700000-0000-4000-8000-000000000001'::uuid,
    'ad800000-0000-4000-8000-000000000001'::uuid,
    'haccp.production.training-publication',repeat('a',64)),
  ('staging','ad300000-0000-4000-8000-000000000002'::uuid,
    'ad400000-0000-4000-8000-000000000002'::uuid,
    'ad500000-0000-4000-8000-000000000002'::uuid,
    'ad600000-0000-4000-8000-000000000002'::uuid,
    'ad700000-0000-4000-8000-000000000002'::uuid,
    'ad800000-0000-4000-8000-000000000002'::uuid,
    'haccp.staging.training-publication',repeat('b',64))
) fixture(environment_name,course_id,version_id,submission_id,run_id,request_id,manifest_id,audience,fingerprint);

insert into public.training_publication_review_submissions(
  id,organization_id,course_id,course_version_id,version_revision,content_fingerprint,
  submitted_by,action_request_id
)
select submission_id,organization_id,course_id,version_id,1,fingerprint,
  'ad100000-0000-4000-8000-000000000001',
  case environment_name when 'production' then 'ad510000-0000-4000-8000-000000000001'::uuid
    else 'ad510000-0000-4000-8000-000000000002'::uuid end
from integrity_audience_versions;

insert into public.training_storage_verification_runs(
  id,organization_id,course_id,course_version_id,submission_id,version_revision,
  content_fingerprint,challenge_nonce,requested_by,action_request_id,expires_at
)
select run_id,organization_id,course_id,version_id,submission_id,1,fingerprint,
  case environment_name when 'production' then 'ad610000-0000-4000-8000-000000000001'::uuid
    else 'ad610000-0000-4000-8000-000000000002'::uuid end,
  'ad100000-0000-4000-8000-000000000001',
  case environment_name when 'production' then 'ad620000-0000-4000-8000-000000000001'::uuid
    else 'ad620000-0000-4000-8000-000000000002'::uuid end,
  statement_timestamp()+interval '30 minutes'
from integrity_audience_versions;

insert into public.training_publication_requests(
  id,organization_id,course_id,course_version_id,submission_id,verification_run_id,
  version_revision,content_fingerprint,requested_by,action_request_id,protocol_version,
  audience,signing_key_id,authorization_envelope,authorization_signature
)
select request_id,organization_id,course_id,version_id,submission_id,run_id,1,fingerprint,
  'ad100000-0000-4000-8000-000000000001',
  case environment_name when 'production' then 'ad710000-0000-4000-8000-000000000001'::uuid
    else 'ad710000-0000-4000-8000-000000000002'::uuid end,
  1,audience,'audience-test-key','{}'::jsonb,repeat('A',86)||'=='
from integrity_audience_versions;

insert into public.training_media_assets(
  id,organization_id,course_version_id,asset_key,media_type,title_i18n,alt_i18n,
  storage_bucket,storage_object_path,mime_type,byte_size,width,height,sha256,
  source_mime_type,source_byte_size,source_sha256,approval_status,status,created_by
)
select (md5(version.environment_name||':media:'||number)::uuid),version.organization_id,
  version.version_id,'asset-'||lpad(number::text,2,'0'),'image',jsonb_build_object('en','Image'),
  jsonb_build_object('en','Alt'),'training-media',
  'organizations/'||version.organization_id||'/courses/'||version.course_id||'/versions/'||
    version.version_id||'/assets/'||(md5(version.environment_name||':media:'||number)::uuid)||'/'||
    (md5(version.environment_name||':object:'||number)::uuid)||'.webp',
  'image/webp',1000+number,100+number,100+number,
  encode(extensions.digest(convert_to(version.environment_name||':published:'||number,'UTF8'),'sha256'),'hex'),
  'image/webp',1000+number,
  encode(extensions.digest(convert_to(version.environment_name||':source:'||number,'UTF8'),'sha256'),'hex'),
  'submitted','ready','ad100000-0000-4000-8000-000000000001'
from integrity_audience_versions version cross join generate_series(1,40) number;

insert into public.training_publication_media_manifests(
  id,organization_id,course_id,course_version_id,submission_id,verification_run_id,
  publication_request_id,version_revision,content_fingerprint,manifest_fingerprint,
  object_count,verifier_capability_id,completion_request_id,requested_by
)
select manifest_id,organization_id,course_id,version_id,submission_id,run_id,request_id,1,
  fingerprint,case environment_name when 'production' then repeat('c',64) else repeat('d',64) end,
  40,case environment_name when 'production' then 'ad200000-0000-4000-8000-000000000001'::uuid
    else 'ad200000-0000-4000-8000-000000000002'::uuid end,
  case environment_name when 'production' then 'ad810000-0000-4000-8000-000000000001'::uuid
    else 'ad810000-0000-4000-8000-000000000002'::uuid end,
  'ad100000-0000-4000-8000-000000000001'
from integrity_audience_versions;

insert into public.training_publication_media_manifest_items(
  manifest_id,organization_id,course_id,course_version_id,media_id,media_revision,
  module_id,lesson_id,module_position,lesson_position,slot_position,asset_key,
  storage_bucket,storage_object_path,sha256,byte_size,width,height,mime_type
)
select version.manifest_id,version.organization_id,version.course_id,version.version_id,asset.id,
  asset.revision,md5(version.environment_name||':module')::uuid,
  md5(version.environment_name||':lesson:'||number)::uuid,1,number,1,asset.asset_key,
  'training-published-media','sha256/'||substring(asset.sha256 from 1 for 2)||'/'||asset.sha256||'.webp',
  asset.sha256,asset.byte_size,asset.width,asset.height,'image/webp'
from integrity_audience_versions version cross join generate_series(1,40) number
join public.training_media_assets asset
  on asset.id=md5(version.environment_name||':media:'||number)::uuid
 and asset.organization_id=version.organization_id and asset.course_version_id=version.version_id;

insert into private.training_published_media_integrity_jobs(manifest_id,next_due_at)
select manifest_id,case environment_name when 'staging' then statement_timestamp()-interval '1 minute'
  else statement_timestamp()+interval '1 hour' end
from integrity_audience_versions;

-- Fixture-only lifecycle setup. Production code never disables these gates.
alter table public.training_course_versions disable trigger training_course_versions_05_media_publication;
alter table public.training_course_versions disable trigger training_course_versions_02_manifest_publication_gate;
update public.training_course_versions set status='published',published_at=statement_timestamp(),
  published_by='ad100000-0000-4000-8000-000000000001'
where id in(select version_id from integrity_audience_versions);
alter table public.training_course_versions enable trigger training_course_versions_02_manifest_publication_gate;
alter table public.training_course_versions enable trigger training_course_versions_05_media_publication;

select is((select count(*)::integer from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000001',
  'production-integrity-capability-secret-test-only-0001',
  'haccp.production.training-publication','ad900000-0000-4000-8000-000000000001',
  'ad900000-0000-4000-8000-000000000002')),0,
  'production capability cannot claim a staging manifest');

create temporary table staging_integrity_claim as
select * from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000002',
  'staging-integrity-capability-secret-test-only-00001',
  'haccp.staging.training-publication','ad900000-0000-4000-8000-000000000003',
  'ad900000-0000-4000-8000-000000000004');
select is((select count(*)::integer from staging_integrity_claim),40,
  'same-audience staging capability claims all 40 manifest objects');
select ok((select count(distinct manifest_id)=1 and count(distinct lease_token)=1
  from staging_integrity_claim) and (select attempt_count=1
  from private.training_published_media_integrity_jobs
  where manifest_id='ad800000-0000-4000-8000-000000000002'),
  'claim creates one atomic lease for the exact manifest');

update private.training_published_media_integrity_jobs set next_due_at=statement_timestamp()-interval '1 minute'
where manifest_id='ad800000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000002',
  'staging-integrity-capability-secret-test-only-00001',
  'haccp.staging.training-publication','ad900000-0000-4000-8000-000000000005',
  'ad900000-0000-4000-8000-000000000006')),0,
  'staging capability cannot claim a production manifest');

select throws_ok(format($call$select * from public.complete_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000001',
  'production-integrity-capability-secret-test-only-0001',
  'haccp.production.training-publication','ad800000-0000-4000-8000-000000000002',
  %L,'passed',%L::jsonb,null,'ad910000-0000-4000-8000-000000000001')$call$,
  (select lease_token from staging_integrity_claim limit 1),
  (select jsonb_agg(jsonb_build_object('media_id',media_id,'sha256',expected_sha256,
    'byte_size',expected_byte_size,'width',expected_width,'height',expected_height))::text
   from staging_integrity_claim)),
  '42501','Training verifier access denied','cross-audience completion is rejected without target disclosure');

select throws_ok($call$select * from public.complete_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000002',
  'staging-integrity-capability-secret-test-only-00001',
  'haccp.staging.training-publication','ad800000-0000-4000-8000-000000000002',
  null,'failed','[]'::jsonb,'published_media_unavailable',
  'ad910000-0000-4000-8000-000000000004')$call$,
  '55000','Training published media integrity completion is invalid or stale',
  'same-audience completion still requires the exact non-null active lease token');

select lives_ok(format($call$select * from public.complete_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000003',
  'staging-rotated-capability-secret-test-only-000001',
  'haccp.staging.training-publication','ad800000-0000-4000-8000-000000000002',
  %L,'passed',%L::jsonb,null,'ad910000-0000-4000-8000-000000000002')$call$,
  (select lease_token from staging_integrity_claim limit 1),
  (select jsonb_agg(jsonb_build_object('media_id',media_id,'sha256',expected_sha256,
    'byte_size',expected_byte_size,'width',expected_width,'height',expected_height))::text
   from staging_integrity_claim)),
  'rotated active capability may complete a lease for the same immutable audience');
select ok((select status='passed' and checked_object_count=40
  and verifier_capability_id='ad200000-0000-4000-8000-000000000003'
  from public.training_published_media_integrity_runs
  where manifest_id='ad800000-0000-4000-8000-000000000002'),
  'same-audience rotation is recorded without rewriting earlier evidence');
select is((select count(*)::integer from public.training_published_media_integrity_items item
  join public.training_published_media_integrity_runs run on run.id=item.integrity_run_id
  where run.manifest_id='ad800000-0000-4000-8000-000000000002'),40,
  'successful completion preserves exact 40-object evidence validation');

create temporary table production_integrity_claim as
select * from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000001',
  'production-integrity-capability-secret-test-only-0001',
  'haccp.production.training-publication','ad900000-0000-4000-8000-000000000007',
  'ad900000-0000-4000-8000-000000000008');
select is((select count(*)::integer from production_integrity_claim),40,
  'same-audience production capability claims its production manifest');
select is((select count(*)::integer from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000001',
  'production-integrity-capability-secret-test-only-0001',
  'haccp.production.training-publication','ad900000-0000-4000-8000-000000000009',
  'ad900000-0000-4000-8000-000000000010')),0,
  'a concurrent-style second claim cannot acquire the live lease');
select is((select attempt_count from private.training_published_media_integrity_jobs
  where manifest_id='ad800000-0000-4000-8000-000000000001'),1,
  'concurrent polling does not increment or replace an active lease');

select lives_ok(format($call$select * from public.complete_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000001',
  'production-integrity-capability-secret-test-only-0001',
  'haccp.production.training-publication','ad800000-0000-4000-8000-000000000001',
  %L,'passed',%L::jsonb,null,'ad910000-0000-4000-8000-000000000003')$call$,
  (select lease_token from production_integrity_claim limit 1),
  (select jsonb_agg(jsonb_build_object('media_id',media_id,'sha256',expected_sha256,
    'byte_size',expected_byte_size,'width',expected_width,'height',expected_height))::text
   from production_integrity_claim)),
  'same-audience production completion succeeds');
select is((select checked_object_count from public.training_published_media_integrity_runs
  where manifest_id='ad800000-0000-4000-8000-000000000001'),40,
  'production completion records one complete audit');

select throws_ok($call$select * from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000004',
  'revoked-integrity-capability-secret-test-only-000001',
  'haccp.production.training-publication','ad920000-0000-4000-8000-000000000001',
  'ad920000-0000-4000-8000-000000000002')$call$,
  '42501','Training verifier access denied','revoked capability is rejected');
select throws_ok($call$select * from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000005',
  'expired-integrity-capability-secret-test-only-000001',
  'haccp.production.training-publication','ad920000-0000-4000-8000-000000000003',
  'ad920000-0000-4000-8000-000000000004')$call$,
  '42501','Training verifier access denied','expired capability is rejected');
select throws_ok($call$select * from public.claim_training_published_media_integrity_audit(
  'ad200000-0000-4000-8000-000000000001',
  'production-integrity-capability-secret-test-only-0001',
  'haccp.staging.training-publication','ad920000-0000-4000-8000-000000000005',
  'ad920000-0000-4000-8000-000000000006')$call$,
  '42501','Training verifier access denied','capability audience must equal expected audience');

select ok((select proargnames[1:5]=array['target_capability_id','capability_secret','expected_audience',
  'worker_instance_id','claim_request_id']
  from pg_catalog.pg_proc
  where oid='public.claim_training_published_media_integrity_audit(uuid,text,text,uuid,uuid)'::regprocedure)
  and (select proargnames[1:9]=array['target_capability_id','capability_secret','expected_audience',
    'target_manifest_id','target_lease_token','audit_status','observed_objects','failure_code','completion_request_id']
  from pg_catalog.pg_proc
  where oid='public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid)'::regprocedure),
  'corrected RPC parameter names, types, order, and PostgREST signatures are unchanged');
select ok((select bool_and(prosecdef and proconfig @> array['search_path=""'])
  from pg_catalog.pg_proc
  where oid in(
    'public.claim_training_published_media_integrity_audit(uuid,text,text,uuid,uuid)'::regprocedure,
    'public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid)'::regprocedure
  )),
  'corrected RPCs remain SECURITY DEFINER with empty search_path');
select ok(has_function_privilege('anon',
  'public.claim_training_published_media_integrity_audit(uuid,text,text,uuid,uuid)','execute')
  and has_function_privilege('anon',
  'public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid)','execute')
  and not has_function_privilege('authenticated',
  'public.claim_training_published_media_integrity_audit(uuid,text,text,uuid,uuid)','execute')
  and not has_function_privilege('service_role',
  'public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid)','execute'),
  'existing least-privilege capability broker grants are preserved');

select * from finish();
rollback;
