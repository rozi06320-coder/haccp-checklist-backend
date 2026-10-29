create extension if not exists pgtap;
begin;

select plan(10);

select has_function(
  'public',
  'get_daily_report_staff_hygiene_applicability',
  array['uuid','uuid','date','uuid','uuid']
);
select ok(
  has_function_privilege(
    'service_role',
    'public.get_daily_report_staff_hygiene_applicability(uuid,uuid,date,uuid,uuid)',
    'execute'
  ),
  'service_role can execute Staff Hygiene applicability RPC'
);
select ok(not has_function_privilege(
  'anon',
  'public.get_daily_report_staff_hygiene_applicability(uuid,uuid,date,uuid,uuid)',
  'execute'
), 'anon cannot execute Staff Hygiene applicability RPC');
select ok(not has_function_privilege(
  'authenticated',
  'public.get_daily_report_staff_hygiene_applicability(uuid,uuid,date,uuid,uuid)',
  'execute'
), 'authenticated cannot execute Staff Hygiene applicability RPC');
select ok((select prosecdef from pg_proc where oid =
  'public.get_daily_report_staff_hygiene_applicability(uuid,uuid,date,uuid,uuid)'::regprocedure),
  'Staff Hygiene applicability RPC is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid =
  'public.get_daily_report_staff_hygiene_applicability(uuid,uuid,date,uuid,uuid)'::regprocedure),
  'Staff Hygiene applicability RPC has an empty search_path');
select throws_ok(
  $$select * from public.get_daily_report_staff_hygiene_applicability(null,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-10-30')$$,
  '42501', null, 'anonymous actor without a valid lease is rejected'
);
select throws_ok(
  $$select * from public.get_daily_report_staff_hygiene_applicability(null,'00000000-0000-4000-8000-000000000001',null)$$,
  '22023', null, 'null business date is rejected'
);
select ok((select relrowsecurity from pg_class where oid = 'public.branch_operational_teams'::regclass),
  'operational team RLS remains enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.operational_staff_assignments'::regclass),
  'operational assignment RLS remains enabled');

select * from finish();
rollback;
