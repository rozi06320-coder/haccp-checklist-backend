begin;
select plan(19);

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
  'cf100000-0000-4000-8000-000000000003'::uuid
]) user_id;

update public.profiles
set full_name = case id
  when 'cf100000-0000-4000-8000-000000000001' then 'Equipment Supervisor'
  when 'cf100000-0000-4000-8000-000000000002' then 'Other Supervisor'
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
  ('cf300000-0000-4000-8000-000000000002', 'cf100000-0000-4000-8000-000000000002', 'branch_manager');

insert into public.organization_memberships(organization_id, user_id, role) values
  ('cf200000-0000-4000-8000-000000000001', 'cf100000-0000-4000-8000-000000000003', 'organization_manager');

insert into public.branch_supervisor_teams(
  id, organization_id, branch_id, supervisor_user_id
) values
  ('cf400000-0000-4000-8000-000000000001', 'cf200000-0000-4000-8000-000000000001', 'cf300000-0000-4000-8000-000000000001', 'cf100000-0000-4000-8000-000000000001'),
  ('cf400000-0000-4000-8000-000000000002', 'cf200000-0000-4000-8000-000000000001', 'cf300000-0000-4000-8000-000000000002', 'cf100000-0000-4000-8000-000000000002');

select ok(
  has_function_privilege(
    'service_role',
    'public.list_supervisor_cold_storage_equipment(uuid,uuid)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'public.create_supervisor_cold_storage_equipment(uuid,uuid,text,text)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'public.rename_supervisor_cold_storage_equipment(uuid,uuid,uuid,text)',
    'execute'
  ),
  'service role can execute the three master equipment RPCs'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.list_supervisor_cold_storage_equipment(uuid,uuid)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.create_supervisor_cold_storage_equipment(uuid,uuid,text,text)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.rename_supervisor_cold_storage_equipment(uuid,uuid,uuid,text)',
    'execute'
  ),
  'authenticated cannot execute master equipment RPCs directly'
);

select is(
  (select name
   from public.create_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     E'  Walk-in\t  Freezer  ',
     'freezer'
   )),
  'Walk-in Freezer',
  'assigned Supervisor creates equipment with trimmed and collapsed name'
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
    'Warmer',
    'warmer'
  )
$$, '22023', 'invalid cold storage equipment type', 'create rejects invalid equipment type');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    '   ',
    'freezer'
  )
$$, '22023', 'invalid cold storage equipment name', 'create rejects blank equipment name');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    repeat('x', 121),
    'freezer'
  )
$$, '22023', 'invalid cold storage equipment name', 'create rejects overlong equipment name');

select throws_ok($$
  select *
  from public.create_supervisor_cold_storage_equipment(
    'cf100000-0000-4000-8000-000000000001',
    'cf300000-0000-4000-8000-000000000001',
    'walk-in freezer',
    'freezer'
  )
$$, '23505', null, 'create rejects duplicate normalized active name');

select is(
  (select name
   from public.create_supervisor_cold_storage_equipment(
     'cf100000-0000-4000-8000-000000000001',
     'cf300000-0000-4000-8000-000000000001',
     'Reach-in Refrigerator',
     'refrigerator'
   )),
  'Reach-in Refrigerator',
  'assigned Supervisor can create a second distinct equipment row'
);

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
    'Manager Unit',
    'refrigerator'
  )
$$, '42501', 'cold storage equipment access denied', 'Organization Manager cannot mutate Supervisor equipment master');

select * from finish();
rollback;
