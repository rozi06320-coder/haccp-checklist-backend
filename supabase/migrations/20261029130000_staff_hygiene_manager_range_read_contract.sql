begin;

create or replace function public.get_manager_staff_hygiene_applicability_range(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_date_from date,
  p_date_to date
)
returns table(
  branch_id uuid,
  business_date date,
  operational_team_id uuid,
  eligible_staff_count bigint,
  required boolean,
  applicability text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_actor_user_id is null or p_organization_id is null
     or p_date_from is null or p_date_to is null
     or p_date_from > p_date_to
     or p_date_to - p_date_from >= 31 then
    raise exception 'invalid Staff Hygiene applicability date range' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id and organization.active
  ) or (not private.actor_manages_active_organization(p_actor_user_id, p_organization_id)
        and not private.is_internal_admin(p_actor_user_id)) then
    raise exception 'Staff Hygiene applicability access denied' using errcode = '42501';
  end if;

  return query
  with dates as (
    select generate_series(p_date_from, p_date_to, interval '1 day')::date as business_date
  ), eligible_branches as (
    select lifecycle.organization_id, lifecycle.branch_id, dates.business_date
    from dates
    join public.daily_report_branch_lifecycle lifecycle
      on lifecycle.organization_id = p_organization_id
     and lifecycle.active
     and lifecycle.effective_from_business_date <= dates.business_date
     and (lifecycle.effective_to_business_date is null or lifecycle.effective_to_business_date > dates.business_date)
  ), team_scope as (
    select branches.branch_id, branches.business_date, team.id as operational_team_id
    from eligible_branches branches
    left join public.branch_operational_teams team
      on team.organization_id = branches.organization_id
     and team.branch_id = branches.branch_id
     and team.active
  )
  select scope.branch_id, scope.business_date, scope.operational_team_id,
    count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty')::bigint,
    count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0,
    case when count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0
      then 'required' else 'not_applicable' end
  from team_scope scope
  left join public.operational_staff_assignments assignment
    on assignment.organization_id = p_organization_id
   and assignment.branch_id = scope.branch_id
   and assignment.operational_team_id = scope.operational_team_id
   and assignment.active
   and assignment.valid_from <= scope.business_date
   and (assignment.valid_to is null or assignment.valid_to >= scope.business_date)
  left join public.operational_staff staff
    on staff.id = assignment.operational_staff_id
   and staff.organization_id = p_organization_id
   and staff.branch_id = scope.branch_id
   and staff.employment_status = 'active'
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id = assignment.id
   and duty.operational_staff_id = assignment.operational_staff_id
   and duty.organization_id = p_organization_id
   and duty.branch_id = scope.branch_id
   and duty.duty_date = scope.business_date
  group by scope.branch_id, scope.business_date, scope.operational_team_id
  order by scope.business_date, scope.branch_id, scope.operational_team_id;
end;
$$;

revoke all on function public.get_manager_staff_hygiene_applicability_range(uuid,uuid,date,date)
  from public, anon, authenticated, service_role;
grant execute on function public.get_manager_staff_hygiene_applicability_range(uuid,uuid,date,date)
  to service_role;

commit;
