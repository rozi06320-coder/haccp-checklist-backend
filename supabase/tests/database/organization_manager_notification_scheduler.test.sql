begin;
select plan(8);

select has_function('public', 'enqueue_due_organization_manager_notification_evaluation_jobs',
  array['integer', 'timestamp with time zone'],
  'enqueue_due_organization_manager_notification_evaluation_jobs function exists');

select is((select pg_get_function_arguments(
  'public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)'::regprocedure)),
  'p_catch_up_days integer DEFAULT 3, p_as_of timestamp with time zone DEFAULT NULL::timestamp with time zone',
  'function arguments have correct defaults');

select ok((select procedure.prosecdef from pg_proc procedure
  where procedure.oid = 'public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)'::regprocedure),
  'function is SECURITY DEFINER');

select ok((select coalesce(array_to_string(procedure.proconfig, ','), '') like '%search_path=""%'
  from pg_proc procedure
  where procedure.oid = 'public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)'::regprocedure),
  'function has empty search_path');

select ok(has_function_privilege('service_role',
  'public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)', 'execute'),
  'service_role can execute scheduler enqueue function');

select ok(not has_function_privilege('public',
  'public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)', 'execute'),
  'public cannot execute scheduler enqueue function');

select ok(not has_function_privilege('anon',
  'public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)', 'execute'),
  'anon cannot execute scheduler enqueue function');

select ok(not has_function_privilege('authenticated',
  'public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)', 'execute'),
  'authenticated cannot execute scheduler enqueue function');

select * from finish();
rollback;
