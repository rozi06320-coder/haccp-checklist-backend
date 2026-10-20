begin;
select plan(43);

select has_table('private','training_verifier_capabilities','private verifier capability registry exists');
select has_table('public','training_publication_requests','immutable publication request table exists');
select has_table('public','training_verifier_jobs','mutable verifier lease table exists');
select has_table('public','training_verifier_events','append-only verifier event table exists');
select has_table('private','training_verifier_source_observations','immutable source observations exist');
select ok(not exists(select 1 from pg_catalog.pg_roles where rolname='training_storage_verifier'),
  'migration provisions no verifier PostgreSQL role or LOGIN');

select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.training_publication_requests'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid='public.training_verifier_jobs'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid='public.training_verifier_events'::regclass),
  'all public verifier tables have RLS');
select ok(not has_table_privilege('service_role','public.training_publication_requests','select')
  and not has_table_privilege('service_role','public.training_verifier_jobs','select')
  and not has_table_privilege('service_role','public.training_verifier_events','select'),
  'ordinary service role has no direct queue or event reads');
select ok(not has_table_privilege('anon','private.training_verifier_capabilities','select')
  and not has_table_privilege('authenticated','private.training_verifier_capabilities','select')
  and not has_table_privilege('service_role','private.training_verifier_capabilities','select'),
  'capability digests are not readable through application roles');

select ok(has_function_privilege('service_role','public.get_internal_admin_training_publication_history(uuid,uuid,uuid,uuid)','execute')
  and has_function_privilege('service_role','public.get_internal_admin_training_publication_signing_context(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text)','execute')
  and has_function_privilege('service_role','public.request_internal_admin_training_publication(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid,jsonb,text)','execute'),
  'ordinary API may only orchestrate authenticated admin history, signing context, and queueing');
select ok(not has_function_privilege('service_role','public.claim_training_storage_verifier_job(uuid,text,text,uuid,uuid)','execute')
  and not has_function_privilege('service_role','public.fail_training_storage_verifier_job(uuid,text,text,uuid,uuid,text,boolean,uuid)','execute')
  and not has_function_privilege('service_role','public.block_training_storage_verifier_job_after_source_verification(uuid,text,text,uuid,uuid,jsonb,uuid)','execute'),
  'ordinary service role cannot execute verifier broker RPCs');
select ok(has_function_privilege('anon','public.claim_training_storage_verifier_job(uuid,text,text,uuid,uuid)','execute')
  and has_function_privilege('anon','public.fail_training_storage_verifier_job(uuid,text,text,uuid,uuid,text,boolean,uuid)','execute')
  and has_function_privilege('anon','public.block_training_storage_verifier_job_after_source_verification(uuid,text,text,uuid,uuid,jsonb,uuid)','execute'),
  'broker entry points are reachable only through their independent secret check');
select ok(not has_function_privilege('anon','public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb)','execute')
  and not has_function_privilege('anon','public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)','execute')
  and not has_function_privilege('service_role','public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb)','execute')
  and not has_function_privilege('service_role','public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)','execute'),
  'Phase 3A verification completion and publication remain ungranted');

select is((select count(*)::integer from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace
  on namespace.oid=procedure.pronamespace where namespace.nspname in('public','private')
  and procedure.proname in('training_verifier_storage_claim_is_active','assert_training_verifier_capability',
    'get_internal_admin_training_publication_history','get_internal_admin_training_publication_signing_context',
    'request_internal_admin_training_publication','claim_training_storage_verifier_job',
    'fail_training_storage_verifier_job','block_training_storage_verifier_job_after_source_verification')
  and procedure.prosecdef and procedure.proconfig @> array['search_path=""']),8,
  'every new function is SECURITY DEFINER with empty search_path');
select has_trigger('public','training_publication_requests','training_publication_requests_immutability','requests are immutable');
select has_trigger('public','training_verifier_events','training_verifier_events_immutability','events are immutable');
select has_trigger('private','training_verifier_source_observations','training_verifier_source_observations_immutability','observations are immutable');
select ok(exists(select 1 from pg_catalog.pg_policies where schemaname='storage' and tablename='objects'
  and policyname='training_verifier_source_object_read' and cmd='SELECT'
  and roles='{authenticated}'::name[]),'worker Storage policy is authenticated SELECT only');
select ok(not exists(select 1 from pg_catalog.pg_policies where schemaname='storage' and tablename='objects'
  and policyname like 'training_verifier_source_object_%' and cmd<>'SELECT'),
  'worker has no Storage write or delete policy');

insert into private.training_verifier_capabilities(id,secret_sha256,audience,expires_at) values(
  '9c000000-0000-4000-8000-000000000001',
  extensions.digest(convert_to('a-very-long-test-only-verifier-capability-secret-0001','UTF8'),'sha256'),
  'haccp.test.training-publication',statement_timestamp()+interval '1 hour'
);
select throws_ok($call$select * from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','wrong-but-still-long-enough-capability-secret-0001',
  'haccp.test.training-publication','9c000000-0000-4000-8000-000000000002','9c000000-0000-4000-8000-000000000003')$call$,
  '42501','Training verifier access denied','wrong verifier secret is rejected');
select throws_ok($call$select * from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.other.training-publication','9c000000-0000-4000-8000-000000000002','9c000000-0000-4000-8000-000000000003')$call$,
  '42501','Training verifier access denied','cross-environment capability replay is rejected');
select is((select count(*)::integer from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c000000-0000-4000-8000-000000000002','9c000000-0000-4000-8000-000000000003')),0,
  'valid capability safely observes an empty queue');

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','9c100000-0000-4000-8000-000000000001','authenticated',
  'authenticated','phase3b-verifier-fixture@example.invalid','{}','{}',now(),now());
insert into public.internal_admin_memberships(user_id,active)
values('9c100000-0000-4000-8000-000000000001',true);
create temporary table verifier_scope as select course.organization_id,course.id course_id,version.id version_id,
  version.revision,private.training_publication_content_fingerprint(course.organization_id,course.id,version.id) fingerprint
from public.training_courses course join public.training_course_versions version
  on version.course_id=course.id and version.organization_id=course.organization_id
where course.course_key='baladiyah-food-safety-hygiene' and version.version_number=1 and version.status='draft' limit 1;
insert into public.training_publication_review_submissions(id,organization_id,course_id,course_version_id,
  version_revision,content_fingerprint,submitted_by,action_request_id)
select '9c200000-0000-4000-8000-000000000001',organization_id,course_id,version_id,revision,fingerprint,
  '9c100000-0000-4000-8000-000000000001','9c200000-0000-4000-8000-000000000002' from verifier_scope;
insert into public.training_storage_verification_runs(id,organization_id,course_id,course_version_id,submission_id,
  version_revision,content_fingerprint,challenge_nonce,requested_by,action_request_id,expires_at)
select '9c300000-0000-4000-8000-000000000001',organization_id,course_id,version_id,
  '9c200000-0000-4000-8000-000000000001',revision,fingerprint,'9c300000-0000-4000-8000-000000000002',
  '9c100000-0000-4000-8000-000000000001','9c300000-0000-4000-8000-000000000003',statement_timestamp()+interval '10 minutes'
from verifier_scope;
insert into public.training_publication_requests(id,organization_id,course_id,course_version_id,submission_id,
  verification_run_id,version_revision,content_fingerprint,requested_by,action_request_id,protocol_version,
  audience,signing_key_id,authorization_envelope,authorization_signature)
select '9c400000-0000-4000-8000-000000000001',organization_id,course_id,version_id,
  '9c200000-0000-4000-8000-000000000001','9c300000-0000-4000-8000-000000000001',revision,fingerprint,
  '9c100000-0000-4000-8000-000000000001','9c400000-0000-4000-8000-000000000002',1,
  'haccp.test.training-publication','test-key','{}'::jsonb,repeat('A',86)||'==' from verifier_scope;
insert into public.training_verifier_jobs(publication_request_id) values('9c400000-0000-4000-8000-000000000001');

select is((select count(*)::integer from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c500000-0000-4000-8000-000000000001','9c500000-0000-4000-8000-000000000002')),0,
  'claim with a deliberately empty fixture manifest returns no private objects');
select ok((select state='leased' and attempt_count=1 from public.training_verifier_jobs
  where publication_request_id='9c400000-0000-4000-8000-000000000001')
  and (select count(*)=1 from public.training_verifier_events where publication_request_id='9c400000-0000-4000-8000-000000000001'
    and event_type='claimed'),'first worker atomically owns one bounded lease');
select is((select count(*)::integer from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c500000-0000-4000-8000-000000000009','9c500000-0000-4000-8000-000000000010')),0,
  'a concurrent-style second claimant receives no live leased job');
select is((select attempt_count from public.training_verifier_jobs where publication_request_id='9c400000-0000-4000-8000-000000000001'),1,
  'a second poll cannot double-claim a live lease');
update public.training_verifier_jobs set lease_expires_at=statement_timestamp()-interval '1 second'
where publication_request_id='9c400000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c500000-0000-4000-8000-000000000003','9c500000-0000-4000-8000-000000000004')),0,
  'expired first lease is reclaimed atomically');
select ok((select attempt_count=2 and state='leased' from public.training_verifier_jobs
  where publication_request_id='9c400000-0000-4000-8000-000000000001')
  and (select count(*)=1 from public.training_verifier_events where publication_request_id='9c400000-0000-4000-8000-000000000001'
    and event_type='lease_expired'),'worker crash produces an append-only lease-expiry event and deterministic retry');
update public.training_verifier_jobs set lease_expires_at=statement_timestamp()-interval '1 second'
where publication_request_id='9c400000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c500000-0000-4000-8000-000000000005','9c500000-0000-4000-8000-000000000006')),0,
  'expired second lease is reclaimed for the final attempt');
select is((select attempt_count from public.training_verifier_jobs where publication_request_id='9c400000-0000-4000-8000-000000000001'),3,
  'retry count is bounded at the configured maximum');
update public.training_verifier_jobs set lease_expires_at=statement_timestamp()-interval '1 second'
where publication_request_id='9c400000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c500000-0000-4000-8000-000000000007','9c500000-0000-4000-8000-000000000008')),0,
  'expired final lease produces no new claimed manifest');
select ok((select state='terminal_failed' and attempt_count=3 and last_failure_code='retry_limit_exhausted'
    from public.training_verifier_jobs where publication_request_id='9c400000-0000-4000-8000-000000000001')
  and (select count(*)=1 from public.training_verifier_events where publication_request_id='9c400000-0000-4000-8000-000000000001'
    and event_type='terminal_failure'),'expired third lease terminates exactly once instead of retrying forever');
select ok((select status='pending' and verified_at is null and consumed_at is null from public.training_storage_verification_runs
  where id='9c300000-0000-4000-8000-000000000001')
  and (select status='draft' from public.training_course_versions where id=(select version_id from verifier_scope)),
  'all worker crash/retry outcomes leave Phase 3A verification pending and the course draft');
insert into public.training_storage_verification_runs(id,organization_id,course_id,course_version_id,submission_id,
  version_revision,content_fingerprint,challenge_nonce,requested_by,action_request_id,expires_at)
select '9c300000-0000-4000-8000-000000000011',organization_id,course_id,version_id,
  '9c200000-0000-4000-8000-000000000001',revision,fingerprint,'9c300000-0000-4000-8000-000000000012',
  '9c100000-0000-4000-8000-000000000001','9c300000-0000-4000-8000-000000000013',statement_timestamp()+interval '10 minutes'
from verifier_scope;
insert into public.training_publication_requests(id,organization_id,course_id,course_version_id,submission_id,
  verification_run_id,version_revision,content_fingerprint,requested_by,action_request_id,protocol_version,
  audience,signing_key_id,authorization_envelope,authorization_signature)
select '9c400000-0000-4000-8000-000000000011',organization_id,course_id,version_id,
  '9c200000-0000-4000-8000-000000000001','9c300000-0000-4000-8000-000000000011',revision,fingerprint,
  '9c100000-0000-4000-8000-000000000001','9c400000-0000-4000-8000-000000000012',1,
  'haccp.test.training-publication','test-key','{}'::jsonb,repeat('A',86)||'==' from verifier_scope;
insert into public.training_verifier_jobs(publication_request_id) values('9c400000-0000-4000-8000-000000000011');
update public.training_lessons set title_i18n=jsonb_set(title_i18n,'{en}','"Stale verifier fixture"'),
  updated_by='9c100000-0000-4000-8000-000000000001'
where id=(select lesson.id from public.training_lessons lesson where lesson.course_version_id=(select version_id from verifier_scope)
  order by lesson.id limit 1);
select is((select count(*)::integer from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c500000-0000-4000-8000-000000000011','9c500000-0000-4000-8000-000000000012')),0,
  'stale queued fingerprint exposes no private manifest');
select ok((select state='terminal_failed' and last_failure_code='publication_request_stale'
    from public.training_verifier_jobs where publication_request_id='9c400000-0000-4000-8000-000000000011')
  and (select count(*)=1 from public.training_verifier_events where publication_request_id='9c400000-0000-4000-8000-000000000011'
    and event_type='terminal_failure' and failure_code='publication_request_stale'),
  'locked claim rejects curriculum or media metadata changed after queueing');
select lives_ok(format($call$select * from public.get_internal_admin_training_publication_history(
  '9c100000-0000-4000-8000-000000000001',%L,%L,%L)$call$,(select organization_id from verifier_scope),
  (select course_id from verifier_scope),(select version_id from verifier_scope)),
  'authorized Internal Admin reads only the exact course-version history');
select throws_ok(format($call$select * from public.get_internal_admin_training_publication_history(
  '9c100000-0000-4000-8000-000000000001','9c900000-0000-4000-8000-000000000001',%L,%L)$call$,
  (select course_id from verifier_scope),(select version_id from verifier_scope)),
  'P0002','Training course version not found','history rejects cross-organization scope');
select throws_ok(format($call$select * from public.get_internal_admin_training_publication_history(
  '9c100000-0000-4000-8000-000000000099',%L,%L,%L)$call$,(select organization_id from verifier_scope),
  (select course_id from verifier_scope),(select version_id from verifier_scope)),
  '42501','Training publication access denied','history rejects a forged or unauthorized actor');

update private.training_verifier_capabilities set active=false where id='9c000000-0000-4000-8000-000000000001';
select throws_ok($call$select * from public.claim_training_storage_verifier_job(
  '9c000000-0000-4000-8000-000000000001','a-very-long-test-only-verifier-capability-secret-0001',
  'haccp.test.training-publication','9c000000-0000-4000-8000-000000000002','9c000000-0000-4000-8000-000000000003')$call$,
  '42501','Training verifier access denied','revoked capability is rejected');

select ok((select proargnames=array['actor_user_id','target_organization_id','target_course_id','target_course_version_id',
  'target_submission_id','target_verification_run_id','expected_revision','expected_content_fingerprint',
  'challenge_nonce','issued_at_epoch_seconds','expires_at_epoch_seconds']
  from pg_catalog.pg_proc where oid='public.get_internal_admin_training_publication_signing_context(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text)'::regprocedure),
  'signing context RPC has the exact stable input/output parameter contract');
select ok((select proargnames[1:5]=array['target_capability_id','capability_secret','expected_audience','worker_instance_id','claim_request_id']
  from pg_catalog.pg_proc where oid='public.claim_training_storage_verifier_job(uuid,text,text,uuid,uuid)'::regprocedure),
  'claim RPC accepts no actor identity or client-selected organization');
select ok((select proargnames[1:8]=array['target_capability_id','capability_secret','expected_audience',
  'target_publication_request_id','target_lease_token','failure_code','retryable','failure_request_id']
  from pg_catalog.pg_proc where oid='public.fail_training_storage_verifier_job(uuid,text,text,uuid,uuid,text,boolean,uuid)'::regprocedure),
  'failure RPC is lease-bound and correlation-bound');
select ok((select pg_get_functiondef('public.block_training_storage_verifier_job_after_source_verification(uuid,text,text,uuid,uuid,jsonb,uuid)'::regprocedure)
  not like '%complete_internal_admin_training_storage_verification(%'
  and pg_get_functiondef('public.block_training_storage_verifier_job_after_source_verification(uuid,text,text,uuid,uuid,jsonb,uuid)'::regprocedure)
  not like '%publish_internal_admin_training_course_version(%'),
  'source verification cannot indirectly complete or publish Phase 3A');

select * from finish();
rollback;
