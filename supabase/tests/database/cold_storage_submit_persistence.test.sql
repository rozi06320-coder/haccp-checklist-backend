begin;
select plan(34);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1f000000-0000-4000-8000-000000000001'::uuid,
  '1f000000-0000-4000-8000-000000000002',
  '1f000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name = case id
  when '1f000000-0000-4000-8000-000000000001' then 'Cold Submit One'
  when '1f000000-0000-4000-8000-000000000002' then 'Cold Submit Two'
  else 'Cold Submit Staff'
end, must_change_password = false
where id::text like '1f000000-%';
insert into public.organizations(id,name,slug)
values('2f000000-0000-4000-8000-000000000001','Cold Submit Org','cold-submit-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Cold Submit Branch','CSC','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','branch_manager'),
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000002','branch_manager'),
 ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001'),
 ('4f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000002');

select has_table('public','cold_storage_submission_idempotency','cold storage idempotency table exists');
select has_table('public','cold_storage_issues','cold storage issue table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.cold_storage_submission_idempotency'::regclass),'cold storage idempotency RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.cold_storage_issues'::regclass),'cold storage issues RLS enabled');
select is(has_function_privilege('authenticated','public.submit_cold_storage_slot(uuid,uuid,bigint,text,uuid,text,jsonb,jsonb)','execute'),false,'authenticated cannot execute cold storage slot submit RPC');
select is(has_function_privilege('service_role','public.submit_cold_storage_slot(uuid,uuid,bigint,text,uuid,text,jsonb,jsonb)','execute'),true,'service role can execute cold storage slot submit RPC');
select ok(not has_table_privilege('authenticated','public.cold_storage_submission_idempotency','insert')
  and not has_table_privilege('authenticated','public.cold_storage_issues','insert')
  and not has_table_privilege('authenticated','public.cold_storage_issues','update'),
  'authenticated role has no direct cold storage idempotency or issue writes');

select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000001',
    repeat('a',64),
    '[{"equipment_id":"inactive","equipment_name":"Inactive Ref","equipment_type":"refrigerator","active":false}]'::jsonb,
    '[{"equipment_id":"inactive","slot":"12:00","temperature_c":9,"status":"fail","corrective_action":"ignored"}]'::jsonb
  )
$$, '22023', 'invalid cold storage slot submit', 'submit requires at least one active equipment');
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000002',
    repeat('a',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[]'::jsonb
  )
$$, '22023', 'invalid cold storage slot submit', 'active equipment requires a slot reading');
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000003',
    repeat('a',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"12:00","temperature_c":"","status":"pending"}]'::jsonb
  )
$$, '22023', 'invalid cold storage slot submit', 'active reading requires numeric temperature');
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000004',
    repeat('a',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"12:00","temperature_c":5,"status":"fail","corrective_action":"  "}]'::jsonb
  )
$$, '22023', 'invalid cold storage slot submit', '5C requires corrective action');
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '3:00',
    '5f000000-0000-4000-8000-000000000005',
    repeat('a',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"12:00","temperature_c":4,"status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid cold storage slot', 'removed 3:00 submitted slot is rejected');
select throws_ok($$
  select public.save_cold_storage_draft(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"8:00","temperature_c":4,"status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid cold storage reading row', 'removed 8:00 draft slot is rejected');
select ok(
  pg_catalog.pg_get_constraintdef((
    select oid from pg_catalog.pg_constraint
    where conname = 'cold_storage_readings_slot_check'
      and conrelid = 'public.cold_storage_readings'::regclass
  )) like '%8:00%',
  'legacy slot remains allowed by storage constraint for existing read compatibility'
);
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000006',
    repeat('a',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"warmer","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"12:00","temperature_c":4,"status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid cold storage equipment row', 'invalid equipment type is rejected');
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000007',
    repeat('a',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"missing","slot":"12:00","temperature_c":4,"status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid cold storage reading row', 'reading for unknown equipment is rejected');

select lives_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000008',
    repeat('b',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"12:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"inactive","slot":"12:00","temperature_c":12,"status":"fail","corrective_action":"ignored"},
      {"equipment_id":"ref-1","slot":"12:00","temperature_c":5,"status":"fail","corrective_action":"Moved product and adjusted thermostat"}
    ]'::jsonb
  )
$$, 'successful 12:00 submit');
select is(
  (select count(*) from public.cold_storage_readings r
   join public.cold_storage_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'
     and r.slot = '12:00'
     and r.submitted_at is not null),
  2::bigint,
  '12:00 submit locks active equipment readings only'
);
select is(
  (select count(*) from public.cold_storage_issues i
   join public.cold_storage_submissions s on s.id = i.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'),
  1::bigint,
  '5C creates one issue and inactive high temperature is ignored'
);
select is(
  (select equipment_id || ':' || temperature_c::text from public.cold_storage_issues i
   join public.cold_storage_submissions s on s.id = i.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'),
  'ref-1:5',
  'issue references active 5C equipment'
);
select is(
  (select status from public.cold_storage_readings r
   join public.cold_storage_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'
     and r.equipment_id = 'freezer-1' and r.slot = '12:00'),
  'pass',
  '4.9-or-less safe readings are pass'
);
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000008',
    repeat('b',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"12:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"inactive","slot":"12:00","temperature_c":12,"status":"fail","corrective_action":"ignored"},
      {"equipment_id":"ref-1","slot":"12:00","temperature_c":5,"status":"fail","corrective_action":"Moved product and adjusted thermostat"}
    ]'::jsonb
  )
$$, 'idempotent replay same hash succeeds');
select is(
  (select count(*) from public.cold_storage_issues i
   join public.cold_storage_submissions s on s.id = i.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'),
  1::bigint,
  'idempotent replay does not duplicate issue'
);
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000008',
    repeat('c',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"12:00","temperature_c":4,"status":"pass"}]'::jsonb
  )
$$, '23505', 'idempotency conflict', 'changed hash replay is rejected');
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    '5f000000-0000-4000-8000-000000000009',
    repeat('d',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"12:00","temperature_c":-17,"status":"pass"},
      {"equipment_id":"ref-1","slot":"12:00","temperature_c":4,"status":"pass"}
    ]'::jsonb
  )
$$, '23505', 'cold storage slot already submitted', 'submitted slot cannot be changed with new key');

select lives_ok($$
  select public.save_cold_storage_draft(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[
      {"equipment_id":"freezer-1","equipment_name":"Changed Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Changed","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Changed Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"12:00","temperature_c":-1,"status":"fail","corrective_action":"bad draft"},
      {"equipment_id":"ref-1","slot":"12:00","temperature_c":1,"status":"pass"},
      {"equipment_id":"freezer-1","slot":"20:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"ref-1","slot":"20:00","temperature_c":4.9,"status":"pass"}
    ]'::jsonb
  )
$$, 'draft after 12:00 submit can update unsubmitted slots');
select is(
  (select temperature_c from public.cold_storage_readings r
   join public.cold_storage_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'
     and r.equipment_id = 'ref-1' and r.slot = '12:00'),
  5::numeric,
  'submitted 12:00 reading remains immutable after draft save'
);
select is(
  (select temperature_c from public.cold_storage_readings r
   join public.cold_storage_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'
     and r.equipment_id = 'ref-1' and r.slot = '20:00'),
  4.9::numeric,
  'unsubmitted 20:00 reading updates through draft save'
);

select lives_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '20:00',
    '5f000000-0000-4000-8000-000000000010',
    repeat('e',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"20:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"ref-1","slot":"20:00","temperature_c":4.9,"status":"pass"}
    ]'::jsonb
  )
$$, 'successful 20:00 submit');
select is(
  (select count(*) from public.cold_storage_issues i
   join public.cold_storage_submissions s on s.id = i.submission_id
   where s.supervisor_team_id = '4f000000-0000-4000-8000-000000000001'
     and i.slot = '20:00'),
  0::bigint,
  '4.9C does not create issue'
);
select lives_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '02:00',
    '5f000000-0000-4000-8000-000000000011',
    repeat('f',64),
    '[
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":true},
      {"equipment_id":"inactive","equipment_name":"Inactive Refrigerator","equipment_type":"refrigerator","active":false},
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}
    ]'::jsonb,
    '[
      {"equipment_id":"freezer-1","slot":"02:00","temperature_c":-19,"status":"pass"},
      {"equipment_id":"ref-1","slot":"02:00","temperature_c":4.8,"status":"pass"}
    ]'::jsonb
  )
$$, 'successful 02:00 submit');
select is(
  (select state from public.cold_storage_submissions where supervisor_team_id = '4f000000-0000-4000-8000-000000000001'),
  'submitted',
  'submission becomes submitted after all active slots submitted'
);

select is(
  jsonb_array_length(public.get_cold_storage_current_state('1f000000-0000-4000-8000-000000000002','3f000000-0000-4000-8000-000000000001')->'equipment'),
  3,
  'same-branch other supervisor can read branch-shared submitted cold storage state'
);
select throws_ok($$
  select public.submit_cold_storage_slot(
    '1f000000-0000-4000-8000-000000000003',
    '3f000000-0000-4000-8000-000000000001',
    0,
    '12:00',
    '5f000000-0000-4000-8000-000000000012',
    repeat('a',64),
    '[{"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-1","slot":"12:00","temperature_c":4,"status":"pass"}]'::jsonb
  )
$$, '42501', 'cold storage operation denied', 'staff actor cannot submit');

select * from finish();
rollback;
