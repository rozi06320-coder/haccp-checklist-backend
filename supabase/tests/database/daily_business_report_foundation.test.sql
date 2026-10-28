begin;
select no_plan();

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@daily-report.invalid','{}','{}',now(),now()
from unnest(array[
  '17000000-0000-4000-8000-000000000001'::uuid,
  '17000000-0000-4000-8000-000000000002',
  '17000000-0000-4000-8000-000000000003'
])id;
update public.profiles set full_name='Daily Report Test',must_change_password=false
where id::text like'17000000-%';
insert into public.organizations(id,name,slug,active)values
  ('27000000-0000-4000-8000-000000000001','Daily Report Org','daily-report-org',true),
  ('27000000-0000-4000-8000-000000000002','Other Daily Report Org','other-daily-report-org',true);
insert into public.organization_memberships(organization_id,user_id,role,active)values
  ('27000000-0000-4000-8000-000000000001','17000000-0000-4000-8000-000000000001','organization_manager',true),
  ('27000000-0000-4000-8000-000000000002','17000000-0000-4000-8000-000000000002','organization_manager',true);
insert into public.internal_admin_memberships(user_id,active)values
  ('17000000-0000-4000-8000-000000000003',true);
insert into public.branches(id,organization_id,name,code,timezone,active)values
  ('37000000-0000-4000-8000-000000000001','27000000-0000-4000-8000-000000000001','Riyadh Branch','DR-RUH','Asia/Riyadh',true),
  ('37000000-0000-4000-8000-000000000002','27000000-0000-4000-8000-000000000001','Dubai Branch','DR-DXB','Asia/Dubai',true),
  ('37000000-0000-4000-8000-000000000003','27000000-0000-4000-8000-000000000002','Other Branch','DR-OTHER','Asia/Riyadh',true);

select has_table('public','daily_report_branch_lifecycle','branch lifecycle exists');
select has_table('private','daily_business_report_activations','activation cutoff exists');
select has_table('private','daily_business_report_generation_jobs','private queue exists');
select has_table('private','daily_business_report_job_recovery_audit','recovery audit exists');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.daily_business_reports'::regclass),'report identity has RLS');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='private.daily_business_report_activations'::regclass),'activation table has RLS');
select ok(not has_table_privilege('authenticated','public.daily_business_reports','select'),'authenticated cannot read reports directly');
select ok(not has_table_privilege('service_role','public.daily_business_report_revisions','select'),'service role uses RPCs');
select ok(not has_function_privilege('authenticated','public.finalize_daily_business_report_generation_job(uuid,uuid,uuid,date,integer,timestamptz,jsonb,text,text)','execute'),'authenticated cannot finalize');
select ok(has_function_privilege('service_role','public.finalize_daily_business_report_generation_job(uuid,uuid,uuid,date,integer,timestamptz,jsonb,text,text)','execute'),'service role can finalize atomically');
select ok(to_regprocedure('public.store_daily_business_report_revision(uuid,date,integer,timestamptz,jsonb,text,text)')is null,'independent storage RPC does not exist');
select ok(to_regprocedure('public.complete_daily_business_report_generation_job(uuid,uuid,text,text,timestamptz)')is null,'independent completion RPC does not exist');
select ok(to_regprocedure('public.claim_daily_business_report_generation_jobs(uuid,integer,integer,timestamptz)')is null,'claim has no caller-controlled clock');

select is(private.phase4a_business_date_at('Asia/Riyadh','2026-10-26 00:59:59+00'),date'2026-10-25','Riyadh remains before rollover');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-10-26 01:00:00+00'),date'2026-10-26','Riyadh rolls at 04:00');
select is(private.daily_business_report_branch_close_at('2026-03-28','Europe/London'),'2026-03-29 03:00:00+00'::timestamptz,'DST-safe close');

select is((select count(*)::integer from public.daily_report_module_applicability
  where branch_id='37000000-0000-4000-8000-000000000001'),7,'new active branch gets seven modules');
select is((select effective_from_business_date from public.daily_report_branch_lifecycle
  where branch_id='37000000-0000-4000-8000-000000000001'),
  private.phase4a_business_date('Asia/Riyadh')+1,'new branch starts on its next local business date');
select is((select requirement_basis from public.daily_report_module_applicability
  where branch_id='37000000-0000-4000-8000-000000000001'and module_key='staff_hygiene'),
  'eligible_operational_staff','Staff Hygiene basis is conditional');
select is((select requirement_basis from public.daily_report_module_applicability
  where branch_id='37000000-0000-4000-8000-000000000001'and module_key='cold_storage'),
  'eligible_cold_storage_equipment','Cold Storage basis is conditional');
select is((select requirement_basis from public.daily_report_module_applicability
  where branch_id='37000000-0000-4000-8000-000000000001'and module_key='oil_tracking'),
  'eligible_oil_tracking_fryers','Oil Tracking basis is conditional');
select is((select count(*)::integer from public.daily_report_module_applicability
  where branch_id='37000000-0000-4000-8000-000000000001'
    and module_key in('kitchen_closing','foh_closing','cash_monitoring','maintenance')),0,
  'closing, duplicate cash and maintenance requirements are absent');

update public.branches set active=false where id='37000000-0000-4000-8000-000000000001';
select is((select active from public.daily_report_branch_lifecycle where branch_id='37000000-0000-4000-8000-000000000001'and effective_to_business_date is null),false,'same-boundary deactivation captured');
update public.branches set active=true,timezone='Asia/Dubai' where id='37000000-0000-4000-8000-000000000001';
select is((select timezone from public.daily_report_branch_lifecycle where branch_id='37000000-0000-4000-8000-000000000001'and effective_to_business_date is null),'Asia/Dubai','same-boundary reactivation and timezone change captured');
select is((select count(*)::integer from public.daily_report_branch_lifecycle where branch_id='37000000-0000-4000-8000-000000000001'),1,'repeated changes collapse at the same future boundary');

delete from public.daily_report_module_applicability where organization_id in('27000000-0000-4000-8000-000000000001','27000000-0000-4000-8000-000000000002');
delete from public.daily_report_branch_lifecycle where organization_id in('27000000-0000-4000-8000-000000000001','27000000-0000-4000-8000-000000000002');
insert into public.daily_report_branch_lifecycle(organization_id,branch_id,effective_from_business_date,effective_to_business_date,active,timezone)values
 ('27000000-0000-4000-8000-000000000001','37000000-0000-4000-8000-000000000001','2026-01-01','2026-01-20',true,'Asia/Riyadh'),
 ('27000000-0000-4000-8000-000000000001','37000000-0000-4000-8000-000000000001','2026-01-20','2026-01-21',false,'Asia/Riyadh'),
 ('27000000-0000-4000-8000-000000000001','37000000-0000-4000-8000-000000000001','2026-01-21','2026-01-25',true,'Asia/Riyadh'),
 ('27000000-0000-4000-8000-000000000001','37000000-0000-4000-8000-000000000001','2026-01-25',null,true,'Asia/Dubai'),
 ('27000000-0000-4000-8000-000000000001','37000000-0000-4000-8000-000000000002','2026-01-02',null,true,'Asia/Dubai'),
 ('27000000-0000-4000-8000-000000000002','37000000-0000-4000-8000-000000000003','2026-01-01',null,true,'Asia/Riyadh');
insert into public.daily_report_module_applicability(organization_id,branch_id,module_key,requirement_basis,effective_from_business_date,required)
select lifecycle.organization_id,lifecycle.branch_id,module.module_key,
 case module.module_key when'staff_hygiene'then'eligible_operational_staff'
  when'cold_storage'then'eligible_cold_storage_equipment'
  when'oil_tracking'then'eligible_oil_tracking_fryers'else'static'end,
 date'2026-01-01',true
from(select distinct organization_id,branch_id from public.daily_report_branch_lifecycle)lifecycle
cross join pg_catalog.unnest(array['kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking','sales_tracking']::text[])module(module_key);

select is((select count(*)::integer from jsonb_array_elements(private.daily_business_report_eligibility_snapshot('27000000-0000-4000-8000-000000000001','2026-01-20')->'branches')),1,'deactivated branch excluded');
select is((select count(*)::integer from jsonb_array_elements(private.daily_business_report_eligibility_snapshot('27000000-0000-4000-8000-000000000001','2026-01-21')->'branches')),2,'reactivated branch restored');
select is(private.daily_business_report_organization_due_at('27000000-0000-4000-8000-000000000001','2026-01-10'),'2026-01-11 01:00:00+00'::timestamptz,'organization waits for latest close');

create function pg_temp.daily_report_module(
  p_status text,p_required boolean,p_basis text,p_expected integer,p_submitted integer,
  p_missing integer,p_issues integer,p_path text,p_sales boolean default false
)returns jsonb language sql immutable as $$
 select jsonb_build_object('status',p_status,'required',p_required,'requirement_basis',p_basis,
  'expected_count',p_expected,'submitted_count',p_submitted,'missing_count',p_missing,
  'issue_count',p_issues,'source_report_ids','[]'::jsonb,'detail_path',p_path)
  ||case when p_sales then jsonb_build_object('cash_monitoring_source_report_id',null)else'{}'::jsonb end
$$;
create function pg_temp.daily_report_payload(p_org uuid,p_date date,p_path text default'/management/reports')
returns jsonb language sql stable as $$
 with eligible as(
  select value branch from jsonb_array_elements(private.daily_business_report_eligibility_snapshot(p_org,p_date)->'branches')
 ),branch_payload as(
  select jsonb_build_object('branch_id',branch->>'branch_id','modules',jsonb_build_object(
   'kitchen_opening',pg_temp.daily_report_module('missing',true,'static',1,0,1,0,p_path),
   'foh_opening',pg_temp.daily_report_module('missing',true,'static',1,0,1,0,p_path),
   'staff_hygiene',pg_temp.daily_report_module('not_applicable',false,'eligible_operational_staff',0,0,0,0,p_path),
   'daily_audit',pg_temp.daily_report_module('missing',true,'static',1,0,1,0,p_path),
   'cold_storage',pg_temp.daily_report_module('missing',true,'eligible_cold_storage_equipment',1,0,1,0,p_path),
   'oil_tracking',pg_temp.daily_report_module('missing',true,'eligible_oil_tracking_fryers',1,0,1,0,p_path),
   'sales_tracking',pg_temp.daily_report_module('missing',true,'static',1,0,1,0,p_path,true)
  ))value from eligible
 ),counts as(select count(*)::integer n from eligible)
 select jsonb_build_object('organization_id',p_org,'business_date',p_date,
  'summary',jsonb_build_object('required_count',n*6,'submitted_count',0,'missing_count',n*6,
   'issue_count',0,'not_applicable_count',n,'unavailable_count',0),
  'branches',coalesce((select jsonb_agg(value order by value->>'branch_id')from branch_payload),'[]'::jsonb))
 from counts
$$;

select throws_ok(format('select * from public.enqueue_daily_business_report_generation_job(%L,%L,%L)',
 '27000000-0000-4000-8000-000000000001','2026-01-10','wm-a'),'55000',
 'daily business report is outside the active reporting window','scheduler is fail-closed before activation');
insert into private.daily_business_report_activations(organization_id,activated_at,created_at)
values('27000000-0000-4000-8000-000000000001','2026-01-05 00:00+00','2026-01-05 00:00+00');
select throws_ok(format('select * from public.enqueue_daily_business_report_generation_job(%L,%L,%L)',
 '27000000-0000-4000-8000-000000000001','2026-01-01','old-wm'),'55000',
 'daily business report is outside the active reporting window','pre-activation backlog is rejected');

select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 '57000000-0000-4000-8000-000000000099','58000000-0000-4000-8000-000000000099',
 '27000000-0000-4000-8000-000000000001','2026-01-10','2026-01-11 02:00+00',
 pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-10'),'wm-a','initial'),
 '55000','daily business report lease is not active','storage without a claimed job is denied');

select * from public.enqueue_daily_business_report_generation_job('27000000-0000-4000-8000-000000000001','2026-01-10','wm-a');
create temporary table claim_a as select * from public.claim_daily_business_report_generation_jobs('57000000-0000-4000-8000-000000000001',1,600);
select is((select count(*)::integer from claim_a),1,'due job claimed');
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_a),'58000000-0000-4000-8000-000000000099','27000000-0000-4000-8000-000000000001','2026-01-10',
 '2026-01-11 02:00+00',pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-10'),'wm-a','initial'),
 '55000','daily business report lease is not active','wrong lease denied');

create temporary table invalid_payload as select jsonb_set(pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-10'),'{branches,0,modules,kitchen_opening,status}','"forged"')payload;
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_a),(select lease_token from claim_a),'27000000-0000-4000-8000-000000000001','2026-01-10',
 '2026-01-11 02:00+00',(select payload from invalid_payload),'wm-a','initial'),
 '22023','invalid daily business report module payload','invalid status denied');
select is((select state from private.daily_business_report_generation_jobs where id=(select job_id from claim_a)),'running','failed validation leaves claimed job unchanged');
select is((select count(*)::integer from public.daily_business_report_revisions),0,'failed finalization rolls back revision storage');

create temporary table revision_a as select * from public.finalize_daily_business_report_generation_job(
 (select job_id from claim_a),(select lease_token from claim_a),'27000000-0000-4000-8000-000000000001','2026-01-10',1,
 '2026-01-11 02:00+00',pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-10'),
 'wm-a','initial');
select is((select revision from revision_a),1,'atomic finalization creates revision one');
select is((select state from private.daily_business_report_generation_jobs where id=(select job_id from claim_a)),'completed','atomic finalization completes job');

select * from public.enqueue_daily_business_report_generation_job('27000000-0000-4000-8000-000000000001','2026-01-10','wm-b');
create temporary table claim_b as select * from public.claim_daily_business_report_generation_jobs('57000000-0000-4000-8000-000000000001',1,600);
create temporary table revision_b as select * from public.finalize_daily_business_report_generation_job(
 (select job_id from claim_b),(select lease_token from claim_b),'27000000-0000-4000-8000-000000000001','2026-01-10',1,
 '2026-01-11 03:00+00',pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-10','/management/reports/b'),
 'wm-b','source_correction');
select is((select revision from revision_b),2,'A to B creates revision two');
select * from public.enqueue_daily_business_report_generation_job('27000000-0000-4000-8000-000000000001','2026-01-10','wm-c');
create temporary table claim_c as select * from public.claim_daily_business_report_generation_jobs('57000000-0000-4000-8000-000000000001',1,600);
create temporary table revision_c as select * from public.finalize_daily_business_report_generation_job(
 (select job_id from claim_c),(select lease_token from claim_c),'27000000-0000-4000-8000-000000000001','2026-01-10',1,
 '2026-01-11 04:00+00',pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-10'),
 'wm-c','source_correction');
select is((select revision from revision_c),3,'A to B to A is accepted');
select is((select count(*)::integer from public.daily_business_report_revisions),3,'all immutable revisions retained');

select * from public.enqueue_daily_business_report_generation_job('27000000-0000-4000-8000-000000000001','2026-01-11','wm-invalid');
create temporary table claim_invalid as select * from public.claim_daily_business_report_generation_jobs('57000000-0000-4000-8000-000000000002',1,600);
create temporary table bad_url as select jsonb_set(pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-11'),'{branches,0,modules,kitchen_opening,detail_path}','"https://attacker.invalid/x"')payload;
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_invalid),(select lease_token from claim_invalid),'27000000-0000-4000-8000-000000000001','2026-01-11',
 '2026-01-12 02:00+00',(select payload from bad_url),'wm-invalid','initial'),
 '22023','invalid daily business report detail path','external URL denied');
create temporary table bad_count as select jsonb_set(pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-11'),'{summary,missing_count}','999')payload;
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_invalid),(select lease_token from claim_invalid),'27000000-0000-4000-8000-000000000001','2026-01-11',
 '2026-01-12 02:00+00',(select payload from bad_count),'wm-invalid','initial'),
 '22023','daily business report summary mismatch','invalid aggregate count denied');
create temporary table bad_module_count as select jsonb_set(jsonb_set(
 pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-11'),
 '{branches,0,modules,kitchen_opening,missing_count}','2'),'{summary,missing_count}','13')payload;
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_invalid),(select lease_token from claim_invalid),'27000000-0000-4000-8000-000000000001','2026-01-11',
 '2026-01-12 02:00+00',(select payload from bad_module_count),'wm-invalid','initial'),
 '22023','daily business report source or count mismatch','invalid module count denied');
create temporary table fake_source as select jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(
 pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-11'),
 '{branches,0,modules,sales_tracking,status}','"submitted"'),
 '{branches,0,modules,sales_tracking,submitted_count}','1'),
 '{branches,0,modules,sales_tracking,missing_count}','0'),
 '{branches,0,modules,sales_tracking,source_report_ids}','["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"]'),
 '{branches,0,modules,sales_tracking,cash_monitoring_source_report_id}','"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"')payload;
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_invalid),(select lease_token from claim_invalid),'27000000-0000-4000-8000-000000000001','2026-01-11',
 '2026-01-12 02:00+00',(select payload from fake_source),'wm-invalid','initial'),
 '22023','daily business report source or count mismatch','fabricated source ID denied');
insert into public.sales_tracking_reports(
 id,organization_id,branch_id,supervisor_user_id,business_date,state,submitted_at,
 branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,submitted_by_name_snapshot
)values(
 'e1000000-0000-4000-8000-000000000001','27000000-0000-4000-8000-000000000002',
 '37000000-0000-4000-8000-000000000003','17000000-0000-4000-8000-000000000002',
 '2026-01-11','submitted',statement_timestamp(),'Other Branch','Daily Report Test','Branch shared','Daily Report Test');
create temporary table cross_tenant_source as select jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(
 pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-11'),
 '{branches,0,modules,sales_tracking,status}','"submitted"'),
 '{branches,0,modules,sales_tracking,submitted_count}','1'),
 '{branches,0,modules,sales_tracking,missing_count}','0'),
 '{branches,0,modules,sales_tracking,source_report_ids}','["e1000000-0000-4000-8000-000000000001"]'),
 '{branches,0,modules,sales_tracking,cash_monitoring_source_report_id}','"e1000000-0000-4000-8000-000000000001"')payload;
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_invalid),(select lease_token from claim_invalid),'27000000-0000-4000-8000-000000000001','2026-01-11',
 '2026-01-12 02:00+00',(select payload from cross_tenant_source),'wm-invalid','initial'),
 '22023','daily business report source or count mismatch','cross-tenant source ID denied');
create temporary table split_cash_source as select jsonb_set(
 pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-11'),
 '{branches,0,modules,sales_tracking,cash_monitoring_source_report_id}','"e1000000-0000-4000-8000-000000000001"')payload;
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_invalid),(select lease_token from claim_invalid),'27000000-0000-4000-8000-000000000001','2026-01-11',
 '2026-01-12 02:00+00',(select payload from split_cash_source),'wm-invalid','initial'),
 '22023','cash monitoring must share the authoritative sales report','Cash Monitoring cannot reference a different report');

update private.daily_business_report_generation_jobs set lease_expires_at=statement_timestamp()-interval'1 second'
where id=(select job_id from claim_invalid);
select throws_ok(format('select * from public.finalize_daily_business_report_generation_job(%L,%L,%L,%L,1,%L,%L::jsonb,%L,%L)',
 (select job_id from claim_invalid),(select lease_token from claim_invalid),'27000000-0000-4000-8000-000000000001','2026-01-11',
 '2026-01-12 02:00+00',pg_temp.daily_report_payload('27000000-0000-4000-8000-000000000001','2026-01-11'),'wm-invalid','initial'),
 '55000','daily business report lease is not active','expired lease denied using server clock');

create temporary table reclaimed as select * from public.claim_daily_business_report_generation_jobs('57000000-0000-4000-8000-000000000003',1,600);
update private.daily_business_report_generation_jobs set lease_token='58000000-0000-4000-8000-000000000088'
where id=(select job_id from reclaimed);
select throws_ok(format('select * from public.release_daily_business_report_generation_job(%L,%L,%L,%L)',
 (select job_id from reclaimed),(select lease_token from reclaimed),'retry','source_unavailable'),
 '55000','daily business report lease is not active','replaced lease denied');
select is((select state from public.release_daily_business_report_generation_job(
 (select job_id from reclaimed),'58000000-0000-4000-8000-000000000088','failed','source_unavailable')),
 'failed','active lease can mark terminal failure');
select is((select state from public.requeue_failed_daily_business_report_generation_job(
 '17000000-0000-4000-8000-000000000003',(select job_id from reclaimed),'wm-invalid','operator reviewed source outage')),
 'retry','failed job can be safely requeued');
select is((select count(*)::integer from private.daily_business_report_job_recovery_audit where job_id=(select job_id from reclaimed)),1,'failed-job recovery is audited');
select is((select attempt_count from private.daily_business_report_generation_jobs where id=(select job_id from reclaimed)),0,'recovery resets bounded attempt window');

select is((select count(*)::integer from public.get_daily_business_report(
 '17000000-0000-4000-8000-000000000001','27000000-0000-4000-8000-000000000001','2026-01-10',null)),1,'manager reads own report');
select throws_ok($$select * from public.get_daily_business_report(
 '17000000-0000-4000-8000-000000000001','27000000-0000-4000-8000-000000000002','2026-01-10',null)$$,
 '42501','daily business report access denied','cross-tenant read denied');
select throws_ok(format('update public.daily_business_report_revisions set source_watermark=%L where id=%L',
 'tampered',(select revision_id from revision_a)),'42501','daily business report revision is immutable','revision update denied');
select throws_ok(format('delete from public.daily_business_report_revisions where id=%L',(select revision_id from revision_a)),
 '42501','daily business report revision is immutable','revision delete denied');

select * from finish();
rollback;
