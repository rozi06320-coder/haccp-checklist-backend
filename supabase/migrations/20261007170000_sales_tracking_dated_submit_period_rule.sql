begin;

-- The explicit-date API is the normal Supervisor path. Keep its completion
-- rule aligned with the legacy overload: Closing-only or Middle plus Closing.
create or replace function public.submit_sales_tracking(
 actor_user_id uuid,target_branch_id uuid,target_business_date date,
 expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 c record;
 s public.sales_tracking_reports%rowtype;
 case_row public.sales_tracking_report_cases%rowtype;
 prior public.sales_tracking_submission_idempotency%rowtype;
 period_count bigint;
 closing_count bigint;
 invalid_period_count bigint;
begin
 if request_hash!~'^[0-9a-f]{64}$'then raise exception'invalid sales tracking request hash'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null then raise exception'sales tracking business date required'using errcode='22004';end if;
 if target_business_date>c.business_date then raise exception'sales tracking future business date denied'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_business_date::text||':sales_tracking',0));
 select*into prior from public.sales_tracking_submission_idempotency x where x.actor_user_id=submit_sales_tracking.actor_user_id and x.idempotency_key=submit_sales_tracking.idempotency_key;
 if prior.actor_user_id is not null then
  if prior.request_hash<>request_hash then raise exception'sales tracking idempotency conflict'using errcode='23505';end if;
  perform 1 from public.sales_tracking_reports x where x.id=prior.report_id and x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=target_business_date and x.state='submitted';
  if not found then raise exception'sales tracking submit denied'using errcode='42501';end if;
  return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,target_business_date);
 end if;
 case_row:=private.lock_normal_sales_tracking_case(c.organization_id,c.branch_id,target_business_date,false);
 if case_row.id is null then raise sqlstate'PT409'using message='sales tracking changed';end if;
 if case_row.authoritative_report_id is not null then raise exception'sales tracking already submitted'using errcode='23505';end if;
 select r.*into s from public.sales_tracking_reports r where r.case_id=case_row.id and r.state='draft'for update;
 if s.id is null or coalesce(expected_revision,-1)<>s.branch_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 select count(*),count(*)filter(where p.entry_period='closing_shift'),count(*)filter(where p.entry_period not in('middle_shift','closing_shift'))
 into period_count,closing_count,invalid_period_count
 from public.sales_tracking_period_entries p where p.report_id=s.id;
 if period_count<1 or period_count>2 or closing_count<>1 or invalid_period_count<>0 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports r set state='submitted',submitted_at=pg_catalog.now(),branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name where r.id=s.id returning*into s;
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,target_business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking submit denied'using errcode='42501';end$$;

revoke all on function public.submit_sales_tracking(uuid,uuid,date,bigint,uuid,text)from public,anon,authenticated;
grant execute on function public.submit_sales_tracking(uuid,uuid,date,bigint,uuid,text)to service_role;

commit;
