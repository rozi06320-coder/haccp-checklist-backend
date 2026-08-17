create or replace function private.cold_storage_due_slots_for(target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp())
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare branch_timezone text; local_date date; local_hour int;
begin
  select timezone into strict branch_timezone from public.branches where id = target_branch_id;
  local_date := (as_of at time zone branch_timezone)::date;
  local_hour := extract(hour from as_of at time zone branch_timezone)::int;
  if target_business_date < local_date then
    return array['12:00','3:00','8:00']::text[];
  elsif target_business_date > local_date then
    return array[]::text[];
  elsif local_hour < 12 then
    return array[]::text[];
  elsif local_hour < 15 then
    return array['12:00']::text[];
  elsif local_hour < 20 then
    return array['12:00','3:00']::text[];
  else
    return array['12:00','3:00','8:00']::text[];
  end if;
end $$;

create or replace function private.cold_storage_closed_slots_for(target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp())
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare branch_timezone text; local_date date; local_hour int;
begin
  select timezone into strict branch_timezone from public.branches where id = target_branch_id;
  local_date := (as_of at time zone branch_timezone)::date;
  local_hour := extract(hour from as_of at time zone branch_timezone)::int;
  if target_business_date < local_date then
    return array['12:00','3:00','8:00']::text[];
  elsif target_business_date > local_date or local_hour < 15 then
    return array[]::text[];
  elsif local_hour < 20 then
    return array['12:00']::text[];
  else
    return array['12:00','3:00']::text[];
  end if;
end $$;

create or replace function private.cold_storage_missed_slots_for(
  target_branch_id uuid,
  target_business_date date,
  submitted_slots text[],
  as_of timestamptz default pg_catalog.statement_timestamp()
) returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(slot order by case slot when '12:00' then 1 when '3:00' then 2 else 3 end), array[]::text[])
  from unnest(private.cold_storage_closed_slots_for(target_branch_id, target_business_date, as_of)) slot
  where not slot = any(coalesce(submitted_slots, array[]::text[]));
$$;

create or replace function private.cold_storage_missed_issue_id(submission_id uuid, slot text)
returns uuid language sql immutable security definer set search_path = '' as $$
  select (
    substr(md5(submission_id::text || ':cold_storage_missed:' || slot), 1, 8) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_missed:' || slot), 9, 4) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_missed:' || slot), 13, 4) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_missed:' || slot), 17, 4) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_missed:' || slot), 21, 12)
  )::uuid;
$$;

revoke all on function private.cold_storage_due_slots_for(uuid,date,timestamptz),
  private.cold_storage_closed_slots_for(uuid,date,timestamptz),
  private.cold_storage_missed_slots_for(uuid,date,text[],timestamptz),
  private.cold_storage_missed_issue_id(uuid,text)
from public, anon, authenticated;

create or replace function public.list_cold_storage_supervisor_reports(
  actor_user_id uuid,
  target_branch_id uuid,
  requested_page int default 1,
  requested_page_size int default 20
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  if requested_page < 1 or requested_page_size not between 1 and 50 then
    raise exception 'invalid cold storage report list' using errcode = '22023';
  end if;
  return pg_catalog.jsonb_build_object(
    'reports', coalesce((
      select pg_catalog.jsonb_agg(q.row_data order by q.business_date desc, q.submitted_at desc)
      from (
        select
          s.business_date,
          report.submitted_at,
          pg_catalog.jsonb_build_object(
            'id', s.id,
            'branch_id', s.branch_id,
            'checklist_type', 'cold_storage',
            'business_date', s.business_date,
            'submitted_at', report.submitted_at,
            'submitted_by', s.supervisor_name_snapshot,
            'completion', case when cardinality(report.due_slots) = 0 then 0 else pg_catalog.round((cardinality(report.submitted_slots)::numeric * 100) / cardinality(report.due_slots)) end,
            'issue_count', report.temperature_issue_count + cardinality(report.missed_slots),
            'missed_check_count', cardinality(report.missed_slots),
            'missed_slots', to_jsonb(report.missed_slots),
            'status',
              case
                when cardinality(report.missed_slots) > 0 or report.temperature_issue_count > 0 then 'issues_found'
                when cardinality(report.submitted_slots) < cardinality(report.due_slots) then 'in_progress'
                else 'compliant'
              end,
            'submitted_slots', to_jsonb(report.submitted_slots)
          ) row_data
        from public.cold_storage_submissions s
        cross join lateral (
          select
            coalesce(array_agg(distinct r.slot order by r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots,
            max(r.submitted_at) submitted_at,
            private.cold_storage_due_slots_for(s.branch_id, s.business_date) due_slots,
            private.cold_storage_missed_slots_for(s.branch_id, s.business_date, coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[])) missed_slots,
            (select count(*)::int from public.cold_storage_issues i where i.submission_id = s.id) temperature_issue_count
          from public.cold_storage_equipment e
          join public.cold_storage_readings r on r.submission_id = e.submission_id
            and r.equipment_id = e.equipment_id
            and r.submitted_at is not null
          where e.submission_id = s.id
            and e.active
        ) report
        where s.supervisor_team_id = c.team_id
          and s.branch_id = c.branch_id
          and report.submitted_at is not null
        order by s.business_date desc, report.submitted_at desc
        limit requested_page_size offset ((requested_page - 1) * requested_page_size)
      ) q
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from public.cold_storage_submissions s
      where s.supervisor_team_id = c.team_id
        and s.branch_id = c.branch_id
        and exists (
          select 1
          from public.cold_storage_equipment e
          join public.cold_storage_readings r on r.submission_id = e.submission_id
            and r.equipment_id = e.equipment_id
            and r.submitted_at is not null
          where e.submission_id = s.id
            and e.active
        )
    )
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage report access denied' using errcode = '42501';
end $$;

create or replace function public.get_cold_storage_report_detail(
  actor_user_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.cold_storage_submissions%rowtype; submitted_time timestamptz; temperature_issue_total bigint; submitted_slot_array text[]; due_slot_array text[]; missed_slot_array text[];
begin
  select * into strict s from public.cold_storage_submissions x
  where x.id = target_report_id
    and exists (
      select 1
      from public.cold_storage_equipment e
      join public.cold_storage_readings r on r.submission_id = e.submission_id
        and r.equipment_id = e.equipment_id
        and r.submitted_at is not null
      where e.submission_id = x.id
        and e.active
    );
  if not (s.supervisor_user_id = actor_user_id and private.actor_owns_operational_team(actor_user_id, s.branch_id, s.supervisor_team_id)) then
    raise exception 'cold storage report access denied' using errcode = '42501';
  end if;
  select max(r.submitted_at), coalesce(array_agg(distinct r.slot), array[]::text[]) into submitted_time, submitted_slot_array
  from public.cold_storage_readings r
  join public.cold_storage_equipment e on e.submission_id = r.submission_id
    and e.equipment_id = r.equipment_id
    and e.active
  where r.submission_id = s.id
    and r.submitted_at is not null;
  due_slot_array := private.cold_storage_due_slots_for(s.branch_id, s.business_date);
  missed_slot_array := private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted_slot_array);
  select count(*) into temperature_issue_total from public.cold_storage_issues i where i.submission_id = s.id;
  return pg_catalog.jsonb_build_object(
    'id', s.id,
    'organization_id', s.organization_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'supervisor_team_id', s.supervisor_team_id,
    'business_date', s.business_date,
    'checklist_type', 'cold_storage',
    'definition_id', 'cold_storage_v1',
    'submitted_at', submitted_time,
    'submitted_by', s.supervisor_name_snapshot,
    'completion', case when cardinality(due_slot_array) = 0 then 0 else pg_catalog.round((cardinality(submitted_slot_array)::numeric * 100) / cardinality(due_slot_array)) end,
    'issue_count', temperature_issue_total + cardinality(missed_slot_array),
    'missed_check_count', cardinality(missed_slot_array),
    'missed_slots', to_jsonb(missed_slot_array),
    'status',
      case
        when temperature_issue_total > 0 or cardinality(missed_slot_array) > 0 then 'issues_found'
        when cardinality(submitted_slot_array) < cardinality(due_slot_array) then 'in_progress'
        else 'compliant'
      end,
    'submitted_slots', to_jsonb(submitted_slot_array),
    'rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'equipment_id', e.equipment_id,
        'equipment_name', e.equipment_name,
        'equipment_type', e.equipment_type,
        'active', e.active,
        'slot', r.slot,
        'temperature_c', r.temperature_c,
        'status', r.status,
        'corrective_action', r.corrective_action,
        'submitted_at', r.submitted_at
      ) order by r.slot, e.equipment_id)
      from public.cold_storage_readings r
      join public.cold_storage_equipment e on e.submission_id = r.submission_id
        and e.equipment_id = r.equipment_id
      where r.submission_id = s.id
        and r.submitted_at is not null
    ), '[]'::jsonb),
    'issues', coalesce((
      select pg_catalog.jsonb_agg(issue.row_data order by issue.sort_slot, issue.equipment_id)
      from (
        select i.slot sort_slot, i.equipment_id, pg_catalog.jsonb_build_object(
          'id', i.id,
          'equipment_id', i.equipment_id,
          'equipment_name', coalesce(e.equipment_name, i.equipment_id),
          'slot', i.slot,
          'temperature_c', i.temperature_c,
          'title', 'Cold Storage temperature issue',
          'remark', i.corrective_action
        ) row_data
        from public.cold_storage_issues i
        left join public.cold_storage_equipment e on e.submission_id = i.submission_id
          and e.equipment_id = i.equipment_id
        where i.submission_id = s.id
      ) issue
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage report access denied' using errcode = '42501';
end $$;

revoke all on function public.list_cold_storage_supervisor_reports(uuid,uuid,int,int),
  public.get_cold_storage_report_detail(uuid,uuid)
from public, anon, authenticated;
grant execute on function public.list_cold_storage_supervisor_reports(uuid,uuid,int,int),
  public.get_cold_storage_report_detail(uuid,uuid)
to service_role;

create or replace function public.list_cold_storage_managed_reports(
  actor_user_id uuid,
  target_organization_id uuid,
  requested_page int default 1,
  requested_page_size int default 20,
  date_from date default null,
  date_to date default null,
  branch_filter uuid default null,
  supervisor_filter uuid default null,
  status_filter text default null,
  search_term text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or (status_filter is not null and status_filter not in ('compliant', 'issues_found')) then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
  end if;
  return pg_catalog.jsonb_build_object(
    'reports', coalesce((
      select pg_catalog.jsonb_agg(q.row_data order by q.business_date desc, q.submitted_at desc, q.id desc)
      from (
        select
          s.id,
          s.business_date,
          report.submitted_at,
          pg_catalog.jsonb_build_object(
            'id', s.id,
            'branch_id', s.branch_id,
            'branch_name', s.branch_name_snapshot,
            'checklist_type', 'cold_storage',
            'definition_id', 'cold_storage_v1',
            'business_date', s.business_date,
            'submitted_at', report.submitted_at,
            'submitted_by', s.supervisor_name_snapshot,
            'supervisor_user_id', s.supervisor_user_id,
            'completion', case when cardinality(report.due_slots) = 0 then 0 else pg_catalog.round((cardinality(report.submitted_slots)::numeric * 100) / cardinality(report.due_slots)) end,
            'issue_count', report.temperature_issue_count + cardinality(report.missed_slots),
            'missed_check_count', cardinality(report.missed_slots),
            'missed_slots', to_jsonb(report.missed_slots),
            'status', report.report_status,
            'submitted_slots', to_jsonb(report.submitted_slots)
          ) row_data
        from public.cold_storage_submissions s
        cross join lateral (
          select
            base.submitted_slots,
            base.submitted_at,
            base.due_slots,
            base.missed_slots,
            base.temperature_issue_count,
            case
              when cardinality(base.missed_slots) > 0 or base.temperature_issue_count > 0 then 'issues_found'
              when cardinality(base.submitted_slots) < cardinality(base.due_slots) then 'in_progress'
              else 'compliant'
            end report_status
          from (
            select
              coalesce(array_agg(distinct r.slot order by r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots,
              max(r.submitted_at) submitted_at,
              private.cold_storage_due_slots_for(s.branch_id, s.business_date) due_slots,
              private.cold_storage_missed_slots_for(s.branch_id, s.business_date, coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[])) missed_slots,
              (select count(*)::int from public.cold_storage_issues i where i.submission_id = s.id) temperature_issue_count
            from public.cold_storage_equipment e
            join public.cold_storage_readings r on r.submission_id = e.submission_id
              and r.equipment_id = e.equipment_id
              and r.submitted_at is not null
            where e.submission_id = s.id
              and e.active
          ) base
        ) report
        where s.organization_id = target_organization_id
          and report.submitted_at is not null
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (status_filter is null or report.report_status = status_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or exists (
              select 1
              from unnest(report.missed_slots) missed_slot
              where ('missed ' || missed_slot) ilike '%' || pg_catalog.btrim(search_term) || '%'
            ))
        order by s.business_date desc, report.submitted_at desc, s.id desc
        limit requested_page_size offset ((requested_page - 1) * requested_page_size)
      ) q
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from public.cold_storage_submissions s
      cross join lateral (
        select
          base.submitted_at,
          case
            when cardinality(base.missed_slots) > 0 or base.temperature_issue_count > 0 then 'issues_found'
            when cardinality(base.submitted_slots) < cardinality(base.due_slots) then 'in_progress'
            else 'compliant'
          end report_status,
          base.missed_slots
        from (
          select
            coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots,
            max(r.submitted_at) submitted_at,
            private.cold_storage_due_slots_for(s.branch_id, s.business_date) due_slots,
            private.cold_storage_missed_slots_for(s.branch_id, s.business_date, coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[])) missed_slots,
            (select count(*)::int from public.cold_storage_issues i where i.submission_id = s.id) temperature_issue_count
          from public.cold_storage_equipment e
          join public.cold_storage_readings r on r.submission_id = e.submission_id
            and r.equipment_id = e.equipment_id
            and r.submitted_at is not null
          where e.submission_id = s.id
            and e.active
        ) base
      ) report
      where s.organization_id = target_organization_id
        and report.submitted_at is not null
        and (date_from is null or s.business_date >= date_from)
        and (date_to is null or s.business_date <= date_to)
        and (branch_filter is null or s.branch_id = branch_filter)
        and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
        and (status_filter is null or report.report_status = status_filter)
        and (nullif(pg_catalog.btrim(search_term), '') is null
          or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          or exists (
            select 1
            from unnest(report.missed_slots) missed_slot
            where ('missed ' || missed_slot) ilike '%' || pg_catalog.btrim(search_term) || '%'
          ))
    )
  );
end $$;

create or replace function public.get_cold_storage_managed_report_detail(
  actor_user_id uuid,
  target_organization_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.cold_storage_submissions%rowtype; submitted_time timestamptz; temperature_issue_total bigint; submitted_slot_array text[]; due_slot_array text[]; missed_slot_array text[];
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
  end if;
  select * into strict s from public.cold_storage_submissions x
  where x.id = target_report_id
    and x.organization_id = target_organization_id
    and exists (
      select 1
      from public.cold_storage_equipment e
      join public.cold_storage_readings r on r.submission_id = e.submission_id
        and r.equipment_id = e.equipment_id
        and r.submitted_at is not null
      where e.submission_id = x.id
        and e.active
    );
  select max(r.submitted_at), coalesce(array_agg(distinct r.slot), array[]::text[]) into submitted_time, submitted_slot_array
  from public.cold_storage_readings r
  join public.cold_storage_equipment e on e.submission_id = r.submission_id
    and e.equipment_id = r.equipment_id
    and e.active
  where r.submission_id = s.id
    and r.submitted_at is not null;
  due_slot_array := private.cold_storage_due_slots_for(s.branch_id, s.business_date);
  missed_slot_array := private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted_slot_array);
  select count(*) into temperature_issue_total from public.cold_storage_issues i where i.submission_id = s.id;
  return pg_catalog.jsonb_build_object(
    'id', s.id,
    'organization_id', s.organization_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'supervisor_team_id', s.supervisor_team_id,
    'business_date', s.business_date,
    'checklist_type', 'cold_storage',
    'definition_id', 'cold_storage_v1',
    'submitted_at', submitted_time,
    'submitted_by', s.supervisor_name_snapshot,
    'completion', case when cardinality(due_slot_array) = 0 then 0 else pg_catalog.round((cardinality(submitted_slot_array)::numeric * 100) / cardinality(due_slot_array)) end,
    'issue_count', temperature_issue_total + cardinality(missed_slot_array),
    'missed_check_count', cardinality(missed_slot_array),
    'missed_slots', to_jsonb(missed_slot_array),
    'status',
      case
        when temperature_issue_total > 0 or cardinality(missed_slot_array) > 0 then 'issues_found'
        when cardinality(submitted_slot_array) < cardinality(due_slot_array) then 'in_progress'
        else 'compliant'
      end,
    'submitted_slots', to_jsonb(submitted_slot_array),
    'rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'equipment_id', e.equipment_id,
        'equipment_name', e.equipment_name,
        'equipment_type', e.equipment_type,
        'active', e.active,
        'slot', r.slot,
        'temperature_c', r.temperature_c,
        'status', r.status,
        'corrective_action', r.corrective_action,
        'submitted_at', r.submitted_at
      ) order by r.slot, e.equipment_id)
      from public.cold_storage_readings r
      join public.cold_storage_equipment e on e.submission_id = r.submission_id
        and e.equipment_id = r.equipment_id
      where r.submission_id = s.id
        and r.submitted_at is not null
    ), '[]'::jsonb),
    'issues', coalesce((
      select pg_catalog.jsonb_agg(issue.row_data order by issue.sort_slot, issue.equipment_id)
      from (
        select i.slot sort_slot, i.equipment_id, pg_catalog.jsonb_build_object(
          'id', i.id,
          'equipment_id', i.equipment_id,
          'equipment_name', coalesce(e.equipment_name, i.equipment_id),
          'slot', i.slot,
          'temperature_c', i.temperature_c,
          'title', 'Cold Storage temperature issue',
          'remark', i.corrective_action
        ) row_data
        from public.cold_storage_issues i
        left join public.cold_storage_equipment e on e.submission_id = i.submission_id
          and e.equipment_id = i.equipment_id
        where i.submission_id = s.id
      ) issue
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
end $$;

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
    or (staff_filter is not null)
    or (type_filter is not null and type_filter <> 'cold_storage')
    or (status_filter is not null and status_filter <> 'new') then
    raise exception 'cold storage issue access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'issues', coalesce((
      with combined as (
        select i.created_at, i.id, pg_catalog.jsonb_build_object(
          'id', i.id,
          'report_id', i.submission_id,
          'branch_id', s.branch_id,
          'branch_name', s.branch_name_snapshot,
          'business_date', s.business_date,
          'submitted_by', s.supervisor_name_snapshot,
          'checklist_type', 'cold_storage',
          'title', 'Cold storage temperature issue - ' || coalesce(e.equipment_name, i.equipment_id),
          'description', i.slot || ' reading: ' || i.temperature_c || 'C. ' || i.corrective_action,
          'status', 'new',
          'created_at', i.created_at,
          'item_id', i.equipment_id,
          'item_text', coalesce(e.equipment_name, i.equipment_id),
          'affected_staff_id', null,
          'affected_staff_name', null
        ) dto
        from public.cold_storage_issues i
        join public.cold_storage_submissions s on s.id = i.submission_id
        left join public.cold_storage_equipment e
          on e.submission_id = i.submission_id and e.equipment_id = i.equipment_id
        where s.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or coalesce(e.equipment_name, i.equipment_id) ilike '%' || pg_catalog.btrim(search_term) || '%'
            or i.corrective_action ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
        union all
        select s.updated_at created_at, private.cold_storage_missed_issue_id(s.id, missed.slot) id, pg_catalog.jsonb_build_object(
          'id', private.cold_storage_missed_issue_id(s.id, missed.slot),
          'report_id', s.id,
          'branch_id', s.branch_id,
          'branch_name', s.branch_name_snapshot,
          'business_date', s.business_date,
          'submitted_by', s.supervisor_name_snapshot,
          'checklist_type', 'cold_storage',
          'title', 'Refrigerator & Freezer missed scheduled check - ' || missed.slot,
          'description', missed.slot || ' scheduled Refrigerator & Freezer check was not submitted.',
          'status', 'new',
          'created_at', s.updated_at,
          'item_id', 'missed:' || missed.slot,
          'item_text', 'Missed ' || missed.slot || ' scheduled check',
          'affected_staff_id', null,
          'affected_staff_name', null
        ) dto
        from public.cold_storage_submissions s
        cross join lateral (
          select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots
          from public.cold_storage_equipment e
          left join public.cold_storage_readings r on r.submission_id = e.submission_id
            and r.equipment_id = e.equipment_id
            and r.submitted_at is not null
          where e.submission_id = s.id
            and e.active
        ) submitted
        cross join lateral unnest(private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted.submitted_slots)) missed(slot)
        where s.organization_id = target_organization_id
          and exists (select 1 from public.cold_storage_equipment e where e.submission_id = s.id and e.active)
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or ('missed ' || missed.slot) ilike '%' || pg_catalog.btrim(search_term) || '%'
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
        from public.cold_storage_issues i
        join public.cold_storage_submissions s on s.id = i.submission_id
        left join public.cold_storage_equipment e
          on e.submission_id = i.submission_id and e.equipment_id = i.equipment_id
        where s.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or coalesce(e.equipment_name, i.equipment_id) ilike '%' || pg_catalog.btrim(search_term) || '%'
            or i.corrective_action ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
        union all
        select private.cold_storage_missed_issue_id(s.id, missed.slot) id
        from public.cold_storage_submissions s
        cross join lateral (
          select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots
          from public.cold_storage_equipment e
          left join public.cold_storage_readings r on r.submission_id = e.submission_id
            and r.equipment_id = e.equipment_id
            and r.submitted_at is not null
          where e.submission_id = s.id
            and e.active
        ) submitted
        cross join lateral unnest(private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted.submitted_slots)) missed(slot)
        where s.organization_id = target_organization_id
          and exists (select 1 from public.cold_storage_equipment e where e.submission_id = s.id and e.active)
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or ('missed ' || missed.slot) ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
      )
      select count(*) from combined
    )
  );
end $$;

create or replace function public.get_cold_storage_managed_issue(
  actor_user_id uuid,
  target_organization_id uuid,
  target_issue_id uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'cold storage issue access denied' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id', i.id,
    'report_id', i.submission_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'business_date', s.business_date,
    'submitted_by', s.supervisor_name_snapshot,
    'checklist_type', 'cold_storage',
    'item_id', i.equipment_id,
    'item_text', coalesce(e.equipment_name, i.equipment_id),
    'affected_staff_id', null,
    'affected_staff_name', null,
    'remark', 'Slot: ' || i.slot || chr(10) || 'Temperature: ' || i.temperature_c || 'C' || chr(10) || i.corrective_action,
    'status', 'new',
    'created_at', i.created_at
  ) into result
  from public.cold_storage_issues i
  join public.cold_storage_submissions s on s.id = i.submission_id
  left join public.cold_storage_equipment e
    on e.submission_id = i.submission_id and e.equipment_id = i.equipment_id
  where i.id = target_issue_id and s.organization_id = target_organization_id;

  if result is not null then
    return result;
  end if;

  select pg_catalog.jsonb_build_object(
    'id', private.cold_storage_missed_issue_id(s.id, missed.slot),
    'report_id', s.id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'business_date', s.business_date,
    'submitted_by', s.supervisor_name_snapshot,
    'checklist_type', 'cold_storage',
    'item_id', 'missed:' || missed.slot,
    'item_text', 'Missed ' || missed.slot || ' scheduled check',
    'affected_staff_id', null,
    'affected_staff_name', null,
    'remark', 'Missed scheduled check' || chr(10) || 'Slot: ' || missed.slot,
    'status', 'new',
    'created_at', s.updated_at
  ) into strict result
  from public.cold_storage_submissions s
  cross join lateral (
    select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots
    from public.cold_storage_equipment e
    left join public.cold_storage_readings r on r.submission_id = e.submission_id
      and r.equipment_id = e.equipment_id
      and r.submitted_at is not null
    where e.submission_id = s.id
      and e.active
  ) submitted
  cross join lateral unnest(private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted.submitted_slots)) missed(slot)
  where s.organization_id = target_organization_id
    and exists (select 1 from public.cold_storage_equipment e where e.submission_id = s.id and e.active)
    and private.cold_storage_missed_issue_id(s.id, missed.slot) = target_issue_id;

  return result;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage issue access denied' using errcode = '42501';
end $$;

revoke all on function public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_cold_storage_managed_report_detail(uuid,uuid,uuid),
  public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_cold_storage_managed_issue(uuid,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_cold_storage_managed_report_detail(uuid,uuid,uuid),
  public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text),
  public.get_cold_storage_managed_issue(uuid,uuid,uuid)
to service_role;
