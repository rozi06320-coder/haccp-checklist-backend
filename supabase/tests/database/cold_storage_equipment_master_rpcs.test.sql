begin;
select plan(40);

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
  'cf100000-0000-4000-8000-000000000001'::uuid,
  'cf100000-0000-4000-8000-000000000002'::uuid,
  'cf100000-0000-4000-8000-000000000003'::uuid,
  'cf100000-0000-4000-8000-000000000004'::uuid
]) user_id;

update public.profiles
set full_name = case id
  when 'cf100000-0000-4000-8000-000000000001' then 'Equipment Supervisor'
  when 'cf100000-0000-4000-8000-000000000002' then 'Other Supervisor'
  when 'cf100000-0000-4000-8000-000000000004' then 'Same Branch Supervisor'
  else 'Organization Manager'
end,
must_change_password = false
where id::text like 'cf100000-%';

insert into public.organizations(id, name, slug) values
  ('cf200000-0000-4000-8000-000000000001', 'Equipment RPC Org', 'equipment-rpc-org'),
  ('cf200000-0000-4000-8000-000000000002', 'Other Equipment RPC Org', 'other-equipment-rpc-org');

insert into public.branches(id, organization_id, name, code, timezone) values
  ('cf300000-0000-4000-8000-000000000001', 'cf200000-0000-4000-8000-000000000001', 'Assigned Branch', 'RPC-A', 'Asia/Riyadh'),
  ('cf300000-0000-4000-8000-000000000002', 'cf200000-0000-4000-8000-000000000001', 'Other Branch', 'RPC-B', 'Asia/Riyadh'),
  ('cf300000-0000-4000-8000-000000000003', 'cf200000-0000-4000-8000-000000000002', 'Other Organization Branch', 'RPC-X', 'Asia/Riyadh');

insert into public.branch_memberships(branch_id, user_id, role) values
  ('cf300000-0000-4000-8000-000000000001', 'cf100000-0000-4000-8000-000000000001', 'branch_manager'),
  ('cf300000-0000-4000-8000-000000000001', 'cf100000-0000-4000-8000-000000000004', 'branch_manager'),
  ('cf300000-0000-4000-8000-000000000002', 'cf100000-0000-4000-8000-000000000002', 'branch_manager');

insert into public.organization_memberships(organization_id, user_id, role) values
  ('cf200000-0000-4000-8000-000000000001', 'cf100000-0000-4000-8000-000000000003', 'organization_manager');

insert into public.branch_supervisor_teams(
  id, organization_id, branch_id, supervisor_user_id
) values
  ('cf400000-0000-4000-8000-000000000001', 'cf200000-0000-4000-8000-000000000001', 'cf300000-0000-4000-8000-000000000001', 'cf100000-0000-4000-8000-000000000001'),
  ('cf400000-0000-4000-8000-000000000004', 'cf200000-0000-4000-8000-000000000001', 'cf300000-0000-4000-8000-000000000001', 'cf100000-0000-4000-8000-000000000004'),
  ('cf400000-0000-4000-8000-000000000002', 'cf200000-0000-4000-8000-000000000001', 'cf300000-0000-4000-8000-000000000002', 'cf100000-0000-4000-8000-000000000002');

select ok(
  has_function_privilege(
    'service_role',
    'public.list_supervisor_cold_storage_equipment(uuid,uuid)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'public.create_supervisor_cold_storage_equipment(uuid,uuid,text,text,text)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'public.rename_supervisor_cold_storage_equipment(uuid,uuid,uuid,text)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'public.update_supervisor_cold_storage_equipment(uuid,uuid,uuid,text,text,text)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'public.archive_supervisor_cold_storage_equipment(uuid,uuid,uuid)',
    'execute'
  ),
  'service role can execute master equipment RPCs'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.list_supervisor_cold_storage_equipment(uuid,uuid)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.create_supervisor_cold_storage_equipment(uuid,uuid,text,text,text)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.rename_supervisor_cold_storage_equipment(uuid,uuid,uuid,text)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.update_supervisor_cold_storage_equipment(uuid,uuid,uuid,text,text,text)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.archive_supervisor_cold_storage_equipment(uuid,uuid,uuid)',
    'execute'
  ),
  'authenticated cannot execute master equipment RPCs directly'
);

select is(
  (select equipment_code || '|' || name
   from public.create_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     E' g1 ',
     E'  Walk-in\t  Freezer  ',
     'freezer'
   )),
  'G1|Walk-in Freezer',
  'assigned Supervisor creates equipment with normalized code and name'
);

select is(
  (select organization_id::text || '|' || branch_id::text || '|' || created_by::text
   from public.branch_cold_storage_equipment
   where name = 'Walk-in Freezer'),
  'cf200000-0000-4000-8000-000000000001|cf300000-0000-4000-8000-000000000001|cf100000-0000-4000-8000-000000000001',
  'organization, branch, and creator are derived from the verified actor context'
);

select lives_ok($$
  insert into public.branch_cold_storage_equipment(
    organization_id, branch_id, name, equipment_type, active, created_by
  ) values (
    'cf200000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'Retired Freezer',
    'freezer',
    false,
    'cf100000-0000-4000-8000-000000000001'
  )
$$, 'inactive equipment fixture can coexist in the master table');

insert into public.branch_cold_storage_equipment(
  organization_id, branch_id, name, equipment_type, created_by
) values (
  'cf200000-0000-4000-8000-000000000001',
  'cf300000-0000-4000-8000-000000000002',
  'Other Branch Freezer',
  'freezer',
  'cf100000-0000-4000-8000-000000000002'
);

select is(
  (select count(*)
   from public.list_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001'
   )),
  1::bigint,
  'list returns active equipment only'
);

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'W1',
    'Warmer',
    'warmer'
  )
$$, '22023', 'invalid cold storage equipment type', 'create rejects invalid equipment type');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'B1',
    '   ',
    'freezer'
  )
$$, '22023', 'invalid cold storage equipment name', 'create rejects blank equipment name');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'L1',
    repeat('x', 121),
    'freezer'
  )
$$, '22023', 'invalid cold storage equipment name', 'create rejects overlong equipment name');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'G2',
    'walk-in freezer',
    'freezer'
  )
$$, '23505', null, 'create rejects duplicate normalized active name');

select is(
  (select equipment_code || '|' || name
   from public.create_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     'C1',
     'Reach-in Refrigerator',
     'refrigerator'
   )),
  'C1|Reach-in Refrigerator',
  'assigned Supervisor can create a second distinct equipment row'
);

select is(
  (select equipment_code
   from public.create_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     'ch-01',
     'Front Counter Chiller',
     'refrigerator'
   )),
  'CH-01',
  'create accepts hyphenated codes and normalizes lowercase'
);

select throws_ok($$
  select * from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'C 2',
    'Invalid Space Code',
    'refrigerator'
  )
$$, '22023', 'invalid cold storage equipment code', 'create rejects internal code spaces');

select throws_ok($$
  select * from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'C/2',
    'Invalid Slash Code',
    'refrigerator'
  )
$$, '22023', 'invalid cold storage equipment code', 'create rejects invalid code characters');

select throws_ok($$
  select * from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    repeat('C', 25),
    'Overlong Code',
    'refrigerator'
  )
$$, '22023', 'invalid cold storage equipment code', 'create rejects codes longer than 24 characters');

select throws_ok($$
  select * from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    '',
    'Blank Code',
    'refrigerator'
  )
$$, '22023', 'invalid cold storage equipment code', 'create rejects empty code');

select throws_ok($$
  select * from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'C1',
    'Duplicate Code Refrigerator',
    'refrigerator'
  )
$$, '23505', 'equipment code already exists', 'create rejects duplicate active code in the same branch');

select lives_ok($$
  select * from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000002',
    'cf300000-0000-4000-8000-000000000002',
    'C1',
    'Other Branch Code Freezer',
    'freezer'
  )
$$, 'same equipment code is allowed in another branch');

insert into public.branch_cold_storage_equipment(
  organization_id, branch_id, equipment_code, name, equipment_type, active, created_by
) values (
  'cf200000-0000-4000-8000-000000000001',
  'cf300000-0000-4000-8000-000000000001',
  'R1',
  'Archived Code Fixture',
  'freezer',
  false,
  'cf100000-0000-4000-8000-000000000001'
);

select lives_ok($$
  select * from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'R1',
    'Reused Archived Code',
    'freezer'
  )
$$, 'archived equipment code can be reused in the same branch');

insert into public.cold_storage_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, state, branch_name_snapshot, supervisor_name_snapshot,
  team_name_snapshot
) values (
  'cf500000-0000-4000-8000-000000000001',
  'cf200000-0000-4000-8000-000000000001',
  'cf300000-0000-4000-8000-000000000001',
  'cf100000-0000-4000-8000-000000000001',
  'cf400000-0000-4000-8000-000000000001',
  '2026-08-10',
  'submitted',
  'Assigned Branch',
  'Equipment Supervisor',
  'Equipment Supervisor Team'
);

insert into public.cold_storage_equipment(
  id, submission_id, equipment_id, equipment_name, equipment_type, active,
  master_equipment_id, organization_id, branch_id
)
select
  'cf600000-0000-4000-8000-000000000001',
  'cf500000-0000-4000-8000-000000000001',
  'historical-freezer',
  'Walk-in Freezer',
  'freezer',
  true,
  master.id,
  master.organization_id,
  master.branch_id
from public.branch_cold_storage_equipment master
where master.branch_id = 'cf300000-0000-4000-8000-000000000001'
  and master.name = 'Walk-in Freezer';

insert into public.cold_storage_readings(
  id, submission_id, equipment_id, slot, temperature_c, status,
  corrective_action, submitted_at
) values (
  'cf700000-0000-4000-8000-000000000001',
  'cf500000-0000-4000-8000-000000000001',
  'historical-freezer',
  '12:00',
  4,
  'pass',
  '',
  now()
);

select is(
  (select name
   from public.rename_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     (select id
      from public.branch_cold_storage_equipment
      where branch_id = 'cf300000-0000-4000-8000-000000000001'
        and name = 'Walk-in Freezer'),
     '  Main   Walk-in Freezer '
   )),
  'Main Walk-in Freezer',
  'assigned Supervisor renames equipment with normalized name'
);

select is(
  (select updated_by
   from public.branch_cold_storage_equipment
   where name = 'Main Walk-in Freezer'),
  'cf100000-0000-4000-8000-000000000001'::uuid,
  'rename records the verified actor as updater'
);

select is(
  (select equipment_name
   from public.cold_storage_equipment
   where id = 'cf600000-0000-4000-8000-000000000001'),
  'Walk-in Freezer',
  'rename leaves historical submission snapshot name unchanged'
);

select throws_ok($$
  select *
  from public.rename_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    (select id
     from public.branch_cold_storage_equipment
     where branch_id = 'cf300000-0000-4000-8000-000000000001'
       and name = 'Reach-in Refrigerator'),
    'main walk-in freezer'
  )
$$, '23505', null, 'rename rejects duplicate normalized active name');

select throws_ok($$
  select *
  from public.rename_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    (select id
     from public.branch_cold_storage_equipment
     where branch_id = 'cf300000-0000-4000-8000-000000000001'
       and name = 'Retired Freezer'),
    'Renamed Retired Freezer'
  )
$$, '42501', 'cold storage equipment access denied', 'rename rejects inactive equipment rows');

select is(
  (select equipment_code || '|' || name || '|' || equipment_type
   from public.update_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     (select id
      from public.branch_cold_storage_equipment
      where branch_id = 'cf300000-0000-4000-8000-000000000001'
        and name = 'Main Walk-in Freezer'),
     'CH1',
     'Prep Refrigerator',
     'refrigerator'
   )),
  'CH1|Prep Refrigerator|refrigerator',
  'assigned Supervisor updates equipment code, name, and type'
);

select is(
  (select name || '|' || equipment_type
   from public.list_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000004',
     'cf300000-0000-4000-8000-000000000001'
   )
   where name = 'Prep Refrigerator'),
  'Prep Refrigerator|refrigerator',
  'same-branch Supervisor sees the updated equipment master'
);

select is(
  (select equipment_type
   from public.cold_storage_equipment
   where id = 'cf600000-0000-4000-8000-000000000001'),
  'freezer',
  'type change leaves historical submission snapshot type unchanged'
);

select throws_ok($$
  select *
  from public.update_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    (select id
     from public.branch_cold_storage_equipment
     where branch_id = 'cf300000-0000-4000-8000-000000000001'
       and name = 'Reach-in Refrigerator'),
    'C2',
    'prep refrigerator',
    'freezer'
  )
$$, '23505', null, 'update rejects duplicate active name');

select throws_ok($$
  select *
  from public.update_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    (select id
     from public.branch_cold_storage_equipment
     where branch_id = 'cf300000-0000-4000-8000-000000000001'
       and name = 'Reach-in Refrigerator'),
    'CH-01',
    'Distinct Name',
    'freezer'
  )
$$, '23505', 'equipment code already exists', 'update rejects duplicate active code');

select is(
  (select active
   from public.archive_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     (select id
      from public.branch_cold_storage_equipment
      where branch_id = 'cf300000-0000-4000-8000-000000000001'
        and name = 'Prep Refrigerator')
   )),
  false,
  'remove archives equipment with active=false'
);

select is(
  (select count(*)
   from public.list_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000004',
     'cf300000-0000-4000-8000-000000000001'
   )
   where name = 'Prep Refrigerator'),
  0::bigint,
  'same-branch Supervisor no longer sees archived equipment in active roster'
);

select is(
  (select count(*)
   from public.cold_storage_readings reading
   join public.cold_storage_equipment snapshot
     on snapshot.submission_id = reading.submission_id
    and snapshot.equipment_id = reading.equipment_id
   where reading.id = 'cf700000-0000-4000-8000-000000000001'
     and reading.submitted_at is not null
     and snapshot.equipment_name = 'Walk-in Freezer'
     and snapshot.equipment_type = 'freezer'),
  1::bigint,
  'archive leaves historical submitted readings queryable'
);

select is(
  (select state
   from public.cold_storage_submissions
   where id = 'cf500000-0000-4000-8000-000000000001'),
  'submitted',
  'submitted slot remains submitted after equipment archive'
);

select is(
  (select count(*)
   from public.cold_storage_equipment snapshot
   left join public.branch_cold_storage_equipment master
     on master.id = snapshot.master_equipment_id
    and master.branch_id = snapshot.branch_id
    and master.organization_id = snapshot.organization_id
   where snapshot.master_equipment_id is not null
     and master.id is null),
  0::bigint,
  'archiving equipment creates no orphaned snapshot rows'
);

select throws_ok($$
  select *
  from public.archive_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000002',
    (select id
     from public.branch_cold_storage_equipment
     where branch_id = 'cf300000-0000-4000-8000-000000000001'
     limit 1)
  )
$$, '42501', 'cold storage equipment access denied', 'Supervisor cannot archive another branch equipment row');

select is(
  (select count(*)
   from public.list_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000002',
     'cf300000-0000-4000-8000-000000000002'
   )),
  2::bigint,
  'other branch active roster is unaffected by branch equipment archive'
);

select throws_ok($$
  select *
  from public.list_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000002'
  )
$$, '42501', 'cold storage equipment access denied', 'Supervisor cannot list another branch master');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000003',
    'X1',
    'Cross Organization Unit',
    'freezer'
  )
$$, '42501', 'cold storage equipment access denied', 'Supervisor cannot create equipment across organizations');

select throws_ok($$
  select *
  from public.rename_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    (select id
     from public.branch_cold_storage_equipment
     where branch_id = 'cf300000-0000-4000-8000-000000000002'
     limit 1),
    'Unauthorized Rename'
  )
$$, '42501', 'cold storage equipment access denied', 'Supervisor cannot rename another branch equipment row');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000003',
    'cf300000-0000-4000-8000-000000000001',
    'M1',
    'Manager Unit',
    'refrigerator'
  )
$$, '42501', 'cold storage equipment access denied', 'Organization Manager cannot mutate Supervisor equipment master');

select * from finish();
rollback;
