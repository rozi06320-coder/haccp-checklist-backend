begin;
select plan(42);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
 ('7a100000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001','authenticated','authenticated','question-admin@example.invalid','{}','{}',now(),now()),
 ('7a100000-0000-4000-8000-000000000002','7a100000-0000-4000-8000-000000000002','authenticated','authenticated','question-other@example.invalid','{}','{}',now(),now());

insert into public.internal_admin_memberships(user_id,active)
values ('7a100000-0000-4000-8000-000000000001',true);

insert into public.organizations(id,name,slug) values
 ('7a200000-0000-4000-8000-000000000001','Question Authoring Org','question-authoring-org');

insert into public.training_courses(id,organization_id,course_key,status,created_by)
values ('7a300000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','question-course','active','7a100000-0000-4000-8000-000000000001');

insert into public.training_course_versions(
 id,organization_id,course_id,version_number,status,default_locale,supported_locales,title_i18n,description_i18n,created_by
) values (
 '7a400000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001',
 '7a300000-0000-4000-8000-000000000001',1,'draft','en',array['en','ar'],
 '{"en":"Question Course","ar":"دورة الأسئلة"}','{"en":"Draft","ar":"مسودة"}',
 '7a100000-0000-4000-8000-000000000001'
);

insert into public.training_modules(id,organization_id,course_version_id,stable_key,position,title_i18n,description_i18n,metadata)
values ('7a500000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','module-one',1,'{"en":"Module","ar":"وحدة"}','{"en":"Description","ar":"وصف"}','{}');

insert into public.training_lessons(id,organization_id,course_version_id,module_id,stable_key,position,lesson_type,required,title_i18n,objective_i18n,content_i18n,pass_threshold_bps,max_attempts,retry_delay_seconds,metadata)
values ('7a600000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a500000-0000-4000-8000-000000000001','quiz-one',1,'quiz',true,'{"en":"Quiz","ar":"اختبار"}','{"en":"Objective","ar":"هدف"}','{"en":{},"ar":{}}',8000,3,0,'{}');

insert into public.training_question_drafts(
 id,organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key,created_by
) values (
 '7a700000-0000-4000-8000-000000000001','7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','question-one',1,
 '{"en":"Which choice is safe?","ar":"أي خيار آمن؟"}','{"en":"Because it follows the rule.","ar":"لأنه يتبع القاعدة."}','safe',
 '7a100000-0000-4000-8000-000000000001');

insert into public.training_question_draft_options(organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n)
values
 ('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001','safe',1,'{"en":"Safe","ar":"آمن"}'),
 ('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001','unsafe',2,'{"en":"Unsafe","ar":"غير آمن"}');

set constraints training_question_drafts_90_complete, training_question_draft_options_90_complete immediate;

select has_table('public','training_question_drafts','draft question table exists');
select has_table('public','training_question_draft_options','draft option table exists');
select has_pk('public','training_question_drafts','draft questions have a primary key');
select has_pk('public','training_question_draft_options','draft options have a primary key');
select has_index('public','training_question_drafts','training_question_drafts_version_lesson_position_idx','draft question scope index exists');
select has_index('public','training_question_draft_options','training_question_draft_options_question_position_idx','draft option ordering index exists');
select ok((select relrowsecurity from pg_class where oid='public.training_question_drafts'::regclass),'question RLS is enabled');
select ok((select relrowsecurity from pg_class where oid='public.training_question_draft_options'::regclass),'option RLS is enabled');
select ok(not has_table_privilege('anon','public.training_question_drafts','select') and not has_table_privilege('authenticated','public.training_question_drafts','insert') and not has_table_privilege('service_role','public.training_question_drafts','select'),'question direct table access is revoked');
select ok(not has_table_privilege('anon','public.training_question_draft_options','select') and not has_table_privilege('authenticated','public.training_question_draft_options','insert') and not has_table_privilege('service_role','public.training_question_draft_options','select'),'option direct table access is revoked');
select ok((select count(*)=1 from public.training_question_drafts where stable_key='question-one'),'valid draft question persists');
select is((select count(*)::integer from public.training_question_draft_options where question_id='7a700000-0000-4000-8000-000000000001'),'2','valid question has two options');
select is((select correct_option_key from public.training_question_drafts where id='7a700000-0000-4000-8000-000000000001'),'safe','correct option is persisted server-side');
select is((select revision from public.training_question_drafts where id='7a700000-0000-4000-8000-000000000001'),0::bigint,'revision starts at zero');
select is((select count(*)::integer from pg_proc where proname='training_question_localized_text_valid' and prosecdef and proconfig @> array['search_path=""']),'1','locale validator is SECURITY DEFINER with empty search path');
select is((select count(*)::integer from pg_proc where proname='enforce_training_question_draft_scope' and prosecdef and proconfig @> array['search_path=""']),'1','question scope trigger is hardened');
select is((select count(*)::integer from pg_proc where proname='validate_training_question_draft_complete' and prosecdef and proconfig @> array['search_path=""']),'1','completeness trigger is hardened');
select is((select count(*)::integer from pg_proc where proname='enforce_training_question_revision' and prosecdef and proconfig @> array['search_path=""']),'1','revision trigger is hardened');
select ok(has_function_privilege('service_role','private.training_question_localized_text_valid(uuid,jsonb,integer)','execute') and not has_function_privilege('anon','private.training_question_localized_text_valid(uuid,jsonb,integer)','execute'),'locale helper is service-role-only');

select throws_like($$
  insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','question-one',2,'{"en":"x","ar":"س"}','{"en":"x","ar":"س"}','safe')
$$,'%duplicate key value violates unique constraint "training_question_drafts_lesson_stable_key"%','duplicate stable keys are rejected');

select throws_like($$
  insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','question-two',1,'{"en":"x","ar":"س"}','{"en":"x","ar":"س"}','safe')
$$,'%duplicate key value violates unique constraint "training_question_drafts_lesson_position"%','duplicate positions are rejected');

select throws_like($$
  insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','question-two',2,'{"en":"x"}','{"en":"x"}','safe')
$$,'%Training question locale content is invalid%','missing supported locale content is rejected');

select throws_like($$
  insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','question-two',2,'{"en":"x","ar":"س"}','{"en":"x","ar":"س"}','missing')
$$,'%Training question requires at least two options and a valid correct option%','invalid correct option is rejected at constraint check');

select throws_like($$
  insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key)
  values('7a200000-0000-4000-8000-000000000002','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','other-org',2,'{"en":"x","ar":"س"}','{"en":"x","ar":"س"}','safe')
$$,'%Training questions require a quiz lesson in a draft course version%','cross-organization question scope fails closed without disclosing scope');

select throws_like($$
  insert into public.training_question_draft_options(organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001','safe',3,'{"en":"x","ar":"س"}')
$$,'%duplicate key value violates unique constraint "training_question_draft_options_question_key"%','duplicate option keys are rejected');

select throws_like($$
  insert into public.training_question_draft_options(organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001','third',2,'{"en":"x","ar":"س"}')
$$,'%duplicate key value violates unique constraint "training_question_draft_options_question_position"%','duplicate option positions are rejected');

select throws_like($$
  update public.training_question_drafts set stable_key='renamed',revision=1
  where id='7a700000-0000-4000-8000-000000000001'
$$,'%Training question identity is immutable%','question identity fields are immutable');

select throws_like($$
  update public.training_question_draft_options set option_key='renamed'
  where question_id='7a700000-0000-4000-8000-000000000001'
$$,'%Training question option identity is immutable%','option identity fields are immutable');

set constraints training_question_drafts_90_complete, training_question_draft_options_90_complete deferred;
select lives_ok($sql$
  do $$
  begin
    delete from public.training_question_draft_options
      where question_id='7a700000-0000-4000-8000-000000000001' and option_key='unsafe';
    insert into public.training_question_draft_options(
      organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n
    ) values(
      '7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001',
      '7a600000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000001',
      'replacement',2,'{"en":"Replacement","ar":"بديل"}'
    );
  end
  $$;
$sql$,'multi-row option replacement remains valid in one transaction');
set constraints training_question_drafts_90_complete, training_question_draft_options_90_complete immediate;

set constraints training_question_drafts_90_complete, training_question_draft_options_90_complete deferred;
insert into public.training_question_drafts(
  id,organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key
) values (
  '7a700000-0000-4000-8000-000000000002','7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','question-two',2,
  '{"en":"Second?","ar":"ثان؟"}','{"en":"Second explanation","ar":"شرح ثان"}','yes'
);
insert into public.training_question_draft_options(
  organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n
) values
 ('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000002','yes',1,'{"en":"Yes","ar":"نعم"}'),
 ('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','7a700000-0000-4000-8000-000000000002','no',2,'{"en":"No","ar":"لا"}');
set constraints training_question_drafts_90_complete, training_question_draft_options_90_complete immediate;
select lives_ok($$
  delete from public.training_question_drafts where id='7a700000-0000-4000-8000-000000000002'
$$,'deleting a question cascades its draft options');
select is((select count(*)::integer from public.training_question_draft_options where question_id='7a700000-0000-4000-8000-000000000002'),'0','cascaded question deletion leaves no orphan options');

select is((select count(*)::integer from pg_proc p
 join pg_roles owner_role on owner_role.oid=p.proowner
 where p.proname in (
  'training_question_localized_text_valid','enforce_training_question_draft_scope',
  'enforce_training_question_option_scope','enforce_training_question_revision',
  'validate_training_question_draft_complete'
) and p.prosecdef and owner_role.rolname not in ('anon','authenticated','service_role')),'5','SECURITY DEFINER helpers have trusted non-browser ownership');
select ok(
  not has_table_privilege('anon','public.training_question_drafts','insert')
  and not has_table_privilege('authenticated','public.training_question_drafts','insert')
  and not has_table_privilege('anon','public.training_question_draft_options','insert')
  and not has_table_privilege('authenticated','public.training_question_draft_options','insert'),
  'anonymous and authenticated direct writes are denied');
select ok(
  not has_function_privilege('anon','private.enforce_training_question_draft_scope()','execute')
  and not has_function_privilege('authenticated','private.enforce_training_question_draft_scope()','execute'),
  'anonymous and authenticated helper execution is denied');
select ok(to_regprocedure('public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid)') is not null,'existing Baladiyah publication readiness contract remains present');
select ok(to_regprocedure('public.start_training_final_quiz_attempt(uuid,uuid,uuid,uuid,text,uuid)') is not null,'existing final quiz start contract remains present');

select lives_ok($$
  update public.training_question_drafts set explanation_i18n='{"en":"Updated","ar":"محدث"}',revision=1
  where id='7a700000-0000-4000-8000-000000000001'
$$,'a current revision can be advanced exactly once');
select throws_ok($$
  update public.training_question_drafts set explanation_i18n='{"en":"Stale","ar":"قديم"}',revision=1
  where id='7a700000-0000-4000-8000-000000000001'
$$,'40001','Training question revision is stale','stale revisions are rejected atomically');

select throws_like($$
  insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a500000-0000-4000-8000-000000000001','not-a-quiz',2,'{"en":"x","ar":"س"}','{"en":"x","ar":"س"}','safe')
$$,'%require a quiz lesson in a draft course version%','non-quiz lessons are rejected');

-- Use a dedicated retired-state fixture for the question immutability check.
-- The publication-manifest and retirement RPC paths have separate suites; this
-- row satisfies the real lifecycle CHECK without disabling any trigger or
-- bypassing the question immutability trigger under test.
update public.training_course_versions
set status='retired',published_at=now(),
    published_by='7a100000-0000-4000-8000-000000000001',
    retired_at=now(),retired_by='7a100000-0000-4000-8000-000000000001',
    content_hash=repeat('b',64),publication_fingerprint=repeat('a',64)
where id='7a400000-0000-4000-8000-000000000001';
select throws_like($$
  insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key)
  values('7a200000-0000-4000-8000-000000000001','7a400000-0000-4000-8000-000000000001','7a600000-0000-4000-8000-000000000001','published-new',2,'{"en":"x","ar":"س"}','{"en":"x","ar":"س"}','safe')
$$,'%require a quiz lesson in a draft course version%','retired versions reject new questions');
select is((select count(*)::integer from public.training_question_drafts),'1','retirement preserves historical draft row');
select throws_like($$
  update public.training_question_drafts set position=3 where id='7a700000-0000-4000-8000-000000000001'
$$,'%Training questions require a quiz lesson in a draft course version%','retired versions reject question edits without disclosing content state');
do $$
declare saved public.training_question_drafts%rowtype;
begin
  select * into saved from public.training_question_drafts
  where id='7a700000-0000-4000-8000-000000000001';
  if saved.position<>1 or saved.revision<>1
     or saved.explanation_i18n->>'en' is distinct from 'Updated' then
    raise exception 'Rejected retired question update mutated draft content';
  end if;
end
$$;

select * from finish();
rollback;
