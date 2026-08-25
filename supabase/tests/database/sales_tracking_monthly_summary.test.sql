begin;
select plan(37);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1f000000-0000-4000-8000-000000000001'::uuid,
  '1f000000-0000-4000-8000-000000000002',
  '1f000000-0000-4000-8000-000000000003',
  '1f000000-0000-4000-8000-000000000004',
  '1f000000-0000-4000-8000-000000000005'
]) id;

update public.profiles set full_name = case id
  when '1f000000-0000-4000-8000-000000000001' then 'Monthly Manager'
  when '1f000000-0000-4000-8000-000000000002' then 'Other Monthly Manager'
  else 'Monthly Supervisor'
end, must_change_password = false
where id::text like '1f000000-%';

insert into public.organizations(id,name,slug) values
  ('2f000000-0000-4000-8000-000000000001','Monthly Sales Org','monthly-sales-org'),
  ('2f000000-0000-4000-8000-000000000002','Other Monthly Sales Org','other-monthly-sales-org');

insert into public.branches(id,organization_id,name,name_ar,code,timezone,active) values
  ('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Monthly Alpha','ألفا الشهرية','MALPHA','Asia/Riyadh',true),
  ('3f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','Monthly Historical','تاريخي شهري','MALPHA','Asia/Riyadh',false),
  ('3f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000002','Other Monthly Branch','فرع شهري آخر','MOTHER','Asia/Riyadh',true);

insert into public.organization_memberships(organization_id,user_id,role) values
  ('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','organization_manager'),
  ('2f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000002','organization_manager');

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003','branch_manager'),
  ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000004','branch_manager'),
  ('3f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000005','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,active) values
  ('4f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003',true),
  ('4f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000004',true),
  ('4f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000005',false);

insert into public.sales_tracking_reports(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,submitted_at,
  branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot
) values
  ('5f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003','4f000000-0000-4000-8000-000000000001','2026-07-05','draft',null,'Monthly Alpha','Monthly Supervisor One','Monthly Team One'),
  ('5f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000004','4f000000-0000-4000-8000-000000000002','2026-07-08','draft',null,'Monthly Alpha','Monthly Supervisor Two','Monthly Team Two'),
  ('5f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003','4f000000-0000-4000-8000-000000000001','2026-07-06','draft',null,'Monthly Alpha','Monthly Supervisor One','Monthly Team One'),
  ('5f000000-0000-4000-8000-000000000004','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000005','4f000000-0000-4000-8000-000000000003','2026-07-06','draft',null,'Monthly Historical','Monthly Supervisor Three','Monthly Team Three'),
  ('5f000000-0000-4000-8000-000000000005','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000005','4f000000-0000-4000-8000-000000000003','2026-07-07','draft',null,'Monthly Historical','Monthly Supervisor Three','Monthly Team Three');

insert into public.sales_tracking_sales_rows(
  report_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,remarks
) values
  ('5f000000-0000-4000-8000-000000000001','2026-07-05',100,50,80,60,10,'private remark one'),
  ('5f000000-0000-4000-8000-000000000002','2026-07-08',40,60,60,50,0,'private remark two'),
  ('5f000000-0000-4000-8000-000000000003','2026-07-06',999,999,0,0,0,'excluded draft remark'),
  ('5f000000-0000-4000-8000-000000000004','2026-07-06',20,30,20,30,5,'private historical remark');

insert into public.sales_tracking_cash_rows(
  report_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks
) values
  ('5f000000-0000-4000-8000-000000000001','2026-07-05',0,0,0,0,1,0,1,0,0,33,'private cash remark one'),
  ('5f000000-0000-4000-8000-000000000002','2026-07-08',0,0,0,0,0,1,0,0,0,44,'private cash remark two'),
  ('5f000000-0000-4000-8000-000000000003','2026-07-06',0,0,0,0,0,0,0,0,9,999,'excluded draft cash remark'),
  ('5f000000-0000-4000-8000-000000000005','2026-07-07',0,0,0,0,0,0,0,1,0,55,'private cash-only remark');

insert into public.sales_tracking_online_amounts(organization_id,branch_id,report_id,sales_row_id,provider_id,amount)
select '2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','5f000000-0000-4000-8000-000000000001',row.id,provider.id,case provider.default_provider_key when 'jahez' then 7 else 3 end
from public.sales_tracking_sales_rows row
join public.sales_tracking_online_order_providers provider on provider.branch_id='3f000000-0000-4000-8000-000000000001' and provider.default_provider_key in ('jahez','hungerstation')
where row.report_id='5f000000-0000-4000-8000-000000000001';

update public.sales_tracking_reports
set state='submitted',
  submitted_at=case id
    when '5f000000-0000-4000-8000-000000000001' then '2026-07-05T12:00:00Z'::timestamptz
    when '5f000000-0000-4000-8000-000000000002' then '2026-07-08T13:00:00Z'::timestamptz
    when '5f000000-0000-4000-8000-000000000004' then '2026-07-06T12:00:00Z'::timestamptz
    else '2026-07-07T12:00:00Z'::timestamptz
  end
where id in (
  '5f000000-0000-4000-8000-000000000001',
  '5f000000-0000-4000-8000-000000000002',
  '5f000000-0000-4000-8000-000000000004',
  '5f000000-0000-4000-8000-000000000005'
);

select is(has_function_privilege('authenticated','public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)','execute'),false,'authenticated cannot execute monthly summary RPC');
select is(has_function_privilege('service_role','public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)','execute'),true,'service role can execute monthly summary RPC');

select ok(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null) is not null,'own organization manager receives monthly summary');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'submitted_report_count','4','submitted report count excludes draft');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'submitted_branch_day_count','4','submitted branch-day count follows the shared branch daily report model');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'reporting_branch_count','2','inactive historical branch remains represented');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'sales_entry_count','3','sales-only and cash-only reports count honestly');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'cash_entry_count','3','cash entries count independently');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'total_sales','315','monthly sales total is correct');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'total_cash_collected','370','monthly denomination cash total is correct');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'total_variance','0','offsetting variance total is correct');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'balanced_sales_report_count','1','only individually balanced sales report is balanced');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'variance_sales_report_count','2','offsetting variance reports remain variance reports');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->'payment_breakdown'->>'actual_cash','160','actual cash breakdown is correct');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->'payment_breakdown'->>'actual_credit','140','actual credit breakdown is correct');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->'payment_breakdown'->>'online_delivery','15','online delivery breakdown is correct');
select is(
  (select amount->>'amount' from jsonb_array_elements(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->'online_provider_breakdown') amount where amount->>'provider_key'='jahez'),
  '7',
  'monthly provider total includes Jahez'
);
select is(
  (select amount->>'amount' from jsonb_array_elements(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->'online_provider_breakdown') amount where amount->>'provider_key'='hungerstation'),
  '3',
  'monthly provider total includes HungerStation'
);
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->>'legacy_online_delivery','5','monthly legacy online delivery is separated from provider totals');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01','3f000000-0000-4000-8000-000000000001')->'totals'->>'legacy_online_delivery','0','branch filter excludes other branch legacy online delivery');
select is(jsonb_array_length(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01','3f000000-0000-4000-8000-000000000001')->'totals'->'online_provider_breakdown'),2,'branch filter keeps only matching branch provider totals');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->'payment_breakdown'->>'pos_cash','160','POS cash breakdown is correct');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'totals'->'payment_breakdown'->>'pos_credit','140','POS credit breakdown is correct');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01','3f000000-0000-4000-8000-000000000001')->'totals'->>'submitted_report_count','2','branch filter is applied inside RPC');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01','3f000000-0000-4000-8000-000000000001')->'totals'->>'submitted_branch_day_count','2','filtered branch has two submitted days');
select is(jsonb_array_length(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'branches'),2,'branch breakdown includes historical inactive branch');
select is((select count(*) from jsonb_array_elements(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'branches') branch where branch->>'branch_code'='MALPHA'),2::bigint,'same branch code does not merge monthly branch rows');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)->'branches'->1->>'branch_name_ar','تاريخي شهري','Arabic branch name is returned');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-08-01',null)->'totals'->>'submitted_report_count','0','empty month returns zero counts');
select is(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-08-01',null)->'branches','[]'::jsonb,'empty month returns empty branches');
select is(jsonb_typeof(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-08-01',null)->'totals'->'total_sales'),'string','empty money values are decimal strings');
select ok(strpos(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)::text,'supervisor_user_id') = 0,'summary exposes no supervisor IDs');
select ok(strpos(public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01',null)::text,'private remark') = 0,'summary exposes no remarks');
select throws_ok($$select public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','2026-07-01',null)$$,'42501','sales tracking monthly summary access denied','cross-organization manager is denied');
select throws_ok($$select public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001','2026-07-01',null)$$,'42501','sales tracking monthly summary access denied','supervisor is denied');
select throws_ok($$select public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-01','3f000000-0000-4000-8000-000000000003')$$,'42501','sales tracking monthly summary branch denied','cross-organization branch filter is denied');
select throws_ok($$select public.get_managed_sales_tracking_monthly_summary('1f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','2026-07-02',null)$$,'22023','invalid sales tracking month','month must be the first Gregorian day');

select * from finish();
rollback;
