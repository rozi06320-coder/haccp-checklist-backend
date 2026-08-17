-- Manager Sales Tracking issues: variance and derived missed submissions.

create function private.sales_tracking_issue_uuid(seed text)
returns uuid language sql immutable security definer set search_path = '' as $$
  select (
    substr(hash.value, 1, 8) || '-' ||
    substr(hash.value, 9, 4) || '-' ||
    substr(hash.value, 13, 4) || '-' ||
    substr(hash.value, 17, 4) || '-' ||
    substr(hash.value, 21, 12)
  )::uuid
  from (select md5(seed) value) hash
$$;
revoke all on function private.sales_tracking_issue_uuid(text) from public, anon, authenticated;

create function private.sales_tracking_managed_issue_rows(target_organization_id uuid)
returns table(
  id uuid,
  report_id uuid,
  branch_id uuid,
  branch_name text,
  business_date date,
  supervisor_user_id uuid,
  submitted_by text,
  submitted_at timestamptz,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text,
  actual_total numeric,
  pos_total numeric,
  variance numeric
) language sql stable security definer set search_path = '' as $$
  with
  active_branches as materialized (
    select branch.id, branch.name, branch.timezone,
      private.phase4a_business_date(branch.timezone) business_date,
      extract(hour from pg_catalog.statement_timestamp() at time zone branch.timezone) >= 3 closed
    from public.branches branch
    where branch.organization_id = target_organization_id and branch.active
  ),
  eligible_teams as materialized (
    select team.id team_id, team.branch_id, team.supervisor_user_id,
      coalesce(nullif(pg_catalog.btrim(profile.full_name), ''), 'Branch Supervisor') supervisor_name
    from public.branch_supervisor_teams team
    join active_branches branch on branch.id = team.branch_id
    join public.profiles profile on profile.id = team.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id = team.branch_id
      and membership.user_id = team.supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
    where team.organization_id = target_organization_id and team.active
      and profile.disabled_at is null and not profile.must_change_password
  ),
  submitted_reports as materialized (
    select report.id, report.branch_id, report.supervisor_team_id, report.business_date,
      report.supervisor_user_id, report.branch_name_snapshot, report.supervisor_name_snapshot, report.submitted_at,
      coalesce(pg_catalog.sum(row.actual_cash + row.actual_credit + row.online_delivery), 0) actual_total,
      coalesce(pg_catalog.sum(row.pos_cash + row.pos_credit + row.online_delivery), 0) pos_total
    from public.sales_tracking_reports report
    left join public.sales_tracking_sales_rows row on row.report_id = report.id
    where report.organization_id = target_organization_id
      and report.state = 'submitted'
      and report.submitted_at is not null
    group by report.id
  ),
  variance_issues as (
    select report.id,
      report.id report_id,
      report.branch_id,
      report.branch_name_snapshot branch_name,
      report.business_date,
      report.supervisor_user_id,
      report.supervisor_name_snapshot submitted_by,
      report.submitted_at,
      'Sales Tracking variance issue'::text title,
      'Actual total ' || report.actual_total || ', POS total ' || report.pos_total || ', variance ' || (report.actual_total - report.pos_total) || '.' description,
      'new'::text status,
      report.submitted_at created_at,
      'variance'::text item_id,
      'Variance mismatch'::text item_text,
      report.actual_total,
      report.pos_total,
      report.actual_total - report.pos_total variance
    from submitted_reports report
    where pg_catalog.round(report.actual_total - report.pos_total, 2) <> 0
  ),
  missed_issues as (
    select private.sales_tracking_issue_uuid('sales_tracking:missed:' || branch.id || ':' || team.team_id || ':' || branch.business_date) id,
      private.sales_tracking_issue_uuid('sales_tracking:missing-report:' || branch.id || ':' || team.team_id || ':' || branch.business_date) report_id,
      branch.id branch_id,
      branch.name branch_name,
      branch.business_date,
      team.supervisor_user_id,
      team.supervisor_name submitted_by,
      null::timestamptz submitted_at,
      'Missing Sales Tracking submission'::text title,
      'Sales Tracking was not submitted before the 03:00 operational close.'::text description,
      'new'::text status,
      (branch.business_date::timestamp + time '03:00') at time zone branch.timezone created_at,
      'not_checked'::text item_id,
      'Sales Tracking not checked'::text item_text,
      0::numeric actual_total,
      0::numeric pos_total,
      0::numeric variance
    from active_branches branch
    join eligible_teams team on team.branch_id = branch.id
    where branch.closed
      and not exists (
        select 1 from public.sales_tracking_reports report
        where report.organization_id = target_organization_id
          and report.branch_id = branch.id
          and report.supervisor_team_id = team.team_id
          and report.business_date = branch.business_date
          and report.state = 'submitted'
          and report.submitted_at is not null
      )
  )
  select * from variance_issues
  union all
  select * from missed_issues
$$;
revoke all on function private.sales_tracking_managed_issue_rows(uuid) from public, anon, authenticated;

create function public.list_sales_tracking_managed_issues(
  actor_user_id uuid,
  target_organization_id uuid,
  requested_page int default 1,
  requested_page_size int default 20,
  date_from date default null,
  date_to date default null,
  branch_filter uuid default null,
  supervisor_filter uuid default null,
  staff_filter uuid default null,
  type_filter text default null,
  status_filter text default null,
  search_term text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or (type_filter is not null and type_filter <> 'sales_tracking')
    or (status_filter is not null and status_filter <> 'new')
  then
    raise exception 'sales tracking issue access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'issues', coalesce((
      select pg_catalog.jsonb_agg(issue.dto order by issue.created_at desc, issue.id)
      from (
        select row.created_at, row.id, pg_catalog.jsonb_build_object(
          'id', row.id,
          'report_id', row.report_id,
          'branch_id', row.branch_id,
          'branch_name', row.branch_name,
          'business_date', row.business_date,
          'submitted_by', row.submitted_by,
          'checklist_type', 'sales_tracking',
          'title', row.title,
          'description', row.description,
          'status', row.status,
          'created_at', row.created_at,
          'item_id', row.item_id,
          'item_text', row.item_text,
          'affected_staff_id', null,
          'affected_staff_name', null
        ) dto
        from private.sales_tracking_managed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and staff_filter is null
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or row.title ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.description ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
        order by row.created_at desc, row.id
        offset (requested_page - 1) * requested_page_size
        limit requested_page_size
      ) issue
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from private.sales_tracking_managed_issue_rows(target_organization_id) row
      where (date_from is null or row.business_date >= date_from)
        and (date_to is null or row.business_date <= date_to)
        and (branch_filter is null or row.branch_id = branch_filter)
        and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
        and staff_filter is null
        and (
          nullif(pg_catalog.btrim(search_term), '') is null
          or row.title ilike '%' || pg_catalog.btrim(search_term) || '%'
          or row.description ilike '%' || pg_catalog.btrim(search_term) || '%'
          or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%'
          or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%'
        )
    )
  );
end;
$$;

create function public.get_sales_tracking_managed_issue(
  actor_user_id uuid,
  target_organization_id uuid,
  target_issue_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'sales tracking issue access denied' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id', row.id,
    'report_id', row.report_id,
    'branch_id', row.branch_id,
    'branch_name', row.branch_name,
    'business_date', row.business_date,
    'submitted_by', row.submitted_by,
    'checklist_type', 'sales_tracking',
    'item_id', row.item_id,
    'item_text', row.item_text,
    'affected_staff_id', null,
    'affected_staff_name', null,
    'remark', case
      when row.item_id = 'variance'
        then 'Variance issue' || chr(10) ||
          'Submitted at: ' || coalesce(row.submitted_at::text, 'Not submitted') || chr(10) ||
          'Actual total: ' || row.actual_total || chr(10) ||
          'POS total: ' || row.pos_total || chr(10) ||
          'Variance: ' || row.variance || chr(10) ||
          'Actual and POS totals do not match.'
      else 'Not checked' || chr(10) ||
        'Sales Tracking was not submitted before the 03:00 operational close.' || chr(10) ||
        'No fake submission was created.'
    end,
    'status', row.status,
    'created_at', row.created_at
  ) into strict result
  from private.sales_tracking_managed_issue_rows(target_organization_id) row
  where row.id = target_issue_id;

  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'sales tracking issue access denied' using errcode = '42501';
end;
$$;

revoke all on function public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_sales_tracking_managed_issue(uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_sales_tracking_managed_issue(uuid,uuid,uuid)
  to service_role;
