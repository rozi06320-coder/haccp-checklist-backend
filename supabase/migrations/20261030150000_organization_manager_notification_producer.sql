begin;

-- Phase 2B producer foundation.  This migration installs no scheduler and does
-- not enqueue jobs.  A service-role caller must claim a Phase 1 lease first.
do $preflight$
begin
  if pg_catalog.to_regprocedure('public.get_incomplete_branch_tasks_completion(uuid,uuid)') is null
    or pg_catalog.to_regprocedure('public.complete_organization_manager_notification_evaluation_job(uuid,uuid,text,text)') is null
    or pg_catalog.to_regprocedure('public.create_organization_manager_category_notification(uuid,uuid,text,uuid,date,jsonb,text)') is null
    or pg_catalog.to_regprocedure('public.get_daily_business_report_sales_cases(uuid,uuid,date,uuid[],uuid,uuid)') is null
    or pg_catalog.to_regprocedure('private.organization_manager_notification_branch_date_closed(uuid,uuid,date,timestamptz)') is null
    or pg_catalog.to_regclass('private.organization_manager_notification_evaluation_jobs') is null
    or pg_catalog.to_regclass('public.organization_manager_notifications') is null
    or pg_catalog.to_regclass('public.daily_report_branch_lifecycle') is null
    or pg_catalog.to_regclass('public.daily_report_module_applicability') is null
    or pg_catalog.to_regclass('public.sales_tracking_report_cases') is null
    or pg_catalog.to_regclass('public.sales_tracking_reports') is null
    or pg_catalog.to_regclass('public.maintenance_issues') is null
    or pg_catalog.to_regclass('public.maintenance_issue_updates') is null
    or pg_catalog.to_regprocedure('private.daily_business_report_branch_close_at(date,text)') is null
  then
    raise exception 'organization manager notification producer prerequisites are missing' using errcode='42883';
  end if;
  if pg_catalog.to_regprocedure('public.produce_organization_manager_notification_evaluation_job(uuid,uuid)') is not null
    or pg_catalog.to_regprocedure('private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)') is not null
    or pg_catalog.to_regprocedure('private.organization_manager_maintenance_issue_ids(uuid,uuid,date,timestamptz)') is not null
  then
    raise exception 'organization manager notification producer is already installed' using errcode='42710';
  end if;
  if pg_catalog.to_regprocedure('public.create_organization_manager_staff_hygiene_missing_notification(uuid,uuid,date)') is not null
  then
    raise exception 'superseded staff hygiene notification producer is present' using errcode='42710';
  end if;
end
$preflight$;

create function private.organization_manager_sales_tracking_status(
  p_organization_id uuid,
  p_branch_id uuid,
  p_business_date date,
  p_as_of timestamptz
)
returns text
language plpgsql stable security definer set search_path=''
as $$
declare
  applicability_count integer;
  applicability_required boolean;
  case_count integer;
  authoritative_id uuid;
  open_correction_id uuid;
  report_count integer;
  report_case_id uuid;
  report_org_id uuid;
  report_branch_id uuid;
  report_date date;
  report_state text;
  report_review_status text;
  report_submitted_at timestamptz;
  correction_case_id uuid;
  correction_org_id uuid;
  correction_branch_id uuid;
  correction_date date;
  correction_state text;
begin
  if p_organization_id is null or p_branch_id is null or p_business_date is null or p_as_of is null
    or not private.organization_manager_notification_branch_date_closed(
      p_organization_id,p_branch_id,p_business_date,p_as_of) then
    return 'unknown';
  end if;

  select count(*)::integer, bool_and(applicability.required)
    into applicability_count, applicability_required
  from public.daily_report_module_applicability applicability
  where applicability.organization_id=p_organization_id
    and applicability.branch_id=p_branch_id
    and applicability.module_key='sales_tracking'
    and applicability.effective_from_business_date<=p_business_date
    and (applicability.effective_to_business_date is null
      or applicability.effective_to_business_date>p_business_date);
  if applicability_count<>1 then return 'unknown'; end if;
  if not coalesce(applicability_required,false) then return 'satisfied'; end if;

  select count(*)::integer into case_count
  from public.sales_tracking_report_cases c
  where c.organization_id=p_organization_id and c.branch_id=p_branch_id
    and c.business_date=p_business_date;
  if case_count>1 then return 'unknown'; end if;
  if case_count=0 then return 'missing'; end if;
  select c.authoritative_report_id,c.open_correction_report_id into authoritative_id,open_correction_id
  from public.sales_tracking_report_cases c
  where c.organization_id=p_organization_id and c.branch_id=p_branch_id
    and c.business_date=p_business_date;
  if open_correction_id is not null then
    select count(*)::integer into report_count
    from public.sales_tracking_reports r where r.id=open_correction_id;
    if report_count<>1 then return 'unknown'; end if;
    select r.case_id,r.organization_id,r.branch_id,r.business_date,r.state
      into correction_case_id,correction_org_id,correction_branch_id,correction_date,correction_state
    from public.sales_tracking_reports r where r.id=open_correction_id;
    if correction_case_id is distinct from (select c.id from public.sales_tracking_report_cases c
      where c.organization_id=p_organization_id and c.branch_id=p_branch_id and c.business_date=p_business_date)
      or correction_org_id is distinct from p_organization_id
      or correction_branch_id is distinct from p_branch_id
      or correction_date is distinct from p_business_date
      or correction_state is distinct from 'draft' then
      return 'unknown';
    end if;
  end if;
  if authoritative_id is null then return 'missing'; end if;

  select count(*)::integer into report_count
  from public.sales_tracking_reports r where r.id=authoritative_id;
  if report_count=1 then
    select r.case_id,r.organization_id,r.branch_id,r.business_date,r.state,r.review_status,r.submitted_at
      into report_case_id,report_org_id,report_branch_id,report_date,report_state,
        report_review_status,report_submitted_at
    from public.sales_tracking_reports r where r.id=authoritative_id;
  end if;
  if report_count<>1
    or report_case_id is distinct from (select c.id from public.sales_tracking_report_cases c
      where c.organization_id=p_organization_id and c.branch_id=p_branch_id and c.business_date=p_business_date)
    or report_org_id is distinct from p_organization_id
    or report_branch_id is distinct from p_branch_id
    or report_date is distinct from p_business_date
    or report_state is distinct from 'submitted' or report_submitted_at is null
    or report_submitted_at>p_as_of then
    return 'unknown';
  end if;
  if report_review_status is null or report_review_status not in ('none','reviewed','needs_review') then return 'unknown'; end if;
  return 'satisfied';
end
$$;

create function private.organization_manager_maintenance_issue_ids(
  p_organization_id uuid,
  p_branch_id uuid,
  p_business_date date,
  p_as_of timestamptz
)
returns table(issue_ids jsonb, issue_count integer, source_completeness text)
language plpgsql stable security definer set search_path=''
as $$
declare close_at timestamptz; lifecycle_count integer; branch_active boolean;
begin
  select private.daily_business_report_branch_close_at(p_business_date,min(lifecycle.timezone)),
    count(*)::integer,bool_and(lifecycle.active)
    into close_at,lifecycle_count,branch_active
  from public.daily_report_branch_lifecycle lifecycle
  where lifecycle.organization_id=p_organization_id and lifecycle.branch_id=p_branch_id
    and lifecycle.effective_from_business_date<=p_business_date
    and (lifecycle.effective_to_business_date is null
      or lifecycle.effective_to_business_date>p_business_date);
  if lifecycle_count<>1 or not coalesce(branch_active,false) or close_at is null or close_at>p_as_of then
    return query select '[]'::jsonb,0,'unknown'; return;
  end if;
  if exists(
    select 1 from public.maintenance_issues issue
    where issue.organization_id=p_organization_id and issue.branch_id=p_branch_id
      and issue.location_scope='branch' and issue.created_at<=close_at
      and issue.status in ('resolved','closed')
      and not exists(
        select 1 from public.maintenance_issue_updates update_row
        where update_row.issue_id=issue.id and update_row.organization_id=p_organization_id
          and update_row.created_at<=close_at
      )
      and coalesce(issue.resolved_at,issue.closed_at,issue.updated_at)<=close_at
  ) then
    return query select '[]'::jsonb,0,'unknown'; return;
  end if;
  return query
    select coalesce(pg_catalog.jsonb_agg(issue.id order by issue.id),'[]'::jsonb),
      count(*)::integer,'complete'
    from public.maintenance_issues issue
    where issue.organization_id=p_organization_id and issue.branch_id=p_branch_id
      and issue.location_scope='branch'
      and issue.created_at<=close_at
      and (
        coalesce((
          select update_row.status
          from public.maintenance_issue_updates update_row
          where update_row.issue_id=issue.id
            and update_row.organization_id=p_organization_id
            and update_row.created_at<=close_at
          order by update_row.created_at desc,update_row.id desc
          limit 1
        ),issue.status) not in ('resolved','closed')
        or coalesce((
          select update_row.created_at
          from public.maintenance_issue_updates update_row
          where update_row.issue_id=issue.id
            and update_row.organization_id=p_organization_id
          order by update_row.created_at desc,update_row.id desc
          limit 1
        ),issue.resolved_at,issue.closed_at,issue.updated_at)>close_at
      );
end
$$;

create function public.produce_organization_manager_notification_evaluation_job(
  p_job_id uuid,p_lease_token uuid
)
returns table(job_id uuid,result text,error_code text,created_count integer)
language plpgsql security definer set search_path=''
as $$
declare
  job private.organization_manager_notification_evaluation_jobs%rowtype;
  now_at timestamptz:=pg_catalog.statement_timestamp();
  source_state text;
  issue_ids jsonb; issue_count integer; completeness text;
  incomplete_modules jsonb; incomplete_count integer;
  recipient record; created integer:=0; saved record;
begin
  select j.* into job from private.organization_manager_notification_evaluation_jobs j where j.id=p_job_id;
  if job.id is null or job.state<>'running' or job.lease_token is distinct from p_lease_token
    or job.lease_expires_at<=now_at then
    raise exception 'manager notification producer lease is not active' using errcode='55000';
  end if;
  if not exists(select 1 from public.organizations o join public.branches b on b.organization_id=o.id
    where o.id=job.organization_id and o.active and b.id=job.branch_id and b.active) then
    return query select job.id,'terminal','invalid_scope',0; return;
  end if;
  if not private.organization_manager_notification_branch_date_closed(
    job.organization_id,job.branch_id,job.business_date,now_at) then
    return query select job.id,'retryable_unknown','business_date_not_closed',0; return;
  end if;

  if job.notification_category='incomplete_branch_tasks' then
    select pg_catalog.jsonb_agg(e.module_key order by e.module_key) filter(where e.module_state='incomplete'),
      count(*) filter(where e.module_state='incomplete')::integer,
      max(e.source_completeness)
      into incomplete_modules,incomplete_count,completeness
    from public.get_incomplete_branch_tasks_completion(job.id,p_lease_token) e;
    if completeness is distinct from 'complete' then
      return query select job.id,'retryable_unknown','incomplete_source_unknown',0; return;
    end if;
    if coalesce(incomplete_count,0)=0 then return query select job.id,'completed',null::text,0; return; end if;
  elsif job.notification_category='sales_tracking_missing' then
    source_state:=private.organization_manager_sales_tracking_status(
      job.organization_id,job.branch_id,job.business_date,now_at);
    if source_state='unknown' then return query select job.id,'retryable_unknown','sales_tracking_source_unknown',0; return; end if;
    if source_state<>'missing' then return query select job.id,'completed',null::text,0; return; end if;
  elsif job.notification_category='maintenance_issue' then
    select m.issue_ids,m.issue_count,m.source_completeness into issue_ids,issue_count,completeness
      from private.organization_manager_maintenance_issue_ids(
        job.organization_id,job.branch_id,job.business_date,now_at) m;
    if completeness<>'complete' then return query select job.id,'retryable_unknown','maintenance_source_unknown',0; return; end if;
    if issue_count=0 then return query select job.id,'completed',null::text,0; return; end if;
  else
    return query select job.id,'terminal','invalid_category',0; return;
  end if;

  for recipient in
    select distinct m.user_id
    from public.organization_memberships m
    join public.profiles p on p.id=m.user_id
    join public.organizations o on o.id=m.organization_id and o.active
    where m.organization_id=job.organization_id and m.role='organization_manager'
      and m.active and p.disabled_at is null and not p.must_change_password
  loop
    if job.notification_category='sales_tracking_missing' then
      select * into saved from public.create_organization_manager_category_notification(
        job.organization_id,recipient.user_id,'sales_tracking_missing',job.branch_id,job.business_date,
        pg_catalog.jsonb_build_object('schema_version','1','category','sales_tracking_missing','evidence','missing'),
        'manager:v1:sales_tracking_missing:'||job.organization_id::text||':'||job.branch_id::text||':'||job.business_date::text);
    elsif job.notification_category='maintenance_issue' then
      select * into saved from public.create_organization_manager_category_notification(
        job.organization_id,recipient.user_id,'maintenance_issue',job.branch_id,job.business_date,
        pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','issue_ids',issue_ids,'issue_count',issue_count),
        'manager:v1:maintenance_issue:'||job.organization_id::text||':'||job.branch_id::text||':'||job.business_date::text);
    else
      select * into saved from public.create_organization_manager_category_notification(
        job.organization_id,recipient.user_id,'incomplete_branch_tasks',job.branch_id,job.business_date,
        pg_catalog.jsonb_build_object('schema_version','1','category','incomplete_branch_tasks','incomplete_modules',incomplete_modules,'incomplete_count',incomplete_count),
        'manager:v1:incomplete_branch_tasks:'||job.organization_id::text||':'||job.branch_id::text||':'||job.business_date::text);
    end if;
    if coalesce(saved.created,false) then created:=created+1; end if;
  end loop;
  return query select job.id,'completed',null::text,created;
exception when others then
  if sqlstate in ('40001','40P01','53300','57014') then
    return query select job.id,'retryable_unknown','producer_retryable',0;
  end if;
  raise;
end
$$;

revoke all on function private.organization_manager_sales_tracking_status(uuid,uuid,date,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function private.organization_manager_maintenance_issue_ids(uuid,uuid,date,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.produce_organization_manager_notification_evaluation_job(uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.produce_organization_manager_notification_evaluation_job(uuid,uuid)
  to service_role;

commit;
