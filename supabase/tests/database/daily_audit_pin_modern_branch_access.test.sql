begin;
select plan(35);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1f100000-0000-4000-8000-000000000001'::uuid,
  '1f100000-0000-4000-8000-000000000002',
  '1f100000-0000-4000-8000-000000000003'
]) id;

update public.profiles
set full_name = case id
    when '1f100000-0000-4000-8000-000000000001' then 'Organization Manager'
    when '1f100000-0000-4000-8000-000000000002' then 'Modern Supervisor'
    else 'Other Supervisor'
  end,
  must_change_password = false
where id::text like '1f100000-%';

insert into public.organizations(id,name,slug,active) values
  ('2f100000-0000-4000-8000-000000000001','Modern Daily Audit','modern-daily-audit',true),
  ('2f100000-0000-4000-8000-000000000002','Inactive Daily Audit','inactive-daily-audit',false);

insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('3f100000-0000-4000-8000-000000000001','2f100000-0000-4000-8000-000000000001','Modern Branch','MD1','Asia/Riyadh',true),
  ('3f100000-0000-4000-8000-000000000002','2f100000-0000-4000-8000-000000000001','Other Branch','MD2','Asia/Riyadh',true),
  ('3f100000-0000-4000-8000-000000000003','2f100000-0000-4000-8000-000000000001','Inactive Branch','MD3','Asia/Riyadh',false),
  ('3f100000-0000-4000-8000-000000000004','2f100000-0000-4000-8000-000000000002','Inactive Org Branch','MD4','Asia/Riyadh',true);

insert into public.organization_memberships(organization_id,user_id,role) values
  ('2f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000001','organization_manager');

insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('3f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000002','branch_manager',true),
  ('3f100000-0000-4000-8000-000000000002','1f100000-0000-4000-8000-000000000003','branch_manager',true),
  ('3f100000-0000-4000-8000-000000000003','1f100000-0000-4000-8000-000000000002','branch_manager',true),
  ('3f100000-0000-4000-8000-000000000004','1f100000-0000-4000-8000-000000000002','branch_manager',true);

insert into public.branch_operational_teams(id,organization_id,branch_id,name,active) values
  ('4f100000-0000-4000-8000-000000000001','2f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000001','Modern Team',true);

insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,
  assignment_role,active,valid_from,created_by
) values (
  '4f100000-0000-4000-8000-000000000002','2f100000-0000-4000-8000-000000000001',
  '3f100000-0000-4000-8000-000000000001','4f100000-0000-4000-8000-000000000001',
  '1f100000-0000-4000-8000-000000000002','primary',true,current_date,
  '1f100000-0000-4000-8000-000000000001'
);

insert into public.daily_audit_access_users(
  id,organization_id,display_name,pin_hash,salt,kdf_version,cost,block_size,
  parallelization,credential_version,active,created_by,updated_by
) values (
  '5f100000-0000-4000-8000-000000000001','2f100000-0000-4000-8000-000000000001',
  'Audit Runner',decode(repeat('11',32),'hex'),decode(repeat('12',16),'hex'),
  1,16384,8,1,'6f100000-0000-4000-8000-000000000001',true,
  '1f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000001'
);

insert into private.organization_manager_daily_audit_pins(
  organization_id,manager_user_id,pin_hash,salt,pin_fingerprint,kdf_version,
  cost,block_size,parallelization,credential_version,configured_by,updated_by
) values (
  '2f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000001',
  decode(repeat('21',32),'hex'),decode(repeat('22',16),'hex'),decode(repeat('23',32),'hex'),
  1,16384,8,1,'6f100000-0000-4000-8000-000000000002',
  '1f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000001'
);

select ok(
  private.actor_can_read_operational_branch(
    '1f100000-0000-4000-8000-000000000002',
    '3f100000-0000-4000-8000-000000000001'
  ),
  'modern-only Supervisor has canonical branch access'
);
select ok(
  exists(
    select 1 from public.branch_operational_team_supervisors
    where supervisor_user_id='1f100000-0000-4000-8000-000000000002'
      and branch_id='3f100000-0000-4000-8000-000000000001' and active
  ),
  'modern-only Supervisor has an active operational-team assignment'
);
select is(
  (select count(*) from public.branch_supervisor_teams
   where supervisor_user_id='1f100000-0000-4000-8000-000000000002'),
  0::bigint,
  'modern-only Supervisor has no legacy Supervisor-team row'
);

set local role service_role;
select is(
  (select count(*) from public.get_daily_audit_access_user_credentials(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001'
  )),
  1::bigint,
  'modern-only Supervisor can resolve an active manual PIN credential'
);
select is(
  (select count(*) from public.get_organization_manager_daily_audit_credentials(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001'
  )),
  1::bigint,
  'modern-only Supervisor can resolve an active Manager PIN credential'
);
select lives_ok($$
  select * from public.record_organization_manager_daily_audit_access_grant(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001',
    '1f100000-0000-4000-8000-000000000001','6f100000-0000-4000-8000-000000000002'
  )
$$,'modern-only Supervisor can record a Manager PIN grant');
reset role;

select is(
  (select count(*) from public.account_management_audit_logs
   where actor_user_id='1f100000-0000-4000-8000-000000000002'
     and branch_id='3f100000-0000-4000-8000-000000000001'
     and action='daily_audit_access_granted'),
  1::bigint,
  'recorded Manager PIN grant retains its audit event'
);

set local role service_role;
select is(
  public.validate_organization_manager_daily_audit_grant(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001',
    '1f100000-0000-4000-8000-000000000001','6f100000-0000-4000-8000-000000000002'
  ),
  true,
  'current credential version validates for a modern-only Supervisor'
);
select is(
  public.validate_organization_manager_daily_audit_grant(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001',
    '1f100000-0000-4000-8000-000000000001','6f100000-0000-4000-8000-000000000099'
  ),
  false,
  'stale credential version does not validate'
);
select throws_ok($$
  select * from public.record_organization_manager_daily_audit_access_grant(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001',
    '1f100000-0000-4000-8000-000000000001','6f100000-0000-4000-8000-000000000099'
  )
$$,'42501','access denied','stale credential version cannot be recorded');

select throws_ok($$
  select * from public.get_daily_audit_access_user_credentials(
    '1f100000-0000-4000-8000-000000000003','3f100000-0000-4000-8000-000000000001'
  )
$$,'42501','access denied','cross-branch actor cannot resolve manual credentials');
select throws_ok($$
  select * from public.get_organization_manager_daily_audit_credentials(
    '1f100000-0000-4000-8000-000000000003','3f100000-0000-4000-8000-000000000001'
  )
$$,'42501','access denied','cross-branch actor cannot resolve Manager credentials');
select is(
  public.validate_organization_manager_daily_audit_grant(
    '1f100000-0000-4000-8000-000000000003','3f100000-0000-4000-8000-000000000001',
    '1f100000-0000-4000-8000-000000000001','6f100000-0000-4000-8000-000000000002'
  ),
  false,
  'cross-branch actor cannot validate a grant'
);

select throws_ok($$
  select * from public.get_daily_audit_access_user_credentials(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000003'
  )
$$,'42501','access denied','inactive branch cannot resolve manual credentials');
select throws_ok($$
  select * from public.get_organization_manager_daily_audit_credentials(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000003'
  )
$$,'42501','access denied','inactive branch cannot resolve Manager credentials');
select is(
  public.validate_organization_manager_daily_audit_grant(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000003',
    '1f100000-0000-4000-8000-000000000001','6f100000-0000-4000-8000-000000000002'
  ),
  false,
  'inactive branch cannot validate a grant'
);

select throws_ok($$
  select * from public.get_daily_audit_access_user_credentials(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000004'
  )
$$,'42501','access denied','inactive organization cannot resolve manual credentials');
select throws_ok($$
  select * from public.get_organization_manager_daily_audit_credentials(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000004'
  )
$$,'42501','access denied','inactive organization cannot resolve Manager credentials');
select is(
  public.validate_organization_manager_daily_audit_grant(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000004',
    '1f100000-0000-4000-8000-000000000001','6f100000-0000-4000-8000-000000000002'
  ),
  false,
  'inactive organization cannot validate a grant'
);
reset role;

select ok((
  select bool_and(not has_function_privilege('public', signature, 'execute'))
  from unnest(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)',
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)',
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)',
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'
  ]) signature
),'public cannot execute the four PIN RPCs');
select ok((
  select bool_and(not has_function_privilege('anon', signature, 'execute'))
  from unnest(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)',
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)',
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)',
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'
  ]) signature
),'anon cannot execute the four PIN RPCs');
select ok((
  select bool_and(not has_function_privilege('authenticated', signature, 'execute'))
  from unnest(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)',
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)',
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)',
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'
  ]) signature
),'authenticated cannot execute the four PIN RPCs');
select ok((
  select bool_and(has_function_privilege('service_role', signature, 'execute'))
  from unnest(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)',
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)',
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)',
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'
  ]) signature
),'service_role can execute the four PIN RPCs');

select ok((
  select bool_and(prosecdef)
  from pg_proc
  where oid = any(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)'::regprocedure,
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)'::regprocedure,
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)'::regprocedure,
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'::regprocedure
  ]::oid[])
),'all four PIN RPCs remain SECURITY DEFINER');
select ok((
  select bool_and(proconfig::text like '%search_path=%')
  from pg_proc
  where oid = any(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)'::regprocedure,
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)'::regprocedure,
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)'::regprocedure,
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'::regprocedure
  ]::oid[])
),'all four PIN RPCs retain an empty search_path');
select ok((
  select bool_and(pg_get_functiondef(oid) !~ 'actor_owns_operational_team')
  from pg_proc
  where oid = any(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)'::regprocedure,
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)'::regprocedure,
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)'::regprocedure,
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'::regprocedure
  ]::oid[])
),'the four PIN RPCs no longer depend on legacy team ownership');
select is((
  select count(*)
  from pg_proc
  where oid = any(array[
    'public.get_daily_audit_access_user_credentials(uuid,uuid)'::regprocedure,
    'public.get_organization_manager_daily_audit_credentials(uuid,uuid)'::regprocedure,
    'public.record_organization_manager_daily_audit_access_grant(uuid,uuid,uuid,uuid)'::regprocedure,
    'public.validate_organization_manager_daily_audit_grant(uuid,uuid,uuid,uuid)'::regprocedure
  ]::oid[])
    and pg_get_functiondef(oid) ~ 'actor_can_read_operational_branch'
),4::bigint,'all four PIN RPCs use canonical modern branch access');

set local role service_role;
select is(
  public.get_supervisor_daily_audit_current_state(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001','2026-10-10'
  )->>'state',
  'empty',
  'Daily Audit current-state remains available to a modern-only Supervisor'
);
select set_config('test.daily_audit_draft', public.save_supervisor_daily_audit_draft(
  '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001','2026-10-10',0,
  'manual_access_user','5f100000-0000-4000-8000-000000000001','Audit Runner',
  '6f100000-0000-4000-8000-000000000001','[]'::jsonb
)::text,true);
select is(current_setting('test.daily_audit_draft')::jsonb->>'state','draft','Daily Audit draft save remains unchanged');
select is(current_setting('test.daily_audit_draft')::jsonb->>'revision','1','Daily Audit draft save still advances revision zero to one');
reset role;
select ok((
  select supervisor_team_id is null
  from public.checklist_submissions
  where branch_id='3f100000-0000-4000-8000-000000000001'
    and business_date='2026-10-10' and checklist_type='daily_audit'
),'modern-only Daily Audit persists without legacy attribution');

set local role service_role;
select set_config('test.daily_audit_submit', public.submit_supervisor_daily_audit(
  '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001','2026-10-10',1,
  'manual_access_user','5f100000-0000-4000-8000-000000000001','Audit Runner',
  '6f100000-0000-4000-8000-000000000001',
  (select jsonb_agg(jsonb_build_object(
    'item_id',definition.item_id,'answer','compliant','remark',''
  ) order by definition.item_number)
   from public.daily_audit_item_definitions definition where definition.active),
  'modern-access-submit'
)::text,true);
select is(current_setting('test.daily_audit_submit')::jsonb->>'state','submitted','Daily Audit submit remains unchanged');
select is(current_setting('test.daily_audit_submit')::jsonb->>'revision','2','Daily Audit submit still advances revision one to two');
select is(
  jsonb_array_length(current_setting('test.daily_audit_submit')::jsonb->'items'),
  13,
  'Daily Audit submit still returns all thirteen canonical items'
);
select is(
  public.get_supervisor_daily_audit_current_state(
    '1f100000-0000-4000-8000-000000000002','3f100000-0000-4000-8000-000000000001','2026-10-10'
  )->>'state',
  'submitted',
  'Daily Audit current-state returns the submitted result'
);
reset role;

select * from finish();
rollback;
