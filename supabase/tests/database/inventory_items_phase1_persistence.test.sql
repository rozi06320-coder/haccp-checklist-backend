begin;
select plan(148);

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
select has_table('public','branch_inventory_items_settings','branch inventory settings table exists');
select has_column('public','inventory_beef_production_rows','russian_label_snapshot','beef Russian label snapshot exists');
select has_column('public','inventory_beef_production_rows','australian_label_snapshot','beef Australian label snapshot exists');
select has_column('public','inventory_beef_production_rows','hunch_sauce_label_snapshot','beef Hunch Sauce label snapshot exists');
select has_column('public','inventory_beef_production_rows','updated_by_user_id','beef row updater attribution exists');
select has_function('private','inventory_items_label_snapshot',array['jsonb','text','text'],'inventory label snapshot helper exists');
select has_function('public','update_inventory_beef_production_field_labels',array['uuid','uuid','text','text','text'],'inventory label settings RPC exists');
select has_function('public','update_inventory_beef_production_row',array['uuid','uuid','uuid','timestamptz','jsonb'],'saved Beef row update RPC exists');
select has_function('public','create_inventory_beef_production_row',array['uuid','uuid','date','jsonb'],'dedicated Beef row create RPC exists');
select has_table('public','inventory_item_usage_items','item usage item table exists');
select has_table('public','inventory_item_usage_day_values','item usage day value table exists');
select has_column('public','inventory_item_usage_items','deleted_at','item usage tombstone timestamp exists');
select has_column('public','inventory_item_usage_items','deleted_by_user_id','item usage tombstone actor exists');
select has_function('public','delete_inventory_item_usage_item',array['uuid','uuid','uuid'],'empty Item Usage delete RPC exists');
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
select is(has_function_privilege('authenticated','public.delete_inventory_item_usage_item(uuid,uuid,uuid)','execute'),false,'authenticated cannot execute Item Usage delete RPC directly');
select is(has_function_privilege('service_role','public.delete_inventory_item_usage_item(uuid,uuid,uuid)','execute'),true,'service role can execute Item Usage delete RPC');
select is(has_function_privilege('authenticated','public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)','execute'),false,'authenticated cannot execute inventory label settings RPC');
select is(has_function_privilege('service_role','public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)','execute'),true,'service role can execute inventory label settings RPC');
select is(has_function_privilege('authenticated','public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb)','execute'),false,'authenticated cannot execute Beef row update RPC directly');
select is(has_function_privilege('service_role','public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb)','execute'),true,'service role can execute Beef row update RPC');
select is(has_function_privilege('authenticated','public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)','execute'),false,'authenticated cannot execute Beef row create RPC directly');
select is(has_function_privilege('service_role','public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)','execute'),true,'service role can execute Beef row create RPC');
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
select ok(
  public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001') ? 'beef_production_labels'
  and not public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001') ? 'beef_production_label',
  'inventory state exposes only the current field-label response contract'
);
select is(
  public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',(date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date)->>'inventory_month',
  (date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date::text,
  'selected month current state uses requested Gregorian month'
);

insert into public.branch_inventory_items_settings(
  organization_id, branch_id, beef_russian_label, beef_australian_label, beef_hunch_sauce_label
) values (
  '2d000000-0000-4000-8000-000000000001', '3d000000-0000-4000-8000-000000000003',
  'Custom Russian', 'Custom Australian', 'Custom Sauce'
);
select lives_ok(format($$
  select public.create_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000005',
    '3d000000-0000-4000-8000-000000000003',
    '%s',
    '{"russian_kg":"17","australian_kg":"3","fat_kg":"1","ready_patty":"40","hunch_sauce_kg":"2","wastage_grams":"50"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh')), 'dedicated Beef create saves one row without Item Usage');
select is((select count(*) from public.inventory_items_reports where branch_id='3d000000-0000-4000-8000-000000000003'),1::bigint,'dedicated Beef create resolves one canonical branch/month report');
select is((select count(*) from public.inventory_beef_production_rows beef join public.inventory_items_reports report on report.id=beef.report_id where report.branch_id='3d000000-0000-4000-8000-000000000003'),1::bigint,'dedicated Beef create inserts exactly one row');
select is((select russian_kg::text || '|' || australian_kg::text || '|' || fat_kg::text || '|' || ready_patty::text || '|' || hunch_sauce_kg::text || '|' || wastage_grams::text from public.inventory_beef_production_rows beef join public.inventory_items_reports report on report.id=beef.report_id where report.branch_id='3d000000-0000-4000-8000-000000000003'),'17|3|1|40|2|50','dedicated Beef create persists all six numeric values');
select is((select russian_label_snapshot || '|' || australian_label_snapshot || '|' || hunch_sauce_label_snapshot from public.inventory_beef_production_rows beef join public.inventory_items_reports report on report.id=beef.report_id where report.branch_id='3d000000-0000-4000-8000-000000000003'),'Custom Russian|Custom Australian|Custom Sauce','dedicated Beef create snapshots authoritative branch labels');
select is((select created_by from public.inventory_beef_production_rows beef join public.inventory_items_reports report on report.id=beef.report_id where report.branch_id='3d000000-0000-4000-8000-000000000003'),'1d000000-0000-4000-8000-000000000005'::uuid,'dedicated Beef create records the actor');
select is((select updated_by_user_id from public.inventory_beef_production_rows beef join public.inventory_items_reports report on report.id=beef.report_id where report.branch_id='3d000000-0000-4000-8000-000000000003'),null::uuid,'dedicated Beef create has no updater');
select is((select count(*) from public.inventory_item_usage_items item join public.inventory_items_reports report on report.id=item.report_id where report.branch_id='3d000000-0000-4000-8000-000000000003'),0::bigint,'dedicated Beef create does not create or persist Item Usage');
select is(jsonb_array_length(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000003')->'beef_rows'),1,'dedicated Beef create returns the authoritative row');
select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"8","australian_kg":"3","fat_kg":"1","ready_patty":"40","hunch_sauce_kg":"2","wastage_grams":"50"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh')), '23505', null, 'duplicate Beef create for the same branch date conflicts');
select is((select count(*) from public.inventory_beef_production_rows beef join public.inventory_items_reports report on report.id=beef.report_id where report.branch_id='3d000000-0000-4000-8000-000000000003'),1::bigint,'duplicate Beef create leaves one canonical row');
select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"-1","australian_kg":"0","fat_kg":"0","ready_patty":"0","hunch_sauce_kg":"0","wastage_grams":"0"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh') - 1), '22023', null, 'dedicated Beef create rejects negative values');
select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"1","australian_kg":"0","fat_kg":"0","ready_patty":"0","hunch_sauce_kg":"0","wastage_grams":"0"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh') - 1), '42501', null, 'dedicated Beef create rejects a cross-branch actor');
select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"1","australian_kg":"0","fat_kg":"0","ready_patty":"0","hunch_sauce_kg":"0","wastage_grams":"0"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh') - 1), '42501', null, 'dedicated Beef create rejects a cross-organization actor');
update public.inventory_items_reports
set state = 'submitted', submitted_at = pg_catalog.clock_timestamp(), submitted_by_user_id = '1d000000-0000-4000-8000-000000000005'
where branch_id = '3d000000-0000-4000-8000-000000000003';
select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"1","australian_kg":"0","fat_kg":"0","ready_patty":"0","hunch_sauce_kg":"0","wastage_grams":"0"}'::jsonb
  )
$$, case
  when private.phase4a_business_date('Asia/Riyadh') > date_trunc('month', private.phase4a_business_date('Asia/Riyadh'))::date
    then private.phase4a_business_date('Asia/Riyadh') - 1
  else private.phase4a_business_date('Asia/Riyadh') + 1
end), '22023', null, 'dedicated Beef create rejects a submitted month');

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
select is((select russian_label_snapshot || '|' || australian_label_snapshot || '|' || hunch_sauce_label_snapshot from public.inventory_beef_production_rows row join public.inventory_items_reports report on report.id=row.report_id where report.supervisor_user_id='1d000000-0000-4000-8000-000000000001'),'Russian kg|Australian kg|Hunch sauce kg','new beef row snapshots default labels at first save');
select is((select count(*) from public.inventory_item_usage_items item join public.inventory_items_reports report on report.id=item.report_id where report.supervisor_user_id='1d000000-0000-4000-8000-000000000001'),1::bigint,'draft persists item usage item row');
select is((select count(*) from public.inventory_item_usage_day_values value join public.inventory_item_usage_items item on item.id=value.item_id join public.inventory_items_reports report on report.id=item.report_id where report.supervisor_user_id='1d000000-0000-4000-8000-000000000001'),2::bigint,'draft persists item usage day values');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'beef_rows'->0->>'total_kg','16.0','current state restores computed beef total');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'item_usage'->'items'->0->'usage'->>'8','3.5','current state restores item usage grid');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000004','3d000000-0000-4000-8000-000000000001')->'beef_rows'->0->>'russian_kg','10.5','branch peer sees first supervisor beef day');
select is(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000004','3d000000-0000-4000-8000-000000000001')->'item_usage'->'items'->0->'usage'->>'8','3.5','branch peer sees first supervisor item usage day');
select is((
  select beef.created_by
  from public.inventory_beef_production_rows beef
  join public.inventory_items_reports report on report.id=beef.report_id
  where report.branch_id='3d000000-0000-4000-8000-000000000001'
  limit 1
),'1d000000-0000-4000-8000-000000000001'::uuid,'first beef day keeps its creator');
select is((select created_by from public.inventory_item_usage_day_values where day_number=8),'1d000000-0000-4000-8000-000000000001'::uuid,'first item usage day keeps its creator');
select ok(
  (public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'beef_rows'->0) ? 'updated_at',
  'current state returns the Beef row concurrency timestamp'
);

create temp table _beef_edit_original on commit drop as
select beef.*
from public.inventory_beef_production_rows beef
join public.inventory_items_reports report on report.id=beef.report_id
where report.branch_id='3d000000-0000-4000-8000-000000000001'
limit 1;

select lives_ok($$
  select public.update_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    (select id from _beef_edit_original),
    (select updated_at from _beef_edit_original),
    '{"russian_kg":"11","australian_kg":"5","fat_kg":"2","ready_patty":"121","hunch_sauce_kg":"3.5","wastage_grams":"151"}'::jsonb
  )
$$, 'branch peer edits one saved Beef day through the dedicated RPC');
select is(
  (select russian_kg::text || '|' || australian_kg::text || '|' || fat_kg::text || '|' || ready_patty::text || '|' || hunch_sauce_kg::text || '|' || wastage_grams::text from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),
  '11|5|2|121|3.5|151',
  'all six Beef values update in place including Hunch Sauce'
);
select is((select id from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),(select id from _beef_edit_original),'Beef row UUID is unchanged');
select is((select production_date from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),(select production_date from _beef_edit_original),'Beef production date is unchanged');
select is((select created_by from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),(select created_by from _beef_edit_original),'Beef creator is unchanged');
select is((select created_at from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),(select created_at from _beef_edit_original),'Beef creation timestamp is unchanged');
select is(
  (select russian_label_snapshot || '|' || australian_label_snapshot || '|' || hunch_sauce_label_snapshot from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),
  (select russian_label_snapshot || '|' || australian_label_snapshot || '|' || hunch_sauce_label_snapshot from _beef_edit_original),
  'Beef label snapshots are unchanged'
);
select ok((select updated_at > (select updated_at from _beef_edit_original) from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),'Beef update advances the concurrency timestamp');
select is((select updated_by_user_id from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),'1d000000-0000-4000-8000-000000000004'::uuid,'Beef update records the editing supervisor');
select is((select count(*) from public.inventory_beef_production_rows where report_id=(select report_id from _beef_edit_original)),1::bigint,'Beef edit creates no duplicate row');
select throws_ok($$
  select public.update_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
    (select id from _beef_edit_original),(select updated_at from _beef_edit_original),
    '{"russian_kg":"99","australian_kg":"5","fat_kg":"2","ready_patty":"121","hunch_sauce_kg":"3.5","wastage_grams":"151"}'::jsonb
  )
$$, '40001', null, 'stale Beef edit is rejected');
select is((select russian_kg::text from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),'11','stale Beef edit does not overwrite the saved value');
select throws_ok($$
  select public.update_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000003',
    (select id from _beef_edit_original),(select updated_at from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),
    '{"russian_kg":"11","australian_kg":"5","fat_kg":"2","ready_patty":"121","hunch_sauce_kg":"3.5","wastage_grams":"151"}'::jsonb
  )
$$, '42501', null, 'another branch cannot edit the Beef row');
select throws_ok($$
  select public.update_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000002',
    (select id from _beef_edit_original),(select updated_at from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),
    '{"russian_kg":"11","australian_kg":"5","fat_kg":"2","ready_patty":"121","hunch_sauce_kg":"3.5","wastage_grams":"151"}'::jsonb
  )
$$, '42501', null, 'another organization cannot edit the Beef row');
select throws_ok($$
  select public.update_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
    '6d000000-0000-4000-8000-000000000099',pg_catalog.clock_timestamp(),
    '{"russian_kg":"11","australian_kg":"5","fat_kg":"2","ready_patty":"121","hunch_sauce_kg":"3.5","wastage_grams":"151"}'::jsonb
  )
$$, 'P0002', null, 'missing Beef row is reported safely');
select lives_ok($$
  select public.update_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
    (select id from _beef_edit_original),(select updated_at from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),
    '{"russian_kg":"10.5","australian_kg":"4","fat_kg":"1.5","ready_patty":"120","hunch_sauce_kg":"2","wastage_grams":"150"}'::jsonb
  )
$$, 'a second Beef edit updates the same logical row');
select is((select russian_kg::text from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),'10.5','second Beef edit persists without a duplicate');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000004',
    '3d000000-0000-4000-8000-000000000001',
    '[{"production_date":"%s","russian_kg":"99","australian_kg":4,"fat_kg":"1.5","ready_patty":120,"hunch_sauce_kg":"2","wastage_grams":"150"}]'::jsonb,
    '{"usage_month":"%s-01","items":[]}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh'), to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'branch peer cannot change first supervisor beef day');
select lives_ok($$
  select public.update_inventory_beef_production_field_labels(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    'Beef A',
    'Beef B',
    'Sauce X'
  )
$$, 'supervisor renames beef field labels');
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
select is((select russian_label_snapshot || '|' || australian_label_snapshot || '|' || hunch_sauce_label_snapshot from public.inventory_beef_production_rows where russian_kg=10.5),'Russian kg|Australian kg|Hunch sauce kg','existing beef row keeps original label snapshots after branch rename');
select is((select russian_label_snapshot || '|' || australian_label_snapshot || '|' || hunch_sauce_label_snapshot from public.inventory_beef_production_rows where russian_kg=7),'Beef A|Beef B|Sauce X','new beef row snapshots renamed labels after branch rename');
select is((select created_by from public.inventory_item_usage_day_values where day_number=10),'1d000000-0000-4000-8000-000000000004'::uuid,'appended item usage day records branch peer creator');
select is((select created_by from public.inventory_beef_production_rows where russian_kg=10.5),'1d000000-0000-4000-8000-000000000001'::uuid,'branch peer identical retry preserves original beef creator');
select is((select created_by from public.inventory_item_usage_day_values where day_number=8),'1d000000-0000-4000-8000-000000000001'::uuid,'branch peer identical retry preserves original item usage creator');
select is((
  select row_json->>'russian_label_snapshot'
  from jsonb_array_elements(public.get_inventory_items_current_state('1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')->'beef_rows') row_json
  where row_json->>'russian_kg' = '7'
), 'Beef A', 'current state returns per-row label snapshots');

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

insert into public.branch_inventory_catalog_items(id,organization_id,branch_id,name,unit,kind)
values('7d000000-0000-4000-8000-000000000100','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','Delete Safety Catalog Item','kg','ingredient');

select lives_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '[]'::jsonb,
    '{"usage_month":"%s-01","items":[
      {"item_id":"6d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Smokey Beef Burger","usage":{"1":"2","8":3.5,"9":"4"}},
      {"item_id":"7d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Empty Saved Row","usage":{}},
      {"item_id":"7d000000-0000-4000-8000-000000000002","group_name":"Liwa","item_name":"Empty Until Submit","usage":{}}
    ]}'::jsonb
  )
$$, to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), 'two empty Item Usage rows can be saved before deletion');
select lives_ok($$
  select public.delete_inventory_item_usage_item(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '7d000000-0000-4000-8000-000000000001'
  )
$$, 'saved empty Item Usage row can be deleted while report is draft');
select ok((
  select deleted_at is not null and deleted_by_user_id='1d000000-0000-4000-8000-000000000001'
  from public.inventory_item_usage_items
  where id='7d000000-0000-4000-8000-000000000001'
), 'delete records a one-way actor/timestamp tombstone');
select ok(not exists (
  select 1
  from jsonb_array_elements(public.get_inventory_items_current_state(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001'
  )->'item_usage'->'items') item
  where item->>'id'='7d000000-0000-4000-8000-000000000001'
), 'deleted Item Usage row stays absent from current state');
select is((
  select jsonb_array_length(public.get_inventory_items_current_state(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001'
  )->'item_usage'->'items')
), 2, 'other Item Usage rows remain unchanged');
select ok(not exists (
  select 1
  from jsonb_array_elements(public.list_managed_inventory_items_reports(
    '1d000000-0000-4000-8000-000000000003','2d000000-0000-4000-8000-000000000001',
    date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))::date,null
  )->'reports'->0->'item_usage_rows') item
  where item->>'item_id'='7d000000-0000-4000-8000-000000000001'
), 'manager report/export state excludes tombstoned rows');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','[]'::jsonb,
    '{"usage_month":"%s-01","items":[{"item_id":"7d000000-0000-4000-8000-000000000001","group_name":"Liwa","item_name":"Empty Saved Row","usage":{}}]}'::jsonb
  )
$$, to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'stale whole-grid save cannot resurrect a deleted UUID');
select throws_ok(format($$
  select public.save_inventory_items_draft(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','[]'::jsonb,
    '{"usage_month":"%s-01","items":[{"group_name":"Liwa","item_name":"Empty Saved Row","usage":{}}]}'::jsonb
  )
$$, to_char(private.phase4a_business_date('Asia/Riyadh'), 'YYYY-MM')), '23505', null, 'stale no-ID save cannot recreate a tombstoned logical row');
select is((
  select count(*) from public.inventory_item_usage_items item
  where item.report_id=(select report.id from public.inventory_items_reports report where report.branch_id='3d000000-0000-4000-8000-000000000001' and report.inventory_month=date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))::date)
    and item.usage_month=date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))::date
    and item.group_name='Liwa' and item.item_name='Empty Saved Row' and item.deleted_at is null
), 0::bigint, 'no-ID stale save creates no replacement active row');
select ok((
  select item.deleted_at is not null
  from public.inventory_item_usage_items item
  where item.id='7d000000-0000-4000-8000-000000000001'
), 'no-ID stale save preserves the original tombstone');
select ok(not exists (
  select 1
  from jsonb_array_elements(public.get_inventory_items_current_state(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001'
  )->'item_usage'->'items') item
  where item->>'group_name'='Liwa' and item->>'item_name'='Empty Saved Row'
), 'current state still excludes the row after no-ID stale save');
select throws_ok($$
  select public.delete_inventory_item_usage_item(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','6d000000-0000-4000-8000-000000000001'
  )
$$, '23505', null, 'saved populated Item Usage row cannot be deleted');
select throws_ok($$
  select public.delete_inventory_item_usage_item(
    '1d000000-0000-4000-8000-000000000005','3d000000-0000-4000-8000-000000000001','7d000000-0000-4000-8000-000000000002'
  )
$$, '42501', null, 'another branch supervisor cannot delete Item Usage rows');
select throws_ok($$
  select public.delete_inventory_item_usage_item(
    '1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000001','7d000000-0000-4000-8000-000000000002'
  )
$$, '42501', null, 'another organization supervisor cannot delete Item Usage rows');
select throws_ok($$
  select public.delete_inventory_item_usage_item(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','7d000000-0000-4000-8000-000000000001'
  )
$$, '23505', null, 'repeated or concurrent delete fails without changing active rows');
select is((select count(*) from public.branch_inventory_catalog_items where id='7d000000-0000-4000-8000-000000000100'),1::bigint,'deleting Item Usage never removes the catalog master item');

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
select throws_ok($$
  select public.delete_inventory_item_usage_item(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','7d000000-0000-4000-8000-000000000002'
  )
$$, '23505', null, 'submitted month keeps empty Item Usage rows immutable');
select is((select submitted_by_user_id from public.inventory_items_reports where branch_id='3d000000-0000-4000-8000-000000000001' and inventory_month=date_trunc('month',private.phase4a_business_date('Asia/Riyadh'))::date),'1d000000-0000-4000-8000-000000000004'::uuid,'shared month records the submitting supervisor');
select throws_ok($$
  update public.inventory_items_reports set state='draft'
  where supervisor_user_id='1d000000-0000-4000-8000-000000000001'
$$, '23505', null, 'submitted report cannot be reopened directly');
select throws_ok($$
  update public.inventory_beef_production_rows set russian_kg=999
  where report_id=(select id from public.inventory_items_reports where supervisor_user_id='1d000000-0000-4000-8000-000000000001')
$$, '23514', null, 'submitted Beef row cannot be updated directly');
select throws_ok($$
  select public.update_inventory_beef_production_row(
    '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
    (select id from _beef_edit_original),(select updated_at from public.inventory_beef_production_rows where id=(select id from _beef_edit_original)),
    '{"russian_kg":"12","australian_kg":"4","fat_kg":"1.5","ready_patty":"120","hunch_sauce_kg":"2","wastage_grams":"150"}'::jsonb
  )
$$, '23514', null, 'dedicated Beef edit RPC rejects a submitted month');
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
  select public.submit_inventory_items(
    '1d000000-0000-4000-8000-000000000001',
    '3d000000-0000-4000-8000-000000000001',
    '5d000000-0000-4000-8000-000000000003',
    'future-inventory-hash',
    '[{"production_date":"%s","russian_kg":"1","australian_kg":"1","fat_kg":"0","ready_patty":"10","hunch_sauce_kg":"1","wastage_grams":"0"}]'::jsonb,
    '{"usage_month":"%s","items":[{"group_name":"Liwa","item_name":"Next Month Item","usage":{"1":"1"}}]}'::jsonb
  )
$$, (date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date, (date_trunc('month', private.phase4a_business_date('Asia/Riyadh')) + interval '1 month')::date), '22023', null, 'future inventory month cannot be closed');
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
