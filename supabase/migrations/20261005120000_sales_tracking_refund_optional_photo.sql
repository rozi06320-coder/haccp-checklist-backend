begin;

alter table public.sales_tracking_sales_rows
  add column refund_total numeric(14,2) not null default 0,
  add constraint sales_tracking_sales_rows_refund_nonnegative_check check(refund_total>=0),
  add constraint sales_tracking_sales_rows_refund_not_over_gross_check
    check(refund_total<=actual_cash+actual_credit+online_delivery);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('sales-tracking-evidence','sales-tracking-evidence',false,5242880,
  array['image/jpeg','image/png','image/webp'])
on conflict(id)do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create unique index if not exists sales_tracking_reports_id_org_branch_uidx
  on public.sales_tracking_reports(id,organization_id,branch_id);

create table public.sales_tracking_attachments(
  id uuid primary key,
  organization_id uuid not null,
  branch_id uuid not null,
  report_id uuid not null,
  storage_path text not null,
  original_filename text not null,
  mime_type text not null check(mime_type in('image/jpeg','image/png','image/webp')),
  size_bytes bigint not null check(size_bytes>0 and size_bytes<=5242880),
  uploaded_by_user_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by_user_id uuid references public.profiles(id) on delete restrict,
  constraint sales_tracking_attachments_report_scope_fkey
    foreign key(report_id,organization_id,branch_id)
    references public.sales_tracking_reports(id,organization_id,branch_id) on delete restrict,
  constraint sales_tracking_attachments_storage_path_check check(length(storage_path)between 1 and 500),
  constraint sales_tracking_attachments_filename_check check(length(original_filename)between 1 and 180),
  constraint sales_tracking_attachments_deleted_check check((deleted_at is null)=(deleted_by_user_id is null))
);
create unique index sales_tracking_attachments_active_report_uidx
  on public.sales_tracking_attachments(report_id)where deleted_at is null;
create index sales_tracking_attachments_scope_idx
  on public.sales_tracking_attachments(organization_id,branch_id,report_id);
alter table public.sales_tracking_attachments enable row level security;
revoke all on public.sales_tracking_attachments from public,anon,authenticated;

create function private.sales_tracking_refund_field(row_value jsonb)
returns numeric language plpgsql immutable security definer set search_path='' as $$
declare raw text;amount numeric;gross numeric;
begin
 raw:=pg_catalog.btrim(coalesce(row_value->>'refund_total',''));
 if raw=''then return 0;end if;
 if raw!~'^(0|[1-9][0-9]*)(\.[0-9]{1,2})?$'then raise exception'invalid sales tracking refund'using errcode='22023';end if;
 amount:=raw::numeric;
 gross:=private.sales_tracking_numeric_field(row_value,'actual_cash')+
   private.sales_tracking_numeric_field(row_value,'actual_credit')+
   private.sales_tracking_numeric_field(row_value,'online_delivery');
 if amount<0 or amount>gross then raise exception'invalid sales tracking refund'using errcode='22023';end if;
 return amount;
exception when invalid_text_representation or numeric_value_out_of_range then
 raise exception'invalid sales tracking refund'using errcode='22023';
end$$;
revoke all on function private.sales_tracking_refund_field(jsonb)from public,anon,authenticated;

create function private.sales_tracking_attachment_json(target_report_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when attachment.id is null then null else pg_catalog.jsonb_build_object(
  'id',attachment.id,'storage_path',attachment.storage_path,'original_filename',attachment.original_filename,
  'mime_type',attachment.mime_type,'size_bytes',attachment.size_bytes,'created_at',attachment.created_at)
 end from(select 1)seed left join lateral(
  select a.* from public.sales_tracking_attachments a
  where a.report_id=target_report_id and a.deleted_at is null order by a.created_at desc limit 1
 )attachment on true
$$;
revoke all on function private.sales_tracking_attachment_json(uuid)from public,anon,authenticated;

create function public.ensure_sales_tracking_draft_report(actor_user_id uuid,target_branch_id uuid,target_business_date date)
returns table(report_id uuid,organization_id uuid,branch_id uuid,business_date date,revision bigint)
language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;v_currency text;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null or target_business_date>c.business_date then raise exception'invalid sales tracking business date'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_business_date::text||':sales_tracking',0));
 select*into s from public.sales_tracking_reports r where r.organization_id=c.organization_id and r.branch_id=c.branch_id and r.business_date=target_business_date for update;
 if s.id is null then
  select case b.country_code when'AE'then'AED'else'SAR'end into v_currency from public.branches b where b.id=c.branch_id;
  insert into public.sales_tracking_reports(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,
   branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,branch_revision,updated_by_user_id,currency_code)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,target_business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',0,actor_user_id,v_currency)returning*into s;
 end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 return query select s.id,s.organization_id,s.branch_id,s.business_date,s.branch_revision;
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

create function public.finalize_sales_tracking_attachment(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,
 expected_revision bigint,attachment_id uuid,attachment_metadata jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;old public.sales_tracking_attachments%rowtype;created public.sales_tracking_attachments%rowtype;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_report_id::text||':sales_tracking_photo',0));
 select*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 if attachment_metadata->>'storage_path'<>c.organization_id::text||'/'||c.branch_id::text||'/sales-tracking/'||s.id::text||'/'||attachment_id::text||(case attachment_metadata->>'mime_type' when'image/jpeg'then'.jpg'when'image/png'then'.png'when'image/webp'then'.webp'else''end)then raise exception'invalid sales tracking attachment path'using errcode='22023';end if;
 select*into old from public.sales_tracking_attachments a where a.report_id=s.id and a.deleted_at is null for update;
 if old.id is not null then update public.sales_tracking_attachments set deleted_at=now(),deleted_by_user_id=actor_user_id where id=old.id;end if;
 insert into public.sales_tracking_attachments(id,organization_id,branch_id,report_id,storage_path,original_filename,mime_type,size_bytes,uploaded_by_user_id)
 values(attachment_id,c.organization_id,c.branch_id,s.id,attachment_metadata->>'storage_path',attachment_metadata->>'original_filename',attachment_metadata->>'mime_type',(attachment_metadata->>'size_bytes')::bigint,actor_user_id)returning*into created;
 return pg_catalog.jsonb_build_object('attachment',private.sales_tracking_attachment_json(s.id),'old_storage_path',old.storage_path);
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

create function public.remove_sales_tracking_attachment(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,
 target_attachment_id uuid,expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;a public.sales_tracking_attachments%rowtype;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 select*into a from public.sales_tracking_attachments x where x.id=target_attachment_id and x.report_id=s.id and x.deleted_at is null for update;
 if not found then raise exception'sales tracking attachment not found'using errcode='P0002';end if;
 update public.sales_tracking_attachments set deleted_at=now(),deleted_by_user_id=actor_user_id where id=a.id;
 return pg_catalog.jsonb_build_object('attachment',null,'old_storage_path',a.storage_path);
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

revoke all on function public.ensure_sales_tracking_draft_report(uuid,uuid,date),
 public.finalize_sales_tracking_attachment(uuid,uuid,uuid,bigint,uuid,jsonb),
 public.remove_sales_tracking_attachment(uuid,uuid,uuid,uuid,bigint)from public,anon,authenticated;
grant execute on function public.ensure_sales_tracking_draft_report(uuid,uuid,date),
 public.finalize_sales_tracking_attachment(uuid,uuid,uuid,bigint,uuid,jsonb),
 public.remove_sales_tracking_attachment(uuid,uuid,uuid,uuid,bigint)to service_role;

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
  'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'actual_cash',r.actual_cash,'actual_credit',r.actual_credit,'pos_cash',r.pos_cash,'pos_credit',r.pos_credit,'online_delivery',r.online_delivery,'refund_total',r.refund_total,'online_amounts',private.sales_tracking_online_amounts_for_row(r.id),'remarks',r.remarks,'actual_total',r.actual_cash+r.actual_credit+r.online_delivery,'gross_sales',r.actual_cash+r.actual_credit+r.online_delivery,'net_sales',r.actual_cash+r.actual_credit+r.online_delivery-r.refund_total,'pos_total',r.pos_cash+r.pos_credit+r.online_delivery,'variance',(r.actual_cash+r.actual_credit+r.online_delivery)-(r.pos_cash+r.pos_credit+r.online_delivery))order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_sales_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'denom_1',r.denom_1,'denom_2',r.denom_2,'denom_5',r.denom_5,'denom_10',r.denom_10,'denom_20',r.denom_20,'denom_50',r.denom_50,'denom_100',r.denom_100,'denom_200',r.denom_200,'denom_500',r.denom_500,'remaining_cash',r.remaining_cash,'remarks',r.remarks,'cash_total',r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_cash_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'attachment',private.sales_tracking_attachment_json(s.id),'totals',pg_catalog.jsonb_build_object('actual_cash',coalesce((select sum(r.actual_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'actual_credit',coalesce((select sum(r.actual_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_cash',coalesce((select sum(r.pos_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_credit',coalesce((select sum(r.pos_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'online_delivery',coalesce((select sum(r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'actual_total',coalesce((select sum(r.actual_cash+r.actual_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'gross_sales',coalesce((select sum(r.actual_cash+r.actual_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'refund_total',coalesce((select sum(r.refund_total)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'net_sales',coalesce((select sum(r.actual_cash+r.actual_credit+r.online_delivery-r.refund_total)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_total',coalesce((select sum(r.pos_cash+r.pos_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'variance',coalesce((select sum((r.actual_cash+r.actual_credit)-(r.pos_cash+r.pos_credit))from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'cash_total',coalesce((select sum(r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)from public.sales_tracking_cash_rows r where r.report_id=s.id),0),'remaining_cash',coalesce((select sum(r.remaining_cash)from public.sales_tracking_cash_rows r where r.report_id=s.id),0))
 );
exception when no_data_found or too_many_rows then raise exception'sales tracking state denied'using errcode='42501';end;
$$;

create or replace function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,c.business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking state denied'using errcode='42501';end$$;

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
declare c record;s public.sales_tracking_reports%rowtype;p public.sales_tracking_period_entries%rowtype;v_business_date date;v jsonb;provider_amounts jsonb;provider_total numeric;sales_row public.sales_tracking_sales_rows%rowtype;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null then raise exception'sales tracking business date required'using errcode='22004';end if;
 v_business_date:=target_business_date;
 if v_business_date>c.business_date then raise exception'sales tracking future business date denied'using errcode='22023';end if;
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,v_business_date);perform private.validate_sales_tracking_entry_dates(cash_rows,v_business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 select value into strict v from pg_catalog.jsonb_array_elements(sales_rows);
 provider_amounts:=coalesce(v->'online_amounts','[]'::jsonb);
 if pg_catalog.jsonb_typeof(provider_amounts)<>'array'then raise exception'invalid sales tracking online amounts'using errcode='22023';end if;
 if private.sales_tracking_numeric_field(v,'online_delivery')>0 and pg_catalog.jsonb_array_length(provider_amounts)=0 then raise exception'online provider breakdown required'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a)where pg_catalog.jsonb_typeof(a->'provider_id')<>'string'or(a->>'provider_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')then raise exception'invalid sales tracking online provider'using errcode='22023';end if;
 if(select count(*)<>count(distinct a->>'provider_id')from pg_catalog.jsonb_array_elements(provider_amounts)e(a))then raise exception'duplicate sales tracking online provider'using errcode='22023';end if;
 if exists(
  select 1
  from pg_catalog.jsonb_array_elements(provider_amounts)e(a)
  left join public.sales_tracking_online_order_providers provider on provider.id=(a->>'provider_id')::uuid and provider.organization_id=c.organization_id and provider.branch_id=c.branch_id and provider.active
  where provider.id is null
 )then raise exception'invalid sales tracking online provider scope'using errcode='22023';end if;
 if pg_catalog.jsonb_array_length(provider_amounts)>0 then
  select coalesce(sum(private.sales_tracking_numeric_field(a,'amount')),0)into provider_total from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
  if provider_total<>private.sales_tracking_numeric_field(v,'online_delivery')then raise exception'sales tracking online provider total mismatch'using errcode='23514';end if;
 else
  provider_total:=private.sales_tracking_numeric_field(v,'online_delivery');
 end if;
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
 insert into public.sales_tracking_sales_rows(report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,refund_total,remarks)
 values(s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),private.sales_tracking_numeric_field(v,'pos_credit'),provider_total,private.sales_tracking_refund_field(v),nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),''))
 returning*into sales_row;
 if pg_catalog.jsonb_array_length(provider_amounts)>0 then
  insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)
  select sales_row.id,(a->>'provider_id')::uuid,private.sales_tracking_numeric_field(a,'amount')
  from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 end if;
 insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(x,'entry_date'),private.sales_tracking_integer_field(x,'denom_1'),private.sales_tracking_integer_field(x,'denom_2'),private.sales_tracking_integer_field(x,'denom_5'),private.sales_tracking_integer_field(x,'denom_10'),private.sales_tracking_integer_field(x,'denom_20'),private.sales_tracking_integer_field(x,'denom_50'),private.sales_tracking_integer_field(x,'denom_100'),private.sales_tracking_integer_field(x,'denom_200'),private.sales_tracking_integer_field(x,'denom_500'),private.sales_tracking_numeric_field(x,'remaining_cash'),nullif(pg_catalog.btrim(coalesce(x->>'remarks','')),'')from pg_catalog.jsonb_array_elements(cash_rows)e(x);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id,v_business_date);
exception when no_data_found or too_many_rows then raise exception'sales tracking draft denied'using errcode='42501';end;
$function$;

create or replace function public.list_managed_sales_tracking_reports(actor_user_id uuid,target_organization_id uuid,from_date date default null,to_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)or(from_date is not null and to_date is not null and from_date>to_date)then raise exception'sales tracking report access denied'using errcode='42501';end if;
 return pg_catalog.jsonb_build_object(
 'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,'actual_cash',x.actual_cash,'actual_credit',x.actual_credit,'pos_cash',x.pos_cash,'pos_credit',x.pos_credit,'online_delivery',x.online_delivery,'refund_total',x.refund_total,'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.id,'provider_key',provider.default_provider_key,'provider_name',provider.name,'amount',amount.amount) order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.created_at,provider.name,provider.id)) from public.sales_tracking_online_amounts amount join public.sales_tracking_online_order_providers provider on provider.id=amount.provider_id where amount.sales_row_id=x.id and amount.amount<>0),'[]'::jsonb),'actual_total',x.actual_cash+x.actual_credit+x.online_delivery,'gross_sales',x.actual_cash+x.actual_credit+x.online_delivery,'net_sales',x.actual_cash+x.actual_credit+x.online_delivery-x.refund_total,'evidence_filename',(select a.original_filename from public.sales_tracking_attachments a where a.report_id=r.id and a.deleted_at is null),'evidence_available',exists(select 1 from public.sales_tracking_attachments a where a.report_id=r.id and a.deleted_at is null),'pos_total',x.pos_cash+x.pos_credit+x.online_delivery,'variance',(x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit),'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_sales_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb),
 'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,'denom_1',x.denom_1,'denom_2',x.denom_2,'denom_5',x.denom_5,'denom_10',x.denom_10,'denom_20',x.denom_20,'denom_50',x.denom_50,'denom_100',x.denom_100,'denom_200',x.denom_200,'denom_500',x.denom_500,'cash_total',x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500,'remaining_cash',x.remaining_cash,'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_cash_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb));
end;
$$;

create or replace function public.get_managed_sales_tracking_monthly_summary(actor_user_id uuid,target_organization_id uuid,target_month date,branch_filter uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if target_month is null or target_month<>pg_catalog.date_trunc('month',target_month)::date then raise exception'invalid sales tracking month'using errcode='22023';end if;
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)then raise exception'sales tracking monthly summary access denied'using errcode='42501';end if;
 if branch_filter is not null and not exists(select 1 from public.branches branch where branch.id=branch_filter and branch.organization_id=target_organization_id)then raise exception'sales tracking monthly summary branch denied'using errcode='42501';end if;
 with scoped_reports as materialized(
  select report.id,report.branch_id,report.business_date,report.currency_code,branch.name branch_name,branch.name_ar branch_name_ar,branch.code branch_code
  from public.sales_tracking_reports report join public.branches branch on branch.id=report.branch_id and branch.organization_id=report.organization_id
  where report.organization_id=target_organization_id and report.state='submitted'and report.submitted_at is not null
   and report.business_date>=target_month and report.business_date<(target_month+interval '1 month')::date and(branch_filter is null or report.branch_id=branch_filter)
 ),metrics as materialized(
  select report.id,report.branch_id,report.business_date,report.currency_code,report.branch_name,report.branch_name_ar,report.branch_code,
   (select pg_catalog.count(*)from public.sales_tracking_sales_rows row where row.report_id=report.id)::bigint sales_entry_count,
   (select pg_catalog.count(*)from public.sales_tracking_cash_rows row where row.report_id=report.id)::bigint cash_entry_count,
   coalesce((select pg_catalog.sum(row.actual_cash)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)actual_cash,
   coalesce((select pg_catalog.sum(row.actual_credit)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)actual_credit,
   coalesce((select pg_catalog.sum(row.online_delivery)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)online_delivery,
   coalesce((select pg_catalog.sum(row.pos_cash)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)pos_cash,
   coalesce((select pg_catalog.sum(row.pos_credit)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)pos_credit,
   coalesce((select pg_catalog.sum(row.actual_cash+row.actual_credit+row.online_delivery)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)total_sales,coalesce((select pg_catalog.sum(row.refund_total)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)refund_total,coalesce((select pg_catalog.sum(row.actual_cash+row.actual_credit+row.online_delivery-row.refund_total)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)net_sales,
   coalesce((select pg_catalog.sum((row.actual_cash+row.actual_credit)-(row.pos_cash+row.pos_credit))from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)total_variance,
   coalesce((select pg_catalog.sum(row.denom_1+row.denom_2*2+row.denom_5*5+row.denom_10*10+row.denom_20*20+row.denom_50*50+row.denom_100*100+row.denom_200*200+row.denom_500*500)from public.sales_tracking_cash_rows row where row.report_id=report.id),0::numeric)total_cash_collected
  from scoped_reports report
 ),provider_amounts as materialized(
  select report.currency_code,report.branch_id,provider.default_provider_key,provider.normalized_name,min(provider.name)provider_name,bool_or(provider.is_default)is_default,min(provider.created_at)first_created_at,min(provider.id::text)::uuid first_provider_id,pg_catalog.sum(amount.amount)amount
  from scoped_reports report join public.sales_tracking_sales_rows row on row.report_id=report.id join public.sales_tracking_online_amounts amount on amount.sales_row_id=row.id and amount.amount<>0 join public.sales_tracking_online_order_providers provider on provider.id=amount.provider_id
  group by report.currency_code,report.branch_id,provider.default_provider_key,provider.normalized_name
 ),provider_totals as materialized(
  select currency_code,default_provider_key,normalized_name,min(provider_name)provider_name,bool_or(is_default)is_default,min(first_created_at)first_created_at,min(first_provider_id::text)::uuid first_provider_id,pg_catalog.sum(amount)amount
  from provider_amounts group by currency_code,default_provider_key,normalized_name
 ),legacy_online as materialized(
  select report.currency_code,report.branch_id,coalesce(pg_catalog.sum(row.online_delivery),0::numeric)amount
  from scoped_reports report join public.sales_tracking_sales_rows row on row.report_id=report.id
  where not exists(select 1 from public.sales_tracking_online_amounts amount where amount.sales_row_id=row.id)
  group by report.currency_code,report.branch_id
 ),currency_totals as materialized(
  select currency_code,pg_catalog.count(*)::bigint submitted_report_count,pg_catalog.count(distinct(branch_id,business_date))::bigint submitted_branch_day_count,pg_catalog.count(distinct branch_id)::bigint reporting_branch_count,
   coalesce(pg_catalog.sum(sales_entry_count),0)::bigint sales_entry_count,coalesce(pg_catalog.sum(cash_entry_count),0)::bigint cash_entry_count,
   coalesce(pg_catalog.sum(total_sales),0::numeric) total_sales,coalesce(pg_catalog.sum(refund_total),0::numeric) refund_total,coalesce(pg_catalog.sum(net_sales),0::numeric) net_sales,coalesce(pg_catalog.sum(total_cash_collected),0::numeric) total_cash_collected,coalesce(pg_catalog.sum(total_variance),0::numeric) total_variance,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)=0)::bigint balanced_sales_report_count,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)<>0)::bigint variance_sales_report_count,
   coalesce(pg_catalog.sum(actual_cash),0::numeric)actual_cash,coalesce(pg_catalog.sum(actual_credit),0::numeric)actual_credit,coalesce(pg_catalog.sum(online_delivery),0::numeric)online_delivery,coalesce(pg_catalog.sum(pos_cash),0::numeric)pos_cash,coalesce(pg_catalog.sum(pos_credit),0::numeric)pos_credit
  from metrics group by currency_code
 ),branch_totals as materialized(
  select branch_id,branch_name,branch_name_ar,branch_code,currency_code,pg_catalog.count(*)::bigint submitted_report_count,pg_catalog.count(distinct business_date)::bigint submitted_day_count,
   coalesce(pg_catalog.sum(sales_entry_count),0)::bigint sales_entry_count,coalesce(pg_catalog.sum(cash_entry_count),0)::bigint cash_entry_count,
   coalesce(pg_catalog.sum(total_sales),0::numeric)total_sales,coalesce(pg_catalog.sum(refund_total),0::numeric)refund_total,coalesce(pg_catalog.sum(net_sales),0::numeric)net_sales,coalesce(pg_catalog.sum(total_cash_collected),0::numeric)total_cash_collected,coalesce(pg_catalog.sum(total_variance),0::numeric)total_variance,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)=0)::bigint balanced_sales_report_count,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)<>0)::bigint variance_sales_report_count,
   coalesce(pg_catalog.sum(actual_cash),0::numeric)actual_cash,coalesce(pg_catalog.sum(actual_credit),0::numeric)actual_credit,coalesce(pg_catalog.sum(online_delivery),0::numeric)online_delivery,coalesce(pg_catalog.sum(pos_cash),0::numeric)pos_cash,coalesce(pg_catalog.sum(pos_credit),0::numeric)pos_credit
  from metrics group by branch_id,branch_name,branch_name_ar,branch_code,currency_code
 )
 select pg_catalog.jsonb_build_object(
  'generated_at',pg_catalog.statement_timestamp(),
  'scope',pg_catalog.jsonb_build_object('organization_id',target_organization_id,'branch_id',branch_filter,'month',pg_catalog.to_char(target_month,'YYYY-MM'),'date_from',target_month,'date_to',(target_month+interval '1 month - 1 day')::date),
  'currency_totals',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('currency_code',total.currency_code,'submitted_report_count',total.submitted_report_count,'submitted_branch_day_count',total.submitted_branch_day_count,'reporting_branch_count',total.reporting_branch_count,'sales_entry_count',total.sales_entry_count,'cash_entry_count',total.cash_entry_count,'total_sales',total.total_sales::text,'gross_sales',total.total_sales::text,'refund_total',total.refund_total::text,'net_sales',total.net_sales::text,'total_cash_collected',total.total_cash_collected::text,'total_variance',total.total_variance::text,'balanced_sales_report_count',total.balanced_sales_report_count,'variance_sales_report_count',total.variance_sales_report_count,'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash',total.actual_cash::text,'actual_credit',total.actual_credit::text,'online_delivery',total.online_delivery::text,'pos_cash',total.pos_cash::text,'pos_credit',total.pos_credit::text),'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.first_provider_id,'provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text)order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id))from provider_totals provider where provider.currency_code=total.currency_code),'[]'::jsonb),'legacy_online_delivery',coalesce((select pg_catalog.sum(legacy.amount)::text from legacy_online legacy where legacy.currency_code=total.currency_code),'0'))order by total.currency_code)from currency_totals total),'[]'::jsonb),
 'branches',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('branch_id',branch.branch_id,'branch_name',branch.branch_name,'branch_name_ar',branch.branch_name_ar,'branch_code',branch.branch_code,'currency_code',branch.currency_code,'submitted_report_count',branch.submitted_report_count,'submitted_day_count',branch.submitted_day_count,'sales_entry_count',branch.sales_entry_count,'cash_entry_count',branch.cash_entry_count,'total_sales',branch.total_sales::text,'gross_sales',branch.total_sales::text,'refund_total',branch.refund_total::text,'net_sales',branch.net_sales::text,'total_cash_collected',branch.total_cash_collected::text,'total_variance',branch.total_variance::text,'balanced_sales_report_count',branch.balanced_sales_report_count,'variance_sales_report_count',branch.variance_sales_report_count,'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash',branch.actual_cash::text,'actual_credit',branch.actual_credit::text,'online_delivery',branch.online_delivery::text,'pos_cash',branch.pos_cash::text,'pos_credit',branch.pos_credit::text),'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.first_provider_id,'provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text)order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id))from provider_amounts provider where provider.currency_code=branch.currency_code and provider.branch_id=branch.branch_id),'[]'::jsonb),'legacy_online_delivery',coalesce((select legacy.amount::text from legacy_online legacy where legacy.currency_code=branch.currency_code and legacy.branch_id=branch.branch_id),'0'))order by branch.branch_name,branch.currency_code,branch.branch_id)from branch_totals branch),'[]'::jsonb)
 )into result;
 if pg_catalog.jsonb_array_length(result->'currency_totals')<=1 then
  result:=result||pg_catalog.jsonb_build_object('totals',coalesce(result->'currency_totals'->0,pg_catalog.jsonb_build_object(
   'submitted_report_count',0,'submitted_branch_day_count',0,'reporting_branch_count',0,'sales_entry_count',0,'cash_entry_count',0,
   'total_sales','0','gross_sales','0','refund_total','0','net_sales','0','total_cash_collected','0','total_variance','0',
   'balanced_sales_report_count',0,'variance_sales_report_count',0,
   'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash','0','actual_credit','0','online_delivery','0','pos_cash','0','pos_credit','0'),
   'online_provider_breakdown','[]'::jsonb,'legacy_online_delivery','0')));
 end if;
 return result;
end;
$$;

revoke all on function public.get_sales_tracking_current_state(uuid,uuid,date),public.get_sales_tracking_current_state(uuid,uuid),public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb),public.list_managed_sales_tracking_reports(uuid,uuid,date,date),public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.get_sales_tracking_current_state(uuid,uuid,date),public.get_sales_tracking_current_state(uuid,uuid),public.save_sales_tracking_draft(uuid,uuid,date,bigint,text,jsonb,jsonb),public.list_managed_sales_tracking_reports(uuid,uuid,date,date),public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid) to service_role;


commit;
