-- Manager-only Daily Audit read model. Supervisor persistence remains unchanged.
create function public.list_managed_daily_audit_reports(
  actor_user_id uuid,
  target_organization_id uuid,
  requested_page integer default 1,
  requested_page_size integer default 20,
  date_from date default null,
  date_to date default null,
  branch_filter uuid default null,
  supervisor_filter uuid default null,
  status_filter text default null,
  search_term text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or (status_filter is not null and status_filter not in ('compliant', 'issues_found'))
    or (branch_filter is not null and not exists (
      select 1 from public.branches b
      where b.id = branch_filter and b.organization_id = target_organization_id
    ))
  then
    raise exception 'daily audit report access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'reports', coalesce((
      select pg_catalog.jsonb_agg(row_data.dto order by row_data.business_date desc, row_data.submitted_at desc, row_data.id desc)
      from (
        select s.id, s.business_date, s.submitted_at,
          pg_catalog.jsonb_build_object(
            'id', s.id,
            'branch_id', s.branch_id,
            'branch_name', s.branch_name_snapshot,
            'checklist_type', 'daily_audit',
            'definition_id', s.definition_id,
            'business_date', s.business_date,
            'submitted_at', s.submitted_at,
            'submitted_by', s.daily_audit_auditor_name_snapshot,
            'auditor_kind', s.daily_audit_auditor_kind,
            'completion', 100,
            'issue_count', (select count(*) from public.daily_audit_item_results r where r.submission_id = s.id and r.answer = 'non_compliant'),
            'status', case when exists (
              select 1 from public.daily_audit_item_results r where r.submission_id = s.id and r.answer = 'non_compliant'
            ) then 'issues_found' else 'compliant' end,
            'record_kind', 'submission'
          ) dto
        from public.checklist_submissions s
        where s.organization_id = target_organization_id
          and s.checklist_type = 'daily_audit'
          and s.state = 'submitted'
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (status_filter is null or (status_filter = 'issues_found') = exists (
            select 1 from public.daily_audit_item_results r where r.submission_id = s.id and r.answer = 'non_compliant'
          ))
          and (nullif(btrim(search_term), '') is null
            or s.branch_name_snapshot ilike '%' || btrim(search_term) || '%'
            or s.daily_audit_auditor_name_snapshot ilike '%' || btrim(search_term) || '%')
        order by s.business_date desc, s.submitted_at desc, s.id desc
        limit requested_page_size offset ((requested_page - 1) * requested_page_size)
      ) row_data
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from public.checklist_submissions s
      where s.organization_id = target_organization_id
        and s.checklist_type = 'daily_audit'
        and s.state = 'submitted'
        and (date_from is null or s.business_date >= date_from)
        and (date_to is null or s.business_date <= date_to)
        and (branch_filter is null or s.branch_id = branch_filter)
        and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
        and (status_filter is null or (status_filter = 'issues_found') = exists (
          select 1 from public.daily_audit_item_results r where r.submission_id = s.id and r.answer = 'non_compliant'
        ))
        and (nullif(btrim(search_term), '') is null
          or s.branch_name_snapshot ilike '%' || btrim(search_term) || '%'
          or s.daily_audit_auditor_name_snapshot ilike '%' || btrim(search_term) || '%')
    )
  );
end;
$$;

create function public.get_managed_daily_audit_report_detail(
  actor_user_id uuid,
  target_organization_id uuid,
  target_submission_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'daily audit report access denied' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id', s.id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'business_date', s.business_date,
    'checklist_type', 'daily_audit',
    'definition_id', s.definition_id,
    'submitted_at', s.submitted_at,
    'submitted_by', s.daily_audit_auditor_name_snapshot,
    'auditor_kind', s.daily_audit_auditor_kind,
    'completion', 100,
    'issue_count', (select count(*) from public.daily_audit_item_results r where r.submission_id = s.id and r.answer = 'non_compliant'),
    'status', case when exists (
      select 1 from public.daily_audit_item_results r where r.submission_id = s.id and r.answer = 'non_compliant'
    ) then 'issues_found' else 'compliant' end,
    'record_kind', 'submission',
    'items', (
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_id', d.item_id,
        'item_text', d.item_label_en,
        'answer', coalesce(r.answer, 'not_checked'),
        'remark', coalesce(r.remark, '')
      ) order by d.item_number)
      from public.daily_audit_item_definitions d
      left join public.daily_audit_item_results r
        on r.submission_id = s.id and r.item_id = d.item_id
      where d.active
    )
  ) into strict result
  from public.checklist_submissions s
  where s.id = target_submission_id
    and s.organization_id = target_organization_id
    and s.checklist_type = 'daily_audit'
    and s.state = 'submitted';

  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'daily audit report access denied' using errcode = '42501';
end;
$$;

create function public.get_management_overview_with_daily_audit(
  actor_user_id uuid,
  target_organization_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  base jsonb;
  branch_data jsonb;
  branches jsonb := '[]'::jsonb;
  submission public.checklist_submissions%rowtype;
  daily_state text;
  answered integer;
  compliant integer;
  issues integer;
  total_answered integer := 0;
  total_compliant integer := 0;
  total_issues integer := 0;
  branch_count integer := 0;
  daily_counts jsonb;
  branch_totals jsonb;
  base_totals jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'management overview access denied' using errcode = '42501';
  end if;

  base := public.get_phase4a_management_overview(actor_user_id, target_organization_id);

  for branch_data in select value from pg_catalog.jsonb_array_elements(base -> 'branches') loop
    branch_count := branch_count + 1;
    submission := null;
    select s.* into submission
    from public.checklist_submissions s
    where s.organization_id = target_organization_id
      and s.branch_id = (branch_data ->> 'branch_id')::uuid
      and s.business_date = (branch_data ->> 'business_date')::date
      and s.checklist_type = 'daily_audit'
    order by case s.state when 'submitted' then 0 else 1 end, s.updated_at desc, s.id desc
    limit 1;

    if submission.id is null then
      daily_state := 'not_started'; answered := 0; compliant := 0; issues := 0;
    elsif submission.state = 'draft' then
      daily_state := 'draft'; answered := 0; compliant := 0; issues := 0;
    else
      daily_state := 'submitted';
      select count(*) filter (where r.answer in ('compliant', 'non_compliant')),
             count(*) filter (where r.answer = 'compliant'),
             count(*) filter (where r.answer = 'non_compliant')
        into answered, compliant, issues
      from public.daily_audit_item_results r where r.submission_id = submission.id;
    end if;

    daily_counts := pg_catalog.jsonb_build_object(
      'checklist_type', 'daily_audit',
      'expected_checks', 13,
      'answered_checks', answered,
      'compliant_checks', compliant,
      'issue_checks', issues,
      'pending_checks', 13 - answered,
      'completion_percentage', round(answered * 100.0 / 13)::integer,
      'compliance_percentage', case when answered = 0 then null else round(compliant * 100.0 / answered)::integer end,
      'team_states', pg_catalog.jsonb_build_object(
        'not_started', case when daily_state = 'not_started' then 1 else 0 end,
        'draft', case when daily_state = 'draft' then 1 else 0 end,
        'submitted', case when daily_state = 'submitted' then 1 else 0 end
      )
    );

    branch_totals := branch_data -> 'totals';
    branch_totals := branch_totals || pg_catalog.jsonb_build_object(
      'expected_checks', (branch_totals ->> 'expected_checks')::integer + 13,
      'answered_checks', (branch_totals ->> 'answered_checks')::integer + answered,
      'compliant_checks', (branch_totals ->> 'compliant_checks')::integer + compliant,
      'issue_checks', (branch_totals ->> 'issue_checks')::integer + issues,
      'pending_checks', (branch_totals ->> 'pending_checks')::integer + 13 - answered,
      'completion_percentage', round(((branch_totals ->> 'answered_checks')::integer + answered) * 100.0 / ((branch_totals ->> 'expected_checks')::integer + 13))::integer,
      'compliance_percentage', case when (branch_totals ->> 'answered_checks')::integer + answered = 0 then null else round(((branch_totals ->> 'compliant_checks')::integer + compliant) * 100.0 / ((branch_totals ->> 'answered_checks')::integer + answered))::integer end
    );

    branches := branches || pg_catalog.jsonb_build_array(branch_data || pg_catalog.jsonb_build_object(
      'totals', branch_totals,
      'checklists', (branch_data -> 'checklists') || pg_catalog.jsonb_build_array(daily_counts)
    ));
    total_answered := total_answered + answered;
    total_compliant := total_compliant + compliant;
    total_issues := total_issues + issues;
  end loop;

  base_totals := base -> 'totals';
  base_totals := base_totals || pg_catalog.jsonb_build_object(
    'expected_checks', (base_totals ->> 'expected_checks')::integer + branch_count * 13,
    'answered_checks', (base_totals ->> 'answered_checks')::integer + total_answered,
    'compliant_checks', (base_totals ->> 'compliant_checks')::integer + total_compliant,
    'issue_checks', (base_totals ->> 'issue_checks')::integer + total_issues,
    'pending_checks', (base_totals ->> 'pending_checks')::integer + branch_count * 13 - total_answered,
    'completion_percentage', case when (base_totals ->> 'expected_checks')::integer + branch_count * 13 = 0 then null else round(((base_totals ->> 'answered_checks')::integer + total_answered) * 100.0 / ((base_totals ->> 'expected_checks')::integer + branch_count * 13))::integer end,
    'compliance_percentage', case when (base_totals ->> 'answered_checks')::integer + total_answered = 0 then null else round(((base_totals ->> 'compliant_checks')::integer + total_compliant) * 100.0 / ((base_totals ->> 'answered_checks')::integer + total_answered))::integer end
  );

  return base || pg_catalog.jsonb_build_object('branches', branches, 'totals', base_totals);
end;
$$;

revoke all on function public.list_managed_daily_audit_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text) from public, anon, authenticated;
revoke all on function public.get_managed_daily_audit_report_detail(uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.get_management_overview_with_daily_audit(uuid,uuid) from public, anon, authenticated;
grant execute on function public.list_managed_daily_audit_reports(uuid,uuid,integer,integer,date,date,uuid,uuid,text,text) to service_role;
grant execute on function public.get_managed_daily_audit_report_detail(uuid,uuid,uuid) to service_role;
grant execute on function public.get_management_overview_with_daily_audit(uuid,uuid) to service_role;
