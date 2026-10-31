begin;
select plan(45);

select has_function('public','get_incomplete_branch_tasks_completion',array['uuid','uuid'],
  'bounded incomplete-branch-tasks RPC exists');
select has_table('private','organization_manager_notification_evaluation_jobs',
  'category-neutral notification evaluation job table exists');
select has_function('public','enqueue_organization_manager_notification_evaluation_job',
  array['uuid','uuid','date','text'],'category-neutral enqueue RPC exists');
select has_function('public','claim_organization_manager_notification_evaluation_jobs',
  array['uuid','text','integer','integer'],'category-neutral claim RPC exists');
select has_function('public','complete_organization_manager_notification_evaluation_job',
  array['uuid','uuid','text','text'],'category-neutral completion RPC exists');
select has_function('private','incomplete_branch_tasks_completion_at',array['uuid','uuid','date','timestamp with time zone'],
  'timestamped evaluator helper exists for deterministic boundary tests');
select is((select pg_get_function_arguments(
  'public.get_incomplete_branch_tasks_completion(uuid,uuid)'::regprocedure)),
  'p_job_id uuid, p_lease_token uuid','public RPC arguments are exactly job ID and lease token');
select ok((select procedure.prosecdef from pg_proc procedure
  where procedure.oid='public.get_incomplete_branch_tasks_completion(uuid,uuid)'::regprocedure),
  'public evaluator is SECURITY DEFINER');
select is((select procedure.provolatile::text from pg_proc procedure
  where procedure.oid='public.get_incomplete_branch_tasks_completion(uuid,uuid)'::regprocedure),'s',
  'public evaluator is STABLE/read-only');
select ok((select coalesce(array_to_string(procedure.proconfig,','),'') like '%search_path=""%'
  from pg_proc procedure
  where procedure.oid='public.get_incomplete_branch_tasks_completion(uuid,uuid)'::regprocedure),
  'public evaluator has an empty search_path');
select ok(has_function_privilege('service_role',
  'public.get_incomplete_branch_tasks_completion(uuid,uuid)','execute'),
  'service_role can execute the evaluator');
select ok(not has_function_privilege('public',
  'public.get_incomplete_branch_tasks_completion(uuid,uuid)','execute'),
  'PUBLIC cannot execute the evaluator');
select ok(not has_function_privilege('anon',
  'public.get_incomplete_branch_tasks_completion(uuid,uuid)','execute'),
  'anon cannot execute the evaluator');
select ok(not has_function_privilege('authenticated',
  'public.get_incomplete_branch_tasks_completion(uuid,uuid)','execute'),
  'authenticated cannot execute the evaluator');
select ok(not has_function_privilege('service_role',
  'private.incomplete_branch_tasks_completion_at(uuid,uuid,date,timestamptz)','execute'),
  'service_role cannot bypass producer authorization through the timestamped helper');
select ok(has_function_privilege('service_role',
  'public.enqueue_organization_manager_notification_evaluation_job(uuid,uuid,date,text)','execute')
  and has_function_privilege('service_role',
    'public.claim_organization_manager_notification_evaluation_jobs(uuid,text,integer,integer)','execute')
  and has_function_privilege('service_role',
    'public.complete_organization_manager_notification_evaluation_job(uuid,uuid,text,text)','execute'),
  'service_role can manage the generic evaluation lease lifecycle');
select ok(not has_function_privilege('public',
  'public.claim_organization_manager_notification_evaluation_jobs(uuid,text,integer,integer)','execute')
  and not has_function_privilege('anon',
    'public.claim_organization_manager_notification_evaluation_jobs(uuid,text,integer,integer)','execute')
  and not has_function_privilege('authenticated',
    'public.claim_organization_manager_notification_evaluation_jobs(uuid,text,integer,integer)','execute'),
  'generic lease lifecycle is unavailable to non-service roles');
select ok(not has_table_privilege('service_role',
  'private.organization_manager_notification_evaluation_jobs','select')
  and not has_table_privilege('service_role',
    'private.organization_manager_notification_evaluation_jobs','insert')
  and not has_table_privilege('service_role',
    'private.organization_manager_notification_evaluation_jobs','update'),
  'service_role cannot bypass lease RPCs with direct table access');
select throws_ok(
  $$select * from public.get_incomplete_branch_tasks_completion(null,null)$$,
  '22023','invalid incomplete branch task producer lease',
  'null producer authorization is rejected');
select throws_ok(
  $$select * from public.get_incomplete_branch_tasks_completion('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')$$,
  '55000','incomplete branch task producer lease is not active',
  'unknown producer lease is rejected');

insert into public.organizations(id,name,slug)
values
  ('a1300000-0000-4000-8000-000000000001','Completion Org A','completion-org-a'),
  ('a1300000-0000-4000-8000-000000000002','Completion Org B','completion-org-b');
insert into public.branches(id,organization_id,name,code,timezone)
values
  ('b1300000-0000-4000-8000-000000000001','a1300000-0000-4000-8000-000000000001','Completion Branch A','CBA','Asia/Riyadh'),
  ('b1300000-0000-4000-8000-000000000002','a1300000-0000-4000-8000-000000000002','Completion Branch B','CBB','Asia/Riyadh');

delete from public.daily_report_module_applicability
where branch_id in('b1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000002');
delete from public.daily_report_branch_lifecycle
where branch_id in('b1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000002');
insert into public.daily_report_branch_lifecycle(
  organization_id,branch_id,effective_from_business_date,active,timezone
) values
  ('a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001','2020-01-01',true,'Asia/Riyadh'),
  ('a1300000-0000-4000-8000-000000000002','b1300000-0000-4000-8000-000000000002','2020-01-01',true,'Asia/Riyadh');
insert into public.daily_report_module_applicability(
  organization_id,branch_id,module_key,requirement_basis,effective_from_business_date,required
)
select branch.organization_id,branch.id,module.module_key,
  case module.module_key when'staff_hygiene'then'eligible_operational_staff'
    when'cold_storage'then'eligible_cold_storage_equipment'
    when'oil_tracking'then'eligible_oil_tracking_fryers'else'static'end,
  '2020-01-01'::date,true
from public.branches branch
cross join pg_catalog.unnest(array[
  'kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking'
]::text[]) module(module_key)
where branch.id in('b1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000002');

select throws_ok(
  $$select * from private.incomplete_branch_tasks_completion_at(
    'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
    '2020-01-01','2020-01-02 00:59:59+00')$$,
  '55000','branch business date is not complete',
  '03:59:59 branch-local preserves the final Cold Storage slot and blocks evaluation');
select lives_ok(
  $$select * from private.incomplete_branch_tasks_completion_at(
    'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
    '2020-01-01','2020-01-02 01:00:00+00')$$,
  '04:00:00 branch-local permits evaluation');
select is((select pg_catalog.count(*)::integer from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00')),6,'exactly six module states are returned');
select is((select pg_catalog.array_agg(module_key order by module_key) from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00')),
  array['cold_storage','daily_audit','foh_opening','kitchen_opening','oil_tracking','staff_hygiene']::text[],
  'all six and only the six non-Sales-Tracking modules are returned');
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00') where module_key='kitchen_opening'),
  'incomplete','missing Kitchen Opening evidence is incomplete');
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00') where module_key='foh_opening'),
  'incomplete','missing FOH Opening evidence is incomplete');
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00') where module_key='daily_audit'),
  'incomplete','missing Daily Audit evidence is incomplete');
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00') where module_key='staff_hygiene'),
  'not_required','Staff Hygiene excludes teams with zero historically eligible staff');
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00') where module_key='cold_storage'),
  'unknown','missing historical Cold Storage equipment snapshot is unknown');
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00') where module_key='oil_tracking'),
  'unknown','missing historical fryer evidence is unknown');

insert into private.organization_manager_notification_evaluation_jobs(
  id,notification_category,organization_id,branch_id,business_date,state,attempt_count,
  lease_token,leased_by,lease_expires_at,completed_at
) values
  ('c1300000-0000-4000-8000-000000000001','incomplete_branch_tasks','a1300000-0000-4000-8000-000000000001',
    'b1300000-0000-4000-8000-000000000001','2020-01-01','running',1,
    'd1300000-0000-4000-8000-000000000001','e1300000-0000-4000-8000-000000000001',statement_timestamp()+interval '5 minutes',null),
  ('c1300000-0000-4000-8000-000000000002','incomplete_branch_tasks','a1300000-0000-4000-8000-000000000002',
    'b1300000-0000-4000-8000-000000000002','2020-01-01','running',1,
    'd1300000-0000-4000-8000-000000000002','e1300000-0000-4000-8000-000000000002',statement_timestamp()+interval '5 minutes',null),
  ('c1300000-0000-4000-8000-000000000003','sales_tracking_missing','a1300000-0000-4000-8000-000000000001',
    'b1300000-0000-4000-8000-000000000001','2020-01-02','running',1,
    'd1300000-0000-4000-8000-000000000003','e1300000-0000-4000-8000-000000000003',statement_timestamp()+interval '5 minutes',null),
  ('c1300000-0000-4000-8000-000000000004','incomplete_branch_tasks','a1300000-0000-4000-8000-000000000001',
    'b1300000-0000-4000-8000-000000000001','2020-01-03','running',1,
    'd1300000-0000-4000-8000-000000000004','e1300000-0000-4000-8000-000000000004',statement_timestamp()-interval '1 second',null),
  ('c1300000-0000-4000-8000-000000000005','incomplete_branch_tasks','a1300000-0000-4000-8000-000000000001',
    'b1300000-0000-4000-8000-000000000001','2020-01-04','completed',1,
    null,null,null,statement_timestamp()),
  ('c1300000-0000-4000-8000-000000000006','incomplete_branch_tasks','a1300000-0000-4000-8000-000000000001',
    'b1300000-0000-4000-8000-000000000001','2020-01-05','retry',1,
    null,null,null,null);
select is((select pg_catalog.count(*)::integer from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')
  where organization_id='a1300000-0000-4000-8000-000000000001'
    and branch_id='b1300000-0000-4000-8000-000000000001'),6,
  'lease-bound evaluator returns only its exact organization and branch');
select is((select pg_catalog.count(*)::integer from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000002','d1300000-0000-4000-8000-000000000002')
  where organization_id='a1300000-0000-4000-8000-000000000001'
     or branch_id='b1300000-0000-4000-8000-000000000001'),0,
  'a producer lease cannot cross organization or branch scope');
select is((select pg_catalog.min(source_completeness) from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')),
  'unknown','any required UNKNOWN module makes source_completeness unknown');
select throws_ok($$select * from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000001','ffffffff-ffff-4fff-8fff-ffffffffffff')$$,
  '55000','incomplete branch task producer lease is not active','forged lease token fails closed');
select throws_ok($$select * from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000003','d1300000-0000-4000-8000-000000000003')$$,
  '55000','incomplete branch task producer lease is not active',
  'a lease for another notification category cannot authorize this evaluator');
select throws_ok($$select * from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000004','d1300000-0000-4000-8000-000000000004')$$,
  '55000','incomplete branch task producer lease is not active','expired lease fails closed');
select throws_ok($$select * from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000005','d1300000-0000-4000-8000-000000000005')$$,
  '55000','incomplete branch task producer lease is not active','consumed lease fails closed');
select throws_ok($$select * from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000006','d1300000-0000-4000-8000-000000000006')$$,
  '55000','incomplete branch task producer lease is not active','stale retry lease fails closed');
select is((select state from public.complete_organization_manager_notification_evaluation_job(
  'c1300000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001','completed')),
  'completed','lease lifecycle explicitly consumes a completed evaluation lease');
select throws_ok($$select * from public.get_incomplete_branch_tasks_completion(
  'c1300000-0000-4000-8000-000000000001','d1300000-0000-4000-8000-000000000001')$$,
  '55000','incomplete branch task producer lease is not active','a just-consumed lease cannot be reused');

update public.daily_report_branch_lifecycle lifecycle set active=false
where lifecycle.branch_id='b1300000-0000-4000-8000-000000000001';
select is((select pg_catalog.count(*)::integer from private.incomplete_branch_tasks_completion_at(
  'a1300000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001',
  '2020-01-01','2020-01-02 01:00:00+00') where module_state='not_required'),6,
  'authoritatively closed branches return all six modules as not required');

select ok(pg_catalog.position('evidence_count>1' in pg_catalog.replace(pg_get_functiondef(
  'private.incomplete_branch_tasks_completion_at(uuid,uuid,date,timestamptz)'::regprocedure),' ',''))>0,
  'duplicate submission evidence is rejected');
select ok(pg_catalog.position('equipment.master_equipment_idisnull' in pg_catalog.replace(pg_get_functiondef(
  'private.incomplete_branch_tasks_completion_at(uuid,uuid,date,timestamptz)'::regprocedure),' ',''))>0,
  'ambiguous historical equipment snapshots are rejected');
select ok(pg_catalog.to_regclass('private.organization_manager_notification_jobs') is null
  or pg_catalog.position('organization_manager_notification_jobs' in pg_get_functiondef(
    'public.get_incomplete_branch_tasks_completion(uuid,uuid)'::regprocedure))=0,
  'evaluator is independent of the superseded Staff Hygiene job table');
select ok(not exists(select 1 from pg_constraint constraint_row
  where constraint_row.conrelid='private.organization_manager_notification_evaluation_jobs'::regclass
    and pg_get_constraintdef(constraint_row.oid) ilike '%staff_hygiene_missing%'),
  'generic job foundation does not introduce staff_hygiene_missing');

select * from finish();
rollback;
