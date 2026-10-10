begin;

-- Convert only untouched legacy copied corrections. The provider-total
-- constraint is made immediate so each explicit provider delete is validated
-- while its Sales parent still exists; it is restored before returning.
create or replace function private.convert_untouched_sales_tracking_corrections()
returns bigint language plpgsql security definer set search_path='' as $$
declare
 candidate record;
 eligible boolean;
 converted_count bigint:=0;
begin
 set constraints public.sales_tracking_online_amounts_total_check immediate;
 for candidate in
  select case_row.id case_id,case_row.organization_id,case_row.open_correction_report_id draft_id
  from public.sales_tracking_report_cases case_row
  where case_row.open_correction_report_id is not null
  order by case_row.id
 loop
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
   candidate.organization_id::text||':'||candidate.draft_id::text||':sales_tracking_correction',0));
  perform 1
  from public.sales_tracking_report_cases case_lock
  join public.sales_tracking_reports source_lock on source_lock.id=case_lock.authoritative_report_id
  join public.sales_tracking_reports draft_lock on draft_lock.id=case_lock.open_correction_report_id
  where case_lock.id=candidate.case_id and draft_lock.id=candidate.draft_id
  for update of case_lock,source_lock,draft_lock;
  if not found then continue;end if;

  select
   case_row.open_correction_report_id=draft.id
   and case_row.authoritative_report_id=source.id
   and draft.state='draft'
   and source.state='submitted'
   and source.review_status='needs_review'
   and draft.supersedes_report_id=source.id
   and draft.branch_revision=1
   and draft.submitted_at is null
   and draft.correction_created_by_user_id is not null
   and draft.updated_by_user_id=draft.correction_created_by_user_id
   and not exists(select 1 from public.sales_tracking_attachments attachment where attachment.report_id=draft.id)
   and not exists(select 1 from public.sales_tracking_review_events event where event.report_id=draft.id)
   and not exists(
    (select period.entry_period from public.sales_tracking_period_entries period where period.report_id=draft.id
     except all
     select period.entry_period from public.sales_tracking_period_entries period where period.report_id=source.id)
    union all
    (select period.entry_period from public.sales_tracking_period_entries period where period.report_id=source.id
     except all
     select period.entry_period from public.sales_tracking_period_entries period where period.report_id=draft.id))
   and not exists(
    (select period.entry_period,row.entry_date,row.actual_cash,row.actual_credit,row.pos_cash,row.pos_credit,
      row.online_delivery,row.refund_total,row.remarks
     from public.sales_tracking_sales_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=draft.id
     except all
     select period.entry_period,row.entry_date,row.actual_cash,row.actual_credit,row.pos_cash,row.pos_credit,
      row.online_delivery,row.refund_total,row.remarks
     from public.sales_tracking_sales_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=source.id)
    union all
    (select period.entry_period,row.entry_date,row.actual_cash,row.actual_credit,row.pos_cash,row.pos_credit,
      row.online_delivery,row.refund_total,row.remarks
     from public.sales_tracking_sales_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=source.id
     except all
     select period.entry_period,row.entry_date,row.actual_cash,row.actual_credit,row.pos_cash,row.pos_credit,
      row.online_delivery,row.refund_total,row.remarks
     from public.sales_tracking_sales_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=draft.id))
   and not exists(
    (select period.entry_period,row.entry_date,row.denom_1,row.denom_2,row.denom_5,row.denom_10,
      row.denom_20,row.denom_50,row.denom_100,row.denom_200,row.denom_500,row.remaining_cash,row.remarks
     from public.sales_tracking_cash_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=draft.id
     except all
     select period.entry_period,row.entry_date,row.denom_1,row.denom_2,row.denom_5,row.denom_10,
      row.denom_20,row.denom_50,row.denom_100,row.denom_200,row.denom_500,row.remaining_cash,row.remarks
     from public.sales_tracking_cash_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=source.id)
    union all
    (select period.entry_period,row.entry_date,row.denom_1,row.denom_2,row.denom_5,row.denom_10,
      row.denom_20,row.denom_50,row.denom_100,row.denom_200,row.denom_500,row.remaining_cash,row.remarks
     from public.sales_tracking_cash_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=source.id
     except all
     select period.entry_period,row.entry_date,row.denom_1,row.denom_2,row.denom_5,row.denom_10,
      row.denom_20,row.denom_50,row.denom_100,row.denom_200,row.denom_500,row.remaining_cash,row.remarks
     from public.sales_tracking_cash_rows row join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where row.report_id=draft.id))
   and not exists(
    (select period.entry_period,amount.provider_id,amount.amount
     from public.sales_tracking_online_amounts amount
     join public.sales_tracking_sales_rows row on row.id=amount.sales_row_id
     join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where amount.report_id=draft.id
     except all
     select period.entry_period,amount.provider_id,amount.amount
     from public.sales_tracking_online_amounts amount
     join public.sales_tracking_sales_rows row on row.id=amount.sales_row_id
     join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where amount.report_id=source.id)
    union all
    (select period.entry_period,amount.provider_id,amount.amount
     from public.sales_tracking_online_amounts amount
     join public.sales_tracking_sales_rows row on row.id=amount.sales_row_id
     join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where amount.report_id=source.id
     except all
     select period.entry_period,amount.provider_id,amount.amount
     from public.sales_tracking_online_amounts amount
     join public.sales_tracking_sales_rows row on row.id=amount.sales_row_id
     join public.sales_tracking_period_entries period on period.id=row.period_entry_id
     where amount.report_id=draft.id))
  into eligible
  from public.sales_tracking_report_cases case_row
  join public.sales_tracking_reports source on source.id=case_row.authoritative_report_id
  join public.sales_tracking_reports draft on draft.id=case_row.open_correction_report_id
  where case_row.id=candidate.case_id and draft.id=candidate.draft_id;

  if coalesce(eligible,false)then
   delete from public.sales_tracking_online_amounts amount where amount.report_id=candidate.draft_id;
   delete from public.sales_tracking_sales_rows row where row.report_id=candidate.draft_id;
   delete from public.sales_tracking_cash_rows row where row.report_id=candidate.draft_id;
   delete from public.sales_tracking_period_entries period where period.report_id=candidate.draft_id;
   update public.sales_tracking_reports draft
   set branch_revision=2,updated_at=pg_catalog.now()
   where draft.id=candidate.draft_id and draft.state='draft'and draft.branch_revision=1;
   converted_count:=converted_count+1;
  end if;
 end loop;
 set constraints public.sales_tracking_online_amounts_total_check deferred;
 return converted_count;
end$$;
revoke all on function private.convert_untouched_sales_tracking_corrections()
 from public,anon,authenticated,service_role;

select private.convert_untouched_sales_tracking_corrections();

-- Needs Review starts a replacement version with current attribution and no
-- copied financial/evidence children. The authoritative submission remains
-- unchanged until the replacement is submitted.
create or replace function public.start_sales_tracking_correction(
 actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_review_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 c record;
 source public.sales_tracking_reports%rowtype;
 case_row public.sales_tracking_report_cases%rowtype;
 created public.sales_tracking_reports%rowtype;
 current_team_id uuid;
 current_team_name text;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||target_branch_id::text||':'||target_report_id::text||':sales_tracking_correction',0));
 select r.*into source from public.sales_tracking_reports r
 where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select x.*into strict case_row from public.sales_tracking_report_cases x where x.id=source.case_id for update;
 if case_row.authoritative_report_id<>source.id or source.state<>'submitted'or source.review_status<>'needs_review'
 then raise exception'sales tracking re-entry is not available'using errcode='55000';end if;
 if source.review_revision<>expected_review_revision then raise sqlstate'PT409'using message='sales tracking review changed';end if;
 if case_row.open_correction_report_id is not null then raise sqlstate'PT409'using message='sales tracking re-entry already open';end if;

 select team.id,coalesce(shift.name,c.actor_name||' Team')into current_team_id,current_team_name
 from public.branch_supervisor_teams team
 join public.branch_shifts shift on shift.id=team.shift_id and shift.branch_id=team.branch_id and shift.organization_id=team.organization_id
 where team.supervisor_user_id=actor_user_id and team.branch_id=c.branch_id and team.organization_id=c.organization_id
  and team.active and shift.active
 order by team.created_at,team.id limit 1;
 current_team_name:=coalesce(current_team_name,c.actor_name||' Team');

 insert into public.sales_tracking_reports(
  organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,
  branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,
  branch_revision,updated_by_user_id,currency_code,case_id,version_number,
  supersedes_report_id,correction_created_by_user_id,correction_created_at)
 values(
  source.organization_id,source.branch_id,actor_user_id,current_team_id,source.business_date,'draft',
  c.branch_name,c.actor_name,current_team_name,
  1,actor_user_id,source.currency_code,source.case_id,source.version_number+1,
  source.id,actor_user_id,pg_catalog.now())
 returning*into created;

 update public.sales_tracking_report_cases x set open_correction_report_id=created.id where x.id=case_row.id;
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,source.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking re-entry denied'using errcode='42501';end$$;

-- Re-entry periods follow the ordinary insert-once lifecycle. Existing saved
-- periods are never deleted or rebuilt.
create or replace function public.save_sales_tracking_correction(
 actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_revision bigint,
 entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 c record;
 s public.sales_tracking_reports%rowtype;
 case_row public.sales_tracking_report_cases%rowtype;
 p public.sales_tracking_period_entries%rowtype;
 v jsonb;
 provider_amounts jsonb;
 provider_total numeric;
 sales_row public.sales_tracking_sales_rows%rowtype;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||target_report_id::text||':sales_tracking_correction',0));
 select r.*into s from public.sales_tracking_reports r
 where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select x.*into strict case_row from public.sales_tracking_report_cases x where x.id=s.case_id for update;
 if case_row.open_correction_report_id<>s.id or s.state<>'draft'
 then raise exception'sales tracking re-entry is not open'using errcode='55000';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking re-entry changed';end if;
 if exists(select 1 from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period=save_sales_tracking_correction.entry_period)
 then raise sqlstate'PT409'using message='sales tracking re-entry period already saved';end if;

 perform private.validate_sales_tracking_sales_rows(sales_rows);
 perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,s.business_date);
 perform private.validate_sales_tracking_entry_dates(cash_rows,s.business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1
 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 select value into strict v from pg_catalog.jsonb_array_elements(sales_rows);
 provider_amounts:=coalesce(v->'online_amounts','[]'::jsonb);
 if pg_catalog.jsonb_typeof(provider_amounts)<>'array'then raise exception'invalid sales tracking online amounts'using errcode='22023';end if;
 if private.sales_tracking_numeric_field(v,'online_delivery')>0 and pg_catalog.jsonb_array_length(provider_amounts)=0
 then raise exception'online provider breakdown required'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)
  where pg_catalog.jsonb_typeof(a->'provider_id')<>'string'or(a->>'provider_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
 then raise exception'invalid sales tracking online provider'using errcode='22023';end if;
 if(select count(*)<>count(distinct a->>'provider_id')from pg_catalog.jsonb_array_elements(provider_amounts)e(a))
 then raise exception'duplicate sales tracking online provider'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)
  left join public.sales_tracking_online_order_providers provider
   on provider.id=(a->>'provider_id')::uuid and provider.organization_id=c.organization_id and provider.branch_id=c.branch_id and provider.active
  where provider.id is null)
 then raise exception'invalid sales tracking online provider scope'using errcode='22023';end if;
 select coalesce(sum(private.sales_tracking_numeric_field(a,'amount')),0)into provider_total
 from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 if provider_total<>private.sales_tracking_numeric_field(v,'online_delivery')
 then raise exception'sales tracking online provider total mismatch'using errcode='23514';end if;

 insert into public.sales_tracking_period_entries(report_id,entry_period,entered_by_user_id,entered_by_name_snapshot)
 values(s.id,entry_period,actor_user_id,c.actor_name)returning*into p;
 insert into public.sales_tracking_sales_rows(
  report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,refund_total,remarks)
 values(
  s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),
  private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),
  private.sales_tracking_numeric_field(v,'pos_credit'),provider_total,private.sales_tracking_refund_field(v),
  nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),''))returning*into sales_row;
 insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)
 select sales_row.id,(a->>'provider_id')::uuid,private.sales_tracking_numeric_field(a,'amount')
 from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 insert into public.sales_tracking_cash_rows(
  report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(x,'entry_date'),
  private.sales_tracking_integer_field(x,'denom_1'),private.sales_tracking_integer_field(x,'denom_2'),
  private.sales_tracking_integer_field(x,'denom_5'),private.sales_tracking_integer_field(x,'denom_10'),
  private.sales_tracking_integer_field(x,'denom_20'),private.sales_tracking_integer_field(x,'denom_50'),
  private.sales_tracking_integer_field(x,'denom_100'),private.sales_tracking_integer_field(x,'denom_200'),
  private.sales_tracking_integer_field(x,'denom_500'),private.sales_tracking_numeric_field(x,'remaining_cash'),
  nullif(pg_catalog.btrim(coalesce(x->>'remarks','')),'')
 from pg_catalog.jsonb_array_elements(cash_rows)e(x);
 update public.sales_tracking_reports r
 set branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id where r.id=s.id;
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,s.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking re-entry denied'using errcode='42501';end$$;

create or replace function public.submit_sales_tracking_correction(
 actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_revision bigint,
 idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 c record;
 s public.sales_tracking_reports%rowtype;
 source public.sales_tracking_reports%rowtype;
 case_row public.sales_tracking_report_cases%rowtype;
 prior public.sales_tracking_submission_idempotency%rowtype;
 period_count bigint;
 closing_count bigint;
 invalid_period_count bigint;
 incomplete_period_count bigint;
begin
 if request_hash!~'^[0-9a-f]{64}$'then raise exception'invalid sales tracking request hash'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into prior from public.sales_tracking_submission_idempotency x
 where x.actor_user_id=submit_sales_tracking_correction.actor_user_id and x.idempotency_key=submit_sales_tracking_correction.idempotency_key;
 if prior.actor_user_id is not null then
  if prior.request_hash<>request_hash or prior.report_id<>target_report_id
  then raise sqlstate'PT409'using message='sales tracking idempotency conflict';end if;
  return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,
   (select r.business_date from public.sales_tracking_reports r where r.id=target_report_id));
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||target_report_id::text||':sales_tracking_correction',0));
 select r.*into s from public.sales_tracking_reports r
 where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select x.*into strict case_row from public.sales_tracking_report_cases x where x.id=s.case_id for update;
 select r.*into strict source from public.sales_tracking_reports r where r.id=case_row.authoritative_report_id for update;
 if case_row.open_correction_report_id<>s.id or s.state<>'draft'or source.state<>'submitted'
  or source.review_status<>'needs_review'or s.supersedes_report_id<>source.id
 then raise exception'sales tracking re-entry is not open'using errcode='55000';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking re-entry changed';end if;
 select count(*),count(*)filter(where p.entry_period='closing_shift'),count(*)filter(where p.entry_period not in('middle_shift','closing_shift')),
  count(*)filter(where(select count(*)from public.sales_tracking_sales_rows sales where sales.report_id=s.id and sales.period_entry_id=p.id)<>1
   or(select count(*)from public.sales_tracking_cash_rows cash where cash.report_id=s.id and cash.period_entry_id=p.id)<>1)
 into period_count,closing_count,invalid_period_count,incomplete_period_count
 from public.sales_tracking_period_entries p where p.report_id=s.id;
 if period_count<1 or period_count>2 or closing_count<>1 or invalid_period_count<>0 or incomplete_period_count<>0
 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;

 update public.sales_tracking_reports r set state='superseded'where r.id=source.id;
 update public.sales_tracking_reports r set
  state='submitted',submitted_at=pg_catalog.now(),submitted_by_user_id=actor_user_id,
  submitted_by_name_snapshot=c.actor_name,branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id,
  review_status='reviewed',review_revision=source.review_revision+1,reviewed_at=pg_catalog.now(),reviewed_by_user_id=null
 where r.id=s.id;
 update public.sales_tracking_report_cases x
 set authoritative_report_id=s.id,open_correction_report_id=null where x.id=case_row.id;
 insert into public.sales_tracking_review_events(organization_id,branch_id,report_id,from_status,to_status,actor_user_id)
 values(s.organization_id,s.branch_id,s.id,'needs_review','reviewed',actor_user_id);
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)
 values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,s.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking re-entry denied'using errcode='42501';end$$;

-- Preserve the daily projection, but select reports only through the logical
-- case authority pointer.
create or replace function public.list_managed_sales_tracking_reports(
 actor_user_id uuid,target_organization_id uuid,from_date date default null,to_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
  or(from_date is not null and to_date is not null and from_date>to_date)
 then raise exception'sales tracking report access denied'using errcode='42501';end if;
 return pg_catalog.jsonb_build_object(
  'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,
   'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,
   'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,
   'submitted_by',coalesce(submitter.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,
   'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,
   'review_status',coalesce(r.review_status,'none'),'review_revision',coalesce(r.review_revision,0),
   'reviewed_at',r.reviewed_at,'reviewed_by_user_id',r.reviewed_by_user_id,'reviewed_by',reviewer.full_name,
   'actual_cash',x.actual_cash,'actual_credit',x.actual_credit,'pos_cash',x.pos_cash,'pos_credit',x.pos_credit,
   'online_delivery',x.online_delivery,'refund_total',x.refund_total,
   'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'provider_id',provider.id,'provider_key',provider.default_provider_key,'provider_name',provider.name,'amount',amount.amount)
    order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.created_at,provider.name,provider.id))
    from public.sales_tracking_online_amounts amount
    join public.sales_tracking_online_order_providers provider on provider.id=amount.provider_id
    where amount.sales_row_id=x.id and amount.amount<>0),'[]'::jsonb),
   'actual_total',x.actual_cash+x.actual_credit+x.online_delivery,'gross_sales',x.actual_cash+x.actual_credit+x.online_delivery,
   'net_sales',x.actual_cash+x.actual_credit+x.online_delivery-x.refund_total,
   'evidence_filename',(select attachment.original_filename from public.sales_tracking_attachments attachment
    where attachment.report_id=r.id and attachment.deleted_at is null order by attachment.display_order,attachment.created_at,attachment.id limit 1),
   'evidence_filenames',coalesce((select pg_catalog.jsonb_agg(attachment.original_filename order by attachment.display_order,attachment.created_at,attachment.id)
    from public.sales_tracking_attachments attachment where attachment.report_id=r.id and attachment.deleted_at is null),'[]'::jsonb),
   'evidence_count',(select pg_catalog.count(*)from public.sales_tracking_attachments attachment where attachment.report_id=r.id and attachment.deleted_at is null),
   'evidence_available',exists(select 1 from public.sales_tracking_attachments attachment where attachment.report_id=r.id and attachment.deleted_at is null),
   'pos_total',x.pos_cash+x.pos_credit+x.online_delivery,'variance',(x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit),'remarks',x.remarks)
   order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)
   from public.sales_tracking_report_cases case_row
   join public.sales_tracking_reports r on r.id=case_row.authoritative_report_id and r.case_id=case_row.id
   join public.sales_tracking_sales_rows x on x.report_id=r.id
   left join public.sales_tracking_period_entries p on p.id=x.period_entry_id
   left join public.profiles submitter on submitter.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)
   left join public.profiles reviewer on reviewer.id=r.reviewed_by_user_id
   where case_row.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null
    and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb),
  'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,
   'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,
   'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,
   'submitted_by',coalesce(submitter.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,
   'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,
   'review_status',coalesce(r.review_status,'none'),'review_revision',coalesce(r.review_revision,0),
   'reviewed_at',r.reviewed_at,'reviewed_by_user_id',r.reviewed_by_user_id,'reviewed_by',reviewer.full_name,
   'denom_1',x.denom_1,'denom_2',x.denom_2,'denom_5',x.denom_5,'denom_10',x.denom_10,
   'denom_20',x.denom_20,'denom_50',x.denom_50,'denom_100',x.denom_100,'denom_200',x.denom_200,'denom_500',x.denom_500,
   'cash_total',x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500,
   'remaining_cash',x.remaining_cash,'remarks',x.remarks)
   order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)
   from public.sales_tracking_report_cases case_row
   join public.sales_tracking_reports r on r.id=case_row.authoritative_report_id and r.case_id=case_row.id
   join public.sales_tracking_cash_rows x on x.report_id=r.id
   left join public.sales_tracking_period_entries p on p.id=x.period_entry_id
   left join public.profiles submitter on submitter.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)
   left join public.profiles reviewer on reviewer.id=r.reviewed_by_user_id
   where case_row.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null
    and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb));
end$$;

create or replace function public.get_managed_sales_tracking_attachments(
 actor_user_id uuid,target_organization_id uuid,target_report_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare report_id uuid;
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
 then raise exception'sales tracking attachment access denied'using errcode='42501';end if;
 select report.id into report_id
 from public.sales_tracking_report_cases case_row
 join public.sales_tracking_reports report on report.id=case_row.authoritative_report_id and report.case_id=case_row.id
 where report.id=target_report_id and case_row.organization_id=target_organization_id
  and report.state='submitted'and report.submitted_at is not null;
 if report_id is null then raise exception'sales tracking report not found'using errcode='P0002';end if;
 return pg_catalog.jsonb_build_object('report_id',report_id,'attachments',private.sales_tracking_attachments_json(report_id));
end$$;

-- Monthly totals are recomputed directly from authoritative case pointers.
create or replace function public.get_managed_sales_tracking_monthly_summary(
 actor_user_id uuid,target_organization_id uuid,target_month date,branch_filter uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if target_month is null or target_month<>pg_catalog.date_trunc('month',target_month)::date
 then raise exception'invalid sales tracking month'using errcode='22023';end if;
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
 then raise exception'sales tracking monthly summary access denied'using errcode='42501';end if;
 if branch_filter is not null and not exists(select 1 from public.branches branch where branch.id=branch_filter and branch.organization_id=target_organization_id)
 then raise exception'sales tracking monthly summary branch denied'using errcode='42501';end if;
 with scoped_reports as materialized(
  select report.id,report.branch_id,report.business_date,report.currency_code,
   branch.name branch_name,branch.name_ar branch_name_ar,branch.code branch_code
  from public.sales_tracking_report_cases case_row
  join public.sales_tracking_reports report on report.id=case_row.authoritative_report_id and report.case_id=case_row.id
  join public.branches branch on branch.id=report.branch_id and branch.organization_id=report.organization_id
  where case_row.organization_id=target_organization_id and report.state='submitted'and report.submitted_at is not null
   and report.business_date>=target_month and report.business_date<(target_month+interval'1 month')::date
   and(branch_filter is null or report.branch_id=branch_filter)
 ),metrics as materialized(
  select report.*,
   (select pg_catalog.count(*)from public.sales_tracking_sales_rows row where row.report_id=report.id)::bigint sales_entry_count,
   (select pg_catalog.count(*)from public.sales_tracking_cash_rows row where row.report_id=report.id)::bigint cash_entry_count,
   (select pg_catalog.count(*)from public.sales_tracking_attachments a where a.report_id=report.id and a.deleted_at is null)::bigint evidence_photo_count,
   coalesce((select pg_catalog.sum(row.actual_cash)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)actual_cash,
   coalesce((select pg_catalog.sum(row.actual_credit)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)actual_credit,
   coalesce((select pg_catalog.sum(row.online_delivery)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)online_delivery,
   coalesce((select pg_catalog.sum(row.pos_cash)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)pos_cash,
   coalesce((select pg_catalog.sum(row.pos_credit)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)pos_credit,
   coalesce((select pg_catalog.sum(row.actual_cash+row.actual_credit+row.online_delivery)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)total_sales,
   coalesce((select pg_catalog.sum(row.refund_total)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)refund_total,
   coalesce((select pg_catalog.sum(row.actual_cash+row.actual_credit+row.online_delivery-row.refund_total)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)net_sales,
   coalesce((select pg_catalog.sum((row.actual_cash+row.actual_credit)-(row.pos_cash+row.pos_credit))from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)total_variance,
   coalesce((select pg_catalog.sum(row.denom_1+row.denom_2*2+row.denom_5*5+row.denom_10*10+row.denom_20*20+row.denom_50*50+row.denom_100*100+row.denom_200*200+row.denom_500*500)from public.sales_tracking_cash_rows row where row.report_id=report.id),0::numeric)total_cash_collected
  from scoped_reports report
 ),provider_amounts as materialized(
  select report.currency_code,report.branch_id,provider.default_provider_key,provider.normalized_name,
   min(provider.name)provider_name,bool_or(provider.is_default)is_default,min(provider.created_at)first_created_at,
   min(provider.id::text)::uuid first_provider_id,pg_catalog.sum(amount.amount)amount
  from scoped_reports report
  join public.sales_tracking_sales_rows row on row.report_id=report.id
  join public.sales_tracking_online_amounts amount on amount.sales_row_id=row.id and amount.amount<>0
  join public.sales_tracking_online_order_providers provider on provider.id=amount.provider_id
  group by report.currency_code,report.branch_id,provider.default_provider_key,provider.normalized_name
 ),provider_totals as materialized(
  select currency_code,default_provider_key,normalized_name,min(provider_name)provider_name,bool_or(is_default)is_default,
   min(first_created_at)first_created_at,min(first_provider_id::text)::uuid first_provider_id,pg_catalog.sum(amount)amount
  from provider_amounts group by currency_code,default_provider_key,normalized_name
 ),legacy_online as materialized(
  select report.currency_code,report.branch_id,coalesce(pg_catalog.sum(row.online_delivery),0::numeric)amount
  from scoped_reports report join public.sales_tracking_sales_rows row on row.report_id=report.id
  where not exists(select 1 from public.sales_tracking_online_amounts amount where amount.sales_row_id=row.id)
  group by report.currency_code,report.branch_id
 ),currency_totals as materialized(
  select currency_code,pg_catalog.count(*)::bigint submitted_report_count,
   pg_catalog.count(distinct(branch_id,business_date))::bigint submitted_branch_day_count,
   pg_catalog.count(distinct branch_id)::bigint reporting_branch_count,
   coalesce(pg_catalog.sum(sales_entry_count),0)::bigint sales_entry_count,
   coalesce(pg_catalog.sum(cash_entry_count),0)::bigint cash_entry_count,
   coalesce(pg_catalog.sum(evidence_photo_count),0)::bigint evidence_photo_count,
   coalesce(pg_catalog.sum(total_sales),0::numeric)total_sales,coalesce(pg_catalog.sum(refund_total),0::numeric)refund_total,
   coalesce(pg_catalog.sum(net_sales),0::numeric)net_sales,coalesce(pg_catalog.sum(total_cash_collected),0::numeric)total_cash_collected,
   coalesce(pg_catalog.sum(total_variance),0::numeric)total_variance,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)=0)::bigint balanced_sales_report_count,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)<>0)::bigint variance_sales_report_count,
   coalesce(pg_catalog.sum(actual_cash),0::numeric)actual_cash,coalesce(pg_catalog.sum(actual_credit),0::numeric)actual_credit,
   coalesce(pg_catalog.sum(online_delivery),0::numeric)online_delivery,coalesce(pg_catalog.sum(pos_cash),0::numeric)pos_cash,
   coalesce(pg_catalog.sum(pos_credit),0::numeric)pos_credit
  from metrics group by currency_code
 ),branch_totals as materialized(
  select branch_id,branch_name,branch_name_ar,branch_code,currency_code,pg_catalog.count(*)::bigint submitted_report_count,
   pg_catalog.count(distinct business_date)::bigint submitted_day_count,
   coalesce(pg_catalog.sum(sales_entry_count),0)::bigint sales_entry_count,
   coalesce(pg_catalog.sum(cash_entry_count),0)::bigint cash_entry_count,
   coalesce(pg_catalog.sum(evidence_photo_count),0)::bigint evidence_photo_count,
   coalesce(pg_catalog.sum(total_sales),0::numeric)total_sales,coalesce(pg_catalog.sum(refund_total),0::numeric)refund_total,
   coalesce(pg_catalog.sum(net_sales),0::numeric)net_sales,coalesce(pg_catalog.sum(total_cash_collected),0::numeric)total_cash_collected,
   coalesce(pg_catalog.sum(total_variance),0::numeric)total_variance,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)=0)::bigint balanced_sales_report_count,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)<>0)::bigint variance_sales_report_count,
   coalesce(pg_catalog.sum(actual_cash),0::numeric)actual_cash,coalesce(pg_catalog.sum(actual_credit),0::numeric)actual_credit,
   coalesce(pg_catalog.sum(online_delivery),0::numeric)online_delivery,coalesce(pg_catalog.sum(pos_cash),0::numeric)pos_cash,
   coalesce(pg_catalog.sum(pos_credit),0::numeric)pos_credit
  from metrics group by branch_id,branch_name,branch_name_ar,branch_code,currency_code
 )
 select pg_catalog.jsonb_build_object(
  'generated_at',pg_catalog.statement_timestamp(),
  'scope',pg_catalog.jsonb_build_object('organization_id',target_organization_id,'branch_id',branch_filter,'month',pg_catalog.to_char(target_month,'YYYY-MM'),'date_from',target_month,'date_to',(target_month+interval'1 month - 1 day')::date),
  'currency_totals',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'currency_code',total.currency_code,'submitted_report_count',total.submitted_report_count,
   'submitted_branch_day_count',total.submitted_branch_day_count,'reporting_branch_count',total.reporting_branch_count,
   'sales_entry_count',total.sales_entry_count,'cash_entry_count',total.cash_entry_count,'evidence_photo_count',total.evidence_photo_count,
   'total_sales',total.total_sales::text,'gross_sales',total.total_sales::text,'refund_total',total.refund_total::text,
   'net_sales',total.net_sales::text,'total_cash_collected',total.total_cash_collected::text,'total_variance',total.total_variance::text,
   'balanced_sales_report_count',total.balanced_sales_report_count,'variance_sales_report_count',total.variance_sales_report_count,
   'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash',total.actual_cash::text,'actual_credit',total.actual_credit::text,'online_delivery',total.online_delivery::text,'pos_cash',total.pos_cash::text,'pos_credit',total.pos_credit::text),
   'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.first_provider_id,'provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text)
    order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id))from provider_totals provider where provider.currency_code=total.currency_code),'[]'::jsonb),
   'legacy_online_delivery',coalesce((select pg_catalog.sum(legacy.amount)::text from legacy_online legacy where legacy.currency_code=total.currency_code),'0'))
   order by total.currency_code)from currency_totals total),'[]'::jsonb),
  'branches',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'branch_id',branch.branch_id,'branch_name',branch.branch_name,'branch_name_ar',branch.branch_name_ar,
   'branch_code',branch.branch_code,'currency_code',branch.currency_code,'submitted_report_count',branch.submitted_report_count,
   'submitted_day_count',branch.submitted_day_count,'sales_entry_count',branch.sales_entry_count,
   'cash_entry_count',branch.cash_entry_count,'evidence_photo_count',branch.evidence_photo_count,
   'total_sales',branch.total_sales::text,'gross_sales',branch.total_sales::text,'refund_total',branch.refund_total::text,
   'net_sales',branch.net_sales::text,'total_cash_collected',branch.total_cash_collected::text,'total_variance',branch.total_variance::text,
   'balanced_sales_report_count',branch.balanced_sales_report_count,'variance_sales_report_count',branch.variance_sales_report_count,
   'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash',branch.actual_cash::text,'actual_credit',branch.actual_credit::text,'online_delivery',branch.online_delivery::text,'pos_cash',branch.pos_cash::text,'pos_credit',branch.pos_credit::text),
   'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.first_provider_id,'provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text)
    order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id))from provider_amounts provider where provider.currency_code=branch.currency_code and provider.branch_id=branch.branch_id),'[]'::jsonb),
   'legacy_online_delivery',coalesce((select legacy.amount::text from legacy_online legacy where legacy.currency_code=branch.currency_code and legacy.branch_id=branch.branch_id),'0'))
   order by branch.branch_name,branch.currency_code,branch.branch_id)from branch_totals branch),'[]'::jsonb)
 )into result;
 if pg_catalog.jsonb_array_length(result->'currency_totals')<=1 then
  result:=result||pg_catalog.jsonb_build_object('totals',coalesce(result->'currency_totals'->0,pg_catalog.jsonb_build_object(
   'submitted_report_count',0,'submitted_branch_day_count',0,'reporting_branch_count',0,
   'sales_entry_count',0,'cash_entry_count',0,'evidence_photo_count',0,
   'total_sales','0','gross_sales','0','refund_total','0','net_sales','0','total_cash_collected','0','total_variance','0',
   'balanced_sales_report_count',0,'variance_sales_report_count',0,
   'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash','0','actual_credit','0','online_delivery','0','pos_cash','0','pos_credit','0'),
   'online_provider_breakdown','[]'::jsonb,'legacy_online_delivery','0')));
 end if;
 return result;
end$$;

revoke all on function
 public.start_sales_tracking_correction(uuid,uuid,uuid,bigint),
 public.save_sales_tracking_correction(uuid,uuid,uuid,bigint,text,jsonb,jsonb),
 public.submit_sales_tracking_correction(uuid,uuid,uuid,bigint,uuid,text),
 public.list_managed_sales_tracking_reports(uuid,uuid,date,date),
 public.get_managed_sales_tracking_attachments(uuid,uuid,uuid),
 public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)
from public,anon,authenticated;
grant execute on function
 public.start_sales_tracking_correction(uuid,uuid,uuid,bigint),
 public.save_sales_tracking_correction(uuid,uuid,uuid,bigint,text,jsonb,jsonb),
 public.submit_sales_tracking_correction(uuid,uuid,uuid,bigint,uuid,text),
 public.list_managed_sales_tracking_reports(uuid,uuid,date,date),
 public.get_managed_sales_tracking_attachments(uuid,uuid,uuid),
 public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)
to service_role;

commit;
