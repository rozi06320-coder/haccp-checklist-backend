create function public.list_cold_storage_supervisor_reports(
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
          max(r.submitted_at) submitted_at,
          pg_catalog.jsonb_build_object(
            'id', s.id,
            'branch_id', s.branch_id,
            'checklist_type', 'cold_storage',
            'business_date', s.business_date,
            'submitted_at', max(r.submitted_at),
            'submitted_by', s.supervisor_name_snapshot,
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
        where s.supervisor_team_id = c.team_id
          and s.branch_id = c.branch_id
        group by s.id
        order by s.business_date desc, submitted_at desc
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

create function public.get_cold_storage_report_detail(
  actor_user_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.cold_storage_submissions%rowtype; submitted_time timestamptz; issue_total bigint; slot_total bigint;
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
    raise exception 'cold storage report access denied' using errcode = '42501';
end $$;

revoke all on function public.list_cold_storage_supervisor_reports(uuid,uuid,int,int),
  public.get_cold_storage_report_detail(uuid,uuid)
from public, anon, authenticated;
grant execute on function public.list_cold_storage_supervisor_reports(uuid,uuid,int,int),
  public.get_cold_storage_report_detail(uuid,uuid)
to service_role;
