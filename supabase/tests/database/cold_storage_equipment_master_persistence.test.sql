begin;
select plan(23);

insert into auth.users(
  instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  user_id,
  'authenticated',
  'authenticated',
  user_id || '@example.invalid',
  '{}',
  '{}',
  now(),
  now()
from unnest(array[
  'ce100000-0000-4000-8000-000000000001'::uuid,
  'ce100000-0000-4000-8000-000000000002'::uuid,
  'ce100000-0000-4000-8000-000000000003'::uuid
]) user_id;

update public.profiles
set full_name = case id
  when 'ce100000-0000-4000-8000-000000000001' then 'Master Supervisor'
  when 'ce100000-0000-4000-8000-000000000002' then 'Legacy Supervisor'
  else 'Master Organization Manager'
end,
must_change_password = false
where id::text like 'ce100000-%';

insert into public.organizations(id, name, slug)
values ('ce200000-0000-4000-8000-000000000001', 'Master Persistence Org', 'master-persistence-org');

insert into public.branches(id, organization_id, name, code, timezone) values
  ('ce300000-0000-4000-8000-000000000001', 'ce200000-0000-4000-8000-000000000001', 'Master Branch', 'MST', 'Asia/Riyadh'),
  ('ce300000-0000-4000-8000-000000000002', 'ce200000-0000-4000-8000-000000000001', 'Legacy Branch', 'LEG', 'Asia/Riyadh');

insert into public.branch_memberships(branch_id, user_id, role) values
  ('ce300000-0000-4000-8000-000000000001', 'ce100000-0000-4000-8000-000000000001', 'branch_manager'),
  ('ce300000-0000-4000-8000-000000000002', 'ce100000-0000-4000-8000-000000000002', 'branch_manager');

insert into public.organization_memberships(organization_id, user_id, role)
values ('ce200000-0000-4000-8000-000000000001', 'ce100000-0000-4000-8000-000000000003', 'organization_manager');

insert into public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id) values
  ('ce400000-0000-4000-8000-000000000001', 'ce200000-0000-4000-8000-000000000001', 'ce300000-0000-4000-8000-000000000001', 'ce100000-0000-4000-8000-000000000001'),
  ('ce400000-0000-4000-8000-000000000002', 'ce200000-0000-4000-8000-000000000001', 'ce300000-0000-4000-8000-000000000002', 'ce100000-0000-4000-8000-000000000002');

insert into public.branch_cold_storage_equipment(
  id, organization_id, branch_id, name, equipment_type, created_by
) values
  ('ce500000-0000-4000-8000-000000000001', 'ce200000-0000-4000-8000-000000000001', 'ce300000-0000-4000-8000-000000000001', 'Walk-in Freezer', 'freezer', 'ce100000-0000-4000-8000-000000000001'),
  ('ce500000-0000-4000-8000-000000000099', 'ce200000-0000-4000-8000-000000000001', 'ce300000-0000-4000-8000-000000000002', 'Other Branch Freezer', 'freezer', 'ce100000-0000-4000-8000-000000000002');

select is(
  jsonb_array_length(
    public.get_cold_storage_current_state(
      'ce100000-0000-4000-8000-000000000001',
      'ce300000-0000-4000-8000-000000000001'
    ) -> 'equipment'
  ),
  1,
  'current-state without a submission returns the active branch master roster'
);

select is(
  public.get_cold_storage_current_state(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001'
  ) -> 'equipment' -> 0 ->> 'equipment_id',
  'ce500000-0000-4000-8000-000000000001',
  'master UUID is the canonical current-state equipment ID'
);

select lives_ok($$
  select public.save_cold_storage_draft(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('ce100000-0000-4000-8000-000000000001','ce300000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"equipment_id":"ce500000-0000-4000-8000-000000000001","equipment_name":"Browser Spoof","equipment_type":"refrigerator","active":false}]'::jsonb,
    '[{"equipment_id":"ce500000-0000-4000-8000-000000000001","slot":"12:00","temperature_c":-18,"status":"pass"}]'::jsonb
  )
$$, 'draft save accepts a master-backed equipment UUID');

select is(
  (select equipment_name || '|' || equipment_type || '|' || active::text
   from public.cold_storage_equipment
   where master_equipment_id = 'ce500000-0000-4000-8000-000000000001'),
  'Walk-in Freezer|freezer|true',
  'draft snapshot name, type, and active state are derived from the master'
);

select is(
  (select organization_id::text || '|' || branch_id::text
   from public.cold_storage_equipment
   where master_equipment_id = 'ce500000-0000-4000-8000-000000000001'),
  'ce200000-0000-4000-8000-000000000001|ce300000-0000-4000-8000-000000000001',
  'master snapshot linkage is scoped from server-owned data'
);

select is(
  public.get_cold_storage_current_state(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001'
  ) -> 'readings' -> 0 ->> 'temperature_c',
  '-18',
  'master-backed draft reading restores'
);

insert into public.branch_cold_storage_equipment(
  id, organization_id, branch_id, name, equipment_type, created_by
) values (
  'ce500000-0000-4000-8000-000000000002',
  'ce200000-0000-4000-8000-000000000001',
  'ce300000-0000-4000-8000-000000000001',
  'Line Refrigerator',
  'refrigerator',
  'ce100000-0000-4000-8000-000000000001'
);

select is(
  jsonb_array_length(
    public.get_cold_storage_current_state(
      'ce100000-0000-4000-8000-000000000001',
      'ce300000-0000-4000-8000-000000000001'
    ) -> 'equipment'
  ),
  2,
  'an active master added after draft creation appears in unsubmitted current-state'
);

select lives_ok($$
  select * from public.rename_supervisor_cold_storage_equipment(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    'ce500000-0000-4000-8000-000000000001',
    'Main Walk-in Freezer'
  )
$$, 'master equipment can be renamed before submit');

select is(
  (select value ->> 'equipment_name'
   from jsonb_array_elements(public.get_cold_storage_current_state(
     'ce100000-0000-4000-8000-000000000001',
     'ce300000-0000-4000-8000-000000000001'
   ) -> 'equipment')
   where value ->> 'equipment_id' = 'ce500000-0000-4000-8000-000000000001'),
  'Main Walk-in Freezer',
  'an unsubmitted draft displays the current master name'
);

select lives_ok($$
  select public.save_cold_storage_draft(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('ce100000-0000-4000-8000-000000000001','ce300000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[
      {"equipment_id":"ce500000-0000-4000-8000-000000000001","equipment_name":"Ignored One","equipment_type":"refrigerator"},
      {"equipment_id":"ce500000-0000-4000-8000-000000000002","equipment_name":"Ignored Two","equipment_type":"freezer"}
    ]'::jsonb,
    '[{"equipment_id":"ce500000-0000-4000-8000-000000000001","slot":"12:00","temperature_c":-17,"status":"pass"}]'::jsonb
  )
$$, 'draft refreshes its snapshot from all active master rows');

select is(
  (select count(*) from public.cold_storage_equipment snapshot
   where snapshot.submission_id = (
     select id from public.cold_storage_submissions
     where supervisor_team_id = 'ce400000-0000-4000-8000-000000000001'
   ) and snapshot.master_equipment_id is not null),
  2::bigint,
  'draft snapshot contains exactly the two linked active master rows'
);

select throws_ok($$
  select public.save_cold_storage_draft(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('ce100000-0000-4000-8000-000000000001','ce300000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"equipment_id":"ce500000-0000-4000-8000-000000000099","equipment_name":"Cross Branch","equipment_type":"freezer"}]'::jsonb,
    '[]'::jsonb
  )
$$, '42501', 'cold storage master equipment denied', 'draft rejects a master equipment UUID from another branch');

select lives_ok($$
  select public.submit_cold_storage_slot(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('ce100000-0000-4000-8000-000000000001','ce300000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '12:00',
    'ce600000-0000-4000-8000-000000000001',
    repeat('a', 64),
    '[
      {"equipment_id":"ce500000-0000-4000-8000-000000000001","equipment_name":"Spoofed","equipment_type":"refrigerator"},
      {"equipment_id":"ce500000-0000-4000-8000-000000000002","equipment_name":"Spoofed","equipment_type":"freezer"}
    ]'::jsonb,
    '[
      {"equipment_id":"ce500000-0000-4000-8000-000000000001","slot":"12:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"ce500000-0000-4000-8000-000000000002","slot":"12:00","temperature_c":3,"status":"pass"}
    ]'::jsonb
  )
$$, 'first slot submit stores the server-derived master snapshot');

select lives_ok($$
  select * from public.rename_supervisor_cold_storage_equipment(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    'ce500000-0000-4000-8000-000000000001',
    'Renamed After Submit'
  )
$$, 'master can be renamed after a slot is submitted');

select is(
  (select value ->> 'equipment_name'
   from jsonb_array_elements(public.get_cold_storage_current_state(
     'ce100000-0000-4000-8000-000000000001',
     'ce300000-0000-4000-8000-000000000001'
   ) -> 'equipment')
   where value ->> 'equipment_id' = 'ce500000-0000-4000-8000-000000000001'),
  'Main Walk-in Freezer',
  'a submitted slot freezes the current-day equipment name snapshot'
);

select lives_ok($$
  select public.save_cold_storage_draft(
    'ce100000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    (public.get_cold_storage_current_state('ce100000-0000-4000-8000-000000000001','ce300000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[
      {"equipment_id":"ce500000-0000-4000-8000-000000000001","equipment_name":"Browser Rename","equipment_type":"freezer"},
      {"equipment_id":"ce500000-0000-4000-8000-000000000002","equipment_name":"Browser Rename","equipment_type":"freezer"}
    ]'::jsonb,
    '[
      {"equipment_id":"ce500000-0000-4000-8000-000000000001","slot":"20:00","temperature_c":-18,"status":"pass"},
      {"equipment_id":"ce500000-0000-4000-8000-000000000002","slot":"20:00","temperature_c":3,"status":"pass"}
    ]'::jsonb
  )
$$, 'draft can update an unsubmitted slot after the roster is frozen');

select is(
  (select equipment_name
   from public.cold_storage_equipment
   where master_equipment_id = 'ce500000-0000-4000-8000-000000000001'),
  'Main Walk-in Freezer',
  'post-submit draft cannot alter the frozen snapshot name'
);

select is(
  (select value ->> 'equipment_name'
   from jsonb_array_elements(public.get_cold_storage_managed_report_detail(
     'ce100000-0000-4000-8000-000000000003',
     'ce200000-0000-4000-8000-000000000001',
     (select id from public.cold_storage_submissions
      where supervisor_team_id = 'ce400000-0000-4000-8000-000000000001')
   ) -> 'rows')
   where value ->> 'equipment_id' = 'ce500000-0000-4000-8000-000000000001'),
  'Main Walk-in Freezer',
  'Manager report detail continues to read the frozen submission snapshot name'
);

update public.cold_storage_submissions
set business_date = business_date - 1
where supervisor_team_id = 'ce400000-0000-4000-8000-000000000001';

select is(
  (select value ->> 'equipment_name'
   from jsonb_array_elements(public.get_cold_storage_current_state(
     'ce100000-0000-4000-8000-000000000001',
     'ce300000-0000-4000-8000-000000000001'
   ) -> 'equipment')
   where value ->> 'equipment_id' = 'ce500000-0000-4000-8000-000000000001'),
  'Renamed After Submit',
  'the next business date uses the renamed active master name'
);

select lives_ok($$
  select public.save_cold_storage_draft(
    'ce100000-0000-4000-8000-000000000002',
    'ce300000-0000-4000-8000-000000000002',
    (public.get_cold_storage_current_state('ce100000-0000-4000-8000-000000000002','ce300000-0000-4000-8000-000000000002')->>'revision')::bigint,
    '[{"equipment_id":"legacy-text-id","equipment_name":"Legacy Text Refrigerator","equipment_type":"refrigerator"}]'::jsonb,
    '[{"equipment_id":"legacy-text-id","slot":"12:00","temperature_c":4,"status":"pass"}]'::jsonb
  )
$$, 'legacy text-only equipment remains supported alongside a branch master');

select is(
  (select equipment_name
   from public.cold_storage_equipment snapshot
   join public.cold_storage_submissions submission on submission.id = snapshot.submission_id
   where submission.supervisor_team_id = 'ce400000-0000-4000-8000-000000000002'
     and snapshot.equipment_id = 'legacy-text-id'),
  'Legacy Text Refrigerator',
  'legacy text-only snapshot remains readable'
);

select is(
  (select master_equipment_id
   from public.cold_storage_equipment snapshot
   join public.cold_storage_submissions submission on submission.id = snapshot.submission_id
   where submission.supervisor_team_id = 'ce400000-0000-4000-8000-000000000002'
     and snapshot.equipment_id = 'legacy-text-id'),
  null::uuid,
  'legacy text-only snapshot remains unlinked from the equipment master'
);

select is(
  jsonb_array_length(public.get_cold_storage_current_state(
    'ce100000-0000-4000-8000-000000000002',
    'ce300000-0000-4000-8000-000000000002'
  ) -> 'equipment'),
  2,
  'legacy current-state includes both active master and legacy snapshot equipment'
);

select * from finish();
rollback;
