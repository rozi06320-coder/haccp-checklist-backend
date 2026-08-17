create or replace function private.cold_storage_missed_report_id(submission_id uuid)
returns uuid language sql immutable security definer set search_path = '' as $$
  select (
    substr(md5(submission_id::text || ':cold_storage_not_checked_report'), 1, 8) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_not_checked_report'), 9, 4) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_not_checked_report'), 13, 4) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_not_checked_report'), 17, 4) || '-' ||
    substr(md5(submission_id::text || ':cold_storage_not_checked_report'), 21, 12)
  )::uuid;
$$;

revoke all on function private.cold_storage_missed_report_id(uuid) from public, anon, authenticated;

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
    or (status_filter is not null and status_filter not in ('compliant', 'issues_found', 'in_progress', 'not_checked')) then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'reports', coalesce((
      with report_base as (
        select
          s.id,
          s.branch_id,
          s.branch_name_snapshot,
          s.supervisor_user_id,
          s.supervisor_name_snapshot,
          s.business_date,
          s.updated_at,
          report.submitted_slots,
          report.submitted_at,
          report.due_slots,
          report.missed_slots,
          report.temperature_issue_count,
          report.active_equipment_count
        from public.cold_storage_submissions s
        cross join lateral (
          select
            coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots,
            max(r.submitted_at) submitted_at,
            private.cold_storage_due_slots_for(s.branch_id, s.business_date) due_slots,
            private.cold_storage_missed_slots_for(s.branch_id, s.business_date, coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[])) missed_slots,
            (select count(*)::int from public.cold_storage_issues i where i.submission_id = s.id) temperature_issue_count,
            count(distinct e.equipment_id)::int active_equipment_count
          from public.cold_storage_equipment e
          left join public.cold_storage_readings r on r.submission_id = e.submission_id
            and r.equipment_id = e.equipment_id
            and r.submitted_at is not null
          where e.submission_id = s.id
            and e.active
        ) report
        where s.organization_id = target_organization_id
          and report.active_equipment_count > 0
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
      ),
      combined as (
        select
          b.id,
          b.business_date,
          b.submitted_at sort_time,
          case
            when cardinality(b.missed_slots) > 0 or b.temperature_issue_count > 0 then 'issues_found'
            when cardinality(b.submitted_slots) < cardinality(b.due_slots) then 'in_progress'
            else 'compliant'
          end report_status,
          b.branch_name_snapshot search_branch,
          b.supervisor_name_snapshot search_supervisor,
          b.missed_slots,
          pg_catalog.jsonb_build_object(
            'id', b.id,
            'record_kind', 'submission',
            'source_submission_id', b.id,
            'branch_id', b.branch_id,
            'branch_name', b.branch_name_snapshot,
            'checklist_type', 'cold_storage',
            'definition_id', 'cold_storage_v1',
            'business_date', b.business_date,
            'submitted_at', b.submitted_at,
            'submitted_by', b.supervisor_name_snapshot,
            'supervisor_user_id', b.supervisor_user_id,
            'completion', case when cardinality(b.due_slots) = 0 then 0 else pg_catalog.round((cardinality(b.submitted_slots)::numeric * 100) / cardinality(b.due_slots)) end,
            'issue_count', b.temperature_issue_count + cardinality(b.missed_slots),
            'missed_check_count', cardinality(b.missed_slots),
            'missed_slots', to_jsonb(b.missed_slots),
            'status', case
              when cardinality(b.missed_slots) > 0 or b.temperature_issue_count > 0 then 'issues_found'
              when cardinality(b.submitted_slots) < cardinality(b.due_slots) then 'in_progress'
              else 'compliant'
            end,
            'submitted_slots', to_jsonb(b.submitted_slots)
          ) row_data
        from report_base b
        where b.submitted_at is not null
        union all
        select
          private.cold_storage_missed_report_id(b.id) id,
          b.business_date,
          b.updated_at sort_time,
          'not_checked' report_status,
          b.branch_name_snapshot search_branch,
          b.supervisor_name_snapshot search_supervisor,
          b.missed_slots,
          pg_catalog.jsonb_build_object(
            'id', private.cold_storage_missed_report_id(b.id),
            'record_kind', 'derived_missing',
            'source_submission_id', b.id,
            'branch_id', b.branch_id,
            'branch_name', b.branch_name_snapshot,
            'checklist_type', 'cold_storage',
            'definition_id', 'cold_storage_v1',
            'business_date', b.business_date,
            'submitted_at', null,
            'submitted_by', null,
            'supervisor_user_id', b.supervisor_user_id,
            'completion', 0,
            'issue_count', cardinality(b.missed_slots),
            'missed_check_count', cardinality(b.missed_slots),
            'missed_slots', to_jsonb(b.missed_slots),
            'status', 'not_checked',
            'submitted_slots', to_jsonb(b.submitted_slots)
          ) row_data
        from report_base b
        where cardinality(b.missed_slots) > 0
      )
      select pg_catalog.jsonb_agg(row_data order by business_date desc, sort_time desc nulls last, id desc)
      from (
        select *
        from combined
        where (status_filter is null or report_status = status_filter)
          and (nullif(pg_catalog.btrim(search_term), '') is null
            or search_branch ilike '%' || pg_catalog.btrim(search_term) || '%'
            or search_supervisor ilike '%' || pg_catalog.btrim(search_term) || '%'
            or exists (
              select 1
              from unnest(missed_slots) missed_slot
              where ('missed ' || missed_slot) ilike '%' || pg_catalog.btrim(search_term) || '%'
            ))
        order by business_date desc, sort_time desc nulls last, id desc
        limit requested_page_size offset ((requested_page - 1) * requested_page_size)
      ) page_rows
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      with report_base as (
        select
          s.id,
          s.branch_name_snapshot,
          s.supervisor_name_snapshot,
          s.business_date,
          report.submitted_slots,
          report.submitted_at,
          report.due_slots,
          report.missed_slots,
          report.temperature_issue_count,
          report.active_equipment_count
        from public.cold_storage_submissions s
        cross join lateral (
          select
            coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots,
            max(r.submitted_at) submitted_at,
            private.cold_storage_due_slots_for(s.branch_id, s.business_date) due_slots,
            private.cold_storage_missed_slots_for(s.branch_id, s.business_date, coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[])) missed_slots,
            (select count(*)::int from public.cold_storage_issues i where i.submission_id = s.id) temperature_issue_count,
            count(distinct e.equipment_id)::int active_equipment_count
          from public.cold_storage_equipment e
          left join public.cold_storage_readings r on r.submission_id = e.submission_id
            and r.equipment_id = e.equipment_id
            and r.submitted_at is not null
          where e.submission_id = s.id
            and e.active
        ) report
        where s.organization_id = target_organization_id
          and report.active_equipment_count > 0
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
      ),
      combined as (
        select id, business_date, branch_name_snapshot search_branch, supervisor_name_snapshot search_supervisor, missed_slots,
          case
            when cardinality(missed_slots) > 0 or temperature_issue_count > 0 then 'issues_found'
            when cardinality(submitted_slots) < cardinality(due_slots) then 'in_progress'
            else 'compliant'
          end report_status
        from report_base
        where submitted_at is not null
        union all
        select private.cold_storage_missed_report_id(id), business_date, branch_name_snapshot, supervisor_name_snapshot, missed_slots, 'not_checked'
        from report_base
        where cardinality(missed_slots) > 0
      )
      select count(*)
      from combined
      where (status_filter is null or report_status = status_filter)
        and (nullif(pg_catalog.btrim(search_term), '') is null
          or search_branch ilike '%' || pg_catalog.btrim(search_term) || '%'
          or search_supervisor ilike '%' || pg_catalog.btrim(search_term) || '%'
          or exists (
            select 1
            from unnest(missed_slots) missed_slot
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

  select * into s from public.cold_storage_submissions x
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

  if found then
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
      'record_kind', 'submission',
      'source_submission_id', s.id,
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
  end if;

  select x.* into strict s
  from public.cold_storage_submissions x
  cross join lateral (
    select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots
    from public.cold_storage_equipment e
    left join public.cold_storage_readings r on r.submission_id = e.submission_id
      and r.equipment_id = e.equipment_id
      and r.submitted_at is not null
    where e.submission_id = x.id
      and e.active
  ) submitted
  where x.organization_id = target_organization_id
    and private.cold_storage_missed_report_id(x.id) = target_report_id
    and exists (select 1 from public.cold_storage_equipment e where e.submission_id = x.id and e.active)
    and cardinality(private.cold_storage_missed_slots_for(x.branch_id, x.business_date, submitted.submitted_slots)) > 0;

  select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) into submitted_slot_array
  from public.cold_storage_equipment e
  left join public.cold_storage_readings r on r.submission_id = e.submission_id
    and r.equipment_id = e.equipment_id
    and r.submitted_at is not null
  where e.submission_id = s.id
    and e.active;
  missed_slot_array := private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted_slot_array);
  return pg_catalog.jsonb_build_object(
    'id', private.cold_storage_missed_report_id(s.id),
    'record_kind', 'derived_missing',
    'source_submission_id', s.id,
    'organization_id', s.organization_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'supervisor_team_id', s.supervisor_team_id,
    'business_date', s.business_date,
    'checklist_type', 'cold_storage',
    'definition_id', 'cold_storage_v1',
    'submitted_at', null,
    'submitted_by', null,
    'completion', 0,
    'issue_count', cardinality(missed_slot_array),
    'missed_check_count', cardinality(missed_slot_array),
    'missed_slots', to_jsonb(missed_slot_array),
    'status', 'not_checked',
    'submitted_slots', to_jsonb(submitted_slot_array),
    'items', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_id', 'missed:' || slot,
        'item_text', slot || ' scheduled Refrigerator & Freezer check',
        'answer', 'not_checked',
        'remark', 'Scheduled temperature check was not submitted.',
        'evidence', null
      ) order by case slot when '12:00' then 1 when '3:00' then 2 else 3 end)
      from unnest(missed_slot_array) slot
    ), '[]'::jsonb),
    'rows', '[]'::jsonb,
    'issues', '[]'::jsonb
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
end $$;

revoke all on function public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)
to service_role;
