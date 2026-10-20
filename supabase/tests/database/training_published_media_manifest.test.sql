begin;
select plan(29);

select has_table('public','training_publication_media_manifests','published manifest root exists');
select has_table('public','training_publication_media_manifest_items','published manifest items exist');
select has_table('public','training_published_media_integrity_runs','append-only integrity runs exist');
select has_table('public','training_published_media_integrity_items','append-only integrity items exist');
select has_table('private','training_published_media_integrity_jobs','private integrity lease queue exists');

select ok((select not public and file_size_limit=5242880 and allowed_mime_types=array['image/webp']::text[]
  from storage.buckets where id='training-published-media'),
  'published media bucket is private, WebP-only, and limited to 5 MiB');
select ok(exists(select 1 from pg_catalog.pg_policies where schemaname='storage' and tablename='objects'
  and policyname='training_verifier_published_object_read' and cmd='SELECT' and roles='{authenticated}'::name[])
  and exists(select 1 from pg_catalog.pg_policies where schemaname='storage' and tablename='objects'
  and policyname='training_verifier_published_object_insert' and cmd='INSERT' and roles='{authenticated}'::name[]),
  'scoped verifier may select and create published objects');
select ok(not exists(select 1 from pg_catalog.pg_policies where schemaname='storage' and tablename='objects'
  and policyname like 'training_verifier_published_object_%' and cmd in('UPDATE','DELETE')),
  'verifier has no published-object update or delete policy');
select ok(not exists(select 1 from pg_catalog.pg_policies where schemaname='storage' and tablename='objects'
  and policyname like 'training_verifier_published_object_%' and ('anon'=any(roles) or 'service_role'=any(roles))),
  'published object policies are not exposed to anon or ordinary service role');

select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.training_publication_media_manifests'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid='public.training_publication_media_manifest_items'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid='public.training_published_media_integrity_runs'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid='public.training_published_media_integrity_items'::regclass),
  'all public manifest and integrity evidence tables have RLS');
select ok(not has_table_privilege('anon','public.training_publication_media_manifests','select')
  and not has_table_privilege('authenticated','public.training_publication_media_manifests','select')
  and not has_table_privilege('service_role','public.training_publication_media_manifests','select'),
  'application roles cannot directly enumerate immutable manifests');
select has_trigger('public','training_publication_media_manifests','training_publication_media_manifests_immutability','manifest roots are immutable');
select has_trigger('public','training_publication_media_manifest_items','training_publication_media_manifest_items_immutability','manifest items are immutable');
select has_trigger('public','training_published_media_integrity_runs','training_published_media_integrity_runs_immutability','integrity runs are immutable');
select has_trigger('public','training_published_media_integrity_items','training_published_media_integrity_items_immutability','integrity items are immutable');
select has_column('public','training_published_media_integrity_runs','recorded_sequence','integrity evidence has monotonic ordering');

select ok(has_function_privilege('anon','public.finalize_training_storage_verifier_publication(uuid,text,text,uuid,uuid,jsonb,jsonb,text,uuid)','execute')
  and has_function_privilege('anon','public.renew_training_storage_verifier_job_lease(uuid,text,text,uuid,uuid,uuid)','execute')
  and has_function_privilege('anon','public.claim_training_published_media_integrity_audit(uuid,text,text,uuid,uuid)','execute')
  and has_function_privilege('anon','public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid)','execute'),
  'only capability-broker entry points are callable through anon');
select ok(not has_function_privilege('service_role','public.finalize_training_storage_verifier_publication(uuid,text,text,uuid,uuid,jsonb,jsonb,text,uuid)','execute')
  and not has_function_privilege('service_role','public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid)','execute'),
  'ordinary service role cannot finalize publication or integrity evidence');
select ok(not has_function_privilege('anon','public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb)','execute')
  and not has_function_privilege('anon','public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)','execute')
  and not has_function_privilege('service_role','public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb)','execute')
  and not has_function_privilege('service_role','public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)','execute'),
  'Phase 3A completion and publish RPCs remain ungranted');
select ok(has_function_privilege('service_role','public.authorize_training_published_media_read(uuid,uuid,uuid,uuid,uuid)','execute')
  and not has_function_privilege('anon','public.authorize_training_published_media_read(uuid,uuid,uuid,uuid,uuid)','execute')
  and not has_function_privilege('authenticated','public.authorize_training_published_media_read(uuid,uuid,uuid,uuid,uuid)','execute'),
  'official learner media authorization is server-only');

select is((select count(*)::integer from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace
  on namespace.oid=procedure.pronamespace where namespace.nspname in('public','private')
  and procedure.proname in('training_published_media_manifest_fingerprint','renew_training_storage_verifier_job_lease',
    'finalize_training_storage_verifier_publication','claim_training_published_media_integrity_audit',
    'complete_training_published_media_integrity_audit','authorize_training_published_media_read')
  and procedure.prosecdef and procedure.proconfig @> array['search_path=""']),6,
  'every Phase 3C RPC/helper is SECURITY DEFINER with empty search_path');
select ok((select proargnames[1:5]=array['target_organization_id','target_branch_id','target_employee_id','target_enrollment_id','target_media_id']
  from pg_catalog.pg_proc where oid='public.authorize_training_published_media_read(uuid,uuid,uuid,uuid,uuid)'::regprocedure),
  'learner media authorization accepts no object path or bucket from callers');
select ok((select proargnames[1:9]=array['target_capability_id','capability_secret','expected_audience',
  'target_publication_request_id','target_lease_token','source_observed_objects','published_manifest_items',
  'expected_manifest_fingerprint','completion_request_id']
  from pg_catalog.pg_proc where oid='public.finalize_training_storage_verifier_publication(uuid,text,text,uuid,uuid,jsonb,jsonb,text,uuid)'::regprocedure),
  'finalization is capability-, lease-, manifest-, and request-bound');

select throws_ok($call$select * from public.finalize_training_storage_verifier_publication(
  '9d000000-0000-4000-8000-000000000001','wrong-but-long-enough-capability-secret-0001',
  'haccp.test.training-publication','9d000000-0000-4000-8000-000000000002',
  '9d000000-0000-4000-8000-000000000003','[]'::jsonb,'[]'::jsonb,repeat('0',64),
  '9d000000-0000-4000-8000-000000000004')$call$,
  '42501','Training verifier access denied','forged finalization capability is rejected before manifest processing');
select is(length(private.training_published_media_manifest_fingerprint(
  '9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',
  '9d000000-0000-4000-8000-000000000003',1,repeat('a',64),'[]'::jsonb)),64,
  'canonical manifest fingerprint is a SHA-256 hex digest');
with items as (select jsonb_build_array(
  jsonb_build_object('media_id','9d100000-0000-4000-8000-000000000002','media_revision',1,
    'sha256',repeat('b',64),'byte_size',100,'width',10,'height',10,'object_path','sha256/bb/'||repeat('b',64)||'.webp'),
  jsonb_build_object('media_id','9d100000-0000-4000-8000-000000000001','media_revision',1,
    'sha256',repeat('c',64),'byte_size',101,'width',11,'height',11,'object_path','sha256/cc/'||repeat('c',64)||'.webp')) value)
select is(private.training_published_media_manifest_fingerprint(
  '9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',
  '9d000000-0000-4000-8000-000000000003',1,repeat('a',64),value),
  private.training_published_media_manifest_fingerprint(
  '9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',
  '9d000000-0000-4000-8000-000000000003',1,repeat('a',64),
  jsonb_build_array(value->1,value->0)),'fingerprint is reproducible regardless of JSON item order') from items;
select isnt(private.training_published_media_manifest_fingerprint(
  '9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',
  '9d000000-0000-4000-8000-000000000003',1,repeat('a',64),jsonb_build_array(
    jsonb_build_object('media_id','9d100000-0000-4000-8000-000000000001','media_revision',1,
      'sha256',repeat('b',64),'byte_size',100,'width',10,'height',10,'object_path','sha256/bb/'||repeat('b',64)||'.webp'))),
  private.training_published_media_manifest_fingerprint(
  '9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',
  '9d000000-0000-4000-8000-000000000003',1,repeat('a',64),jsonb_build_array(
    jsonb_build_object('media_id','9d100000-0000-4000-8000-000000000001','media_revision',1,
      'sha256',repeat('b',64),'byte_size',100,'width',10,'height',10,'object_path','sha256/bb/'||repeat('b',64)||'-changed.webp'))),
  'object-path substitution changes the bound manifest fingerprint');

select ok((select publication_media_manifest_id is null and publication_media_manifest_fingerprint is null
  from public.training_course_versions where status='draft' order by created_at limit 1),
  'existing draft versions remain unbound and draft-preview compatible');
select is((select integrity_freshness_seconds from private.training_published_media_configuration
  where singleton),86400,'integrity evidence freshness defaults to 24 hours');

select * from finish();
rollback;
