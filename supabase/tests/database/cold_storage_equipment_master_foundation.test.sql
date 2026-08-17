begin;
select plan(26);

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
  'ce100000-0000-4000-8000-000000000002'::uuid
]) user_id;

update public.profiles
set full_name = case id
  when 'ce100000-0000-4000-8000-000000000001' then 'Equipment Supervisor One'
  else 'Equipment Supervisor Two'
end,
must_change_password = false
where id in (
  'ce100000-0000-4000-8000-000000000001',
  'ce100000-0000-4000-8000-000000000002'
);

insert into public.organizations(id, name, slug) values
  ('ce200000-0000-4000-8000-000000000001', 'Equipment Org One', 'equipment-org-one'),
  ('ce200000-0000-4000-8000-000000000002', 'Equipment Org Two', 'equipment-org-two');

insert into public.branches(id, organization_id, name, code, timezone) values
  ('ce300000-0000-4000-8000-000000000001', 'ce200000-0000-4000-8000-000000000001', 'Backfill Branch', 'EQ-A', 'Asia/Riyadh'),
  ('ce300000-0000-4000-8000-000000000002', 'ce200000-0000-4000-8000-000000000001', 'Ambiguous Branch', 'EQ-B', 'Asia/Riyadh'),
  ('ce300000-0000-4000-8000-000000000003', 'ce200000-0000-4000-8000-000000000001', 'Constraint Branch', 'EQ-C', 'Asia/Riyadh'),
  ('ce300000-0000-4000-8000-000000000004', 'ce200000-0000-4000-8000-000000000001', 'Second Branch', 'EQ-D', 'Asia/Riyadh'),
  ('ce300000-0000-4000-8000-000000000005', 'ce200000-0000-4000-8000-000000000002', 'Other Org Branch', 'EQ-X', 'Asia/Riyadh');

insert into public.branch_memberships(branch_id, user_id, role)
select branch.id,
  case branch.organization_id
    when 'ce200000-0000-4000-8000-000000000001' then 'ce100000-0000-4000-8000-000000000001'::uuid
    else 'ce100000-0000-4000-8000-000000000002'::uuid
  end,
  'branch_manager'
from public.branches branch
where branch.id::text like 'ce300000-%';

insert into public.branch_supervisor_teams(
  id, organization_id, branch_id, supervisor_user_id
) values
  ('ce400000-0000-4000-8000-000000000001', 'ce200000-0000-4000-8000-000000000001', 'ce300000-0000-4000-8000-000000000001', 'ce100000-0000-4000-8000-000000000001'),
  ('ce400000-0000-4000-8000-000000000002', 'ce200000-0000-4000-8000-000000000001', 'ce300000-0000-4000-8000-000000000002', 'ce100000-0000-4000-8000-000000000001');

insert into public.cold_storage_submissions(
  id, organization_id, branch_id, supervisor_user_id, supervisor_team_id,
  business_date, state, branch_name_snapshot, supervisor_name_snapshot,
  team_name_snapshot, updated_at
) values
  (
    'ce500000-0000-4000-8000-000000000001',
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    'ce100000-0000-4000-8000-000000000001',
    'ce400000-0000-4000-8000-000000000001',
    '2026-07-01', 'submitted', 'Backfill Branch', 'Equipment Supervisor One',
    'Equipment Supervisor One Team', '2026-07-01 12:00:00+00'
  ),
  (
    'ce500000-0000-4000-8000-000000000002',
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000001',
    'ce100000-0000-4000-8000-000000000001',
    'ce400000-0000-4000-8000-000000000001',
    '2026-08-01', 'draft', 'Backfill Branch', 'Equipment Supervisor One',
    'Equipment Supervisor One Team', '2026-08-01 12:00:00+00'
  ),
  (
    'ce500000-0000-4000-8000-000000000003',
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000002',
    'ce100000-0000-4000-8000-000000000001',
    'ce400000-0000-4000-8000-000000000002',
    '2026-08-02', 'draft', 'Ambiguous Branch', 'Equipment Supervisor One',
    'Equipment Supervisor One Team', '2026-08-02 12:00:00+00'
  );

insert into public.cold_storage_equipment(
  id, submission_id, equipment_id, equipment_name, equipment_type, active
) values
  ('ce600000-0000-4000-8000-000000000001', 'ce500000-0000-4000-8000-000000000001', 'legacy-unit', 'Historical Refrigerator', 'refrigerator', true),
  ('ce600000-0000-4000-8000-000000000002', 'ce500000-0000-4000-8000-000000000002', 'latest-fridge', 'Walk-in Refrigerator', 'refrigerator', true),
  ('ce600000-0000-4000-8000-000000000003', 'ce500000-0000-4000-8000-000000000002', 'latest-freezer', 'Walk-in Freezer', 'freezer', true),
  ('ce600000-0000-4000-8000-000000000004', 'ce500000-0000-4000-8000-000000000003', 'duplicate-one', 'Duplicate Unit', 'refrigerator', true),
  ('ce600000-0000-4000-8000-000000000005', 'ce500000-0000-4000-8000-000000000003', 'duplicate-two', 'duplicate unit', 'freezer', true);

select has_table(
  'public',
  'branch_cold_storage_equipment',
  'branch Cold Storage equipment master table exists'
);
select col_is_pk(
  'public',
  'branch_cold_storage_equipment',
  'id',
  'master equipment uses a UUID primary key'
);
select has_column(
  'public',
  'cold_storage_equipment',
  'master_equipment_id',
  'snapshot table has nullable master link'
);
select has_column(
  'public',
  'cold_storage_equipment',
  'organization_id',
  'snapshot table has nullable organization scope'
);
select has_column(
  'public',
  'cold_storage_equipment',
  'branch_id',
  'snapshot table has nullable branch scope'
);
select ok(
  (select relrowsecurity
   from pg_catalog.pg_class
   where oid = 'public.branch_cold_storage_equipment'::regclass),
  'master equipment table has RLS enabled'
);
select ok(
  not has_table_privilege('authenticated', 'public.branch_cold_storage_equipment', 'insert')
  and not has_table_privilege('authenticated', 'public.branch_cold_storage_equipment', 'update')
  and not has_table_privilege('authenticated', 'public.branch_cold_storage_equipment', 'delete'),
  'authenticated cannot write master equipment directly'
);
select ok(
  not has_table_privilege('service_role', 'public.branch_cold_storage_equipment', 'insert')
  and not has_table_privilege('service_role', 'public.branch_cold_storage_equipment', 'update')
  and not has_table_privilege('service_role', 'public.branch_cold_storage_equipment', 'delete'),
  'service role will require future security-definer RPCs for master writes'
);

select lives_ok($$
  insert into public.branch_cold_storage_equipment(
    id, organization_id, branch_id, name, equipment_type, created_by
  ) values (
    'ce700000-0000-4000-8000-000000000001',
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000003',
    'Prep Refrigerator',
    'refrigerator',
    'ce100000-0000-4000-8000-000000000001'
  )
$$, 'a valid branch master equipment row can be stored');

select throws_ok($$
  insert into public.branch_cold_storage_equipment(
    organization_id, branch_id, name, equipment_type, created_by
  ) values (
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000003',
    'Invalid Equipment',
    'warmer',
    'ce100000-0000-4000-8000-000000000001'
  )
$$, '23514', null, 'invalid equipment type is rejected');

select throws_ok($$
  insert into public.branch_cold_storage_equipment(
    organization_id, branch_id, name, equipment_type, created_by
  ) values (
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000003',
    '',
    'freezer',
    'ce100000-0000-4000-8000-000000000001'
  )
$$, '23514', null, 'blank equipment name is rejected');

select throws_ok($$
  insert into public.branch_cold_storage_equipment(
    organization_id, branch_id, name, equipment_type, created_by
  ) values (
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000003',
    repeat('x', 121),
    'freezer',
    'ce100000-0000-4000-8000-000000000001'
  )
$$, '23514', null, 'equipment names longer than 120 characters are rejected');

select throws_ok($$
  insert into public.branch_cold_storage_equipment(
    organization_id, branch_id, name, equipment_type, created_by
  ) values (
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000003',
    'prep refrigerator',
    'refrigerator',
    'ce100000-0000-4000-8000-000000000001'
  )
$$, '23505', null, 'active equipment names are unique per branch after case normalization');

select lives_ok($$
  insert into public.branch_cold_storage_equipment(
    id, organization_id, branch_id, name, equipment_type, created_by
  ) values (
    'ce700000-0000-4000-8000-000000000002',
    'ce200000-0000-4000-8000-000000000001',
    'ce300000-0000-4000-8000-000000000004',
    'Prep Refrigerator',
    'refrigerator',
    'ce100000-0000-4000-8000-000000000001'
  )
$$, 'the same active name is allowed in another branch');

select lives_ok($$
  insert into public.branch_cold_storage_equipment(
    organization_id, branch_id, name, equipment_type, active, created_by
  ) values
    (
      'ce200000-0000-4000-8000-000000000001',
      'ce300000-0000-4000-8000-000000000003',
      'Prep Refrigerator',
      'refrigerator',
      false,
      'ce100000-0000-4000-8000-000000000001'
    ),
    (
      'ce200000-0000-4000-8000-000000000001',
      'ce300000-0000-4000-8000-000000000003',
      'prep refrigerator',
      'freezer',
      false,
      'ce100000-0000-4000-8000-000000000001'
    )
$$, 'inactive duplicate names are retained without blocking the one active name');

insert into public.branch_cold_storage_equipment(
  id, organization_id, branch_id, name, equipment_type, created_by
) values (
  'ce700000-0000-4000-8000-000000000003',
  'ce200000-0000-4000-8000-000000000002',
  'ce300000-0000-4000-8000-000000000005',
  'Other Organization Freezer',
  'freezer',
  'ce100000-0000-4000-8000-000000000002'
);

select private.backfill_branch_cold_storage_equipment_master();

select is(
  (select count(*)
   from public.branch_cold_storage_equipment master
   where master.branch_id = 'ce300000-0000-4000-8000-000000000001'),
  2::bigint,
  'unambiguous latest roster creates one master row per snapshot equipment'
);
select is(
  (select count(*)
   from public.cold_storage_equipment equipment
   where equipment.submission_id = 'ce500000-0000-4000-8000-000000000002'
     and equipment.master_equipment_id is not null
     and equipment.organization_id = 'ce200000-0000-4000-8000-000000000001'
     and equipment.branch_id = 'ce300000-0000-4000-8000-000000000001'),
  2::bigint,
  'only latest source snapshots are linked with their branch scope'
);
select is(
  (select string_agg(master.name, ',' order by master.name)
   from public.branch_cold_storage_equipment master
   where master.branch_id = 'ce300000-0000-4000-8000-000000000001'),
  'Walk-in Freezer,Walk-in Refrigerator',
  'backfill preserves the latest equipment names without renaming'
);
select is(
  (select equipment.equipment_name
   from public.cold_storage_equipment equipment
   where equipment.id = 'ce600000-0000-4000-8000-000000000001'
     and equipment.master_equipment_id is null
     and equipment.organization_id is null
     and equipment.branch_id is null),
  'Historical Refrigerator',
  'older legacy snapshot remains readable and unlinked'
);
select is(
  (select count(*)
   from public.branch_cold_storage_equipment master
   where master.branch_id = 'ce300000-0000-4000-8000-000000000002'),
  0::bigint,
  'ambiguous latest active roster skips the complete branch master backfill'
);
select is(
  (select count(*)
   from public.cold_storage_equipment equipment
   where equipment.submission_id = 'ce500000-0000-4000-8000-000000000003'
     and equipment.master_equipment_id is not null),
  0::bigint,
  'ambiguous latest roster snapshots remain unlinked'
);

select throws_ok($$
  update public.cold_storage_equipment equipment
  set master_equipment_id = 'ce700000-0000-4000-8000-000000000002'
  where equipment.id = 'ce600000-0000-4000-8000-000000000002'
$$, '23503', null, 'snapshot master linkage cannot cross branches');

select throws_ok($$
  update public.cold_storage_equipment equipment
  set master_equipment_id = 'ce700000-0000-4000-8000-000000000003',
    organization_id = 'ce200000-0000-4000-8000-000000000002',
    branch_id = 'ce300000-0000-4000-8000-000000000005'
  where equipment.id = 'ce600000-0000-4000-8000-000000000002'
$$, '23503', null, 'snapshot scope cannot differ from its submission organization and branch');

select lives_ok($$
  select private.backfill_branch_cold_storage_equipment_master()
$$, 'backfill helper can be rerun safely');
select is(
  (select count(*)
   from public.branch_cold_storage_equipment master
   where master.branch_id = 'ce300000-0000-4000-8000-000000000001'),
  2::bigint,
  'backfill rerun does not duplicate an established branch master'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.backfill_branch_cold_storage_equipment_master()',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'private.backfill_branch_cold_storage_equipment_master()',
    'execute'
  ),
  'migration backfill helper is not callable by application roles'
);

select * from finish();
rollback;
