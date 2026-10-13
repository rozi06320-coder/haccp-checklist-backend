begin;
select plan(56);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('2a100000-0000-4000-8000-000000000001'::uuid, 'lms-foundation-admin@example.invalid'),
  ('2a100000-0000-4000-8000-000000000002'::uuid, 'lms-foundation-user@example.invalid')
) users(id,email);

update public.profiles
set full_name='Training LMS Foundation Test',must_change_password=false
where id::text like '2a100000-%';

insert into public.internal_admin_memberships(user_id,active,created_by,updated_by)
values(
  '2a100000-0000-4000-8000-000000000001',true,
  '2a100000-0000-4000-8000-000000000001','2a100000-0000-4000-8000-000000000001'
);

insert into public.organizations(id,name,slug) values
  ('2a200000-0000-4000-8000-000000000001','Training LMS Org A','training-lms-org-a'),
  ('2a200000-0000-4000-8000-000000000002','Training LMS Org B','training-lms-org-b');

insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('2a300000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001','Training LMS Branch A','TLMA','Asia/Riyadh',true),
  ('2a300000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000002','Training LMS Branch B','TLMB','Asia/Riyadh',true);

insert into public.operational_staff(
  id,organization_id,branch_id,display_name,employment_status,created_by,staff_code
) values
  ('2a400000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001','2a300000-0000-4000-8000-000000000001','Training Employee A','active','2a100000-0000-4000-8000-000000000001','LMS-A'),
  ('2a400000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000002','2a300000-0000-4000-8000-000000000002','Training Employee B','active','2a100000-0000-4000-8000-000000000001','LMS-B');

select is(
  (select count(*)::integer from information_schema.tables
   where table_schema='public' and table_name in(
     'operational_staff_training_credentials','training_learner_sessions','training_courses',
     'training_course_versions','training_modules','training_lessons'
   )),6,'all six Phase 2A foundation tables exist');

select is(
  (select count(*)::integer from information_schema.columns
   where table_schema='public' and table_name='operational_staff_training_credentials'
     and column_name in('pin','plaintext_pin','plain_text_pin')),0,
  'credential table has no plaintext PIN column');

select throws_like($$
  insert into public.operational_staff_training_credentials(
    employee_id,organization_id,pin_hash,salt,kdf_version,cost,block_size,parallelization,credential_version
  ) values(
    '2a400000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000002',
    chr(92)||'x'||repeat('11',32),chr(92)||'x'||repeat('22',16),1,16384,8,1,gen_random_uuid()
  )
$$,'%violates foreign key constraint "operational_staff_training_credentials_employee_org_fkey"%',
  'credential employee and organization scope is enforced');

select throws_like($$
  insert into public.operational_staff_training_credentials(
    employee_id,organization_id,pin_hash,salt,kdf_version,cost,block_size,parallelization,credential_version
  ) values(
    '2a400000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
    chr(92)||'x'||repeat('11',32),chr(92)||'x'||repeat('22',16),1,16384,8,1,null
  )
$$,'%null value in column "credential_version"%',
  'credential version is required');

select throws_ok($$
  select * from public.store_internal_admin_operational_staff_training_credential(
    '2a100000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000001',
    '2a400000-0000-4000-8000-000000000001',
    chr(92)||'x'||repeat('11',32),chr(92)||'x'||repeat('22',16),1,16384,8,1
  )
$$,'42501','Access denied','non-admin cannot store an employee Training credential');

select throws_ok($$
  select * from public.store_internal_admin_operational_staff_training_credential(
    '2a100000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000002',
    '2a400000-0000-4000-8000-000000000001',
    chr(92)||'x'||repeat('11',32),chr(92)||'x'||repeat('22',16),1,16384,8,1
  )
$$,'P0002','Employee not found','credential RPC enforces employee organization scope');

select lives_ok($$
  select * from public.store_internal_admin_operational_staff_training_credential(
    '2a100000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
    '2a400000-0000-4000-8000-000000000001',
    chr(92)||'x'||repeat('11',32),chr(92)||'x'||repeat('22',16),1,16384,8,1
  )
$$,'Internal Admin can store an employee Training credential');

select is(
  (select status from public.operational_staff_training_credentials
   where employee_id='2a400000-0000-4000-8000-000000000001'),
  'active','stored credential is active');

select ok(
  (select credential_version is not null
     and failed_attempt_count=0 and locked_until is null
   from public.operational_staff_training_credentials
   where employee_id='2a400000-0000-4000-8000-000000000001'),
  'stored credential has a version and reset lock state');

select set_config('test.lms_credential_version',(
  select credential_version::text
  from public.operational_staff_training_credentials
  where employee_id='2a400000-0000-4000-8000-000000000001'
),false);

select throws_like($$
  insert into public.training_learner_sessions(
    organization_id,employee_id,branch_id_at_auth,credential_version,expires_at
  ) values(
    '2a200000-0000-4000-8000-000000000002','2a400000-0000-4000-8000-000000000001',
    '2a300000-0000-4000-8000-000000000002',current_setting('test.lms_credential_version')::uuid,now()+interval '1 hour'
  )
$$,'%violates foreign key constraint "training_learner_sessions_employee_org_fkey"%',
  'learner session employee and organization scope is enforced');

select throws_like($$
  insert into public.training_learner_sessions(
    organization_id,employee_id,branch_id_at_auth,credential_version,expires_at
  ) values(
    '2a200000-0000-4000-8000-000000000001','2a400000-0000-4000-8000-000000000001',
    '2a300000-0000-4000-8000-000000000002',current_setting('test.lms_credential_version')::uuid,now()+interval '1 hour'
  )
$$,'%violates foreign key constraint "training_learner_sessions_branch_org_fkey"%',
  'learner session branch and organization scope is enforced');

select throws_like($$
  insert into public.training_learner_sessions(
    organization_id,employee_id,branch_id_at_auth,credential_version,issued_at,expires_at
  ) values(
    '2a200000-0000-4000-8000-000000000001','2a400000-0000-4000-8000-000000000001',
    '2a300000-0000-4000-8000-000000000001',current_setting('test.lms_credential_version')::uuid,now(),now()
  )
$$,'%violates check constraint "training_learner_sessions_expiry_check"%',
  'learner session expiry must be after issue time');

insert into public.training_learner_sessions(
  id,organization_id,employee_id,branch_id_at_auth,credential_version,issued_at,expires_at
) values(
  '2a500000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
  '2a400000-0000-4000-8000-000000000001','2a300000-0000-4000-8000-000000000001',
  current_setting('test.lms_credential_version')::uuid,now(),now()+interval '1 hour'
);

select lives_ok($$
  select * from public.store_internal_admin_operational_staff_training_credential(
    '2a100000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
    '2a400000-0000-4000-8000-000000000001',
    chr(92)||'x'||repeat('33',32),chr(92)||'x'||repeat('44',16),1,16384,8,1
  )
$$,'credential reset succeeds');

select isnt(
  (select credential_version::text from public.operational_staff_training_credentials
   where employee_id='2a400000-0000-4000-8000-000000000001'),
  current_setting('test.lms_credential_version'),
  'credential reset rotates credential_version');

select ok(
  (select revoked_at is not null from public.training_learner_sessions
   where id='2a500000-0000-4000-8000-000000000001'),
  'credential reset revokes existing persistent sessions');

select ok(
  not (select to_jsonb(status_row)::text ~ '(pin_hash|salt|plaintext|"pin")'
       from public.get_internal_admin_operational_staff_training_credential_status(
         '2a100000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
         '2a400000-0000-4000-8000-000000000001'
       ) status_row),
  'credential status RPC never returns PIN, hash, or salt fields');

select ok(
  (select configured and status='active' and credential_version is not null
   from public.get_internal_admin_operational_staff_training_credential_status(
     '2a100000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
     '2a400000-0000-4000-8000-000000000001'
   )),
  'safe credential status reports configured active state');

select throws_ok($$
  select * from public.get_internal_admin_operational_staff_training_credential_status(
    '2a100000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000001',
    '2a400000-0000-4000-8000-000000000001'
  )
$$,'42501','Access denied','non-admin cannot read credential status');

select set_config('test.lms_reset_version',(
  select credential_version::text
  from public.operational_staff_training_credentials
  where employee_id='2a400000-0000-4000-8000-000000000001'
),false);

insert into public.training_learner_sessions(
  id,organization_id,employee_id,branch_id_at_auth,credential_version,issued_at,expires_at
) values(
  '2a500000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000001',
  '2a400000-0000-4000-8000-000000000001','2a300000-0000-4000-8000-000000000001',
  current_setting('test.lms_reset_version')::uuid,now(),now()+interval '1 hour'
);

select lives_ok($$
  select * from public.revoke_internal_admin_operational_staff_training_credential(
    '2a100000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
    '2a400000-0000-4000-8000-000000000001'
  )
$$,'Internal Admin can revoke an employee Training credential');

select is(
  (select status from public.operational_staff_training_credentials
   where employee_id='2a400000-0000-4000-8000-000000000001'),
  'revoked','revoked is a valid credential state');

select isnt(
  (select credential_version::text from public.operational_staff_training_credentials
   where employee_id='2a400000-0000-4000-8000-000000000001'),
  current_setting('test.lms_reset_version'),
  'credential revocation rotates credential_version');

select ok(
  (select revoked_at is not null from public.training_learner_sessions
   where id='2a500000-0000-4000-8000-000000000002'),
  'credential revocation revokes existing persistent sessions');

select is(
  (select count(*)::integer from public.operational_staff_training_credentials
   where employee_id='2a400000-0000-4000-8000-000000000001' and status='active'),
  0,'revoked credential cannot be treated as active');

select lives_ok($$
  select * from public.revoke_internal_admin_operational_staff_training_credential(
    '2a100000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
    '2a400000-0000-4000-8000-000000000001'
  )
$$,'credential revocation is idempotent');

insert into public.training_courses(id,organization_id,course_key,status,created_by,updated_by) values
  ('2a600000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001','food-safety','active','2a100000-0000-4000-8000-000000000001','2a100000-0000-4000-8000-000000000001'),
  ('2a600000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000002','food-safety','active','2a100000-0000-4000-8000-000000000001','2a100000-0000-4000-8000-000000000001');

select lives_ok($$
  insert into public.training_courses(organization_id,course_key,status)
  values('2a200000-0000-4000-8000-000000000002','branch-safety','active')
$$,'course keys are organization scoped');

select throws_like($$
  insert into public.training_courses(organization_id,course_key,status)
  values('2a200000-0000-4000-8000-000000000001','food-safety','active')
$$,'%duplicate key value violates unique constraint "training_courses_organization_course_key_key"%',
  'course key is unique within an organization');

select throws_like($$
  insert into public.training_course_versions(
    organization_id,course_id,version_number,status,default_locale,supported_locales
  ) values(
    '2a200000-0000-4000-8000-000000000002','2a600000-0000-4000-8000-000000000001',1,'draft','en',array['en']
  )
$$,'%violates foreign key constraint "training_course_versions_course_org_fkey"%',
  'course version cannot cross organization boundaries');

insert into public.training_course_versions(
  id,organization_id,course_id,version_number,status,default_locale,supported_locales,
  title_i18n,description_i18n,created_by,updated_by
) values(
  '2a700000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
  '2a600000-0000-4000-8000-000000000001',1,'draft','en',array['en','ar','id','hi','fil'],
  '{"en":"Food Safety"}','{"en":"Foundation"}',
  '2a100000-0000-4000-8000-000000000001','2a100000-0000-4000-8000-000000000001'
);

select throws_like($$
  insert into public.training_course_versions(
    organization_id,course_id,version_number,status,default_locale,supported_locales,
    published_at,published_by
  ) values(
    '2a200000-0000-4000-8000-000000000001','2a600000-0000-4000-8000-000000000001',1,
    'published','en',array['en'],now(),'2a100000-0000-4000-8000-000000000001'
  )
$$,'%duplicate key value violates unique constraint "training_course_versions_course_number_key"%',
  'version number is unique per course');

select throws_like($$
  insert into public.training_course_versions(
    organization_id,course_id,version_number,status,default_locale,supported_locales
  ) values(
    '2a200000-0000-4000-8000-000000000002','2a600000-0000-4000-8000-000000000002',1,
    'draft','en',array[]::text[]
  )
$$,'%violates check constraint "training_course_versions_locales_check"%',
  'supported locale arrays cannot be empty');

select throws_like($$
  insert into public.training_modules(
    organization_id,course_version_id,stable_key,position,title_i18n
  ) values(
    '2a200000-0000-4000-8000-000000000002','2a700000-0000-4000-8000-000000000001','wrong-org',0,'{}'
  )
$$,'%violates foreign key constraint "training_modules_version_org_fkey"%',
  'module organization must match its course version');

insert into public.training_modules(
  id,organization_id,course_version_id,stable_key,position,category_key,title_i18n,description_i18n,metadata
) values(
  '2a800000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
  '2a700000-0000-4000-8000-000000000001','personal-hygiene',0,'hygiene','{}','{}','{}'
);

select throws_like($$
  insert into public.training_modules(organization_id,course_version_id,stable_key,position)
  values('2a200000-0000-4000-8000-000000000001','2a700000-0000-4000-8000-000000000001','personal-hygiene',1)
$$,'%duplicate key value violates unique constraint "training_modules_version_stable_key_key"%',
  'module stable key is unique per version');

select throws_like($$
  insert into public.training_lessons(
    organization_id,course_version_id,module_id,stable_key,position,lesson_type
  ) values(
    '2a200000-0000-4000-8000-000000000002','2a700000-0000-4000-8000-000000000001',
    '2a800000-0000-4000-8000-000000000001','wrong-org',0,'reading'
  )
$$,'%violates foreign key constraint%',
  'lesson organization/version/module consistency is enforced');

insert into public.training_lessons(
  id,organization_id,course_version_id,module_id,stable_key,position,lesson_type,
  title_i18n,objective_i18n,content_i18n
) values(
  '2a900000-0000-4000-8000-000000000001','2a200000-0000-4000-8000-000000000001',
  '2a700000-0000-4000-8000-000000000001','2a800000-0000-4000-8000-000000000001',
  'personal-hygiene-overview',0,'reading','{}','{}','{}'
);

select throws_like($$
  insert into public.training_lessons(
    organization_id,course_version_id,module_id,stable_key,position,lesson_type
  ) values(
    '2a200000-0000-4000-8000-000000000001','2a700000-0000-4000-8000-000000000001',
    '2a800000-0000-4000-8000-000000000001','personal-hygiene-overview',1,'reading'
  )
$$,'%duplicate key value violates unique constraint "training_lessons_module_stable_key_key"%',
  'lesson stable key is unique per module');

insert into public.training_lessons(
  id,organization_id,course_version_id,module_id,stable_key,position,lesson_type,max_attempts
) values(
  '2a900000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000001',
  '2a700000-0000-4000-8000-000000000001','2a800000-0000-4000-8000-000000000001',
  'personal-hygiene-quiz',1,'quiz',3
);

select is(
  (select pass_threshold_bps from public.training_lessons where id='2a900000-0000-4000-8000-000000000002'),
  8000,'quiz lessons default to the approved 80 percent threshold');

select throws_like($$
  insert into public.training_lessons(
    organization_id,course_version_id,module_id,stable_key,position,lesson_type,pass_threshold_bps
  ) values(
    '2a200000-0000-4000-8000-000000000001','2a700000-0000-4000-8000-000000000001',
    '2a800000-0000-4000-8000-000000000001','invalid-threshold',2,'quiz',10001
  )
$$,'%violates check constraint "training_lessons_pass_threshold_check"%',
  'quiz pass threshold must be between zero and 10000 basis points');

select throws_like($$
  insert into public.training_lessons(
    organization_id,course_version_id,module_id,stable_key,position,lesson_type,max_attempts
  ) values(
    '2a200000-0000-4000-8000-000000000001','2a700000-0000-4000-8000-000000000001',
    '2a800000-0000-4000-8000-000000000001','invalid-attempts',2,'quiz',0
  )
$$,'%violates check constraint "training_lessons_max_attempts_check"%',
  'quiz max attempts must be null or positive');

select lives_ok($$
  update public.training_modules set category_key='food-safety'
  where id='2a800000-0000-4000-8000-000000000001'
$$,'draft module remains editable');
select lives_ok($$
  update public.training_lessons set minimum_engagement_seconds=10
  where id='2a900000-0000-4000-8000-000000000001'
$$,'draft lesson remains editable');

update public.training_course_versions
set status='published',published_at=now(),published_by='2a100000-0000-4000-8000-000000000001',
    content_hash='phase-2a-test',revision=1
where id='2a700000-0000-4000-8000-000000000001';

select throws_ok($$
  update public.training_modules set category_key='changed'
  where id='2a800000-0000-4000-8000-000000000001'
$$,'55000','Published or retired Training content is immutable','published module update is rejected');
select throws_ok($$
  insert into public.training_modules(organization_id,course_version_id,stable_key,position)
  values('2a200000-0000-4000-8000-000000000001','2a700000-0000-4000-8000-000000000001','late-module',4)
$$,'55000','Published or retired Training content is immutable','published module insert is rejected');
select throws_ok($$
  delete from public.training_modules where id='2a800000-0000-4000-8000-000000000001'
$$,'55000','Published or retired Training content is immutable','published module delete is rejected');
select throws_ok($$
  update public.training_lessons set required=false
  where id='2a900000-0000-4000-8000-000000000001'
$$,'55000','Published or retired Training content is immutable','published lesson update is rejected');
select throws_ok($$
  insert into public.training_lessons(
    organization_id,course_version_id,module_id,stable_key,position,lesson_type
  ) values(
    '2a200000-0000-4000-8000-000000000001','2a700000-0000-4000-8000-000000000001',
    '2a800000-0000-4000-8000-000000000001','late-lesson',3,'reading'
  )
$$,'55000','Published or retired Training content is immutable','published lesson insert is rejected');
select throws_ok($$
  delete from public.training_lessons where id='2a900000-0000-4000-8000-000000000001'
$$,'55000','Published or retired Training content is immutable','published lesson delete is rejected');
select throws_ok($$
  update public.training_course_versions set title_i18n='{"en":"Changed"}'
  where id='2a700000-0000-4000-8000-000000000001'
$$,'55000','Published Training course version content is immutable','published version content mutation is rejected');

select lives_ok($$
  update public.training_course_versions
  set status='retired',retired_at=now(),retired_by='2a100000-0000-4000-8000-000000000001'
  where id='2a700000-0000-4000-8000-000000000001'
$$,'published version may transition to retired without content changes');

select throws_ok($$
  update public.training_course_versions set description_i18n='{"en":"Changed"}'
  where id='2a700000-0000-4000-8000-000000000001'
$$,'55000','Retired Training course versions are immutable','retired version mutation is rejected');
select throws_ok($$
  update public.training_lessons set required=false
  where id='2a900000-0000-4000-8000-000000000001'
$$,'55000','Published or retired Training content is immutable','retired lesson mutation is rejected');

insert into public.training_course_versions(
  id,organization_id,course_id,version_number,status,default_locale,supported_locales
) values(
  '2a700000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000001',
  '2a600000-0000-4000-8000-000000000001',2,'draft','en',array['en']
);
insert into public.training_modules(
  id,organization_id,course_version_id,stable_key,position
) values(
  '2a800000-0000-4000-8000-000000000002','2a200000-0000-4000-8000-000000000001',
  '2a700000-0000-4000-8000-000000000002','draft-module',0
);
select lives_ok($$
  update public.training_modules set position=1
  where id='2a800000-0000-4000-8000-000000000002'
$$,'new draft version content remains editable after retiring an older version');

select is(
  (select count(*)::integer from pg_catalog.pg_class table_row
   join pg_catalog.pg_namespace namespace on namespace.oid=table_row.relnamespace
   where namespace.nspname='public'
     and table_row.relname in(
       'operational_staff_training_credentials','training_learner_sessions','training_courses',
       'training_course_versions','training_modules','training_lessons'
     ) and table_row.relrowsecurity),
  6,'RLS is enabled on every Phase 2A table');

select ok(
  not has_table_privilege('anon','public.operational_staff_training_credentials','select')
  and not has_table_privilege('authenticated','public.training_learner_sessions','select')
  and not has_table_privilege('public','public.training_courses','select')
  and not has_table_privilege('anon','public.training_course_versions','insert')
  and not has_table_privilege('authenticated','public.training_modules','update')
  and not has_table_privilege('public','public.training_lessons','delete'),
  'PUBLIC, anon, and authenticated have no direct Phase 2A table access');

select ok(
  not has_table_privilege('service_role','public.operational_staff_training_credentials','select')
  and not has_table_privilege('service_role','public.training_learner_sessions','insert')
  and not has_table_privilege('service_role','public.training_courses','update'),
  'service_role is restricted to hardened RPC access rather than direct table grants');

select is(
  (select count(*)::integer from pg_catalog.pg_proc routine
   join pg_catalog.pg_namespace namespace on namespace.oid=routine.pronamespace
   where namespace.nspname in('public','private')
     and routine.proname in(
       'store_internal_admin_operational_staff_training_credential',
       'revoke_internal_admin_operational_staff_training_credential',
       'get_internal_admin_operational_staff_training_credential_status',
       'apply_training_lesson_defaults','enforce_training_draft_content',
       'enforce_training_course_version_immutability'
     ) and routine.prosecdef),
  6,'all Phase 2A functions are SECURITY DEFINER');

select is(
  (select count(*)::integer from pg_catalog.pg_proc routine
   join pg_catalog.pg_namespace namespace on namespace.oid=routine.pronamespace
   where namespace.nspname in('public','private')
     and routine.proname in(
       'store_internal_admin_operational_staff_training_credential',
       'revoke_internal_admin_operational_staff_training_credential',
       'get_internal_admin_operational_staff_training_credential_status',
       'apply_training_lesson_defaults','enforce_training_draft_content',
       'enforce_training_course_version_immutability'
     ) and exists(
       select 1 from unnest(routine.proconfig) setting
       where setting in('search_path=','search_path=""')
     )),
  6,'all Phase 2A functions have an empty search_path');

select ok(
  has_function_privilege('service_role','public.store_internal_admin_operational_staff_training_credential(uuid,uuid,uuid,text,text,integer,integer,integer,integer)','execute')
  and has_function_privilege('service_role','public.revoke_internal_admin_operational_staff_training_credential(uuid,uuid,uuid)','execute')
  and has_function_privilege('service_role','public.get_internal_admin_operational_staff_training_credential_status(uuid,uuid,uuid)','execute'),
  'service_role can execute all credential lifecycle RPCs');

select ok(
  not has_function_privilege('public','public.store_internal_admin_operational_staff_training_credential(uuid,uuid,uuid,text,text,integer,integer,integer,integer)','execute')
  and not has_function_privilege('anon','public.revoke_internal_admin_operational_staff_training_credential(uuid,uuid,uuid)','execute')
  and not has_function_privilege('authenticated','public.get_internal_admin_operational_staff_training_credential_status(uuid,uuid,uuid)','execute'),
  'PUBLIC, anon, and authenticated cannot execute credential lifecycle RPCs');

select * from finish();
rollback;
