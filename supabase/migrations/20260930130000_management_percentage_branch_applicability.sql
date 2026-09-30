alter table public.branches
  add column if not exists sales_tracking_percentage_included boolean not null default true,
  add column if not exists oil_tracking_percentage_included boolean not null default true;

update public.branches
set sales_tracking_percentage_included = false,
    oil_tracking_percentage_included = false
where id in (
  '03acf21e-fbca-48d0-955f-5e783d43c23e'::uuid,
  '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid
);

do $management_percentage_applicability$
declare
  definition text;
  previous_definition text;
  match_count integer;
begin
  select pg_catalog.pg_get_functiondef('public.get_phase4a_management_overview(uuid,uuid)'::regprocedure)
  into definition;

  select pg_catalog.count(*) into match_count
  from pg_catalog.regexp_matches(
    definition,
    $pattern$select[[:space:]]+branch\.id,[[:space:]]*branch\.name,[[:space:]]*branch\.code,[[:space:]]*branch\.timezone,[[:space:]]+private\.phase4a_business_date\(branch\.timezone\)[[:space:]]+business_date,$pattern$,
    'g'
  );
  if match_count <> 1 then
    raise exception 'management overview active branch projection changed' using errcode = '22023';
  end if;
  definition := pg_catalog.regexp_replace(
    definition,
    $pattern$select[[:space:]]+branch\.id,[[:space:]]*branch\.name,[[:space:]]*branch\.code,[[:space:]]*branch\.timezone,[[:space:]]+private\.phase4a_business_date\(branch\.timezone\)[[:space:]]+business_date,$pattern$,
    $replacement$select branch.id, branch.name, branch.code, branch.timezone,
      branch.sales_tracking_percentage_included,
      branch.oil_tracking_percentage_included,
      private.phase4a_business_date(branch.timezone) business_date,$replacement$
  );

  select pg_catalog.count(*) into match_count
  from pg_catalog.regexp_matches(definition, $pattern$branch_rows[[:space:]]+as[[:space:]]+materialized[[:space:]]*\($pattern$, 'g');
  if match_count <> 1 then
    raise exception 'management overview branch rows changed' using errcode = '22023';
  end if;
  definition := pg_catalog.regexp_replace(
    definition,
    $pattern$branch_rows[[:space:]]+as[[:space:]]+materialized[[:space:]]*\($pattern$,
    $replacement$branch_percentage_candidates as materialized (
    select metric.*,
      case
        when metric.checklist_type = 'oil_tracking' then branch.oil_tracking_percentage_included
        when metric.checklist_type = 'sales_tracking' then branch.sales_tracking_percentage_included
        else true
      end percentage_included
    from branch_checklist_metrics metric
    join active_branches branch on branch.id = metric.branch_id
  ),
  branch_percentage_metrics as materialized (
    select branch.id branch_id,
      coalesce(pg_catalog.sum(metric.expected_checks) filter (where metric.percentage_included), 0)::bigint expected_checks,
      coalesce(pg_catalog.sum(metric.answered_checks) filter (where metric.percentage_included), 0)::bigint answered_checks,
      coalesce(pg_catalog.sum(metric.compliant_checks) filter (where metric.percentage_included), 0)::bigint compliant_checks
    from active_branches branch
    left join branch_percentage_candidates metric on metric.branch_id = branch.id
    group by branch.id
  ),
  branch_rows as materialized ($replacement$
  );

  previous_definition := definition;
  definition := pg_catalog.replace(
    definition,
    '(metric.expected_checks - metric.answered_checks)::bigint pending_checks,',
    '(metric.expected_checks - metric.answered_checks)::bigint pending_checks,
      pg_catalog.max(percentage_metric.expected_checks) percentage_expected_checks,
      pg_catalog.max(percentage_metric.answered_checks) percentage_answered_checks,
      pg_catalog.max(percentage_metric.compliant_checks) percentage_compliant_checks,'
  );
  if definition = previous_definition then
    raise exception 'management overview branch count projection changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
      case when metric.expected_checks = 0 then null
        else pg_catalog.round(metric.answered_checks * 100.0 / metric.expected_checks)::integer
      end completion_percentage,
      case when metric.answered_checks = 0 then null
        else pg_catalog.round(metric.compliant_checks * 100.0 / metric.answered_checks)::integer
      end compliance_percentage
$old$, $new$
      case when pg_catalog.max(percentage_metric.expected_checks) = 0 then null
        else pg_catalog.round(pg_catalog.max(percentage_metric.answered_checks) * 100.0 / pg_catalog.max(percentage_metric.expected_checks))::integer
      end completion_percentage,
      case when pg_catalog.max(percentage_metric.answered_checks) = 0 then null
        else pg_catalog.round(pg_catalog.max(percentage_metric.compliant_checks) * 100.0 / pg_catalog.max(percentage_metric.answered_checks))::integer
      end compliance_percentage
$new$);
  if definition = previous_definition then
    raise exception 'management overview branch percentage expressions changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(
    definition,
    'join branch_metrics metric on metric.branch_id = branch.id',
    'join branch_metrics metric on metric.branch_id = branch.id
    join branch_percentage_metrics percentage_metric on percentage_metric.branch_id = branch.id'
  );
  if definition = previous_definition then
    raise exception 'management overview branch metric join changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
      coalesce(pg_catalog.sum(branch.issue_checks), 0)::bigint issue_checks
    from branch_rows branch
$old$, $new$
      coalesce(pg_catalog.sum(branch.issue_checks), 0)::bigint issue_checks,
      coalesce(pg_catalog.sum(branch.percentage_expected_checks), 0)::bigint percentage_expected_checks,
      coalesce(pg_catalog.sum(branch.percentage_answered_checks), 0)::bigint percentage_answered_checks,
      coalesce(pg_catalog.sum(branch.percentage_compliant_checks), 0)::bigint percentage_compliant_checks
    from branch_rows branch
$new$);
  if definition = previous_definition then
    raise exception 'management overview organization percentage basis changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
      'pending_checks', totals.expected_checks - totals.answered_checks,
      'completion_percentage', case when totals.expected_checks = 0 then null
        else pg_catalog.round(totals.answered_checks * 100.0 / totals.expected_checks)::integer end,
      'compliance_percentage', case when totals.answered_checks = 0 then null
        else pg_catalog.round(totals.compliant_checks * 100.0 / totals.answered_checks)::integer end
$old$, $new$
      'pending_checks', totals.expected_checks - totals.answered_checks,
      'percentage_expected_checks', totals.percentage_expected_checks,
      'percentage_answered_checks', totals.percentage_answered_checks,
      'percentage_compliant_checks', totals.percentage_compliant_checks,
      'completion_percentage', case when totals.percentage_expected_checks = 0 then null
        else pg_catalog.round(totals.percentage_answered_checks * 100.0 / totals.percentage_expected_checks)::integer end,
      'compliance_percentage', case when totals.percentage_answered_checks = 0 then null
        else pg_catalog.round(totals.percentage_compliant_checks * 100.0 / totals.percentage_answered_checks)::integer end
$new$);
  if definition = previous_definition then
    raise exception 'management overview organization JSON changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
          'pending_checks', branch.pending_checks,
          'completion_percentage', branch.completion_percentage,
          'compliance_percentage', branch.compliance_percentage
$old$, $new$
          'pending_checks', branch.pending_checks,
          'percentage_expected_checks', branch.percentage_expected_checks,
          'percentage_answered_checks', branch.percentage_answered_checks,
          'percentage_compliant_checks', branch.percentage_compliant_checks,
          'completion_percentage', branch.completion_percentage,
          'compliance_percentage', branch.compliance_percentage
$new$);
  if definition = previous_definition then
    raise exception 'management overview branch JSON changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
            'pending_checks', checklist.expected_checks - checklist.answered_checks,
            'completion_percentage', case when checklist.expected_checks = 0 then null
              else pg_catalog.round(checklist.answered_checks * 100.0 / checklist.expected_checks)::integer end,
            'compliance_percentage', case when checklist.answered_checks = 0 then null
              else pg_catalog.round(checklist.compliant_checks * 100.0 / checklist.answered_checks)::integer end
$old$, $new$
            'pending_checks', checklist.expected_checks - checklist.answered_checks,
            'percentage_expected_checks', case when checklist.percentage_included then checklist.expected_checks else 0 end,
            'percentage_answered_checks', case when checklist.percentage_included then checklist.answered_checks else 0 end,
            'percentage_compliant_checks', case when checklist.percentage_included then checklist.compliant_checks else 0 end,
            'completion_percentage', case when not checklist.percentage_included or checklist.expected_checks = 0 then null
              else pg_catalog.round(checklist.answered_checks * 100.0 / checklist.expected_checks)::integer end,
            'compliance_percentage', case when not checklist.percentage_included or checklist.answered_checks = 0 then null
              else pg_catalog.round(checklist.compliant_checks * 100.0 / checklist.answered_checks)::integer end
$new$);
  if definition = previous_definition then
    raise exception 'management overview checklist JSON changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(
    definition,
    'from branch_checklist_metrics checklist',
    'from branch_percentage_candidates checklist'
  );
  if definition = previous_definition then
    raise exception 'management overview checklist JSON source changed' using errcode = '22023';
  end if;

  execute definition;
end
$management_percentage_applicability$;

do $management_daily_audit_percentage_applicability$
declare
  definition text;
  previous_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.get_management_overview_with_daily_audit(uuid,uuid)'::regprocedure)
  into definition;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
      'pending_checks', 13 - answered,
      'completion_percentage', round(answered * 100.0 / 13)::integer,
$old$, $new$
      'pending_checks', 13 - answered,
      'percentage_expected_checks', 13,
      'percentage_answered_checks', answered,
      'percentage_compliant_checks', compliant,
      'completion_percentage', round(answered * 100.0 / 13)::integer,
$new$);
  if definition = previous_definition then
    raise exception 'daily audit checklist percentage basis changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
      'pending_checks', (branch_totals ->> 'pending_checks')::integer + 13 - answered,
      'completion_percentage', round(((branch_totals ->> 'answered_checks')::integer + answered) * 100.0 / ((branch_totals ->> 'expected_checks')::integer + 13))::integer,
      'compliance_percentage', case when (branch_totals ->> 'answered_checks')::integer + answered = 0 then null else round(((branch_totals ->> 'compliant_checks')::integer + compliant) * 100.0 / ((branch_totals ->> 'answered_checks')::integer + answered))::integer end
$old$, $new$
      'pending_checks', (branch_totals ->> 'pending_checks')::integer + 13 - answered,
      'percentage_expected_checks', (branch_totals ->> 'percentage_expected_checks')::integer + 13,
      'percentage_answered_checks', (branch_totals ->> 'percentage_answered_checks')::integer + answered,
      'percentage_compliant_checks', (branch_totals ->> 'percentage_compliant_checks')::integer + compliant,
      'completion_percentage', round(((branch_totals ->> 'percentage_answered_checks')::integer + answered) * 100.0 / ((branch_totals ->> 'percentage_expected_checks')::integer + 13))::integer,
      'compliance_percentage', case when (branch_totals ->> 'percentage_answered_checks')::integer + answered = 0 then null else round(((branch_totals ->> 'percentage_compliant_checks')::integer + compliant) * 100.0 / ((branch_totals ->> 'percentage_answered_checks')::integer + answered))::integer end
$new$);
  if definition = previous_definition then
    raise exception 'daily audit branch percentage rollup changed' using errcode = '22023';
  end if;

  previous_definition := definition;
  definition := pg_catalog.replace(definition, $old$
    'pending_checks', (base_totals ->> 'pending_checks')::integer + branch_count * 13 - total_answered,
    'completion_percentage', case when (base_totals ->> 'expected_checks')::integer + branch_count * 13 = 0 then null else round(((base_totals ->> 'answered_checks')::integer + total_answered) * 100.0 / ((base_totals ->> 'expected_checks')::integer + branch_count * 13))::integer end,
    'compliance_percentage', case when (base_totals ->> 'answered_checks')::integer + total_answered = 0 then null else round(((base_totals ->> 'compliant_checks')::integer + total_compliant) * 100.0 / ((base_totals ->> 'answered_checks')::integer + total_answered))::integer end
$old$, $new$
    'pending_checks', (base_totals ->> 'pending_checks')::integer + branch_count * 13 - total_answered,
    'percentage_expected_checks', (base_totals ->> 'percentage_expected_checks')::integer + branch_count * 13,
    'percentage_answered_checks', (base_totals ->> 'percentage_answered_checks')::integer + total_answered,
    'percentage_compliant_checks', (base_totals ->> 'percentage_compliant_checks')::integer + total_compliant,
    'completion_percentage', case when (base_totals ->> 'percentage_expected_checks')::integer + branch_count * 13 = 0 then null else round(((base_totals ->> 'percentage_answered_checks')::integer + total_answered) * 100.0 / ((base_totals ->> 'percentage_expected_checks')::integer + branch_count * 13))::integer end,
    'compliance_percentage', case when (base_totals ->> 'percentage_answered_checks')::integer + total_answered = 0 then null else round(((base_totals ->> 'percentage_compliant_checks')::integer + total_compliant) * 100.0 / ((base_totals ->> 'percentage_answered_checks')::integer + total_answered))::integer end
$new$);
  if definition = previous_definition then
    raise exception 'daily audit organization percentage rollup changed' using errcode = '22023';
  end if;

  execute definition;
end
$management_daily_audit_percentage_applicability$;

revoke all on function public.get_phase4a_management_overview(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.get_phase4a_management_overview(uuid,uuid)
  to service_role;

revoke all on function public.get_management_overview_with_daily_audit(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.get_management_overview_with_daily_audit(uuid,uuid)
  to service_role;
