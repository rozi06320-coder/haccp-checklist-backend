-- Sales Tracking explicit business-date RPC support.
-- This migration preserves existing no-date RPC signatures for staged rollout compatibility.
-- New clients pass target_business_date and the database rejects future dates using the
-- branch-local current business date from private.phase2_branch_context, which delegates
-- to the production 04:00-aware private.phase4a_business_date(branch.timezone).

create or replace function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid,target_business_date date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;v_business_date date;v_currency text;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null then raise exception'sales tracking business date required'using errcode='22004';end if;
 v_business_date:=target_business_date;
 if v_business_date>c.business_date then raise exception'sales tracking future business date denied'using errcode='22023';end if;
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=v_business_date;
 select case branch.country_code when 'AE' then 'AED' else 'SAR' end into strict v_currency from public.branches branch where branch.id=c.branch_id and branch.organization_id=c.organization_id;
 return pg_catalog.jsonb_build_object(
  'report_id',s.id,'business_date',v_business_date,'currency_code',coalesce(s.currency_code,v_currency),'state',coalesce(s.state,'draft'),'revision',coalesce(s.branch_revision,0),
  'submitted_at',s.submitted_at,'submitted_by_user_id',s.submitted_by_user_id,'submitted_by_name_snapshot',s.submitted_by_name_snapshot,
  'periods',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',p.id,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at)order by case p.entry_period when'middle_shift'then 1 else 2 end)from public.sales_tracking_period_entries p where p.report_id=s.id),'[]'::jsonb),
  'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'actual_cash',r.actual_cash,'actual_credit',r.actual_credit,'pos_cash',r.pos_cash,'pos_credit',r.pos_credit,'online_delivery',r.online_delivery,'online_amounts',private.sales_tracking_online_amounts_for_row(r.id),'remarks',r.remarks,'actual_total',r.actual_cash+r.actual_credit+r.online_delivery,'pos_total',r.pos_cash+r.pos_credit+r.online_delivery,'variance',(r.actual_cash+r.actual_credit+r.online_delivery)-(r.pos_cash+r.pos_credit+r.online_delivery))order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_sales_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'denom_1',r.denom_1,'denom_2',r.denom_2,'denom_5',r.denom_5,'denom_10',r.denom_10,'denom_20',r.denom_20,'denom_50',r.denom_50,'denom_100',r.denom_100,'denom_200',r.denom_200,'denom_500',r.denom_500,'remaining_cash',r.remaining_cash,'remarks',r.remarks,'cash_total',r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_cash_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'totals',pg_catalog.jsonb_build_object('actual_cash',coalesce((select sum(r.actual_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'actual_credit',coalesce((select sum(r.actual_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_cash',coalesce((select sum(r.pos_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_credit',coalesce((select sum(r.pos_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'online_delivery',coalesce((select sum(r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'actual_total',coalesce((select sum(r.actual_cash+r.actual_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_total',coalesce((select sum(r.pos_cash+r.pos_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'variance',coalesce((select sum((r.actual_cash+r.actual_credit)-(r.pos_cash+r.pos_credit))from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'cash_total',coalesce((select sum(r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)from public.sales_tracking_cash_rows r where r.report_id=s.id),0),'remaining_cash',coalesce((select sum(r.remaining_cash)from public.sales_tracking_cash_rows r where r.report_id=s.id),0))
 );
exception when no_data_found or too_many_rows then raise exception'sales tracking state denied'using errcode='42501';end;
$$;

create or replace function public.save_sales_tracking_draft(actor_user_id uuid,target_branch_id uuid,target_business_date date,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;p public.sales_tracking_period_entries%rowtype;v_business_date date;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null then raise exception'sales tracking business date required'using errcode='22004';end if;
 v_business_date:=target_business_date;
 if v_business_date>c.business_date then raise exception'sales tracking future business date denied'using errcode='22023';end if;
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,v_business_date);perform private.validate_sales_tracking_entry_dates(cash_rows,v_business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||v_business_date::text||':sales_tracking',0));
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=v_business_date for update;
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise exception'sales tracking changed'using errcode='40001';end if;
 if s.state='submitted'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.id is null then
  insert into public.sales_tracking_reports(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,branch_revision,updated_by_user_id)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,v_business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',1,actor_user_id)returning*into s;
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
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,v_business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking draft denied'using errcode='42501';end;
$$;

create or replace function public.submit_sales_tracking(actor_user_id uuid,target_branch_id uuid,target_business_date date,expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;prior public.sales_tracking_submission_idempotency%rowtype;v_business_date date;
begin
 if request_hash!~'^[0-9a-f]{64}$'then raise exception'invalid sales tracking request hash'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null then raise exception'sales tracking business date required'using errcode='22004';end if;
 v_business_date:=target_business_date;
 if v_business_date>c.business_date then raise exception'sales tracking future business date denied'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||v_business_date::text||':sales_tracking',0));
 select*into prior from public.sales_tracking_submission_idempotency x where x.actor_user_id=submit_sales_tracking.actor_user_id and x.idempotency_key=submit_sales_tracking.idempotency_key;
 if prior.actor_user_id is not null then
  if prior.request_hash<>request_hash then raise exception'sales tracking idempotency conflict'using errcode='23505';end if;
  perform 1 from public.sales_tracking_reports x where x.id=prior.report_id and x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=v_business_date and x.state='submitted';
  if not found then raise exception'sales tracking submit denied'using errcode='42501';end if;
  return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,v_business_date);
 end if;
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=v_business_date for update;
 if s.id is null or coalesce(expected_revision,-1)<>s.branch_revision then raise exception'sales tracking changed'using errcode='40001';end if;
 if s.state='submitted'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if(select count(*)from public.sales_tracking_period_entries p where p.report_id=s.id)<>2 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports set state='submitted',submitted_at=now(),branch_revision=branch_revision+1,updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name where id=s.id returning*into s;
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,v_business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking submit denied'using errcode='42501';end;
$$;

revoke all on function public.get_sales_tracking_current_state(uuid,uuid,date),public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,date,bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.get_sales_tracking_current_state(uuid,uuid,date),public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,date,bigint,uuid,text) to service_role;
