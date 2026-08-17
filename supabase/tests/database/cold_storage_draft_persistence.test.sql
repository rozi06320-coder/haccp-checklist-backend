begin;
select plan(33);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1e000000-0000-4000-8000-000000000001'::uuid,
  '1e000000-0000-4000-8000-000000000002',
  '1e000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name = case id
  when '1e000000-0000-4000-8000-000000000001' then 'Cold Supervisor One'
  when '1e000000-0000-4000-8000-000000000002' then 'Cold Supervisor Two'
  else 'Cold Staff'
end, must_change_password = false
where id::text like '1e000000-%';
insert into public.organizations(id,name,slug)
values('2e000000-0000-4000-8000-000000000001','Cold Storage Org','cold-storage-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Cold Branch','COLD','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager'),
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002','branch_manager'),
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001'),
 ('4e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002');

select has_table('public','cold_storage_submissions','cold storage submission table exists');
select has_table('public','cold_storage_equipment','cold storage equipment table exists');
select has_table('public','cold_storage_readings','cold storage reading table exists');
select col_is_pk('public','cold_storage_submissions','id','cold storage submission UUID PK');
select col_is_pk('public','cold_storage_equipment','id','cold storage equipment UUID PK');
select col_is_pk('public','cold_storage_readings','id','cold storage reading UUID PK');
select ok((select relrowsecurity from pg_class where oid = 'public.cold_storage_submissions'::regclass),'cold storage submission RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.cold_storage_equipment'::regclass),'cold storage equipment RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.cold_storage_readings'::regclass),'cold storage reading RLS enabled');
select is(has_function_privilege('authenticated','public.save_cold_storage_draft(uuid,uuid,bigint,jsonb,jsonb)','execute'),false,'authenticated cannot execute cold storage draft RPC');
select is(has_function_privilege('service_role','public.save_cold_storage_draft(uuid,uuid,bigint,jsonb,jsonb)','execute'),true,'service role can execute cold storage draft RPC');
select ok(not has_table_privilege('authenticated','public.cold_storage_submissions','insert')
  and not has_table_privilege('authenticated','public.cold_storage_equipment','insert')
  and not has_table_privilege('authenticated','public.cold_storage_readings','insert')
  and not has_table_privilege('authenticated','public.cold_storage_submissions','update')
  and not has_table_privilege('authenticated','public.cold_storage_equipment','delete')
  and not has_table_privilege('authenticated','public.cold_storage_readings','delete'),
  'authenticated role has no direct cold storage writes');

select is(
  public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->>'business_date',
  private.phase4a_business_date('Asia/Riyadh')::text,
  'empty state uses server business date'
);
select is(
  public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->>'state',
  'none',
  'empty current state has none state'
);
select is(
  jsonb_array_length(public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->'equipment'),
  0,
  'empty current state has no equipment'
);
select is(
  jsonb_array_length(public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->'readings'),
  0,
  'empty current state has no readings'
);

select lives_ok($$
  select public.save_cold_storage_draft(
    '1e000000-0000-4000-8000-000000000001',
    '3e000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[
      {"equipment_id":"ref-1","equipment_name":"Line Refrigerator","equipment_type":"refrigerator"},
      {"equipment_id":"freezer-1","equipment_name":"Walk-in Freezer","equipment_type":"freezer","active":false}
    ]'::jsonb,
    '[
      {"equipment_id":"ref-1","slot":"12:00","temperature_c":"3.5","status":"pass"},
      {"equipment_id":"ref-1","slot":"20:00","temperature_c":5.2,"status":"fail","corrective_action":"Moved food and adjusted thermostat"},
      {"equipment_id":"freezer-1","slot":"02:00","temperature_c":"","status":"pending","corrective_action":null}
    ]'::jsonb
  )
$$, 'supervisor saves cold storage draft');
select is(
  (select count(*) from public.cold_storage_submissions
   where organization_id = '2e000000-0000-4000-8000-000000000001'
     and branch_id = '3e000000-0000-4000-8000-000000000001'
     and supervisor_team_id = '4e000000-0000-4000-8000-000000000001'),
  1::bigint,
  'one cold storage submission row saved'
);
select is(
  (select business_date from public.cold_storage_submissions
   where supervisor_team_id = '4e000000-0000-4000-8000-000000000001'),
  private.phase4a_business_date('Asia/Riyadh'),
  'draft business date is server-calculated'
);
select is(
  (select branch_name_snapshot || '|' || supervisor_name_snapshot || '|' || team_name_snapshot
   from public.cold_storage_submissions where supervisor_team_id = '4e000000-0000-4000-8000-000000000001'),
  'Cold Branch|Cold Supervisor One|Cold Supervisor One Team',
  'snapshots are populated from verified server context'
);
select is(
  jsonb_array_length(public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->'equipment'),
  2,
  'equipment added once and restored'
);
select is(
  jsonb_array_length(public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->'readings'),
  3,
  'reading rows restore per equipment and slot'
);
select is(
  (select string_agg((elem.value->>'equipment_id') || ':' || (elem.value->>'slot') || ':' || (elem.value->>'status'), ',' order by elem.value->>'equipment_id', elem.value->>'slot')
   from jsonb_array_elements(public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->'readings') as elem(value)),
  'freezer-1:02:00:pending,ref-1:12:00:pass,ref-1:20:00:fail',
  'readings restore by equipment and slot'
);
select is(
  public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->'readings'->1->>'temperature_c',
  '3.5',
  'numeric string restores as numeric JSON'
);
select is(
  jsonb_array_length(public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000001')->'equipment'),
  2,
  'same-branch other supervisor can read branch-shared cold storage draft'
);
select throws_ok($$
  select public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000003','3e000000-0000-4000-8000-000000000001')
$$, '42501', 'cold storage state denied', 'staff actor is denied');

select lives_ok($$
  select public.save_cold_storage_draft(
    '1e000000-0000-4000-8000-000000000001',
    '3e000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"equipment_id":"ref-2","equipment_name":"Prep Refrigerator","equipment_type":"refrigerator","active":true}]'::jsonb,
    '[{"equipment_id":"ref-2","slot":"12:00","temperature_c":4.4,"status":"pass","corrective_action":"ok"}]'::jsonb
  )
$$, 'second draft save succeeds');
select is(
  (select count(*) from public.cold_storage_equipment e
   join public.cold_storage_submissions s on s.id = e.submission_id
   where s.supervisor_team_id = '4e000000-0000-4000-8000-000000000001'),
  1::bigint,
  'second draft replaces equipment rows instead of duplicating'
);
select is(
  (select count(*) from public.cold_storage_readings r
   join public.cold_storage_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4e000000-0000-4000-8000-000000000001'),
  1::bigint,
  'second draft replaces reading rows instead of duplicating'
);
select is(
  public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->'equipment'->0->>'equipment_id',
  'ref-2',
  'replacement equipment is restored'
);
select throws_ok($$
  select public.save_cold_storage_draft(
    '1e000000-0000-4000-8000-000000000001',
    '3e000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"equipment_id":"ref-3","equipment_name":"Bad Unit","equipment_type":"warmer"}]'::jsonb,
    '[]'::jsonb
  )
$$, '22023', 'invalid cold storage equipment row', 'invalid equipment_type is rejected');
select throws_ok($$
  select public.save_cold_storage_draft(
    '1e000000-0000-4000-8000-000000000001',
    '3e000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"equipment_id":"ref-3","equipment_name":"Prep Refrigerator","equipment_type":"refrigerator"}]'::jsonb,
    '[{"equipment_id":"ref-3","slot":"2:00","temperature_c":3,"status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid cold storage reading row', 'invalid slot is rejected');
select throws_ok($$
  select public.save_cold_storage_draft(
    '1e000000-0000-4000-8000-000000000001',
    '3e000000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"equipment_id":"ref-3","equipment_name":"Prep Refrigerator","equipment_type":"refrigerator"}]'::jsonb,
    '[{"equipment_id":"missing","slot":"12:00","temperature_c":3,"status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid cold storage reading row', 'reading for unknown equipment is rejected');

select * from finish();
rollback;
