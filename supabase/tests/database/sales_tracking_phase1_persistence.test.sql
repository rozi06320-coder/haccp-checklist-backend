begin;
select plan(36);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@sales-base.invalid','{}','{}',now(),now()
from unnest(array['1c000000-0000-4000-8000-000000000001'::uuid,'1c000000-0000-4000-8000-000000000002','1c000000-0000-4000-8000-000000000003'])id;
update public.profiles set full_name=case when id='1c000000-0000-4000-8000-000000000001'then'Sales Supervisor One'when id='1c000000-0000-4000-8000-000000000002'then'Sales Supervisor Two'else'Sales Manager'end,must_change_password=false where id::text like'1c000000-%';
insert into public.organizations(id,name,slug)values('2c000000-0000-4000-8000-000000000001','Sales Tracking Org','sales-tracking-org');
insert into public.branches(id,organization_id,name,code,timezone)values('3c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','Sales Branch','SALES','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)values('2c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)values('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001','branch_manager'),('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)values('4c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001'),('4c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002');

select has_table('public','sales_tracking_reports','sales tracking report table exists');
select has_table('public','sales_tracking_sales_rows','sales tracking sales rows table exists');
select has_table('public','sales_tracking_cash_rows','sales tracking cash rows table exists');
select col_is_pk('public','sales_tracking_reports','id','sales tracking report UUID PK');
select col_is_pk('public','sales_tracking_sales_rows','id','sales tracking sales row UUID PK');
select col_is_pk('public','sales_tracking_cash_rows','id','sales tracking cash row UUID PK');
select ok((select relrowsecurity from pg_class where oid='public.sales_tracking_reports'::regclass),'sales tracking reports RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.sales_tracking_sales_rows'::regclass),'sales rows RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.sales_tracking_cash_rows'::regclass),'cash rows RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.sales_tracking_period_entries'::regclass),'period entries RLS enabled');
select ok(not has_function_privilege('authenticated','public.get_sales_tracking_current_state(uuid,uuid)','execute'),'authenticated cannot call current-state RPC');
select ok(not has_function_privilege('authenticated','public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb)','execute'),'authenticated cannot call save RPC');
select ok(not has_function_privilege('authenticated','public.submit_sales_tracking(uuid,uuid,bigint,uuid,text)','execute'),'authenticated cannot call submit RPC');
select ok(has_function_privilege('service_role','public.get_sales_tracking_current_state(uuid,uuid)','execute'),'service role can call current-state RPC');
select ok(has_function_privilege('service_role','public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb)','execute'),'service role can call save RPC');
select ok(has_function_privilege('service_role','public.submit_sales_tracking(uuid,uuid,bigint,uuid,text)','execute'),'service role can call submit RPC');
select ok(not has_table_privilege('authenticated','public.sales_tracking_reports','insert')and not has_table_privilege('authenticated','public.sales_tracking_sales_rows','insert')and not has_table_privilege('authenticated','public.sales_tracking_cash_rows','insert')and not has_table_privilege('authenticated','public.sales_tracking_period_entries','insert'),'authenticated has no direct Sales writes');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'business_date',private.phase4a_business_date('Asia/Riyadh')::text,'empty state uses server business date');
select is(jsonb_array_length(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'periods'),0,'empty state has no periods');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision','0','empty state starts at revision zero');

select lives_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',0,'middle_shift','[{"entry_date":"%s","actual_cash":"100","actual_credit":50,"pos_cash":90,"pos_credit":60,"online_delivery":25,"remarks":" lunch "}]','[{"entry_date":"%s","denom_1":1,"denom_2":2,"denom_5":3,"denom_10":4,"denom_20":5,"denom_50":6,"denom_100":7,"denom_200":8,"denom_500":9,"remaining_cash":"125.5","remarks":" counted "}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'first supervisor saves Middle Shift');
select is((select count(*)from public.sales_tracking_reports where organization_id='2c000000-0000-4000-8000-000000000001'and branch_id='3c000000-0000-4000-8000-000000000001'),1::bigint,'one branch/day report exists');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->'sales_rows'->0->>'actual_total','175','same-branch peer restores computed Middle Shift total');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->'cash_rows'->0->>'cash_total','7260','same-branch peer restores denomination total');
select throws_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,'middle_shift','[{"entry_date":"%s","actual_cash":-1}]','[]')$$,private.phase4a_business_date('Asia/Riyadh')),'22023','invalid sales tracking numeric field','negative values are rejected');
select throws_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,'closing_shift','[]','[{"entry_date":"%s","denom_5":1.5}]')$$,private.phase4a_business_date('Asia/Riyadh')),'22023','invalid sales tracking denomination field','non-integer denominations are rejected');
select throws_ok($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,'closing_shift','[{"entry_date":"2000-01-01","actual_cash":1}]','[]')$$,'22023','sales tracking entry date mismatch','entry date must match branch business date');
select lives_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',1,'closing_shift','[{"entry_date":"%s","actual_cash":7,"actual_credit":8,"pos_cash":6,"pos_credit":6,"online_delivery":2}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'second supervisor saves Closing Shift');
select is(jsonb_array_length(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->'periods'),2,'first supervisor reloads both periods');
select lives_ok($$select public.submit_sales_tracking('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',2,'5c000000-0000-4000-8000-000000000001',repeat('a',64))$$,'complete branch/day report submits');
select is(public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->>'state','submitted','same-branch peer sees submitted state');
select lives_ok($$select public.submit_sales_tracking('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',2,'5c000000-0000-4000-8000-000000000001',repeat('a',64))$$,'same idempotency key and hash replay');
select throws_ok($$select public.submit_sales_tracking('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001',2,'5c000000-0000-4000-8000-000000000001',repeat('b',64))$$,'23505','sales tracking idempotency conflict','changed idempotent replay conflicts');
select throws_ok(format($$select public.save_sales_tracking_draft('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001',3,'closing_shift','[{"entry_date":"%s","actual_cash":999}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'23505','sales tracking already submitted','submitted report cannot reopen');
select throws_ok($$select public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000003','3c000000-0000-4000-8000-000000000001')$$,'42501','sales tracking state denied','manager cannot use supervisor state RPC');
select throws_ok($$select public.get_sales_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000099')$$,'42501','sales tracking state denied','unrelated branch is denied');

select * from finish();
rollback;
