begin;
select no_plan();

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',email,
  '{"provider":"email","providers":["email"]}','{}',now(),now()
from (values
  ('73000000-0000-4000-8000-000000000001'::uuid,'reset-admin@example.invalid'),
  ('73000000-0000-4000-8000-000000000002'::uuid,'reset-manager@example.invalid'),
  ('73000000-0000-4000-8000-000000000003'::uuid,'reset-other@example.invalid'),
  ('73000000-0000-4000-8000-000000000004'::uuid,'reset-multi@example.invalid'),
  ('73000000-0000-4000-8000-000000000005'::uuid,'reset-mixed@example.invalid'),
  ('73000000-0000-4000-8000-000000000006'::uuid,'reset-failure@example.invalid')
) users(id,email);

insert into public.internal_admin_memberships(user_id,active) values
  ('73000000-0000-4000-8000-000000000001',true),
  ('73000000-0000-4000-8000-000000000005',true);
insert into public.organizations(id,name,slug,active) values
  ('74000000-0000-4000-8000-000000000001','Reset Org A','reset-security-org-a',true),
  ('74000000-0000-4000-8000-000000000002','Reset Org B','reset-security-org-b',true);
insert into public.organization_memberships(organization_id,user_id,role,active) values
  ('74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002','organization_manager',true),
  ('74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003','organization_manager',true),
  ('74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000004','organization_manager',true),
  ('74000000-0000-4000-8000-000000000002','73000000-0000-4000-8000-000000000004','organization_manager',true),
  ('74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000005','organization_manager',true),
  ('74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000006','organization_manager',true);
insert into auth.sessions(id,user_id,created_at,updated_at) values
  ('75000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000001',now(),now()),
  ('75000000-0000-4000-8000-000000000003','73000000-0000-4000-8000-000000000001',now(),now()),
  ('75000000-0000-4000-8000-000000000002','73000000-0000-4000-8000-000000000002',now(),now());

select ok(has_function_privilege('service_role','public.issue_organization_manager_password_reset_step_up(uuid,uuid,uuid,uuid,text)','execute'),'service role can broker a verified step-up');
select ok(not has_function_privilege('authenticated','public.issue_organization_manager_password_reset_step_up(uuid,uuid,uuid,uuid,text)','execute'),'browser cannot issue step-up grants');
select ok(not has_function_privilege('anon','public.begin_organization_manager_password_reset(uuid,uuid,uuid,uuid,text,text)','execute'),'anon cannot begin reset');
select ok(not has_table_privilege('service_role','private.organization_manager_password_reset_step_up_grants','select'),'service role cannot read grant hashes');
select ok(not has_table_privilege('authenticated','public.organization_manager_password_reset_events','insert'),'authenticated cannot forge reset history');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.organization_manager_password_reset_events'::regclass),'reset events have RLS');
select is(public.validate_organization_manager_backend_session('73000000-0000-4000-8000-000000000002','75000000-0000-4000-8000-000000000002'),'active','live Organization Manager session is active');
select is(public.validate_organization_manager_backend_session('73000000-0000-4000-8000-000000000002','75000000-0000-4000-8000-000000000099'),'revoked','missing Organization Manager session is revoked');
select is(public.validate_organization_manager_backend_session('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001'),'not_applicable','Internal Admin keeps the unrelated bearer-auth path');

set local role service_role;
select throws_ok(
  $$select public.issue_organization_manager_password_reset_step_up('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000002','73000000-0000-4000-8000-000000000002',repeat('1',64))$$,
  '42501','password reset denied','cross-organization target is denied');
select throws_ok(
  $$select public.issue_organization_manager_password_reset_step_up('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000001',repeat('2',64))$$,
  '42501','password reset denied','self reset is denied');
select throws_ok(
  $$select public.issue_organization_manager_password_reset_step_up('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000004',repeat('3',64))$$,
  '42501','password reset denied','multi-organization target is denied');
select throws_ok(
  $$select public.issue_organization_manager_password_reset_step_up('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000005',repeat('4',64))$$,
  '42501','password reset denied','mixed Internal Admin target is denied');

create temporary table issued_grant on commit drop as
select public.issue_organization_manager_password_reset_step_up(
  '73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002',repeat('a',64)
) result;
select throws_ok(
  $$select public.begin_organization_manager_password_reset('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002',repeat('b',64),repeat('9',64))$$,
  'P0001','password reset step-up required','unknown step-up evidence is denied');
create temporary table reset_begin on commit drop as
select public.begin_organization_manager_password_reset(
  '73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002',repeat('b',64),repeat('a',64)
) result;
reset role;

select is((select result->>'status' from reset_begin),'pending_auth','valid grant begins reset');
select ok((select must_change_password from public.profiles where id='73000000-0000-4000-8000-000000000002'),'target is quarantined before Auth mutation');
select ok((select consumed_at is not null from private.organization_manager_password_reset_step_up_grants where secret_sha256=repeat('a',64)),'grant is atomically consumed');

set local role service_role;
select throws_ok(
  $$select public.begin_organization_manager_password_reset('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002',repeat('c',64),repeat('a',64))$$,
  'P0001','password reset step-up required','consumed grant cannot be replayed');
select is((public.finalize_organization_manager_password_reset(
  (select (result->>'operation_id')::uuid from reset_begin),'73000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002')->>'status'),
  'succeeded','reset finalizes exactly once');
reset role;
select is((select count(*) from auth.sessions where user_id='73000000-0000-4000-8000-000000000002'),0::bigint,'successful reset revokes stale target sessions');
set local role service_role;
select is((public.finalize_password_change('73000000-0000-4000-8000-000000000002')->>'success')::boolean,true,'known reset password keeps the existing forced-change completion flow');
reset role;
select ok(not (select must_change_password from public.profiles where id='73000000-0000-4000-8000-000000000002'),'completed password change restores normal manager access');

-- Simulate an ambiguous Auth outcome, age it, then establish a replacement
-- operation whose caller will set a new known password.
set local role service_role;
select public.issue_organization_manager_password_reset_step_up(
  '73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000006',repeat('d',64));
create temporary table ambiguous_begin on commit drop as
select public.begin_organization_manager_password_reset(
  '73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000006',repeat('e',64),repeat('d',64)
) result;
select public.fail_organization_manager_password_reset(
  (select (result->>'operation_id')::uuid from ambiguous_begin),'73000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000006','auth_outcome_unknown');
reset role;
select ok((select must_change_password from public.profiles where id='73000000-0000-4000-8000-000000000006'),'ambiguous outcome remains fail closed');
update public.organization_manager_password_reset_operations set state_changed_at=now()-interval '3 minutes'
where id=(select (result->>'operation_id')::uuid from ambiguous_begin);
set local role service_role;
select public.issue_organization_manager_password_reset_step_up(
  '73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000006',repeat('f',64));
create temporary table recovery_begin on commit drop as
select public.begin_organization_manager_password_reset(
  '73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000006',repeat('0',64),repeat('f',64)
) result;
reset role;
select is((select result->>'recovery_generation' from recovery_begin),'1','stale ambiguous operation gets one bounded replacement');
select is((select status from public.organization_manager_password_reset_operations where id=(select (result->>'operation_id')::uuid from ambiguous_begin)),'superseded','old ambiguous operation is permanently superseded');
set local role service_role;
select throws_ok(
  $$select public.finalize_password_change('73000000-0000-4000-8000-000000000006')$$,
  '42501','password change finalization denied','unresolved recovery cannot restore normal access');
reset role;

set local role service_role;
select public.issue_organization_manager_password_reset_step_up(
  '73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003',repeat('6',64));
select throws_ok(
  $$select public.begin_organization_manager_password_reset('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000003','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003',repeat('5',64),repeat('6',64))$$,
  'P0001','password reset step-up required','grant is bound to the authenticated session');
select throws_ok(
  $$select public.begin_organization_manager_password_reset('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000002',repeat('5',64),repeat('6',64))$$,
  'P0001','password reset step-up required','grant is bound to the exact target');
reset role;
update private.organization_manager_password_reset_step_up_grants
set issued_at=now()-interval '6 minutes',expires_at=now()-interval '1 minute'
where secret_sha256=repeat('6',64);
set local role service_role;
select throws_ok(
  $$select public.begin_organization_manager_password_reset('73000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003',repeat('5',64),repeat('6',64))$$,
  'P0001','password reset step-up required','expired grant is rejected');
reset role;

truncate private.organization_manager_password_reset_rate_limits;
set local role service_role;
select ok((public.consume_organization_manager_password_reset_rate_limit('73000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003',repeat('7',64),'step_up')->>'allowed')::boolean,'first shared rate attempt is allowed');
select public.consume_organization_manager_password_reset_rate_limit('73000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003',repeat('7',64),'step_up');
select public.consume_organization_manager_password_reset_rate_limit('73000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003',repeat('7',64),'step_up');
select ok(not (public.consume_organization_manager_password_reset_rate_limit('73000000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003',repeat('7',64),'step_up')->>'allowed')::boolean,'target limit persists across replicas in the database');
reset role;

select throws_ok(
  $$update public.organization_manager_password_reset_events set details='{}'$$,
  '42501','Organization Manager password reset events are immutable','reset event history cannot be rewritten');
select throws_ok(
  $$delete from public.organization_manager_password_reset_events$$,
  '42501','Organization Manager password reset events are immutable','reset event history cannot be deleted');
select ok(not exists(select 1 from information_schema.columns where table_schema in('public','private')
  and table_name like 'organization_manager_password_reset%' and lower(column_name)~'temporary_password|plaintext'),
  'reset persistence contains no temporary credential column');

-- Snapshot IDs deliberately survive Auth user deletion; the existing audit
-- table keeps its documented ON DELETE SET NULL semantics.
delete from auth.users where id='73000000-0000-4000-8000-000000000002';
select ok(exists(select 1 from public.organization_manager_password_reset_operations where target_user_id='73000000-0000-4000-8000-000000000002'),'operation history survives target Auth deletion');
select ok(exists(select 1 from public.organization_manager_password_reset_events where target_user_id='73000000-0000-4000-8000-000000000002'),'immutable reset events survive target Auth deletion');
select ok(exists(select 1 from public.account_management_audit_logs where target_user_id is null and details->>'reset_operation_id' is not null),'account audit preserves history with SET NULL target attribution');
delete from auth.users where id='73000000-0000-4000-8000-000000000001';
select ok(exists(select 1 from public.organization_manager_password_reset_operations where actor_user_id='73000000-0000-4000-8000-000000000001'),'operation history survives actor Auth deletion');
select ok(exists(select 1 from public.organization_manager_password_reset_events where actor_user_id='73000000-0000-4000-8000-000000000001'),'immutable reset events survive actor Auth deletion');

select * from finish();
rollback;
