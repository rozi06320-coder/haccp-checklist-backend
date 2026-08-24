create table if not exists public.financial_closing_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  business_date date not null,
  state text not null default 'draft' check (state in ('draft', 'submitted')),
  revision bigint not null default 0 check (revision >= 0),
  branch_name_snapshot text not null check (length(btrim(branch_name_snapshot)) > 0),
  branch_code_snapshot text not null check (length(btrim(branch_code_snapshot)) > 0),
  branch_city_snapshot text null,
  submitted_by_user_id uuid null references auth.users(id) on delete restrict,
  submitted_by_name_snapshot text null,
  submitted_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by_user_id uuid null references auth.users(id) on delete restrict,
  constraint financial_closing_reports_lifecycle_check check (
    (state = 'draft' and submitted_at is null)
    or (state = 'submitted' and submitted_at is not null and submitted_by_user_id is not null)
  ),
  constraint financial_closing_reports_branch_scope_fkey foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint financial_closing_reports_org_branch_date_key unique (organization_id, branch_id, business_date)
);

create table if not exists public.financial_closing_items (
  report_id uuid not null references public.financial_closing_reports(id) on delete restrict,
  item_key text not null,
  status text null check (status in ('completed', 'not_completed', 'not_applicable')),
  reason text null check (reason is null or length(reason) <= 2000),
  follow_up text null check (follow_up is null or length(follow_up) <= 2000),
  updated_at timestamptz not null default now(),
  primary key (report_id, item_key),
  constraint financial_closing_items_key_check check (item_key in (
    'sales_closing',
    'collections',
    'exceptions',
    'purchases',
    'transfers',
    'production',
    'waste',
    'petty_cash',
    'pending_documents',
    'exception_escalation'
  ))
);

create index if not exists financial_closing_reports_manager_idx
  on public.financial_closing_reports(organization_id, business_date desc, branch_id, state);
create index if not exists financial_closing_reports_branch_date_idx
  on public.financial_closing_reports(branch_id, business_date desc);

drop trigger if exists financial_closing_reports_set_updated_at on public.financial_closing_reports;
create trigger financial_closing_reports_set_updated_at
before update on public.financial_closing_reports
for each row execute function private.set_updated_at();

alter table public.financial_closing_reports enable row level security;
alter table public.financial_closing_items enable row level security;

create or replace function private.financial_closing_item_keys()
returns text[] language sql immutable security definer set search_path = '' as $$
  select array[
    'sales_closing',
    'collections',
    'exceptions',
    'purchases',
    'transfers',
    'production',
    'waste',
    'petty_cash',
    'pending_documents',
    'exception_escalation'
  ]::text[]
$$;

create or replace function private.financial_closing_item_ordinal(target_item_key text)
returns int language sql immutable security definer set search_path = '' as $$
  select case target_item_key
    when 'sales_closing' then 1
    when 'collections' then 2
    when 'exceptions' then 3
    when 'purchases' then 4
    when 'transfers' then 5
    when 'production' then 6
    when 'waste' then 7
    when 'petty_cash' then 8
    when 'pending_documents' then 9
    when 'exception_escalation' then 10
    else null
  end
$$;

create or replace function private.financial_closing_item_label(target_item_key text)
returns text language sql immutable security definer set search_path = '' as $$
  select case target_item_key
    when 'sales_closing' then 'Sales Closing'
    when 'collections' then 'Collections'
    when 'exceptions' then 'Exceptions'
    when 'purchases' then 'Purchases'
    when 'transfers' then 'Transfers'
    when 'production' then 'Production'
    when 'waste' then 'Waste'
    when 'petty_cash' then 'Petty Cash'
    when 'pending_documents' then 'Pending Documents'
    when 'exception_escalation' then 'Exception Escalation'
    else target_item_key
  end
$$;

create or replace function private.financial_closing_completion(target_report_id uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  with counts as (
    select
      count(*) filter (where item.status = 'completed') as completed_count,
      count(*) filter (where item.status = 'not_completed') as not_completed_count,
      count(*) filter (where item.status = 'not_applicable') as not_applicable_count
    from public.financial_closing_items item
    where item.report_id = target_report_id
  )
  select case
    when completed_count + not_completed_count > 0 then round((completed_count::numeric * 100) / (completed_count + not_completed_count), 1)
    when not_applicable_count = 10 then 100
    else 0
  end
  from counts
$$;

create or replace function private.validate_financial_closing_items(report_items jsonb, final_required boolean)
returns table(item_key text, status text, reason text, follow_up text)
language plpgsql stable security definer set search_path = '' as $$
declare
  raw_item jsonb;
  seen text[] := array[]::text[];
  required_key text;
begin
  if report_items is null or jsonb_typeof(report_items) <> 'array' then
    raise exception 'invalid financial closing items' using errcode = '22023';
  end if;

  for raw_item in select value from jsonb_array_elements(report_items) loop
    item_key := raw_item ->> 'item_key';
    status := nullif(btrim(coalesce(raw_item ->> 'status', '')), '');
    reason := nullif(btrim(coalesce(raw_item ->> 'reason', '')), '');
    follow_up := nullif(btrim(coalesce(raw_item ->> 'follow_up', '')), '');

    if item_key is null or not item_key = any(private.financial_closing_item_keys()) then
      raise exception 'invalid financial closing item' using errcode = '22023';
    end if;
    if item_key = any(seen) then
      raise exception 'duplicate financial closing item' using errcode = '22023';
    end if;
    seen := seen || item_key;

    if status is not null and status not in ('completed', 'not_completed', 'not_applicable') then
      raise exception 'invalid financial closing status' using errcode = '22023';
    end if;
    if final_required and status is null then
      raise exception 'financial closing status required' using errcode = '22023';
    end if;
    if status = 'not_completed' and final_required and (reason is null or follow_up is null) then
      raise exception 'financial closing follow-up required' using errcode = '22023';
    end if;
    if length(coalesce(reason, '')) > 2000 or length(coalesce(follow_up, '')) > 2000 then
      raise exception 'financial closing note too long' using errcode = '22023';
    end if;

    return next;
  end loop;

  if final_required then
    foreach required_key in array private.financial_closing_item_keys() loop
      if not required_key = any(seen) then
        raise exception 'financial closing status required' using errcode = '22023';
      end if;
    end loop;
  end if;
end
$$;

create or replace function private.financial_closing_payload(actor_user_id uuid, target_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  c record;
  report public.financial_closing_reports%rowtype;
  current_city text;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);
  select branch.city into current_city
  from public.branches branch
  where branch.id = c.branch_id and branch.organization_id = c.organization_id;

  select * into report
  from public.financial_closing_reports saved
  where saved.organization_id = c.organization_id
    and saved.branch_id = c.branch_id
    and saved.business_date = c.business_date;

  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'branch_id', c.branch_id,
    'business_date', c.business_date,
    'state', coalesce(report.state, 'empty'),
    'revision', coalesce(report.revision, 0),
    'branch_name', coalesce(report.branch_name_snapshot, c.branch_name),
    'branch_code', coalesce(report.branch_code_snapshot, c.branch_code),
    'branch_city', coalesce(report.branch_city_snapshot, current_city),
    'submitted_at', report.submitted_at,
    'submitted_by_user_id', report.submitted_by_user_id,
    'submitted_by_name_snapshot', report.submitted_by_name_snapshot,
    'updated_at', report.updated_at,
    'completion', coalesce(private.financial_closing_completion(report.id), 0),
    'not_completed_count', coalesce((select count(*) from public.financial_closing_items item where item.report_id = report.id and item.status = 'not_completed'), 0),
    'items', (
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_key', key.item_key,
        'status', item.status,
        'reason', coalesce(item.reason, ''),
        'follow_up', coalesce(item.follow_up, '')
      ) order by key.ordinal)
      from unnest(private.financial_closing_item_keys()) with ordinality as key(item_key, ordinal)
      left join public.financial_closing_items item on item.report_id = report.id and item.item_key = key.item_key
    )
  );
exception when no_data_found or too_many_rows then
  raise exception 'financial closing access denied' using errcode = '42501';
end
$$;

create or replace function public.get_financial_closing_current_state(actor_user_id uuid, target_branch_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select private.financial_closing_payload(actor_user_id, target_branch_id)
$$;

create or replace function public.save_financial_closing_draft(actor_user_id uuid, target_branch_id uuid, expected_revision bigint, report_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c record;
  report public.financial_closing_reports%rowtype;
  current_city text;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);
  perform pg_advisory_xact_lock(hashtextextended(c.organization_id::text || ':' || c.branch_id::text || ':' || c.business_date::text || ':financial_closing', 0));
  perform 1 from private.validate_financial_closing_items(report_items, false);
  select branch.city into current_city from public.branches branch where branch.id = c.branch_id and branch.organization_id = c.organization_id;

  select * into report
  from public.financial_closing_reports saved
  where saved.organization_id = c.organization_id and saved.branch_id = c.branch_id and saved.business_date = c.business_date
  for update;

  if report.id is null then
    if expected_revision <> 0 then raise exception 'financial closing changed' using errcode = '40001'; end if;
    insert into public.financial_closing_reports(
      organization_id, branch_id, business_date, state, revision,
      branch_name_snapshot, branch_code_snapshot, branch_city_snapshot, updated_by_user_id
    )
    values(c.organization_id, c.branch_id, c.business_date, 'draft', 0, c.branch_name, c.branch_code, current_city, actor_user_id)
    returning * into report;
  else
    if report.state = 'submitted' then raise exception 'financial closing already submitted' using errcode = '55000'; end if;
    if report.revision <> expected_revision then raise exception 'financial closing changed' using errcode = '40001'; end if;
  end if;

  delete from public.financial_closing_items item where item.report_id = report.id;
  insert into public.financial_closing_items(report_id, item_key, status, reason, follow_up)
  select report.id, item.item_key, item.status, item.reason, item.follow_up
  from private.validate_financial_closing_items(report_items, false) item;

  update public.financial_closing_reports
  set revision = revision + 1,
      updated_at = now(),
      updated_by_user_id = actor_user_id
  where id = report.id;

  return private.financial_closing_payload(actor_user_id, target_branch_id);
exception when no_data_found or too_many_rows then
  raise exception 'financial closing access denied' using errcode = '42501';
end
$$;

create or replace function public.submit_financial_closing(actor_user_id uuid, target_branch_id uuid, expected_revision bigint, report_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c record;
  report public.financial_closing_reports%rowtype;
  current_city text;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);
  perform pg_advisory_xact_lock(hashtextextended(c.organization_id::text || ':' || c.branch_id::text || ':' || c.business_date::text || ':financial_closing', 0));
  perform 1 from private.validate_financial_closing_items(report_items, true);
  select branch.city into current_city from public.branches branch where branch.id = c.branch_id and branch.organization_id = c.organization_id;

  select * into report
  from public.financial_closing_reports saved
  where saved.organization_id = c.organization_id and saved.branch_id = c.branch_id and saved.business_date = c.business_date
  for update;

  if report.id is null then
    if expected_revision <> 0 then raise exception 'financial closing changed' using errcode = '40001'; end if;
    insert into public.financial_closing_reports(
      organization_id, branch_id, business_date, state, revision,
      branch_name_snapshot, branch_code_snapshot, branch_city_snapshot, updated_by_user_id
    )
    values(c.organization_id, c.branch_id, c.business_date, 'draft', 0, c.branch_name, c.branch_code, current_city, actor_user_id)
    returning * into report;
  else
    if report.state = 'submitted' then raise exception 'financial closing already submitted' using errcode = '55000'; end if;
    if report.revision <> expected_revision then raise exception 'financial closing changed' using errcode = '40001'; end if;
  end if;

  delete from public.financial_closing_items item where item.report_id = report.id;
  insert into public.financial_closing_items(report_id, item_key, status, reason, follow_up)
  select report.id, item.item_key, item.status, item.reason, item.follow_up
  from private.validate_financial_closing_items(report_items, true) item;

  update public.financial_closing_reports
  set state = 'submitted',
      revision = revision + 1,
      branch_name_snapshot = c.branch_name,
      branch_code_snapshot = c.branch_code,
      branch_city_snapshot = current_city,
      submitted_by_user_id = actor_user_id,
      submitted_by_name_snapshot = c.actor_name,
      submitted_at = now(),
      updated_at = now(),
      updated_by_user_id = actor_user_id
  where id = report.id;

  return private.financial_closing_payload(actor_user_id, target_branch_id);
exception when no_data_found or too_many_rows then
  raise exception 'financial closing access denied' using errcode = '42501';
end
$$;

create or replace function public.list_managed_financial_closing_reports(
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
)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or requested_page < 1
    or requested_page_size not between 1 and 50
    or length(coalesce(search_term, '')) > 120
    or (date_from is not null and date_to is not null and date_from > date_to)
    or (branch_filter is not null and not exists (select 1 from public.branches branch where branch.id = branch_filter and branch.organization_id = target_organization_id))
    or (status_filter is not null and status_filter not in ('compliant', 'issues_found', 'in_progress', 'not_checked'))
  then
    raise exception 'financial closing report access denied' using errcode = '42501';
  end if;

  return (
    select pg_catalog.jsonb_build_object(
      'reports', coalesce(pg_catalog.jsonb_agg(x.dto order by x.business_date desc, x.sort_time desc, x.id desc) filter (where x.rn between (requested_page - 1) * requested_page_size + 1 and requested_page * requested_page_size), '[]'::jsonb),
      'page', requested_page,
      'page_size', requested_page_size,
      'total', count(*)
    )
    from (
      select q.*, row_number() over(order by q.business_date desc, q.sort_time desc, q.id desc) rn
      from (
        select report.id,
          report.business_date,
          coalesce(report.submitted_at, report.updated_at) sort_time,
          pg_catalog.jsonb_build_object(
            'id', report.id,
            'branch_id', report.branch_id,
            'branch_name', report.branch_name_snapshot,
            'branch_code', report.branch_code_snapshot,
            'checklist_type', 'financial_closing',
            'business_date', report.business_date,
            'submitted_at', report.submitted_at,
            'submitted_by', report.submitted_by_name_snapshot,
            'completion', private.financial_closing_completion(report.id),
            'issue_count', (select count(*) from public.financial_closing_items item where item.report_id = report.id and item.status = 'not_completed'),
            'status', case
              when report.state = 'draft' then 'in_progress'
              when exists(select 1 from public.financial_closing_items item where item.report_id = report.id and item.status = 'not_completed') then 'issues_found'
              else 'compliant'
            end
          ) dto
        from public.financial_closing_reports report
        where report.organization_id = target_organization_id
          and (date_from is null or report.business_date >= date_from)
          and (date_to is null or report.business_date <= date_to)
          and (branch_filter is null or report.branch_id = branch_filter)
          and (supervisor_filter is null or report.submitted_by_user_id = supervisor_filter)
          and (nullif(btrim(search_term), '') is null
            or report.branch_name_snapshot ilike '%' || btrim(search_term) || '%'
            or report.branch_code_snapshot ilike '%' || btrim(search_term) || '%'
            or report.submitted_by_name_snapshot ilike '%' || btrim(search_term) || '%')
      ) q
      where status_filter is null
        or (status_filter = 'not_checked' and false)
        or (status_filter = 'in_progress' and (q.dto ->> 'status') = 'in_progress')
        or (status_filter = 'issues_found' and (q.dto ->> 'status') = 'issues_found')
        or (status_filter = 'compliant' and (q.dto ->> 'status') = 'compliant')
    ) x
  );
end
$$;

create or replace function public.get_managed_financial_closing_report_detail(actor_user_id uuid, target_organization_id uuid, target_report_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  report public.financial_closing_reports%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'financial closing report access denied' using errcode = '42501';
  end if;

  select * into strict report
  from public.financial_closing_reports saved
  where saved.id = target_report_id and saved.organization_id = target_organization_id;

  return pg_catalog.jsonb_build_object(
    'id', report.id,
    'branch_id', report.branch_id,
    'branch_name', report.branch_name_snapshot,
    'branch_code', report.branch_code_snapshot,
    'business_date', report.business_date,
    'checklist_type', 'financial_closing',
    'definition_id', 'financial_closing_v1',
    'submitted_at', report.submitted_at,
    'submitted_by', report.submitted_by_name_snapshot,
    'completion', private.financial_closing_completion(report.id),
    'issue_count', (select count(*) from public.financial_closing_items item where item.report_id = report.id and item.status = 'not_completed'),
    'status', case
      when report.state = 'draft' then 'in_progress'
      when exists(select 1 from public.financial_closing_items item where item.report_id = report.id and item.status = 'not_completed') then 'issues_found'
      else 'compliant'
    end,
    'items', (
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_id', key.item_key,
        'item_text', private.financial_closing_item_label(key.item_key),
        'answer', coalesce(item.status, 'not_checked'),
        'remark', coalesce(item.reason, ''),
        'follow_up', coalesce(item.follow_up, '')
      ) order by key.ordinal)
      from unnest(private.financial_closing_item_keys()) with ordinality as key(item_key, ordinal)
      left join public.financial_closing_items item on item.report_id = report.id and item.item_key = key.item_key
    )
  );
exception when no_data_found or too_many_rows then
  raise exception 'financial closing report access denied' using errcode = '42501';
end
$$;

create or replace function public.list_phase2_branch_reports(actor_user_id uuid,target_branch_id uuid,requested_page int default 1,requested_page_size int default 20,target_checklist_type text default null)
returns jsonb language plpgsql stable security definer set search_path=''as $$declare c record;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if requested_page<1 or requested_page_size not between 1 and 50 or(target_checklist_type is not null and target_checklist_type not in('kitchen_opening','foh_opening','staff_hygiene','oil_tracking','cold_storage','sales_tracking','daily_audit','purchase_log','supplier_receiving','financial_closing'))then raise exception'invalid report list'using errcode='22023';end if;
 return(select pg_catalog.jsonb_build_object('reports',coalesce(pg_catalog.jsonb_agg(x.dto order by x.business_date desc,x.submitted_at desc,x.id desc)filter(where x.rn between(requested_page-1)*requested_page_size+1 and requested_page*requested_page_size),'[]'::jsonb),'page',requested_page,'page_size',requested_page_size,'total',count(*))from(
  select q.*,row_number()over(order by q.business_date desc,q.submitted_at desc,q.id desc)rn from(
   select s.id,s.business_date,s.submitted_at,s.checklist_type,pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type',s.checklist_type,'business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',case when s.checklist_type='daily_audit'then coalesce(nullif(btrim(s.daily_audit_auditor_name_snapshot),''),nullif(btrim(s.supervisor_name_snapshot),''))else coalesce(p.full_name,s.supervisor_name_snapshot)end,'completion',100,'issue_count',case when s.checklist_type='daily_audit'then(select count(*)from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant')else(select count(*)from public.checklist_issues i where i.source_submission_id=s.id)end,'status',case when s.checklist_type='daily_audit'and exists(select 1 from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant')then'issues_found'when s.checklist_type<>'daily_audit'and exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end)dto
   from public.checklist_submissions s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)
   where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.state='submitted'and s.checklist_type in('kitchen_opening','foh_opening','staff_hygiene','daily_audit')
   union all
   select s.id,s.business_date,greatest(coalesce(s.opening_submitted_at,'-infinity'::timestamptz),coalesce(s.closing_submitted_at,'-infinity'::timestamptz)),'oil_tracking',pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type','oil_tracking','business_date',s.business_date,'submitted_at',greatest(coalesce(s.opening_submitted_at,'-infinity'::timestamptz),coalesce(s.closing_submitted_at,'-infinity'::timestamptz)),'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',case when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 100 else 50 end,'issue_count',(select count(*)from public.oil_tracking_issues i where i.source_submission_id=s.id),'status',case when s.opening_submitted_at is null or s.closing_submitted_at is null then'in_progress'when exists(select 1 from public.oil_tracking_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end)
   from public.oil_tracking_submissions s left join public.profiles p on p.id=coalesce(s.closing_submitted_by_user_id,s.opening_submitted_by_user_id,s.supervisor_user_id)where s.organization_id=c.organization_id and s.branch_id=c.branch_id and(s.opening_submitted_at is not null or s.closing_submitted_at is not null)
   union all
   select s.id,s.business_date,max(r.submitted_at),'cold_storage',pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type','cold_storage','business_date',s.business_date,'submitted_at',max(r.submitted_at),'submitted_by',coalesce(max(p.full_name),s.supervisor_name_snapshot),'completion',100,'issue_count',(select count(*)from public.cold_storage_issues i where i.submission_id=s.id),'status',case when exists(select 1 from public.cold_storage_issues i where i.submission_id=s.id)then'issues_found'else'compliant'end)
   from public.cold_storage_submissions s join public.cold_storage_readings r on r.submission_id=s.id and r.submitted_at is not null left join public.profiles p on p.id=r.submitted_by_user_id where s.organization_id=c.organization_id and s.branch_id=c.branch_id group by s.id
   union all
   select s.id,s.business_date,s.submitted_at,'sales_tracking',pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type','sales_tracking','business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',100,'issue_count',0,'status','compliant')from public.sales_tracking_reports s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.state='submitted'
   union all
   select f.id,f.business_date,f.submitted_at,'financial_closing',pg_catalog.jsonb_build_object('id',f.id,'branch_id',f.branch_id,'checklist_type','financial_closing','business_date',f.business_date,'submitted_at',f.submitted_at,'submitted_by',f.submitted_by_name_snapshot,'completion',private.financial_closing_completion(f.id),'issue_count',(select count(*)from public.financial_closing_items i where i.report_id=f.id and i.status='not_completed'),'status',case when exists(select 1 from public.financial_closing_items i where i.report_id=f.id and i.status='not_completed')then'issues_found'else'compliant'end)from public.financial_closing_reports f where f.organization_id=c.organization_id and f.branch_id=c.branch_id and f.state='submitted'
   union all
   select r.id,r.purchase_date,r.created_at,'purchase_log',pg_catalog.jsonb_build_object('id',r.id,'branch_id',r.branch_id,'checklist_type','purchase_log','business_date',r.purchase_date,'submitted_at',r.created_at,'submitted_by',p.full_name,'completion',100,'issue_count',0,'status','recorded')from public.branch_purchase_logs r left join public.profiles p on p.id=r.created_by where r.organization_id=c.organization_id and r.branch_id=c.branch_id
   union all
   select r.id,(r.created_at at time zone b.timezone)::date,r.created_at,'supplier_receiving',pg_catalog.jsonb_build_object('id',r.id,'branch_id',r.branch_id,'checklist_type','supplier_receiving','business_date',(r.created_at at time zone b.timezone)::date,'submitted_at',r.created_at,'submitted_by',p.full_name,'completion',100,'issue_count',0,'status','recorded')from public.branch_supplier_receivings r join public.branches b on b.id=r.branch_id left join public.profiles p on p.id=r.created_by where r.organization_id=c.organization_id and r.branch_id=c.branch_id
  )q where target_checklist_type is null or q.checklist_type=target_checklist_type
 )x);
exception when no_data_found or too_many_rows then raise exception'report access denied'using errcode='42501';end$$;

create or replace function public.get_phase2_branch_report_detail_core(actor_user_id uuid,target_report_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''as $$declare result jsonb;branch uuid;begin
 select x.branch_id into branch from(select id,branch_id from public.checklist_submissions union all select id,branch_id from public.oil_tracking_submissions union all select id,branch_id from public.cold_storage_submissions union all select id,branch_id from public.sales_tracking_reports union all select id,branch_id from public.financial_closing_reports)x where x.id=target_report_id;
 if branch is null or not private.actor_can_read_operational_branch(actor_user_id,branch)then raise exception'report access denied'using errcode='42501';end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type',s.checklist_type,'definition_id',s.definition_id,'submitted_at',s.submitted_at,'submitted_by',case when s.checklist_type='daily_audit'then coalesce(nullif(btrim(s.daily_audit_auditor_name_snapshot),''),nullif(btrim(s.supervisor_name_snapshot),''))else coalesce(p.full_name,s.supervisor_name_snapshot)end,'completion',100,'issue_count',case when s.checklist_type='daily_audit'then(select count(*)from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant')else(select count(*)from public.checklist_issues i where i.source_submission_id=s.id)end,'status',case when(s.checklist_type='daily_audit'and exists(select 1 from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant'))or(s.checklist_type<>'daily_audit'and exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id))then'issues_found'else'compliant'end,
  'items',case when s.checklist_type='daily_audit'then coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'item_text',d.item_label_en,'answer',r.answer,'remark',r.remark)order by r.item_number)from public.daily_audit_item_results r join public.daily_audit_item_definitions d on d.item_id=r.item_id where r.submission_id=s.id),'[]'::jsonb)else coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'item_text',r.item_text_snapshot,'answer',r.answer,'remark',r.remark)order by r.ordinal)from public.opening_item_results r where r.submission_id=s.id),'[]'::jsonb)end,
  'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',h.operational_staff_id,'display_name',h.display_name_snapshot,'operational_roles',h.operational_roles_snapshot,'uniform',h.uniform_result,'fingernails',h.fingernails_result,'hair',h.hair_result,'facial_hair',h.facial_hair_result,'remark',h.remark)order by h.display_name_snapshot)from public.hygiene_staff_snapshots h where h.submission_id=s.id),'[]'::jsonb))into result from public.checklist_submissions s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)where s.id=target_report_id and s.state='submitted';
 if result is not null then return result;end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type','oil_tracking','definition_id','oil_tracking_v1','submitted_at',greatest(coalesce(s.opening_submitted_at,'-infinity'::timestamptz),coalesce(s.closing_submitted_at,'-infinity'::timestamptz)),'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',case when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 100 else 50 end,'issue_count',(select count(*)from public.oil_tracking_issues i where i.source_submission_id=s.id),'status',case when exists(select 1 from public.oil_tracking_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end,'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.fryer_id,'item_text',r.fryer_label_snapshot,'answer',r.opening_status,'remark',r.opening_note||case when r.closing_note=''then''else' / '||r.closing_note end)order by r.fryer_id)from public.oil_tracking_fryer_results r where r.submission_id=s.id),'[]'::jsonb))into result from public.oil_tracking_submissions s left join public.profiles p on p.id=coalesce(s.closing_submitted_by_user_id,s.opening_submitted_by_user_id,s.supervisor_user_id)where s.id=target_report_id and(s.opening_submitted_at is not null or s.closing_submitted_at is not null);if result is not null then return result;end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type','cold_storage','definition_id','cold_storage_v1','submitted_at',max(r.submitted_at),'submitted_by',coalesce(max(p.full_name),s.supervisor_name_snapshot),'completion',100,'issue_count',(select count(*)from public.cold_storage_issues i where i.submission_id=s.id),'status',case when exists(select 1 from public.cold_storage_issues i where i.submission_id=s.id)then'issues_found'else'compliant'end,'items',pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.equipment_id||':'||r.slot,'item_text',e.equipment_name||' — '||r.slot,'answer',r.status,'remark',r.corrective_action)order by r.slot,r.equipment_id))into result from public.cold_storage_submissions s join public.cold_storage_readings r on r.submission_id=s.id and r.submitted_at is not null join public.cold_storage_equipment e on e.submission_id=s.id and e.equipment_id=r.equipment_id left join public.profiles p on p.id=r.submitted_by_user_id where s.id=target_report_id group by s.id;if result is not null then return result;end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type','sales_tracking','definition_id','sales_tracking_v1','submitted_at',s.submitted_at,'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',100,'issue_count',0,'status','compliant','items',coalesce((select pg_catalog.jsonb_agg(x.item order by x.entry_date,x.kind)from(select r.entry_date,'sales'kind,pg_catalog.jsonb_build_object('item_id','sales:'||r.id,'item_text','Sales — '||r.entry_date,'answer','recorded','remark',coalesce(r.remarks,''))item from public.sales_tracking_sales_rows r where r.report_id=s.id union all select r.entry_date,'cash',pg_catalog.jsonb_build_object('item_id','cash:'||r.id,'item_text','Cash — '||r.entry_date,'answer','recorded','remark',coalesce(r.remarks,''))from public.sales_tracking_cash_rows r where r.report_id=s.id)x),'[]'::jsonb))into result from public.sales_tracking_reports s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)where s.id=target_report_id and s.state='submitted';if result is not null then return result;end if;
 select pg_catalog.jsonb_build_object('id',f.id,'branch_id',f.branch_id,'branch_name',f.branch_name_snapshot,'branch_code',f.branch_code_snapshot,'business_date',f.business_date,'checklist_type','financial_closing','definition_id','financial_closing_v1','submitted_at',f.submitted_at,'submitted_by',f.submitted_by_name_snapshot,'completion',private.financial_closing_completion(f.id),'issue_count',(select count(*)from public.financial_closing_items i where i.report_id=f.id and i.status='not_completed'),'status',case when exists(select 1 from public.financial_closing_items i where i.report_id=f.id and i.status='not_completed')then'issues_found'else'compliant'end,'items',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',key.item_key,'item_text',private.financial_closing_item_label(key.item_key),'answer',coalesce(item.status,'not_checked'),'remark',coalesce(item.reason,''),'follow_up',coalesce(item.follow_up,''))order by key.ordinal)from unnest(private.financial_closing_item_keys())with ordinality as key(item_key,ordinal)left join public.financial_closing_items item on item.report_id=f.id and item.item_key=key.item_key))into result from public.financial_closing_reports f where f.id=target_report_id and f.state='submitted';if result is not null then return result;end if;
 raise exception'report access denied'using errcode='42501';end$$;

revoke all on function
  private.financial_closing_item_keys(),
  private.financial_closing_item_ordinal(text),
  private.financial_closing_item_label(text),
  private.financial_closing_completion(uuid),
  private.validate_financial_closing_items(jsonb, boolean),
  private.financial_closing_payload(uuid, uuid)
from public, anon, authenticated;

revoke all on function
  public.get_financial_closing_current_state(uuid, uuid),
  public.save_financial_closing_draft(uuid, uuid, bigint, jsonb),
  public.submit_financial_closing(uuid, uuid, bigint, jsonb),
  public.list_managed_financial_closing_reports(uuid, uuid, int, int, date, date, uuid, uuid, text, text),
  public.get_managed_financial_closing_report_detail(uuid, uuid, uuid),
  public.list_phase2_branch_reports(uuid, uuid, int, int, text),
  public.get_phase2_branch_report_detail_core(uuid, uuid)
from public, anon, authenticated;

grant execute on function
  public.get_financial_closing_current_state(uuid, uuid),
  public.save_financial_closing_draft(uuid, uuid, bigint, jsonb),
  public.submit_financial_closing(uuid, uuid, bigint, jsonb),
  public.list_managed_financial_closing_reports(uuid, uuid, int, int, date, date, uuid, uuid, text, text),
  public.get_managed_financial_closing_report_detail(uuid, uuid, uuid),
  public.list_phase2_branch_reports(uuid, uuid, int, int, text),
  public.get_phase2_branch_report_detail_core(uuid, uuid)
to service_role;
