-- Treat Sales Tracking optimistic-concurrency conflicts as HTTP 409 business
-- conflicts instead of retryable PostgreSQL serialization failures.

create or replace function public.save_sales_tracking_draft(
  actor_user_id uuid,
  target_branch_id uuid,
  target_business_date date,
  expected_revision bigint,
  entry_period text,
  sales_rows jsonb,
  cash_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise sqlstate 'PT409' using message='sales tracking changed';end if;
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
$function$;

revoke all on function public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb)
from public,anon,authenticated;
grant execute on function public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb)
to service_role;
