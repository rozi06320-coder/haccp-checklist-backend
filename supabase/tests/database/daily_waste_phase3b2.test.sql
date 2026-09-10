begin;
select no_plan();

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', id || '@daily-waste.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1b200000-0000-4000-8000-000000000001'::uuid,
  '1b200000-0000-4000-8000-000000000002'
]) id;

update public.profiles
set full_name = case id
    when '1b200000-0000-4000-8000-000000000001' then 'Daily Waste Supervisor A'
    else 'Daily Waste Supervisor B'
  end,
  must_change_password = false
where id in ('1b200000-0000-4000-8000-000000000001','1b200000-0000-4000-8000-000000000002');

insert into public.organizations(id,name,slug)
values
  ('2b200000-0000-4000-8000-000000000001','Daily Waste Org A','daily-waste-org-a'),
  ('2b200000-0000-4000-8000-000000000002','Daily Waste Org B','daily-waste-org-b');

insert into public.branches(id,organization_id,name,code,timezone)
values
  ('3b200000-0000-4000-8000-000000000001','2b200000-0000-4000-8000-000000000001','Daily Waste Branch A','DWA','Asia/Riyadh'),
  ('3b200000-0000-4000-8000-000000000002','2b200000-0000-4000-8000-000000000002','Daily Waste Branch B','DWB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role)
values
  ('3b200000-0000-4000-8000-000000000001','1b200000-0000-4000-8000-000000000001','branch_manager'),
  ('3b200000-0000-4000-8000-000000000002','1b200000-0000-4000-8000-000000000002','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values
  ('7b200000-0000-4000-8000-000000000001','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','1b200000-0000-4000-8000-000000000001'),
  ('7b200000-0000-4000-8000-000000000002','2b200000-0000-4000-8000-000000000002','3b200000-0000-4000-8000-000000000002','1b200000-0000-4000-8000-000000000002');

insert into public.branch_inventory_catalog_items(id,organization_id,branch_id,name,unit,kind,is_active)
values
  ('4b200000-0000-4000-8000-000000000001','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Bread','pcs','ingredient',true),
  ('4b200000-0000-4000-8000-000000000002','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Beef','pcs','ingredient',true),
  ('4b200000-0000-4000-8000-000000000003','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Bottled Water','pcs','standalone_stock',true),
  ('4b200000-0000-4000-8000-000000000004','2b200000-0000-4000-8000-000000000002','3b200000-0000-4000-8000-000000000002','Other Bread','pcs','ingredient',true),
  ('4b200000-0000-4000-8000-000000000010','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Smoky Sauce','g','ingredient',true),
  ('4b200000-0000-4000-8000-000000000011','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Flour','kg','ingredient',true),
  ('4b200000-0000-4000-8000-000000000012','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Milk','ml','ingredient',true),
  ('4b200000-0000-4000-8000-000000000013','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Cooking Oil','L','ingredient',true),
  ('4b200000-0000-4000-8000-000000000014','2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001','Inactive Item','pcs','ingredient',false);

-- 1. report/table RLS
select has_table('public','branch_daily_waste_reports','daily waste report table exists');
select has_table('public','branch_daily_waste_entries','daily waste entries table exists');
select ok(
  (select relrowsecurity from pg_class where oid='public.branch_daily_waste_reports'::regclass)
  and (select relrowsecurity from pg_class where oid='public.branch_daily_waste_entries'::regclass),
  'all daily waste tables have RLS enabled'
);

-- 2. authenticated direct writes denied
select ok(
  not has_table_privilege('authenticated','public.branch_daily_waste_reports','insert,update,delete')
  and not has_table_privilege('authenticated','public.branch_daily_waste_entries','insert,update,delete'),
  'authenticated has no direct table mutation privileges'
);

set local role authenticated;
select throws_ok(
  $$insert into public.branch_daily_waste_reports(organization_id,branch_id,business_date,created_by_user_id,updated_by_user_id) values('2b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',current_date,'1b200000-0000-4000-8000-000000000001','1b200000-0000-4000-8000-000000000001')$$,
  '42501',
  null,
  'authenticated direct report insert is denied'
);
reset role;

-- 3. service role RPC boundary
select ok(
  has_function_privilege('service_role','public.save_branch_daily_waste(uuid,uuid,date,bigint,jsonb)','execute')
  and not has_function_privilege('authenticated','public.save_branch_daily_waste(uuid,uuid,date,bigint,jsonb)','execute'),
  'save RPC is service-role only'
);
select ok(
  has_function_privilege('service_role','public.get_branch_daily_waste(uuid,uuid,date,date)','execute')
  and not has_function_privilege('authenticated','public.get_branch_daily_waste(uuid,uuid,date,date)','execute'),
  'read RPC is service-role only'
);

-- 4. branch isolation / 5. wrong branch rejected
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000002','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[]')$$,
  '42501',
  'daily waste access denied',
  'branch B actor cannot write branch A'
);

-- 6. future date rejected
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh') + 1,0,'[]')$$,
  '22023',
  'daily waste future business date denied',
  'future business date is rejected'
);

-- 7. expected_revision required
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),null,'[]')$$,
  '22023',
  'invalid daily waste revision',
  'null expected_revision is rejected'
);

-- 10. empty first patch creates nothing
select is(
  (public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[]')->>'report_id'),
  null,
  'empty first patch creates no report'
);
select is(
  (select count(*)::int from public.branch_daily_waste_reports where branch_id='3b200000-0000-4000-8000-000000000001'),
  0,
  'database has no reports after empty first patch'
);

-- Unknown field rejection: payload with unexpected key
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    0,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":1,"note":null,"unexpected":true}]'
  )$$,
  '22023',
  'invalid daily waste payload: unexpected field',
  'payload with unexpected key is rejected'
);

-- Unknown field rejection: payload with foo key
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    0,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":1,"foo":"bar"}]'
  )$$,
  '22023',
  'invalid daily waste payload: unexpected field',
  'payload with foo key is rejected'
);

-- Multi-item atomic rollback: valid item + invalid item rolls back completely
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    0,
    '[
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":1},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6}
    ]'
  )$$,
  '22023',
  'note required when waste exceeds threshold for unit pcs',
  'multi-item payload with 1 invalid item fails atomically'
);
select is(
  (select count(*)::int from public.branch_daily_waste_reports where branch_id='3b200000-0000-4000-8000-000000000001'),
  0,
  'atomic rollback leaves 0 reports after failed multi-item save'
);
select is(
  (select count(*)::int from public.branch_daily_waste_entries where branch_id='3b200000-0000-4000-8000-000000000001'),
  0,
  'atomic rollback leaves 0 entries after failed multi-item save'
);

-- 8. first revision 0 -> 1 / 12. new positive waste creates row
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    0,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":3}]'
  )$$,
  'first positive waste patch succeeds'
);
select is(
  (select revision from public.branch_daily_waste_reports where branch_id='3b200000-0000-4000-8000-000000000001'),
  1::bigint,
  'first save creates revision one'
);
select is(
  (select count(*)::int from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000001'),
  1,
  'new positive waste creates row'
);

-- 9. stale revision rejected
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),0,'[]')$$,
  '40001',
  'daily waste changed',
  'stale revision 0 is rejected when revision is 1'
);

-- 11. empty existing patch no revision bump
select is(
  (public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),1,'[]')->>'revision'),
  '1',
  'empty existing patch does not increment revision'
);

-- 13. exact threshold values accepted without note: 5 pcs, 700 g, 0.7 kg, 700 ml, 0.7 L
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    1,
    '[
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":5},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000010","quantity":700},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000011","quantity":0.7},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000012","quantity":700},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000013","quantity":0.7}
    ]'
  )$$,
  'exact threshold values are accepted without note'
);

-- 14. above each threshold rejects missing/blank note
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),2,'[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6}]')$$,
  '22023',
  'note required when waste exceeds threshold for unit pcs',
  'pcs > 5 rejects missing note'
);
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),2,'[{"inventory_item_id":"4b200000-0000-4000-8000-000000000010","quantity":701}]')$$,
  '22023',
  'note required when waste exceeds threshold for unit g',
  'g > 700 rejects missing note'
);
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),2,'[{"inventory_item_id":"4b200000-0000-4000-8000-000000000011","quantity":0.8}]')$$,
  '22023',
  'note required when waste exceeds threshold for unit kg',
  'kg > 0.7 rejects missing note'
);
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),2,'[{"inventory_item_id":"4b200000-0000-4000-8000-000000000012","quantity":701}]')$$,
  '22023',
  'note required when waste exceeds threshold for unit ml',
  'ml > 700 rejects missing note'
);
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),2,'[{"inventory_item_id":"4b200000-0000-4000-8000-000000000013","quantity":0.8}]')$$,
  '22023',
  'note required when waste exceeds threshold for unit L',
  'L > 0.7 rejects missing note'
);
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),2,'[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6,"note":"    "}]')$$,
  '22023',
  'note required when waste exceeds threshold for unit pcs',
  'whitespace-only note rejected as missing'
);

-- 15. above threshold accepts valid note / 16. whitespace note normalization
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    2,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6,"note":"  Damaged in fridge  "}]'
  )$$,
  'above threshold accepts valid note with trimming'
);
select is(
  (select note from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  'Damaged in fridge',
  'whitespace note is normalized and trimmed'
);

-- Exactly 500 character note is accepted
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    3,
    jsonb_build_array(jsonb_build_object('inventory_item_id','4b200000-0000-4000-8000-000000000002','quantity',6,'note',repeat('x',500)))
  )$$,
  'note with exactly 500 characters is accepted'
);
select is(
  (select length(note) from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  500,
  'stored note has length 500'
);

-- 17. note > 500 rejected (501 characters)
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    4,
    jsonb_build_array(jsonb_build_object('inventory_item_id','4b200000-0000-4000-8000-000000000002','quantity',6,'note',repeat('x',501)))
  )$$,
  '22023',
  'daily waste note exceeds maximum length',
  'note over 500 characters is rejected'
);

-- Identity preservation check across updates
drop table if exists pg_temp._beef_before;
create temp table _beef_before on commit drop as
select id, report_id, organization_id, branch_id, business_date, inventory_item_id
from public.branch_daily_waste_entries
where inventory_item_id = '4b200000-0000-4000-8000-000000000002';

select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    4,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6,"note":"Damaged in fridge"}]'
  )$$,
  'reset note to Damaged in fridge'
);

select is(
  (select id from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  (select id from _beef_before),
  'entry id strictly preserved across update'
);
select is(
  (select report_id from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  (select report_id from _beef_before),
  'report_id strictly preserved across update'
);
select is(
  (select organization_id from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  (select organization_id from _beef_before),
  'organization_id strictly preserved across update'
);
select is(
  (select branch_id from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  (select branch_id from _beef_before),
  'branch_id strictly preserved across update'
);
select is(
  (select business_date from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  (select business_date from _beef_before),
  'business_date strictly preserved across update'
);
select is(
  (select inventory_item_id from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  (select inventory_item_id from _beef_before),
  'inventory_item_id strictly preserved across update'
);

-- Numeric scale semantic no-op: 6 vs 6.0 does not bump revision
select is(
  (public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    5,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6.0,"note":"Damaged in fridge"}]'
  )->>'revision'),
  '5',
  'numeric scale variation 6 vs 6.0 produces no revision bump'
);

-- Normalized note semantic no-op: "Damaged in fridge" vs "   Damaged in fridge   " does not bump revision
select is(
  (public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    5,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6,"note":"   Damaged in fridge   "}]'
  )->>'revision'),
  '5',
  'trimmed normalized note produces no revision bump'
);

-- Null vs whitespace semantic no-op: Bread currently has note null, "   " does not bump revision
select is(
  (public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    5,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":3,"note":"   "}]'
  )->>'revision'),
  '5',
  'whitespace note for existing null note entry produces no revision bump'
);

-- Payload order invariance: saving [Beef, Bread] in different order does not bump revision
select is(
  (public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    5,
    '[
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":6,"note":"Damaged in fridge"},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":3}
    ]'
  )->>'revision'),
  '5',
  'payload order invariance produces no revision bump'
);

-- 18. Fractional pcs correction on existing active row rejected
select throws_ok(
  $$select public.save_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),5,'[{"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":2.5}]')$$,
  '22023',
  'pcs quantity must be an integer',
  'fractional quantity for pcs is rejected'
);

-- 19. g/kg/ml/L decimal quantities accepted
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    5,
    '[
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000010","quantity":123.45},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000011","quantity":0.45},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000012","quantity":500.5},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000013","quantity":0.25}
    ]'
  )$$,
  'decimal quantities for g, kg, ml, L are accepted'
);

-- 20. quantity 0 deletes existing row
select is(
  (select count(*)::int from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000001'),
  1,
  'bread exists before zeroing'
);
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    6,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000001","quantity":0}]'
  )$$,
  'explicit zero deletes existing row'
);
select is(
  (select count(*)::int from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000001'),
  0,
  'bread is removed from entries after zeroing'
);

-- 21. quantity 0 nonexistent row no-op
select is(
  (public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    7,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000003","quantity":0}]'
  )->>'revision'),
  '7',
  'quantity 0 on nonexistent row is no-op and does not increment revision'
);

-- 22. omitted item preserved / 23. multiple items patch independently
select is(
  (select quantity from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  6::numeric,
  'beef quantity is 6'
);
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    7,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000003","quantity":2}]'
  )$$,
  'patching water succeeds'
);
select is(
  (select quantity from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000002'),
  6::numeric,
  'omitted beef item is preserved'
);

-- 24. duplicate item IDs rejected
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    8,
    '[
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000003","quantity":1},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000003","quantity":2}
    ]'
  )$$,
  '23505',
  'duplicate daily waste inventory item',
  'duplicate inventory items in payload are rejected'
);

-- 25. unknown unit/corrupt catalog unit rejected safely
select throws_ok(
  $$select private.is_daily_waste_note_required('box', 10)$$,
  '22023',
  'unsupported inventory item unit: box',
  'unknown unit in helper raises exception safely'
);

-- 26. new inactive item rejected
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    8,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000014","quantity":1}]'
  )$$,
  '22023',
  'cannot record waste for inactive inventory item',
  'new waste for inactive item is rejected'
);

-- Fractional pcs correction on historical inactive row: correcting historical inactive pcs row to 2.5 is rejected
update public.branch_inventory_catalog_items
set is_active = false
where id = '4b200000-0000-4000-8000-000000000002';

select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    8,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":2.5,"note":"fractional correction"}]'
  )$$,
  '22023',
  'pcs quantity must be an integer',
  'fractional pcs correction on historical inactive row is rejected'
);

update public.branch_inventory_catalog_items
set is_active = true
where id = '4b200000-0000-4000-8000-000000000002';

-- 27. historical inactive item correction allowed / 28. snapshot name preserved / 29. snapshot unit preserved / 30. historical threshold uses frozen unit
update public.branch_inventory_catalog_items
set is_active = false, name = 'Smoky Sauce Inactive Renamed'
where id = '4b200000-0000-4000-8000-000000000010';

select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    8,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000010","quantity":800,"note":"Historical spoil"}]'
  )$$,
  'historical correction for now-inactive item succeeds'
);
select is(
  (select inventory_item_name_snapshot from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000010'),
  'Smoky Sauce',
  'historical snapshot name is preserved and not overwritten with renamed catalog'
);
select is(
  (select inventory_item_unit_snapshot from public.branch_daily_waste_entries where inventory_item_id='4b200000-0000-4000-8000-000000000010'),
  'g',
  'historical snapshot unit is preserved'
);

-- 30. historical threshold uses frozen unit
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    9,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000010","quantity":701}]'
  )$$,
  '22023',
  'note required when waste exceeds threshold for unit g',
  'historical correction exceeding frozen unit threshold requires note'
);

-- 31. identical quantity/note save no revision bump
select is(
  (public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    9,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000010","quantity":800,"note":"Historical spoil"}]'
  )->>'revision'),
  '9',
  'identical quantity and note save produces no revision bump'
);

-- 33. cross-branch inventory item rejected
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    9,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000004","quantity":1}]'
  )$$,
  '42501',
  'inventory item unavailable',
  'cross-branch inventory item is rejected'
);

-- 34. raw snapshot fields cannot be trusted from payload
select throws_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    9,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000003","quantity":1,"inventory_item_name_snapshot":"Hacked Name"}]'
  )$$,
  '22023',
  'invalid daily waste payload: unexpected field',
  'client supplied snapshot name is rejected'
);

-- 32. clearing all entries retains report with incremented revision
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    9,
    '[
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":0},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000003","quantity":0},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000010","quantity":0},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000011","quantity":0},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000012","quantity":0},
      {"inventory_item_id":"4b200000-0000-4000-8000-000000000013","quantity":0}
    ]'
  )$$,
  'clearing all entries succeeds'
);
select is(
  (select revision from public.branch_daily_waste_reports where branch_id='3b200000-0000-4000-8000-000000000001'),
  10::bigint,
  'clearing all entries increments revision'
);
select is(
  (select count(*)::int from public.branch_daily_waste_entries where branch_id='3b200000-0000-4000-8000-000000000001'),
  0,
  'clearing all entries leaves zero entry rows'
);

-- Read RPC returns report with empty entries
select is(
  jsonb_array_length(public.get_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'))->'reports'),
  1,
  'read RPC returns the report for the cleared day'
);
select is(
  (public.get_branch_daily_waste('1b200000-0000-4000-8000-000000000001','3b200000-0000-4000-8000-000000000001',private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'))->'reports'->0->>'revision'),
  '10',
  'read RPC returns revision 10 for cleared report'
);

-- GET 62-day range accepted
select lives_ok(
  $$select public.get_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh') - 62,
    private.phase4a_business_date('Asia/Riyadh')
  )$$,
  'GET exactly 62-day date range is accepted'
);

-- GET 63-day range rejected with 22023
select throws_ok(
  $$select public.get_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh') - 63,
    private.phase4a_business_date('Asia/Riyadh')
  )$$,
  '22023',
  'daily waste date range exceeds maximum of 62 days',
  'GET 63-day date range is rejected'
);

-- 35. restrictive inventory-item FK behavior
-- Re-create an entry so FK is exercised
select lives_ok(
  $$select public.save_branch_daily_waste(
    '1b200000-0000-4000-8000-000000000001',
    '3b200000-0000-4000-8000-000000000001',
    private.phase4a_business_date('Asia/Riyadh'),
    10,
    '[{"inventory_item_id":"4b200000-0000-4000-8000-000000000002","quantity":1}]'
  )$$,
  'recreating beef waste succeeds'
);
select throws_ok(
  $$delete from public.branch_inventory_catalog_items where id='4b200000-0000-4000-8000-000000000002'$$,
  '23503',
  null,
  'deleting referenced inventory item violates restrictive FK'
);

select * from finish();
rollback;
