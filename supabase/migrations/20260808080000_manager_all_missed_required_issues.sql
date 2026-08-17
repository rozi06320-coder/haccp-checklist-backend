-- Manager Issues: derive missed/not-checked rows for required daily work without creating fake submissions.

create or replace function private.management_missed_issue_id(seed text)
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
revoke all on function private.management_missed_issue_id(text) from public, anon, authenticated;

create or replace function private.management_branch_closed(branch_timezone text, as_of timestamptz default pg_catalog.statement_timestamp())
returns boolean language sql stable security definer set search_path = '' as $$
  select extract(hour from as_of at time zone branch_timezone) >= 3
$$;
revoke all on function private.management_branch_closed(text,timestamptz) from public, anon, authenticated;

create or replace function private.management_oil_opening_closed(branch_timezone text, as_of timestamptz default pg_catalog.statement_timestamp())
returns boolean language sql stable security definer set search_path = '' as $$
  select extract(hour from as_of at time zone branch_timezone) >= 15
$$;
revoke all on function private.management_oil_opening_closed(text,timestamptz) from public, anon, authenticated;

create or replace function private.cold_storage_closed_slots_for(target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp())
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare branch_timezone text; local_date date; local_hour int;
begin
  select timezone into strict branch_timezone from public.branches where id = target_branch_id;
  local_date := (as_of at time zone branch_timezone)::date;
  local_hour := extract(hour from as_of at time zone branch_timezone)::int;

  if target_business_date < local_date then
    if target_business_date = local_date - 1 and local_hour < 3 then
      return array[]::text[];
    end if;
    return array['12:00','3:00','8:00']::text[];
  elsif target_business_date > local_date or local_hour < 15 then
    return array[]::text[];
  elsif local_hour < 20 then
    return array['12:00']::text[];
  else
    return array['12:00','3:00']::text[];
  end if;
end $$;
revoke all on function private.cold_storage_closed_slots_for(uuid,date,timestamptz) from public, anon, authenticated;

create or replace function private.phase4a_managed_missed_issue_rows(target_organization_id uuid)
returns table(
  id uuid,
  report_id uuid,
  branch_id uuid,
  branch_name text,
  business_date date,
  supervisor_user_id uuid,
  submitted_by text,
  checklist_type text,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text,
  affected_staff_id uuid,
  affected_staff_name text
) language sql stable security definer set search_path = '' as $$
  with
  active_branches as materialized (
    select branch.id, branch.name, branch.timezone,
      private.phase4a_business_date(branch.timezone) business_date,
      private.management_branch_closed(branch.timezone) closed
    from public.branches branch
    where branch.organization_id = target_organization_id
      and branch.active
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
    where team.organization_id = target_organization_id
      and team.active
      and profile.disabled_at is null
      and not profile.must_change_password
  ),
  required_opening as (
    select branch.id branch_id, branch.name branch_name, branch.business_date,
      team.team_id, team.supervisor_user_id, team.supervisor_name,
      checklist.checklist_type
    from active_branches branch
    join eligible_teams team on team.branch_id = branch.id
    cross join (values ('kitchen_opening'::text), ('foh_opening'::text)) checklist(checklist_type)
    where branch.closed
      and not exists (
        select 1 from public.checklist_submissions submission
        where submission.organization_id = target_organization_id
          and submission.branch_id = branch.id
          and submission.supervisor_team_id = team.team_id
          and submission.business_date = branch.business_date
          and submission.checklist_type = checklist.checklist_type
          and submission.state = 'submitted'
      )
  ),
  hygiene_roster as materialized (
    select distinct branch.id branch_id, branch.name branch_name, branch.business_date,
      team.team_id, team.supervisor_user_id, team.supervisor_name
    from active_branches branch
    join eligible_teams team on team.branch_id = branch.id
    join public.operational_staff_assignments assignment
      on assignment.supervisor_team_id = team.team_id
      and assignment.branch_id = branch.id
      and assignment.active
    join public.operational_staff staff
      on staff.id = assignment.operational_staff_id
      and staff.organization_id = target_organization_id
      and staff.employment_status = 'active'
    left join public.operational_staff_duty_statuses duty
      on duty.assignment_id = assignment.id
      and duty.operational_staff_id = staff.id
      and duty.duty_date = branch.business_date
    where branch.closed
      and coalesce(duty.duty_status, 'on_duty') = 'on_duty'
  ),
  required_hygiene as (
    select roster.*, 'staff_hygiene'::text checklist_type
    from hygiene_roster roster
    where not exists (
      select 1 from public.checklist_submissions submission
      where submission.organization_id = target_organization_id
        and submission.branch_id = roster.branch_id
        and submission.supervisor_team_id = roster.team_id
        and submission.business_date = roster.business_date
        and submission.checklist_type = 'staff_hygiene'
        and submission.state = 'submitted'
    )
  ),
  missed as (
    select * from required_opening
    union all
    select * from required_hygiene
  )
  select
    private.management_missed_issue_id('phase4a:missed:' || missed.checklist_type || ':' || missed.branch_id || ':' || missed.team_id || ':' || missed.business_date) id,
    private.management_missed_issue_id('phase4a:missing-report:' || missed.checklist_type || ':' || missed.branch_id || ':' || missed.team_id || ':' || missed.business_date) report_id,
    missed.branch_id,
    missed.branch_name,
    missed.business_date,
    missed.supervisor_user_id,
    missed.supervisor_name submitted_by,
    missed.checklist_type,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening not checked'
      when 'foh_opening' then 'FOH Opening not checked'
      else 'Staff Hygiene not checked'
    end title,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening was not submitted before the 03:00 operational close.'
      when 'foh_opening' then 'FOH Opening was not submitted before the 03:00 operational close.'
      else 'Staff Hygiene was not submitted before the 03:00 operational close.'
    end description,
    'new'::text status,
    (missed.business_date::timestamp + time '03:00') at time zone branch.timezone created_at,
    'not_checked'::text item_id,
    case missed.checklist_type
      when 'kitchen_opening' then 'Kitchen Opening not checked'
      when 'foh_opening' then 'FOH Opening not checked'
      else 'Staff Hygiene not checked'
    end item_text,
    null::uuid affected_staff_id,
    null::text affected_staff_name
  from missed
  join active_branches branch on branch.id = missed.branch_id
$$;
revoke all on function private.phase4a_managed_missed_issue_rows(uuid) from public, anon, authenticated;

create or replace function public.list_phase4a_managed_issues(
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
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or (type_filter is not null and type_filter not in ('kitchen_opening','foh_opening','staff_hygiene'))
    or (status_filter is not null and status_filter <> 'new')
  then
    raise exception 'issue access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'issues', coalesce((
      with combined as (
        select i.created_at, i.id, pg_catalog.jsonb_build_object(
          'id', i.id,
          'report_id', i.source_submission_id,
          'branch_id', i.branch_id,
          'branch_name', s.branch_name_snapshot,
          'business_date', s.business_date,
          'submitted_by', s.supervisor_name_snapshot,
          'checklist_type', i.checklist_type,
          'title', coalesce(i.item_text_snapshot, i.affected_staff_name_snapshot),
          'item_id', i.item_id,
          'item_text', i.item_text_snapshot,
          'affected_staff_id', i.affected_staff_id,
          'affected_staff_name', i.affected_staff_name_snapshot,
          'description', i.remark,
          'status', i.status,
          'created_at', i.created_at
        ) dto
        from public.checklist_issues i
        join public.checklist_submissions s on s.id = i.source_submission_id
        where i.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or i.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (staff_filter is null or i.affected_staff_id = staff_filter)
          and (type_filter is null or i.checklist_type = type_filter)
          and (status_filter is null or i.status = status_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or coalesce(i.item_text_snapshot, i.affected_staff_name_snapshot) ilike '%' || pg_catalog.btrim(search_term) || '%'
            or i.remark ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
        union all
        select row.created_at, row.id, pg_catalog.jsonb_build_object(
          'id', row.id,
          'report_id', row.report_id,
          'branch_id', row.branch_id,
          'branch_name', row.branch_name,
          'business_date', row.business_date,
          'submitted_by', row.submitted_by,
          'checklist_type', row.checklist_type,
          'title', row.title,
          'description', row.description,
          'status', row.status,
          'created_at', row.created_at,
          'item_id', row.item_id,
          'item_text', row.item_text,
          'affected_staff_id', row.affected_staff_id,
          'affected_staff_name', row.affected_staff_name
        ) dto
        from private.phase4a_managed_missed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and staff_filter is null
          and (type_filter is null or row.checklist_type = type_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or row.title ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.description ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
      )
      select pg_catalog.jsonb_agg(dto order by created_at desc, id)
      from (
        select * from combined
        order by created_at desc, id
        offset (requested_page - 1) * requested_page_size
        limit requested_page_size
      ) issue
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      with combined as (
        select i.id
        from public.checklist_issues i
        join public.checklist_submissions s on s.id = i.source_submission_id
        where i.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or i.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (staff_filter is null or i.affected_staff_id = staff_filter)
          and (type_filter is null or i.checklist_type = type_filter)
          and (status_filter is null or i.status = status_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or coalesce(i.item_text_snapshot, i.affected_staff_name_snapshot) ilike '%' || pg_catalog.btrim(search_term) || '%'
            or i.remark ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
        union all
        select row.id
        from private.phase4a_managed_missed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and staff_filter is null
          and (type_filter is null or row.checklist_type = type_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or row.title ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.description ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
      )
      select count(*) from combined
    )
  );
end $$;

create or replace function public.get_phase4a_managed_issue(actor_user_id uuid,target_organization_id uuid,target_issue_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id) then
    raise exception 'issue access denied' using errcode='42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id',i.id,'report_id',i.source_submission_id,'branch_id',i.branch_id,
    'branch_name',s.branch_name_snapshot,'business_date',s.business_date,
    'submitted_by',s.supervisor_name_snapshot,'checklist_type',i.checklist_type,
    'item_id',i.item_id,'item_text',i.item_text_snapshot,
    'affected_staff_id',i.affected_staff_id,'affected_staff_name',i.affected_staff_name_snapshot,
    'remark',i.remark,'status',i.status,'created_at',i.created_at
  ) into result
  from public.checklist_issues i
  join public.checklist_submissions s on s.id=i.source_submission_id
  where i.id=target_issue_id and i.organization_id=target_organization_id;

  if result is not null then
    return result;
  end if;

  select pg_catalog.jsonb_build_object(
    'id',row.id,'report_id',row.report_id,'branch_id',row.branch_id,
    'branch_name',row.branch_name,'business_date',row.business_date,
    'submitted_by',row.submitted_by,'checklist_type',row.checklist_type,
    'item_id',row.item_id,'item_text',row.item_text,
    'affected_staff_id',row.affected_staff_id,'affected_staff_name',row.affected_staff_name,
    'remark','Not checked' || chr(10) || row.description || chr(10) || 'No fake submission was created.',
    'status',row.status,'created_at',row.created_at
  ) into strict result
  from private.phase4a_managed_missed_issue_rows(target_organization_id) row
  where row.id=target_issue_id;

  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'issue access denied' using errcode='42501';
end $$;

create or replace function private.oil_tracking_managed_missed_issue_rows(target_organization_id uuid)
returns table(
  id uuid,
  report_id uuid,
  branch_id uuid,
  branch_name text,
  business_date date,
  supervisor_user_id uuid,
  submitted_by text,
  section text,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text
) language sql stable security definer set search_path = '' as $$
  with
  active_branches as materialized (
    select branch.id, branch.name, branch.timezone,
      private.phase4a_business_date(branch.timezone) business_date,
      private.management_oil_opening_closed(branch.timezone) opening_closed,
      private.management_branch_closed(branch.timezone) operational_closed
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
  selected_units as materialized (
    select branch.id branch_id, branch.name branch_name, branch.business_date,
      branch.opening_closed, branch.operational_closed, team.team_id, team.supervisor_user_id,
      team.supervisor_name, submission.id submission_id, submission.opening_submitted_at,
      submission.closing_submitted_at,
      coalesce(active_fryers.active_count, 0) active_count
    from active_branches branch
    join eligible_teams team on team.branch_id = branch.id
    left join lateral (
      select candidate.*
      from public.oil_tracking_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = branch.id
        and candidate.supervisor_team_id = team.team_id
        and candidate.business_date = branch.business_date
      order by candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
    left join lateral (
      select count(row.id)::int active_count
      from public.oil_tracking_fryer_results row
      where row.submission_id = submission.id
        and row.in_use_today
    ) active_fryers on true
  ),
  required_units as (
    select *
    from selected_units unit
    where unit.submission_id is null or unit.active_count > 0
  ),
  missed as (
    select unit.*, 'opening'::text section
    from required_units unit
    where unit.opening_closed and unit.opening_submitted_at is null
    union all
    select unit.*, 'closing'::text section
    from required_units unit
    where unit.operational_closed and unit.closing_submitted_at is null
  )
  select
    private.management_missed_issue_id('oil_tracking:missed:' || missed.section || ':' || missed.branch_id || ':' || missed.team_id || ':' || missed.business_date) id,
    coalesce(missed.submission_id, private.management_missed_issue_id('oil_tracking:missing-report:' || missed.branch_id || ':' || missed.team_id || ':' || missed.business_date)) report_id,
    missed.branch_id,
    missed.branch_name,
    missed.business_date,
    missed.supervisor_user_id,
    missed.supervisor_name submitted_by,
    missed.section,
    'Oil Tracking ' || missed.section || ' not checked' title,
    'Oil Tracking ' || missed.section || ' section was not submitted before its required close.' description,
    'new'::text status,
    (missed.business_date::timestamp + case missed.section when 'opening' then time '15:00' else time '03:00' end) at time zone branch.timezone created_at,
    'missed:' || missed.section item_id,
    'Missed ' || missed.section || ' check' item_text
  from missed
  join active_branches branch on branch.id = missed.branch_id
$$;
revoke all on function private.oil_tracking_managed_missed_issue_rows(uuid) from public, anon, authenticated;

create or replace function public.list_oil_tracking_managed_issues(
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
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or staff_filter is not null
    or (type_filter is not null and type_filter <> 'oil_tracking')
    or (status_filter is not null and status_filter <> 'new')
  then
    raise exception 'oil tracking issue access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'issues', coalesce((
      with combined as (
        select i.created_at, i.id, pg_catalog.jsonb_build_object(
          'id', i.id,'report_id', i.source_submission_id,'branch_id', i.branch_id,
          'branch_name', s.branch_name_snapshot,'business_date', s.business_date,
          'submitted_by', s.supervisor_name_snapshot,'checklist_type', 'oil_tracking',
          'title', i.title || ' - ' || i.fryer_label_snapshot,
          'description', case when i.section = 'closing' and i.tpm_status is not null then 'Closing TPM status: ' || replace(i.tpm_status, '_', ' ') || coalesce(nullif('. ' || i.remark, '. '), '') else coalesce(nullif(i.remark, ''), 'Opening oil check failed.') end,
          'status', i.status,'created_at', i.created_at,'item_id', i.fryer_id,
          'item_text', i.fryer_label_snapshot,'affected_staff_id', null,'affected_staff_name', null
        ) dto
        from public.oil_tracking_issues i
        join public.oil_tracking_submissions s on s.id = i.source_submission_id
        where i.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or i.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (status_filter is null or i.status = status_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or i.fryer_label_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%' or i.title ilike '%' || pg_catalog.btrim(search_term) || '%' or i.remark ilike '%' || pg_catalog.btrim(search_term) || '%' or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
        union all
        select row.created_at, row.id, pg_catalog.jsonb_build_object(
          'id', row.id,'report_id', row.report_id,'branch_id', row.branch_id,
          'branch_name', row.branch_name,'business_date', row.business_date,
          'submitted_by', row.submitted_by,'checklist_type', 'oil_tracking',
          'title', row.title,'description', row.description,'status', row.status,
          'created_at', row.created_at,'item_id', row.item_id,'item_text', row.item_text,
          'affected_staff_id', null,'affected_staff_name', null
        ) dto
        from private.oil_tracking_managed_missed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or row.title ilike '%' || pg_catalog.btrim(search_term) || '%' or row.description ilike '%' || pg_catalog.btrim(search_term) || '%' or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%' or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%')
      )
      select pg_catalog.jsonb_agg(dto order by created_at desc, id)
      from (select * from combined order by created_at desc, id offset (requested_page - 1) * requested_page_size limit requested_page_size) issue
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      with combined as (
        select i.id
        from public.oil_tracking_issues i
        join public.oil_tracking_submissions s on s.id = i.source_submission_id
        where i.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or i.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (status_filter is null or i.status = status_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or i.fryer_label_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%' or i.title ilike '%' || pg_catalog.btrim(search_term) || '%' or i.remark ilike '%' || pg_catalog.btrim(search_term) || '%' or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
        union all
        select row.id
        from private.oil_tracking_managed_missed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or row.title ilike '%' || pg_catalog.btrim(search_term) || '%' or row.description ilike '%' || pg_catalog.btrim(search_term) || '%' or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%' or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%')
      )
      select count(*) from combined
    )
  );
end $$;

create or replace function public.get_oil_tracking_managed_issue(actor_user_id uuid,target_organization_id uuid,target_issue_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'oil tracking issue access denied' using errcode = '42501';
  end if;
  select pg_catalog.jsonb_build_object(
    'id', i.id,'report_id', i.source_submission_id,'branch_id', i.branch_id,
    'branch_name', s.branch_name_snapshot,'business_date', s.business_date,
    'submitted_by', s.supervisor_name_snapshot,'checklist_type', 'oil_tracking',
    'item_id', i.fryer_id,'item_text', i.fryer_label_snapshot,
    'affected_staff_id', null,'affected_staff_name', null,
    'remark', case when i.section = 'closing' and i.tpm_status is not null then 'Section: closing' || chr(10) || 'TPM status: ' || replace(i.tpm_status, '_', ' ') || chr(10) || coalesce(i.remark, '') else 'Section: opening' || chr(10) || coalesce(i.remark, '') end,
    'status', i.status,'created_at', i.created_at
  ) into result
  from public.oil_tracking_issues i
  join public.oil_tracking_submissions s on s.id = i.source_submission_id
  where i.id = target_issue_id and i.organization_id = target_organization_id;
  if result is not null then return result; end if;
  select pg_catalog.jsonb_build_object(
    'id', row.id,'report_id', row.report_id,'branch_id', row.branch_id,
    'branch_name', row.branch_name,'business_date', row.business_date,
    'submitted_by', row.submitted_by,'checklist_type', 'oil_tracking',
    'item_id', row.item_id,'item_text', row.item_text,
    'affected_staff_id', null,'affected_staff_name', null,
    'remark', 'Not checked' || chr(10) || 'Section: ' || row.section || chr(10) || row.description || chr(10) || 'No fake submission was created.',
    'status', row.status,'created_at', row.created_at
  ) into strict result
  from private.oil_tracking_managed_missed_issue_rows(target_organization_id) row
  where row.id = target_issue_id;
  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'oil tracking issue access denied' using errcode = '42501';
end $$;

create or replace function private.cold_storage_managed_missed_issue_rows(target_organization_id uuid)
returns table(
  id uuid,
  report_id uuid,
  branch_id uuid,
  branch_name text,
  business_date date,
  supervisor_user_id uuid,
  submitted_by text,
  slot text,
  title text,
  description text,
  status text,
  created_at timestamptz,
  item_id text,
  item_text text
) language sql stable security definer set search_path = '' as $$
  with
  active_branches as materialized (
    select branch.id, branch.name, branch.timezone,
      private.phase4a_business_date(branch.timezone) business_date
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
  current_units as materialized (
    select branch.id branch_id, branch.name branch_name, branch.business_date, branch.timezone,
      team.team_id, team.supervisor_user_id, team.supervisor_name,
      submission.id submission_id, submission.updated_at,
      coalesce(equipment.active_count, 0) active_count
    from active_branches branch
    join eligible_teams team on team.branch_id = branch.id
    left join lateral (
      select candidate.*
      from public.cold_storage_submissions candidate
      where candidate.organization_id = target_organization_id
        and candidate.branch_id = branch.id
        and candidate.supervisor_team_id = team.team_id
        and candidate.business_date = branch.business_date
      order by candidate.updated_at desc, candidate.id
      limit 1
    ) submission on true
    left join lateral (
      select count(e.id)::int active_count
      from public.cold_storage_equipment e
      where e.submission_id = submission.id and e.active
    ) equipment on true
  ),
  submitted_units as materialized (
    select submission.branch_id, submission.branch_name_snapshot branch_name, submission.business_date,
      branch.timezone, submission.supervisor_team_id team_id, submission.supervisor_user_id,
      submission.supervisor_name_snapshot submitted_by, submission.id submission_id,
      submission.updated_at, coalesce(equipment.active_count, 0) active_count
    from public.cold_storage_submissions submission
    join public.branches branch
      on branch.id = submission.branch_id
      and branch.organization_id = submission.organization_id
      and branch.active
    left join lateral (
      select count(e.id)::int active_count
      from public.cold_storage_equipment e
      where e.submission_id = submission.id and e.active
    ) equipment on true
    where submission.organization_id = target_organization_id
      and submission.business_date <= private.phase4a_business_date(branch.timezone)
  ),
  selected_units as materialized (
    select * from current_units
    union
    select * from submitted_units
  ),
  submitted_slots as materialized (
    select unit.branch_id, unit.team_id, unit.business_date, unit.submission_id,
      coalesce(array_agg(distinct reading.slot) filter (where reading.slot is not null), array[]::text[]) slots
    from selected_units unit
    left join public.cold_storage_equipment equipment
      on equipment.submission_id = unit.submission_id and equipment.active
    left join public.cold_storage_readings reading
      on reading.submission_id = unit.submission_id
      and reading.equipment_id = equipment.equipment_id
      and reading.submitted_at is not null
    group by unit.branch_id, unit.team_id, unit.business_date, unit.submission_id
  ),
  required_units as (
    select unit.*, coalesce(submitted_slots.slots, array[]::text[]) submitted
    from selected_units unit
    left join submitted_slots
      on submitted_slots.branch_id = unit.branch_id
      and submitted_slots.team_id = unit.team_id
      and submitted_slots.business_date = unit.business_date
      and submitted_slots.submission_id is not distinct from unit.submission_id
    where unit.submission_id is null or unit.active_count > 0
  )
  select
    case when unit.submission_id is null
      then private.management_missed_issue_id('cold_storage:missed:' || unit.branch_id || ':' || unit.team_id || ':' || unit.business_date || ':' || missed.slot)
      else private.cold_storage_missed_issue_id(unit.submission_id, missed.slot)
    end id,
    coalesce(unit.submission_id, private.management_missed_issue_id('cold_storage:missing-report:' || unit.branch_id || ':' || unit.team_id || ':' || unit.business_date)) report_id,
    unit.branch_id,
    unit.branch_name,
    unit.business_date,
    unit.supervisor_user_id,
    unit.supervisor_name submitted_by,
    missed.slot,
    'Refrigerator & Freezer missed scheduled check - ' || missed.slot title,
    missed.slot || ' scheduled Refrigerator & Freezer check was not submitted.' description,
    'new'::text status,
    coalesce(unit.updated_at, (unit.business_date::timestamp + case missed.slot when '12:00' then time '15:00' when '3:00' then time '20:00' else time '03:00' end) at time zone unit.timezone) created_at,
    'missed:' || missed.slot item_id,
    'Missed ' || missed.slot || ' scheduled check' item_text
  from required_units unit
  cross join lateral unnest(private.cold_storage_missed_slots_for(unit.branch_id, unit.business_date, unit.submitted)) missed(slot)
$$;
revoke all on function private.cold_storage_managed_missed_issue_rows(uuid) from public, anon, authenticated;

create or replace function public.list_cold_storage_managed_issues(
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
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or staff_filter is not null
    or (type_filter is not null and type_filter <> 'cold_storage')
    or (status_filter is not null and status_filter <> 'new')
  then
    raise exception 'cold storage issue access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'issues', coalesce((
      with combined as (
        select i.created_at, i.id, pg_catalog.jsonb_build_object(
          'id', i.id,'report_id', i.submission_id,'branch_id', s.branch_id,
          'branch_name', s.branch_name_snapshot,'business_date', s.business_date,
          'submitted_by', s.supervisor_name_snapshot,'checklist_type', 'cold_storage',
          'title', 'Cold storage temperature issue - ' || coalesce(e.equipment_name, i.equipment_id),
          'description', i.slot || ' reading: ' || i.temperature_c || 'C. ' || i.corrective_action,
          'status', 'new','created_at', i.created_at,'item_id', i.equipment_id,
          'item_text', coalesce(e.equipment_name, i.equipment_id),'affected_staff_id', null,'affected_staff_name', null
        ) dto
        from public.cold_storage_issues i
        join public.cold_storage_submissions s on s.id = i.submission_id
        left join public.cold_storage_equipment e on e.submission_id = i.submission_id and e.equipment_id = i.equipment_id
        where s.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or coalesce(e.equipment_name, i.equipment_id) ilike '%' || pg_catalog.btrim(search_term) || '%' or i.corrective_action ilike '%' || pg_catalog.btrim(search_term) || '%' or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
        union all
        select row.created_at, row.id, pg_catalog.jsonb_build_object(
          'id', row.id,'report_id', row.report_id,'branch_id', row.branch_id,
          'branch_name', row.branch_name,'business_date', row.business_date,
          'submitted_by', row.submitted_by,'checklist_type', 'cold_storage',
          'title', row.title,'description', row.description,'status', row.status,
          'created_at', row.created_at,'item_id', row.item_id,'item_text', row.item_text,
          'affected_staff_id', null,'affected_staff_name', null
        ) dto
        from private.cold_storage_managed_missed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or row.title ilike '%' || pg_catalog.btrim(search_term) || '%' or row.description ilike '%' || pg_catalog.btrim(search_term) || '%' or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%' or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%')
      )
      select pg_catalog.jsonb_agg(dto order by created_at desc, id)
      from (select * from combined order by created_at desc, id offset (requested_page - 1) * requested_page_size limit requested_page_size) issue
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      with combined as (
        select i.id
        from public.cold_storage_issues i
        join public.cold_storage_submissions s on s.id = i.submission_id
        left join public.cold_storage_equipment e on e.submission_id = i.submission_id and e.equipment_id = i.equipment_id
        where s.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or coalesce(e.equipment_name, i.equipment_id) ilike '%' || pg_catalog.btrim(search_term) || '%' or i.corrective_action ilike '%' || pg_catalog.btrim(search_term) || '%' or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
        union all
        select row.id
        from private.cold_storage_managed_missed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null or row.title ilike '%' || pg_catalog.btrim(search_term) || '%' or row.description ilike '%' || pg_catalog.btrim(search_term) || '%' or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%' or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%')
      )
      select count(*) from combined
    )
  );
end $$;

create or replace function public.get_cold_storage_managed_issue(actor_user_id uuid,target_organization_id uuid,target_issue_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'cold storage issue access denied' using errcode = '42501';
  end if;
  select pg_catalog.jsonb_build_object(
    'id', i.id,'report_id', i.submission_id,'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,'business_date', s.business_date,
    'submitted_by', s.supervisor_name_snapshot,'checklist_type', 'cold_storage',
    'item_id', i.equipment_id,'item_text', coalesce(e.equipment_name, i.equipment_id),
    'affected_staff_id', null,'affected_staff_name', null,
    'remark', 'Slot: ' || i.slot || chr(10) || 'Temperature: ' || i.temperature_c || 'C' || chr(10) || i.corrective_action,
    'status', 'new','created_at', i.created_at
  ) into result
  from public.cold_storage_issues i
  join public.cold_storage_submissions s on s.id = i.submission_id
  left join public.cold_storage_equipment e on e.submission_id = i.submission_id and e.equipment_id = i.equipment_id
  where i.id = target_issue_id and s.organization_id = target_organization_id;
  if result is not null then return result; end if;
  select pg_catalog.jsonb_build_object(
    'id', row.id,'report_id', row.report_id,'branch_id', row.branch_id,
    'branch_name', row.branch_name,'business_date', row.business_date,
    'submitted_by', row.submitted_by,'checklist_type', 'cold_storage',
    'item_id', row.item_id,'item_text', row.item_text,
    'affected_staff_id', null,'affected_staff_name', null,
    'remark', 'Missed scheduled check' || chr(10) || 'Slot: ' || row.slot || chr(10) || 'No fake submission was created.',
    'status', row.status,'created_at', row.created_at
  ) into strict result
  from private.cold_storage_managed_missed_issue_rows(target_organization_id) row
  where row.id = target_issue_id;
  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage issue access denied' using errcode = '42501';
end $$;

revoke all on function public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_phase4a_managed_issue(uuid,uuid,uuid),
  public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_oil_tracking_managed_issue(uuid,uuid,uuid),
  public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_cold_storage_managed_issue(uuid,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_phase4a_managed_issue(uuid,uuid,uuid),
  public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_oil_tracking_managed_issue(uuid,uuid,uuid),
  public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_cold_storage_managed_issue(uuid,uuid,uuid)
to service_role;
