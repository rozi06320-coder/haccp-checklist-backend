begin;
select plan(41);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  'a1100000-0000-4000-8000-000000000001'::uuid,
  'a1100000-0000-4000-8000-000000000002'
]) id;

update public.profiles
set full_name = case id
  when 'a1100000-0000-4000-8000-000000000001' then 'Carry Forward Supervisor'
  else 'Other Organization Supervisor'
end,
must_change_password = false
where id::text like 'a1100000-%';

insert into public.organizations(id,name,slug) values
  ('b1100000-0000-4000-8000-000000000001','Carry Forward Org','carry-forward-org'),
  ('b1100000-0000-4000-8000-000000000002','Other Carry Forward Org','other-carry-forward-org');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('c1100000-0000-4000-8000-000000000001','b1100000-0000-4000-8000-000000000001','Carry Branch','CF1','Asia/Riyadh'),
  ('c1100000-0000-4000-8000-000000000002','b1100000-0000-4000-8000-000000000001','Other Branch','CF2','Asia/Riyadh'),
  ('c1100000-0000-4000-8000-000000000003','b1100000-0000-4000-8000-000000000002','Other Org Branch','CF3','Asia/Riyadh'),
  ('c1100000-0000-4000-8000-000000000004','b1100000-0000-4000-8000-000000000001','First Month Branch','CF4','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('c1100000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001','branch_manager',true),
  ('c1100000-0000-4000-8000-000000000002','a1100000-0000-4000-8000-000000000001','branch_manager',true),
  ('c1100000-0000-4000-8000-000000000004','a1100000-0000-4000-8000-000000000001','branch_manager',true),
  ('c1100000-0000-4000-8000-000000000003','a1100000-0000-4000-8000-000000000002','branch_manager',true);

insert into public.inventory_items_reports(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, inventory_month, state, branch_name_snapshot,
  supervisor_name_snapshot, supervisor_team_name_snapshot
) values
  ('d1100000-0000-4000-8000-000000000101','b1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001',null,'2026-01-31','2026-01-01','draft','Carry Branch','Carry Forward Supervisor','Carry Team'),
  ('d1100000-0000-4000-8000-000000000103','b1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001',null,'2026-03-31','2026-03-01','draft','Carry Branch','Carry Forward Supervisor','Carry Team'),
  ('d1100000-0000-4000-8000-000000000104','b1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001',null,'2026-04-30','2026-04-01','draft','Carry Branch','Carry Forward Supervisor','Carry Team'),
  ('d1100000-0000-4000-8000-000000000202','b1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000002','a1100000-0000-4000-8000-000000000001',null,'2026-04-30','2026-04-01','draft','Other Branch','Carry Forward Supervisor','Carry Team'),
  ('d1100000-0000-4000-8000-000000000303','b1100000-0000-4000-8000-000000000002','c1100000-0000-4000-8000-000000000003','a1100000-0000-4000-8000-000000000002',null,'2026-04-30','2026-04-01','draft','Other Org Branch','Other Organization Supervisor','Other Team');

insert into public.inventory_item_usage_items(
  id, report_id, usage_month, group_name, item_name, sort_order, created_by
) values
  ('e1100000-0000-4000-8000-000000000101','d1100000-0000-4000-8000-000000000101','2026-01-01','Main','Old Only',1,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000301','d1100000-0000-4000-8000-000000000103','2026-03-01','Main','Beef',1,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000302','d1100000-0000-4000-8000-000000000103','2026-03-01','Main','Chicken',2,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000303','d1100000-0000-4000-8000-000000000103','2026-03-01','Main','Fries',3,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000304','d1100000-0000-4000-8000-000000000103','2026-03-01','Main','Oil',4,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000305','d1100000-0000-4000-8000-000000000103','2026-03-01','main','BEEF',5,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000306','d1100000-0000-4000-8000-000000000103','2026-03-01','Secondary','Oil',6,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000307','d1100000-0000-4000-8000-000000000103','2026-03-01','Main','Deleted Item',7,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000401','d1100000-0000-4000-8000-000000000104','2026-04-01','Main','Draft Only',1,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000501','d1100000-0000-4000-8000-000000000202','2026-04-01','Main','Cross Branch',1,'a1100000-0000-4000-8000-000000000001'),
  ('e1100000-0000-4000-8000-000000000601','d1100000-0000-4000-8000-000000000303','2026-04-01','Main','Cross Organization',1,'a1100000-0000-4000-8000-000000000002');

update public.inventory_item_usage_items
set deleted_at = '2026-03-30 10:00:00+00',
    deleted_by_user_id = 'a1100000-0000-4000-8000-000000000001'
where id = 'e1100000-0000-4000-8000-000000000307';

insert into public.inventory_item_usage_day_values(id,item_id,day_number,quantity,created_by) values
  ('f1100000-0000-4000-8000-000000000001','e1100000-0000-4000-8000-000000000301',1,11,'a1100000-0000-4000-8000-000000000001');

insert into public.inventory_beef_production_rows(
  id, report_id, production_date, russian_kg, australian_kg, fat_kg,
  ready_patty, hunch_sauce_kg, wastage_grams, created_by,
  russian_label_snapshot, australian_label_snapshot, hunch_sauce_label_snapshot
) values (
  'f1100000-0000-4000-8000-000000000101','d1100000-0000-4000-8000-000000000103','2026-03-15',10,5,1,20,2,0,
  'a1100000-0000-4000-8000-000000000001','Russian kg','Australian kg','Hunch sauce kg'
);

update public.inventory_items_reports
set state = 'submitted', submitted_at = inventory_month + interval '1 month',
    submitted_by_user_id = supervisor_user_id,
    submitted_by_name_snapshot = supervisor_name_snapshot
where id in (
  'd1100000-0000-4000-8000-000000000101',
  'd1100000-0000-4000-8000-000000000103',
  'd1100000-0000-4000-8000-000000000202',
  'd1100000-0000-4000-8000-000000000303'
);

select has_function('private','inventory_items_carry_forward_items_json',array['uuid','uuid','date','uuid'],'carry-forward helper exists');
select ok((select prosecdef from pg_catalog.pg_proc where oid='private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)'::regprocedure),'carry-forward helper is SECURITY DEFINER');
select ok((select coalesce(array_to_string(proconfig,','),'') like '%search_path=%' from pg_catalog.pg_proc where oid='private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)'::regprocedure),'carry-forward helper fixes search_path');
select is(has_function_privilege('authenticated','private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)','execute'),false,'authenticated cannot execute carry-forward helper');
select is(has_function_privilege('service_role','public.get_inventory_items_current_state(uuid,uuid,date)','execute'),true,'service role retains current-state access');

select is((select count(*) from public.inventory_items_reports where branch_id='c1100000-0000-4000-8000-000000000001' and inventory_month='2026-05-01'),0::bigint,'target month initially has no report');
select is((select count(*) from public.inventory_item_usage_items item join public.inventory_items_reports report on report.id=item.report_id where report.branch_id='c1100000-0000-4000-8000-000000000001' and report.inventory_month='2026-05-01'),0::bigint,'target month initially has no Item Usage rows');

create temp table _may_state on commit drop as
select public.get_inventory_items_current_state(
  'a1100000-0000-4000-8000-000000000001',
  'c1100000-0000-4000-8000-000000000001',
  '2026-05-01'
) as value;

select is(jsonb_array_length(value->'item_usage'->'items'),5,'new month projects four unique Main names plus same-name different-group row') from _may_state;
select is((select jsonb_agg(item->>'item_name' order by ordinal) from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') with ordinality projected(item,ordinal)),
  '["Beef", "Chicken", "Fries", "Oil", "Oil"]'::jsonb,'projection uses latest submitted source ordering and ignores newer draft');
select is((select count(*) from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item where lower(item->>'item_name')='beef'),1::bigint,'normalized duplicate identity is projected once');
select is((select count(*) from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item where item->>'item_name'='Oil'),2::bigint,'same item name in different groups remains distinct');
select ok((select bool_and(not (item ? 'id')) from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item),'projected rows omit source UUIDs');
select ok((select bool_and(item->'usage'='{}'::jsonb) from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item),'projected rows have empty usage values');
select ok(not exists(select 1 from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item where item->>'item_name'='Deleted Item'),'source tombstone is excluded');
select ok(not exists(select 1 from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item where item->>'item_name'='Cross Branch'),'source selection is branch-isolated');
select ok(not exists(select 1 from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item where item->>'item_name'='Cross Organization'),'source selection is organization-isolated');
select is(jsonb_array_length((select value->'beef_rows' from _may_state)),0,'source Beef Production rows are not carried');
select is((select value->>'report_id' from _may_state),null::text,'read-only projection has no target report ID');
select is((select count(*) from public.inventory_items_reports where branch_id='c1100000-0000-4000-8000-000000000001' and inventory_month='2026-05-01'),0::bigint,'first load creates no target report');

select lives_ok($$select public.get_inventory_items_current_state(
  'a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','2026-05-01')$$,
  'repeated target load succeeds');
select is((select count(*) from public.inventory_item_usage_items item join public.inventory_items_reports report on report.id=item.report_id where report.branch_id='c1100000-0000-4000-8000-000000000001' and report.inventory_month='2026-05-01'),0::bigint,'repeated load creates no Item Usage rows');

select lives_ok($sql$select public.save_inventory_items_draft(
  'a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','[]'::jsonb,
  '{"usage_month":"2026-05-01","items":[
    {"group_name":"Main","item_name":"Beef","usage":{"1":"2"}},
    {"group_name":"Main","item_name":"Chicken","usage":{}},
    {"group_name":"Main","item_name":"Fries","usage":{}},
    {"group_name":"Main","item_name":"Oil","usage":{}},
    {"group_name":"Secondary","item_name":"Oil","usage":{}}
  ]}'::jsonb)$sql$,'first ordinary Save Changes persists projected names');
select is((select count(*) from public.inventory_items_reports where branch_id='c1100000-0000-4000-8000-000000000001' and inventory_month='2026-05-01'),1::bigint,'first save creates one target report');
select is((select count(*) from public.inventory_item_usage_items item join public.inventory_items_reports report on report.id=item.report_id where report.branch_id='c1100000-0000-4000-8000-000000000001' and report.inventory_month='2026-05-01' and item.deleted_at is null),5::bigint,'first save creates five target Item Usage rows');
select is((select count(*) from public.inventory_item_usage_items target_item join public.inventory_items_reports target_report on target_report.id=target_item.report_id where target_report.inventory_month='2026-05-01' and target_item.id in (select source_item.id from public.inventory_item_usage_items source_item where source_item.report_id='d1100000-0000-4000-8000-000000000103')),0::bigint,'first save assigns fresh target row UUIDs');
select is((select count(*) from public.inventory_item_usage_day_values value join public.inventory_item_usage_items item on item.id=value.item_id join public.inventory_items_reports report on report.id=item.report_id where report.inventory_month='2026-05-01' and report.branch_id='c1100000-0000-4000-8000-000000000001'),1::bigint,'only newly entered target quantity is persisted');
select ok((select bool_and(item ? 'id') from jsonb_array_elements(public.get_inventory_items_current_state('a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','2026-05-01')->'item_usage'->'items') item),'existing target rows are returned with persisted IDs instead of reseeding');
select is(public.get_inventory_items_current_state('a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','2026-05-01')->'item_usage'->'items'->0->'usage'->>'1','2','target state contains only the new target quantity');

select lives_ok($sql$select public.save_inventory_items_draft(
  'a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','[]'::jsonb,
  '{"usage_month":"2026-05-01","items":[
    {"group_name":"Main","item_name":"Beef","usage":{"1":"2"}},
    {"group_name":"Main","item_name":"Chicken","usage":{}},
    {"group_name":"Main","item_name":"Fries","usage":{}},
    {"group_name":"Main","item_name":"Oil","usage":{}},
    {"group_name":"Secondary","item_name":"Oil","usage":{}}
  ]}'::jsonb)$sql$,'same first-save payload is concurrency-safe and idempotent');
select is((select count(*) from public.inventory_item_usage_items item join public.inventory_items_reports report on report.id=item.report_id where report.branch_id='c1100000-0000-4000-8000-000000000001' and report.inventory_month='2026-05-01'),5::bigint,'replayed save does not duplicate target items');

insert into public.inventory_items_reports(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,business_date, inventory_month, state,
  branch_name_snapshot, supervisor_name_snapshot, supervisor_team_name_snapshot
) values
  ('d1100000-0000-4000-8000-000000000106','b1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001',null,'2026-06-30','2026-06-01','draft','Carry Branch','Carry Forward Supervisor','Carry Team'),
  ('d1100000-0000-4000-8000-000000000107','b1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001',null,'2026-07-31','2026-07-01','draft','Carry Branch','Carry Forward Supervisor','Carry Team');
insert into public.inventory_item_usage_items(id,report_id,usage_month,group_name,item_name,sort_order,created_by)
values ('e1100000-0000-4000-8000-000000000701','d1100000-0000-4000-8000-000000000106','2026-06-01','Main','Removed Target Item',1,'a1100000-0000-4000-8000-000000000001');
update public.inventory_item_usage_items
set deleted_at='2026-06-02 10:00:00+00',deleted_by_user_id='a1100000-0000-4000-8000-000000000001'
where id='e1100000-0000-4000-8000-000000000701';
insert into public.inventory_beef_production_rows(
  id,report_id,production_date,russian_kg,australian_kg,fat_kg,ready_patty,hunch_sauce_kg,wastage_grams,created_by,
  russian_label_snapshot,australian_label_snapshot,hunch_sauce_label_snapshot
) values ('f1100000-0000-4000-8000-000000000107','d1100000-0000-4000-8000-000000000107','2026-07-10',1,1,0,2,0,0,'a1100000-0000-4000-8000-000000000001','Russian kg','Australian kg','Hunch sauce kg');

select is(jsonb_array_length(public.get_inventory_items_current_state('a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','2026-06-01')->'item_usage'->'items'),0,'tombstoned target history prevents reseeding');
select is(jsonb_array_length(public.get_inventory_items_current_state('a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','2026-07-01')->'item_usage'->'items'),5,'Beef-only target report may project prior submitted Item Usage names');
select is(jsonb_array_length(public.get_inventory_items_current_state('a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','2026-07-01')->'beef_rows'),1,'Beef-only target returns only its own Beef rows');
select is(jsonb_array_length(public.get_inventory_items_current_state('a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000004','2026-05-01')->'item_usage'->'items'),0,'first-ever branch month remains empty for frontend static fallback');

select throws_ok($sql$select public.save_inventory_items_draft(
  'a1100000-0000-4000-8000-000000000001','c1100000-0000-4000-8000-000000000001','[]'::jsonb,
  '{"usage_month":"2026-03-01","items":[]}'::jsonb)$sql$,'23505',null,'submitted source month remains immutable');
select is((select count(*) from public.inventory_item_usage_day_values where item_id='e1100000-0000-4000-8000-000000000301'),1::bigint,'source quantity remains unchanged');
select ok(exists(select 1 from pg_catalog.pg_constraint where conrelid='public.inventory_items_reports'::regclass and conname='inventory_items_reports_organization_branch_month_key'),'branch/month uniqueness remains enforced');
select ok(pg_catalog.pg_get_functiondef('private.lock_inventory_items_month(uuid,date)'::regprocedure) like '%pg_advisory_xact_lock%','ordinary persistence retains branch/month advisory locking');
select ok(
  pg_catalog.strpos(pg_catalog.lower(pg_catalog.pg_get_functiondef('public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'::regprocedure)), 'perform private.lock_inventory_items_month') > 0
  and pg_catalog.strpos(pg_catalog.lower(pg_catalog.pg_get_functiondef('public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'::regprocedure)), 'perform private.lock_inventory_items_month')
    < pg_catalog.strpos(pg_catalog.lower(pg_catalog.pg_get_functiondef('public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'::regprocedure)), 'select * into report'),
  'first-save path locks the branch/month before canonical report lookup'
);
select ok(not exists(select 1 from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item where item->>'item_name'='Draft Only'),'newer draft month is ignored');
select ok(not exists(select 1 from _may_state cross join lateral jsonb_array_elements(value->'item_usage'->'items') item where item->>'item_name'='Old Only'),'latest eligible submitted month wins over older submitted month');

select * from finish();
rollback;
