begin;
select plan(19);

select has_function('public','produce_organization_manager_notification_evaluation_job','Phase 2B producer RPC exists');
select ok(to_regprocedure('public.produce_organization_manager_notification_evaluation_job(uuid,uuid)') is not null,
  'producer signature is lease-bound');
select ok((select p.prosecdef from pg_proc p where p.oid=to_regprocedure('public.produce_organization_manager_notification_evaluation_job(uuid,uuid)')),
  'producer is SECURITY DEFINER');
select ok((select exists(select 1 from pg_proc p where p.oid=to_regprocedure('public.produce_organization_manager_notification_evaluation_job(uuid,uuid)') and 'search_path=""'=any(coalesce(p.proconfig,'{}')))),
  'producer has an empty stored search_path');
select is(has_function_privilege('service_role','public.produce_organization_manager_notification_evaluation_job(uuid,uuid)','execute'),true,
  'service_role can execute producer');
select is(has_function_privilege('anon','public.produce_organization_manager_notification_evaluation_job(uuid,uuid)','execute'),false,
  'anon cannot execute producer');
select is(has_function_privilege('authenticated','public.produce_organization_manager_notification_evaluation_job(uuid,uuid)','execute'),false,
  'authenticated cannot execute producer');

select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)'))
  like '%report_state is distinct from ''submitted''%', 'submitted linkage is validated');
select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)'))
  not like '%report_review_status=''needs_review'' then return ''unknown''%', 'Needs Review does not make valid submitted evidence missing');
select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)'))
  like '%''needs_review''%', 'Needs Review is accepted for valid submitted evidence');
select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)'))
  like '%correction_state is distinct from ''draft''%', 'correction linkage is validated');
select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)'))
  like '%return ''missing''%', 'missing evidence has an explicit state');
select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)'))
  like '%return ''unknown''%', 'malformed evidence has an unknown state');

select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_maintenance_issue_ids(uuid,uuid,date,timestamptz)'))
  like '%maintenance_issue_updates%', 'maintenance uses historical updates');
select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_maintenance_issue_ids(uuid,uuid,date,timestamptz)'))
  like '%location_scope=''branch''%', 'office maintenance is excluded');
select ok(pg_get_functiondef(to_regprocedure('private.organization_manager_maintenance_issue_ids(uuid,uuid,date,timestamptz)'))
  like '%created_at<=close_at%', 'maintenance is evaluated as of cutoff');

select ok(pg_get_functiondef(to_regprocedure('public.produce_organization_manager_notification_evaluation_job(uuid,uuid)'))
  like '%lease_token is distinct from p_lease_token%', 'forged leases are rejected');
select ok(pg_get_functiondef(to_regprocedure('public.produce_organization_manager_notification_evaluation_job(uuid,uuid)'))
  like '%create_organization_manager_category_notification%', 'category insertion uses Phase 2A RPC');
select ok(pg_get_functiondef(to_regprocedure('public.produce_organization_manager_notification_evaluation_job(uuid,uuid)'))
  not like '%organization_manager_push_deliveries%', 'producer does not insert push rows');

select * from finish();
rollback;
