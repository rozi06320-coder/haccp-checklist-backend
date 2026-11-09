-- Disposable runtime suite for 20261108120000_inventory_item_usage_edit_draft.sql.
-- Never run against Production. All fixtures are transaction-local.
begin;
select plan(23);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@example.invalid','{}','{}',pg_catalog.now(),pg_catalog.now()
from unnest(array[
  'e1000000-0000-4000-8000-000000000001'::uuid,
  'e1000000-0000-4000-8000-000000000002'::uuid
]) id;

update public.profiles set full_name='Item Usage Edit Supervisor',must_change_password=false,disabled_at=null
where id='e1000000-0000-4000-8000-000000000001';
update public.profiles set full_name='Item Usage Other Branch Supervisor',must_change_password=false,disabled_at=null
where id='e1000000-0000-4000-8000-000000000002';

insert into public.organizations(id,name,slug)
values('e2000000-0000-4000-8000-000000000001','Item Usage Edit Org','item-usage-edit-runtime');
insert into private.daily_report_timezones(name)
values('Asia/Riyadh') on conflict(name) do nothing;
insert into public.branches(id,organization_id,name,code,timezone) values
  ('e3000000-0000-4000-8000-000000000001','e2000000-0000-4000-8000-000000000001','Item Usage Edit Branch','EUI1','Asia/Riyadh'),
  ('e3000000-0000-4000-8000-000000000002','e2000000-0000-4000-8000-000000000001','Item Usage Other Branch','EUI2','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('e3000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','branch_manager',true),
  ('e3000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000002','branch_manager',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('e4000000-0000-4000-8000-000000000001','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001'),
  ('e4000000-0000-4000-8000-000000000002','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000002');
insert into public.branch_operational_teams(id,organization_id,branch_id,name) values
  ('e5000000-0000-4000-8000-000000000001','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001','Item Usage Edit Team'),
  ('e5000000-0000-4000-8000-000000000002','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000002','Item Usage Other Team');
insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
) values
  ('e5000000-0000-4000-8000-000000000011','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001','e5000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','primary','e1000000-0000-4000-8000-000000000001'),
  ('e5000000-0000-4000-8000-000000000012','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000002','e5000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000002','primary','e1000000-0000-4000-8000-000000000002');

create temp table edit_context on commit drop as
select (pg_catalog.date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date inventory_month,
  (pg_catalog.date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date production_date;

select has_function('public','update_inventory_item_usage_entry',array['uuid','uuid','uuid','timestamptz','jsonb','jsonb','uuid'],
  'dedicated Item Usage edit RPC exists');
select ok(pg_catalog.has_function_privilege('service_role','public.update_inventory_item_usage_entry(uuid,uuid,uuid,timestamptz,jsonb,jsonb,uuid)','EXECUTE'),
  'service_role can execute the edit RPC');
select ok(not pg_catalog.has_function_privilege('anon','public.update_inventory_item_usage_entry(uuid,uuid,uuid,timestamptz,jsonb,jsonb,uuid)','EXECUTE')
  and not pg_catalog.has_function_privilege('authenticated','public.update_inventory_item_usage_entry(uuid,uuid,uuid,timestamptz,jsonb,jsonb,uuid)','EXECUTE'),
  'browser roles cannot execute the edit RPC');
select ok(not pg_catalog.has_table_privilege('anon','public.inventory_item_usage_edit_audits','INSERT')
  and not pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_edit_audits','INSERT'),
  'browser roles cannot write edit audit history');

select lives_ok(format($sql$
  select public.save_inventory_items_draft(
    'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
    '[]'::jsonb,
    '{"usage_month":"%s","items":[{"item_id":"e6000000-0000-4000-8000-000000000001","group_name":"Runtime","item_name":"Editable Usage","usage":{"1":"2","2":"3"}},{"item_id":"e6000000-0000-4000-8000-000000000002","group_name":"Runtime","item_name":"Deletable Empty Usage","usage":{}}]}'::jsonb
  )
$sql$,(select inventory_month from edit_context)), 'draft Item Usage fixture is created');

create temp table edit_snapshot on commit drop as
select report.id report_id,report.updated_at, item.id item_id,
  (select pg_catalog.jsonb_object_agg(value.day_number::text,value.quantity order by value.day_number)
   from public.inventory_item_usage_day_values value where value.item_id=item.id) usage
from public.inventory_items_reports report
join public.inventory_item_usage_items item on item.report_id=report.id
where report.branch_id='e3000000-0000-4000-8000-000000000001' and item.id='e6000000-0000-4000-8000-000000000001';

select lives_ok(format($sql$
  select public.update_inventory_item_usage_entry(
    'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
    'e6000000-0000-4000-8000-000000000001','%s'::timestamptz,'{"1":2,"2":3}'::jsonb,'{"1":"5","2":"3"}'::jsonb,
    'e7000000-0000-4000-8000-000000000001'
  )
$sql$,(select updated_at from edit_snapshot)), 'authorized draft quantity edit succeeds');
select is((select usage from edit_snapshot),'{"1":2,"2":3}'::jsonb,'fixture snapshot retains the original usage');
select is((select quantity from public.inventory_item_usage_day_values where item_id='e6000000-0000-4000-8000-000000000001' and day_number=1),5::numeric,'same day row receives the new quantity');
select is((select report_id from public.inventory_item_usage_items where id='e6000000-0000-4000-8000-000000000001'),(select report_id from edit_snapshot),'same Item Usage identity and report are preserved');
select is((select count(*) from public.inventory_item_usage_edit_audits where item_id='e6000000-0000-4000-8000-000000000001'),1::bigint,'one append-only audit row is written');
select is((select old_usage from public.inventory_item_usage_edit_audits where item_id='e6000000-0000-4000-8000-000000000001'),'{"1":2,"2":3}'::jsonb,'audit stores old quantities');
select is((select new_usage from public.inventory_item_usage_edit_audits where item_id='e6000000-0000-4000-8000-000000000001'),'{"1":5,"2":3}'::jsonb,'audit stores normalized new quantities');

select lives_ok(format($sql$
  select public.update_inventory_item_usage_entry(
    'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
    'e6000000-0000-4000-8000-000000000001','%s'::timestamptz,'{"1":2,"2":3}'::jsonb,'{"1":"5","2":"3"}'::jsonb,
    'e7000000-0000-4000-8000-000000000001'
  )
$sql$,(select updated_at from edit_snapshot)), 'same idempotency key is a successful retry');
select is((select count(*) from public.inventory_item_usage_edit_audits),1::bigint,'idempotent retry does not duplicate audit history');

select throws_ok(format($sql$
  select public.update_inventory_item_usage_entry(
    'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
    'e6000000-0000-4000-8000-000000000001','%s'::timestamptz,'{"1":2,"2":3}'::jsonb,'{"1":"7","2":"3"}'::jsonb,
    'e7000000-0000-4000-8000-000000000002'
  )
$sql$,(select updated_at from edit_snapshot)), '40001',null,'stale expected version is rejected');
select throws_ok($$select public.update_inventory_item_usage_entry(
  'e1000000-0000-4000-8000-000000000002','e3000000-0000-4000-8000-000000000001',
  'e6000000-0000-4000-8000-000000000001',now(),'{}'::jsonb,'{}'::jsonb,
  'e7000000-0000-4000-8000-000000000003')$$,'42501',null,'cross-branch actor is rejected');
select throws_ok($$select public.update_inventory_item_usage_entry(
  'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
  'e6000000-0000-4000-8000-000000000001',now(),'{"1":5,"2":3}'::jsonb,'{"1":8}'::jsonb,
  'e7000000-0000-4000-8000-000000000004')$$,'22023',null,'changing immutable day keys is rejected');
select throws_ok($$update public.inventory_item_usage_day_values set quantity=99
  where item_id='e6000000-0000-4000-8000-000000000001' and day_number=1$$,
  '23505',null,'direct day-value updates still hit the immutable trigger');
select ok(not pg_catalog.has_table_privilege('anon','public.inventory_item_usage_day_values','UPDATE')
  and not pg_catalog.has_table_privilege('authenticated','public.inventory_item_usage_day_values','UPDATE'),
  'direct client day-value updates remain denied');
select lives_ok($$select public.delete_inventory_item_usage_item(
  'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
  'e6000000-0000-4000-8000-000000000002','{}'::jsonb)$$,
  'empty Item Usage row can use the existing soft-delete workflow');
select throws_ok($$select public.update_inventory_item_usage_entry(
  'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
  'e6000000-0000-4000-8000-000000000002',now(),'{}'::jsonb,'{}'::jsonb,
  'e7000000-0000-4000-8000-000000000006')$$,'23505',null,'deleted Item Usage rows cannot be edited');

select lives_ok(format($sql$
  select public.submit_inventory_items(
    'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
    'e8000000-0000-4000-8000-000000000001','runtime-item-usage-edit-submit',
    '[]'::jsonb,'{"usage_month":"%s","items":[{"item_id":"e6000000-0000-4000-8000-000000000001","group_name":"Runtime","item_name":"Editable Usage","usage":{"1":"5","2":"3"}}]}'::jsonb
  )
$sql$,(select inventory_month from edit_context)), 'fixture month can be submitted');
select throws_ok($$select public.update_inventory_item_usage_entry(
  'e1000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001',
  'e6000000-0000-4000-8000-000000000001',now(),'{"1":5,"2":3}'::jsonb,'{"1":9,"2":3}'::jsonb,
  'e7000000-0000-4000-8000-000000000005')$$,'23505',null,'submitted month cannot be edited');

select * from finish();
rollback;
