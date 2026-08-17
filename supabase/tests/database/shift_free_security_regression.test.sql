begin;
select plan(71);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
 id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '16000000-0000-4000-8000-000000000001'::uuid,
 '16000000-0000-4000-8000-000000000002',
 '16000000-0000-4000-8000-000000000003',
 '16000000-0000-4000-8000-000000000004',
 '16000000-0000-4000-8000-000000000005',
 '16000000-0000-4000-8000-000000000006',
 '16000000-0000-4000-8000-000000000007',
 '16000000-0000-4000-8000-000000000008',
 '16000000-0000-4000-8000-000000000009'
]) id;
update public.profiles set full_name='Regression '||right(id::text,1),must_change_password=false
 where id::text like '16000000-%';
update public.profiles set disabled_at=now()
 where id='16000000-0000-4000-8000-000000000006';
update public.profiles set must_change_password=true
 where id='16000000-0000-4000-8000-000000000007';

insert into public.organizations(id,name,slug) values
 ('26000000-0000-4000-8000-000000000001','Regression A','regression-a'),
 ('26000000-0000-4000-8000-000000000002','Regression B','regression-b');
insert into public.branches(id,organization_id,name,code,timezone,active) values
 ('36000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001','A1','RGA1','Asia/Riyadh',true),
 ('36000000-0000-4000-8000-000000000002','26000000-0000-4000-8000-000000000001','A2','RGA2','America/Los_Angeles',true),
 ('36000000-0000-4000-8000-000000000003','26000000-0000-4000-8000-000000000002','B1','RGB1','UTC',true);
insert into public.organization_memberships(organization_id,user_id,role) values
 ('26000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000001','organization_manager'),
 ('26000000-0000-4000-8000-000000000002','16000000-0000-4000-8000-000000000008','organization_manager');
insert into public.internal_admin_memberships(user_id,active)
 values('16000000-0000-4000-8000-000000000009',true);
insert into public.branch_memberships(branch_id,user_id,role) values
 ('36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000002','branch_manager'),
 ('36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000003','branch_manager'),
 ('36000000-0000-4000-8000-000000000002','16000000-0000-4000-8000-000000000003','branch_manager'),
 ('36000000-0000-4000-8000-000000000002','16000000-0000-4000-8000-000000000002','branch_manager'),
 ('36000000-0000-4000-8000-000000000003','16000000-0000-4000-8000-000000000004','branch_manager'),
 ('36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000005','staff'),
 ('36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000006','branch_manager'),
 ('36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000007','branch_manager');

select is(
 (select count(*) from information_schema.columns where table_schema='public'
  and ((table_name='organizations' and column_name='active')
   or (table_name='branch_memberships' and column_name='active'))
  and data_type='boolean' and is_nullable='NO'),2::bigint,
 'organization and membership lifecycle columns remain boolean NOT NULL');
select is(
 (select count(*) from information_schema.columns where table_schema='public'
  and ((table_name='organizations' and column_name='active')
   or (table_name='branch_memberships' and column_name='active'))
  and column_default='true'),2::bigint,
 'organization and membership lifecycle columns still default true');
select is(
 (select count(*) from pg_catalog.pg_attribute attribute
  join pg_catalog.pg_class relation on relation.oid=attribute.attrelid
  join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
  where namespace.nspname='public'
   and ((relation.relname='organizations' and attribute.attname='active')
    or (relation.relname='branch_memberships' and attribute.attname='active'))
   and attribute.atthasmissing and attribute.attmissingval::text='{t}'),2::bigint,
 'catalog retains true lifecycle backfill metadata');
select ok((select bool_and(active) from public.organizations where id::text like '26000000-%')
 and (select bool_and(active) from public.branch_memberships where user_id::text like '16000000-%'),
 'rows inserted without lifecycle fields receive true defaults');
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000001',true);
select is((select count(*) from public.organizations where id='26000000-0000-4000-8000-000000000001'),
 1::bigint,'valid Organization Manager RLS access remains');
reset role;
update public.organizations set active=false where id='26000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000001',true);
select is((select count(*) from public.organizations where id='26000000-0000-4000-8000-000000000001'),
 0::bigint,'inactive organization remains denied by RLS');
reset role;
update public.organizations set active=true where id='26000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000002',true);
select is((select count(*) from public.branches where id='36000000-0000-4000-8000-000000000001'),
 1::bigint,'valid Branch Supervisor RLS access remains');
reset role;
update public.branch_memberships set active=false where branch_id='36000000-0000-4000-8000-000000000001'
 and user_id='16000000-0000-4000-8000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000002',true);
select is((select count(*) from public.branches where id='36000000-0000-4000-8000-000000000001'),
 0::bigint,'inactive branch membership remains denied by RLS');
reset role;
update public.branch_memberships set active=true where branch_id='36000000-0000-4000-8000-000000000001'
 and user_id='16000000-0000-4000-8000-000000000002';

select col_is_null('public','branch_supervisor_teams','shift_id','team shift is nullable');
select is((select column_default::text from information_schema.columns where table_schema='public'
 and table_name='branch_supervisor_teams' and column_name='shift_id'),null::text,
 'team shift has the safe implicit NULL default');
select col_is_null('public','operational_staff_assignments','shift_id','assignment shift is nullable');
select is((select column_default::text from information_schema.columns where table_schema='public'
 and table_name='operational_staff_assignments' and column_name='shift_id'),null::text,
 'assignment shift has the safe implicit NULL default');
select has_index('public','branch_supervisor_teams','branch_supervisor_teams_active_supervisor_branch_key',
 'active Supervisor/branch unique index exists');
select ok((select indexdef like '%(supervisor_user_id, branch_id) WHERE active'
 from pg_indexes where schemaname='public'
 and indexname='branch_supervisor_teams_active_supervisor_branch_key'),
 'unique index has exact active scope');

select ok(not has_function_privilege('public',
 'public.create_managed_supervisor_team(uuid,uuid,uuid,uuid)','execute')
 and not has_function_privilege('anon',
 'public.create_managed_supervisor_team(uuid,uuid,uuid,uuid)','execute')
 and not has_function_privilege('authenticated',
 'public.create_managed_supervisor_team(uuid,uuid,uuid,uuid)','execute')
 and has_function_privilege('service_role',
 'public.create_managed_supervisor_team(uuid,uuid,uuid,uuid)','execute'),
 'current team RPC is service-role-only');
select ok(not has_function_privilege('public',
 'public.create_supervisor_operational_staff(uuid,uuid,text,text[])','execute')
 and not has_function_privilege('anon',
 'public.create_supervisor_operational_staff(uuid,uuid,text,text[])','execute')
 and not has_function_privilege('authenticated',
 'public.create_supervisor_operational_staff(uuid,uuid,text,text[])','execute')
 and has_function_privilege('service_role',
 'public.create_supervisor_operational_staff(uuid,uuid,text,text[])','execute'),
 'current staff RPC is service-role-only');
select is((select proconfig from pg_proc where oid=
 'public.create_managed_supervisor_team(uuid,uuid,uuid,uuid)'::regprocedure),
 array['search_path=""'],'team RPC has fixed empty search_path');
select is((select proconfig from pg_proc where oid=
 'public.create_supervisor_operational_staff(uuid,uuid,text,text[])'::regprocedure),
 array['search_path=""'],'staff RPC has fixed empty search_path');
select ok(not has_table_privilege('service_role','public.branch_supervisor_teams','insert')
 and not has_table_privilege('service_role','public.operational_staff_assignments','update')
 and not has_table_privilege('authenticated','public.branch_supervisor_teams','delete'),
 'no broad team or assignment table grants');
select ok(not has_function_privilege('public',
 'public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute')
 and not has_function_privilege('anon',
 'public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute')
 and not has_function_privilege('authenticated',
 'public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute')
 and has_function_privilege('service_role',
 'public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute'),
 'deprecated shift overload remains service-role-only');

select throws_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000002','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000002')$$,
 '42501','team operation denied','Supervisor cannot self-assign');
select throws_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000002',
 '36000000-0000-4000-8000-000000000003','16000000-0000-4000-8000-000000000004')$$,
 '42501','team operation denied','Organization Manager is exact-tenant scoped');
select throws_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000005')$$,
 '42501','team operation denied','legacy Staff membership is ineligible');
select throws_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000006')$$,
 '42501','team operation denied','disabled Supervisor is ineligible');
select throws_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000007')$$,
 '42501','team operation denied','forced-password Supervisor is ineligible for manual ensure');

select lives_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000002')$$,
 'manager creates first Supervisor team without shift');
select lives_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000001','16000000-0000-4000-8000-000000000003')$$,
 'different Supervisor gets separate team in same branch');
select lives_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000002','16000000-0000-4000-8000-000000000002')$$,
 'same Supervisor gets a team in another authorized branch');
select is((select count(*) from public.branch_supervisor_teams
 where organization_id='26000000-0000-4000-8000-000000000001' and active),3::bigint,
 'expected independent active team topology exists');
update public.profiles set disabled_at=null where id='16000000-0000-4000-8000-000000000006';
update public.profiles set must_change_password=false where id='16000000-0000-4000-8000-000000000007';
insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id) values
 ('26000000-0000-4000-8000-000000000001','36000000-0000-4000-8000-000000000001',
  '16000000-0000-4000-8000-000000000006'),
 ('26000000-0000-4000-8000-000000000001','36000000-0000-4000-8000-000000000001',
  '16000000-0000-4000-8000-000000000007');
update public.profiles set disabled_at=now() where id='16000000-0000-4000-8000-000000000006';
update public.profiles set must_change_password=true where id='16000000-0000-4000-8000-000000000007';
select throws_ok($$select * from public.get_supervisor_branch_timezone(
 '16000000-0000-4000-8000-000000000006','36000000-0000-4000-8000-000000000001')$$,
 '42501','branch access denied','disabled profile cannot use an existing team');
select throws_ok($$select * from public.get_supervisor_branch_timezone(
 '16000000-0000-4000-8000-000000000007','36000000-0000-4000-8000-000000000001')$$,
 '42501','branch access denied','forced-password profile cannot use an existing team');
update public.organizations set active=false where id='26000000-0000-4000-8000-000000000001';
select throws_ok($$select * from public.get_supervisor_branch_timezone(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001')$$,
 '42501','branch access denied','inactive organization denies Supervisor access');
update public.organizations set active=true where id='26000000-0000-4000-8000-000000000001';
update public.branches set active=false where id='36000000-0000-4000-8000-000000000001';
select throws_ok($$select * from public.get_supervisor_branch_timezone(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001')$$,
 '42501','branch access denied','inactive branch denies Supervisor access');
update public.branches set active=true where id='36000000-0000-4000-8000-000000000001';
update public.branch_memberships set active=false where branch_id='36000000-0000-4000-8000-000000000001'
 and user_id='16000000-0000-4000-8000-000000000002';
select throws_ok($$select * from public.get_supervisor_branch_timezone(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001')$$,
 '42501','branch access denied','inactive membership denies Supervisor access');
update public.branch_memberships set active=true where branch_id='36000000-0000-4000-8000-000000000001'
 and user_id='16000000-0000-4000-8000-000000000002';
update public.branch_supervisor_teams set active=false where branch_id='36000000-0000-4000-8000-000000000002'
 and supervisor_user_id='16000000-0000-4000-8000-000000000002';
select throws_ok($$select * from public.get_supervisor_branch_timezone(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000002')$$,
 '42501','branch access denied','inactive team denies Supervisor access');
update public.branch_supervisor_teams set active=true where branch_id='36000000-0000-4000-8000-000000000002'
 and supervisor_user_id='16000000-0000-4000-8000-000000000002';
select throws_ok($$insert into public.branch_supervisor_teams(
 organization_id,branch_id,supervisor_user_id) values(
 '26000000-0000-4000-8000-000000000001','36000000-0000-4000-8000-000000000001',
 '16000000-0000-4000-8000-000000000002')$$,'23505',null,
 'duplicate active team is rejected by database');
select is((select count(*) from public.account_management_audit_logs
 where organization_id='26000000-0000-4000-8000-000000000001'
 and action='supervisor_team_assigned'),3::bigint,'successful team assignments are audited once');
select is((select count(*) from public.account_management_audit_logs
 where action='supervisor_team_assigned' and actor_user_id='16000000-0000-4000-8000-000000000002'),
 0::bigint,'failed unauthorized team mutation leaves no audit');

select lives_ok($$select * from public.create_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 'Owner Worker',array['kitchen','cleaner'])$$,'staff create works without shift');
select throws_ok($$select * from public.create_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 'Zero',array[]::text[])$$,'42501','staff operation denied','zero roles rejected');
select throws_ok($$select * from public.create_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 'Duplicate',array['kitchen','kitchen'])$$,'42501','staff operation denied','duplicate roles rejected');
select throws_ok($$select * from public.create_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 'Three',array['kitchen','cleaner','production'])$$,'42501','staff operation denied','three roles rejected');
select throws_ok($$select * from public.create_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 'Invalid',array['owner'])$$,'42501','staff operation denied','invalid role rejected');
select lives_ok($$select * from public.create_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000003','36000000-0000-4000-8000-000000000001',
 'Other Worker',array['dispatcher'])$$,'second Supervisor creates own staff');
select lives_ok($$select * from public.create_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000008','26000000-0000-4000-8000-000000000002',
 '36000000-0000-4000-8000-000000000003','16000000-0000-4000-8000-000000000004')$$,
 'other tenant manager creates its Supervisor team');
select lives_ok($$select * from public.create_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000004','36000000-0000-4000-8000-000000000003',
 'Other Tenant Worker',array['cleaner'])$$,'other tenant Supervisor creates own staff');
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000001',true);
select cmp_ok((select count(*) from public.operational_staff
 where organization_id='26000000-0000-4000-8000-000000000001'),'>',0::bigint,
 'active Organization Manager can read active organization staff');
reset role;
update public.organizations set active=false where id='26000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000001',true);
select is((select count(*) from public.operational_staff
 where organization_id='26000000-0000-4000-8000-000000000001'),0::bigint,
 'inactive organization prevents operational staff reads');
reset role;
update public.organizations set active=true where id='26000000-0000-4000-8000-000000000001';
update public.branches set active=false where id='36000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000003',true);
select is((select count(*) from public.branches
 where id='36000000-0000-4000-8000-000000000001'),0::bigint,
 'inactive branch remains denied by RLS');
reset role;
update public.branches set active=true where id='36000000-0000-4000-8000-000000000001';
update public.branch_memberships set active=false
 where branch_id='36000000-0000-4000-8000-000000000001'
   and user_id='16000000-0000-4000-8000-000000000003';
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','16000000-0000-4000-8000-000000000003',true);
select is((select count(*) from public.operational_staff
 where branch_id='36000000-0000-4000-8000-000000000001'),0::bigint,
 'inactive branch membership cannot read operational staff');
reset role;
update public.branch_memberships set active=true
 where branch_id='36000000-0000-4000-8000-000000000001'
   and user_id='16000000-0000-4000-8000-000000000003';
select throws_ok($$select * from public.update_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000003',
 (select id from public.operational_staff where organization_id='26000000-0000-4000-8000-000000000002'
  and branch_id='36000000-0000-4000-8000-000000000003'
  and created_by='16000000-0000-4000-8000-000000000004' and display_name='Other Tenant Worker'),
 'Cross Tenant','active',array['cleaner'])$$,'42501','staff operation denied',
 'cross-organization staff update denied');
select throws_ok($$select * from public.update_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 (select id from public.operational_staff where organization_id='26000000-0000-4000-8000-000000000001'
  and branch_id='36000000-0000-4000-8000-000000000001'
  and created_by='16000000-0000-4000-8000-000000000003' and display_name='Other Worker'),
 'Stolen','active',array['dispatcher'])$$,'42501','staff operation denied',
 'same-branch other Supervisor cannot update staff');
select throws_ok($$select * from public.update_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000002',
 (select id from public.operational_staff where organization_id='26000000-0000-4000-8000-000000000001'
  and branch_id='36000000-0000-4000-8000-000000000001'
  and created_by='16000000-0000-4000-8000-000000000002' and display_name='Owner Worker'),
 'Cross Branch','active',array['kitchen'])$$,'42501','staff operation denied',
 'cross-branch staff update denied');
select lives_ok($$select * from public.update_supervisor_operational_staff(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 (select id from public.operational_staff where organization_id='26000000-0000-4000-8000-000000000001'
  and branch_id='36000000-0000-4000-8000-000000000001'
  and created_by='16000000-0000-4000-8000-000000000002' and display_name='Owner Worker'),
 'Owner Worker','inactive',array['kitchen','cleaner'])$$,'staff can be made inactive without shift');
select ok((select employment_status='inactive' and deactivated_at is not null
 from public.operational_staff where organization_id='26000000-0000-4000-8000-000000000001'
  and branch_id='36000000-0000-4000-8000-000000000001'
  and created_by='16000000-0000-4000-8000-000000000002' and display_name='Owner Worker'),
 'inactive employment lifecycle is persisted');
select lives_ok($$select * from public.set_supervisor_operational_duty(
 '16000000-0000-4000-8000-000000000003','36000000-0000-4000-8000-000000000001',
 (select id from public.operational_staff where organization_id='26000000-0000-4000-8000-000000000001'
  and branch_id='36000000-0000-4000-8000-000000000001'
  and created_by='16000000-0000-4000-8000-000000000003' and display_name='Other Worker'),
 '2026-07-31','day_off')$$,'Day Off works for a shift-free assignment');
select is((select duty_status from public.operational_staff_duty_statuses duty
 join public.operational_staff staff on staff.id=duty.operational_staff_id
 where staff.organization_id='26000000-0000-4000-8000-000000000001'
 and staff.branch_id='36000000-0000-4000-8000-000000000001'
 and staff.created_by='16000000-0000-4000-8000-000000000003'
 and staff.display_name='Other Worker' and duty.duty_date='2026-07-31'),
 'day_off','Day Off is date scoped without shift');
select ok((select staff.employment_status='active' and assignment.operational_roles=array['dispatcher']
  and assignment.active and assignment.shift_id is null
 from public.operational_staff staff join public.operational_staff_assignments assignment
  on assignment.operational_staff_id=staff.id
 where staff.organization_id='26000000-0000-4000-8000-000000000001'
 and staff.branch_id='36000000-0000-4000-8000-000000000001'
 and staff.created_by='16000000-0000-4000-8000-000000000003'
 and staff.display_name='Other Worker'),
 'Day Off preserves staff, roles, team assignment, employment, and null shift');
select is((select duty_status from public.get_supervisor_operational_team(
 '16000000-0000-4000-8000-000000000003','36000000-0000-4000-8000-000000000001',
 '2026-08-01') where display_name='Other Worker'),'on_duty',
 'another branch-local date remains isolated and defaults On Duty');
select lives_ok($$select * from public.set_supervisor_operational_duty(
 '16000000-0000-4000-8000-000000000003','36000000-0000-4000-8000-000000000001',
 (select id from public.operational_staff where organization_id='26000000-0000-4000-8000-000000000001'
  and branch_id='36000000-0000-4000-8000-000000000001'
  and created_by='16000000-0000-4000-8000-000000000003' and display_name='Other Worker'),
 '2026-07-31','on_duty')$$,'On Duty works for a shift-free assignment');
select is((select count(*) from public.operational_staff_duty_statuses duty
 join public.operational_staff staff on staff.id=duty.operational_staff_id
 where staff.organization_id='26000000-0000-4000-8000-000000000001'
 and staff.branch_id='36000000-0000-4000-8000-000000000001'
 and staff.created_by='16000000-0000-4000-8000-000000000003'
 and staff.display_name='Other Worker' and duty.duty_date='2026-07-31'),1::bigint,
 'duty upsert preserves one row per assignment and date');
select is((select count(*) from public.get_supervisor_operational_team(
 '16000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000001',
 '2026-07-31') where display_name='Owner Worker'),0::bigint,
 'inactive staff is excluded from the active team result');

select throws_ok($$select * from public.update_managed_supervisor_team(
 '16000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000001',
 (select id from public.branch_supervisor_teams where supervisor_user_id=
  '16000000-0000-4000-8000-000000000003' and branch_id='36000000-0000-4000-8000-000000000001'),false)$$,
 '23514','team has active dependencies','team deactivation blocked by active staff assignment');
select is((select count(*) from public.account_management_audit_logs
 where organization_id='26000000-0000-4000-8000-000000000001'
 and action='supervisor_team_deactivated'),0::bigint,'failed deactivation leaves no audit');

insert into public.branch_shifts(id,organization_id,branch_id,name,start_time,end_time,active)
values('46000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000002','Historical','08:00','16:00',false);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,shift_id,active)
values('56000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000002','16000000-0000-4000-8000-000000000003',
 '46000000-0000-4000-8000-000000000001',false);
insert into public.operational_staff(id,organization_id,branch_id,display_name,employment_status,created_by,
 deactivated_at,deactivated_by)
values('66000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000002','Historical Worker','inactive',
 '16000000-0000-4000-8000-000000000003',now(),'16000000-0000-4000-8000-000000000003');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,
 supervisor_team_id,shift_id,operational_roles,active,valid_to)
values('76000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000001',
 '36000000-0000-4000-8000-000000000002','66000000-0000-4000-8000-000000000001',
 '56000000-0000-4000-8000-000000000001','46000000-0000-4000-8000-000000000001',
 array['cleaner'],false,current_date);
insert into public.branch_operational_teams(id,organization_id,branch_id,name,active) values
 ('46000000-0000-4000-8000-000000000101','26000000-0000-4000-8000-000000000001','36000000-0000-4000-8000-000000000001','Provisioning Canonical A',true),
 ('46000000-0000-4000-8000-000000000102','26000000-0000-4000-8000-000000000001','36000000-0000-4000-8000-000000000002','Provisioning Canonical B',true),
 ('46000000-0000-4000-8000-000000000103','26000000-0000-4000-8000-000000000002','36000000-0000-4000-8000-000000000003','Provisioning Other Org',true);
select ok(exists(select 1 from public.branch_shifts where id='46000000-0000-4000-8000-000000000001')
 and exists(select 1 from public.branch_supervisor_teams where id='56000000-0000-4000-8000-000000000001'
  and shift_id='46000000-0000-4000-8000-000000000001')
 and exists(select 1 from public.operational_staff_assignments
  where id='76000000-0000-4000-8000-000000000001'
  and shift_id='46000000-0000-4000-8000-000000000001'),
 'historical non-null shift references and rows remain valid');

select lives_ok($$select public.finalize_provisioned_supervisor(
 '16000000-0000-4000-8000-000000000009','26000000-0000-4000-8000-000000000001',
 '16000000-0000-4000-8000-000000000008','Provisioned',array[
  '36000000-0000-4000-8000-000000000001'::uuid,
  '36000000-0000-4000-8000-000000000002'::uuid],
 null,
 pg_catalog.jsonb_build_array(
  pg_catalog.jsonb_build_object('operational_team_id','46000000-0000-4000-8000-000000000101','assignment_role','primary'),
  pg_catalog.jsonb_build_object('operational_team_id','46000000-0000-4000-8000-000000000102','assignment_role','backup')
 ))$$,
 'provisioning finalization atomically creates canonical team assignments');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id=
 '16000000-0000-4000-8000-000000000008' and active),2::bigint,
 'provisioning creates exactly one active canonical assignment per selected team');
select ok(not exists(select 1 from public.branch_supervisor_teams where supervisor_user_id=
 '16000000-0000-4000-8000-000000000008'),
 'provisioned supervisor does not require a legacy supervisor team');
select throws_ok($$select public.finalize_provisioned_supervisor(
 '16000000-0000-4000-8000-000000000009','26000000-0000-4000-8000-000000000001',
 '16000000-0000-4000-8000-000000000004','Invalid Atomic',array[
  '36000000-0000-4000-8000-000000000001'::uuid,
  '36000000-0000-4000-8000-000000000003'::uuid],
 null,
 pg_catalog.jsonb_build_array(
  pg_catalog.jsonb_build_object('operational_team_id','46000000-0000-4000-8000-000000000101','assignment_role','backup'),
  pg_catalog.jsonb_build_object('operational_team_id','46000000-0000-4000-8000-000000000103','assignment_role','backup')
 ))$$,'22023','invalid provisioning input',
 'failed cross-tenant finalization is rejected atomically');
select ok(not exists(select 1 from public.organization_memberships where user_id=
 '16000000-0000-4000-8000-000000000004' and organization_id='26000000-0000-4000-8000-000000000001')
 and not exists(select 1 from public.branch_operational_team_supervisors where supervisor_user_id=
 '16000000-0000-4000-8000-000000000004' and organization_id='26000000-0000-4000-8000-000000000001'),
 'failed finalization leaves no partial membership or canonical team rows');

select ok(not exists(select 1 from public.account_management_audit_logs log
 cross join lateral jsonb_object_keys(log.details) key
 where log.organization_id in ('26000000-0000-4000-8000-000000000001','26000000-0000-4000-8000-000000000002')
 and log.action in ('supervisor_team_assigned','supervisor_team_deactivated',
  'operational_staff_created','operational_staff_updated','operational_staff_deactivated')
 and key ~* 'email|password|token|secret|shift'),
 'current mutation audit details are secret-free and shift-free');

select * from finish();
rollback;
