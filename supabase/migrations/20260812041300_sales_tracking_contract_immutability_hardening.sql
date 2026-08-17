-- Complete the Sales two-period contract and enforce immutable persisted data at table level.

alter table public.sales_tracking_reports
  add column submitted_by_name_snapshot text;

alter table public.sales_tracking_reports
  add constraint sales_tracking_reports_submitted_by_name_snapshot_check check (
    submitted_by_name_snapshot is null
    or (
      submitted_by_name_snapshot = pg_catalog.btrim(submitted_by_name_snapshot)
      and pg_catalog.length(submitted_by_name_snapshot) > 0
    )
  );

create or replace function private.prevent_sales_tracking_period_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'saved sales tracking period is immutable' using errcode = '55000';
end
$$;

create or replace function private.prevent_sales_tracking_child_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.period_entry_id is not null
    or exists (
      select 1
      from public.sales_tracking_reports report
      where report.id = old.report_id
        and report.state = 'submitted'
    )
  then
    raise exception 'saved sales tracking data is immutable' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end
$$;

create or replace function private.require_open_sales_tracking_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.sales_tracking_reports report
    where report.id = new.report_id
      and report.state = 'submitted'
  )
  then
    raise exception 'submitted sales tracking report is immutable' using errcode = '55000';
  end if;
  return new;
end
$$;

create or replace function private.prevent_submitted_sales_tracking_report_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.state = 'submitted' then
    raise exception 'submitted sales tracking report is immutable' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end
$$;

create trigger sales_tracking_period_entries_immutable
before update or delete on public.sales_tracking_period_entries
for each row execute function private.prevent_sales_tracking_period_mutation();

create trigger sales_tracking_period_entries_require_open_report
before insert on public.sales_tracking_period_entries
for each row execute function private.require_open_sales_tracking_report();

create trigger sales_tracking_sales_rows_immutable
before update or delete on public.sales_tracking_sales_rows
for each row execute function private.prevent_sales_tracking_child_mutation();

create trigger sales_tracking_sales_rows_require_open_report
before insert on public.sales_tracking_sales_rows
for each row execute function private.require_open_sales_tracking_report();

create trigger sales_tracking_cash_rows_immutable
before update or delete on public.sales_tracking_cash_rows
for each row execute function private.prevent_sales_tracking_child_mutation();

create trigger sales_tracking_cash_rows_require_open_report
before insert on public.sales_tracking_cash_rows
for each row execute function private.require_open_sales_tracking_report();

create trigger sales_tracking_reports_submitted_immutable
before update or delete on public.sales_tracking_reports
for each row execute function private.prevent_submitted_sales_tracking_report_mutation();

create or replace function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date;
 return pg_catalog.jsonb_build_object(
  'report_id',s.id,'business_date',c.business_date,'state',coalesce(s.state,'draft'),'revision',coalesce(s.branch_revision,0),
  'submitted_at',s.submitted_at,'submitted_by_user_id',s.submitted_by_user_id,'submitted_by_name_snapshot',s.submitted_by_name_snapshot,
  'periods',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',p.id,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,
    'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at
  )order by case p.entry_period when'middle_shift'then 1 else 2 end)from public.sales_tracking_period_entries p where p.report_id=s.id),'[]'::jsonb),
  'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,
    'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,
    'actual_cash',r.actual_cash,'actual_credit',r.actual_credit,'pos_cash',r.pos_cash,'pos_credit',r.pos_credit,
    'online_delivery',r.online_delivery,'remarks',r.remarks,'actual_total',r.actual_cash+r.actual_credit+r.online_delivery,
    'pos_total',r.pos_cash+r.pos_credit+r.online_delivery,
    'variance',(r.actual_cash+r.actual_credit+r.online_delivery)-(r.pos_cash+r.pos_credit+r.online_delivery)
  )order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_sales_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,
    'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,
    'denom_1',r.denom_1,'denom_2',r.denom_2,'denom_5',r.denom_5,'denom_10',r.denom_10,
    'denom_20',r.denom_20,'denom_50',r.denom_50,'denom_100',r.denom_100,'denom_200',r.denom_200,
    'denom_500',r.denom_500,'remaining_cash',r.remaining_cash,'remarks',r.remarks,
    'cash_total',r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500
  )order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_cash_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'totals',pg_catalog.jsonb_build_object(
    'actual_cash',coalesce((select sum(r.actual_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'actual_credit',coalesce((select sum(r.actual_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'pos_cash',coalesce((select sum(r.pos_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'pos_credit',coalesce((select sum(r.pos_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'online_delivery',coalesce((select sum(r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'actual_total',coalesce((select sum(r.actual_cash+r.actual_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'pos_total',coalesce((select sum(r.pos_cash+r.pos_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'variance',coalesce((select sum((r.actual_cash+r.actual_credit)-(r.pos_cash+r.pos_credit))from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'cash_total',coalesce((select sum(r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)from public.sales_tracking_cash_rows r where r.report_id=s.id),0),
    'remaining_cash',coalesce((select sum(r.remaining_cash)from public.sales_tracking_cash_rows r where r.report_id=s.id),0)
  )
 );
exception when no_data_found or too_many_rows then raise exception'sales tracking state denied'using errcode='42501';end$$;

create or replace function public.submit_sales_tracking(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;prior public.sales_tracking_submission_idempotency%rowtype;
begin
 if request_hash!~'^[0-9a-f]{64}$'then raise exception'invalid sales tracking request hash'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':sales_tracking',0));
 select*into prior from public.sales_tracking_submission_idempotency x where x.actor_user_id=submit_sales_tracking.actor_user_id and x.idempotency_key=submit_sales_tracking.idempotency_key;
 if prior.actor_user_id is not null then
  if prior.request_hash<>request_hash then raise exception'sales tracking idempotency conflict'using errcode='23505';end if;
  perform 1 from public.sales_tracking_reports x where x.id=prior.report_id and x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date and x.state='submitted';
  if not found then raise exception'sales tracking submit denied'using errcode='42501';end if;
  return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
 end if;
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date for update;
 if s.id is null or coalesce(expected_revision,-1)<>s.branch_revision then raise exception'sales tracking changed'using errcode='40001';end if;
 if s.state='submitted'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if(select count(*)from public.sales_tracking_period_entries p where p.report_id=s.id)<>2 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports set state='submitted',submitted_at=now(),branch_revision=branch_revision+1,updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name where id=s.id returning*into s;
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking submit denied'using errcode='42501';end$$;

revoke all on public.sales_tracking_reports,public.sales_tracking_sales_rows,public.sales_tracking_cash_rows,public.sales_tracking_period_entries,public.sales_tracking_submission_idempotency from service_role;
revoke all on public.sales_tracking_reports,public.sales_tracking_sales_rows,public.sales_tracking_cash_rows,public.sales_tracking_period_entries,public.sales_tracking_submission_idempotency from public,anon,authenticated;

revoke all on function private.prevent_sales_tracking_period_mutation(),private.prevent_sales_tracking_child_mutation(),private.require_open_sales_tracking_report(),private.prevent_submitted_sales_tracking_report_mutation() from public,anon,authenticated,service_role;
revoke all on function public.get_sales_tracking_current_state(uuid,uuid),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.get_sales_tracking_current_state(uuid,uuid),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text) to service_role;
