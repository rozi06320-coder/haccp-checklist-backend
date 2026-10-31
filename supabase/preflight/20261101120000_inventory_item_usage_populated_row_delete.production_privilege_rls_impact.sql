-- SELECT-only Production diagnostic for direct Inventory Items table-write
-- privileges. This reads catalogs and function definitions only; it does not
-- read business rows or change privileges, policies, RLS, or data.

with
target_names(table_name) as (
  values
    ('inventory_items_reports'::name),
    ('inventory_item_usage_items'::name),
    ('inventory_item_usage_day_values'::name)
),
client_roles(role_name,role_oid,role_superuser,role_bypass_rls) as (
  select expected.role_name,role.oid,coalesce(role.rolsuper,false),coalesce(role.rolbypassrls,false)
  from (values ('anon'::name),('authenticated'::name)) expected(role_name)
  left join pg_catalog.pg_roles role on role.rolname=expected.role_name
),
target_relations as (
  select target.table_name,relation.oid,relation.relowner,relation.relacl,
    relation.relrowsecurity,relation.relforcerowsecurity,namespace.oid namespace_oid
  from target_names target
  left join pg_catalog.pg_namespace namespace on namespace.nspname='public'
  left join pg_catalog.pg_class relation
    on relation.relnamespace=namespace.oid
   and relation.relname=target.table_name
   and relation.relkind in('r','p')
),
role_table_access as (
  select relation.table_name,relation.oid relation_oid,relation.relrowsecurity,
    relation.relforcerowsecurity,role.role_name,role.role_oid,
    role.role_superuser,role.role_bypass_rls,
    coalesce(role.role_oid is not null and relation.relowner is not null
      and pg_catalog.pg_has_role(role.role_oid,relation.relowner,'USAGE'),false) owns_or_inherits_owner,
    coalesce(pg_catalog.has_table_privilege(role.role_oid,relation.oid,'INSERT'),false) effective_insert,
    coalesce(pg_catalog.has_table_privilege(role.role_oid,relation.oid,'UPDATE'),false) effective_update,
    coalesce(pg_catalog.has_table_privilege(role.role_oid,relation.oid,'DELETE'),false) effective_delete,
    coalesce((
      select pg_catalog.array_agg(parent.rolname order by parent.rolname)
      from pg_catalog.pg_roles parent
      where role.role_oid is not null
        and parent.oid<>role.role_oid
        and pg_catalog.pg_has_role(role.role_oid,parent.oid,'USAGE')
        and (
          pg_catalog.has_table_privilege(parent.oid,relation.oid,'INSERT')
          or pg_catalog.has_table_privilege(parent.oid,relation.oid,'UPDATE')
          or pg_catalog.has_table_privilege(parent.oid,relation.oid,'DELETE')
        )
    ),'{}'::name[]) inherited_write_roles
  from target_relations relation
  cross join client_roles role
),
current_acl_entries as (
  select relation.table_name,
    case when acl.grantee=0 then 'PUBLIC' else grantee.rolname::text end grantee,
    grantor.rolname::text grantor,acl.privilege_type,acl.is_grantable
  from target_relations relation
  cross join lateral pg_catalog.aclexplode(relation.relacl) acl
  left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
  left join pg_catalog.pg_roles grantor on grantor.oid=acl.grantor
  where acl.privilege_type in('INSERT','UPDATE','DELETE')
    and (
      acl.grantee=0
      or acl.grantee in(select role_oid from client_roles where role_oid is not null)
      or (acl.grantee<>0 and exists(
        select 1 from client_roles role
        where role.role_oid is not null
          and pg_catalog.pg_has_role(role.role_oid,acl.grantee,'USAGE')
      ))
    )
),
relevant_default_acl_entries as (
  select owner.rolname::text default_owner,
    case when default_acl.defaclnamespace=0 then '*' else namespace.nspname end schema_name,
    case when acl.grantee=0 then 'PUBLIC' else grantee.rolname::text end grantee,
    grantor.rolname::text grantor,acl.privilege_type,acl.is_grantable
  from pg_catalog.pg_default_acl default_acl
  join pg_catalog.pg_roles owner on owner.oid=default_acl.defaclrole
  left join pg_catalog.pg_namespace namespace on namespace.oid=default_acl.defaclnamespace
  cross join lateral pg_catalog.aclexplode(default_acl.defaclacl) acl
  left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
  left join pg_catalog.pg_roles grantor on grantor.oid=acl.grantor
  where default_acl.defaclobjtype='r'
    and (default_acl.defaclnamespace=0 or namespace.nspname='public')
    and acl.privilege_type in('INSERT','UPDATE','DELETE')
    and (
      acl.grantee=0
      or acl.grantee in(select role_oid from client_roles where role_oid is not null)
      or (acl.grantee<>0 and exists(
        select 1 from client_roles role
        where role.role_oid is not null
          and pg_catalog.pg_has_role(role.role_oid,acl.grantee,'USAGE')
      ))
    )
),
policy_details as (
  select relation.table_name,policy.polname,
    case policy.polcmd when '*' then 'ALL' when 'r' then 'SELECT'
      when 'a' then 'INSERT' when 'w' then 'UPDATE' when 'd' then 'DELETE' end command,
    policy.polpermissive,
    coalesce((
      select pg_catalog.array_agg(case when policy_role=0 then 'PUBLIC' else role.rolname::text end order by policy_role)
      from pg_catalog.unnest(policy.polroles) policy_role
      left join pg_catalog.pg_roles role on role.oid=policy_role
    ),'{}'::text[]) policy_roles,
    pg_catalog.pg_get_expr(policy.polqual,policy.polrelid) using_expression,
    pg_catalog.pg_get_expr(policy.polwithcheck,policy.polrelid) check_expression,
    policy.polcmd,policy.polroles
  from target_relations relation
  join pg_catalog.pg_policy policy on policy.polrelid=relation.oid
),
trigger_details as (
  select relation.table_name,trigger.tgname,
    pg_catalog.pg_get_triggerdef(trigger.oid) trigger_definition,
    trigger.tgfoid::pg_catalog.regprocedure::text trigger_function
  from target_relations relation
  join pg_catalog.pg_trigger trigger on trigger.tgrelid=relation.oid
  where not trigger.tgisinternal
),
operations(operation,policy_command) as (
  values ('INSERT'::text,'a'::"char"),('UPDATE'::text,'w'::"char"),('DELETE'::text,'d'::"char")
),
role_operation_paths as (
  select access.table_name,access.role_name,operation.operation,
    access.relrowsecurity,access.relforcerowsecurity,
    access.role_superuser,access.role_bypass_rls,access.owns_or_inherits_owner,
    case operation.operation when 'INSERT' then access.effective_insert
      when 'UPDATE' then access.effective_update else access.effective_delete end effective_privilege,
    coalesce((
      select pg_catalog.array_agg(policy.polname order by policy.polname)
      from policy_details policy
      where policy.table_name=access.table_name
        and policy.polpermissive
        and policy.polcmd in('*'::"char",operation.policy_command)
        and exists(
          select 1 from pg_catalog.unnest(policy.polroles) policy_role
          where policy_role=0
            or policy_role=access.role_oid
            or (policy_role<>0 and access.role_oid is not null
              and pg_catalog.pg_has_role(access.role_oid,policy_role,'USAGE'))
        )
    ),'{}'::name[]) applicable_permissive_policies
  from role_table_access access
  cross join operations operation
),
routine_definitions as (
  select procedure.oid,procedure.oid::pg_catalog.regprocedure::text signature,
    namespace.nspname schema_name,procedure.prosecdef,
    pg_catalog.pg_get_functiondef(procedure.oid) definition
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname in('public','private') and procedure.prokind='f'
),
sanitized_routines as (
  select routine.*,
    pg_catalog.regexp_replace(
      pg_catalog.regexp_replace(
        pg_catalog.regexp_replace(routine.definition,$regex$--[^\r\n]*$regex$,' ','g'),
        $regex$/\*.*?\*/$regex$,' ','gs'
      ),
      $regex$'(?:''|[^'])*'$regex$,' ','g'
    ) executable_definition
  from routine_definitions routine
),
routine_writers as (
  select * from sanitized_routines
  where executable_definition ~* $regex$(insert\s+into|update|delete\s+from)\s+public\.inventory_(items_reports|item_usage_items|item_usage_day_values)\M$regex$
),
routine_client_access as (
  select routine.signature,routine.schema_name,routine.prosecdef,role.role_name,
    coalesce(pg_catalog.has_function_privilege(role.role_oid,routine.oid,'EXECUTE'),false) effective_execute,
    routine.executable_definition
  from routine_writers routine
  cross join client_roles role
),
checks(check_name,status,evidence,sort_order) as (
  select 'target_tables_present',case when count(oid)=3 then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('table',table_name,'oid',oid) order by table_name)::text,10
  from target_relations

  union all
  select 'current_write_acl_grantors','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(acl) order by table_name,grantee,privilege_type)::text
    from current_acl_entries acl
  ),'[]'),20

  union all
  select 'default_acl_write_sources','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(acl) order by default_owner,schema_name,grantee,privilege_type)::text
    from relevant_default_acl_entries acl
  ),'[]'),30

  union all
  select 'client_role_attributes',case when bool_and(role_oid is not null and not role_superuser and not role_bypass_rls) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'role',role_name,'oid',role_oid,'superuser',role_superuser,'bypass_rls',role_bypass_rls
    ) order by role_name)::text,40
  from client_roles

  union all
  select 'rls_and_effective_write_privileges',case when bool_and(relrowsecurity) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'table',table_name,'role',role_name,'rls_enabled',relrowsecurity,'force_rls',relforcerowsecurity,
      'owns_or_inherits_owner',owns_or_inherits_owner,
      'effective_insert',effective_insert,'effective_update',effective_update,'effective_delete',effective_delete,
      'inherited_write_roles',inherited_write_roles
    ) order by table_name,role_name)::text,50
  from role_table_access

  union all
  select 'applicable_rls_write_policies','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'table',table_name,'policy',polname,'command',command,'permissive',polpermissive,
      'roles',policy_roles,'using',using_expression,'with_check',check_expression
    ) order by table_name,polname)::text
    from policy_details where command in('ALL','INSERT','UPDATE','DELETE')
  ),'[]'),60

  union all
  select 'write_guard_triggers','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'table',table_name,'trigger',tgname,'definition',trigger_definition,
      'function',trigger_function
    ) order by table_name,tgname)::text
    from trigger_details
  ),'[]'),65

  union all
  select 'effective_browser_mutation_path',case when not exists(
    select 1 from role_operation_paths path
    where path.effective_privilege and (
      not path.relrowsecurity or path.role_superuser or path.role_bypass_rls
      or path.owns_or_inherits_owner
      or pg_catalog.cardinality(path.applicable_permissive_policies)>0
    )
  ) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'table',table_name,'role',role_name,'operation',operation,
      'effective_privilege',effective_privilege,'rls_enabled',relrowsecurity,
      'superuser',role_superuser,'bypass_rls',role_bypass_rls,
      'owns_or_inherits_owner',owns_or_inherits_owner,
      'applicable_permissive_policies',applicable_permissive_policies
    ) order by table_name,role_name,operation)::text,70
  from role_operation_paths

  union all
  select 'catalog_discovered_writer_routines','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'signature',signature,'schema',schema_name,'security_definer',prosecdef,
      'role',role_name,'effective_execute',effective_execute
    ) order by signature,role_name)::text
    from routine_client_access
  ),'[]'),80

  union all
  select 'invoker_routine_dependency_on_table_grants',case when not exists(
    select 1 from routine_client_access
    where effective_execute and not prosecdef
  ) then 'PASS' else 'BLOCKED' end,
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'signature',signature,'role',role_name
    ) order by signature,role_name)::text from routine_client_access
      where effective_execute and not prosecdef),'[]'),90

  union all
  select 'direct_client_write_grants_remediation_gate',case when
      exists(select 1 from current_acl_entries)
      or exists(select 1 from role_table_access where effective_insert or effective_update or effective_delete)
    then 'BLOCKED' else 'PASS' end,
    case when exists(select 1 from current_acl_entries)
      then 'direct/inherited client table-write ACLs remain; do not apply the Item Usage migration'
      else 'no effective client table-write privileges detected' end,100
)
select result.check_name,result.status,result.evidence
from (
  select check_name,status,evidence,sort_order from checks
  union all
  select 'overall_readiness',
    case when not exists(select 1 from checks where status='BLOCKED') then 'PASS' else 'BLOCKED' end,
    case when not exists(select 1 from checks where status='BLOCKED')
      then 'catalog checks permit a separately approved least-privilege remediation'
      else 'privilege/RLS impact remains unresolved; do not apply the Item Usage migration' end,
    1000
) result
order by result.sort_order,result.check_name;
