begin;

-- Daily Business Report Phase 2.6: Authoritative Module Applicability RPC
-- Read-only SECURITY DEFINER function to retrieve authoritative module applicability
-- and branch lifecycle state for an organization on a given business date.
-- Restricted exclusively to service_role with empty search_path, explicit actor/lease
-- authorization (no NULL actor bypass), and fail-closed combinatoric completeness verification.

drop function if exists public.get_daily_report_authoritative_applicability(uuid, uuid, date);
drop function if exists public.get_daily_report_authoritative_applicability(uuid, uuid, date, uuid, uuid);

create or replace function public.get_daily_report_authoritative_applicability(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_business_date date,
  p_job_id uuid default null,
  p_lease_token uuid default null
)
returns table(
  branch_id uuid,
  timezone text,
  close_at timestamptz,
  module_key text,
  required boolean,
  requirement_basis text
)
language plpgsql
stable
security definer
set search_path=''
as $$
begin
  -- 1. Input sanitization & Tenant validation
  if p_organization_id is null or p_business_date is null
    or not exists(
      select 1 from public.organizations organization
      where organization.id = p_organization_id and organization.active
    )
  then
    raise exception 'invalid daily business report organization or date' using errcode='22023';
  end if;

  -- 2. Caller authorization: No NULL actor bypass
  -- Path A: Authenticated actor (must manage active organization or be internal admin)
  if p_actor_user_id is not null then
    if not private.actor_manages_active_organization(p_actor_user_id, p_organization_id)
      and not private.is_internal_admin(p_actor_user_id)
    then
      raise exception 'daily business report applicability access denied' using errcode='42501';
    end if;
  -- Path B: Legitimate internal generator operation with active leased generation job
  elsif p_job_id is not null and p_lease_token is not null then
    if not exists (
      select 1 from private.daily_business_report_generation_jobs job
      where job.id = p_job_id
        and job.lease_token = p_lease_token
        and job.organization_id = p_organization_id
        and job.business_date = p_business_date
        and job.state = 'running'
        and job.lease_expires_at > pg_catalog.statement_timestamp()
    ) then
      raise exception 'daily business report generation lease invalid or expired' using errcode='42501';
    end if;
  else
    -- Fails closed: NULL actor without an explicit valid server generator lease is denied
    raise exception 'daily business report applicability requires authenticated actor or authorized server lease'
      using errcode='42501';
  end if;

  -- 3. Fail-closed completeness verification against authoritative expected combinations
  -- 3a. Detect duplicate records for any (branch, module) on p_business_date
  if exists (
    select 1
    from public.daily_report_branch_lifecycle lifecycle
    join public.daily_report_module_applicability applicability
      on applicability.organization_id = lifecycle.organization_id
      and applicability.branch_id = lifecycle.branch_id
      and applicability.effective_from_business_date <= p_business_date
      and (applicability.effective_to_business_date is null
        or applicability.effective_to_business_date > p_business_date)
    where lifecycle.organization_id = p_organization_id
      and lifecycle.active
      and lifecycle.effective_from_business_date <= p_business_date
      and (lifecycle.effective_to_business_date is null
        or lifecycle.effective_to_business_date > p_business_date)
    group by lifecycle.branch_id, applicability.module_key
    having count(*) > 1
  ) then
    raise exception 'daily business report module applicability duplicate records detected' using errcode='22023';
  end if;

  -- 3b. Verify every active branch has all 7 canonical modules configured on p_business_date
  if exists (
    with expected_modules as (
      select unnest(array[
        'kitchen_opening',
        'foh_opening',
        'staff_hygiene',
        'daily_audit',
        'cold_storage',
        'oil_tracking',
        'sales_tracking'
      ]::text[]) as module_key
    ),
    active_branches as (
      select lifecycle.branch_id
      from public.daily_report_branch_lifecycle lifecycle
      where lifecycle.organization_id = p_organization_id
        and lifecycle.active
        and lifecycle.effective_from_business_date <= p_business_date
        and (lifecycle.effective_to_business_date is null
          or lifecycle.effective_to_business_date > p_business_date)
    ),
    expected_combinations as (
      select b.branch_id, m.module_key
      from active_branches b
      cross join expected_modules m
    ),
    actual_records as (
      select applicability.branch_id, applicability.module_key
      from active_branches b
      join public.daily_report_module_applicability applicability
        on applicability.organization_id = p_organization_id
        and applicability.branch_id = b.branch_id
        and applicability.effective_from_business_date <= p_business_date
        and (applicability.effective_to_business_date is null
          or applicability.effective_to_business_date > p_business_date)
    )
    select 1
    from expected_combinations ec
    left join actual_records ar
      on ar.branch_id = ec.branch_id
      and ar.module_key = ec.module_key
    where ar.module_key is null
  ) then
    raise exception 'daily business report module applicability missing' using errcode='22023';
  end if;

  -- 4. Return authoritative records ordered deterministically
  return query
  select
    lifecycle.branch_id,
    lifecycle.timezone,
    private.daily_business_report_branch_close_at(p_business_date, lifecycle.timezone) as close_at,
    applicability.module_key,
    applicability.required,
    applicability.requirement_basis
  from public.daily_report_branch_lifecycle lifecycle
  join public.daily_report_module_applicability applicability
    on applicability.organization_id = lifecycle.organization_id
    and applicability.branch_id = lifecycle.branch_id
    and applicability.effective_from_business_date <= p_business_date
    and (applicability.effective_to_business_date is null
      or applicability.effective_to_business_date > p_business_date)
  where lifecycle.organization_id = p_organization_id
    and lifecycle.active
    and lifecycle.effective_from_business_date <= p_business_date
    and (lifecycle.effective_to_business_date is null
      or lifecycle.effective_to_business_date > p_business_date)
  order by lifecycle.branch_id, applicability.module_key;
end;
$$;

revoke all on function public.get_daily_report_authoritative_applicability(uuid, uuid, date, uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_daily_report_authoritative_applicability(uuid, uuid, date, uuid, uuid) to service_role;

commit;
