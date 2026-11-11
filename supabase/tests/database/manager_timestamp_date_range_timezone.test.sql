begin;
select plan(29);

-- Schema-valid rows around local midnight exercise the RPC predicates themselves.
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','9d000000-0000-4000-8000-000000000001','authenticated','authenticated','date-range-manager@example.invalid','{}','{}',now(),now());
insert into public.organizations(id,name,slug)
values('9d000000-0000-4000-8000-000000000002','Date Range Test Org','date-range-test-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('9d000000-0000-4000-8000-000000000003','9d000000-0000-4000-8000-000000000002','Riyadh Date Branch','DRR','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role,active)
values('9d000000-0000-4000-8000-000000000002','9d000000-0000-4000-8000-000000000001','organization_manager',true);
insert into public.profiles(id,full_name,must_change_password)
values('9d000000-0000-4000-8000-000000000001','Date Range Manager',false)
on conflict (id) do nothing;
update public.daily_report_branch_lifecycle
set effective_from_business_date='2026-11-01', effective_to_business_date=null
where organization_id='9d000000-0000-4000-8000-000000000002'
  and branch_id='9d000000-0000-4000-8000-000000000003';
insert into public.branch_supplier_receivings(
  id,organization_id,branch_id,category,supplier_name_en,quantity,unit,created_by,created_at,updated_at
) values
 ('9d000000-0000-4000-8000-000000000004','9d000000-0000-4000-8000-000000000002','9d000000-0000-4000-8000-000000000003','raw','Boundary Supplier',1,'kg','9d000000-0000-4000-8000-000000000001','2026-11-08 20:59:59+00','2026-11-08 20:59:59+00'),
 ('9d000000-0000-4000-8000-000000000005','9d000000-0000-4000-8000-000000000002','9d000000-0000-4000-8000-000000000003','raw','Boundary Supplier',1,'kg','9d000000-0000-4000-8000-000000000001','2026-11-08 21:00:00+00','2026-11-08 21:00:00+00');
insert into public.maintenance_issues(
  id,organization_id,branch_id,title,category,priority,status,reported_by,created_at,updated_at
) values
 ('9d000000-0000-4000-8000-000000000006','9d000000-0000-4000-8000-000000000002','9d000000-0000-4000-8000-000000000003','Boundary Issue','equipment','normal','new','9d000000-0000-4000-8000-000000000001','2026-11-08 20:59:59+00','2026-11-08 20:59:59+00'),
 ('9d000000-0000-4000-8000-000000000007','9d000000-0000-4000-8000-000000000002','9d000000-0000-4000-8000-000000000003','Boundary Issue','equipment','normal','new','9d000000-0000-4000-8000-000000000001','2026-11-08 21:00:00+00','2026-11-08 21:00:00+00');

select has_table('public','daily_report_branch_lifecycle','branch lifecycle is the authoritative historical timezone source');
select has_column('public','daily_report_branch_lifecycle','effective_from_business_date','lifecycle has an effective start date');
select has_column('public','daily_report_branch_lifecycle','effective_to_business_date','lifecycle has an effective end date');
select has_column('public','daily_report_branch_lifecycle','timezone','lifecycle stores the authoritative timezone');

select ok(position('daily_report_branch_lifecycle' in pg_get_functiondef('public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)'::regprocedure)) > 0,
  'supplier receiving date filters use lifecycle timezone evidence');
select ok(position('at time zone lifecycle.timezone' in pg_get_functiondef('public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)'::regprocedure)) > 0,
  'supplier receiving filters convert timestamps using the lifecycle timezone');
select ok(position('daily_report_branch_lifecycle' in pg_get_functiondef('public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)'::regprocedure)) > 0,
  'maintenance issue date filters use lifecycle timezone evidence');
select ok(position('at time zone lifecycle.timezone' in pg_get_functiondef('public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)'::regprocedure)) > 0,
  'maintenance issue filters convert timestamps using the lifecycle timezone');

select ok(not has_function_privilege('authenticated','public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)','execute')
  and not has_function_privilege('anon','public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)','execute')
  and has_function_privilege('service_role','public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)','execute'),
  'supplier receiving manager read remains service-role only');
select ok(not has_function_privilege('authenticated','public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)','execute')
  and not has_function_privilege('anon','public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)','execute')
  and has_function_privilege('service_role','public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)','execute'),
  'maintenance issue manager read remains service-role only');

-- Riyadh changes local date at 21:00 UTC (UTC+03:00).
select is(('2026-11-08 20:59:59+00'::timestamptz at time zone 'Asia/Riyadh')::date,'2026-11-08'::date,'Riyadh before midnight remains on the prior local date');
select is(('2026-11-08 21:00:00+00'::timestamptz at time zone 'Asia/Riyadh')::date,'2026-11-09'::date,'Riyadh at local midnight enters the next local date');
-- Dubai changes local date at 20:00 UTC (UTC+04:00).
select is(('2026-11-08 19:59:59+00'::timestamptz at time zone 'Asia/Dubai')::date,'2026-11-08'::date,'Dubai before midnight remains on the prior local date');
select is(('2026-11-08 20:00:00+00'::timestamptz at time zone 'Asia/Dubai')::date,'2026-11-09'::date,'Dubai at local midnight enters the next local date');

select is(('2026-11-08 20:59:59+00'::timestamptz at time zone 'Asia/Riyadh')::date >= '2026-11-08'::date,true,'Riyadh inclusive lower bound includes the date');
select is(('2026-11-08 21:00:00+00'::timestamptz at time zone 'Asia/Riyadh')::date <= '2026-11-09'::date,true,'Riyadh inclusive upper bound includes the date');
select is(('2026-11-08 19:59:59+00'::timestamptz at time zone 'Asia/Dubai')::date >= '2026-11-08'::date,true,'Dubai inclusive lower bound includes the date');
select is(('2026-11-08 20:00:00+00'::timestamptz at time zone 'Asia/Dubai')::date <= '2026-11-09'::date,true,'Dubai inclusive upper bound includes the date');

select is((select count(*) from public.list_managed_supplier_receivings('9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',null,null,null,'2026-11-08','2026-11-08')),1::bigint,'supplier date range uses branch-local Riyadh date');
select is((select count(*) from public.list_managed_supplier_receivings('9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',null,null,null,'2026-11-09','2026-11-09')),1::bigint,'supplier next local date includes the UTC-midnight boundary row');
select is((select count(*) from public.list_managed_maintenance_issues('9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',null,null,null,null,'2026-11-08','2026-11-08')),1::bigint,'maintenance date range uses branch-local Riyadh date');
select is((select count(*) from public.list_managed_maintenance_issues('9d000000-0000-4000-8000-000000000001','9d000000-0000-4000-8000-000000000002',null,null,null,null,'2026-11-09','2026-11-09')),1::bigint,'maintenance next local date includes the UTC-midnight boundary row');

select ok(position('effective_to_business_date is null' in pg_get_functiondef('public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)'::regprocedure)) > 0,
  'supplier filter handles open lifecycle intervals');
select ok(position('effective_to_business_date is null' in pg_get_functiondef('public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)'::regprocedure)) > 0,
  'maintenance filter handles open lifecycle intervals');
select ok(position('effective_to_business_date' in pg_get_functiondef('public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date)'::regprocedure)) > 0,
  'supplier filter does not invent a current timezone for historical rows');
select ok(position('effective_to_business_date' in pg_get_functiondef('public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date)'::regprocedure)) > 0,
  'maintenance filter does not invent a current timezone for historical rows');

select throws_ok($$select * from public.list_managed_supplier_receivings('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002',null,null,null,'2026-11-01','2026-11-02')$$,
  '42501','managed supplier receiving access denied','supplier cross-organization access is denied');
select throws_ok($$select * from public.list_managed_maintenance_issues('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002',null,null,null,null,'2026-11-01','2026-11-02')$$,
  '42501','managed maintenance issue access denied','maintenance cross-organization access is denied');

select is((select count(*) from public.daily_report_branch_lifecycle where effective_to_business_date is not null and effective_to_business_date <= effective_from_business_date),0::bigint,
  'existing lifecycle periods have no invalid overlap interval');
select * from finish();
rollback;
