begin;

-- Staff Hygiene applicability is derived from the authoritative operational-team
-- roster for the requested branch business date.  This is deliberately separate
-- from the configurable module table: a module can be configured, but it is not
-- required when no eligible on-duty staff exist.
create or replace function private.staff_hygiene_branch_has_eligible_staff(
  p_organization_id uuid,
  p_branch_id uuid,
  p_business_date date
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.operational_staff_assignments assignment
    join public.operational_staff staff
      on staff.id = assignment.operational_staff_id
      and staff.organization_id = assignment.organization_id
      and staff.branch_id = assignment.branch_id
      and staff.employment_status = 'active'
    join public.branch_operational_teams team
      on team.id = assignment.operational_team_id
      and team.organization_id = assignment.organization_id
      and team.branch_id = assignment.branch_id
      and team.active
    left join public.operational_staff_duty_statuses duty
      on duty.assignment_id = assignment.id
      and duty.operational_staff_id = assignment.operational_staff_id
      and duty.organization_id = assignment.organization_id
      and duty.branch_id = assignment.branch_id
      and duty.duty_date = p_business_date
    where assignment.organization_id = p_organization_id
      and assignment.branch_id = p_branch_id
      and assignment.active
      and assignment.valid_from <= p_business_date
      and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
  )
$$;

revoke all on function private.staff_hygiene_branch_has_eligible_staff(uuid,uuid,date)
  from public, anon, authenticated, service_role;

create or replace function public.get_daily_report_staff_hygiene_applicability(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_business_date date,
  p_job_id uuid default null,
  p_lease_token uuid default null
)
returns table(
  branch_id uuid,
  operational_team_id uuid,
  eligible_staff_count bigint,
  required boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_organization_id is null or p_business_date is null
    or not exists (
      select 1 from public.organizations organization
      where organization.id = p_organization_id and organization.active
    ) then
    raise exception 'invalid staff hygiene applicability scope' using errcode = '22023';
  end if;

  if p_actor_user_id is not null then
    if not private.actor_manages_active_organization(p_actor_user_id, p_organization_id)
      and not private.is_internal_admin(p_actor_user_id) then
      raise exception 'staff hygiene applicability access denied' using errcode = '42501';
    end if;
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
      raise exception 'daily business report generation lease invalid or expired' using errcode = '42501';
    end if;
  else
    raise exception 'staff hygiene applicability requires authenticated actor or authorized server lease'
      using errcode = '42501';
  end if;

  return query
  select branch.id,
    team.id,
     count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty')::bigint,
     count(distinct staff.id) filter (where coalesce(duty.duty_status, 'on_duty') = 'on_duty') > 0
  from public.branches branch
  join public.daily_report_branch_lifecycle lifecycle
    on lifecycle.organization_id = branch.organization_id
    and lifecycle.branch_id = branch.id
    and lifecycle.active
    and lifecycle.effective_from_business_date <= p_business_date
    and (lifecycle.effective_to_business_date is null or lifecycle.effective_to_business_date > p_business_date)
  join public.branch_operational_teams team
    on team.organization_id = branch.organization_id
    and team.branch_id = branch.id
    and team.active
  left join public.operational_staff_assignments assignment
    on assignment.organization_id = team.organization_id
    and assignment.branch_id = team.branch_id
    and assignment.operational_team_id = team.id
    and assignment.active
    and assignment.valid_from <= p_business_date
    and (assignment.valid_to is null or assignment.valid_to >= p_business_date)
  left join public.operational_staff staff
    on staff.id = assignment.operational_staff_id
    and staff.organization_id = assignment.organization_id
    and staff.branch_id = assignment.branch_id
    and staff.employment_status = 'active'
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id = assignment.id
    and duty.operational_staff_id = assignment.operational_staff_id
    and duty.organization_id = assignment.organization_id
    and duty.branch_id = assignment.branch_id
    and duty.duty_date = p_business_date
  where branch.organization_id = p_organization_id
  group by branch.id, team.id
  order by branch.id, team.id;
end;
$$;

revoke all on function public.get_daily_report_staff_hygiene_applicability(uuid,uuid,date,uuid,uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_daily_report_staff_hygiene_applicability(uuid,uuid,date,uuid,uuid)
  to service_role;

-- Make the existing authoritative module RPC report the runtime Staff Hygiene
-- requirement without changing its response shape or historical data.
do $patch_daily_applicability$
declare definition text; patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.get_daily_report_authoritative_applicability(uuid,uuid,date,uuid,uuid)'::regprocedure
  ) into definition;
  patched := pg_catalog.replace(definition,
    '    applicability.required,',
    '    case when applicability.module_key = ''staff_hygiene'' then private.staff_hygiene_branch_has_eligible_staff(lifecycle.organization_id, lifecycle.branch_id, p_business_date) else applicability.required end,');
  if patched = definition then
    raise exception 'daily report applicability required expression changed' using errcode = '22023';
  end if;
  execute patched;
end;
$patch_daily_applicability$;

-- A zero-eligible team is not an empty submission.  Historical submitted rows
-- remain readable; only new draft/final writes are rejected.
do $patch_hygiene_writes$
declare definition text; patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.save_operational_team_hygiene_draft(uuid,uuid,uuid,bigint,jsonb)'::regprocedure
  ) into definition;
  patched := pg_catalog.replace(definition,
    '  if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count',
    '  if eligible_count = 0 then raise exception ''staff hygiene not applicable'' using errcode = ''22023''; end if;' || pg_catalog.chr(10) || '  if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count');
  if patched = definition then
    raise exception 'staff hygiene draft validation changed' using errcode = '22023';
  end if;
  execute patched;

  select pg_catalog.pg_get_functiondef(
    'public.submit_operational_team_hygiene(uuid,uuid,uuid,uuid,text,jsonb)'::regprocedure
  ) into definition;
  patched := pg_catalog.replace(definition,
    '  if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count',
    '  if eligible_count = 0 then raise exception ''staff hygiene not applicable'' using errcode = ''22023''; end if;' || pg_catalog.chr(10) || '  if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count');
  if patched = definition then
    raise exception 'staff hygiene submission validation changed' using errcode = '22023';
  end if;
  execute patched;
end;
$patch_hygiene_writes$;

-- Keep management aggregation aligned with effective-dated assignments.  This
-- changes no report totals for currently valid assignments and prevents future
-- or expired staff from becoming applicable by accident.
do $patch_management_roster$
declare definition text; patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.get_phase4a_management_overview(uuid,uuid)'::regprocedure
  ) into definition;
  patched := pg_catalog.replace(definition,
    $oldroster$    where assignment.active
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'$oldroster$,
    $newroster$    where assignment.active
      and assignment.valid_from <= branch.business_date
      and (assignment.valid_to is null or assignment.valid_to >= branch.business_date)
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'$newroster$);
  if patched = definition then
    raise exception 'management hygiene roster changed' using errcode = '22023';
  end if;
  execute patched;
end;
$patch_management_roster$;

-- Supervisor Hygiene metrics are scoped to the actor's effective operational
-- team assignment.  The existing branch and authorization checks remain intact;
-- only the Hygiene CTE's source rows are narrowed.
do $supervisor_patch$
declare definition text; patched text; old_block text; new_block text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.get_phase4a_supervisor_overview(uuid,uuid)'::regprocedure
  ) into definition;

  old_block := $oldx$), eligible_staff as (
  select distinct a.operational_staff_id
  from public.operational_staff_assignments a
  join public.operational_staff staff on staff.id=a.operational_staff_id and staff.employment_status='active'
  left join public.operational_staff_duty_statuses duty on duty.assignment_id=a.id and duty.duty_date=c.business_date
  where a.organization_id=c.organization_id and a.branch_id=c.branch_id and a.active
   and coalesce(duty.duty_status,'on_duty')='on_duty'
 ), hygiene_submissions as ($oldx$;
  new_block := $newx$), eligible_staff as (
  select distinct a.operational_team_id,a.operational_staff_id
  from public.operational_staff_assignments a
  join public.branch_operational_team_supervisors team_assignment
    on team_assignment.operational_team_id=a.operational_team_id
    and team_assignment.organization_id=a.organization_id
    and team_assignment.branch_id=a.branch_id
    and team_assignment.supervisor_user_id=actor_user_id
    and team_assignment.active
    and team_assignment.valid_from<=c.business_date
    and (team_assignment.valid_to is null or team_assignment.valid_to>=c.business_date)
  join public.branch_operational_teams team
    on team.id=a.operational_team_id and team.organization_id=a.organization_id
    and team.branch_id=a.branch_id and team.active
  join public.operational_staff staff on staff.id=a.operational_staff_id
    and staff.organization_id=a.organization_id and staff.branch_id=a.branch_id
    and staff.employment_status='active'
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id=a.id and duty.operational_staff_id=a.operational_staff_id
    and duty.duty_date=c.business_date
  where a.organization_id=c.organization_id and a.branch_id=c.branch_id and a.active
   and a.valid_from<=c.business_date and (a.valid_to is null or a.valid_to>=c.business_date)
   and coalesce(duty.duty_status,'on_duty')='on_duty'
 ), hygiene_submissions as ($newx$;
  patched := pg_catalog.replace(definition, old_block, new_block);
  if patched = definition then
    raise exception 'supervisor Hygiene eligibility block changed' using errcode = '22023';
  end if;
  patched := pg_catalog.replace(patched,
    '   and s.checklist_type=''staff_hygiene''',
    '   and s.checklist_type=''staff_hygiene''' || pg_catalog.chr(10) || '   and exists (select 1 from public.branch_operational_team_supervisors team_assignment where team_assignment.operational_team_id=s.operational_team_id and team_assignment.organization_id=s.organization_id and team_assignment.branch_id=s.branch_id and team_assignment.supervisor_user_id=actor_user_id and team_assignment.active and team_assignment.valid_from<=c.business_date and (team_assignment.valid_to is null or team_assignment.valid_to>=c.business_date))');
  if pg_catalog.strpos(patched, 'team_assignment.supervisor_user_id=actor_user_id') = 0 then
    raise exception 'supervisor Hygiene submission scope changed' using errcode = '22023';
  end if;
  patched := pg_catalog.replace(patched,
    'select distinct on(s.operational_team_id)s.id,s.state,s.updated_at',
    'select distinct on(s.operational_team_id)s.id,s.operational_team_id,s.state,s.updated_at');
  if pg_catalog.strpos(patched, 's.id,s.operational_team_id,s.state,s.updated_at') = 0 then
    raise exception 'supervisor Hygiene submission team projection changed' using errcode = '22023';
  end if;
  patched := pg_catalog.replace(patched,
    '  join eligible_staff e on e.operational_staff_id=h.operational_staff_id',
    '  join eligible_staff e on e.operational_team_id=s.operational_team_id and e.operational_staff_id=h.operational_staff_id');
  if pg_catalog.strpos(patched, 'e.operational_team_id=s.operational_team_id') = 0 then
    raise exception 'supervisor Hygiene staff scope changed' using errcode = '22023';
  end if;
  execute patched;
end;
$supervisor_patch$;

commit;
