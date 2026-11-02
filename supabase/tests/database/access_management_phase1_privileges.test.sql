begin;
select plan(18);

-- 1. Check functions exist
select has_function('public', 'list_internal_admin_access_assignments', array['uuid', 'uuid', 'uuid', 'text', 'text'], 'list_internal_admin_access_assignments function exists');
select has_function('public', 'grant_internal_admin_training_supervisor', array['uuid', 'uuid', 'uuid', 'uuid[]'], 'grant_internal_admin_training_supervisor function exists');
select has_function('public', 'suspend_internal_admin_training_supervisor', array['uuid', 'uuid', 'uuid'], 'suspend_internal_admin_training_supervisor function exists');
select has_function('public', 'reactivate_internal_admin_training_supervisor', array['uuid', 'uuid', 'uuid', 'uuid[]'], 'reactivate_internal_admin_training_supervisor function exists');
select has_function('public', 'revoke_internal_admin_training_supervisor', array['uuid', 'uuid', 'uuid'], 'revoke_internal_admin_training_supervisor function exists');
select has_function('public', 'reassign_internal_admin_training_supervisor', array['uuid', 'uuid', 'uuid', 'uuid[]'], 'reassign_internal_admin_training_supervisor function exists');
select has_function('public', 'establish_training_supervisor_session', array['uuid'], 'establish_training_supervisor_session function exists');
select has_function('public', 'get_training_supervisor_context', array['uuid', 'uuid'], 'get_training_supervisor_context function exists');

-- 2. Verify SECURITY DEFINER & empty search_path
select ok(prosecdef, 'list_internal_admin_access_assignments is SECURITY DEFINER')
from pg_proc where proname = 'list_internal_admin_access_assignments' and pronamespace = 'public'::regnamespace;

select is(proconfig, array['search_path=""'], 'list_internal_admin_access_assignments has empty search_path')
from pg_proc where proname = 'list_internal_admin_access_assignments' and pronamespace = 'public'::regnamespace;

-- 3. Verify service-role-only permissions
select ok(has_function_privilege('service_role', 'public.list_internal_admin_access_assignments(uuid,uuid,uuid,text,text)', 'EXECUTE'),
  'service_role can execute list_internal_admin_access_assignments');

select ok(not has_function_privilege('public', 'public.list_internal_admin_access_assignments(uuid,uuid,uuid,text,text)', 'EXECUTE'),
  'public cannot execute list_internal_admin_access_assignments');

select ok(not has_function_privilege('anon', 'public.list_internal_admin_access_assignments(uuid,uuid,uuid,text,text)', 'EXECUTE'),
  'anon cannot execute list_internal_admin_access_assignments');

select ok(not has_function_privilege('authenticated', 'public.list_internal_admin_access_assignments(uuid,uuid,uuid,text,text)', 'EXECUTE'),
  'authenticated cannot execute list_internal_admin_access_assignments');

select ok(not has_function_privilege('authenticated', 'public.establish_training_supervisor_session(uuid)', 'EXECUTE'),
  'authenticated cannot execute establish_training_supervisor_session');

-- 4. Check legacy get_training_account_context is revoked
select ok(not has_function_privilege('public', 'public.get_training_account_context(uuid)', 'EXECUTE'),
  'legacy get_training_account_context revoked from public');

select ok(not has_function_privilege('service_role', 'public.get_training_account_context(uuid)', 'EXECUTE'),
  'legacy get_training_account_context revoked from service_role');

-- 5. Check additive columns
select columns_are('public', 'training_memberships',
  array['organization_id', 'user_id', 'account_name', 'active', 'created_by', 'updated_by', 'created_at', 'updated_at', 'training_role', 'credential_version'],
  'training_memberships has training_role and credential_version columns');

select finish();
rollback;
