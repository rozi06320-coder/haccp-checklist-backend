create or replace function public.save_sales_tracking_draft(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;p public.sales_tracking_period_entries%rowtype;v jsonb;provider_amounts jsonb;provider_total numeric;sales_row public.sales_tracking_sales_rows%rowtype;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,c.business_date);perform private.validate_sales_tracking_entry_dates(cash_rows,c.business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 select value into strict v from pg_catalog.jsonb_array_elements(sales_rows);
 provider_amounts := coalesce(v->'online_amounts','[]'::jsonb);
 if pg_catalog.jsonb_typeof(provider_amounts) <> 'array' then raise exception'invalid sales tracking online amounts'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a) where pg_catalog.jsonb_typeof(a->'provider_id')<>'string' or (a->>'provider_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then raise exception'invalid sales tracking online provider'using errcode='22023';end if;
 if (select count(*) <> count(distinct a->>'provider_id') from pg_catalog.jsonb_array_elements(provider_amounts)e(a)) then raise exception'duplicate sales tracking online provider'using errcode='22023';end if;
 if exists(
  select 1
  from pg_catalog.jsonb_array_elements(provider_amounts)e(a)
  left join public.sales_tracking_online_order_providers provider on provider.id=(a->>'provider_id')::uuid and provider.organization_id=c.organization_id and provider.branch_id=c.branch_id and provider.active
  where provider.id is null
 ) then raise exception'invalid sales tracking online provider scope'using errcode='22023';end if;
 if pg_catalog.jsonb_array_length(provider_amounts)>0 then
  select coalesce(sum(private.sales_tracking_numeric_field(a,'amount')),0) into provider_total from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 else
  provider_total := private.sales_tracking_numeric_field(v,'online_delivery');
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':sales_tracking',0));
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date for update;
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise exception'sales tracking changed'using errcode='40001';end if;
 if s.state='submitted'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.id is not null and entry_period='middle_shift' and exists(select 1 from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period='closing_shift')then raise exception'sales tracking closing period already saved'using errcode='23505';end if;
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
 values(s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),private.sales_tracking_numeric_field(v,'pos_credit'),provider_total,nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),''))
 returning*into sales_row;
 if pg_catalog.jsonb_array_length(provider_amounts)>0 then
  insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)
  select sales_row.id,(a->>'provider_id')::uuid,private.sales_tracking_numeric_field(a,'amount')
  from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 end if;
 insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(x,'entry_date'),private.sales_tracking_integer_field(x,'denom_1'),private.sales_tracking_integer_field(x,'denom_2'),private.sales_tracking_integer_field(x,'denom_5'),private.sales_tracking_integer_field(x,'denom_10'),private.sales_tracking_integer_field(x,'denom_20'),private.sales_tracking_integer_field(x,'denom_50'),private.sales_tracking_integer_field(x,'denom_100'),private.sales_tracking_integer_field(x,'denom_200'),private.sales_tracking_integer_field(x,'denom_500'),private.sales_tracking_numeric_field(x,'remaining_cash'),nullif(pg_catalog.btrim(coalesce(x->>'remarks','')),'')from pg_catalog.jsonb_array_elements(cash_rows)e(x);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking draft denied'using errcode='42501';end$$;

create or replace function public.submit_sales_tracking(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;prior public.sales_tracking_submission_idempotency%rowtype;period_count bigint;closing_count bigint;invalid_period_count bigint;
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
 select count(*),count(*)filter(where p.entry_period='closing_shift'),count(*)filter(where p.entry_period not in('middle_shift','closing_shift'))
 into period_count,closing_count,invalid_period_count from public.sales_tracking_period_entries p where p.report_id=s.id;
 if period_count<1 or period_count>2 or closing_count<>1 or invalid_period_count<>0 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports set state='submitted',submitted_at=now(),branch_revision=branch_revision+1,updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name where id=s.id returning*into s;
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking submit denied'using errcode='42501';end$$;

revoke execute on function public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text) from public,anon,authenticated;
grant execute on function public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text) to service_role;
