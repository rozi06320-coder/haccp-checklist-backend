create or replace function private.phase4a_business_date_at(tz text, as_of timestamptz)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select ((as_of at time zone tz) - interval '3 hours')::date
$$;

revoke all on function private.phase4a_business_date_at(text,timestamptz) from public, anon, authenticated;
grant execute on function private.phase4a_business_date_at(text,timestamptz) to service_role;

create or replace function private.phase4a_business_date(tz text)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select private.phase4a_business_date_at(tz, pg_catalog.statement_timestamp())
$$;

revoke all on function private.phase4a_business_date(text) from public, anon, authenticated;
grant execute on function private.phase4a_business_date(text) to service_role;

create or replace function private.managed_financial_closing_operations_summary(
  target_organization_id uuid,
  branch_filter uuid default null,
  as_of timestamptz default pg_catalog.now()
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with active_branches as materialized (
    select branch.id,
      branch.timezone,
      private.phase4a_business_date_at(branch.timezone, as_of) business_date,
      (as_of at time zone branch.timezone)::time local_clock
    from public.branches branch
    where branch.organization_id = target_organization_id
      and branch.active
      and (branch_filter is null or branch.id = branch_filter)
  ),
  branch_status as materialized (
    select branch.id,
      branch.business_date,
      exists (
        select 1
        from public.financial_closing_reports report
        where report.organization_id = target_organization_id
          and report.branch_id = branch.id
          and report.business_date = branch.business_date
          and report.state = 'submitted'
      ) completed_current_day,
      branch.local_clock >= time '02:00'
        and not exists (
          select 1
          from public.financial_closing_reports report
          where report.organization_id = target_organization_id
            and report.branch_id = branch.id
            and report.business_date = case
              when branch.local_clock < time '03:00' then branch.business_date
              else branch.business_date - 1
            end
            and report.state = 'submitted'
        ) overdue_current_business_day
    from active_branches branch
  ),
  date_rows as (
    select branch.business_date, pg_catalog.count(*)::integer branch_count
    from active_branches branch
    group by branch.business_date
  )
  select pg_catalog.jsonb_build_object(
    'total_branches', pg_catalog.count(*)::integer,
    'completed_today', pg_catalog.count(*) filter (where status.completed_current_day)::integer,
    'pending_today', pg_catalog.count(*) filter (where not status.completed_current_day)::integer,
    'overdue_prior_day', pg_catalog.count(*) filter (where status.overdue_current_business_day)::integer,
    'business_dates', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'business_date', date_row.business_date,
        'branch_count', date_row.branch_count
      ) order by date_row.business_date)
      from date_rows date_row
    ), '[]'::jsonb)
  )
  from branch_status status;
$$;

revoke all on function private.managed_financial_closing_operations_summary(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function private.managed_financial_closing_operations_summary(uuid,uuid,timestamptz) to service_role;

create or replace function private.supervisor_notification_branch_scope(actor_user_id uuid)
returns table(
  organization_id uuid,
  branch_id uuid,
  branch_name text,
  branch_code text,
  branch_timezone text,
  business_date date,
  local_time time
)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct branch.organization_id,
    branch.id,
    branch.name,
    branch.code,
    branch.timezone,
    private.phase4a_business_date_at(branch.timezone, pg_catalog.statement_timestamp()),
    (pg_catalog.statement_timestamp() at time zone branch.timezone)::time
  from public.branch_operational_team_supervisors assignment
  join public.branch_operational_teams team
    on team.id = assignment.operational_team_id
   and team.branch_id = assignment.branch_id
   and team.organization_id = assignment.organization_id
   and team.active
  join public.branches branch
    on branch.id = assignment.branch_id
   and branch.organization_id = assignment.organization_id
   and branch.active
  join public.organizations organization on organization.id = branch.organization_id and organization.active
  join public.branch_memberships membership
    on membership.branch_id = branch.id
   and membership.user_id = assignment.supervisor_user_id
   and membership.role = 'branch_manager'
   and membership.active
  join public.profiles profile
    on profile.id = assignment.supervisor_user_id
   and profile.disabled_at is null
   and not profile.must_change_password
  where assignment.supervisor_user_id = actor_user_id
    and assignment.active;
$$;

revoke all on function private.supervisor_notification_branch_scope(uuid) from public, anon, authenticated;
grant execute on function private.supervisor_notification_branch_scope(uuid) to service_role;
