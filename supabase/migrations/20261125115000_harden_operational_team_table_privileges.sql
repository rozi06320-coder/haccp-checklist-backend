-- 20261125115000_harden_operational_team_table_privileges.sql
-- Phase 4D: Harden direct table and column privileges on operational team and
-- audit log tables without modifying unrelated tables, default privileges, or RLS policies.

begin;

-- 1. Revoke all table privileges from public, anon, and authenticated on the 4 target tables
revoke all on table
  public.account_management_audit_logs,
  public.branch_operational_teams,
  public.branch_operational_team_supervisors,
  public.branch_supervisor_teams
  from public, anon, authenticated;

-- 2. Revoke any explicit column-level privileges from public, anon, and authenticated
do $$
declare
  col_grant record;
begin
  for col_grant in
    select distinct table_schema, table_name, column_name, grantee, privilege_type
    from information_schema.column_privileges
    where table_schema = 'public'
      and table_name in (
        'account_management_audit_logs',
        'branch_operational_teams',
        'branch_operational_team_supervisors',
        'branch_supervisor_teams'
      )
      and grantee in ('PUBLIC', 'anon', 'authenticated')
  loop
    execute format(
      'revoke %s (%I) on table %I.%I from %s',
      col_grant.privilege_type,
      col_grant.column_name,
      col_grant.table_schema,
      col_grant.table_name,
      case when col_grant.grantee = 'PUBLIC' then 'public' else quote_ident(col_grant.grantee) end
    );
  end loop;
end;
$$;

-- 3. Preserve authenticated SELECT (enforced by existing RLS policies)
grant select on table
  public.account_management_audit_logs,
  public.branch_operational_teams,
  public.branch_operational_team_supervisors,
  public.branch_supervisor_teams
  to authenticated;

commit;
