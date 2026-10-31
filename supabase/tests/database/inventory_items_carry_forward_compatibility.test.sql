begin;
select plan(17);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@example.invalid','{}','{}',pg_catalog.now(),pg_catalog.now()
from unnest(array[
  'a1400000-0000-4000-8000-000000000001'::uuid,
  'a1400000-0000-4000-8000-000000000002'
]) id;

update public.profiles set full_name=case id
  when 'a1400000-0000-4000-8000-000000000001' then 'Compatibility Supervisor'
  else 'Other Compatibility Supervisor' end,
  must_change_password=false,disabled_at=null
where id::text like 'a1400000-%';

insert into public.organizations(id,name,slug) values
  ('b1400000-0000-4000-8000-000000000001','Compatibility Org','inventory-compatibility-org'),
  ('b1400000-0000-4000-8000-000000000002','Other Compatibility Org','other-inventory-compatibility-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('c1400000-0000-4000-8000-000000000001','b1400000-0000-4000-8000-000000000001','Compatibility Branch','IC1','Asia/Riyadh'),
  ('c1400000-0000-4000-8000-000000000002','b1400000-0000-4000-8000-000000000002','Other Compatibility Branch','IC2','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('c1400000-0000-4000-8000-000000000001','a1400000-0000-4000-8000-000000000001','branch_manager',true),
  ('c1400000-0000-4000-8000-000000000002','a1400000-0000-4000-8000-000000000002','branch_manager',true);

insert into public.inventory_items_reports(
  id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,
  inventory_month,state,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot
) values
  ('d1400000-0000-4000-8000-000000000001','b1400000-0000-4000-8000-000000000001','c1400000-0000-4000-8000-000000000001','a1400000-0000-4000-8000-000000000001',null,'2026-08-31','2026-08-01','draft','Compatibility Branch','Compatibility Supervisor','Compatibility Team'),
  ('d1400000-0000-4000-8000-000000000002','b1400000-0000-4000-8000-000000000001','c1400000-0000-4000-8000-000000000001','a1400000-0000-4000-8000-000000000001',null,'2026-09-30','2026-09-01','draft','Compatibility Branch','Compatibility Supervisor','Compatibility Team'),
  ('d1400000-0000-4000-8000-000000000003','b1400000-0000-4000-8000-000000000001','c1400000-0000-4000-8000-000000000001','a1400000-0000-4000-8000-000000000001',null,'2026-10-31','2026-10-01','draft','Compatibility Branch','Compatibility Supervisor','Compatibility Team'),
  ('d1400000-0000-4000-8000-000000000004','b1400000-0000-4000-8000-000000000002','c1400000-0000-4000-8000-000000000002','a1400000-0000-4000-8000-000000000002',null,'2026-09-30','2026-09-01','draft','Other Compatibility Branch','Other Compatibility Supervisor','Other Team');

insert into public.inventory_item_usage_items(
  id,report_id,usage_month,group_name,item_name,sort_order,created_by
) values
  ('e1400000-0000-4000-8000-000000000001','d1400000-0000-4000-8000-000000000001','2026-08-01','Main','Beef',1,'a1400000-0000-4000-8000-000000000001'),
  ('e1400000-0000-4000-8000-000000000002','d1400000-0000-4000-8000-000000000001','2026-08-01','main','BEEF',2,'a1400000-0000-4000-8000-000000000001'),
  ('e1400000-0000-4000-8000-000000000003','d1400000-0000-4000-8000-000000000001','2026-08-01','Main','Chicken',3,'a1400000-0000-4000-8000-000000000001'),
  ('e1400000-0000-4000-8000-000000000004','d1400000-0000-4000-8000-000000000001','2026-08-01','Main','Deleted Source',4,'a1400000-0000-4000-8000-000000000001'),
  ('e1400000-0000-4000-8000-000000000005','d1400000-0000-4000-8000-000000000003','2026-10-01','Main','Deleted Target History',1,'a1400000-0000-4000-8000-000000000001'),
  ('e1400000-0000-4000-8000-000000000006','d1400000-0000-4000-8000-000000000004','2026-09-01','Main','Cross Organization',1,'a1400000-0000-4000-8000-000000000002');

update public.inventory_item_usage_items set
  deleted_at='2026-08-30 10:00:00+00',deleted_by_user_id='a1400000-0000-4000-8000-000000000001'
where id='e1400000-0000-4000-8000-000000000004';
update public.inventory_item_usage_items set
  deleted_at='2026-10-02 10:00:00+00',deleted_by_user_id='a1400000-0000-4000-8000-000000000001'
where id='e1400000-0000-4000-8000-000000000005';

insert into public.inventory_item_usage_day_values(id,item_id,day_number,quantity,created_by)
values('f1400000-0000-4000-8000-000000000001','e1400000-0000-4000-8000-000000000001',1,7,'a1400000-0000-4000-8000-000000000001');

update public.inventory_items_reports set state='submitted',submitted_at=inventory_month+interval '1 month',
  submitted_by_user_id=supervisor_user_id,submitted_by_name_snapshot=supervisor_name_snapshot
where id in('d1400000-0000-4000-8000-000000000001','d1400000-0000-4000-8000-000000000004');

select has_function('private','inventory_items_carry_forward_items_json',array['uuid','uuid','date','uuid'],
  'exact carry-forward helper exists');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_catalog.pg_proc
  where oid='private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)'::regprocedure),
  'helper is SECURITY DEFINER with empty search_path');
select ok(not pg_catalog.has_function_privilege('anon',
  'private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)','EXECUTE')
  and not pg_catalog.has_function_privilege('authenticated',
  'private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)','EXECUTE'),
  'browser roles cannot execute the internal helper');
select ok(pg_catalog.has_function_privilege('service_role',
  'public.get_inventory_items_current_state(uuid,uuid,date)','EXECUTE'),
  'service_role retains authoritative state RPC access');

create temporary table compatibility_counts on commit drop as
select (select count(*) from public.inventory_items_reports) reports,
  (select count(*) from public.inventory_item_usage_items) items,
  (select count(*) from public.inventory_item_usage_day_values) day_values;
create temporary table september_projection on commit drop as
select public.get_inventory_items_current_state(
  'a1400000-0000-4000-8000-000000000001','c1400000-0000-4000-8000-000000000001','2026-09-01'
) value;

select is((select pg_catalog.jsonb_array_length(value->'item_usage'->'items') from september_projection),2,
  'monthly rollover projects two normalized active identities');
select is((select count(*) from september_projection cross join lateral
  pg_catalog.jsonb_array_elements(value->'item_usage'->'items') item
  where pg_catalog.lower(pg_catalog.btrim(item->>'item_name'))='beef'),1::bigint,
  'normalized duplicate identity is emitted once');
select ok(not exists(select 1 from september_projection cross join lateral
  pg_catalog.jsonb_array_elements(value->'item_usage'->'items') item
  where item->>'item_name'='Deleted Source'),
  'source tombstone is excluded');
select ok(not exists(select 1 from september_projection cross join lateral
  pg_catalog.jsonb_array_elements(value->'item_usage'->'items') item
  where item->>'item_name'='Cross Organization'),
  'source selection remains organization and branch isolated');
select ok((select bool_and(item->'usage'='{}'::jsonb and not(item?'id'))
  from september_projection cross join lateral
  pg_catalog.jsonb_array_elements(value->'item_usage'->'items') item),
  'projection carries names only and exposes no source IDs or quantities');
select is((select value->>'report_id' from september_projection),'d1400000-0000-4000-8000-000000000002',
  'projection uses the existing target report without creating another report');
select is(pg_catalog.jsonb_array_length(public.get_inventory_items_current_state(
  'a1400000-0000-4000-8000-000000000001','c1400000-0000-4000-8000-000000000001','2026-10-01'
)->'item_usage'->'items'),0,
  'any target-month history, including a tombstone, prevents reseeding');
select is((select count(*) from public.inventory_item_usage_day_values
  where item_id='e1400000-0000-4000-8000-000000000001'),1::bigint,
  'source day-value history remains unchanged');
select is((select reports from compatibility_counts),(select count(*) from public.inventory_items_reports),
  'read-only projection creates no reports');
select is((select items from compatibility_counts),(select count(*) from public.inventory_item_usage_items),
  'read-only projection creates no Item Usage rows');
select is((select day_values from compatibility_counts),(select count(*) from public.inventory_item_usage_day_values),
  'read-only projection creates no day values');
select ok(pg_catalog.pg_get_functiondef(
  'private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)'::regprocedure
) not like '%branch_daily_inventory_balance_rows%',
  'carry-forward remains independent of stock-balance calculations');
select ok(pg_catalog.pg_get_functiondef(
  'private.inventory_items_state_json(uuid,uuid,date)'::regprocedure
) like '%private.inventory_items_carry_forward_items_json%',
  'authoritative state projection calls the restored helper');

select * from finish();
rollback;
