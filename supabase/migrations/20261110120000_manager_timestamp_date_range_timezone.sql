-- Apply branch-local timezone semantics to manager timestamp date filters.
-- The lifecycle table is authoritative for historical branch timezone periods.

create or replace function public.list_managed_supplier_receivings(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  category_filter text default null,
  supplier_filter uuid default null,
  date_from_filter date default null,
  date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, supervisor_team_id uuid, branch_name text,
  supplier_id uuid, category text, supplier_name_en text, supplier_name_ar text,
  piv_pos text, quantity numeric, unit text, notes text, photo_storage_path text, photo_original_name text,
  created_by uuid, created_by_name text, created_at timestamptz, updated_at timestamptz
)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (branch_filter is not null and not exists (
      select 1 from public.branches managed_branch
      where managed_branch.id = branch_filter and managed_branch.organization_id = target_organization_id
    ))
    or (supplier_filter is not null and not exists (
      select 1 from public.branch_suppliers managed_supplier
      where managed_supplier.id = supplier_filter and managed_supplier.organization_id = target_organization_id
        and (branch_filter is null or managed_supplier.branch_id = branch_filter)
    ))
    or (category_filter is not null and category_filter not in ('raw','frozen','juice'))
    or (date_from_filter is not null and date_to_filter is not null and date_from_filter > date_to_filter) then
    raise exception 'managed supplier receiving access denied' using errcode = '42501';
  end if;

  return query
  select receiving.id, receiving.organization_id, receiving.branch_id, receiving.supervisor_team_id,
    branch.name, receiving.supplier_id, receiving.category, receiving.supplier_name_en,
    receiving.supplier_name_ar, receiving.piv_pos, receiving.quantity, receiving.unit, receiving.notes,
    receiving.photo_storage_path, receiving.photo_original_name, receiving.created_by,
    creator.full_name, receiving.created_at, receiving.updated_at
  from public.branch_supplier_receivings receiving
  join public.branches branch on branch.id = receiving.branch_id
  left join public.profiles creator on creator.id = receiving.created_by
  where receiving.organization_id = target_organization_id
    and (branch_filter is null or receiving.branch_id = branch_filter)
    and (category_filter is null or receiving.category = category_filter)
    and (supplier_filter is null or receiving.supplier_id = supplier_filter)
    and (
      (date_from_filter is null and date_to_filter is null)
      or exists (
        select 1
        from public.daily_report_branch_lifecycle lifecycle
        where lifecycle.organization_id = receiving.organization_id
          and lifecycle.branch_id = receiving.branch_id
          and (receiving.created_at at time zone lifecycle.timezone)::date >= lifecycle.effective_from_business_date
          and (lifecycle.effective_to_business_date is null
            or (receiving.created_at at time zone lifecycle.timezone)::date < lifecycle.effective_to_business_date)
          and (date_from_filter is null
            or (receiving.created_at at time zone lifecycle.timezone)::date >= date_from_filter)
          and (date_to_filter is null
            or (receiving.created_at at time zone lifecycle.timezone)::date <= date_to_filter)
      )
    )
  order by receiving.created_at desc;
end;
$$;

revoke all on function public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date) from public, anon, authenticated;
grant execute on function public.list_managed_supplier_receivings(uuid,uuid,uuid,text,uuid,date,date) to service_role;

create or replace function public.list_managed_maintenance_issues(
  actor_user_id uuid, target_organization_id uuid, branch_filter uuid default null,
  status_filter text default null, priority_filter text default null, category_filter text default null,
  date_from_filter date default null, date_to_filter date default null
)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, title text, category text,
  priority text, status text, description text, location text, reported_by uuid, reporter_name text,
  responsible_person_name text, created_at timestamptz, updated_at timestamptz, updates jsonb
)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (branch_filter is not null and not exists (select 1 from public.branches managed_branch where managed_branch.id=branch_filter and managed_branch.organization_id=target_organization_id))
    or (status_filter is not null and status_filter not in ('new','in_progress','waiting_parts','resolved','closed'))
    or (priority_filter is not null and priority_filter not in ('low','normal','high','urgent'))
    or (category_filter is not null and category_filter not in ('equipment','plumbing','electrical','refrigeration','building','other'))
    or (date_from_filter is not null and date_to_filter is not null and date_from_filter>date_to_filter) then
    raise exception 'managed maintenance issue access denied' using errcode='42501';
  end if;
  return query
  select issue.id,issue.organization_id,issue.branch_id,
    case when issue.location_scope='office' then 'Office' else branch.name end,
    issue.title,issue.category,issue.priority,issue.status,issue.description,issue.location,
    issue.reported_by,reporter.full_name,issue.responsible_person_name,issue.created_at,issue.updated_at,
    coalesce((select jsonb_agg(jsonb_build_object('id',update_row.id,'status',update_row.status,'note',update_row.note,'updated_by',update_row.updated_by,'updated_by_access_user_id',update_row.updated_by_access_user_id,'updated_by_name',coalesce(updater.full_name,access_updater.display_name),'created_at',update_row.created_at) order by update_row.created_at) from public.maintenance_issue_updates update_row left join public.profiles updater on updater.id=update_row.updated_by left join public.maintenance_access_users access_updater on access_updater.id=update_row.updated_by_access_user_id where update_row.issue_id=issue.id and update_row.organization_id=target_organization_id),'[]'::jsonb)
  from public.maintenance_issues issue left join public.branches branch on branch.id=issue.branch_id left join public.profiles reporter on reporter.id=issue.reported_by
  where issue.organization_id=target_organization_id and (branch_filter is null or issue.branch_id=branch_filter) and (status_filter is null or issue.status=status_filter) and (priority_filter is null or issue.priority=priority_filter) and (category_filter is null or issue.category=category_filter)
    and (
      (date_from_filter is null and date_to_filter is null)
      or exists (
        select 1
        from public.daily_report_branch_lifecycle lifecycle
        where lifecycle.organization_id = issue.organization_id
          and lifecycle.branch_id = issue.branch_id
          and (issue.created_at at time zone lifecycle.timezone)::date >= lifecycle.effective_from_business_date
          and (lifecycle.effective_to_business_date is null
            or (issue.created_at at time zone lifecycle.timezone)::date < lifecycle.effective_to_business_date)
          and (date_from_filter is null
            or (issue.created_at at time zone lifecycle.timezone)::date >= date_from_filter)
          and (date_to_filter is null
            or (issue.created_at at time zone lifecycle.timezone)::date <= date_to_filter)
      )
    )
    and (issue.location_scope='office' or branch.id is not null)
  order by issue.created_at desc;
end;
$$;

revoke all on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) from public,anon,authenticated;
grant execute on function public.list_managed_maintenance_issues(uuid,uuid,uuid,text,text,text,date,date) to service_role;
