begin;
select plan(25);

select has_table('public','training_programs','training programs table exists');
select has_table('public','training_program_courses','training program courses table exists');
select has_column('public','training_enrollments','program_course_id','enrollment has optional program scope');
select has_index('public','training_course_versions','training_course_versions_one_published_idx','one published version is indexed uniquely');
select has_index('public','training_enrollments','training_enrollments_employee_program_course_idx','employee program enrollment lookup is indexed');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.training_programs'::regclass),'program RLS is enabled');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.training_program_courses'::regclass),'program-course RLS is enabled');
select ok(not has_table_privilege('service_role','public.training_programs','select') and not has_table_privilege('anon','public.training_programs','select') and not has_table_privilege('authenticated','public.training_programs','select'),'program direct reads are revoked');
select ok(not has_table_privilege('service_role','public.training_program_courses','select') and not has_table_privilege('anon','public.training_program_courses','select') and not has_table_privilege('authenticated','public.training_program_courses','select'),'program-course direct reads are revoked');
select function_returns('public','initialize_training_program_enrollment',array['uuid','uuid','uuid','uuid'],'setof training_enrollments','program enrollment RPC exists');
select function_returns('public','get_training_program_status',array['uuid','uuid','uuid','text'],'setof record','program status RPC exists');
select is((select count(*)::integer from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname in('initialize_training_program_enrollment','get_training_program_status','provision_internal_admin_restaurant_training_program') and procedure.prosecdef),3,'program RPCs are SECURITY DEFINER');
select is((select count(*)::integer from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname in('initialize_training_program_enrollment','get_training_program_status','provision_internal_admin_restaurant_training_program') and procedure.proconfig @> array['search_path=""']),3,'program RPCs have empty search path');
select ok(has_function_privilege('service_role','public.initialize_training_program_enrollment(uuid,uuid,uuid,uuid)','execute') and not has_function_privilege('anon','public.initialize_training_program_enrollment(uuid,uuid,uuid,uuid)','execute') and not has_function_privilege('authenticated','public.initialize_training_program_enrollment(uuid,uuid,uuid,uuid)','execute'),'program enrollment is service-role only');

insert into public.organizations(id,name,slug) values
('4b200000-0000-4000-8000-000000000001','Phase 4B Org','phase-4b-org'),
('4b200000-0000-4000-8000-000000000002','Phase 4B Other Org','phase-4b-other-org');
insert into public.training_courses(id,organization_id,course_key,status) values
('4b300000-0000-4000-8000-000000000001','4b200000-0000-4000-8000-000000000001','baladiyah-food-safety-hygiene','active'),
('4b300000-0000-4000-8000-000000000002','4b200000-0000-4000-8000-000000000001','restaurant-sop','active'),
('4b300000-0000-4000-8000-000000000003','4b200000-0000-4000-8000-000000000002','other-course','active');
insert into public.training_programs(id,organization_id,program_key,status,title_i18n,description_i18n) values
('4b400000-0000-4000-8000-000000000001','4b200000-0000-4000-8000-000000000001','restaurant-training','draft','{"en":"Training"}','{"en":"Training"}'),
('4b400000-0000-4000-8000-000000000002','4b200000-0000-4000-8000-000000000002','other-program','draft','{"en":"Other"}','{"en":"Other"}');
insert into public.training_program_courses(id,organization_id,program_id,course_id,position,label_i18n,required) values
('4b500000-0000-4000-8000-000000000001','4b200000-0000-4000-8000-000000000001','4b400000-0000-4000-8000-000000000001','4b300000-0000-4000-8000-000000000001',1,'{"en":"Baladiyah"}',true);
insert into public.training_program_courses(id,organization_id,program_id,course_id,position,label_i18n,required,prerequisite_program_course_id) values
('4b500000-0000-4000-8000-000000000002','4b200000-0000-4000-8000-000000000001','4b400000-0000-4000-8000-000000000001','4b300000-0000-4000-8000-000000000002',2,'{"en":"Restaurant SOP"}',true,'4b500000-0000-4000-8000-000000000001');

select is((select count(*)::integer from public.training_program_courses where program_id='4b400000-0000-4000-8000-000000000001'),2,'program has two ordered categories');
select is((select position from public.training_program_courses where id='4b500000-0000-4000-8000-000000000001'),1,'Baladiyah is position one');
select is((select prerequisite_program_course_id from public.training_program_courses where id='4b500000-0000-4000-8000-000000000002'),'4b500000-0000-4000-8000-000000000001'::uuid,'Restaurant SOP requires Baladiyah');
select throws_ok($$insert into public.training_program_courses(id,organization_id,program_id,course_id,position,label_i18n,prerequisite_program_course_id) values('4b500000-0000-4000-8000-000000000003','4b200000-0000-4000-8000-000000000001','4b400000-0000-4000-8000-000000000001','4b300000-0000-4000-8000-000000000002',3,'{"en":"Self"}','4b500000-0000-4000-8000-000000000003')$$,'23514','Training prerequisite must be an earlier course in the same program','self prerequisite is rejected');
select throws_ok($$update public.training_program_courses set position=2 where id='4b500000-0000-4000-8000-000000000001'$$,'23514','Training course order would invalidate an existing prerequisite','moving prerequisite after dependent is rejected');
select throws_ok($$insert into public.training_program_courses(id,organization_id,program_id,course_id,position,label_i18n,prerequisite_program_course_id) values('4b500000-0000-4000-8000-000000000004','4b200000-0000-4000-8000-000000000002','4b400000-0000-4000-8000-000000000002','4b300000-0000-4000-8000-000000000003',2,'{"en":"Cross"}','4b500000-0000-4000-8000-000000000001')$$,'23514','Training prerequisite must be an earlier course in the same program','cross-organization prerequisite is rejected');
select throws_ok($$insert into public.training_program_courses(organization_id,program_id,course_id,position,label_i18n) values('4b200000-0000-4000-8000-000000000001','4b400000-0000-4000-8000-000000000001','4b300000-0000-4000-8000-000000000002',3,'{"en":"Duplicate"}')$$,'23505',null,'duplicate course in program is rejected');
select is((select status from public.training_programs where id='4b400000-0000-4000-8000-000000000001'),'draft','program is not activated automatically');
select is((select count(*)::integer from public.training_course_versions where course_id='4b300000-0000-4000-8000-000000000002'),0,'Restaurant SOP receives no fake course version');
select is((select count(*)::integer from public.training_enrollments where organization_id='4b200000-0000-4000-8000-000000000001'),0,'program foundation creates no employee enrollment');
select is((select count(*)::integer from public.training_lesson_progress where organization_id='4b200000-0000-4000-8000-000000000001'),0,'program foundation creates no learner progress');

select * from finish();
rollback;
