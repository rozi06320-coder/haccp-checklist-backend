begin;
select plan(70);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1d000000-0000-4000-8000-000000000001'::uuid,
  '1d000000-0000-4000-8000-000000000002',
  '1d000000-0000-4000-8000-000000000003',
  '1d000000-0000-4000-8000-000000000004',
  '1d000000-0000-4000-8000-000000000005'
]) id;
update public.profiles set full_name = case id
  when '1d000000-0000-4000-8000-000000000001' then 'Inventory Supervisor One'
  when '1d000000-0000-4000-8000-000000000002' then 'Inventory Supervisor Two'
  when '1d000000-0000-4000-8000-000000000004' then 'Inventory Supervisor Branch Peer'
  when '1d000000-0000-4000-8000-000000000005' then 'Inventory Other Branch Supervisor'
  else 'Inventory Manager'
end, must_change_password = false
where id::text like '1d000000-%';
insert into public.organizations(id,name,slug)
values
 ('2d000000-0000-4000-8000-000000000001','Inventory Org','inventory-org'),
 ('2d000000-0000-4000-8000-000000000002','Other Inventory Org','other-inventory-org');
insert into public.branches(id,organization_id,name,code,timezone)
values
 ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Inventory Branch','INV','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001','Inventory Branch B','INVB','Asia/Riyadh'),
 ('3d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000002','Other Inventory Branch','OINV','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager'),
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000004','branch_manager'),
 ('3d000000-0000-4000-8000-000000000003','1d000000-0000-4000-8000-000000000005','branch_manager'),
 ('3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001'),
 ('4d000000-0000-4000-8000-000000000004','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000004'),
 ('4d000000-0000-4000-8000-000000000005','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000003','1d000000-0000-4000-8000-000000000005'),
 ('4d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000002');

select has_table('public','inventory_items_reports','inventory report table exists');
select has_table('public','inventory_items_submission_idempotency','inventory idempotency table exists');
select has_table('public','inventory_beef_production_rows','beef production row table exists');
select has_table('public','inventory_item_usage_items','item usage item table exists');
select has_table('public','inventory_item_usage_day_values','item usage day value table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_items_reports'::regclass),'inventory reports RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_items_submission_idempotency'::regclass),'inventory idempotency RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_beef_production_rows'::regclass),'beef rows RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_item_usage_items'::regclass),'item usage rows RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.inventory_item_usage_day_values'::regclass),'item usage values RLS enabled');
select is(has_function_privilege('authenticated','public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)','execute'),false,'authenticated cannot execute inventory draft RPC');
select is(has_function_privilege('authenticated','public.get_inventory_items_current_state(uuid,uuid)','execute'),false,'authenticated cannot execute inventory state RPC');
select is(has_function_privilege('authenticated','public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)','execute'),false,'authenticated cannot execute inventory submit RPC');
select is(has_function_privilege('service_role','public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)','execute'),true,'service role can execute inventory draft RPC');
select is(has_function_privilege('service_role','public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)','execute'),true,'service role can execute inventory submit RPC');
select ok(not has_table_privilege('authenticated','public.inventory_items_reports','insert')
  and not has_table_privilege('authenticated','public.inventory_beef_production_rows','insert')
  and not has_table_privilege('authenticated','public.inventory_item_usage_items','insert')
  and not has_table_privilege('authenticated','public.inventory_item_usage_day_values','insert')
  and not has_table_privilege('authenticated','public.inventory_items_reports','update')
  and not has_table_privilege('authenticated','public.inventory_beef_production_rows','delete')
  and not has_table_privilege('authenticated','public.inventory_item_usage_items','delete')
  and not has_table_privilege('authenticated','public.inventory_item_usage_day_values','delete'),
  'authenticated role has no direct inventory writes');

select is(
  public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->>'business_date',
  private.phase4a_business_date('Asia/Riyadh')::text,
  'empty state uses server business date'
);
select is(
  jsonb_array_length(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'beef_rows'),
  0,
  'empty state has no beef rows'
);
select is(
  public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',(date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date)->>'inventory_month',
  (date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date::text,
  'selected month current state uses requested Gregorian month'
);

select lives_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"10.5","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), 'supervisor saves inventory draft');
select is((select count(*) from public.inventory_items_reports where supervisor_user_id='1d000000-0000-4000-8000-000000000001'),1::bigint,'one inventory report row saved');
select is((select business_date from public.inventory_items_reports where supervisor_user_id='1d000000-0000-4000-8000-000000000001'),private.phase4a_business_date('Asia/Riyadh'),'business date is server-calculated');
select is((select count(*) from public.inventory_beef_production_rows row join public.inventory_items_reports report on report.id=row.report_id where report.supervisor_user_id='1d000000-0000-4000-8000-000000000001'),1::bigint,'draft persists beef rows');
select is((select russian_kg::text || '|' || (russian_kg+australian_kg+fat_kg)::text from public.inventory_beef_production_rows row join public.inventory_items_reports report on report.id=row.report_id where report.supervisor_user_id='1d000000-0000-4000-8000-000000000001'),'10.5|16.0','beef numeric values and total persist');
select is((select count(*) from public.inventory_item_usage_items item join public.inventory_items_reports report on report.id=item.report_id where report.supervisor_user_id='1d000000-0000-4000-8000-000000000001'),1::bigint,'draft persists item usage item row');
select is((select count(*) from public.inventory_item_usage_day_values value join public.inventory_item_usage_items item on item.id=value.item_id join public.inventory_items_reports report on report.id=item.report_id where report.supervisor_user_id='1d000000-0000-4000-8000-000000000001'),2::bigint,'draft persists item usage day values');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'beef_rows'->0->>'total_kg','16.0','current state restores computed beef total');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'item_usage'->'items'->0->'usage'->>'8','3.5','current state restores item usage grid');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000004','3d000000-0000-4000-8000-000000000001')->'beef_rows'->0->>'russian_kg','10.5','branch peer sees first supervisor beef day');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000004','3d000000-0000-4000-8000-000000000001')->'item_usage'->'items'->0->'usage'->>'8','3.5','branch peer sees first supervisor item usage day');
select is((select created_by from public.inventory_beef_production_rows limit 1),'1d000000-0000-4000-8000-000000000001'::uuid,'first beef day keeps its creator');
select is((select created_by from public.inventory_item_usage_day_values where day_number=8),'1d000000-0000-4000-8000-000000000001'::uuid,'first item usage day keeps its creator');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"99","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'branch peer cannot change first supervisor beef day');
select lives_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"10.5","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"},{"production_date":"%s","russian_kg":"7","australian_kg":0,"fat_kg":"0","ready_patty":70,"hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5,"10":"4"}}]}'::jsonb
  )
$$,
  private.phase4a_business_date('Asia/Riyadh'),
  private.phase4a_business_date('Asia/Riyadh') + case when extract(day from private.phase4a_business_date('Asia/Riyadh')) = 1 then 1 else -1 end,
  to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')
), 'branch peer appends previously empty beef and item usage days');
select is(jsonb_array_length(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'beef_rows'),2,'first supervisor reloads both shared beef days');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'item_usage'->'items'->0->'usage'->>'10','4','first supervisor reloads branch peer item usage day');
select is((select count(*) from public.inventory_items_reports where organization_id='2d000000-0000-4000-8000-000000000001' and branch_id='3d000000-0000-4000-8000-000000000001' and inventory_month=date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))::date),1::bigint,'only one branch/month inventory report exists');
select is((select supervisor_user_id from public.inventory_items_reports where branch_id='3d000000-0000-4000-8000-000000000001' and inventory_month=date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))::date),'1d000000-0000-4000-8000-000000000001'::uuid,'branch peer does not rewrite original report creator');
select is((select created_by from public.inventory_beef_production_rows where russian_kg=7),'1d000000-0000-4000-8000-000000000004'::uuid,'appended beef day records branch peer creator');
select is((select created_by from public.inventory_item_usage_day_values where day_number=10),'1d000000-0000-4000-8000-000000000004'::uuid,'appended item usage day records branch peer creator');
select is((select created_by from public.inventory_beef_production_rows where russian_kg=10.5),'1d000000-0000-4000-8000-000000000001'::uuid,'branch peer identical retry preserves original beef creator');
select is((select created_by from public.inventory_item_usage_day_values where day_number=8),'1d000000-0000-4000-8000-000000000001'::uuid,'branch peer identical retry preserves original item usage creator');

select lives_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"10.5","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), 'identical daily values can be replayed');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"11","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'saved beef production day cannot be changed');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"10.5","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"9","8":3.5}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'saved item usage day cannot be changed');
select lives_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"10.5","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5,"9":"4"}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), 'new item usage day is appended');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'item_usage'->'items'->0->'usage'->>'1','2','previous item usage survives later saves');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'item_usage'->'items'->0->'usage'->>'9','4','new item usage is restored');

select lives_ok(format($$
  select public.submit_inventory_items(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    '5d000000-0000-4000-8000-000000000001',
    'inventory-hash-current-month',
    '[{"production_date":"%s","russian_kg":"10.5","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5,"9":"4"}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), 'submit closes current inventory month');
select is((select state from public.inventory_items_reports where supervisor_user_id='1d000000-0000-4000-8000-000000000001'),'submitted','submitted month is marked submitted');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->>'state','submitted','current state returns submitted lock');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000004','3d000000-0000-4000-8000-000000000001')->>'state','submitted','branch peer sees the shared submitted lock');
select is((select submitted_by_user_id from public.inventory_items_reports where branch_id='3d000000-0000-4000-8000-000000000001' and inventory_month=date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))::date),'1d000000-0000-4000-8000-000000000004'::uuid,'shared month records the submitting supervisor');
select throws_ok($$
  update public.inventory_items_reports set state='draft'
  where supervisor_user_id='1d000000-0000-4000-8000-000000000001'
$$, '23505', null, 'submitted report cannot be reopened directly');
select throws_ok($$
  update public.inventory_beef_production_rows set russian_kg=999
  where report_id=(select id from public.inventory_items_reports where supervisor_user_id='1d000000-0000-4000-8000-000000000001')
$$, '23505', null, 'saved beef row cannot be updated directly');
select throws_ok($$
  delete from public.inventory_item_usage_day_values
  where item_id='6d000000-0000-4000-8000-000000000001' and day_number=1
$$, '23505', null, 'saved item usage day cannot be deleted directly');
select lives_ok(format($$
  select public.submit_inventory_items(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    '5d000000-0000-4000-8000-000000000001',
    'inventory-hash-current-month',
    '[{"production_date":"%s","russian_kg":"10.5","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5,"9":"4"}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), 'same idempotency replay succeeds');
select throws_ok(format($$
  select public.submit_inventory_items(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    '5d000000-0000-4000-8000-000000000001',
    'changed-inventory-hash',
    '[{"production_date":"%s","russian_kg":"3","australian_kg":1,"fat_kg":"0","ready_patty":20,"hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"group_name":"Liwa","item_name":"Texas Sauce","usage":{"2":"5"}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'same idempotency key with changed body conflicts');
select throws_ok(format($$
  select public.submit_inventory_items(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '5d000000-0000-4000-8000-000000000002',
    'another-inventory-hash',
    '[{"production_date":"%s","russian_kg":"3","australian_kg":1,"fat_kg":"0","ready_patty":20,"hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"group_name":"Liwa","item_name":"Texas Sauce","usage":{"2":"5"}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'different submit after submitted month conflicts');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"9","australian_kg":1,"fat_kg":"0","ready_patty":20,"hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s-01","items":[{"group_name":"Liwa","item_name":"Texas Sauce","usage":{"2":"5"}}]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'draft save after submitted month cannot overwrite');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"9","australian_kg":1,"fat_kg":"0","ready_patty":20,"hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s-01","items":[]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'submitting branch peer cannot reopen the shared month');
select lives_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"1","australian_kg":1,"fat_kg":"0","ready_patty":10,"hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s","items":[{"group_name":"Liwa","item_name":"Next Month Item","usage":{"1":"1"}}]}'::jsonb
  )
$$, (date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date, (date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date), 'next month remains editable after current month submit');
select throws_ok(format($$
  select public.save_inventory_items_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','[{"production_date":"%s","russian_kg":"-1","australian_kg":0,"fat_kg":0,"ready_patty":0,"hunch_sauce_kg":0,"wastage_grams":0}]'::jsonb,'{"usage_month":"%s-01","items":[]}'::jsonb)
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '22023', null, 'negative beef value rejected');
select throws_ok($$
  select public.save_inventory_items_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','[]'::jsonb,'{"usage_month":"2026-02-01","items":[{"group_name":"Liwa","item_name":"A","usage":{"30":1}}]}'::jsonb)
$$, '22023', null, 'invalid month day rejected');
select throws_ok($$
  select public.save_inventory_items_draft('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','[]'::jsonb,'{"usage_month":"2026-08-01","items":[{"group_name":"Liwa","item_name":"","usage":{}}]}'::jsonb)
$$, '22023', null, 'blank item name rejected');
select throws_ok($$
  select public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000003','3d000000-0000-4000-8000-000000000001')
$$, '42501', null, 'manager cannot use supervisor inventory RPC');
select throws_ok($$
  select public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000001')
$$, '42501', null, 'other organization supervisor cannot read inventory state');
select throws_ok($$
  select public.save_inventory_items_draft('1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000001','[]'::jsonb,'{"usage_month":"2026-08-01","items":[]}'::jsonb)
$$, '42501', null, 'other organization supervisor cannot write inventory draft');
select throws_ok($$
  select public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000001')
$$, '42501', null, 'other branch supervisor cannot read shared inventory state');
select throws_ok($$
  select public.save_inventory_items_draft('1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000001','[]'::jsonb,'{"usage_month":"2026-08-01","items":[]}'::jsonb)
$$, '42501', null, 'other branch supervisor cannot write shared inventory draft');

select * from finish();
rollback;
