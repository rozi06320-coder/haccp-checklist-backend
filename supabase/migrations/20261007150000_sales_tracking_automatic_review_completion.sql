begin;

-- Automatic correction completion has no human reviewer. Historical rows that
-- were manually marked Reviewed remain valid with their existing attribution.
alter table public.sales_tracking_reports
  drop constraint sales_tracking_reports_review_actor_check;
alter table public.sales_tracking_reports
  add constraint sales_tracking_reports_review_actor_check check(
    (review_status='none'and reviewed_at is null and reviewed_by_user_id is null)
    or(review_status='needs_review'and reviewed_at is not null and reviewed_by_user_id is not null)
    or(review_status='reviewed'and reviewed_at is not null)
  );

create or replace function public.set_managed_sales_tracking_review_status(
  actor_user_id uuid,
  target_organization_id uuid,
  target_report_id uuid,
  expected_review_revision bigint,
  target_review_status text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare report public.sales_tracking_reports%rowtype;case_row public.sales_tracking_report_cases%rowtype;actor_name text;
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)then raise exception'sales tracking review access denied'using errcode='42501';end if;
 if target_review_status<>'needs_review'then raise exception'invalid sales tracking review status'using errcode='22023';end if;
 select r.*into report from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=target_organization_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select c.*into strict case_row from public.sales_tracking_report_cases c where c.id=report.case_id for update;
 if case_row.authoritative_report_id<>report.id or report.state<>'submitted'then raise exception'sales tracking report is not authoritative'using errcode='55000';end if;
 if case_row.open_correction_report_id is not null then raise sqlstate'PT409'using message='sales tracking correction is open';end if;
 if report.review_revision<>expected_review_revision then raise sqlstate'PT409'using message='sales tracking review changed';end if;
 if report.review_status not in('none','reviewed')then raise exception'sales tracking review status is unchanged'using errcode='22023';end if;
 update public.sales_tracking_reports r set review_status=target_review_status,review_revision=r.review_revision+1,reviewed_at=pg_catalog.now(),reviewed_by_user_id=actor_user_id where r.id=report.id;
 insert into public.sales_tracking_review_events(organization_id,branch_id,report_id,from_status,to_status,actor_user_id)values(report.organization_id,report.branch_id,report.id,report.review_status,target_review_status,actor_user_id);
 select p.full_name into actor_name from public.profiles p where p.id=actor_user_id;
 return pg_catalog.jsonb_build_object('report_id',report.id,'review_status',target_review_status,'review_revision',report.review_revision+1,'reviewed_at',(select r.reviewed_at from public.sales_tracking_reports r where r.id=report.id),'reviewed_by_user_id',actor_user_id,'reviewed_by',actor_name);
end$$;

create or replace function public.submit_sales_tracking_correction(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;source public.sales_tracking_reports%rowtype;case_row public.sales_tracking_report_cases%rowtype;prior public.sales_tracking_submission_idempotency%rowtype;
begin
 if request_hash!~'^[0-9a-f]{64}$'then raise exception'invalid sales tracking request hash'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into prior from public.sales_tracking_submission_idempotency x where x.actor_user_id=submit_sales_tracking_correction.actor_user_id and x.idempotency_key=submit_sales_tracking_correction.idempotency_key;
 if prior.actor_user_id is not null then if prior.request_hash<>request_hash or prior.report_id<>target_report_id then raise sqlstate'PT409'using message='sales tracking idempotency conflict';end if;return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,(select r.business_date from public.sales_tracking_reports r where r.id=target_report_id));end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||target_report_id::text||':sales_tracking_correction',0));
 select r.*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select x.*into strict case_row from public.sales_tracking_report_cases x where x.id=s.case_id for update;
 select r.*into strict source from public.sales_tracking_reports r where r.id=case_row.authoritative_report_id for update;
 if case_row.open_correction_report_id<>s.id or s.state<>'draft'or source.review_status<>'needs_review'then raise exception'sales tracking correction is not open'using errcode='55000';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking correction changed';end if;
 if not exists(select 1 from public.sales_tracking_period_entries p where p.report_id=s.id and p.entry_period='closing_shift')then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports r set state='superseded'where r.id=source.id;
 update public.sales_tracking_reports r set state='submitted',submitted_at=pg_catalog.now(),submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name,branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id,review_status='reviewed',review_revision=source.review_revision+1,reviewed_at=pg_catalog.now(),reviewed_by_user_id=null where r.id=s.id;
 update public.sales_tracking_report_cases x set authoritative_report_id=s.id,open_correction_report_id=null where x.id=case_row.id;
 insert into public.sales_tracking_review_events(organization_id,branch_id,report_id,from_status,to_status,actor_user_id)values(s.organization_id,s.branch_id,s.id,'needs_review','reviewed',actor_user_id);
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,s.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking correction denied'using errcode='42501';end$$;

revoke all on function public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text),public.submit_sales_tracking_correction(uuid,uuid,uuid,bigint,uuid,text)from public,anon,authenticated;
grant execute on function public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text),public.submit_sales_tracking_correction(uuid,uuid,uuid,bigint,uuid,text)to service_role;

commit;
