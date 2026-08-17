create function public.list_oil_tracking_managed_reports(
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
    raise exception 'oil managed report access denied' using errcode = '42501';
  end if;
  return pg_catalog.jsonb_build_object(
    'reports', coalesce((
      select pg_catalog.jsonb_agg(q.dto order by q.business_date desc, q.submitted_at desc, q.id desc)
      from (
        select
          s.id,
          s.business_date,
          greatest(coalesce(s.opening_submitted_at, '-infinity'::timestamptz), coalesce(s.closing_submitted_at, '-infinity'::timestamptz)) submitted_at,
          pg_catalog.jsonb_build_object(
            'id', s.id,
            'branch_id', s.branch_id,
            'branch_name', s.branch_name_snapshot,
            'checklist_type', 'oil_tracking',
            'definition_id', 'oil_tracking_v1',
            'business_date', s.business_date,
            'submitted_at', greatest(coalesce(s.opening_submitted_at, '-infinity'::timestamptz), coalesce(s.closing_submitted_at, '-infinity'::timestamptz)),
            'submitted_by', s.supervisor_name_snapshot,
            'supervisor_user_id', s.supervisor_user_id,
            'completion', case when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 100 else 50 end,
            'issue_count', (select count(*) from public.oil_tracking_issues i where i.source_submission_id = s.id),
            'status',
              case
                when s.opening_submitted_at is null or s.closing_submitted_at is null then 'in_progress'
                when exists(select 1 from public.oil_tracking_issues i where i.source_submission_id = s.id) then 'issues_found'
                else 'compliant'
              end
          ) dto
        from public.oil_tracking_submissions s
        where s.organization_id = target_organization_id
          and (s.opening_submitted_at is not null or s.closing_submitted_at is not null)
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (status_filter is null or (status_filter = 'issues_found') = exists(select 1 from public.oil_tracking_issues i where i.source_submission_id = s.id))
          and (nullif(pg_catalog.btrim(search_term), '') is null
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
        order by s.business_date desc, submitted_at desc, s.id desc
        limit requested_page_size offset ((requested_page - 1) * requested_page_size)
      ) q
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from public.oil_tracking_submissions s
      where s.organization_id = target_organization_id
        and (s.opening_submitted_at is not null or s.closing_submitted_at is not null)
        and (date_from is null or s.business_date >= date_from)
        and (date_to is null or s.business_date <= date_to)
        and (branch_filter is null or s.branch_id = branch_filter)
        and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
        and (status_filter is null or (status_filter = 'issues_found') = exists(select 1 from public.oil_tracking_issues i where i.source_submission_id = s.id))
        and (nullif(pg_catalog.btrim(search_term), '') is null
          or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
    )
  );
end $$;

create function public.get_oil_tracking_managed_report_detail(
  actor_user_id uuid,
  target_organization_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.oil_tracking_submissions%rowtype; submitted_time timestamptz; issue_total bigint;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'oil managed report access denied' using errcode = '42501';
  end if;
  select * into strict s from public.oil_tracking_submissions x
  where x.id = target_report_id
    and x.organization_id = target_organization_id
    and (x.opening_submitted_at is not null or x.closing_submitted_at is not null);
  submitted_time := greatest(coalesce(s.opening_submitted_at, '-infinity'::timestamptz), coalesce(s.closing_submitted_at, '-infinity'::timestamptz));
  select count(*) into issue_total from public.oil_tracking_issues i where i.source_submission_id = s.id;
  return pg_catalog.jsonb_build_object(
    'id', s.id,
    'organization_id', s.organization_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'supervisor_team_id', s.supervisor_team_id,
    'business_date', s.business_date,
    'checklist_type', 'oil_tracking',
    'definition_id', 'oil_tracking_v1',
    'submitted_at', submitted_time,
    'submitted_by', s.supervisor_name_snapshot,
    'completion', case when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 100 else 50 end,
    'issue_count', issue_total,
    'status',
      case
        when s.opening_submitted_at is null or s.closing_submitted_at is null then 'in_progress'
        when issue_total > 0 then 'issues_found'
        else 'compliant'
      end,
    'opening_submitted_at', s.opening_submitted_at,
    'closing_submitted_at', s.closing_submitted_at,
    'rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'fryer_id', r.fryer_id,
        'fryer_label', r.fryer_label_snapshot,
        'fryer_short_label', r.fryer_short_label_snapshot,
        'in_use_today', r.in_use_today,
        'oil_status', r.oil_status,
        'opening_temperature_c', r.opening_temperature_c,
        'opening_status', r.opening_status,
        'opening_note', r.opening_note,
        'closing_tpm_percent', r.closing_tpm_percent,
        'closing_note', r.closing_note,
        'tpm_classification', case when r.closing_tpm_percent is null then null else private.oil_tracking_tpm_status(r.closing_tpm_percent) end
      ) order by r.fryer_id)
      from public.oil_tracking_fryer_results r
      where r.submission_id = s.id
    ), '[]'::jsonb),
    'issues', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', i.id,
        'section', i.section,
        'fryer_id', i.fryer_id,
        'fryer_label', i.fryer_label_snapshot,
        'title', i.title,
        'remark', i.remark,
        'tpm_status', i.tpm_status
      ) order by i.created_at, i.id)
      from public.oil_tracking_issues i
      where i.source_submission_id = s.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'oil managed report access denied' using errcode = '42501';
end $$;

create function public.list_cold_storage_managed_reports(
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
          max(r.submitted_at) submitted_at,
          pg_catalog.jsonb_build_object(
            'id', s.id,
            'branch_id', s.branch_id,
            'branch_name', s.branch_name_snapshot,
            'checklist_type', 'cold_storage',
            'definition_id', 'cold_storage_v1',
            'business_date', s.business_date,
            'submitted_at', max(r.submitted_at),
            'submitted_by', s.supervisor_name_snapshot,
            'supervisor_user_id', s.supervisor_user_id,
            'completion', pg_catalog.round((count(distinct r.slot)::numeric * 100) / 3),
            'issue_count', (select count(*) from public.cold_storage_issues i where i.submission_id = s.id),
            'status',
              case
                when exists(select 1 from public.cold_storage_issues i where i.submission_id = s.id) then 'issues_found'
                when count(distinct r.slot) < 3 then 'in_progress'
                else 'compliant'
              end,
            'submitted_slots', coalesce(pg_catalog.jsonb_agg(distinct r.slot) filter (where r.slot is not null), '[]'::jsonb)
          ) row_data
        from public.cold_storage_submissions s
        join public.cold_storage_equipment e on e.submission_id = s.id and e.active
        join public.cold_storage_readings r on r.submission_id = s.id
          and r.equipment_id = e.equipment_id
          and r.submitted_at is not null
        where s.organization_id = target_organization_id
          and (date_from is null or s.business_date >= date_from)
          and (date_to is null or s.business_date <= date_to)
          and (branch_filter is null or s.branch_id = branch_filter)
          and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
          and (status_filter is null or (status_filter = 'issues_found') = exists(select 1 from public.cold_storage_issues i where i.submission_id = s.id))
          and (nullif(pg_catalog.btrim(search_term), '') is null
            or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
            or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
        group by s.id
        order by s.business_date desc, submitted_at desc, s.id desc
        limit requested_page_size offset ((requested_page - 1) * requested_page_size)
      ) q
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from public.cold_storage_submissions s
      where s.organization_id = target_organization_id
        and (date_from is null or s.business_date >= date_from)
        and (date_to is null or s.business_date <= date_to)
        and (branch_filter is null or s.branch_id = branch_filter)
        and (supervisor_filter is null or s.supervisor_user_id = supervisor_filter)
        and (status_filter is null or (status_filter = 'issues_found') = exists(select 1 from public.cold_storage_issues i where i.submission_id = s.id))
        and (nullif(pg_catalog.btrim(search_term), '') is null
          or s.branch_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%'
          or s.supervisor_name_snapshot ilike '%' || pg_catalog.btrim(search_term) || '%')
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
end $$;

create function public.get_cold_storage_managed_report_detail(
  actor_user_id uuid,
  target_organization_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.cold_storage_submissions%rowtype; submitted_time timestamptz; issue_total bigint; slot_total bigint;
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
  select max(r.submitted_at), count(distinct r.slot) into submitted_time, slot_total
  from public.cold_storage_readings r
  join public.cold_storage_equipment e on e.submission_id = r.submission_id
    and e.equipment_id = r.equipment_id
    and e.active
  where r.submission_id = s.id
    and r.submitted_at is not null;
  select count(*) into issue_total from public.cold_storage_issues i where i.submission_id = s.id;
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
    'completion', pg_catalog.round((slot_total::numeric * 100) / 3),
    'issue_count', issue_total,
    'status',
      case
        when issue_total > 0 then 'issues_found'
        when slot_total < 3 then 'in_progress'
        else 'compliant'
      end,
    'submitted_slots', coalesce((
      select pg_catalog.jsonb_agg(distinct r.slot)
      from public.cold_storage_readings r
      join public.cold_storage_equipment e on e.submission_id = r.submission_id
        and e.equipment_id = r.equipment_id
        and e.active
      where r.submission_id = s.id
        and r.submitted_at is not null
    ), '[]'::jsonb),
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
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', i.id,
        'equipment_id', i.equipment_id,
        'equipment_name', coalesce(e.equipment_name, i.equipment_id),
        'slot', i.slot,
        'temperature_c', i.temperature_c,
        'title', 'Cold Storage temperature issue',
        'remark', i.corrective_action
      ) order by i.slot, i.equipment_id)
      from public.cold_storage_issues i
      left join public.cold_storage_equipment e on e.submission_id = i.submission_id
        and e.equipment_id = i.equipment_id
      where i.submission_id = s.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
end $$;

revoke all on function public.list_oil_tracking_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_oil_tracking_managed_report_detail(uuid,uuid,uuid),
  public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)
from public, anon, authenticated;
grant execute on function public.list_oil_tracking_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_oil_tracking_managed_report_detail(uuid,uuid,uuid),
  public.list_cold_storage_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text),
  public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)
to service_role;
