begin;
select plan(16);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values(
  '00000000-0000-0000-0000-000000000000',
  '8a000000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'beef-create@example.invalid',
  '{}',
  '{}',
  pg_catalog.now(),
  pg_catalog.now()
);
update public.profiles
set full_name='Beef Create Supervisor', must_change_password=false
where id='8a000000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug)
values('8a000000-0000-4000-8000-000000000002','Beef Create Org','beef-create-org');
insert into public.branches(id,organization_id,name,code,timezone)
values(
  '8a000000-0000-4000-8000-000000000003',
  '8a000000-0000-4000-8000-000000000002',
  'Beef Create Branch',
  'BCB',
  'Asia/Riyadh'
);
insert into public.branch_memberships(branch_id,user_id,role)
values('8a000000-0000-4000-8000-000000000003','8a000000-0000-4000-8000-000000000001','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values(
  '8a000000-0000-4000-8000-000000000004',
  '8a000000-0000-4000-8000-000000000002',
  '8a000000-0000-4000-8000-000000000003',
  '8a000000-0000-4000-8000-000000000001'
);
insert into public.branch_inventory_items_settings(
  organization_id,branch_id,beef_russian_label,beef_australian_label,beef_hunch_sauce_label
) values(
  '8a000000-0000-4000-8000-000000000002',
  '8a000000-0000-4000-8000-000000000003',
  'Russian Custom',
  'Australian Custom',
  'Sauce Custom'
);

select has_function(
  'public',
  'create_inventory_beef_production_row',
  array['uuid','uuid','date','jsonb'],
  'dedicated Beef create RPC exists'
);
select is(
  has_function_privilege('authenticated','public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)','execute'),
  false,
  'authenticated cannot execute dedicated Beef create directly'
);
select is(
  has_function_privilege('service_role','public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)','execute'),
  true,
  'service role can execute dedicated Beef create'
);

select lives_ok(format($$
  select public.create_inventory_beef_production_row(
    '8a000000-0000-4000-8000-000000000001',
    '8a000000-0000-4000-8000-000000000003',
    '%s',
    '{"russian_kg":"17","australian_kg":"3","fat_kg":"1","ready_patty":"40","hunch_sauce_kg":"2","wastage_grams":"50"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh')), 'dedicated Beef create succeeds');
select is((select count(*) from public.inventory_items_reports where branch_id='8a000000-0000-4000-8000-000000000003'),1::bigint,'one canonical report is created');
select is((select count(*) from public.inventory_beef_production_rows),1::bigint,'one Beef row is created');
select is((select russian_kg::text||'|'||australian_kg::text||'|'||fat_kg::text||'|'||ready_patty::text||'|'||hunch_sauce_kg::text||'|'||wastage_grams::text from public.inventory_beef_production_rows),'17|3|1|40|2|50','all six numeric values persist');
select is((select russian_label_snapshot||'|'||australian_label_snapshot||'|'||hunch_sauce_label_snapshot from public.inventory_beef_production_rows),'Russian Custom|Australian Custom|Sauce Custom','trusted branch labels are snapshotted');
select is((select created_by from public.inventory_beef_production_rows),'8a000000-0000-4000-8000-000000000001'::uuid,'creator is recorded');
select is((select updated_by_user_id from public.inventory_beef_production_rows),null::uuid,'creation has no updater');
select is((select count(*) from public.inventory_item_usage_items),0::bigint,'Beef create does not persist Item Usage rows');
select is(jsonb_array_length(public.get_inventory_items_current_state('8a000000-0000-4000-8000-000000000001','8a000000-0000-4000-8000-000000000003')->'beef_rows'),1,'authoritative state returns the new row');

select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '8a000000-0000-4000-8000-000000000001','8a000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"18","australian_kg":"3","fat_kg":"1","ready_patty":"40","hunch_sauce_kg":"2","wastage_grams":"50"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh')), '23505', null, 'duplicate date conflicts');
select is((select count(*) from public.inventory_beef_production_rows),1::bigint,'duplicate create leaves one row');
select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '8a000000-0000-4000-8000-000000000001','8a000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"-1","australian_kg":"0","fat_kg":"0","ready_patty":"0","hunch_sauce_kg":"0","wastage_grams":"0"}'::jsonb
  )
$$, private.phase4a_business_date('Asia/Riyadh') - 1), '22023', null, 'negative numeric value is rejected');

update public.inventory_items_reports
set state='submitted',submitted_at=pg_catalog.clock_timestamp(),submitted_by_user_id='8a000000-0000-4000-8000-000000000001'
where branch_id='8a000000-0000-4000-8000-000000000003';
select throws_ok(format($$
  select public.create_inventory_beef_production_row(
    '8a000000-0000-4000-8000-000000000001','8a000000-0000-4000-8000-000000000003','%s',
    '{"russian_kg":"1","australian_kg":"0","fat_kg":"0","ready_patty":"0","hunch_sauce_kg":"0","wastage_grams":"0"}'::jsonb
  )
$$, case
  when private.phase4a_business_date('Asia/Riyadh') > date_trunc('month', private.phase4a_business_date('Asia/Riyadh'))::date
    then private.phase4a_business_date('Asia/Riyadh') - 1
  else private.phase4a_business_date('Asia/Riyadh') + 1
end), '22023', null, 'submitted report rejects create');

select * from finish();
rollback;
