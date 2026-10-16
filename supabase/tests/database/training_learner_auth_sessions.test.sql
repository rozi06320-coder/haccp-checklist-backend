begin;
select plan(41);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values(
  '00000000-0000-0000-0000-000000000000',
  '3a100000-0000-4000-8000-000000000001',
  'authenticated','authenticated','phase3a-admin@example.invalid','{}','{}',now(),now()
);
update public.profiles set full_name='Phase 3A Admin',must_change_password=false
where id='3a100000-0000-4000-8000-000000000001';
insert into public.internal_admin_memberships(user_id,active,created_by,updated_by)
values(
  '3a100000-0000-4000-8000-000000000001',true,
  '3a100000-0000-4000-8000-000000000001','3a100000-0000-4000-8000-000000000001'
);

insert into public.organizations(id,name,slug) values
  ('3a200000-0000-4000-8000-000000000001','Phase 3A Org','phase-3a-org'),
  ('3a200000-0000-4000-8000-000000000002','Other Phase 3A Org','other-phase-3a-org');
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('3a300000-0000-4000-8000-000000000001','3a200000-0000-4000-8000-000000000001','Phase 3A Branch','P3A','Asia/Riyadh',true),
  ('3a300000-0000-4000-8000-000000000002','3a200000-0000-4000-8000-000000000002','Other Phase 3A Branch','OP3A','Asia/Riyadh',true);
insert into public.branch_memberships(branch_id,user_id,role,active)
values('3a300000-0000-4000-8000-000000000001','3a100000-0000-4000-8000-000000000001','branch_manager',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,active)
values(
  '3a400000-0000-4000-8000-000000000001','3a200000-0000-4000-8000-000000000001',
  '3a300000-0000-4000-8000-000000000001','3a100000-0000-4000-8000-000000000001',true
);
select set_config('test.phase3a_team',(
  select id::text from public.branch_operational_teams
  where legacy_supervisor_team_id='3a400000-0000-4000-8000-000000000001'
),false);

insert into public.branch_training_access(
  organization_id,branch_id,enabled,pin_hash,salt,kdf_version,cost,block_size,parallelization,credential_version,updated_by
) values(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',true,
  decode(repeat('11',32),'hex'),decode(repeat('22',16),'hex'),1,16384,8,1,
  '3a500000-0000-4000-8000-000000000001','3a100000-0000-4000-8000-000000000001'
);
insert into public.operational_staff(
  id,organization_id,branch_id,display_name,employment_status,created_by,staff_code
) values(
  '3a600000-0000-4000-8000-000000000001','3a200000-0000-4000-8000-000000000001',
  '3a300000-0000-4000-8000-000000000001','Phase 3A Employee','active',
  '3a100000-0000-4000-8000-000000000001','P3A-001'
);
insert into public.operational_staff_assignments(
  id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,
  operational_roles,active,valid_from,valid_to
) values(
  '3a700000-0000-4000-8000-000000000001','3a200000-0000-4000-8000-000000000001',
  '3a300000-0000-4000-8000-000000000001','3a600000-0000-4000-8000-000000000001',
  '3a400000-0000-4000-8000-000000000001',current_setting('test.phase3a_team')::uuid,
  array['kitchen'],true,private.phase4a_business_date('Asia/Riyadh'),null
);

select lives_ok($$
  select * from public.store_internal_admin_operational_staff_training_credential(
    '3a100000-0000-4000-8000-000000000001','3a200000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',
    chr(92)||'x'||repeat('33',32),chr(92)||'x'||repeat('44',16),1,16384,8,1
  )
$$,'existing Internal Admin credential provisioning remains compatible');
select set_config('test.phase3a_credential_version',(
  select credential_version::text from public.operational_staff_training_credentials
  where employee_id='3a600000-0000-4000-8000-000000000001'
),false);

select is((select count(*)::integer from information_schema.columns
  where table_schema='public' and table_name='training_learner_sessions'
    and column_name in('token_digest','idle_expires_at')),2,'session hardening columns exist');
select is((select count(*)::integer from information_schema.columns
  where table_schema='public' and table_name='training_learner_sessions'
    and column_name in('token','raw_token','session_token')),0,'raw session token column does not exist');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.training_learner_sessions'::regclass),
  'learner sessions retain RLS');
select ok(
  not has_table_privilege('anon','public.training_learner_sessions','select')
  and not has_table_privilege('authenticated','public.training_learner_sessions','select')
  and not has_table_privilege('service_role','public.training_learner_sessions','select'),
  'no application role has direct learner-session table access');

select is((select count(*)::integer from public.get_training_learner_login_credential(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001','p3a-001'
)),1,'eligible employee credential resolves case-insensitively');
select is((select count(*)::integer from public.get_training_learner_login_credential(
  '3a200000-0000-4000-8000-000000000002','3a300000-0000-4000-8000-000000000001','P3A-001'
)),0,'cross-organization credential lookup fails closed');
select is((select count(*)::integer from public.get_training_learner_login_credential(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001','UNKNOWN'
)),0,'unknown employee lookup fails closed');
update public.operational_staff
set employment_status='inactive',
    deactivated_at=statement_timestamp(),
    deactivated_by='3a100000-0000-4000-8000-000000000001'
where id='3a600000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.get_training_learner_login_credential(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001','P3A-001'
)),0,'inactive employee login fails closed');
update public.operational_staff
set employment_status='active',deactivated_at=null,deactivated_by=null
where id='3a600000-0000-4000-8000-000000000001';
update public.operational_staff_assignments set active=false
where id='3a700000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.get_training_learner_login_credential(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001','P3A-001'
)),0,'inactive operational assignment login fails closed');
update public.operational_staff_assignments set active=true
where id='3a700000-0000-4000-8000-000000000001';

select is((select count(*)::integer from public.complete_training_learner_login(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
  '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
  false,repeat('1',64)
)),0,'failed authentication creates no session');
select is((select failed_attempt_count from public.operational_staff_training_credentials
  where employee_id='3a600000-0000-4000-8000-000000000001'),1,'first failure is persisted');

do $setup$
begin
  perform * from public.complete_training_learner_login(
    '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
    false,repeat('2',64));
  perform * from public.complete_training_learner_login(
    '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
    false,repeat('3',64));
  perform * from public.complete_training_learner_login(
    '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
    false,repeat('4',64));
  perform * from public.complete_training_learner_login(
    '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
    false,repeat('5',64));
end
$setup$;

select is((select status from public.operational_staff_training_credentials
  where employee_id='3a600000-0000-4000-8000-000000000001'),'locked','fifth failure atomically locks the credential');
select is((select failed_attempt_count from public.operational_staff_training_credentials
  where employee_id='3a600000-0000-4000-8000-000000000001'),5,'lockout retains exactly five failures');
select ok((select locked_until > statement_timestamp() from public.operational_staff_training_credentials
  where employee_id='3a600000-0000-4000-8000-000000000001'),'lockout has a future expiry');
select is((select count(*)::integer from public.complete_training_learner_login(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
  '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
  true,repeat('a',64)
)),0,'matching PIN cannot bypass an active lockout');

update public.operational_staff_training_credentials
set locked_until=statement_timestamp()-interval '1 second'
where employee_id='3a600000-0000-4000-8000-000000000001';
select is((select count(*)::integer from public.complete_training_learner_login(
  '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
  '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
  true,repeat('a',64)
)),1,'expired lock permits a valid login');
select ok((select expires_at-issued_at=interval '12 hours' from public.training_learner_sessions
  where token_digest=repeat('a',64)),'session has a 12-hour absolute lifetime');
select ok((select idle_expires_at-issued_at=interval '1 hour' from public.training_learner_sessions
  where token_digest=repeat('a',64)),'session has a one-hour idle lifetime');
select ok((select token_digest=repeat('a',64) and to_jsonb(learner_session)::text !~ 'raw_token|session_token'
  from public.training_learner_sessions learner_session where token_digest=repeat('a',64)),
  'database stores only the token digest');
select is((select count(*)::integer from public.validate_training_learner_session(repeat('a',64))),1,
  'valid revocable session resolves learner context');
select ok((select last_seen_at is not null and idle_expires_at<=expires_at
  from public.training_learner_sessions where token_digest=repeat('a',64)),
  'session validation refreshes bounded activity timestamps');
select is((select count(*)::integer from public.validate_training_learner_session(repeat('f',64))),0,
  'forged token digest is rejected');

insert into public.training_learner_sessions(
  organization_id,employee_id,branch_id_at_auth,credential_version,
  issued_at,expires_at,last_seen_at,token_digest,idle_expires_at
) values(
  '3a200000-0000-4000-8000-000000000001','3a600000-0000-4000-8000-000000000001',
  '3a300000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
  statement_timestamp()-interval '13 hours',statement_timestamp()-interval '1 hour',
  statement_timestamp()-interval '2 hours',repeat('e',64),statement_timestamp()-interval '2 hours'
),(
  '3a200000-0000-4000-8000-000000000001','3a600000-0000-4000-8000-000000000001',
  '3a300000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
  statement_timestamp()-interval '2 hours',statement_timestamp()+interval '10 hours',
  statement_timestamp()-interval '2 hours',repeat('f0',32),statement_timestamp()-interval '1 hour'
);
select is((select count(*)::integer from public.validate_training_learner_session(repeat('e',64))),0,
  'absolute session expiry is enforced');
select ok((select revoked_at is not null from public.training_learner_sessions where token_digest=repeat('e',64)),
  'an absolute-expired session is persistently revoked');
select is((select count(*)::integer from public.validate_training_learner_session(repeat('f0',32))),0,
  'idle session expiry is enforced');
select ok((select revoked_at is not null from public.training_learner_sessions where token_digest=repeat('f0',32)),
  'an idle-expired session is persistently revoked');

select ok((select revoked from public.revoke_training_learner_session(repeat('a',64))),
  'logout revokes the matching database session');
select is((select count(*)::integer from public.validate_training_learner_session(repeat('a',64))),0,
  'revoked session cannot be reused');
select ok((select revoked from public.revoke_training_learner_session(repeat('a',64))),
  'logout revocation is idempotent');

do $setup$
begin
  perform * from public.complete_training_learner_login(
    '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_credential_version')::uuid,
    true,repeat('b',64));
end
$setup$;
select lives_ok($$
  select * from public.store_internal_admin_operational_staff_training_credential(
    '3a100000-0000-4000-8000-000000000001','3a200000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',
    chr(92)||'x'||repeat('55',32),chr(92)||'x'||repeat('66',16),1,16384,8,1
  )
$$,'credential reset remains operational');
select ok((select revoked_at is not null from public.training_learner_sessions where token_digest=repeat('b',64)),
  'credential reset revokes the old session');

select set_config('test.phase3a_new_version',(
  select credential_version::text from public.operational_staff_training_credentials
  where employee_id='3a600000-0000-4000-8000-000000000001'
),false);
do $setup$
begin
  perform * from public.complete_training_learner_login(
    '3a200000-0000-4000-8000-000000000001','3a300000-0000-4000-8000-000000000001',
    '3a600000-0000-4000-8000-000000000001',current_setting('test.phase3a_new_version')::uuid,
    true,repeat('c',64));
end
$setup$;
update public.branch_operational_teams set active=false
where id=current_setting('test.phase3a_team')::uuid;
select is((select count(*)::integer from public.validate_training_learner_session(repeat('c',64))),0,
  'inactive modern operational assignment context invalidates access');
select ok((select revoked_at is not null from public.training_learner_sessions where token_digest=repeat('c',64)),
  'eligibility failure persistently revokes the old session');

select ok((select bool_and(procedure.prosecdef)
  from pg_catalog.pg_proc procedure
  where procedure.oid in(
    'public.get_training_learner_login_credential(uuid,uuid,text)'::regprocedure,
    'public.complete_training_learner_login(uuid,uuid,uuid,uuid,boolean,text)'::regprocedure,
    'public.validate_training_learner_session(text)'::regprocedure,
    'public.revoke_training_learner_session(text)'::regprocedure
  )),'all learner authentication RPCs are SECURITY DEFINER');
select ok((select bool_and(procedure.proconfig @> array['search_path=""'])
  from pg_catalog.pg_proc procedure
  where procedure.oid in(
    'public.get_training_learner_login_credential(uuid,uuid,text)'::regprocedure,
    'public.complete_training_learner_login(uuid,uuid,uuid,uuid,boolean,text)'::regprocedure,
    'public.validate_training_learner_session(text)'::regprocedure,
    'public.revoke_training_learner_session(text)'::regprocedure
  )),'all learner authentication RPCs have an empty search_path');
select ok(
  has_function_privilege('service_role','public.get_training_learner_login_credential(uuid,uuid,text)','execute')
  and has_function_privilege('service_role','public.complete_training_learner_login(uuid,uuid,uuid,uuid,boolean,text)','execute')
  and has_function_privilege('service_role','public.validate_training_learner_session(text)','execute')
  and has_function_privilege('service_role','public.revoke_training_learner_session(text)','execute'),
  'service_role can execute all learner authentication RPCs');
select ok(
  not has_function_privilege('anon','public.get_training_learner_login_credential(uuid,uuid,text)','execute')
  and not has_function_privilege('anon','public.complete_training_learner_login(uuid,uuid,uuid,uuid,boolean,text)','execute')
  and not has_function_privilege('anon','public.validate_training_learner_session(text)','execute')
  and not has_function_privilege('anon','public.revoke_training_learner_session(text)','execute'),
  'anon cannot execute learner authentication RPCs');
select ok(
  not has_function_privilege('authenticated','public.get_training_learner_login_credential(uuid,uuid,text)','execute')
  and not has_function_privilege('authenticated','public.complete_training_learner_login(uuid,uuid,uuid,uuid,boolean,text)','execute')
  and not has_function_privilege('authenticated','public.validate_training_learner_session(text)','execute')
  and not has_function_privilege('authenticated','public.revoke_training_learner_session(text)','execute'),
  'authenticated cannot execute learner authentication RPCs');

select throws_like($$
  insert into public.training_learner_sessions(
    organization_id,employee_id,branch_id_at_auth,credential_version,expires_at,token_digest,idle_expires_at
  ) values(
    '3a200000-0000-4000-8000-000000000001','3a600000-0000-4000-8000-000000000001',
    '3a300000-0000-4000-8000-000000000001',current_setting('test.phase3a_new_version')::uuid,
    statement_timestamp()+interval '2 hours','NOT-A-DIGEST',statement_timestamp()+interval '1 hour'
  )
$$,'%violates check constraint "training_learner_sessions_token_digest_check"%',
  'invalid token digests are rejected');
select throws_like($$
  insert into public.training_learner_sessions(
    organization_id,employee_id,branch_id_at_auth,credential_version,expires_at,token_digest,idle_expires_at
  ) values(
    '3a200000-0000-4000-8000-000000000001','3a600000-0000-4000-8000-000000000001',
    '3a300000-0000-4000-8000-000000000001',current_setting('test.phase3a_new_version')::uuid,
    statement_timestamp()+interval '1 hour',repeat('d',64),statement_timestamp()+interval '2 hours'
  )
$$,'%violates check constraint "training_learner_sessions_idle_expiry_check"%',
  'idle expiry cannot exceed absolute expiry');

select * from finish();
rollback;
