begin;

-- Keep the public contracts unchanged while evaluating each expensive source set once.
-- The MATERIALIZED CTEs are intentional: rows and total are read from the same
-- filtered snapshot, so pagination cannot rerun lateral slot/issue aggregation.
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

  return (
    with report_base as materialized (
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
          private.cold_storage_missed_slots_for(
            s.branch_id,
            s.business_date,
            coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[])
          ) missed_slots,
          (select count(*)::int from public.cold_storage_issues i where i.submission_id = s.id) temperature_issue_count,
          count(distinct e.equipment_id)::int active_equipment_count
        from public.cold_storage_equipment e
        left join public.cold_storage_readings r
          on r.submission_id = e.submission_id
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
    combined as materialized (
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
        private.cold_storage_missed_report_id(b.id),
        b.business_date,
        b.updated_at,
        'not_checked',
        b.branch_name_snapshot,
        b.supervisor_name_snapshot,
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
        )
      from report_base b
      where cardinality(b.missed_slots) > 0
    ),
    filtered as materialized (
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
    ),
    page_rows as (
      select *
      from filtered
      order by business_date desc, sort_time desc nulls last, id desc
      limit requested_page_size offset ((requested_page - 1) * requested_page_size)
    )
    select pg_catalog.jsonb_build_object(
      'reports', coalesce((select pg_catalog.jsonb_agg(row_data order by business_date desc, sort_time desc nulls last, id desc) from page_rows), '[]'::jsonb),
      'page', requested_page,
      'page_size', requested_page_size,
      'total', (select count(*) from filtered)
    )
  );
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
    or staff_filter is not null
    or (type_filter is not null and type_filter <> 'cold_storage')
    or (status_filter is not null and status_filter <> 'new') then
    raise exception 'cold storage issue access denied' using errcode = '42501';
  end if;

  return (
    with combined as materialized (
      select
        i.created_at,
        i.id,
        pg_catalog.jsonb_build_object(
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
        ) dto,
        s.business_date,
        s.branch_name_snapshot search_branch,
        coalesce(e.equipment_name, i.equipment_id) search_item,
        i.corrective_action search_remark,
        null::text search_title,
        null::text search_description,
        s.supervisor_name_snapshot search_submitted_by
      from public.cold_storage_issues i
      join public.cold_storage_submissions s on s.id = i.submission_id
      left join public.cold_storage_equipment e on e.submission_id = i.submission_id and e.equipment_id = i.equipment_id
      where s.organization_id = target_organization_id
        and (date_from is null or s.business_date >= date_from)
        and (date_to is null or s.business_date <= date_to)
        and (branch_filter is null or s.branch_id = branch_filter)
        and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
      union all
      select
        missed.created_at,
        missed.id,
        pg_catalog.jsonb_build_object(
          'id', missed.id,
          'report_id', missed.report_id,
          'branch_id', missed.branch_id,
          'branch_name', missed.branch_name,
          'business_date', missed.business_date,
          'submitted_by', missed.submitted_by,
          'checklist_type', 'cold_storage',
          'title', missed.title,
          'description', missed.description,
          'status', missed.status,
          'created_at', missed.created_at,
          'item_id', missed.item_id,
          'item_text', missed.item_text,
          'affected_staff_id', null,
          'affected_staff_name', null
        ),
        missed.business_date,
        missed.branch_name,
        null,
        null,
        missed.title,
        missed.description,
        missed.submitted_by
      from private.cold_storage_managed_missed_issue_rows(target_organization_id) missed
      where (date_from is null or missed.business_date >= date_from)
        and (date_to is null or missed.business_date <= date_to)
        and (branch_filter is null or missed.branch_id = branch_filter)
        and (supervisor_filter is null or missed.supervisor_user_id = supervisor_filter)
    ),
    filtered as materialized (
      select *
      from combined
      where (nullif(pg_catalog.btrim(search_term), '') is null
        or search_item ilike '%' || pg_catalog.btrim(search_term) || '%'
        or search_remark ilike '%' || pg_catalog.btrim(search_term) || '%'
        or search_branch ilike '%' || pg_catalog.btrim(search_term) || '%'
        or search_title ilike '%' || pg_catalog.btrim(search_term) || '%'
        or search_description ilike '%' || pg_catalog.btrim(search_term) || '%'
        or search_submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%')
    ),
    page_rows as (
      select *
      from filtered
      order by created_at desc, id
      offset ((requested_page - 1) * requested_page_size)
      limit requested_page_size
    )
    select pg_catalog.jsonb_build_object(
      'issues', coalesce((select pg_catalog.jsonb_agg(dto order by created_at desc, id) from page_rows), '[]'::jsonb),
      'page', requested_page,
      'page_size', requested_page_size,
      'total', (select count(*) from filtered)
    )
  );
end $$;

revoke all on function public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
from public, anon, authenticated;
grant execute on function public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
to service_role;

commit;
