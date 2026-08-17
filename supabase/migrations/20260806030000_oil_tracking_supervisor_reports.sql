create function public.list_oil_tracking_supervisor_reports(
  actor_user_id uuid,
  target_branch_id uuid,
  requested_page int default 1,
  requested_page_size int default 20
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id, target_branch_id);
  if requested_page < 1 or requested_page_size not between 1 and 50 then
    raise exception 'invalid oil report list' using errcode = '22023';
  end if;
  return pg_catalog.jsonb_build_object(
    'reports', coalesce((
      select pg_catalog.jsonb_agg(q.row_data order by q.business_date desc, q.submitted_at desc)
      from (
        select
          s.business_date,
          greatest(coalesce(s.opening_submitted_at, '-infinity'::timestamptz), coalesce(s.closing_submitted_at, '-infinity'::timestamptz)) submitted_at,
          pg_catalog.jsonb_build_object(
            'id', s.id,
            'branch_id', s.branch_id,
            'checklist_type', 'oil_tracking',
            'business_date', s.business_date,
            'submitted_at', greatest(coalesce(s.opening_submitted_at, '-infinity'::timestamptz), coalesce(s.closing_submitted_at, '-infinity'::timestamptz)),
            'submitted_by', s.supervisor_name_snapshot,
            'completion', case when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 100 else 50 end,
            'issue_count', (select count(*) from public.oil_tracking_issues i where i.source_submission_id = s.id),
            'status',
              case
                when s.opening_submitted_at is null or s.closing_submitted_at is null then 'in_progress'
                when exists(select 1 from public.oil_tracking_issues i where i.source_submission_id = s.id) then 'issues_found'
                else 'compliant'
              end
          ) row_data
        from public.oil_tracking_submissions s
        where s.supervisor_team_id = c.team_id
          and s.branch_id = c.branch_id
          and (s.opening_submitted_at is not null or s.closing_submitted_at is not null)
        order by s.business_date desc, submitted_at desc
        limit requested_page_size offset ((requested_page - 1) * requested_page_size)
      ) q
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from public.oil_tracking_submissions s
      where s.supervisor_team_id = c.team_id
        and s.branch_id = c.branch_id
        and (s.opening_submitted_at is not null or s.closing_submitted_at is not null)
    )
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'oil report access denied' using errcode = '42501';
end $$;

create function public.get_oil_tracking_report_detail(
  actor_user_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.oil_tracking_submissions%rowtype; submitted_time timestamptz; issue_total bigint;
begin
  select * into strict s from public.oil_tracking_submissions x
  where x.id = target_report_id
    and (x.opening_submitted_at is not null or x.closing_submitted_at is not null);
  if not (s.supervisor_user_id = actor_user_id and private.actor_owns_operational_team(actor_user_id, s.branch_id, s.supervisor_team_id)) then
    raise exception 'oil report access denied' using errcode = '42501';
  end if;
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
    raise exception 'oil report access denied' using errcode = '42501';
end $$;

revoke all on function public.list_oil_tracking_supervisor_reports(uuid,uuid,int,int),
  public.get_oil_tracking_report_detail(uuid,uuid)
from public, anon, authenticated;
grant execute on function public.list_oil_tracking_supervisor_reports(uuid,uuid,int,int),
  public.get_oil_tracking_report_detail(uuid,uuid)
to service_role;
