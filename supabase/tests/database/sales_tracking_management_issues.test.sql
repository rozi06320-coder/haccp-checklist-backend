begin;
select plan(17);

create temp table sales_tracking_issue_tz as
select
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 3 and 23 order by name limit 1) closed_tz,
  (select name from pg_timezone_names where extract(hour from statement_timestamp() at time zone name) between 0 and 2 order by name limit 1) open_tz;

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000001'::uuid,
  '1e000000-0000-4000-8000-000000000002',
  '1e000000-0000-4000-8000-000000000003',
  '1e000000-0000-4000-8000-000000000004',
  '1e000000-0000-4000-8000-000000000005',
  '1e000000-0000-4000-8000-000000000006'
]) id;
update public.profiles set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Variance Supervisor'
  when '1e000000-0000-4000-8000-000000000002' then 'Balanced Supervisor'
  when '1e000000-0000-4000-8000-000000000003' then 'Missing Closed Supervisor'
  when '1e000000-0000-4000-8000-000000000004' then 'Missing Open Supervisor'
  when '1e000000-0000-4000-8000-000000000005' then 'Sales Issue Manager'
  else 'Other Sales Issue Manager'
end, must_change_password = false
where id::text like '1e000000-%';

insert into public.organizations(id,name,slug) values
  ('2e000000-0000-4000-8000-000000000001','Sales Issues Org','sales-issues-org'),
  ('2e000000-0000-4000-8000-000000000002','Other Sales Issues Org','other-sales-issues-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Variance Branch','VAR',(select closed_tz from sales_tracking_issue_tz)),
  ('3e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','Balanced Branch','BAL',(select closed_tz from sales_tracking_issue_tz)),
  ('3e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','Missing Closed Branch','MIS',(select closed_tz from sales_tracking_issue_tz)),
  ('3e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000001','Missing Open Branch','OPN',(select open_tz from sales_tracking_issue_tz));
insert into public.organization_memberships(organization_id,user_id,role) values
  ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000005','organization_manager'),
  ('2e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000006','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager'),
  ('3e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002','branch_manager'),
  ('3e000000-0000-4000-8000-000000000003','1e000000-0000-4000-8000-000000000003','branch_manager'),
  ('3e000000-0000-4000-8000-000000000004','1e000000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001'),
  ('4e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000002'),
  ('4e000000-0000-4000-8000-000000000003','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000003','1e000000-0000-4000-8000-000000000003'),
  ('4e000000-0000-4000-8000-000000000004','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000004','1e000000-0000-4000-8000-000000000004');

select is(has_function_privilege('authenticated','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),false,'authenticated cannot execute managed sales tracking issues RPC');
select is(has_function_privilege('service_role','public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)','execute'),true,'service role can execute managed sales tracking issues RPC');
select is(has_function_privilege('authenticated','public.get_sales_tracking_managed_issue(uuid,uuid,uuid)','execute'),false,'authenticated cannot execute managed sales tracking issue detail RPC');

do $setup$
declare d date:=private.phase4a_business_date((select closed_tz from sales_tracking_issue_tz));
begin
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',0,'middle_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',200,'actual_credit',50,'pos_cash',175,'pos_credit',50,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',1,'closing_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',0,'actual_credit',0,'pos_cash',0,'pos_credit',0,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.submit_sales_tracking('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',2,'5e000000-0000-4000-8000-000000000001',repeat('a',64));
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000002',0,'middle_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',100,'actual_credit',50,'pos_cash',100,'pos_credit',50,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.save_sales_tracking_draft('1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000002',1,'closing_shift',jsonb_build_array(jsonb_build_object('entry_date',d,'actual_cash',0,'actual_credit',0,'pos_cash',0,'pos_credit',0,'online_delivery',0)),jsonb_build_array(jsonb_build_object('entry_date',d,'remaining_cash',0)));
 perform public.submit_sales_tracking('1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000002',2,'5e000000-0000-4000-8000-000000000002',repeat('b',64));
end$setup$;
select pass('variance supervisor submits mismatched two-period Sales Tracking');
select pass('balanced supervisor submits matching two-period Sales Tracking');

create temp table sales_tracking_issue_list as
select public.list_sales_tracking_managed_issues(
  '1e000000-0000-4000-8000-000000000005',
  '2e000000-0000-4000-8000-000000000001',
  1, 20, null, null, null, null, null, 'sales_tracking', null, null
) payload;

select is((select payload->>'total' from sales_tracking_issue_list),'2','manager sees one variance and one closed missing issue');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'title' = 'Sales Tracking variance issue'),1,'variance issue appears');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'title' = 'Missing Sales Tracking submission'),1,'closed missing issue appears');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'branch_name' = 'Balanced Branch'),0,'balanced submission has no issue');
select is((select count(*)::int from jsonb_array_elements((select payload->'issues' from sales_tracking_issue_list)) issue where issue->>'branch_name' = 'Missing Open Branch'),0,'missing submission before local 03:00 close has no issue');
select is(
  public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001',1,20,null,null,'3e000000-0000-4000-8000-000000000001',null,null,'sales_tracking',null,null)->>'total',
  '1',
  'branch filter limits sales tracking issues'
);
select is(
  public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001',1,20,null,null,null,'1e000000-0000-4000-8000-000000000003',null,'sales_tracking',null,null)->>'total',
  '1',
  'supervisor filter includes derived missed issue'
);
select is(
  public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000005','2e000000-0000-4000-8000-000000000001',1,20,null,null,null,null,'1e000000-0000-4000-8000-000000000003','sales_tracking',null,null)->>'total',
  '0',
  'affected staff filter returns no Sales Tracking issues without denying the full issue list'
);
select ok(position('Actual and POS totals do not match' in public.get_sales_tracking_managed_issue(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    (select (issue->>'id')::uuid from sales_tracking_issue_list, jsonb_array_elements(payload->'issues') issue where issue->>'title' = 'Sales Tracking variance issue')
  )->>'remark') > 0,
  'variance issue detail explains mismatch'
);
select ok(position('No fake submission was created' in public.get_sales_tracking_managed_issue(
    '1e000000-0000-4000-8000-000000000005',
    '2e000000-0000-4000-8000-000000000001',
    (select (issue->>'id')::uuid from sales_tracking_issue_list, jsonb_array_elements(payload->'issues') issue where issue->>'title' = 'Missing Sales Tracking submission')
  )->>'remark') > 0,
  'missing issue detail explains derived issue'
);
select throws_ok($$
  select public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000006','2e000000-0000-4000-8000-000000000001')
$$, '42501', 'sales tracking issue access denied', 'other manager is denied');
select throws_ok($$
  select public.list_sales_tracking_managed_issues('1e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001')
$$, '42501', 'sales tracking issue access denied', 'supervisor is denied');

select * from finish();
rollback;
