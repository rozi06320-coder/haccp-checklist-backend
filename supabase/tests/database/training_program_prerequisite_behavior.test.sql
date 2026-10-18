begin;
select plan(15);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','4c100000-0000-4000-8000-000000000001','authenticated','authenticated','phase4b@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Phase 4B Admin',must_change_password=false where id='4c100000-0000-4000-8000-000000000001';
insert into public.internal_admin_memberships(user_id,active,created_by,updated_by)
values('4c100000-0000-4000-8000-000000000001',true,'4c100000-0000-4000-8000-000000000001','4c100000-0000-4000-8000-000000000001');
insert into public.organizations(id,name,slug) values
('4c200000-0000-4000-8000-000000000001','Phase 4B Behavior Org','phase-4b-behavior'),
('4c200000-0000-4000-8000-000000000002','Phase 4B Foreign Org','phase-4b-foreign');
insert into public.branches(id,organization_id,name,code,timezone,active) values
('4c300000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','Phase 4B Branch','P4B','Asia/Riyadh',true),
('4c300000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','Transferred Branch','P4BT','Asia/Riyadh',true);
insert into public.branch_memberships(branch_id,user_id,role,active)
values('4c300000-0000-4000-8000-000000000001','4c100000-0000-4000-8000-000000000001','branch_manager',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,active)
values('4c400000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c100000-0000-4000-8000-000000000001',true);
select set_config('test.phase4b_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='4c400000-0000-4000-8000-000000000001'),false);
insert into public.branch_training_access(organization_id,branch_id,enabled,pin_hash,salt,kdf_version,cost,block_size,parallelization,credential_version,updated_by)
values('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001',true,decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1,16384,8,1,'4c500000-0000-4000-8000-000000000001','4c100000-0000-4000-8000-000000000001');
insert into public.operational_staff(id,organization_id,branch_id,display_name,employment_status,created_by,staff_code) values
('4c600000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','Learner One','active','4c100000-0000-4000-8000-000000000001','P4B-1'),
('4c600000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','Learner Two','active','4c100000-0000-4000-8000-000000000001','P4B-2');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles,active,valid_from) values
('4c700000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4c400000-0000-4000-8000-000000000001',current_setting('test.phase4b_team')::uuid,array['kitchen'],true,private.phase4a_business_date('Asia/Riyadh')),
('4c700000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000002','4c400000-0000-4000-8000-000000000001',current_setting('test.phase4b_team')::uuid,array['kitchen'],true,private.phase4a_business_date('Asia/Riyadh'));

insert into public.training_courses(id,organization_id,course_key,status) values
('4c800000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','baladiyah-food-safety-hygiene','active'),
('4c800000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','restaurant-sop','active');
insert into public.training_course_versions(id,organization_id,course_id,version_number,status,default_locale,supported_locales,title_i18n,description_i18n,revision,content_hash) values
('4c900000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','4c800000-0000-4000-8000-000000000001',1,'draft','en',array['en','ar','id','hi','fil'],'{"en":"Baladiyah"}','{"en":"Baladiyah"}',1,'phase4b-baladiyah'),
('4c900000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','4c800000-0000-4000-8000-000000000002',1,'draft','en',array['en','ar','id','hi','fil'],'{"en":"SOP"}','{"en":"SOP"}',1,'phase4b-sop');
insert into public.training_modules(id,organization_id,course_version_id,stable_key,position,title_i18n,description_i18n,metadata) values
('4ca00000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000001','learning',1,'{"en":"Learning"}','{"en":"Learning"}','{}'),
('4ca00000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000001','final-assessment',2,'{"en":"Final"}','{"en":"Final"}','{"module_role":"final_assessment"}'),
('4ca00000-0000-4000-8000-000000000003','4c200000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000002','sop-learning',1,'{"en":"SOP"}','{"en":"SOP"}','{}');
insert into public.training_lessons(id,organization_id,course_version_id,module_id,stable_key,position,lesson_type,required,title_i18n,objective_i18n,content_i18n) values
('4cb00000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000001','4ca00000-0000-4000-8000-000000000001','baladiyah-lesson',1,'reading',true,'{"en":"Lesson"}','{"en":"Learn"}','{}'),
('4cb00000-0000-4000-8000-000000000003','4c200000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000002','4ca00000-0000-4000-8000-000000000003','sop-lesson',1,'reading',true,'{"en":"SOP Lesson"}','{"en":"Learn"}','{}');
with questions as (select jsonb_agg(jsonb_build_object('stable_key','q-'||n,'prompt','Question '||n,'options',jsonb_build_array(jsonb_build_object('option_key','a','text','A'),jsonb_build_object('option_key','b','text','B')),'explanation','Explanation') order by n) value from generate_series(1,27)n), answers as (select jsonb_object_agg('q-'||n,'b') value from generate_series(1,27)n)
insert into public.training_lessons(id,organization_id,course_version_id,module_id,stable_key,position,lesson_type,required,title_i18n,objective_i18n,content_i18n,pass_threshold_bps,retry_delay_seconds,metadata)
select '4cb00000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000001','4ca00000-0000-4000-8000-000000000002','final-quiz',1,'quiz',true,'{"en":"Final"}','{"en":"Assess"}',
  (select jsonb_object_agg(locale,jsonb_build_object('questions',questions.value)) from unnest(array['en','ar','id','hi','fil']) locale cross join questions),8000,0,jsonb_build_object('assessment_scope','course','answer_key_by_question',answers.value) from answers;
update public.training_course_versions set status='published',published_at=statement_timestamp(),published_by='4c100000-0000-4000-8000-000000000001' where id in('4c900000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000002');

insert into public.training_programs(id,organization_id,program_key,status,title_i18n,description_i18n) values('4cc00000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','restaurant-training','active','{"en":"Training"}','{"en":"Training"}');
insert into public.training_program_courses(id,organization_id,program_id,course_id,position,label_i18n) values('4cd00000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001','4cc00000-0000-4000-8000-000000000001','4c800000-0000-4000-8000-000000000001',1,'{"en":"Baladiyah"}');
insert into public.training_program_courses(id,organization_id,program_id,course_id,position,label_i18n,prerequisite_program_course_id) values('4cd00000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001','4cc00000-0000-4000-8000-000000000001','4c800000-0000-4000-8000-000000000002',2,'{"en":"SOP"}','4cd00000-0000-4000-8000-000000000001');

select is(private.training_program_prerequisite_satisfied('4c200000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002'),false,'SOP starts locked');
select throws_ok($$select * from public.initialize_training_program_enrollment('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002')$$,'42501','Training course prerequisite is incomplete','direct SOP enrollment is rejected');
select * from public.initialize_training_program_enrollment('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000001');
select set_config('test.phase4b_enrollment',(select id::text from public.training_enrollments where employee_id='4c600000-0000-4000-8000-000000000001'),false);
select public.start_training_lesson('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001',current_setting('test.phase4b_enrollment')::uuid,'4cb00000-0000-4000-8000-000000000001');
select public.complete_training_lesson('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001',current_setting('test.phase4b_enrollment')::uuid,'4cb00000-0000-4000-8000-000000000001');
select is(private.training_program_prerequisite_satisfied('4c200000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002'),false,'lesson completion alone does not unlock SOP');

insert into public.training_quiz_attempts(id,organization_id,enrollment_id,employee_id,course_id,course_version_id,quiz_lesson_id,attempt_number,status,locale,question_order,question_count,pass_threshold_bps,start_idempotency_key,start_request_sha256,submit_idempotency_key,submit_request_sha256,correct_count,score_bps,passed,submitted_at)
select '4ce00000-0000-4000-8000-000000000001','4c200000-0000-4000-8000-000000000001',current_setting('test.phase4b_enrollment')::uuid,'4c600000-0000-4000-8000-000000000001','4c800000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000001','4cb00000-0000-4000-8000-000000000002',1,'submitted','en',array_agg('q-'||n order by n),27,8000,'4cf00000-0000-4000-8000-000000000001',repeat('1',64),'4cf00000-0000-4000-8000-000000000002',repeat('2',64),21,7777,false,statement_timestamp() from generate_series(1,27)n;
select is(private.training_program_prerequisite_satisfied('4c200000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002'),false,'failed quiz does not unlock SOP');
select is(private.training_program_prerequisite_satisfied('4c200000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000002','4cd00000-0000-4000-8000-000000000002'),false,'another employee remains locked');
select is(coalesce(private.training_program_prerequisite_satisfied('4c200000-0000-4000-8000-000000000002','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002'),false),false,'another organization cannot reuse completion');

insert into public.training_quiz_attempts(id,organization_id,enrollment_id,employee_id,course_id,course_version_id,quiz_lesson_id,attempt_number,status,locale,question_order,question_count,pass_threshold_bps,start_idempotency_key,start_request_sha256,submit_idempotency_key,submit_request_sha256,correct_count,score_bps,passed,submitted_at)
select '4ce00000-0000-4000-8000-000000000002','4c200000-0000-4000-8000-000000000001',current_setting('test.phase4b_enrollment')::uuid,'4c600000-0000-4000-8000-000000000001','4c800000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000001','4cb00000-0000-4000-8000-000000000002',2,'submitted','en',array_agg('q-'||n order by n),27,8000,'4cf00000-0000-4000-8000-000000000003',repeat('3',64),'4cf00000-0000-4000-8000-000000000004',repeat('4',64),22,8148,true,statement_timestamp() from generate_series(1,27)n;
insert into public.training_course_completions(organization_id,enrollment_id,employee_id,course_id,course_version_id,passing_attempt_id,quiz_lesson_id,branch_id_at_completion,branch_name_at_completion,operational_team_id_at_completion,operational_team_name_at_completion)
values('4c200000-0000-4000-8000-000000000001',current_setting('test.phase4b_enrollment')::uuid,'4c600000-0000-4000-8000-000000000001','4c800000-0000-4000-8000-000000000001','4c900000-0000-4000-8000-000000000001','4ce00000-0000-4000-8000-000000000002','4cb00000-0000-4000-8000-000000000002','4c300000-0000-4000-8000-000000000001','Phase 4B Branch',current_setting('test.phase4b_team')::uuid,'Team');
select is(private.training_program_prerequisite_satisfied('4c200000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002'),true,'passing quiz completion unlocks SOP');
select lives_ok($$select * from public.initialize_training_program_enrollment('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002')$$,'same employee can initialize SOP enrollment');
select lives_ok($$select * from public.initialize_training_program_enrollment('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002')$$,'SOP enrollment initialization is idempotent');
select is((select count(*)::integer from public.training_enrollments where employee_id='4c600000-0000-4000-8000-000000000001' and course_id='4c800000-0000-4000-8000-000000000002'),1,'concurrent-safe uniqueness leaves one SOP enrollment');
select throws_ok($$select * from public.initialize_training_program_enrollment('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000002','4cd00000-0000-4000-8000-000000000002')$$,'42501','Training course prerequisite is incomplete','another employee cannot initialize SOP');
select throws_ok($$select * from public.initialize_training_enrollment('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000002','restaurant-sop')$$,'42501','Program prerequisite enrollment requires program scope','legacy course-key RPC cannot bypass prerequisite');
select is((select locked from public.get_training_program_status('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','restaurant-training') where category_position=2),false,'program read model derives unlocked SOP state');
update public.training_course_versions set status='retired',retired_at=statement_timestamp(),retired_by='4c100000-0000-4000-8000-000000000001' where id='4c900000-0000-4000-8000-000000000001';
select is((select category_status from public.get_training_program_status('4c200000-0000-4000-8000-000000000001','4c300000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','restaurant-training') where category_position=1),'completed','historical completion remains visible after version retirement');
update public.operational_staff set branch_id='4c300000-0000-4000-8000-000000000002' where id='4c600000-0000-4000-8000-000000000001';
select is(private.training_program_prerequisite_satisfied('4c200000-0000-4000-8000-000000000001','4c600000-0000-4000-8000-000000000001','4cd00000-0000-4000-8000-000000000002'),true,'branch transfer preserves historical completion eligibility');

select * from finish();
rollback;
