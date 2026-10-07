begin;

alter table public.sales_tracking_reports
  add column review_status text not null default 'none',
  add column review_revision bigint not null default 0,
  add column reviewed_at timestamptz,
  add column reviewed_by_user_id uuid references public.profiles(id) on delete restrict,
  add constraint sales_tracking_reports_review_status_check
    check (review_status in ('none','needs_review','reviewed')),
  add constraint sales_tracking_reports_review_revision_check check (review_revision >= 0),
  add constraint sales_tracking_reports_review_actor_check check (
    (review_status = 'none' and reviewed_at is null and reviewed_by_user_id is null)
    or (review_status <> 'none' and reviewed_at is not null and reviewed_by_user_id is not null)
  ),
  add constraint sales_tracking_reports_draft_review_check check (
    state <> 'draft'
    or (review_status = 'none' and review_revision = 0 and reviewed_at is null and reviewed_by_user_id is null)
  );

create table public.sales_tracking_review_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  report_id uuid not null,
  from_status text not null check (from_status in ('none','needs_review','reviewed')),
  to_status text not null check (to_status in ('needs_review','reviewed') and to_status <> from_status),
  actor_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint sales_tracking_review_events_report_scope_fkey
    foreign key (report_id, organization_id, branch_id)
    references public.sales_tracking_reports(id, organization_id, branch_id) on delete restrict
);

create index sales_tracking_review_events_report_created_idx
  on public.sales_tracking_review_events(report_id, created_at desc);

alter table public.sales_tracking_review_events enable row level security;
revoke all on public.sales_tracking_review_events from public, anon, authenticated, service_role;

create or replace function private.prevent_submitted_sales_tracking_report_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.state = 'submitted' then
    if tg_op = 'UPDATE'
      and (pg_catalog.to_jsonb(new) - array['review_status','review_revision','reviewed_at','reviewed_by_user_id','updated_at']::text[])
        = (pg_catalog.to_jsonb(old) - array['review_status','review_revision','reviewed_at','reviewed_by_user_id','updated_at']::text[])
      and new.review_status is distinct from old.review_status
      and new.review_revision = old.review_revision + 1
      and new.review_status in ('needs_review','reviewed')
      and new.reviewed_at is not null
      and new.reviewed_by_user_id is not null
    then
      return new;
    end if;
    raise exception 'submitted sales tracking report is immutable' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end
$$;

create function private.sales_tracking_review_json(target_report_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'review_status', report.review_status,
    'review_revision', report.review_revision,
    'reviewed_at', report.reviewed_at,
    'reviewed_by_user_id', report.reviewed_by_user_id,
    'reviewed_by', reviewer.full_name
  )
  from public.sales_tracking_reports report
  left join public.profiles reviewer on reviewer.id = report.reviewed_by_user_id
  where report.id = target_report_id
$$;
revoke all on function private.sales_tracking_review_json(uuid) from public, anon, authenticated, service_role;

create function public.set_managed_sales_tracking_review_status(
  actor_user_id uuid,
  target_organization_id uuid,
  target_report_id uuid,
  expected_review_revision bigint,
  target_review_status text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  report public.sales_tracking_reports%rowtype;
  actor_name text;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'sales tracking review access denied' using errcode = '42501';
  end if;
  if target_review_status not in ('needs_review','reviewed') then
    raise exception 'invalid sales tracking review status' using errcode = '22023';
  end if;

  select r.* into report
  from public.sales_tracking_reports r
  where r.id = target_report_id and r.organization_id = target_organization_id
  for update;
  if not found then
    raise exception 'sales tracking report not found' using errcode = 'P0002';
  end if;
  if report.state <> 'submitted' then
    raise exception 'sales tracking report is not submitted' using errcode = '55000';
  end if;
  if report.review_revision <> expected_review_revision then
    raise sqlstate 'PT409' using message = 'sales tracking review changed';
  end if;
  if report.review_status = target_review_status then
    raise exception 'sales tracking review status is unchanged' using errcode = '22023';
  end if;

  update public.sales_tracking_reports r
  set review_status = target_review_status,
      review_revision = r.review_revision + 1,
      reviewed_at = pg_catalog.now(),
      reviewed_by_user_id = actor_user_id
  where r.id = report.id;

  insert into public.sales_tracking_review_events(
    organization_id, branch_id, report_id, from_status, to_status, actor_user_id
  ) values (
    report.organization_id, report.branch_id, report.id, report.review_status, target_review_status, actor_user_id
  );

  select p.full_name into actor_name from public.profiles p where p.id = actor_user_id;
  return pg_catalog.jsonb_build_object(
    'report_id', report.id,
    'review_status', target_review_status,
    'review_revision', report.review_revision + 1,
    'reviewed_at', (select r.reviewed_at from public.sales_tracking_reports r where r.id = report.id),
    'reviewed_by_user_id', actor_user_id,
    'reviewed_by', actor_name
  );
end
$$;

revoke all on function public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text)
  from public, anon, authenticated;
grant execute on function public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text)
  to service_role;

alter function public.get_sales_tracking_current_state(uuid,uuid,date)
  rename to get_sales_tracking_current_state_without_review_legacy;
revoke all on function public.get_sales_tracking_current_state_without_review_legacy(uuid,uuid,date)
  from public, anon, authenticated, service_role;

create function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid,target_business_date date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; report_id uuid;
begin
  result := public.get_sales_tracking_current_state_without_review_legacy(actor_user_id,target_branch_id,target_business_date);
  report_id := (result->>'report_id')::uuid;
  return result || coalesce(private.sales_tracking_review_json(report_id),
    pg_catalog.jsonb_build_object('review_status','none','review_revision',0,'reviewed_at',null,'reviewed_by_user_id',null,'reviewed_by',null));
end
$$;
revoke all on function public.get_sales_tracking_current_state(uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.get_sales_tracking_current_state(uuid,uuid,date) to service_role;

alter function public.list_managed_sales_tracking_reports(uuid,uuid,date,date)
  rename to list_managed_sales_tracking_reports_without_review_legacy;
revoke all on function public.list_managed_sales_tracking_reports_without_review_legacy(uuid,uuid,date,date)
  from public,anon,authenticated,service_role;

create function public.list_managed_sales_tracking_reports(actor_user_id uuid,target_organization_id uuid,from_date date default null,to_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; sales_rows jsonb; cash_rows jsonb;
begin
  result := public.list_managed_sales_tracking_reports_without_review_legacy(actor_user_id,target_organization_id,from_date,to_date);
  select coalesce(pg_catalog.jsonb_agg(row_value || private.sales_tracking_review_json((row_value->>'report_id')::uuid)),'[]'::jsonb)
    into sales_rows from pg_catalog.jsonb_array_elements(result->'sales_rows') row_value;
  select coalesce(pg_catalog.jsonb_agg(row_value || private.sales_tracking_review_json((row_value->>'report_id')::uuid)),'[]'::jsonb)
    into cash_rows from pg_catalog.jsonb_array_elements(result->'cash_rows') row_value;
  return pg_catalog.jsonb_set(pg_catalog.jsonb_set(result,'{sales_rows}',sales_rows),'{cash_rows}',cash_rows);
end
$$;
revoke all on function public.list_managed_sales_tracking_reports(uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function public.list_managed_sales_tracking_reports(uuid,uuid,date,date) to service_role;

alter function public.list_phase2_branch_reports(uuid,uuid,int,int,text)
  rename to list_phase2_branch_reports_without_review_legacy;
revoke all on function public.list_phase2_branch_reports_without_review_legacy(uuid,uuid,int,int,text)
  from public,anon,authenticated,service_role;

create function public.list_phase2_branch_reports(actor_user_id uuid,target_branch_id uuid,requested_page int default 1,requested_page_size int default 20,target_checklist_type text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; rows jsonb;
begin
  result := public.list_phase2_branch_reports_without_review_legacy(actor_user_id,target_branch_id,requested_page,requested_page_size,target_checklist_type);
  select coalesce(pg_catalog.jsonb_agg(case when row_value->>'checklist_type'='sales_tracking'
    then row_value || private.sales_tracking_review_json((row_value->>'id')::uuid) else row_value end),'[]'::jsonb)
    into rows from pg_catalog.jsonb_array_elements(result->'reports') row_value;
  return pg_catalog.jsonb_set(result,'{reports}',rows);
end
$$;
revoke all on function public.list_phase2_branch_reports(uuid,uuid,int,int,text) from public,anon,authenticated;
grant execute on function public.list_phase2_branch_reports(uuid,uuid,int,int,text) to service_role;

alter function public.get_phase2_branch_report_detail(uuid,uuid)
  rename to get_phase2_branch_report_detail_without_review_legacy;
revoke all on function public.get_phase2_branch_report_detail_without_review_legacy(uuid,uuid)
  from public,anon,authenticated,service_role;

create function public.get_phase2_branch_report_detail(actor_user_id uuid,target_report_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  result := public.get_phase2_branch_report_detail_without_review_legacy(actor_user_id,target_report_id);
  if result->>'checklist_type'='sales_tracking' then
    result := result || private.sales_tracking_review_json(target_report_id);
  end if;
  return result;
end
$$;
revoke all on function public.get_phase2_branch_report_detail(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_phase2_branch_report_detail(uuid,uuid) to service_role;

commit;
