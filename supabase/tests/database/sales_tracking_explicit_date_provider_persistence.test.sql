begin;
select plan(21);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@explicit-provider.invalid','{}','{}',now(),now()
from unnest(array['1d000000-0000-4000-8000-000000000001'::uuid]) id;

update public.profiles
set full_name='Explicit Provider Supervisor',must_change_password=false
where id='1d000000-0000-4000-8000-000000000001';

insert into public.organizations(id,name,slug)values
 ('2d000000-0000-4000-8000-000000000001','Explicit Provider Org','explicit-provider-org'),
 ('2d000000-0000-4000-8000-000000000002','External Provider Org','external-provider-org');

insert into public.branches(id,organization_id,name,code,timezone)values
 ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Provider Primary','EPP','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','Provider Secondary','EPS','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000002','Provider External','EPE','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role)values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager'),
 ('3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000001','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)values
 ('4d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001'),
 ('4d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000001');

select lives_ok(format($$select public.save_sales_tracking_draft(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','%s',0,'middle_shift',
 '[{"entry_date":"%s","actual_cash":100,"actual_credit":50,"pos_cash":90,"pos_credit":60,"online_delivery":150,"online_amounts":[{"provider_id":"%s","amount":100},{"provider_id":"%s","amount":50}]}]',
 '[{"entry_date":"%s","remaining_cash":0}]')$$,
 private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),
 (select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000001'and default_provider_key='jahez'),
 (select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000001'and default_provider_key='ninja'),
 private.phase4a_business_date('Asia/Riyadh')),'seven-argument Middle Shift saves provider breakdown');

select is((select count(*)from public.sales_tracking_sales_rows row join public.sales_tracking_reports report on report.id=row.report_id where report.branch_id='3d000000-0000-4000-8000-000000000001'),1::bigint,'Middle Shift creates one sales row');
select is((select online_delivery::text from public.sales_tracking_sales_rows row join public.sales_tracking_reports report on report.id=row.report_id where report.branch_id='3d000000-0000-4000-8000-000000000001'),'150','Middle Shift preserves compatibility aggregate');
select is((select count(*)from public.sales_tracking_online_amounts where branch_id='3d000000-0000-4000-8000-000000000001'),2::bigint,'Middle Shift creates two provider rows');
select is((select sum(amount)::text from public.sales_tracking_online_amounts where branch_id='3d000000-0000-4000-8000-000000000001'),'150','Middle Shift provider total is 150');
select is(jsonb_array_length(public.get_sales_tracking_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'))->'sales_rows'->0->'online_amounts'),2,'current state restores Middle Shift providers');

select lives_ok(format($$select public.save_sales_tracking_draft(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','%s',1,'closing_shift',
 '[{"entry_date":"%s","actual_cash":10,"actual_credit":20,"pos_cash":10,"pos_credit":20,"online_delivery":25,"online_amounts":[{"provider_id":"%s","amount":25}]}]',
 '[{"entry_date":"%s","remaining_cash":0}]')$$,
 private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),
 (select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000001'and default_provider_key='hungerstation'),
 private.phase4a_business_date('Asia/Riyadh')),'seven-argument Closing Shift saves its provider breakdown');

select is((select count(*)from public.sales_tracking_online_amounts amount join public.sales_tracking_sales_rows row on row.id=amount.sales_row_id join public.sales_tracking_period_entries period on period.id=row.period_entry_id where period.entry_period='closing_shift'and amount.branch_id='3d000000-0000-4000-8000-000000000001'),1::bigint,'Closing Shift creates one provider row');
select is((select sum(amount.amount)::text from public.sales_tracking_online_amounts amount join public.sales_tracking_sales_rows row on row.id=amount.sales_row_id join public.sales_tracking_period_entries period on period.id=row.period_entry_id where period.entry_period='middle_shift'and amount.branch_id='3d000000-0000-4000-8000-000000000001'),'150','Middle Shift provider rows remain separate');
select is((select sum(amount.amount)::text from public.sales_tracking_online_amounts amount join public.sales_tracking_sales_rows row on row.id=amount.sales_row_id join public.sales_tracking_period_entries period on period.id=row.period_entry_id where period.entry_period='closing_shift'and amount.branch_id='3d000000-0000-4000-8000-000000000001'),'25','Closing Shift provider rows remain separate');
select is((select count(distinct sales_row_id)from public.sales_tracking_online_amounts where branch_id='3d000000-0000-4000-8000-000000000001'),2::bigint,'provider rows are attached to their own period sales rows');

select throws_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',0,'middle_shift','[{"entry_date":"%s","online_delivery":9,"online_amounts":[{"provider_id":"%s","amount":8}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),(select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000002'and default_provider_key='jahez'),private.phase4a_business_date('Asia/Riyadh')),'23514','sales tracking online provider total mismatch','provider total mismatch is rejected');
select throws_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',0,'middle_shift','[{"entry_date":"%s","online_delivery":1,"online_amounts":[{"provider_id":"not-a-uuid","amount":1}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'22023','invalid sales tracking online provider','invalid provider ID is rejected');
select throws_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',0,'middle_shift','[{"entry_date":"%s","online_delivery":1,"online_amounts":[{"provider_id":"%s","amount":1}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),(select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000001'and default_provider_key='jahez'),private.phase4a_business_date('Asia/Riyadh')),'22023','invalid sales tracking online provider scope','provider from another branch is rejected');
select throws_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',0,'middle_shift','[{"entry_date":"%s","online_delivery":1,"online_amounts":[{"provider_id":"%s","amount":1}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),(select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000003'and default_provider_key='jahez'),private.phase4a_business_date('Asia/Riyadh')),'22023','invalid sales tracking online provider scope','provider from another organization is rejected');
select throws_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',0,'middle_shift','[{"entry_date":"%s","online_delivery":2,"online_amounts":[{"provider_id":"%s","amount":1},{"provider_id":"%s","amount":1}]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),(select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000002'and default_provider_key='jahez'),(select id from public.sales_tracking_online_order_providers where branch_id='3d000000-0000-4000-8000-000000000002'and default_provider_key='jahez'),private.phase4a_business_date('Asia/Riyadh')),'22023','duplicate sales tracking online provider','duplicate provider is rejected');

select lives_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',0,'middle_shift','[{"entry_date":"%s","online_delivery":0,"online_amounts":[]}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'empty zero provider breakdown remains valid');
select is((select count(*)from public.sales_tracking_online_amounts where branch_id='3d000000-0000-4000-8000-000000000002'),0::bigint,'zero provider breakdown creates no provider rows');
select throws_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',0,'closing_shift','[{"entry_date":"%s","online_delivery":0}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'PT409','sales tracking changed','stale revision remains a PT409 conflict');
select throws_ok(format($$select public.save_sales_tracking_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','%s',1,'middle_shift','[{"entry_date":"%s","online_delivery":0}]','[{"entry_date":"%s","remaining_cash":0}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'23505','sales tracking period already saved','already-saved period behavior is unchanged');
select is(jsonb_array_length(public.get_sales_tracking_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'))->'sales_rows'->1->'online_amounts'),1,'current state restores Closing Shift provider');

select * from finish();
rollback;
