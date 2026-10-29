begin;

-- Interactive Supervisor reads must not use the organization-wide DBR/Manager
-- applicability function.  This function is deliberately branch and
-- assignment scoped; the backend supplies the verified session actor.
create or replace function public.get_supervisor_staff_hygiene_applicability(
  p_actor_user_id uuid,
  p_branch_id uuid,
  p_business_date date default null
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
declare
  v_org uuid;
  v_date date;
begin
  if p_actor_user_id is null or p_branch_id is null then
    raise exception 'invalid supervisor staff hygiene scope' using errcode = '22023';
  end if;

  select b.organization_id, coalesce(p_business_date, private.phase4a_business_date(b.timezone))
    into v_org, v_date
  from public.branches b
  where b.id = p_branch_id and b.active;
  if v_org is null then
    raise exception 'staff hygiene branch access denied' using errcode = '42501';
  end if;

  -- Establish supervisor/branch authorization before returning the explicit
  -- no-team N/A result.  An unknown actor must never be indistinguishable
  -- from an authorized supervisor who currently has no team assignment.
  if not private.actor_can_read_operational_branch(p_actor_user_id, p_branch_id) then
    raise exception 'staff hygiene branch access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.daily_report_branch_lifecycle lifecycle
    where lifecycle.organization_id = v_org and lifecycle.branch_id = p_branch_id
      and lifecycle.active and lifecycle.effective_from_business_date <= v_date
      and (lifecycle.effective_to_business_date is null or lifecycle.effective_to_business_date > v_date)
  ) then
    return query select p_branch_id, v_date, null::uuid, 0::bigint, false, 'not_applicable'::text;
    return;
  end if;

  if not exists (
    select 1
    from public.branch_operational_team_supervisors a
    where a.supervisor_user_id = p_actor_user_id
      and a.organization_id = v_org
      and a.branch_id = p_branch_id
      and a.active
      and a.valid_from <= v_date
      and (a.valid_to is null or a.valid_to >= v_date)
  ) then
    return query select p_branch_id, v_date, null::uuid, 0::bigint, false, 'not_applicable'::text;
    return;
  end if;

  return query
  select p_branch_id, v_date, team.id,
    count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty')::bigint,
    count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0,
    case when count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0 then 'required' else 'not_applicable' end
  from public.branch_operational_team_supervisors supervisor_team
  join public.branch_operational_teams team
    on team.id = supervisor_team.operational_team_id
   and team.organization_id = v_org and team.branch_id = p_branch_id and team.active
  left join public.operational_staff_assignments assignment
    on assignment.operational_team_id = team.id
   and assignment.organization_id = v_org and assignment.branch_id = p_branch_id and assignment.active
   and assignment.valid_from <= v_date and (assignment.valid_to is null or assignment.valid_to >= v_date)
  left join public.operational_staff staff
    on staff.id = assignment.operational_staff_id
   and staff.organization_id = v_org and staff.branch_id = p_branch_id and staff.employment_status = 'active'
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id = assignment.id and duty.operational_staff_id = assignment.operational_staff_id
   and duty.organization_id = v_org and duty.branch_id = p_branch_id and duty.duty_date = v_date
  where supervisor_team.supervisor_user_id = p_actor_user_id
    and supervisor_team.organization_id = v_org and supervisor_team.branch_id = p_branch_id
    and supervisor_team.active
    and supervisor_team.valid_from <= v_date
    and (supervisor_team.valid_to is null or supervisor_team.valid_to >= v_date)
  group by team.id
  order by team.id;
end;
$$;

revoke all on function public.get_supervisor_staff_hygiene_applicability(uuid,uuid,date)
  from public, anon, authenticated, service_role;
grant execute on function public.get_supervisor_staff_hygiene_applicability(uuid,uuid,date)
  to service_role;

commit;
