-- Two immutable operational periods inside one branch-owned daily Sales report.
-- Legacy child rows remain unassigned because earlier data contains no reliable period evidence.

create table public.sales_tracking_period_entries (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.sales_tracking_reports(id) on delete cascade,
  entry_period text not null check (entry_period in ('middle_shift','closing_shift')),
  entered_by_user_id uuid not null references auth.users(id) on delete restrict,
  entered_by_name_snapshot text not null,
  entered_at timestamptz not null default now(),
  unique(report_id, entry_period),
  unique(id, report_id),
  constraint sales_tracking_period_entries_name_check check (
    entered_by_name_snapshot = btrim(entered_by_name_snapshot)
    and length(entered_by_name_snapshot) > 0
  )
);

alter table public.sales_tracking_sales_rows
  add column period_entry_id uuid;
alter table public.sales_tracking_cash_rows
  add column period_entry_id uuid;

alter table public.sales_tracking_sales_rows
  drop constraint sales_tracking_sales_rows_report_id_entry_date_key;
alter table public.sales_tracking_cash_rows
  drop constraint sales_tracking_cash_rows_report_id_entry_date_key;

alter table public.sales_tracking_sales_rows
  add constraint sales_tracking_sales_rows_period_scope_fkey
  foreign key(period_entry_id, report_id)
  references public.sales_tracking_period_entries(id, report_id) on delete cascade;
alter table public.sales_tracking_cash_rows
  add constraint sales_tracking_cash_rows_period_scope_fkey
  foreign key(period_entry_id, report_id)
  references public.sales_tracking_period_entries(id, report_id) on delete cascade;

create unique index sales_tracking_sales_rows_period_uidx
  on public.sales_tracking_sales_rows(period_entry_id)
  where period_entry_id is not null;
create unique index sales_tracking_cash_rows_period_uidx
  on public.sales_tracking_cash_rows(period_entry_id)
  where period_entry_id is not null;
create unique index sales_tracking_sales_rows_legacy_report_date_uidx
  on public.sales_tracking_sales_rows(report_id, entry_date)
  where period_entry_id is null;
create unique index sales_tracking_cash_rows_legacy_report_date_uidx
  on public.sales_tracking_cash_rows(report_id, entry_date)
  where period_entry_id is null;
create index sales_tracking_period_entries_actor_idx
  on public.sales_tracking_period_entries(entered_by_user_id, entered_at desc);

alter table public.sales_tracking_period_entries enable row level security;
revoke all on public.sales_tracking_period_entries from anon, authenticated;

drop function public.save_sales_tracking_draft(uuid,uuid,bigint,jsonb,jsonb);
drop function public.submit_sales_tracking(uuid,uuid,bigint,uuid,text,jsonb,jsonb);

create or replace function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date;
 return pg_catalog.jsonb_build_object(
  'report_id',s.id,'business_date',c.business_date,'state',coalesce(s.state,'draft'),'revision',coalesce(s.branch_revision,0),'submitted_at',s.submitted_at,
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

create function public.save_sales_tracking_draft(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;p public.sales_tracking_period_entries%rowtype;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,c.business_date);perform private.validate_sales_tracking_entry_dates(cash_rows,c.business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':sales_tracking',0));
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date for update;
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise exception'sales tracking changed'using errcode='40001';end if;
 if s.state='submitted'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.id is null then
  insert into public.sales_tracking_reports(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,branch_revision,updated_by_user_id)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',1,actor_user_id)returning*into s;
 else
  if exists(select 1 from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period=save_sales_tracking_draft.entry_period)then raise exception'sales tracking period already saved'using errcode='23505';end if;
  update public.sales_tracking_reports set branch_revision=branch_revision+1,updated_by_user_id=actor_user_id,updated_at=now()where id=s.id returning*into s;
 end if;
 insert into public.sales_tracking_period_entries(report_id,entry_period,entered_by_user_id,entered_by_name_snapshot)
 values(s.id,entry_period,actor_user_id,c.actor_name)returning*into p;
 insert into public.sales_tracking_sales_rows(report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,remarks)
 select s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),private.sales_tracking_numeric_field(v,'pos_credit'),private.sales_tracking_numeric_field(v,'online_delivery'),nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),'')from pg_catalog.jsonb_array_elements(sales_rows)e(v);
 insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_integer_field(v,'denom_1'),private.sales_tracking_integer_field(v,'denom_2'),private.sales_tracking_integer_field(v,'denom_5'),private.sales_tracking_integer_field(v,'denom_10'),private.sales_tracking_integer_field(v,'denom_20'),private.sales_tracking_integer_field(v,'denom_50'),private.sales_tracking_integer_field(v,'denom_100'),private.sales_tracking_integer_field(v,'denom_200'),private.sales_tracking_integer_field(v,'denom_500'),private.sales_tracking_numeric_field(v,'remaining_cash'),nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),'')from pg_catalog.jsonb_array_elements(cash_rows)e(v);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking draft denied'using errcode='42501';end$$;

create function public.submit_sales_tracking(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;prior public.sales_tracking_submission_idempotency%rowtype;
begin
 if request_hash!~'^[0-9a-f]{64}$'then raise exception'invalid sales tracking request hash'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into prior from public.sales_tracking_submission_idempotency x where x.actor_user_id=submit_sales_tracking.actor_user_id and x.idempotency_key=submit_sales_tracking.idempotency_key;
 if prior.actor_user_id is not null then
  if prior.request_hash<>request_hash then raise exception'sales tracking idempotency conflict'using errcode='23505';end if;
  perform 1 from public.sales_tracking_reports x where x.id=prior.report_id and x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date and x.state='submitted';
  if not found then raise exception'sales tracking submit denied'using errcode='42501';end if;
  return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':sales_tracking',0));
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date for update;
 if s.id is null or coalesce(expected_revision,-1)<>s.branch_revision then raise exception'sales tracking changed'using errcode='40001';end if;
 if s.state='submitted'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if(select count(*)from public.sales_tracking_period_entries p where p.report_id=s.id)<>2 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports set state='submitted',submitted_at=now(),branch_revision=branch_revision+1,updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id where id=s.id returning*into s;
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking submit denied'using errcode='42501';end$$;

create or replace function public.list_managed_sales_tracking_reports(actor_user_id uuid,target_organization_id uuid,from_date date default null,to_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)or(from_date is not null and to_date is not null and from_date>to_date)then raise exception'sales tracking report access denied'using errcode='42501';end if;
 return pg_catalog.jsonb_build_object(
 'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('report_id',r.id,'row_id',x.id,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,'actual_cash',x.actual_cash,'actual_credit',x.actual_credit,'pos_cash',x.pos_cash,'pos_credit',x.pos_credit,'online_delivery',x.online_delivery,'actual_total',x.actual_cash+x.actual_credit+x.online_delivery,'pos_total',x.pos_cash+x.pos_credit+x.online_delivery,'variance',(x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit),'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_sales_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb),
 'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('report_id',r.id,'row_id',x.id,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,'denom_1',x.denom_1,'denom_2',x.denom_2,'denom_5',x.denom_5,'denom_10',x.denom_10,'denom_20',x.denom_20,'denom_50',x.denom_50,'denom_100',x.denom_100,'denom_200',x.denom_200,'denom_500',x.denom_500,'cash_total',x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500,'remaining_cash',x.remaining_cash,'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_cash_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb));
end$$;

alter function public.get_phase2_branch_report_detail(uuid,uuid) rename to get_phase2_branch_report_detail_before_sales_periods;
revoke all on function public.get_phase2_branch_report_detail_before_sales_periods(uuid,uuid) from public,anon,authenticated,service_role;
create function public.get_phase2_branch_report_detail(actor_user_id uuid,target_report_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;branch uuid;
begin
 select s.branch_id into branch from public.sales_tracking_reports s where s.id=target_report_id;
 if branch is null then return public.get_phase2_branch_report_detail_before_sales_periods(actor_user_id,target_report_id);end if;
 if not private.actor_can_read_operational_branch(actor_user_id,branch)then raise exception'report access denied'using errcode='42501';end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type','sales_tracking','definition_id','sales_tracking_v2','submitted_at',s.submitted_at,'submitted_by',coalesce(sp.full_name,s.supervisor_name_snapshot),'completion',100,'issue_count',0,'status','compliant','items',coalesce((select pg_catalog.jsonb_agg(i order by sort_period,kind)from(
  select case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end sort_period,'sales'kind,pg_catalog.jsonb_build_object('item_id','sales:'||r.id,'item_text',coalesce(initcap(replace(p.entry_period,'_',' ')),'Legacy')||' — Sales','answer','recorded','remark',coalesce(r.remarks,''),'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at)i from public.sales_tracking_sales_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id
  union all select case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,'cash',pg_catalog.jsonb_build_object('item_id','cash:'||r.id,'item_text',coalesce(initcap(replace(p.entry_period,'_',' ')),'Legacy')||' — Cash','answer','recorded','remark',coalesce(r.remarks,''),'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at)from public.sales_tracking_cash_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id)x),'[]'::jsonb))into result from public.sales_tracking_reports s left join public.profiles sp on sp.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)where s.id=target_report_id and s.state='submitted';
 if result is null then raise exception'report access denied'using errcode='42501';end if;return result;
end$$;

revoke all on function public.get_sales_tracking_current_state(uuid,uuid),public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text),public.list_managed_sales_tracking_reports(uuid,uuid,date,date),public.get_phase2_branch_report_detail(uuid,uuid)from public,anon,authenticated;
grant execute on function public.get_sales_tracking_current_state(uuid,uuid),public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text),public.list_managed_sales_tracking_reports(uuid,uuid,date,date),public.get_phase2_branch_report_detail(uuid,uuid)to service_role;
