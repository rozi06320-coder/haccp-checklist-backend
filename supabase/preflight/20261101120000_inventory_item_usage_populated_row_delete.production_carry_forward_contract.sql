-- SELECT-only Production diagnostic for the monthly Item Usage carry-forward
-- contract. This reads PostgreSQL catalogs and function definitions only; it
-- does not invoke application functions or read Inventory Items business rows.

with
candidate_functions as (
  select procedure.oid,procedure.oid::pg_catalog.regprocedure::text signature,
    pg_catalog.pg_get_function_identity_arguments(procedure.oid) identity_arguments,
    pg_catalog.pg_get_function_result(procedure.oid) result_type,
    language.lanname language_name,procedure.provolatile,procedure.prosecdef,
    procedure.proconfig,owner.rolname::text owner_name,
    pg_catalog.pg_get_functiondef(procedure.oid) definition
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  join pg_catalog.pg_language language on language.oid=procedure.prolang
  join pg_catalog.pg_roles owner on owner.oid=procedure.proowner
  where namespace.nspname='private'
    and procedure.proname='inventory_items_carry_forward_items_json'
),
expected_function as (
  select * from candidate_functions
  where oid=pg_catalog.to_regprocedure(
    'private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)'
  )
),
caller_function as (
  select procedure.oid,procedure.oid::pg_catalog.regprocedure::text signature,
    pg_catalog.pg_get_functiondef(procedure.oid) definition
  from pg_catalog.pg_proc procedure
  where procedure.oid=pg_catalog.to_regprocedure(
    'private.inventory_items_state_json(uuid,uuid,date)'
  )
),
semantic_evidence as (
  select function.*,
    (select count(*) from pg_catalog.regexp_matches(
      function.definition,$regex$source_item\.deleted_at\s+is\s+null$regex$,'gi'
    )) source_deleted_filter_count,
    function.definition ~* $regex$if\s+target_report_id\s+is\s+not\s+null\s+and\s+exists\s*\([\s\S]*?from\s+public\.inventory_item_usage_items\s+target_item[\s\S]*?where\s+target_item\.report_id\s*=\s*target_report_id[\s\S]*?return\s+'\[\]'::jsonb$regex$ target_history_blocks_reseed,
    function.definition ~* $regex$row_number\s*\(\s*\)\s+over\s*\([\s\S]*?partition\s+by[\s\S]*?lower\s*\([\s\S]*?btrim\s*\(\s*source_item\.group_name\s*\)[\s\S]*?lower\s*\([\s\S]*?btrim\s*\(\s*source_item\.item_name\s*\)$regex$ normalized_identity_partition,
    function.definition ~* $regex$where\s+source_item\.identity_rank\s*=\s*1$regex$ identity_rank_filter
  from expected_function function
),
checks(check_name,status,evidence,sort_order) as (
  select 'deployed_carry_forward_overloads','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'signature',signature,'identity_arguments',identity_arguments,
      'result_type',result_type,'language',language_name,
      'volatility',provolatile,'security_definer',prosecdef,
      'config',proconfig,'owner',owner_name
    ) order by signature)::text from candidate_functions
  ),'[]'),10

  union all
  select 'exact_four_argument_signature',case when count(*)=1 then 'PASS' else 'BLOCKED' end,
    count(*)::text||'/1 private.inventory_items_carry_forward_items_json(uuid,uuid,date,uuid)',20
  from expected_function

  union all
  select 'no_ambiguous_overloads',case when count(*)=1 then 'PASS' else 'BLOCKED' end,
    count(*)::text||' deployed overload(s)',30
  from candidate_functions

  union all
  select 'function_contract',case when count(*)=1
      and bool_and(result_type='jsonb' and language_name='plpgsql' and provolatile='s' and prosecdef)
      and bool_and(coalesce(pg_catalog.array_to_string(proconfig,','),'') like '%search_path=""%')
    then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'signature',signature,'result_type',result_type,'language',language_name,
      'stable',provolatile='s','security_definer',prosecdef,'config',proconfig
    ))::text,'[]'),40
  from expected_function

  union all
  select 'source_tombstones_excluded',case when coalesce((
      select source_deleted_filter_count>=2 from semantic_evidence
    ),false) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_build_object('source_deleted_filter_count',(
      select source_deleted_filter_count from semantic_evidence
    ))::text,50

  union all
  select 'target_history_blocks_reseed',case when coalesce((
      select target_history_blocks_reseed from semantic_evidence
    ),false) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_build_object('matched',(
      select target_history_blocks_reseed from semantic_evidence
    ))::text,60

  union all
  select 'normalized_identity_deduplication',case when coalesce((
      select normalized_identity_partition and identity_rank_filter from semantic_evidence
    ),false) then 'PASS' else 'BLOCKED' end,
    pg_catalog.jsonb_build_object(
      'normalized_partition',(select normalized_identity_partition from semantic_evidence),
      'identity_rank_filter',(select identity_rank_filter from semantic_evidence)
    )::text,70

  union all
  select 'state_projection_calls_exact_helper',case when count(*)=1 and bool_and(
      definition ~* $regex$private\.inventory_items_carry_forward_items_json\s*\(\s*ctx\.organization_id\s*,\s*ctx\.branch_id\s*,\s*selected_month\s*,\s*report\.id\s*\)$regex$
    ) then 'PASS' else 'BLOCKED' end,
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'signature',signature,'calls_exact_helper',definition ~* $regex$private\.inventory_items_carry_forward_items_json\s*\(\s*ctx\.organization_id\s*,\s*ctx\.branch_id\s*,\s*selected_month\s*,\s*report\.id\s*\)$regex$
    ))::text,'[]'),80
  from caller_function

  union all
  select 'deployed_candidate_function_bodies','INFO',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'signature',signature,'definition',definition,'definition_md5',pg_catalog.md5(definition)
    ) order by signature)::text from candidate_functions
  ),'missing'),90

  union all
  select 'carry_forward_contract_gate',case when
      (select count(*)=1 from expected_function)
      and (select count(*)=1 from candidate_functions)
      and coalesce((select source_deleted_filter_count>=2
        and target_history_blocks_reseed
        and normalized_identity_partition
        and identity_rank_filter from semantic_evidence),false)
      and coalesce((select definition ~* $regex$private\.inventory_items_carry_forward_items_json\s*\(\s*ctx\.organization_id\s*,\s*ctx\.branch_id\s*,\s*selected_month\s*,\s*report\.id\s*\)$regex$
        from caller_function),false)
    then 'PASS' else 'BLOCKED' end,
    'requires the exact checked-in helper signature, one overload, tombstone exclusion, target-history guard, normalized identity deduplication, and the exact state-projection caller',100
)
select result.check_name,result.status,result.evidence
from (
  select check_name,status,evidence,sort_order from checks
  union all
  select 'overall_readiness',
    case when not exists(select 1 from checks where status='BLOCKED') then 'PASS' else 'BLOCKED' end,
    case when not exists(select 1 from checks where status='BLOCKED')
      then 'carry-forward Production contract matches the checked-in migration'
      else 'carry-forward Production contract mismatch remains; do not apply the Item Usage migration' end,
    1000
) result
order by result.sort_order,result.check_name;
