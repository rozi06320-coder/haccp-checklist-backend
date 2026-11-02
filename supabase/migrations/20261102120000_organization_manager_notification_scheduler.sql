begin;

-- Phase 2C scheduler foundation.
-- Adds atomic due-job enqueuing for active branches whose local business day has closed at 04:00.
-- Keeps scheduling disabled unless explicitly invoked by the service role.
-- Evaluates exactly three categories: sales_tracking_missing, maintenance_issue, incomplete_branch_tasks.

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.enqueue_organization_manager_notification_evaluation_job(uuid,uuid,date,text)') is null
    or pg_catalog.to_regprocedure('private.organization_manager_notification_branch_date_closed(uuid,uuid,date,timestamptz)') is null
    or pg_catalog.to_regclass('private.organization_manager_notification_evaluation_jobs') is null
    or pg_catalog.to_regclass('public.organizations') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.daily_report_branch_lifecycle') is null
  then
    raise exception 'organization manager notification scheduler prerequisites are missing' using errcode = '42883';
  end if;

  if pg_catalog.to_regprocedure('public.enqueue_due_organization_manager_notification_evaluation_jobs(integer,timestamptz)') is not null then
    raise exception 'organization manager notification scheduler is already installed' using errcode = '42710';
  end if;
end
$preflight$;

create function public.enqueue_due_organization_manager_notification_evaluation_jobs(
  p_catch_up_days integer default 3,
  p_as_of timestamptz default null
)
returns table(
  job_id uuid,
  organization_id uuid,
  branch_id uuid,
  business_date date,
  notification_category text,
  enqueued boolean
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  now_at timestamptz := coalesce(p_as_of, pg_catalog.statement_timestamp());
  branch_record record;
  branch_local_ts timestamp;
  branch_local_time time;
  branch_local_date date;
  latest_closed_business_date date;
  earliest_business_date date;
  candidate_date date;
  category_item text;
  saved_id uuid;
  is_new boolean;
begin
  if p_catch_up_days is null or p_catch_up_days not between 1 and 7 then
    raise exception 'invalid catch_up_days: must be between 1 and 7' using errcode = '22023';
  end if;

  for branch_record in
    select
      organization.id as org_id,
      branch.id as b_id,
      lifecycle.timezone as tz
    from public.organizations organization
    join public.branches branch on branch.organization_id = organization.id
    join public.daily_report_branch_lifecycle lifecycle
      on lifecycle.organization_id = organization.id
     and lifecycle.branch_id = branch.id
    where organization.active = true
      and branch.active = true
      and lifecycle.active = true
      and lifecycle.effective_to_business_date is null
    order by organization.id, branch.id
  loop
    -- Calculate branch local time and date
    branch_local_ts := now_at at time zone branch_record.tz;
    branch_local_time := branch_local_ts::time;
    branch_local_date := branch_local_ts::date;

    -- At or after 04:00, yesterday's business day (branch_local_date - 1) is closed.
    -- Before 04:00, yesterday's business day is still open; the most recent closed day is (branch_local_date - 2).
    if branch_local_time >= time '04:00:00' then
      latest_closed_business_date := branch_local_date - 1;
    else
      latest_closed_business_date := branch_local_date - 2;
    end if;

    earliest_business_date := latest_closed_business_date - (p_catch_up_days - 1);

    -- Iterate candidate closed dates from earliest to latest
    candidate_date := earliest_business_date;
    while candidate_date <= latest_closed_business_date loop
      -- Verify canonical closure according to lifecycle rules
      if private.organization_manager_notification_branch_date_closed(
        branch_record.org_id, branch_record.b_id, candidate_date, now_at
      ) then
        foreach category_item in array array['sales_tracking_missing', 'maintenance_issue', 'incomplete_branch_tasks'] loop
          saved_id := null;
          is_new := false;

          insert into private.organization_manager_notification_evaluation_jobs(
            notification_category, organization_id, branch_id, business_date
          ) values (
            category_item, branch_record.org_id, branch_record.b_id, candidate_date
          )
          on conflict (organization_id, branch_id, business_date, notification_category) do nothing
          returning id into saved_id;

          if saved_id is not null then
            is_new := true;
          else
            select job.id into strict saved_id
            from private.organization_manager_notification_evaluation_jobs job
            where job.organization_id = branch_record.org_id
              and job.branch_id = branch_record.b_id
              and job.business_date = candidate_date
              and job.notification_category = category_item;
            is_new := false;
          end if;

          job_id := saved_id;
          organization_id := branch_record.org_id;
          branch_id := branch_record.b_id;
          business_date := candidate_date;
          notification_category := category_item;
          enqueued := is_new;
          return next;
        end loop;
      end if;
      candidate_date := candidate_date + 1;
    end loop;
  end loop;
end;
$$;

revoke all on function public.enqueue_due_organization_manager_notification_evaluation_jobs(integer, timestamptz)
  from public, anon, authenticated, service_role;

grant execute on function public.enqueue_due_organization_manager_notification_evaluation_jobs(integer, timestamptz)
  to service_role;

commit;
