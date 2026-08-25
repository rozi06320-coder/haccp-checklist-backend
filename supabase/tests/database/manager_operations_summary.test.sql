begin;
select plan(28);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '1d000000-0000-4000-8000-000000000001'::uuid,
  '1d000000-0000-4000-8000-000000000002'
]) id;

update public.profiles set full_name=case id
  when '1d000000-0000-4000-8000-000000000001' then 'Operations Summary Manager'
  else 'Other Operations Summary Manager'
end, must_change_password=false
where id::text like '1d000000-%';

insert into public.organizations(id,name,slug) values
  ('2d000000-0000-4000-8000-000000000001','Operations Summary Org','operations-summary-org'),
  ('2d000000-0000-4000-8000-000000000002','Other Operations Summary Org','other-operations-summary-org');
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Riyadh Closing Complete','OSB-RUH','Asia/Riyadh',true),
  ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','London Closing Draft','OSB-LON','Europe/London',true),
  ('3d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001','Riyadh Closing Missing','OSB-MISS','Asia/Riyadh',true),
  ('3d000000-0000-4000-8000-000000000004','2d000000-0000-4000-8000-000000000001','Inactive Closing Branch','OSB-OFF','Asia/Riyadh',false),
  ('3d000000-0000-4000-8000-000000000005','2d000000-0000-4000-8000-000000000002','Other Operations Summary Branch','OOSB','Asia/Riyadh',true);
insert into public.organization_memberships(organization_id,user_id,role) values
  ('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','organization_manager'),
  ('2d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000002','organization_manager');

insert into public.financial_closing_reports(id,organization_id,branch_id,business_date,state,revision,branch_name_snapshot,branch_code_snapshot,submitted_by_user_id,submitted_by_name_snapshot,submitted_at,updated_by_user_id) values
  ('4d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','2026-08-25','submitted',1,'Riyadh Closing Complete','OSB-RUH','1d000000-0000-4000-8000-000000000001','Operations Summary Manager','2026-08-25 19:00+00','1d000000-0000-4000-8000-000000000001'),
  ('4d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','2026-08-25','draft',1,'London Closing Draft','OSB-LON',null,null,null,'1d000000-0000-4000-8000-000000000001'),
  ('4d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000004','2026-08-25','submitted',1,'Inactive Closing Branch','OSB-OFF','1d000000-0000-4000-8000-000000000001','Operations Summary Manager','2026-08-25 19:00+00','1d000000-0000-4000-8000-000000000001'),
  ('4d000000-0000-4000-8000-000000000004','2d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000005','2026-08-25','submitted',1,'Other Operations Summary Branch','OOSB','1d000000-0000-4000-8000-000000000002','Other Operations Summary Manager','2026-08-25 19:00+00','1d000000-0000-4000-8000-000000000002');
insert into public.financial_closing_items(report_id,item_key,status,reason,follow_up) values
  ('4d000000-0000-4000-8000-000000000001','sales_closing','not_completed','Variance remains open','Manager follow-up required');

select is((select count(*)::text from public.financial_closing_reports report join public.financial_closing_items item on item.report_id=report.id where report.id='4d000000-0000-4000-8000-000000000001' and report.state='submitted' and item.status='not_completed'),'1','submitted report with not-completed items represents issues-found completion');

select ok(not has_function_privilege('authenticated','public.get_managed_operations_summary(uuid,uuid,uuid,date)','execute')
  and has_function_privilege('service_role','public.get_managed_operations_summary(uuid,uuid,uuid,date)','execute'),
  'operations summary RPC is service-role only');

create temp table operations_summary_result as
select public.get_managed_operations_summary(
  '1d000000-0000-4000-8000-000000000001',
  '2d000000-0000-4000-8000-000000000001',
  null,
  '2026-08-01'
) as summary;
grant select on operations_summary_result to service_role;

select is((select summary->'scope'->>'organization_id' from operations_summary_result),'2d000000-0000-4000-8000-000000000001','manager receives own organization summary');
select is((select summary->'scope'->>'month' from operations_summary_result),'2026-08','requested Gregorian month is retained');
select is((select summary->'purchase_logs'->>'unpaid_amount' from operations_summary_result),'0','empty purchase logs return a decimal string zero');
select is((select summary->'inventory'->>'active_branch_count' from operations_summary_result),'3','empty inventory still reports active branches only');
select is((select summary->'staff'->>'active_count' from operations_summary_result),'0','empty staff returns zero');
select is((select summary->'availability'->>'inventory' from operations_summary_result),'ready','empty source is ready rather than unavailable');
select is((select summary->'availability'->>'financial_closing' from operations_summary_result),'ready','financial closing summary is ready with empty or partial source data');
select is((select summary->'financial_closing'->>'total_branches' from operations_summary_result),'3','financial closing excludes inactive and other-organization branches');
select is((select summary->'financial_closing'->>'completed_today' from operations_summary_result),'1','submitted current-day financial closing counts completed even with not-completed items');
select is((select summary->'financial_closing'->>'pending_today' from operations_summary_result),'2','draft and missing current-day financial closings count pending');
select is(((select (summary->'financial_closing'->>'completed_today')::int + (summary->'financial_closing'->>'pending_today')::int from operations_summary_result))::text,'3','completed plus pending equals total branches');

select is(jsonb_array_length(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001',null,'2026-08-24 22:30+00')->'business_dates')::text,'2','branch-local business dates are grouped independently');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001',null,'2026-08-24 23:30+00')->>'completed_today','1','after-hours summary keeps submitted current report completed');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001',null,'2026-08-24 23:30+00')->>'pending_today','2','after-hours summary keeps draft and missing current reports pending');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001',null,'2026-08-24 23:30+00')->>'overdue_prior_day','2','prior-day missing reports after 02:00 branch-local count overdue');
select is(((private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001',null,'2026-08-24 23:30+00')->>'completed_today')::int + (private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001',null,'2026-08-24 23:30+00')->>'pending_today')::int)::text,'3','overdue is separate from today completed/pending invariant');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','2026-08-24 23:30+00')->>'total_branches','1','branch filter scopes financial closing total');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','2026-08-24 23:30+00')->>'completed_today','1','branch filter scopes completed count');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','2026-08-24 23:30+00')->>'overdue_prior_day','1','overdue may overlap a completed-today branch');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','2026-08-24 23:30+00')->>'pending_today','1','draft current report counts pending');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','2026-08-24 23:30+00')->>'overdue_prior_day','0','prior date before 02:00 branch-local does not count overdue');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000003','2026-08-24 23:30+00')->>'pending_today','1','missing current report counts pending');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000003','2026-08-24 23:30+00')->>'overdue_prior_day','1','missing prior report can overlap a pending-today branch');
select is(private.managed_financial_closing_operations_summary('2d000000-0000-4000-8000-000000000002',null,'2026-08-24 23:30+00')->>'total_branches','1','other organization is scoped independently');

set local role service_role;
select throws_ok($$select public.get_managed_operations_summary('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',null,'2026-08-01')$$,
  '42501','operations summary access denied','cross-organization manager is denied');
select throws_ok($$select public.get_managed_operations_summary('1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000005','2026-08-01')$$,
  '42501','operations summary access denied','branch outside organization is denied');
reset role;

select * from finish();
rollback;
