begin;
select plan(7);

-- 1. Check function exists
select has_function(
  'public',
  'transition_internal_admin_access_role',
  array['uuid', 'uuid', 'uuid', 'text', 'text', 'uuid', 'uuid[]', 'jsonb'],
  'transition_internal_admin_access_role function exists with expected signature'
);

-- 2. Verify SECURITY DEFINER & empty search_path
select ok(prosecdef, 'transition_internal_admin_access_role is SECURITY DEFINER')
from pg_proc
where proname = 'transition_internal_admin_access_role'
  and pronamespace = 'public'::regnamespace;

select is(proconfig, array['search_path=""'], 'transition_internal_admin_access_role has empty search_path')
from pg_proc
where proname = 'transition_internal_admin_access_role'
  and pronamespace = 'public'::regnamespace;

-- 3. Verify service-role-only execution permissions
select ok(
  has_function_privilege('service_role', 'public.transition_internal_admin_access_role(uuid,uuid,uuid,text,text,uuid,uuid[],jsonb)', 'EXECUTE'),
  'service_role can execute transition_internal_admin_access_role'
);

select ok(
  not has_function_privilege('public', 'public.transition_internal_admin_access_role(uuid,uuid,uuid,text,text,uuid,uuid[],jsonb)', 'EXECUTE'),
  'public cannot execute transition_internal_admin_access_role'
);

select ok(
  not has_function_privilege('anon', 'public.transition_internal_admin_access_role(uuid,uuid,uuid,text,text,uuid,uuid[],jsonb)', 'EXECUTE'),
  'anon cannot execute transition_internal_admin_access_role'
);

select ok(
  not has_function_privilege('authenticated', 'public.transition_internal_admin_access_role(uuid,uuid,uuid,text,text,uuid,uuid[],jsonb)', 'EXECUTE'),
  'authenticated cannot execute transition_internal_admin_access_role'
);

select finish();
rollback;
