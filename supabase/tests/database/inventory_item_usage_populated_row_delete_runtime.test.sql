-- Disposable pgTAP runtime suite for a database where all migrations through
-- 20261101120000 have been applied. Never run this against Production.
-- Every synthetic row is contained in this transaction and final ROLLBACK.
--
-- The stale-snapshot case proves the outcome of an edit serialized ahead of a
-- delete. True simultaneous blocking/lock timing still requires two sessions;
-- see the release assessment accompanying this file.

begin;
select plan(23);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@example.invalid','{}','{}',pg_catalog.now(),pg_catalog.now()
from unnest(array[
  'f1000000-0000-4000-8000-000000000001'::uuid,
  'f1000000-0000-4000-8000-000000000002',
  'f1000000-0000-4000-8000-000000000003'
]) id;

update public.profiles
set full_name=case id
  when 'f1000000-0000-4000-8000-000000000001' then 'Runtime Inventory Supervisor'
  when 'f1000000-0000-4000-8000-000000000002' then 'Runtime Other Branch Supervisor'
  else 'Runtime Inventory Manager' end,
  must_change_password=false,disabled_at=null
where id::text like 'f1000000-%';

insert into public.organizations(id,name,slug)
values('f2000000-0000-4000-8000-000000000001','Runtime Inventory Org','runtime-inventory-delete-org');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('f3000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','Runtime Inventory Branch','RID1','Asia/Riyadh'),
  ('f3000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000001','Runtime Other Branch','RID2','Asia/Riyadh');

insert into public.organization_memberships(organization_id,user_id,role)
values('f2000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000003','organization_manager');

insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('f3000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','branch_manager',true),
  ('f3000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002','branch_manager',true);

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('f4000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001'),
  ('f4000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002');

insert into public.branch_operational_teams(id,organization_id,branch_id,name) values
  ('f5000000-0000-4000-8000-000000000001','f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001','Runtime Team One'),
  ('f5000000-0000-4000-8000-000000000002','f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002','Runtime Team Two');

insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
) values
  ('f5000000-0000-4000-8000-000000000011','f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001','f5000000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000001','primary','f1000000-0000-4000-8000-000000000001'),
  ('f5000000-0000-4000-8000-000000000012','f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000002','f5000000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000002','primary','f1000000-0000-4000-8000-000000000002');

create temp table runtime_context on commit drop as
select
  (pg_catalog.date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date inventory_month,
  (pg_catalog.date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))-interval '1 month')::date production_date;

select has_function('public','delete_inventory_item_usage_item',array['uuid','uuid','uuid','jsonb'],
  'new four-argument delete RPC exists');
select is(pg_catalog.to_regprocedure('public.delete_inventory_item_usage_item(uuid,uuid,uuid)'),null::regprocedure,
  'legacy three-argument delete RPC is absent');

select lives_ok(format($sql$
  select public.save_inventory_items_draft(
    'f1000000-0000-4000-8000-000000000001',
    'f3000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"1","australian_kg":"1","fat_kg":"0","ready_patty":"1","hunch_sauce_kg":"0","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s","items":[
      {"item_id":"f6000000-0000-4000-8000-000000000001","group_name":"Runtime","item_name":"Populated Tombstone","usage":{"1":"2","2":"3"}},
      {"item_id":"f6000000-0000-4000-8000-000000000002","group_name":"Runtime","item_name":"Submitted Denial Target","usage":{}}
    ]}'::jsonb
  )
$sql$,(select production_date from runtime_context),(select inventory_month from runtime_context)),
  'synthetic populated and empty Item Usage rows save in a draft month');

select is((select count(*) from public.inventory_item_usage_day_values where item_id='f6000000-0000-4000-8000-000000000001'),2::bigint,
  'populated row starts with two immutable day values');

select lives_ok(format($sql$
  select public.save_inventory_items_draft(
    'f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"1","australian_kg":"1","fat_kg":"0","ready_patty":"1","hunch_sauce_kg":"0","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s","items":[
      {"item_id":"f6000000-0000-4000-8000-000000000001","group_name":"Runtime","item_name":"Populated Tombstone","usage":{"1":"2","2":"3","3":"4"}},
      {"item_id":"f6000000-0000-4000-8000-000000000002","group_name":"Runtime","item_name":"Submitted Denial Target","usage":{}}
    ]}'::jsonb
  )
$sql$,(select production_date from runtime_context),(select inventory_month from runtime_context)),
  'a serialized concurrent editor can append a new immutable day value');

select throws_ok($sql$
  select public.delete_inventory_item_usage_item(
    'f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',
    'f6000000-0000-4000-8000-000000000001','{"1":"2","2":"3"}'::jsonb
  )
$sql$,'40001',null,'stale pre-edit expected_usage snapshot is rejected');

select is((select count(*) from public.inventory_item_usage_day_values where item_id='f6000000-0000-4000-8000-000000000001'),3::bigint,
  'stale delete rejection preserves all concurrent day values');

select lives_ok($sql$
  select public.delete_inventory_item_usage_item(
    'f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',
    'f6000000-0000-4000-8000-000000000001','{"1":"2","2":"3","3":"4"}'::jsonb
  )
$sql$,'current populated snapshot can be tombstoned');

select ok((select deleted_at is not null and deleted_by_user_id='f1000000-0000-4000-8000-000000000001'
  from public.inventory_item_usage_items where id='f6000000-0000-4000-8000-000000000001'),
  'parent records one-way tombstone actor and timestamp');

select is((select pg_catalog.jsonb_object_agg(day_number::text,quantity order by day_number)
  from public.inventory_item_usage_day_values where item_id='f6000000-0000-4000-8000-000000000001'),
  '{"1":2,"2":3,"3":4}'::jsonb,'tombstone preserves exact historical day values');

select ok(not exists(
  select 1 from pg_catalog.jsonb_array_elements(public.get_inventory_items_current_state(
    'f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',(select inventory_month from runtime_context)
  )->'item_usage'->'items') item where item->>'id'='f6000000-0000-4000-8000-000000000001'
),'Supervisor authoritative state excludes tombstoned row');

select ok(not exists(
  select 1 from pg_catalog.jsonb_array_elements(public.list_managed_inventory_items_reports(
    'f1000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000001',(select inventory_month from runtime_context),'f3000000-0000-4000-8000-000000000001'
  )->'reports'->0->'item_usage_rows') item where item->>'item_id'='f6000000-0000-4000-8000-000000000001'
),'Manager report/export projection excludes tombstoned row');

select is((public.list_managed_inventory_items_reports(
  'f1000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000001',(select inventory_month from runtime_context),'f3000000-0000-4000-8000-000000000001'
)->'reports'->0->'summary'->>'item_usage_total'),'0','Manager report active usage total excludes tombstoned values');

select is((public.get_managed_operations_summary(
  'f1000000-0000-4000-8000-000000000003','f2000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',(select inventory_month from runtime_context)
)->'inventory'->>'item_usage_row_count'),'1','Manager active row total includes only the remaining row');

select throws_ok($sql$
  update public.inventory_item_usage_day_values set quantity=99
  where item_id='f6000000-0000-4000-8000-000000000001' and day_number=1
$sql$,'23505',null,'historical day values cannot be updated');

select throws_ok($sql$
  delete from public.inventory_item_usage_day_values
  where item_id='f6000000-0000-4000-8000-000000000001' and day_number=1
$sql$,'23505',null,'historical day values cannot be deleted');

create temp table original_delete_metadata on commit drop as
select deleted_at,deleted_by_user_id from public.inventory_item_usage_items
where id='f6000000-0000-4000-8000-000000000001';

select lives_ok($sql$
  select public.delete_inventory_item_usage_item(
    'f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',
    'f6000000-0000-4000-8000-000000000001','{}'::jsonb
  )
$sql$,'correctly scoped repeated delete is idempotent');

select is((select pg_catalog.jsonb_build_object('deleted_at',deleted_at,'deleted_by_user_id',deleted_by_user_id)
  from public.inventory_item_usage_items where id='f6000000-0000-4000-8000-000000000001'),
  (select pg_catalog.jsonb_build_object('deleted_at',deleted_at,'deleted_by_user_id',deleted_by_user_id)
  from original_delete_metadata),'idempotent retry preserves original deletion metadata');

select throws_ok($sql$
  select public.delete_inventory_item_usage_item(
    'f1000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000001',
    'f6000000-0000-4000-8000-000000000002','{}'::jsonb
  )
$sql$,'42501',null,'cross-branch Supervisor cannot delete target branch Item Usage');

select lives_ok(format($sql$
  select public.submit_inventory_items(
    'f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',
    'f7000000-0000-4000-8000-000000000001','runtime-item-delete-submit',
    '[{"production_date":"%s","russian_kg":"1","australian_kg":"1","fat_kg":"0","ready_patty":"1","hunch_sauce_kg":"0","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s","items":[
      {"item_id":"f6000000-0000-4000-8000-000000000002","group_name":"Runtime","item_name":"Submitted Denial Target","usage":{}}
    ]}'::jsonb
  )
$sql$,(select production_date from runtime_context),(select inventory_month from runtime_context)),
  'draft month submits after populated tombstone');

select throws_ok($sql$
  select public.delete_inventory_item_usage_item(
    'f1000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',
    'f6000000-0000-4000-8000-000000000002','{}'::jsonb
  )
$sql$,'23505',null,'submitted month denies a new Item Usage deletion');

select throws_ok($sql$
  delete from public.inventory_item_usage_items where id='f6000000-0000-4000-8000-000000000001'
$sql$,'23505',null,'hard parent deletion remains blocked so ON DELETE CASCADE cannot erase history');

select is((select count(*) from public.inventory_item_usage_day_values where item_id='f6000000-0000-4000-8000-000000000001'),3::bigint,
  'all historical values remain after hard-delete attempt');

select * from finish();
rollback;
