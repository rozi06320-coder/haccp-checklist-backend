-- SELECT-only Production readiness diagnostic for
-- 20261101130000_inventory_items_client_write_privilege_hardening.sql.
-- Reads catalogs only; never changes privileges, RLS, policies, functions, or data.

with
roles as (
  select expected.role_name,role.oid,role.rolsuper,role.rolbypassrls
  from (values ('anon'::name),('authenticated'::name),('service_role'::name)) expected(role_name)
  left join pg_catalog.pg_roles role on role.rolname=expected.role_name
),
targets as (
  select expected.table_name,relation.oid,relation.relowner,relation.relacl,
    relation.relrowsecurity,relation.relforcerowsecurity
  from (values
    ('inventory_items_reports'::name),
    ('inventory_item_usage_items'::name),
    ('inventory_item_usage_day_values'::name)
  ) expected(table_name)
  left join pg_catalog.pg_namespace namespace on namespace.nspname='public'
  left join pg_catalog.pg_class relation
    on relation.relnamespace=namespace.oid and relation.relname=expected.table_name
),
client_access as (
  select target.table_name,role.role_name,role.oid role_oid,
    target.relrowsecurity,target.relforcerowsecurity,
    coalesce(role.rolsuper,false) superuser,coalesce(role.rolbypassrls,false) bypass_rls,
    coalesce(role.oid is not null and target.relowner is not null
      and pg_catalog.pg_has_role(role.oid,target.relowner,'USAGE'),false) owns_or_inherits_owner,
    coalesce(pg_catalog.has_table_privilege(role.oid,target.oid,'INSERT'),false) can_insert,
    coalesce(pg_catalog.has_table_privilege(role.oid,target.oid,'UPDATE'),false) can_update,
    coalesce(pg_catalog.has_table_privilege(role.oid,target.oid,'DELETE'),false) can_delete
  from targets target
  cross join roles role
  where role.role_name in('anon','authenticated')
),
explicit_write_acl as (
  select target.table_name,
    case when acl.grantee=0 then 'PUBLIC' else grantee.rolname::text end grantee,
    grantor.rolname::text grantor,acl.privilege_type,acl.is_grantable
  from targets target
  cross join lateral pg_catalog.aclexplode(target.relacl) acl
  left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
  left join pg_catalog.pg_roles grantor on grantor.oid=acl.grantor
  where acl.privilege_type in('INSERT','UPDATE','DELETE')
),
write_policies as (
  select target.table_name,policy.polname,policy.polcmd,policy.polpermissive,
    policy.polroles,pg_catalog.pg_get_expr(policy.polqual,policy.polrelid) using_expression,
    pg_catalog.pg_get_expr(policy.polwithcheck,policy.polrelid) check_expression
  from targets target
  join pg_catalog.pg_policy policy on policy.polrelid=target.oid
  where policy.polcmd in('*'::"char",'a'::"char",'w'::"char",'d'::"char")
),
rpc_targets(signature) as (
  values
    ('public.get_inventory_items_current_state(uuid,uuid,date)'::text),
    ('public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'),
    ('public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)'),
    ('public.delete_inventory_item_usage_item(uuid,uuid,uuid)')
),
rpc_contracts as (
  select target.signature,procedure.oid,procedure.prosecdef,procedure.proconfig,
    coalesce(pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE'),false) service_execute,
    coalesce(pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE'),false) anon_execute,
    coalesce(pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE'),false) authenticated_execute
  from rpc_targets target
  left join pg_catalog.pg_proc procedure on procedure.oid=pg_catalog.to_regprocedure(target.signature)
),
default_write_acl as (
  select owner.rolname::text owner_name,
    case when default_acl.defaclnamespace=0 then '*' else namespace.nspname end schema_name,
    case when acl.grantee=0 then 'PUBLIC' else grantee.rolname::text end grantee,
    acl.privilege_type
  from pg_catalog.pg_default_acl default_acl
  join pg_catalog.pg_roles owner on owner.oid=default_acl.defaclrole
  left join pg_catalog.pg_namespace namespace on namespace.oid=default_acl.defaclnamespace
  cross join lateral pg_catalog.aclexplode(default_acl.defaclacl) acl
  left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
  where default_acl.defaclobjtype='r'
    and (default_acl.defaclnamespace=0 or namespace.nspname='public')
    and acl.privilege_type in('INSERT','UPDATE','DELETE')
    and (acl.grantee=0 or grantee.rolname in('anon','authenticated'))
),
explicit_column_write_acl as (
  select relation.relname table_name,attribute.attname column_name,
    grantee.rolname::text grantee,grantor.rolname::text grantor,
    acl.privilege_type,acl.is_grantable
  from pg_catalog.pg_attribute attribute
  join pg_catalog.pg_class relation on relation.oid=attribute.attrelid
  join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
  cross join lateral pg_catalog.aclexplode(attribute.attacl) acl
  join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
  left join pg_catalog.pg_roles grantor on grantor.oid=acl.grantor
  where namespace.nspname='public'
    and relation.relname in('inventory_items_reports','inventory_item_usage_day_values')
    and grantee.rolname in('anon','authenticated')
    and acl.privilege_type in('INSERT','UPDATE')
),
checks(check_name,status,evidence,mandatory,sort_order) as (
  select 'required_roles',case when count(oid)=3 then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('role',role_name,'oid',oid) order by role_name)::text,true,10
  from roles

  union all
  select 'required_tables',case when count(oid)=3 then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('table',table_name,'oid',oid) order by table_name)::text,true,20
  from targets

  union all
  select 'confirmed_direct_grant_baseline',case when count(*)=12 then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(acl) order by table_name,grantee,privilege_type)::text,'[]'),true,30
  from explicit_write_acl acl
  where table_name in('inventory_items_reports','inventory_item_usage_day_values')
    and grantee in('anon','authenticated')

  union all
  select 'unrelated_item_table_has_no_client_writes',case when not exists(
    select 1 from client_access where table_name='inventory_item_usage_items' and (can_insert or can_update or can_delete)
  ) then 'PASS' else 'BLOCKED' end,
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(access) order by role_name)::text
      from client_access access where table_name='inventory_item_usage_items'),'[]'),true,40

  union all
  select 'rls_enabled_and_client_roles_non_bypass',case when bool_and(
      relrowsecurity and not superuser and not bypass_rls and not owns_or_inherits_owner
    ) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.to_jsonb(access) order by table_name,role_name)::text,true,50
  from client_access access

  union all
  select 'no_write_policies',case when count(*)=0 then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(policy) order by table_name,polname)::text,'[]'),true,60
  from write_policies policy

  union all
  select 'no_client_column_write_grants',case when count(*)=0 then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(privilege)
      order by table_name,column_name,grantee)::text,'[]'),true,70
  from explicit_column_write_acl privilege

  union all
  select 'service_role_rpc_contract',case when count(*)=4 and bool_and(
      oid is not null and prosecdef and service_execute and not anon_execute and not authenticated_execute
    ) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.to_jsonb(rpc) order by signature)::text,true,80
  from rpc_contracts rpc

  union all
  select 'relevant_default_write_acl','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(default_acl) order by owner_name,schema_name,grantee,privilege_type)::text
    from default_write_acl default_acl
  ),'[]'),false,90

  union all
  select 'remediation_scope','PASS',
    'migration revokes only INSERT/UPDATE/DELETE on inventory_items_reports and inventory_item_usage_day_values from anon/authenticated',true,100
),
results as (
  select check_name,status,evidence,sort_order from checks
  union all
  select 'overall_readiness',case when not exists(
      select 1 from checks where mandatory and status<>'PASS'
    ) then 'PASS' else 'BLOCKED' end,
    case when not exists(select 1 from checks where mandatory and status<>'PASS')
      then 'least-privilege remediation is eligible for transactional preflight'
      else 'least-privilege prerequisites differ; do not execute remediation' end,1000
)
select check_name,status,evidence
from results
order by sort_order,check_name;
