-- Keep non-staff Sales Tracking issues from breaking existing affected-staff issue filters.

create or replace function public.list_sales_tracking_managed_issues(
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
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or (type_filter is not null and type_filter <> 'sales_tracking')
    or (status_filter is not null and status_filter <> 'new')
  then
    raise exception 'sales tracking issue access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'issues', coalesce((
      select pg_catalog.jsonb_agg(issue.dto order by issue.created_at desc, issue.id)
      from (
        select row.created_at, row.id, pg_catalog.jsonb_build_object(
          'id', row.id,
          'report_id', row.report_id,
          'branch_id', row.branch_id,
          'branch_name', row.branch_name,
          'business_date', row.business_date,
          'submitted_by', row.submitted_by,
          'checklist_type', 'sales_tracking',
          'title', row.title,
          'description', row.description,
          'status', row.status,
          'created_at', row.created_at,
          'item_id', row.item_id,
          'item_text', row.item_text,
          'affected_staff_id', null,
          'affected_staff_name', null
        ) dto
        from private.sales_tracking_managed_issue_rows(target_organization_id) row
        where (date_from is null or row.business_date >= date_from)
          and (date_to is null or row.business_date <= date_to)
          and (branch_filter is null or row.branch_id = branch_filter)
          and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
          and staff_filter is null
          and (
            nullif(pg_catalog.btrim(search_term), '') is null
            or row.title ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.description ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%'
            or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%'
          )
        order by row.created_at desc, row.id
        offset (requested_page - 1) * requested_page_size
        limit requested_page_size
      ) issue
    ), '[]'::jsonb),
    'page', requested_page,
    'page_size', requested_page_size,
    'total', (
      select count(*)
      from private.sales_tracking_managed_issue_rows(target_organization_id) row
      where (date_from is null or row.business_date >= date_from)
        and (date_to is null or row.business_date <= date_to)
        and (branch_filter is null or row.branch_id = branch_filter)
        and (supervisor_filter is null or row.supervisor_user_id = supervisor_filter)
        and staff_filter is null
        and (
          nullif(pg_catalog.btrim(search_term), '') is null
          or row.title ilike '%' || pg_catalog.btrim(search_term) || '%'
          or row.description ilike '%' || pg_catalog.btrim(search_term) || '%'
          or row.branch_name ilike '%' || pg_catalog.btrim(search_term) || '%'
          or row.submitted_by ilike '%' || pg_catalog.btrim(search_term) || '%'
        )
    )
  );
end;
$$;

revoke all on function public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  from public, anon, authenticated;
grant execute on function public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  to service_role;
