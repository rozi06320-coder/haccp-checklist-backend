begin;
select plan(42);

select is(
  (select pg_catalog.string_agg(attribute.attname,',' order by key_column.ordinality)
   from pg_catalog.pg_constraint constraint_row
   cross join lateral pg_catalog.unnest(constraint_row.conkey) with ordinality key_column(attnum,ordinality)
   join pg_catalog.pg_attribute attribute
     on attribute.attrelid=constraint_row.conrelid and attribute.attnum=key_column.attnum
   where constraint_row.conname='operational_staff_scheduled_moves_staff_fkey'
     and constraint_row.conrelid='public.operational_staff_scheduled_team_moves'::regclass),
  'operational_staff_id,organization_id',
  'historical move staff FK no longer includes mutable branch_id'
);
select is(
  (select pg_catalog.string_agg(attribute.attname,',' order by key_column.ordinality)
   from pg_catalog.pg_constraint constraint_row
   cross join lateral pg_catalog.unnest(constraint_row.confkey) with ordinality key_column(attnum,ordinality)
   join pg_catalog.pg_attribute attribute
     on attribute.attrelid=constraint_row.confrelid and attribute.attnum=key_column.attnum
   where constraint_row.conname='operational_staff_scheduled_moves_staff_fkey'
     and constraint_row.conrelid='public.operational_staff_scheduled_team_moves'::regclass),
  'id,organization_id',
  'historical move staff FK retains organization-scoped staff identity'
);
select is(
  (select constraint_row.confdeltype::text
   from pg_catalog.pg_constraint constraint_row
   where constraint_row.conname='operational_staff_scheduled_moves_staff_fkey'
     and constraint_row.conrelid='public.operational_staff_scheduled_team_moves'::regclass),
  'r',
  'historical move staff FK keeps ON DELETE RESTRICT'
);
select is(
  (select pg_catalog.string_agg(attribute.attname,',' order by key_column.ordinality)
   from pg_catalog.pg_constraint constraint_row
   cross join lateral pg_catalog.unnest(constraint_row.conkey) with ordinality key_column(attnum,ordinality)
   join pg_catalog.pg_attribute attribute
     on attribute.attrelid=constraint_row.conrelid and attribute.attnum=key_column.attnum
   where constraint_row.conname='operational_staff_id_organization_key'
     and constraint_row.contype='u'
     and constraint_row.conrelid='public.operational_staff'::regclass),
  'id,organization_id',
  'staff identity has the required organization-scoped unique key'
);
select is(
  (select pg_catalog.string_agg(attribute.attname,',' order by key_column.ordinality)
   from pg_catalog.pg_constraint constraint_row
   cross join lateral pg_catalog.unnest(constraint_row.conkey) with ordinality key_column(attnum,ordinality)
   join pg_catalog.pg_attribute attribute
     on attribute.attrelid=constraint_row.conrelid and attribute.attnum=key_column.attnum
   where constraint_row.conname='operational_staff_scheduled_moves_source_assignment_fkey'),
  'source_assignment_id,operational_staff_id,branch_id,organization_id',
  'source assignment history remains branch scoped'
);
select is(
  (select pg_catalog.string_agg(attribute.attname,',' order by key_column.ordinality)
   from pg_catalog.pg_constraint constraint_row
   cross join lateral pg_catalog.unnest(constraint_row.conkey) with ordinality key_column(attnum,ordinality)
   join pg_catalog.pg_attribute attribute
     on attribute.attrelid=constraint_row.conrelid and attribute.attnum=key_column.attnum
   where constraint_row.conname='operational_staff_scheduled_moves_branch_fkey'),
  'branch_id,organization_id',
  'historical move branch remains organization scoped'
);
select is(
  (select pg_catalog.string_agg(attribute.attname,',' order by key_column.ordinality)
   from pg_catalog.pg_constraint constraint_row
   cross join lateral pg_catalog.unnest(constraint_row.conkey) with ordinality key_column(attnum,ordinality)
   join pg_catalog.pg_attribute attribute
     on attribute.attrelid=constraint_row.conrelid and attribute.attnum=key_column.attnum
   where constraint_row.conname='operational_staff_scheduled_moves_source_team_fkey'),
  'source_operational_team_id,branch_id,organization_id',
  'source team history remains branch scoped'
);
select is(
  (select pg_catalog.string_agg(attribute.attname,',' order by key_column.ordinality)
   from pg_catalog.pg_constraint constraint_row
   cross join lateral pg_catalog.unnest(constraint_row.conkey) with ordinality key_column(attnum,ordinality)
   join pg_catalog.pg_attribute attribute
     on attribute.attrelid=constraint_row.conrelid and attribute.attnum=key_column.attnum
   where constraint_row.conname='operational_staff_scheduled_moves_destination_team_fkey'),
  'destination_operational_team_id,branch_id,organization_id',
  'destination team history remains branch scoped'
);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@example.invalid','{}','{}',now(),now()
from pg_catalog.unnest(array[
  '1cf00000-0000-4000-8000-000000000001'::uuid,
  '1cf00000-0000-4000-8000-000000000002',
  '1cf00000-0000-4000-8000-000000000003',
  '1cf00000-0000-4000-8000-000000000004'
]) id;
update public.profiles set must_change_password=false
where id between '1cf00000-0000-4000-8000-000000000001' and '1cf00000-0000-4000-8000-000000000004';

insert into public.organizations(id,name,slug) values
  ('2cf00000-0000-4000-8000-000000000001','Historical Move Transfer Org','historical-move-transfer-org'),
  ('2cf00000-0000-4000-8000-000000000002','Foreign Historical Move Org','foreign-historical-move-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3cf00000-0000-4000-8000-000000000001','2cf00000-0000-4000-8000-000000000001','Branch A','HMA','Asia/Riyadh'),
  ('3cf00000-0000-4000-8000-000000000002','2cf00000-0000-4000-8000-000000000001','Branch B','HMB','Asia/Riyadh'),
  ('3cf00000-0000-4000-8000-000000000003','2cf00000-0000-4000-8000-000000000002','Foreign Branch','HMF','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('3cf00000-0000-4000-8000-000000000001','1cf00000-0000-4000-8000-000000000001','branch_manager'),
  ('3cf00000-0000-4000-8000-000000000001','1cf00000-0000-4000-8000-000000000002','branch_manager'),
  ('3cf00000-0000-4000-8000-000000000002','1cf00000-0000-4000-8000-000000000003','branch_manager'),
  ('3cf00000-0000-4000-8000-000000000003','1cf00000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4cf00000-0000-4000-8000-000000000001','2cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001','1cf00000-0000-4000-8000-000000000001'),
  ('4cf00000-0000-4000-8000-000000000002','2cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001','1cf00000-0000-4000-8000-000000000002'),
  ('4cf00000-0000-4000-8000-000000000003','2cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000002','1cf00000-0000-4000-8000-000000000003'),
  ('4cf00000-0000-4000-8000-000000000004','2cf00000-0000-4000-8000-000000000002','3cf00000-0000-4000-8000-000000000003','1cf00000-0000-4000-8000-000000000004');

select pg_catalog.set_config('test.source_team',(select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='4cf00000-0000-4000-8000-000000000001'),false);
select pg_catalog.set_config('test.alternate_team',(select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='4cf00000-0000-4000-8000-000000000002'),false);
select pg_catalog.set_config('test.destination_team',(select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='4cf00000-0000-4000-8000-000000000003'),false);
select pg_catalog.set_config('test.foreign_team',(select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='4cf00000-0000-4000-8000-000000000004'),false);

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff(
  '1cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
  current_setting('test.source_team')::uuid,'Transfer Candidate',array['kitchen'],null,
  'Historical Move Transfer Org',null,null,null,null,null)$$,'incident staff is created in Branch A');
select lives_ok($$select * from public.create_operational_team_staff(
  '1cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
  current_setting('test.source_team')::uuid,'Scope Peer',array['kitchen'],null,
  'Historical Move Transfer Org',null,null,null,null,null)$$,'scope peer is created in Branch A');
select lives_ok($$select * from public.create_operational_team_staff(
  '1cf00000-0000-4000-8000-000000000004','3cf00000-0000-4000-8000-000000000003',
  current_setting('test.foreign_team')::uuid,'Foreign Staff',array['kitchen'],null,
  'Foreign Historical Move Org',null,null,null,null,null)$$,'foreign organization staff is created');
reset role;

select pg_catalog.set_config('test.staff',(select id::text from public.operational_staff
  where display_name='Transfer Candidate'),false);
select pg_catalog.set_config('test.assignment',(select id::text from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.staff')::uuid and active),false);
select pg_catalog.set_config('test.peer_staff',(select id::text from public.operational_staff
  where display_name='Scope Peer'),false);
select pg_catalog.set_config('test.peer_assignment',(select id::text from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.peer_staff')::uuid and active),false);
select pg_catalog.set_config('test.foreign_staff',(select id::text from public.operational_staff
  where display_name='Foreign Staff'),false);

set local role service_role;
select lives_ok($$select * from public.upsert_operational_staff_health_card(
  '1cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
  jsonb_build_object('operational_staff_id',current_setting('test.staff'),'status','passed',
    'certificate_number','HC-HISTORICAL-MOVE'))$$,'Health Card is saved before movement');
select lives_ok($$select * from public.save_operational_staff_monthly_evaluation(
  '1cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
  current_setting('test.staff')::uuid,date_trunc('month',current_date)::date,'Source Supervisor',
  jsonb_build_array(jsonb_build_object('section','Performance','factor_key','performance',
    'factor_label','Performance','rating',5,'comment','Good')),'completed')$$,
  'evaluation is saved before movement');
select lives_ok($$select * from public.submit_operational_team_hygiene(
  '1cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
  current_setting('test.source_team')::uuid,'7cf00000-0000-4000-8000-000000000001',repeat('f',64),
  jsonb_build_array(
    jsonb_build_object('staff_id',current_setting('test.staff'),'uniform','pass','fingernails','pass',
      'hair','pass','facial_hair','pass','remark',''),
    jsonb_build_object('staff_id',current_setting('test.peer_staff'),'uniform','pass','fingernails','pass',
      'hair','pass','facial_hair','pass','remark','')))$$,'source Hygiene is submitted');
select lives_ok($$select * from public.request_operational_staff_team_move(
  '1cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
  current_setting('test.staff')::uuid,current_setting('test.assignment')::uuid,
  current_setting('test.alternate_team')::uuid)$$,'same-branch scheduling still succeeds');
reset role;

select pg_catalog.set_config('test.historical_move',(select id::text
  from public.operational_staff_scheduled_team_moves
  where operational_staff_id=current_setting('test.staff')::uuid and status='pending'),false);
select is((select status from public.operational_staff_scheduled_team_moves
  where id=current_setting('test.historical_move')::uuid),'pending','same-branch move is initially pending');
set local role service_role;
select lives_ok($$select * from public.cancel_operational_staff_scheduled_team_move(
  '1cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
  current_setting('test.staff')::uuid,current_setting('test.historical_move')::uuid,
  current_setting('test.assignment')::uuid)$$,'same-branch scheduled move can be cancelled');
reset role;
select is((select status from public.operational_staff_scheduled_team_moves
  where id=current_setting('test.historical_move')::uuid),'cancelled','same-branch lifecycle remains unchanged');
select is((select branch_id from public.operational_staff_scheduled_team_moves
  where id=current_setting('test.historical_move')::uuid),
  '3cf00000-0000-4000-8000-000000000001'::uuid,'historical move records Branch A');

select throws_ok($$
  insert into public.operational_staff_scheduled_team_moves(
    organization_id,branch_id,operational_staff_id,source_assignment_id,source_operational_team_id,
    destination_operational_team_id,requested_by_user_id,requested_business_date,effective_business_date,
    status,cancelled_at,cancelled_by_user_id)
  values('2cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
    current_setting('test.foreign_staff')::uuid,current_setting('test.assignment')::uuid,
    current_setting('test.source_team')::uuid,current_setting('test.alternate_team')::uuid,
    '1cf00000-0000-4000-8000-000000000001',current_date,current_date+1,'cancelled',now(),
    '1cf00000-0000-4000-8000-000000000001')
$$,'23503',null,'cross-organization staff reference is rejected');
select throws_ok($$
  insert into public.operational_staff_scheduled_team_moves(
    organization_id,branch_id,operational_staff_id,source_assignment_id,source_operational_team_id,
    destination_operational_team_id,requested_by_user_id,requested_business_date,effective_business_date,
    status,cancelled_at,cancelled_by_user_id)
  values('2cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
    '9cf00000-0000-4000-8000-000000000001',current_setting('test.assignment')::uuid,
    current_setting('test.source_team')::uuid,current_setting('test.alternate_team')::uuid,
    '1cf00000-0000-4000-8000-000000000001',current_date,current_date+1,'cancelled',now(),
    '1cf00000-0000-4000-8000-000000000001')
$$,'23503',null,'nonexistent staff reference is rejected');
select throws_ok($$
  insert into public.operational_staff_scheduled_team_moves(
    organization_id,branch_id,operational_staff_id,source_assignment_id,source_operational_team_id,
    destination_operational_team_id,requested_by_user_id,requested_business_date,effective_business_date,
    status,cancelled_at,cancelled_by_user_id)
  values('2cf00000-0000-4000-8000-000000000001','3cf00000-0000-4000-8000-000000000001',
    current_setting('test.staff')::uuid,current_setting('test.peer_assignment')::uuid,
    current_setting('test.source_team')::uuid,current_setting('test.alternate_team')::uuid,
    '1cf00000-0000-4000-8000-000000000001',current_date,current_date+1,'cancelled',now(),
    '1cf00000-0000-4000-8000-000000000001')
$$,'23503',null,'source assignment scope remains protected');
select throws_ok($$update public.operational_staff_scheduled_team_moves
  set operational_staff_id=current_setting('test.foreign_staff')::uuid
  where id=current_setting('test.historical_move')::uuid$$,
  '23503',null,'historical rows cannot be reassigned to staff from another organization');

set local role service_role;
select lives_ok($$select * from public.request_operational_staff_branch_transfer(
  '1cf00000-0000-4000-8000-000000000001','2cf00000-0000-4000-8000-000000000001',
  '3cf00000-0000-4000-8000-000000000001',current_setting('test.staff')::uuid,
  current_setting('test.assignment')::uuid,'3cf00000-0000-4000-8000-000000000002',
  current_setting('test.destination_team')::uuid,true)$$,'cross-branch transfer is scheduled');
reset role;
select pg_catalog.set_config('test.transfer',(select id::text
  from public.operational_staff_scheduled_branch_transfers
  where operational_staff_id=current_setting('test.staff')::uuid and status='pending'),false);
select is((select status from public.operational_staff_scheduled_branch_transfers
  where id=current_setting('test.transfer')::uuid),'pending','cross-branch transfer is pending');

update public.operational_staff_scheduled_branch_transfers
set effective_at=pg_catalog.statement_timestamp()-interval '1 minute'
where id=current_setting('test.transfer')::uuid;
set local role service_role;
select lives_ok($$select * from public.apply_due_operational_staff_branch_transfers(
  '3cf00000-0000-4000-8000-000000000001','2cf00000-0000-4000-8000-000000000001')$$,
  'due cross-branch transfer applies without a historical move FK violation');
reset role;

select is((select branch_id from public.operational_staff where id=current_setting('test.staff')::uuid),
  '3cf00000-0000-4000-8000-000000000002'::uuid,'staff current branch becomes Branch B');
select is((select count(*) from public.operational_staff_scheduled_team_moves
  where id=current_setting('test.historical_move')::uuid),1::bigint,'historical same-branch row still exists');
select is((select branch_id from public.operational_staff_scheduled_team_moves
  where id=current_setting('test.historical_move')::uuid),
  '3cf00000-0000-4000-8000-000000000001'::uuid,'historical same-branch row keeps Branch A');
select is((select status from public.operational_staff_scheduled_team_moves
  where id=current_setting('test.historical_move')::uuid),'cancelled','historical lifecycle state is unchanged');
select is((select active from public.operational_staff_assignments
  where id=current_setting('test.assignment')::uuid),false,'source assignment is closed');
select is((select closure_reason from public.operational_staff_assignments
  where id=current_setting('test.assignment')::uuid),'branch_transfer','source assignment records branch transfer closure');
select is((select branch_id from public.operational_staff_assignments
  where id=current_setting('test.assignment')::uuid),
  '3cf00000-0000-4000-8000-000000000001'::uuid,'source assignment history keeps Branch A');
select is((select count(*) from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.staff')::uuid and active),1::bigint,
  'exactly one active destination assignment exists');
select is((select branch_id from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.staff')::uuid and active),
  '3cf00000-0000-4000-8000-000000000002'::uuid,'destination assignment is in Branch B');
select is((select operational_team_id from public.operational_staff_assignments
  where operational_staff_id=current_setting('test.staff')::uuid and active),
  current_setting('test.destination_team')::uuid,'destination assignment uses the requested team');
select is((select status from public.operational_staff_scheduled_branch_transfers
  where id=current_setting('test.transfer')::uuid),'applied','scheduled transfer becomes applied');
select is((select applied_assignment_id from public.operational_staff_scheduled_branch_transfers
  where id=current_setting('test.transfer')::uuid),
  (select id from public.operational_staff_assignments
   where operational_staff_id=current_setting('test.staff')::uuid and active),
  'transfer links to the destination assignment');
select is((select count(*) from public.hygiene_staff_snapshots
  where operational_staff_id=current_setting('test.staff')::uuid),1::bigint,
  'Staff Hygiene history remains unchanged');
select is((select certificate_number from public.operational_staff_health_cards
  where operational_staff_id=current_setting('test.staff')::uuid),'HC-HISTORICAL-MOVE',
  'Health Card history remains unchanged');
select is((select count(*) from public.operational_staff_monthly_evaluations
  where operational_staff_id=current_setting('test.staff')::uuid
    and evaluation_month=date_trunc('month',current_date)::date),1::bigint,
  'evaluation history remains unchanged');
select is((select organization_id from public.operational_staff where id=current_setting('test.staff')::uuid),
  '2cf00000-0000-4000-8000-000000000001'::uuid,'staff organization identity remains unchanged');

select * from finish();
rollback;
