begin;

-- A case owns the branch/day identity. Reports are immutable versions inside it.
create table public.sales_tracking_report_cases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  business_date date not null,
  authoritative_report_id uuid,
  open_correction_report_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_tracking_report_cases_branch_scope_fkey
    foreign key(branch_id,organization_id) references public.branches(id,organization_id) on delete restrict,
  constraint sales_tracking_report_cases_branch_day_key unique(organization_id,branch_id,business_date)
);

alter table public.sales_tracking_reports
  add column case_id uuid,
  add column version_number bigint,
  add column supersedes_report_id uuid references public.sales_tracking_reports(id) on delete restrict,
  add column correction_created_by_user_id uuid references public.profiles(id) on delete restrict,
  add column correction_created_at timestamptz;

-- The old branch/day identity must still be intact while existing reports are
-- mapped one-to-one onto cases. Abort rather than infer through dirty data.
do $$
begin
 if pg_catalog.to_regclass('public.sales_tracking_reports_branch_day_key') is null then
  raise exception'expected sales tracking branch/day uniqueness is missing'using errcode='55000';
 end if;
 if exists(select 1 from public.sales_tracking_reports r group by r.organization_id,r.branch_id,r.business_date having count(*)<>1)then
  raise exception'duplicate sales tracking branch/day reports block version backfill'using errcode='55000';
 end if;
 if exists(select 1 from public.sales_tracking_reports r where r.state not in('draft','submitted'))then
  raise exception'unexpected sales tracking state blocks version backfill'using errcode='55000';
 end if;
 if exists(select 1 from public.sales_tracking_reports r where r.case_id is not null or r.version_number is not null or r.supersedes_report_id is not null or r.correction_created_by_user_id is not null or r.correction_created_at is not null)then
  raise exception'sales tracking version metadata is already populated'using errcode='55000';
 end if;
 if not exists(select 1 from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public'and c.relname='sales_tracking_reports'and t.tgname='sales_tracking_reports_submitted_immutable'and not t.tgisinternal and t.tgenabled<>'D')then
  raise exception'sales tracking submitted immutability trigger is not enabled'using errcode='55000';
 end if;
end$$;

insert into public.sales_tracking_report_cases(organization_id,branch_id,business_date)
select distinct r.organization_id,r.branch_id,r.business_date from public.sales_tracking_reports r;

do $$
begin
 if exists(select 1 from public.sales_tracking_report_cases c group by c.organization_id,c.branch_id,c.business_date having count(*)<>1)then
  raise exception'duplicate sales tracking cases block version backfill'using errcode='55000';
 end if;
 if(select count(*)from public.sales_tracking_report_cases)<>(select count(*)from public.sales_tracking_reports)then
  raise exception'sales tracking case/report cardinality mismatch'using errcode='55000';
 end if;
 if exists(select 1 from public.sales_tracking_reports r where(select count(*)from public.sales_tracking_report_cases c where c.organization_id=r.organization_id and c.branch_id=r.branch_id and c.business_date=r.business_date)<>1)then
  raise exception'sales tracking report does not map to exactly one case'using errcode='55000';
 end if;
end$$;

create temporary table sales_tracking_report_version_backfill_guard on commit drop as
select r.id,r.state,pg_catalog.to_jsonb(r)-array['case_id','version_number','supersedes_report_id','correction_created_by_user_id','correction_created_at']::text[] as preserved_row
from public.sales_tracking_reports r;

-- This is the sole trigger suspension in the migration. It brackets only the
-- version-identity metadata backfill; all financial and child triggers remain enabled.
alter table public.sales_tracking_reports disable trigger sales_tracking_reports_submitted_immutable;
update public.sales_tracking_reports r
set case_id=c.id,version_number=1
from public.sales_tracking_report_cases c
where c.organization_id=r.organization_id and c.branch_id=r.branch_id and c.business_date=r.business_date;
alter table public.sales_tracking_reports enable trigger sales_tracking_reports_submitted_immutable;

do $$
begin
 if not exists(select 1 from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public'and c.relname='sales_tracking_reports'and t.tgname='sales_tracking_reports_submitted_immutable'and not t.tgisinternal and t.tgenabled<>'D')then
  raise exception'sales tracking submitted immutability trigger was not restored'using errcode='55000';
 end if;
 if exists(select 1 from public.sales_tracking_reports r where r.case_id is null or r.version_number<>1 or r.supersedes_report_id is not null or r.correction_created_by_user_id is not null or r.correction_created_at is not null)then
  raise exception'invalid sales tracking version metadata backfill'using errcode='55000';
 end if;
 if exists(select 1 from public.sales_tracking_reports r join sales_tracking_report_version_backfill_guard g on g.id=r.id where r.state<>g.state or(pg_catalog.to_jsonb(r)-array['case_id','version_number','supersedes_report_id','correction_created_by_user_id','correction_created_at']::text[])is distinct from g.preserved_row)then
  raise exception'sales tracking backfill changed protected report data'using errcode='55000';
 end if;
 if(select count(*)from sales_tracking_report_version_backfill_guard)<>(select count(*)from public.sales_tracking_reports)then
  raise exception'sales tracking report count changed during version backfill'using errcode='55000';
 end if;
end$$;

update public.sales_tracking_report_cases c
set authoritative_report_id=r.id
from public.sales_tracking_reports r
where r.case_id=c.id and r.state='submitted';

do $$
begin
 if exists(
  select 1 from public.sales_tracking_report_cases c
  where not(
   (c.authoritative_report_id is not null and c.open_correction_report_id is null and exists(select 1 from public.sales_tracking_reports r where r.id=c.authoritative_report_id and r.case_id=c.id and r.state='submitted'and r.version_number=1))
   or(c.authoritative_report_id is null and c.open_correction_report_id is null and(select count(*)from public.sales_tracking_reports r where r.case_id=c.id and r.state='draft'and r.version_number=1)=1)
  )
 )then raise exception'invalid sales tracking case authority backfill'using errcode='55000';end if;
end$$;

alter table public.sales_tracking_reports
  alter column case_id set not null,
  alter column version_number set not null,
  add constraint sales_tracking_reports_case_fkey foreign key(case_id) references public.sales_tracking_report_cases(id) on delete restrict,
  add constraint sales_tracking_reports_case_version_key unique(case_id,version_number),
  add constraint sales_tracking_reports_version_positive_check check(version_number>0),
  add constraint sales_tracking_reports_correction_provenance_check check(
    (version_number=1 and supersedes_report_id is null and correction_created_by_user_id is null and correction_created_at is null)
    or (version_number>1 and supersedes_report_id is not null and correction_created_by_user_id is not null and correction_created_at is not null)
  );

alter table public.sales_tracking_report_cases
  add constraint sales_tracking_report_cases_authoritative_fkey foreign key(authoritative_report_id) references public.sales_tracking_reports(id) on delete restrict,
  add constraint sales_tracking_report_cases_open_correction_fkey foreign key(open_correction_report_id) references public.sales_tracking_reports(id) on delete restrict;

drop index if exists public.sales_tracking_reports_branch_day_key;
alter table public.sales_tracking_reports drop constraint if exists sales_tracking_reports_branch_id_supervisor_user_id_business_date_key;
alter table public.sales_tracking_reports drop constraint sales_tracking_reports_state_check;
alter table public.sales_tracking_reports add constraint sales_tracking_reports_state_check check(state in('draft','submitted','superseded'));

create index sales_tracking_reports_case_state_idx on public.sales_tracking_reports(case_id,state,version_number desc);
create unique index sales_tracking_reports_one_draft_per_case_uidx on public.sales_tracking_reports(case_id) where state='draft';
create index sales_tracking_report_cases_authoritative_idx on public.sales_tracking_report_cases(authoritative_report_id);
create index sales_tracking_report_cases_open_idx on public.sales_tracking_report_cases(open_correction_report_id) where open_correction_report_id is not null;
create trigger sales_tracking_report_cases_set_updated_at before update on public.sales_tracking_report_cases
for each row execute function private.set_updated_at();
alter table public.sales_tracking_report_cases enable row level security;
revoke all on public.sales_tracking_report_cases from public,anon,authenticated,service_role;

-- Preserve the existing normal draft/submit RPC signatures. New first versions are
-- attached to their case automatically; correction RPCs supply their version fields.
create function private.prepare_sales_tracking_report_version()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_case_id uuid;
begin
 if new.case_id is not null then return new;end if;
 insert into public.sales_tracking_report_cases(organization_id,branch_id,business_date)
 values(new.organization_id,new.branch_id,new.business_date)
 on conflict(organization_id,branch_id,business_date)do update set business_date=excluded.business_date
 returning id into target_case_id;
 new.case_id:=target_case_id;new.version_number:=1;return new;
end$$;
revoke all on function private.prepare_sales_tracking_report_version()from public,anon,authenticated,service_role;
create trigger sales_tracking_reports_prepare_version before insert on public.sales_tracking_reports
for each row execute function private.prepare_sales_tracking_report_version();

create function private.sync_sales_tracking_case_authority()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.state='submitted'and old.state='draft'and new.version_number=1 then
  update public.sales_tracking_report_cases c set authoritative_report_id=new.id where c.id=new.case_id and c.open_correction_report_id is null;
 end if;return new;
end$$;
revoke all on function private.sync_sales_tracking_case_authority()from public,anon,authenticated,service_role;
create trigger sales_tracking_reports_sync_case_authority after update of state on public.sales_tracking_reports
for each row execute function private.sync_sales_tracking_case_authority();

-- Submitted financial content stays immutable. The sole lifecycle transition is the
-- authoritative pointer swap's submitted -> superseded metadata-only transition.
create or replace function private.prevent_submitted_sales_tracking_report_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.state='submitted' then
  if tg_op='UPDATE'
   and new.state='superseded'
   and (pg_catalog.to_jsonb(new)-array['state','updated_at']::text[])=(pg_catalog.to_jsonb(old)-array['state','updated_at']::text[])
  then return new;end if;
  if tg_op='UPDATE'
   and (pg_catalog.to_jsonb(new)-array['review_status','review_revision','reviewed_at','reviewed_by_user_id','updated_at']::text[])=(pg_catalog.to_jsonb(old)-array['review_status','review_revision','reviewed_at','reviewed_by_user_id','updated_at']::text[])
   and new.review_status is distinct from old.review_status and new.review_revision=old.review_revision+1
   and new.review_status in('needs_review','reviewed') and new.reviewed_at is not null and new.reviewed_by_user_id is not null
  then return new;end if;
  raise exception'submitted sales tracking report is immutable'using errcode='55000';
 end if;
 if old.state='superseded'then raise exception'superseded sales tracking report is immutable'using errcode='55000';end if;
 if tg_op='DELETE'then return old;end if;return new;
end$$;

-- Copied correction rows are editable only while their version is the case's open draft.
create or replace function private.sales_tracking_open_correction(target_report_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.sales_tracking_report_cases c join public.sales_tracking_reports r on r.id=c.open_correction_report_id
 where r.id=target_report_id and r.state='draft' and r.version_number>1)
$$;
revoke all on function private.sales_tracking_open_correction(uuid) from public,anon,authenticated,service_role;

create or replace function private.prevent_sales_tracking_period_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if private.sales_tracking_open_correction(old.report_id)then if tg_op='DELETE'then return old;end if;return new;end if;
 raise exception'saved sales tracking period is immutable'using errcode='55000';
end$$;

create or replace function private.prevent_sales_tracking_child_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if private.sales_tracking_open_correction(old.report_id)then if tg_op='DELETE'then return old;end if;return new;end if;
 if old.period_entry_id is not null or exists(select 1 from public.sales_tracking_reports r where r.id=old.report_id and r.state in('submitted','superseded'))
 then raise exception'saved sales tracking data is immutable'using errcode='55000';end if;
 if tg_op='DELETE'then return old;end if;return new;
end$$;

create or replace function private.prevent_sales_tracking_online_amount_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_sales_row uuid:=coalesce(old.sales_row_id,new.sales_row_id);target_report_id uuid;
begin
 select r.report_id into target_report_id from public.sales_tracking_sales_rows r where r.id=target_sales_row;
 if private.sales_tracking_open_correction(target_report_id)then if tg_op='DELETE'then return old;end if;return new;end if;
 if exists(select 1 from public.sales_tracking_sales_rows r join public.sales_tracking_reports report on report.id=r.report_id where r.id=target_sales_row and(r.period_entry_id is not null or report.state in('submitted','superseded')))
 then raise exception'saved sales tracking online provider data is immutable'using errcode='55000';end if;
 if tg_op='DELETE'then return old;end if;return new;
end$$;

create or replace function private.require_open_sales_tracking_report()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.sales_tracking_reports r where r.id=new.report_id and r.state in('submitted','superseded'))
 then raise exception'submitted sales tracking report is immutable'using errcode='55000';end if;return new;
end$$;

create function public.start_sales_tracking_correction(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_review_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;source public.sales_tracking_reports%rowtype;case_row public.sales_tracking_report_cases%rowtype;created public.sales_tracking_reports%rowtype;old_period record;new_period_id uuid;old_sales_id uuid;new_sales_id uuid;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||target_branch_id::text||':'||target_report_id::text||':sales_tracking_correction',0));
 select r.* into source from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select x.* into strict case_row from public.sales_tracking_report_cases x where x.id=source.case_id for update;
 if case_row.authoritative_report_id<>source.id or source.state<>'submitted'or source.review_status<>'needs_review'then raise exception'sales tracking correction is not available'using errcode='55000';end if;
 if source.review_revision<>expected_review_revision then raise sqlstate'PT409'using message='sales tracking review changed';end if;
 if case_row.open_correction_report_id is not null then raise sqlstate'PT409'using message='sales tracking correction already open';end if;
 insert into public.sales_tracking_reports(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,branch_revision,updated_by_user_id,currency_code,case_id,version_number,supersedes_report_id,correction_created_by_user_id,correction_created_at)
 values(source.organization_id,source.branch_id,actor_user_id,c.legacy_team_id,source.business_date,'draft',source.branch_name_snapshot,c.actor_name,source.supervisor_team_name_snapshot,1,actor_user_id,source.currency_code,source.case_id,source.version_number+1,source.id,actor_user_id,pg_catalog.now())returning*into created;
 update public.sales_tracking_report_cases x set open_correction_report_id=created.id where x.id=case_row.id;
 for old_period in select p.* from public.sales_tracking_period_entries p where p.report_id=source.id order by p.entered_at,p.id loop
  insert into public.sales_tracking_period_entries(report_id,entry_period,entered_by_user_id,entered_by_name_snapshot,entered_at)
  values(created.id,old_period.entry_period,actor_user_id,c.actor_name,pg_catalog.now())returning id into new_period_id;
  select s.id into old_sales_id from public.sales_tracking_sales_rows s where s.report_id=source.id and s.period_entry_id=old_period.id;
  insert into public.sales_tracking_sales_rows(report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,refund_total,remarks)
  select created.id,new_period_id,s.entry_date,s.actual_cash,s.actual_credit,s.pos_cash,s.pos_credit,s.online_delivery,s.refund_total,s.remarks from public.sales_tracking_sales_rows s where s.id=old_sales_id returning id into new_sales_id;
  insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)
  select new_sales_id,a.provider_id,a.amount from public.sales_tracking_online_amounts a where a.sales_row_id=old_sales_id;
  insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
  select created.id,new_period_id,x.entry_date,x.denom_1,x.denom_2,x.denom_5,x.denom_10,x.denom_20,x.denom_50,x.denom_100,x.denom_200,x.denom_500,x.remaining_cash,x.remarks from public.sales_tracking_cash_rows x where x.report_id=source.id and x.period_entry_id=old_period.id;
 end loop;
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,source.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking correction denied'using errcode='42501';end$$;

create function public.save_sales_tracking_correction(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;case_row public.sales_tracking_report_cases%rowtype;p public.sales_tracking_period_entries%rowtype;v jsonb;provider_amounts jsonb;provider_total numeric;sales_row public.sales_tracking_sales_rows%rowtype;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,(select r.business_date from public.sales_tracking_reports r where r.id=target_report_id));perform private.validate_sales_tracking_entry_dates(cash_rows,(select r.business_date from public.sales_tracking_reports r where r.id=target_report_id));
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 select value into strict v from pg_catalog.jsonb_array_elements(sales_rows);provider_amounts:=coalesce(v->'online_amounts','[]'::jsonb);
 if pg_catalog.jsonb_typeof(provider_amounts)<>'array'then raise exception'invalid sales tracking online amounts'using errcode='22023';end if;
 if private.sales_tracking_numeric_field(v,'online_delivery')>0 and pg_catalog.jsonb_array_length(provider_amounts)=0 then raise exception'online provider breakdown required'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)where pg_catalog.jsonb_typeof(a->'provider_id')<>'string'or(a->>'provider_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')then raise exception'invalid sales tracking online provider'using errcode='22023';end if;
 if(select count(*)<>count(distinct a->>'provider_id')from pg_catalog.jsonb_array_elements(provider_amounts)e(a))then raise exception'duplicate sales tracking online provider'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)left join public.sales_tracking_online_order_providers o on o.id=(a->>'provider_id')::uuid and o.organization_id=c.organization_id and o.branch_id=c.branch_id and o.active where o.id is null)then raise exception'invalid sales tracking online provider scope'using errcode='22023';end if;
 select coalesce(sum(private.sales_tracking_numeric_field(a,'amount')),0)into provider_total from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 if provider_total<>private.sales_tracking_numeric_field(v,'online_delivery')then raise exception'sales tracking online provider total mismatch'using errcode='23514';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||target_report_id::text||':sales_tracking_correction',0));
 select r.*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select x.*into strict case_row from public.sales_tracking_report_cases x where x.id=s.case_id for update;
 if case_row.open_correction_report_id<>s.id or s.state<>'draft'then raise exception'sales tracking correction is not open'using errcode='55000';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking correction changed';end if;
 delete from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period=save_sales_tracking_correction.entry_period;
 insert into public.sales_tracking_period_entries(report_id,entry_period,entered_by_user_id,entered_by_name_snapshot)values(s.id,entry_period,actor_user_id,c.actor_name)returning*into p;
 insert into public.sales_tracking_sales_rows(report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,refund_total,remarks)
 values(s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),private.sales_tracking_numeric_field(v,'pos_credit'),provider_total,private.sales_tracking_refund_field(v),nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),''))returning*into sales_row;
 insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)select sales_row.id,(a->>'provider_id')::uuid,private.sales_tracking_numeric_field(a,'amount')from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(x,'entry_date'),private.sales_tracking_integer_field(x,'denom_1'),private.sales_tracking_integer_field(x,'denom_2'),private.sales_tracking_integer_field(x,'denom_5'),private.sales_tracking_integer_field(x,'denom_10'),private.sales_tracking_integer_field(x,'denom_20'),private.sales_tracking_integer_field(x,'denom_50'),private.sales_tracking_integer_field(x,'denom_100'),private.sales_tracking_integer_field(x,'denom_200'),private.sales_tracking_integer_field(x,'denom_500'),private.sales_tracking_numeric_field(x,'remaining_cash'),nullif(pg_catalog.btrim(coalesce(x->>'remarks','')),'')from pg_catalog.jsonb_array_elements(cash_rows)e(x);
 update public.sales_tracking_reports r set branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id where r.id=s.id;
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,s.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking correction denied'using errcode='42501';end$$;

create function public.submit_sales_tracking_correction(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text)
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
 update public.sales_tracking_reports r set state='submitted',submitted_at=pg_catalog.now(),submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name,branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id,review_status='reviewed',review_revision=source.review_revision+1,reviewed_at=pg_catalog.now(),reviewed_by_user_id=actor_user_id where r.id=s.id;
 update public.sales_tracking_report_cases x set authoritative_report_id=s.id,open_correction_report_id=null where x.id=case_row.id;
 insert into public.sales_tracking_review_events(organization_id,branch_id,report_id,from_status,to_status,actor_user_id)values(s.organization_id,s.branch_id,s.id,'needs_review','reviewed',actor_user_id);
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,s.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking correction denied'using errcode='42501';end$$;

-- Make current state case-aware while retaining the established payload builder.
alter function public.get_sales_tracking_current_state(uuid,uuid,date) rename to get_sales_tracking_current_state_without_corrections_legacy;
revoke all on function public.get_sales_tracking_current_state_without_corrections_legacy(uuid,uuid,date)from public,anon,authenticated,service_role;

create function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid,target_business_date date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;case_row public.sales_tracking_report_cases%rowtype;active_id uuid;source_id uuid;result jsonb;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select x.*into case_row from public.sales_tracking_report_cases x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=target_business_date;
 if case_row.id is null then return public.get_sales_tracking_current_state_without_corrections_legacy(actor_user_id,target_branch_id,target_business_date);end if;
 active_id:=coalesce(case_row.open_correction_report_id,case_row.authoritative_report_id,(select r.id from public.sales_tracking_reports r where r.case_id=case_row.id and r.state='draft'order by r.version_number desc limit 1));
 source_id:=case_row.authoritative_report_id;
 select pg_catalog.jsonb_build_object(
  'report_id',r.id,'business_date',r.business_date,'currency_code',r.currency_code,'state',r.state,'revision',r.branch_revision,
  'submitted_at',r.submitted_at,'submitted_by_user_id',r.submitted_by_user_id,'submitted_by_name_snapshot',r.submitted_by_name_snapshot,
  'review_status',coalesce(source.review_status,r.review_status),'review_revision',coalesce(source.review_revision,r.review_revision),'reviewed_at',coalesce(source.reviewed_at,r.reviewed_at),'reviewed_by_user_id',coalesce(source.reviewed_by_user_id,r.reviewed_by_user_id),'reviewed_by',reviewer.full_name,
  'case_id',r.case_id,'version_number',r.version_number,'is_correction_draft',(case_row.open_correction_report_id=r.id),'supersedes_report_id',r.supersedes_report_id,
  'attachment',private.sales_tracking_attachment_json(r.id),'attachments',private.sales_tracking_attachments_json(r.id),'source_attachments',case when r.id<>source_id then private.sales_tracking_attachments_json(source_id)else'[]'::jsonb end,
  'periods',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',p.id,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at)order by case p.entry_period when'middle_shift'then 1 else 2 end)from public.sales_tracking_period_entries p where p.report_id=r.id),'[]'::jsonb),
  'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',x.id,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'actual_cash',x.actual_cash,'actual_credit',x.actual_credit,'pos_cash',x.pos_cash,'pos_credit',x.pos_credit,'online_delivery',x.online_delivery,'refund_total',x.refund_total,'online_amounts',private.sales_tracking_online_amounts_for_row(x.id),'remarks',x.remarks,'actual_total',x.actual_cash+x.actual_credit+x.online_delivery,'gross_sales',x.actual_cash+x.actual_credit+x.online_delivery,'net_sales',x.actual_cash+x.actual_credit+x.online_delivery-x.refund_total,'pos_total',x.pos_cash+x.pos_credit+x.online_delivery,'variance',(x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit))order by case p.entry_period when'middle_shift'then 1 else 2 end)from public.sales_tracking_sales_rows x left join public.sales_tracking_period_entries p on p.id=x.period_entry_id where x.report_id=r.id),'[]'::jsonb),
  'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',x.id,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'denom_1',x.denom_1,'denom_2',x.denom_2,'denom_5',x.denom_5,'denom_10',x.denom_10,'denom_20',x.denom_20,'denom_50',x.denom_50,'denom_100',x.denom_100,'denom_200',x.denom_200,'denom_500',x.denom_500,'remaining_cash',x.remaining_cash,'remarks',x.remarks,'cash_total',x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500)order by case p.entry_period when'middle_shift'then 1 else 2 end)from public.sales_tracking_cash_rows x left join public.sales_tracking_period_entries p on p.id=x.period_entry_id where x.report_id=r.id),'[]'::jsonb),
  'totals',pg_catalog.jsonb_build_object('actual_cash',coalesce((select sum(x.actual_cash)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'actual_credit',coalesce((select sum(x.actual_credit)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'pos_cash',coalesce((select sum(x.pos_cash)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'pos_credit',coalesce((select sum(x.pos_credit)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'online_delivery',coalesce((select sum(x.online_delivery)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'actual_total',coalesce((select sum(x.actual_cash+x.actual_credit+x.online_delivery)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'gross_sales',coalesce((select sum(x.actual_cash+x.actual_credit+x.online_delivery)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'refund_total',coalesce((select sum(x.refund_total)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'net_sales',coalesce((select sum(x.actual_cash+x.actual_credit+x.online_delivery-x.refund_total)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'pos_total',coalesce((select sum(x.pos_cash+x.pos_credit+x.online_delivery)from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'variance',coalesce((select sum((x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit))from public.sales_tracking_sales_rows x where x.report_id=r.id),0),'cash_total',coalesce((select sum(x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500)from public.sales_tracking_cash_rows x where x.report_id=r.id),0),'remaining_cash',coalesce((select sum(x.remaining_cash)from public.sales_tracking_cash_rows x where x.report_id=r.id),0))
 )into result from public.sales_tracking_reports r left join public.sales_tracking_reports source on source.id=source_id left join public.profiles reviewer on reviewer.id=coalesce(source.reviewed_by_user_id,r.reviewed_by_user_id)where r.id=active_id;
 return result;
exception when no_data_found or too_many_rows then raise exception'sales tracking state denied'using errcode='42501';end$$;

-- A manager cannot race a review decision against an open correction.
create or replace function public.set_managed_sales_tracking_review_status(actor_user_id uuid,target_organization_id uuid,target_report_id uuid,expected_review_revision bigint,target_review_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare report public.sales_tracking_reports%rowtype;case_row public.sales_tracking_report_cases%rowtype;actor_name text;
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)then raise exception'sales tracking review access denied'using errcode='42501';end if;
 if target_review_status not in('needs_review','reviewed')then raise exception'invalid sales tracking review status'using errcode='22023';end if;
 select r.*into report from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=target_organization_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 select c.*into strict case_row from public.sales_tracking_report_cases c where c.id=report.case_id for update;
 if case_row.authoritative_report_id<>report.id or report.state<>'submitted'then raise exception'sales tracking report is not authoritative'using errcode='55000';end if;
 if case_row.open_correction_report_id is not null then raise sqlstate'PT409'using message='sales tracking correction is open';end if;
 if report.review_revision<>expected_review_revision then raise sqlstate'PT409'using message='sales tracking review changed';end if;
 if report.review_status=target_review_status then raise exception'sales tracking review status is unchanged'using errcode='22023';end if;
 update public.sales_tracking_reports r set review_status=target_review_status,review_revision=r.review_revision+1,reviewed_at=pg_catalog.now(),reviewed_by_user_id=actor_user_id where r.id=report.id;
 insert into public.sales_tracking_review_events(organization_id,branch_id,report_id,from_status,to_status,actor_user_id)values(report.organization_id,report.branch_id,report.id,report.review_status,target_review_status,actor_user_id);
 select p.full_name into actor_name from public.profiles p where p.id=actor_user_id;
 return pg_catalog.jsonb_build_object('report_id',report.id,'review_status',target_review_status,'review_revision',report.review_revision+1,'reviewed_at',(select r.reviewed_at from public.sales_tracking_reports r where r.id=report.id),'reviewed_by_user_id',actor_user_id,'reviewed_by',actor_name);
end$$;

-- Normal Sales Tracking mutations must resolve the logical case rather than
-- relying on the pre-versioning branch/day uniqueness of physical reports.
create function private.lock_normal_sales_tracking_case(
 target_organization_id uuid,target_branch_id uuid,target_business_date date,create_if_missing boolean)
returns public.sales_tracking_report_cases language plpgsql security definer set search_path='' as $$
declare case_row public.sales_tracking_report_cases%rowtype;
begin
 select c.* into case_row from public.sales_tracking_report_cases c
 where c.organization_id=target_organization_id and c.branch_id=target_branch_id and c.business_date=target_business_date
 for update;
 if case_row.id is null and create_if_missing then
  insert into public.sales_tracking_report_cases(organization_id,branch_id,business_date)
  values(target_organization_id,target_branch_id,target_business_date)returning*into case_row;
 end if;
 if case_row.id is not null and case_row.open_correction_report_id is not null then
  raise sqlstate'PT409'using message='sales tracking correction is open';
 end if;
 if case_row.authoritative_report_id is not null and not exists(
  select 1 from public.sales_tracking_reports r where r.id=case_row.authoritative_report_id
   and r.case_id=case_row.id and r.organization_id=target_organization_id and r.branch_id=target_branch_id
   and r.business_date=target_business_date and r.state='submitted'
 )then raise exception'invalid sales tracking case authority'using errcode='55000';end if;
 return case_row;
end$$;
revoke all on function private.lock_normal_sales_tracking_case(uuid,uuid,date,boolean)from public,anon,authenticated,service_role;

create or replace function public.ensure_sales_tracking_draft_report(actor_user_id uuid,target_branch_id uuid,target_business_date date)
returns table(report_id uuid,organization_id uuid,branch_id uuid,business_date date,revision bigint)
language plpgsql security definer set search_path='' as $$
declare c record;case_row public.sales_tracking_report_cases%rowtype;s public.sales_tracking_reports%rowtype;v_currency text;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null or target_business_date>c.business_date then raise exception'invalid sales tracking business date'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_business_date::text||':sales_tracking',0));
 case_row:=private.lock_normal_sales_tracking_case(c.organization_id,c.branch_id,target_business_date,true);
 if case_row.authoritative_report_id is not null then raise exception'sales tracking already submitted'using errcode='23505';end if;
 select r.*into s from public.sales_tracking_reports r where r.case_id=case_row.id and r.state='draft'for update;
 if s.id is null then
  if exists(select 1 from public.sales_tracking_reports r where r.case_id=case_row.id)then raise exception'invalid sales tracking case state'using errcode='55000';end if;
  select case b.country_code when'AE'then'AED'else'SAR'end into v_currency from public.branches b where b.id=c.branch_id and b.organization_id=c.organization_id;
  insert into public.sales_tracking_reports(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,
   branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,branch_revision,updated_by_user_id,currency_code,case_id,version_number)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,target_business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',0,actor_user_id,v_currency,case_row.id,1)returning*into s;
 end if;
 return query select s.id,s.organization_id,s.branch_id,s.business_date,s.branch_revision;
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

create or replace function public.save_sales_tracking_draft(
 actor_user_id uuid,target_branch_id uuid,target_business_date date,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;p public.sales_tracking_period_entries%rowtype;v jsonb;provider_amounts jsonb;provider_total numeric;sales_row public.sales_tracking_sales_rows%rowtype;resolved_report_id uuid;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null then raise exception'sales tracking business date required'using errcode='22004';end if;
 if target_business_date>c.business_date then raise exception'sales tracking future business date denied'using errcode='22023';end if;
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,target_business_date);perform private.validate_sales_tracking_entry_dates(cash_rows,target_business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 select value into strict v from pg_catalog.jsonb_array_elements(sales_rows);provider_amounts:=coalesce(v->'online_amounts','[]'::jsonb);
 if pg_catalog.jsonb_typeof(provider_amounts)<>'array'then raise exception'invalid sales tracking online amounts'using errcode='22023';end if;
 if private.sales_tracking_numeric_field(v,'online_delivery')>0 and pg_catalog.jsonb_array_length(provider_amounts)=0 then raise exception'online provider breakdown required'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)where pg_catalog.jsonb_typeof(a->'provider_id')<>'string'or(a->>'provider_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')then raise exception'invalid sales tracking online provider'using errcode='22023';end if;
 if(select count(*)<>count(distinct a->>'provider_id')from pg_catalog.jsonb_array_elements(provider_amounts)e(a))then raise exception'duplicate sales tracking online provider'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)left join public.sales_tracking_online_order_providers o on o.id=(a->>'provider_id')::uuid and o.organization_id=c.organization_id and o.branch_id=c.branch_id and o.active where o.id is null)then raise exception'invalid sales tracking online provider scope'using errcode='22023';end if;
 select coalesce(sum(private.sales_tracking_numeric_field(a,'amount')),0)into provider_total from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 if provider_total<>private.sales_tracking_numeric_field(v,'online_delivery')then raise exception'sales tracking online provider total mismatch'using errcode='23514';end if;
 select e.report_id into strict resolved_report_id from public.ensure_sales_tracking_draft_report(actor_user_id,target_branch_id,target_business_date)e;
 select r.*into strict s from public.sales_tracking_reports r where r.id=resolved_report_id and r.state='draft'for update;
 if coalesce(expected_revision,-1)<>s.branch_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 if exists(select 1 from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period=save_sales_tracking_draft.entry_period)then raise exception'sales tracking period already saved'using errcode='23505';end if;
 insert into public.sales_tracking_period_entries(report_id,entry_period,entered_by_user_id,entered_by_name_snapshot)values(s.id,entry_period,actor_user_id,c.actor_name)returning*into p;
 insert into public.sales_tracking_sales_rows(report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,refund_total,remarks)
 values(s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),private.sales_tracking_numeric_field(v,'pos_credit'),provider_total,private.sales_tracking_refund_field(v),nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),'') )returning*into sales_row;
 insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)select sales_row.id,(a->>'provider_id')::uuid,private.sales_tracking_numeric_field(a,'amount')from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(x,'entry_date'),private.sales_tracking_integer_field(x,'denom_1'),private.sales_tracking_integer_field(x,'denom_2'),private.sales_tracking_integer_field(x,'denom_5'),private.sales_tracking_integer_field(x,'denom_10'),private.sales_tracking_integer_field(x,'denom_20'),private.sales_tracking_integer_field(x,'denom_50'),private.sales_tracking_integer_field(x,'denom_100'),private.sales_tracking_integer_field(x,'denom_200'),private.sales_tracking_integer_field(x,'denom_500'),private.sales_tracking_numeric_field(x,'remaining_cash'),nullif(pg_catalog.btrim(coalesce(x->>'remarks','')),'')from pg_catalog.jsonb_array_elements(cash_rows)e(x);
 update public.sales_tracking_reports r set branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id where r.id=s.id;
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,target_business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking draft denied'using errcode='42501';end$$;

create or replace function public.submit_sales_tracking(actor_user_id uuid,target_branch_id uuid,target_business_date date,expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;case_row public.sales_tracking_report_cases%rowtype;prior public.sales_tracking_submission_idempotency%rowtype;
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
 if(select count(*)from public.sales_tracking_period_entries p where p.report_id=s.id)<>2 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports r set state='submitted',submitted_at=pg_catalog.now(),branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name where r.id=s.id returning*into s;
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,target_business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking submit denied'using errcode='42501';end$$;

create or replace function public.save_sales_tracking_draft(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;case_row public.sales_tracking_report_cases%rowtype;s public.sales_tracking_reports%rowtype;p public.sales_tracking_period_entries%rowtype;v jsonb;provider_amounts jsonb;provider_total numeric;sales_row public.sales_tracking_sales_rows%rowtype;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,c.business_date);perform private.validate_sales_tracking_entry_dates(cash_rows,c.business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 select value into strict v from pg_catalog.jsonb_array_elements(sales_rows);provider_amounts:=coalesce(v->'online_amounts','[]'::jsonb);
 if pg_catalog.jsonb_typeof(provider_amounts)<>'array'then raise exception'invalid sales tracking online amounts'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)where pg_catalog.jsonb_typeof(a->'provider_id')<>'string'or(a->>'provider_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')then raise exception'invalid sales tracking online provider'using errcode='22023';end if;
 if(select count(*)<>count(distinct a->>'provider_id')from pg_catalog.jsonb_array_elements(provider_amounts)e(a))then raise exception'duplicate sales tracking online provider'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)left join public.sales_tracking_online_order_providers provider on provider.id=(a->>'provider_id')::uuid and provider.organization_id=c.organization_id and provider.branch_id=c.branch_id and provider.active where provider.id is null)then raise exception'invalid sales tracking online provider scope'using errcode='22023';end if;
 if pg_catalog.jsonb_array_length(provider_amounts)>0 then select coalesce(sum(private.sales_tracking_numeric_field(a,'amount')),0)into provider_total from pg_catalog.jsonb_array_elements(provider_amounts)e(a);else provider_total:=private.sales_tracking_numeric_field(v,'online_delivery');end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':sales_tracking',0));
 case_row:=private.lock_normal_sales_tracking_case(c.organization_id,c.branch_id,c.business_date,true);
 if case_row.authoritative_report_id is not null then raise exception'sales tracking already submitted'using errcode='23505';end if;
 select r.*into s from public.sales_tracking_reports r where r.case_id=case_row.id and r.state='draft'for update;
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise sqlstate'PT409'using message='sales tracking changed';end if;
 if s.id is not null and entry_period='middle_shift'and exists(select 1 from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period='closing_shift')then raise exception'sales tracking closing period already saved'using errcode='23505';end if;
 if s.id is null then
  if exists(select 1 from public.sales_tracking_reports r where r.case_id=case_row.id)then raise exception'invalid sales tracking case state'using errcode='55000';end if;
  insert into public.sales_tracking_reports(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,branch_revision,updated_by_user_id,case_id,version_number)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',1,actor_user_id,case_row.id,1)returning*into s;
 else
  if exists(select 1 from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period=save_sales_tracking_draft.entry_period)then raise exception'sales tracking period already saved'using errcode='23505';end if;
  update public.sales_tracking_reports r set branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id where r.id=s.id returning*into s;
 end if;
 insert into public.sales_tracking_period_entries(report_id,entry_period,entered_by_user_id,entered_by_name_snapshot)values(s.id,entry_period,actor_user_id,c.actor_name)returning*into p;
 insert into public.sales_tracking_sales_rows(report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,remarks)
 values(s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),private.sales_tracking_numeric_field(v,'pos_credit'),provider_total,nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),''))returning*into sales_row;
 insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)select sales_row.id,(a->>'provider_id')::uuid,private.sales_tracking_numeric_field(a,'amount')from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(x,'entry_date'),private.sales_tracking_integer_field(x,'denom_1'),private.sales_tracking_integer_field(x,'denom_2'),private.sales_tracking_integer_field(x,'denom_5'),private.sales_tracking_integer_field(x,'denom_10'),private.sales_tracking_integer_field(x,'denom_20'),private.sales_tracking_integer_field(x,'denom_50'),private.sales_tracking_integer_field(x,'denom_100'),private.sales_tracking_integer_field(x,'denom_200'),private.sales_tracking_integer_field(x,'denom_500'),private.sales_tracking_numeric_field(x,'remaining_cash'),nullif(pg_catalog.btrim(coalesce(x->>'remarks','')),'')from pg_catalog.jsonb_array_elements(cash_rows)e(x);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,c.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking draft denied'using errcode='42501';end$$;

create or replace function public.submit_sales_tracking(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;case_row public.sales_tracking_report_cases%rowtype;s public.sales_tracking_reports%rowtype;prior public.sales_tracking_submission_idempotency%rowtype;period_count bigint;closing_count bigint;invalid_period_count bigint;
begin
 if request_hash!~'^[0-9a-f]{64}$'then raise exception'invalid sales tracking request hash'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':sales_tracking',0));
 select*into prior from public.sales_tracking_submission_idempotency x where x.actor_user_id=submit_sales_tracking.actor_user_id and x.idempotency_key=submit_sales_tracking.idempotency_key;
 if prior.actor_user_id is not null then
  if prior.request_hash<>request_hash then raise exception'sales tracking idempotency conflict'using errcode='23505';end if;
  perform 1 from public.sales_tracking_reports x where x.id=prior.report_id and x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date and x.state='submitted';
  if not found then raise exception'sales tracking submit denied'using errcode='42501';end if;
  return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,c.business_date);
 end if;
 case_row:=private.lock_normal_sales_tracking_case(c.organization_id,c.branch_id,c.business_date,false);
 if case_row.id is null then raise sqlstate'PT409'using message='sales tracking changed';end if;
 if case_row.authoritative_report_id is not null then raise exception'sales tracking already submitted'using errcode='23505';end if;
 select r.*into s from public.sales_tracking_reports r where r.case_id=case_row.id and r.state='draft'for update;
 if s.id is null or coalesce(expected_revision,-1)<>s.branch_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 select count(*),count(*)filter(where p.entry_period='closing_shift'),count(*)filter(where p.entry_period not in('middle_shift','closing_shift'))into period_count,closing_count,invalid_period_count from public.sales_tracking_period_entries p where p.report_id=s.id;
 if period_count<1 or period_count>2 or closing_count<>1 or invalid_period_count<>0 then raise exception'sales tracking periods incomplete'using errcode='22023';end if;
 update public.sales_tracking_reports r set state='submitted',submitted_at=pg_catalog.now(),branch_revision=r.branch_revision+1,updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c.actor_name where r.id=s.id returning*into s;
 insert into public.sales_tracking_submission_idempotency(actor_user_id,idempotency_key,request_hash,report_id)values(actor_user_id,idempotency_key,request_hash,s.id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,c.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking submit denied'using errcode='42501';end$$;

-- The null-report attachment fallback is intentionally limited to an ordinary
-- version-1 draft. Open corrections must use their explicit report id.
create or replace function public.prepare_sales_tracking_attachment_upload(
 actor_user_id uuid,target_branch_id uuid,target_business_date date,target_report_id uuid,
 expected_revision bigint,attachment_id uuid,attachment_mime_type text,replacement_attachment_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;replacement public.sales_tracking_attachments%rowtype;active_count integer;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null or target_business_date>c.business_date then raise exception'invalid sales tracking business date'using errcode='22023';end if;
 if attachment_id is null or attachment_mime_type not in('image/jpeg','image/png','image/webp')then raise exception'invalid sales tracking attachment'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_business_date::text||':sales_tracking',0));
 if target_report_id is null then select e.report_id into target_report_id from public.ensure_sales_tracking_draft_report(actor_user_id,target_branch_id,target_business_date)e;end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_report_id::text||':sales_tracking_photo',0));
 select r.*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id and r.business_date=target_business_date for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 select count(*)into active_count from public.sales_tracking_attachments a where a.report_id=s.id and a.deleted_at is null;
 if replacement_attachment_id is not null then
  select a.*into replacement from public.sales_tracking_attachments a where a.id=replacement_attachment_id and a.report_id=s.id and a.deleted_at is null for update;
  if not found then raise exception'sales tracking attachment not found'using errcode='P0002';end if;
 elsif active_count>=3 then raise exception'maximum sales tracking photos reached'using errcode='23505';end if;
 return pg_catalog.jsonb_build_object('report_id',s.id,'organization_id',s.organization_id,'branch_id',s.branch_id,'business_date',s.business_date,'revision',s.branch_revision,'attachment_id',attachment_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

revoke all on function public.ensure_sales_tracking_draft_report(uuid,uuid,date),public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb),public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,date,bigint,uuid,text),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text),public.prepare_sales_tracking_attachment_upload(uuid,uuid,date,uuid,bigint,uuid,text,uuid)from public,anon,authenticated;
grant execute on function public.ensure_sales_tracking_draft_report(uuid,uuid,date),public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb),public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking(uuid,uuid,date,bigint,uuid,text),public.submit_sales_tracking(uuid,uuid,bigint,uuid,text),public.prepare_sales_tracking_attachment_upload(uuid,uuid,date,uuid,bigint,uuid,text,uuid)to service_role;

revoke all on function public.start_sales_tracking_correction(uuid,uuid,uuid,bigint),public.save_sales_tracking_correction(uuid,uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking_correction(uuid,uuid,uuid,bigint,uuid,text),public.get_sales_tracking_current_state(uuid,uuid,date),public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text)from public,anon,authenticated;
grant execute on function public.start_sales_tracking_correction(uuid,uuid,uuid,bigint),public.save_sales_tracking_correction(uuid,uuid,uuid,bigint,text,jsonb,jsonb),public.submit_sales_tracking_correction(uuid,uuid,uuid,bigint,uuid,text),public.get_sales_tracking_current_state(uuid,uuid,date),public.set_managed_sales_tracking_review_status(uuid,uuid,uuid,bigint,text)to service_role;

commit;
