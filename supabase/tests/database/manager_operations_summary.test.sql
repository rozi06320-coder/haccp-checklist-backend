begin;
select plan(9);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '1d000000-0000-4000-8000-000000000001'::uuid,
  '1d000000-0000-4000-8000-000000000002'
]) id;

update public.profiles set full_name=case id
  when '1d000000-0000-4000-8000-000000000001' then 'Operations Summary Manager'
  else 'Other Operations Summary Manager'
end, must_change_password=false
where id::text like '1d000000-%';

insert into public.organizations(id,name,slug) values
  ('2d000000-0000-4000-8000-000000000001','Operations Summary Org','operations-summary-org'),
  ('2d000000-0000-4000-8000-000000000002','Other Operations Summary Org','other-operations-summary-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Operations Summary Branch','OSB','Asia/Riyadh'),
  ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000002','Other Operations Summary Branch','OOSB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','organization_manager'),
  ('2d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000002','organization_manager');

select ok(not has_function_privilege('authenticated','public.get_managed_operations_summary(uuid,uuid,uuid,date)','execute')
  and has_function_privilege('service_role','public.get_managed_operations_summary(uuid,uuid,uuid,date)','execute'),
  'operations summary RPC is service-role only');

create temp table operations_summary_result as
select public.get_managed_operations_summary(
  '1d000000-0000-4000-8000-000000000001',
  '2d000000-0000-4000-8000-000000000001',
  null,
  '2026-08-01'
) as summary;
grant select on operations_summary_result to service_role;

select is((select summary->'scope'->>'organization_id' from operations_summary_result),'2d000000-0000-4000-8000-000000000001','manager receives own organization summary');
select is((select summary->'scope'->>'month' from operations_summary_result),'2026-08','requested Gregorian month is retained');
select is((select summary->'purchase_logs'->>'unpaid_amount' from operations_summary_result),'0','empty purchase logs return a decimal string zero');
select is((select summary->'inventory'->>'active_branch_count' from operations_summary_result),'1','empty inventory still reports the active branch');
select is((select summary->'staff'->>'active_count' from operations_summary_result),'0','empty staff returns zero');
select is((select summary->'availability'->>'inventory' from operations_summary_result),'ready','empty source is ready rather than unavailable');

set local role service_role;
select throws_ok($$select public.get_managed_operations_summary('1d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001',null,'2026-08-01')$$,
  '42501','operations summary access denied','cross-organization manager is denied');
select throws_ok($$select public.get_managed_operations_summary('1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000002','2026-08-01')$$,
  '42501','operations summary access denied','branch outside organization is denied');
reset role;

select * from finish();
rollback;
