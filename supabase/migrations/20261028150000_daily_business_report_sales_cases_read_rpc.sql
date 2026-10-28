begin;

-- DBR read path only. The cases table intentionally remains RPC-only; do not
-- grant direct SELECT to service_role or any client role.
create or replace function public.get_daily_business_report_sales_cases(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_business_date date,
  p_branch_ids uuid[],
  p_job_id uuid default null,
  p_lease_token uuid default null
)
returns table(
  case_id uuid,
  authoritative_report_id uuid,
  organization_id uuid,
  branch_id uuid,
  business_date date,
  report_state text,
  submitted_at timestamptz,
  currency_code text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_organization_id is null
    or p_business_date is null
    or p_branch_ids is null
    or pg_catalog.cardinality(p_branch_ids) = 0
  then
    raise exception 'daily business report sales cases access denied' using errcode = '42501';
  end if;

  if p_actor_user_id is not null then
    if not private.actor_manages_active_organization(p_actor_user_id, p_organization_id) then
      raise exception 'daily business report sales cases access denied' using errcode = '42501';
    end if;
  elsif p_job_id is null or p_lease_token is null or not exists (
    select 1
    from private.daily_business_report_generation_jobs job
    where job.id = p_job_id
      and job.lease_token = p_lease_token
      and job.organization_id = p_organization_id
      and job.business_date = p_business_date
      and job.state = 'running'
      and job.lease_expires_at > pg_catalog.statement_timestamp()
  ) then
    raise exception 'daily business report sales cases access denied' using errcode = '42501';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(p_branch_ids) requested(branch_id)
    where not exists (
      select 1
      from public.branches branch
      where branch.id = requested.branch_id
        and branch.organization_id = p_organization_id
    )
  ) then
    raise exception 'daily business report sales cases branch scope denied' using errcode = '42501';
  end if;

  return query
  select
    cases.id,
    cases.authoritative_report_id,
    cases.organization_id,
    cases.branch_id,
    cases.business_date,
    report.state,
    report.submitted_at,
    report.currency_code
  from public.sales_tracking_report_cases cases
  join public.sales_tracking_reports report
    on report.id = cases.authoritative_report_id
   and report.case_id = cases.id
   and report.organization_id = cases.organization_id
   and report.branch_id = cases.branch_id
   and report.business_date = cases.business_date
   and report.state = 'submitted'
  where cases.organization_id = p_organization_id
    and cases.business_date = p_business_date
    and cases.branch_id = any (p_branch_ids);
end;
$$;

revoke all on function public.get_daily_business_report_sales_cases(uuid, uuid, date, uuid[], uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_daily_business_report_sales_cases(uuid, uuid, date, uuid[], uuid, uuid)
  to service_role;

-- Preserve the existing RPC-only table boundary explicitly.
revoke all on public.sales_tracking_report_cases from public, anon, authenticated, service_role;

commit;
