begin;
select plan(22);

select has_column('public','sales_tracking_reports','review_status','Review status is stored separately');
select has_column('public','sales_tracking_reports','review_revision','Review concurrency has a dedicated revision');
select has_table('public','sales_tracking_review_events','Review transitions have append-only audit rows');
select has_function('public','set_managed_sales_tracking_review_status',array['uuid','uuid','uuid','bigint','text'],'Manager review RPC exists');
select ok(has_function_privilege('service_role','public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text)','execute'),'Service role can execute review RPC');
select ok(not has_function_privilege('authenticated','public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text)','execute'),'Browser role cannot execute review RPC');

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
 ('00000000-0000-0000-0000-000000000000','1d000000-0000-4000-8000-000000000001','authenticated','authenticated','review-supervisor@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','1d000000-0000-4000-8000-000000000002','authenticated','authenticated','review-manager@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','1d000000-0000-4000-8000-000000000003','authenticated','authenticated','review-outsider@example.invalid','{}','{}',now(),now());
update public.profiles set full_name=case id when '1d000000-0000-4000-8000-000000000001' then 'Review Supervisor' when '1d000000-0000-4000-8000-000000000002' then 'Review Manager' else 'Review Outsider' end,must_change_password=false where id::text like '1d000000-%';
insert into public.organizations(id,name,slug) values
 ('2d000000-0000-4000-8000-000000000001','Review Org','review-org'),
 ('2d000000-0000-4000-8000-000000000002','Other Review Org','other-review-org');
insert into public.branches(id,organization_id,name,code,timezone,country_code) values('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Review Branch','REV','Asia/Riyadh','SA');
insert into public.branch_memberships(branch_id,user_id,role) values('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager');
insert into public.organization_memberships(organization_id,user_id,role) values
 ('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','organization_manager'),
 ('2d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000003','organization_manager');

select lives_ok(format($$select public.ensure_sales_tracking_draft_report('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','%s')$$,private.phase4a_business_date('Asia/Riyadh')),'Draft report is created');
select throws_ok($$select public.set_managed_sales_tracking_review_status('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),0,'needs_review')$$,'55000','sales tracking report is not submitted','Draft cannot be reviewed');
select lives_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','%s',0,'middle_shift','[{"entry_date":"%s","actual_cash":"10","actual_credit":"0","pos_cash":"10","pos_credit":"0","online_delivery":"0"}]','[{"entry_date":"%s","remaining_cash":"0"}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'Middle period saves');
select lives_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','%s',1,'closing_shift','[{"entry_date":"%s","actual_cash":"20","actual_credit":"0","pos_cash":"20","pos_credit":"0","online_delivery":"0"}]','[{"entry_date":"%s","remaining_cash":"0"}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'Closing period saves');
select lives_ok(format($$select public.submit_sales_tracking('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','%s',2,'5d000000-0000-4000-8000-000000000001',repeat('d',64))$$,private.phase4a_business_date('Asia/Riyadh')),'Report submits');
select lives_ok($$select public.set_managed_sales_tracking_review_status('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),0,'needs_review')$$,'Submitted report can be marked Needs Review');
select is((select review_status from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),'needs_review','Needs Review persists');
select is((select review_revision from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),1::bigint,'Review revision increments');
select throws_ok($$select public.set_managed_sales_tracking_review_status('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),0,'reviewed')$$,'PT409','sales tracking review changed','Stale review revision is rejected');
select lives_ok($$select public.set_managed_sales_tracking_review_status('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),1,'reviewed')$$,'Needs Review can become Reviewed');
select lives_ok($$select public.set_managed_sales_tracking_review_status('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),2,'needs_review')$$,'Reviewed can return to Needs Review');
select is((select count(*) from public.sales_tracking_review_events where report_id=(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001')),3::bigint,'Every transition is audited');
select throws_ok($$select public.set_managed_sales_tracking_review_status('1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001',(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001'),3,'reviewed')$$,'42501','sales tracking review access denied','Wrong organization Manager is denied');
select throws_ok($$update public.sales_tracking_reports set branch_name_snapshot='Changed' where branch_id='3d000000-0000-4000-8000-000000000001'$$,'55000','submitted sales tracking report is immutable','Financial parent data stays immutable');
select throws_ok($$update public.sales_tracking_sales_rows set actual_cash=999 where report_id=(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001')$$,'55000','submitted sales tracking child row is immutable','Financial child data stays immutable');
select is((select sum(actual_cash) from public.sales_tracking_sales_rows where report_id=(select id from public.sales_tracking_reports where branch_id='3d000000-0000-4000-8000-000000000001')),30::numeric,'Review transitions do not change financial totals');

select * from finish();
rollback;
