begin;
select plan(27);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  'aa000000-0000-4000-8000-000000000001'::uuid,
  'aa000000-0000-4000-8000-000000000002',
  'aa000000-0000-4000-8000-000000000003',
  'aa000000-0000-4000-8000-000000000004',
  'aa000000-0000-4000-8000-000000000005',
  'aa000000-0000-4000-8000-000000000006'
]) id;

update public.profiles
set full_name = case id
  when 'aa000000-0000-4000-8000-000000000001' then 'Modern Inventory Supervisor'
  when 'aa000000-0000-4000-8000-000000000002' then 'Legacy Inventory Supervisor'
  when 'aa000000-0000-4000-8000-000000000003' then 'Wrong Branch Supervisor'
  when 'aa000000-0000-4000-8000-000000000004' then 'Inactive Inventory Supervisor'
  when 'aa000000-0000-4000-8000-000000000005' then 'Disabled Inventory Supervisor'
  else 'Password Inventory Supervisor'
end,
must_change_password = id = 'aa000000-0000-4000-8000-000000000006',
disabled_at = case when id = 'aa000000-0000-4000-8000-000000000005' then now() else null end
where id::text like 'aa000000-%';

insert into public.organizations(id,name,slug)
values ('bb000000-0000-4000-8000-000000000001','Modern Inventory Org','modern-inventory-org');

insert into public.branches(id,organization_id,name,code,timezone)
values
  ('cc000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','Modern Inventory Branch','MIB','Asia/Riyadh'),
  ('cc000000-0000-4000-8000-000000000002','bb000000-0000-4000-8000-000000000001','Other Inventory Branch','OIB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('cc000000-0000-4000-8000-000000000001','aa000000-0000-4000-8000-000000000001','branch_manager',true),
  ('cc000000-0000-4000-8000-000000000001','aa000000-0000-4000-8000-000000000002','branch_manager',true),
  ('cc000000-0000-4000-8000-000000000002','aa000000-0000-4000-8000-000000000003','branch_manager',true),
  ('cc000000-0000-4000-8000-000000000001','aa000000-0000-4000-8000-000000000004','branch_manager',false),
  ('cc000000-0000-4000-8000-000000000001','aa000000-0000-4000-8000-000000000005','branch_manager',true),
  ('cc000000-0000-4000-8000-000000000001','aa000000-0000-4000-8000-000000000006','branch_manager',true);

insert into public.branch_operational_teams(id,organization_id,branch_id,name)
values ('dd000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001','Modern Team');

insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
) values (
  'dd000000-0000-4000-8000-000000000002','bb000000-0000-4000-8000-000000000001',
  'cc000000-0000-4000-8000-000000000001','dd000000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001','primary','aa000000-0000-4000-8000-000000000001'
);

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values (
  'dd000000-0000-4000-8000-000000000003','bb000000-0000-4000-8000-000000000001',
  'cc000000-0000-4000-8000-000000000001','aa000000-0000-4000-8000-000000000002'
);

select ok(not (select attnotnull from pg_catalog.pg_attribute
  where attrelid='public.inventory_items_reports'::regclass and attname='supervisor_team_id'),
  'legacy Supervisor-team attribution is nullable');
select is((select count(*) from public.branch_supervisor_teams
  where supervisor_user_id='aa000000-0000-4000-8000-000000000001'),0::bigint,
  'modern Supervisor has no legacy team row');
select is((select count(*) from public.branch_operational_team_supervisors
  where supervisor_user_id='aa000000-0000-4000-8000-000000000001' and active),1::bigint,
  'modern Supervisor has an active operational-team assignment');
select lives_ok($$select public.get_inventory_items_current_state(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001')$$,
  'modern Supervisor without a legacy row can read Inventory Items');

select lives_ok($$select public.update_inventory_beef_production_field_labels(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  'Modern Russian','Modern Australian','Modern Sauce')$$,
  'modern Supervisor can update Beef labels');

select lives_ok(format($sql$select public.create_inventory_beef_production_row(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001','%s',
  '{"russian_kg":"2","australian_kg":"1","fat_kg":"0","ready_patty":"10","hunch_sauce_kg":"1","wastage_grams":"0"}'::jsonb)$sql$,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date),
  'modern Supervisor can create a Beef row');
select is((select supervisor_team_id from public.inventory_items_reports
  where branch_id='cc000000-0000-4000-8000-000000000001'),null::uuid,
  'new report stores NULL when legacy team attribution is unavailable');

create temp table _modern_beef on commit drop as
select beef.id,beef.updated_at
from public.inventory_beef_production_rows beef
join public.inventory_items_reports report on report.id=beef.report_id
where report.branch_id='cc000000-0000-4000-8000-000000000001';

select lives_ok($$select public.update_inventory_beef_production_row(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  (select id from _modern_beef),(select updated_at from _modern_beef),
  '{"russian_kg":"3","australian_kg":"1","fat_kg":"0","ready_patty":"11","hunch_sauce_kg":"1","wastage_grams":"0"}'::jsonb)$$,
  'modern Supervisor can update a Beef row');

select lives_ok(format($sql$select public.save_inventory_items_draft(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  '[{"production_date":"%s","russian_kg":"3","australian_kg":"1","fat_kg":"0","ready_patty":"11","hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
  '{"usage_month":"%s","items":[{"item_id":"ee000000-0000-4000-8000-000000000001","group_name":"Branch","item_name":"Empty Item","usage":{}}]}'::jsonb)$sql$,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date),
  'modern Supervisor can save a draft');
select lives_ok($$select public.delete_inventory_item_usage_item(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  'ee000000-0000-4000-8000-000000000001')$$,
  'modern Supervisor can delete an empty Item Usage row');

select lives_ok(format($sql$select public.submit_inventory_items(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  'ee000000-0000-4000-8000-000000000002','modern-submit-hash',
  '[{"production_date":"%s","russian_kg":"3","australian_kg":"1","fat_kg":"0","ready_patty":"11","hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
  '{"usage_month":"%s","items":[]}'::jsonb)$sql$,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date),
  'modern Supervisor can submit Inventory Items');
select is((select state from public.inventory_items_reports
  where branch_id='cc000000-0000-4000-8000-000000000001'),'submitted',
  'modern submission persists submitted state');
select lives_ok(format($sql$select public.submit_inventory_items(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  'ee000000-0000-4000-8000-000000000002','modern-submit-hash',
  '[{"production_date":"%s","russian_kg":"3","australian_kg":"1","fat_kg":"0","ready_patty":"11","hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
  '{"usage_month":"%s","items":[]}'::jsonb)$sql$,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date),
  'submit idempotency replay remains accepted');
select throws_ok(format($sql$select public.save_inventory_items_draft(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001','[]'::jsonb,
  '{"usage_month":"%s","items":[]}'::jsonb)$sql$,
  (date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date),
  '23505',null,'submitted report remains immutable');
select throws_ok($$select public.update_inventory_beef_production_row(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  (select id from _modern_beef),(select updated_at from public.inventory_beef_production_rows where id=(select id from _modern_beef)),
  '{"russian_kg":"4","australian_kg":"1","fat_kg":"0","ready_patty":"11","hunch_sauce_kg":"1","wastage_grams":"0"}'::jsonb)$$,
  '23514',null,'submitted Beef row remains immutable');

select throws_ok($$select public.get_inventory_items_current_state(
  'aa000000-0000-4000-8000-000000000003','cc000000-0000-4000-8000-000000000001')$$,
  '42501',null,'wrong branch is denied');
select throws_ok($$select public.get_inventory_items_current_state(
  'aa000000-0000-4000-8000-000000000004','cc000000-0000-4000-8000-000000000001')$$,
  '42501',null,'inactive branch membership is denied');
select throws_ok($$select public.get_inventory_items_current_state(
  'aa000000-0000-4000-8000-000000000005','cc000000-0000-4000-8000-000000000001')$$,
  '42501',null,'disabled profile is denied');
select throws_ok($$select public.get_inventory_items_current_state(
  'aa000000-0000-4000-8000-000000000006','cc000000-0000-4000-8000-000000000001')$$,
  '42501',null,'password-change-required profile is denied');
select lives_ok($$select public.get_inventory_items_current_state(
  'aa000000-0000-4000-8000-000000000002','cc000000-0000-4000-8000-000000000001')$$,
  'Supervisor with legacy attribution still works');

select lives_ok($$select public.create_branch_catalog_inventory_item(
  'aa000000-0000-4000-8000-000000000001','cc000000-0000-4000-8000-000000000001',
  '{"name":"Catalog Unchanged","unit":"kg"}'::jsonb)$$,
  'catalog access remains available through its existing branch scope');
select is((select count(*) from public.branch_inventory_catalog_items
  where branch_id='cc000000-0000-4000-8000-000000000001' and name='Catalog Unchanged'),1::bigint,
  'catalog mutation behavior is unchanged');

select is(has_function_privilege('authenticated','public.get_inventory_items_current_state(uuid,uuid)','execute'),false,
  'authenticated cannot execute Inventory Items read RPC directly');
select is(has_function_privilege('service_role','public.get_inventory_items_current_state(uuid,uuid)','execute'),true,
  'service role can execute Inventory Items read RPC');
select ok((select bool_and(prosecdef and coalesce(array_to_string(proconfig,','),'') like '%search_path=%')
  from pg_catalog.pg_proc where oid=any(array[
    'public.get_inventory_items_current_state(uuid,uuid)'::regprocedure,
    'public.get_inventory_items_current_state(uuid,uuid,date)'::regprocedure,
    'public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'::regprocedure,
    'public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)'::regprocedure,
    'public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)'::regprocedure,
    'public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)'::regprocedure,
    'public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb)'::regprocedure,
    'public.delete_inventory_item_usage_item(uuid,uuid,uuid)'::regprocedure
  ])),'affected public RPCs remain SECURITY DEFINER with fixed search_path');
select ok(not exists(select 1 from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where (namespace.nspname,procedure.proname) in (
    ('private','inventory_items_state_json'),('public','save_inventory_items_draft'),
    ('public','submit_inventory_items'),('public','update_inventory_beef_production_field_labels'),
    ('public','create_inventory_beef_production_row'),('public','update_inventory_beef_production_row'),
    ('public','delete_inventory_item_usage_item'))
  and pg_catalog.pg_get_functiondef(procedure.oid) like '%private.phase4a_actor_context%'),
  'no Inventory Items routine retains legacy authorization');
select ok(pg_catalog.pg_get_functiondef('private.require_branch_catalog_scope(uuid,uuid)'::regprocedure)
  not like '%inventory_items_actor_context%',
  'catalog authorization remains independent from Inventory Items changes');

select * from finish();
rollback;
