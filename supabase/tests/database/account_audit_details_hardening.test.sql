begin;

select plan(18);

insert into public.organizations (id, name, slug)
values (
  '22000000-0000-4000-8000-000000000001',
  'Phase 2C Audit Details Organization',
  'phase-2c-audit-details-organization'
);

select lives_ok(
  $$
    insert into public.account_management_audit_logs (
      id,
      organization_id,
      action,
      details
    )
    values (
      '42000000-0000-4000-8000-000000000001',
      '22000000-0000-4000-8000-000000000001',
      'user_created',
      '{"role":"staff","source":{"channel":"management_api"},"changed_fields":["full_name"]}'
    )
  $$,
  'Valid non-sensitive structured audit details remain accepted'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('22000000-0000-4000-8000-000000000001', 'user_created', '{"password_hash":"forbidden"}')$$,
  '23514',
  null,
  'password_hash detail key is rejected'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('22000000-0000-4000-8000-000000000001', 'user_created', '{"newPassword":"forbidden"}')$$,
  '23514',
  null,
  'newPassword detail key is rejected'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('22000000-0000-4000-8000-000000000001', 'user_created', '{"nested":{"client_secret":"forbidden"}}')$$,
  '23514',
  null,
  'nested client_secret detail key is rejected'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('22000000-0000-4000-8000-000000000001', 'user_created', '{"auth_access_token_expires_at":"forbidden"}')$$,
  '23514',
  null,
  'access_token-bearing detail key is rejected'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('22000000-0000-4000-8000-000000000001', 'user_created', '{"items":[{"previous-refresh-token":"forbidden"}]}')$$,
  '23514',
  null,
  'nested refresh_token-bearing detail key is rejected'
);

select throws_ok(
  $$insert into public.account_management_audit_logs (organization_id, action, details) values ('22000000-0000-4000-8000-000000000001', 'user_created', '{"service_role_key":"forbidden"}')$$,
  '23514',
  null,
  'service_role-bearing detail key is rejected'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'private.account_audit_details_are_safe(jsonb)',
    'execute'
  ),
  'Authenticated users still cannot execute the audit detail helper'
);

select is(
  (
    select prosecdef
    from pg_proc
    join pg_namespace on pg_namespace.oid = pg_proc.pronamespace
    where pg_namespace.nspname = 'private'
      and pg_proc.proname = 'account_audit_details_are_safe'
  ),
  false,
  'Audit detail validation remains SECURITY INVOKER'
);

select ok(
  (
    select relrowsecurity
    from pg_class
    join pg_namespace on pg_namespace.oid = pg_class.relnamespace
    where pg_namespace.nspname = 'public'
      and pg_class.relname = 'account_management_audit_logs'
  ),
  'Audit logs have RLS enabled'
);

select is(
  (
    select count(*)
    from pg_policies
    where schemaname = 'public'
      and tablename = 'account_management_audit_logs'
      and policyname = 'account_management_audit_logs_select_organization_manager'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and qual = 'private.is_organization_manager(organization_id)'
  ),
  1::bigint,
  'Audit logs expose exactly the organization-manager SELECT policy'
);

select ok(
  not has_table_privilege('anon', 'public.account_management_audit_logs', 'select')
  and has_table_privilege('authenticated', 'public.account_management_audit_logs', 'select')
  and not has_table_privilege('authenticated', 'public.account_management_audit_logs', 'insert')
  and not has_table_privilege('authenticated', 'public.account_management_audit_logs', 'update')
  and not has_table_privilege('authenticated', 'public.account_management_audit_logs', 'delete')
  and has_table_privilege('service_role', 'public.account_management_audit_logs', 'insert')
  and not has_table_privilege('service_role', 'public.account_management_audit_logs', 'update')
  and not has_table_privilege('service_role', 'public.account_management_audit_logs', 'delete'),
  'Audit table grants preserve read-only application access and append-only trusted access'
);

select is(
  (
    select count(*)
    from pg_constraint
    where conrelid = 'public.account_management_audit_logs'::regclass
      and conname in (
        'account_management_audit_logs_action_check',
        'account_management_audit_logs_details_object_check',
        'account_management_audit_logs_details_safe_check',
        'account_management_audit_logs_branch_organization_fkey'
      )
  ),
  4::bigint,
  'Required audit action, detail, and branch-organization constraints exist'
);

select ok(
  (
    select confdeltype = 'r'
    from pg_constraint
    where conrelid = 'public.account_management_audit_logs'::regclass
      and conname = 'account_management_audit_logs_organization_id_fkey'
  )
  and (
    select bool_and(confdeltype = 'n')
    from pg_constraint
    where conrelid = 'public.account_management_audit_logs'::regclass
      and conname in (
        'account_management_audit_logs_actor_user_id_fkey',
        'account_management_audit_logs_target_user_id_fkey',
        'account_management_audit_logs_branch_organization_fkey'
      )
  ),
  'Foreign keys retain organizations and null deleted actor, target, or branch references'
);

select is(
  (
    select count(*)
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'account_management_audit_logs'
      and indexname in (
        'account_management_audit_logs_organization_created_at_idx',
        'account_management_audit_logs_target_user_id_idx',
        'account_management_audit_logs_branch_id_idx'
      )
  ),
  3::bigint,
  'Organization/date, target-user, and branch audit indexes exist'
);

select ok(
  has_column_privilege('authenticated', 'public.profiles', 'full_name', 'update')
  and not has_column_privilege('authenticated', 'public.profiles', 'must_change_password', 'update')
  and not has_column_privilege('authenticated', 'public.profiles', 'disabled_at', 'update'),
  'Authenticated profile UPDATE privilege remains limited to full_name'
);

select is(
  (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'profiles'
      and (
        (
          column_name = 'must_change_password'
          and is_nullable = 'NO'
          and column_default = 'false'
        )
        or (
          column_name = 'disabled_at'
          and is_nullable = 'YES'
        )
      )
  ),
  2::bigint,
  'Profile lifecycle columns retain the required nullability and default'
);

select ok(
  not exists (
    select 1
    from pg_proc
    join pg_namespace on pg_namespace.oid = pg_proc.pronamespace
    where pg_namespace.nspname = 'public'
      and pg_proc.proname like '%password%'
      and (
        has_function_privilege('public', pg_proc.oid, 'execute')
        or has_function_privilege('anon', pg_proc.oid, 'execute')
        or has_function_privilege('authenticated', pg_proc.oid, 'execute')
      )
  ),
  'No public client-callable password or temporary-flag RPC exists'
);

select * from finish();

rollback;
