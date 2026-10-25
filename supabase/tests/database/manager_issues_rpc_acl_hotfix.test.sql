begin;
select plan(40);

insert into auth.users(
  instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values (
  '00000000-0000-0000-0000-000000000000',
  '1a000000-0000-4000-8000-000000000001',
  'authenticated','authenticated','manager-acl@example.invalid','{}','{}',now(),now()
);
update public.profiles
set full_name='Manager ACL Test',must_change_password=false
where id='1a000000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug)
values('2a000000-0000-4000-8000-000000000001','Manager ACL Test Org','manager-acl-test-org');
insert into public.organization_memberships(organization_id,user_id,role)
values(
  '2a000000-0000-4000-8000-000000000001',
  '1a000000-0000-4000-8000-000000000001',
  'organization_manager'
);

-- Effective privileges for all exact PostgREST-visible signatures.
select is(has_function_privilege('public','public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'PUBLIC cannot list Phase4A Manager Issues');
select is(has_function_privilege('anon','public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'anon cannot list Phase4A Manager Issues');
select is(has_function_privilege('authenticated','public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot list Phase4A Manager Issues');
select is(has_function_privilege('service_role','public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),true,'service_role can list Phase4A Manager Issues');

select is(has_function_privilege('public','public.get_phase4a_managed_issue(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read a Phase4A Manager Issue');
select is(has_function_privilege('anon','public.get_phase4a_managed_issue(uuid,uuid,uuid)','execute'),false,'anon cannot read a Phase4A Manager Issue');
select is(has_function_privilege('authenticated','public.get_phase4a_managed_issue(uuid,uuid,uuid)','execute'),false,'authenticated cannot read a Phase4A Manager Issue');
select is(has_function_privilege('service_role','public.get_phase4a_managed_issue(uuid,uuid,uuid)','execute'),true,'service_role can read a Phase4A Manager Issue');

select is(has_function_privilege('public','public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'PUBLIC cannot list Oil Manager Issues');
select is(has_function_privilege('anon','public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'anon cannot list Oil Manager Issues');
select is(has_function_privilege('authenticated','public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot list Oil Manager Issues');
select is(has_function_privilege('service_role','public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),true,'service_role can list Oil Manager Issues');

select is(has_function_privilege('public','public.get_oil_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read an Oil Manager Issue');
select is(has_function_privilege('anon','public.get_oil_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'anon cannot read an Oil Manager Issue');
select is(has_function_privilege('authenticated','public.get_oil_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'authenticated cannot read an Oil Manager Issue');
select is(has_function_privilege('service_role','public.get_oil_tracking_managed_issue(uuid,uuid,uuid)','execute'),true,'service_role can read an Oil Manager Issue');

select is(has_function_privilege('public','public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'PUBLIC cannot list Cold Storage Manager Issues');
select is(has_function_privilege('anon','public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'anon cannot list Cold Storage Manager Issues');
select is(has_function_privilege('authenticated','public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot list Cold Storage Manager Issues');
select is(has_function_privilege('service_role','public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),true,'service_role can list Cold Storage Manager Issues');

select is(has_function_privilege('public','public.get_cold_storage_managed_issue(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read a Cold Storage Manager Issue');
select is(has_function_privilege('anon','public.get_cold_storage_managed_issue(uuid,uuid,uuid)','execute'),false,'anon cannot read a Cold Storage Manager Issue');
select is(has_function_privilege('authenticated','public.get_cold_storage_managed_issue(uuid,uuid,uuid)','execute'),false,'authenticated cannot read a Cold Storage Manager Issue');
select is(has_function_privilege('service_role','public.get_cold_storage_managed_issue(uuid,uuid,uuid)','execute'),true,'service_role can read a Cold Storage Manager Issue');

select is(has_function_privilege('public','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'PUBLIC cannot list Sales Tracking Manager Issues');
select is(has_function_privilege('anon','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'anon cannot list Sales Tracking Manager Issues');
select is(has_function_privilege('authenticated','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot list Sales Tracking Manager Issues');
select is(has_function_privilege('service_role','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),true,'service_role can list Sales Tracking Manager Issues');

select is(has_function_privilege('public','public.get_sales_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'PUBLIC cannot read a Sales Tracking Manager Issue');
select is(has_function_privilege('anon','public.get_sales_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'anon cannot read a Sales Tracking Manager Issue');
select is(has_function_privilege('authenticated','public.get_sales_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'authenticated cannot read a Sales Tracking Manager Issue');
select is(has_function_privilege('service_role','public.get_sales_tracking_managed_issue(uuid,uuid,uuid)','execute'),true,'service_role can read a Sales Tracking Manager Issue');

-- A browser role cannot bypass the backend by supplying the valid manager UUID.
set local role anon;
select throws_ok(
  $$select public.list_phase4a_managed_issues('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001')$$,
  '42501','permission denied for function list_phase4a_managed_issues',
  'anon direct call is denied before actor authorization'
);
select throws_ok(
  $$select public.get_sales_tracking_managed_issue('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')$$,
  '42501','permission denied for function get_sales_tracking_managed_issue',
  'anon direct detail call is denied before actor authorization'
);
reset role;

set local role authenticated;
select throws_ok(
  $$select public.list_phase4a_managed_issues('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001')$$,
  '42501','permission denied for function list_phase4a_managed_issues',
  'authenticated direct call is denied before actor authorization'
);
select throws_ok(
  $$select public.get_sales_tracking_managed_issue('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001')$$,
  '42501','permission denied for function get_sales_tracking_managed_issue',
  'authenticated direct detail call is denied before actor authorization'
);
reset role;

-- The backend credential retains real execution, including tenant authorization.
set local role service_role;
select lives_ok($$select public.list_phase4a_managed_issues('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001')$$,'service_role can execute Phase4A Manager Issues through the backend boundary');
select lives_ok($$select public.list_oil_tracking_managed_issues('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001')$$,'service_role can execute Oil Manager Issues through the backend boundary');
select lives_ok($$select public.list_cold_storage_managed_issues('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001')$$,'service_role can execute Cold Storage Manager Issues through the backend boundary');
select lives_ok($$select public.list_sales_tracking_managed_issues('1a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001')$$,'service_role can execute Sales Tracking Manager Issues through the backend boundary');
reset role;

select * from finish();
rollback;
