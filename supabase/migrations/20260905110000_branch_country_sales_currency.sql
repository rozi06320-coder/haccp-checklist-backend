-- Branch country and Sales Tracking currency snapshot contract.

alter table public.branches
  add column country_code text default 'SA';

alter table public.branches
  alter column country_code set not null,
  add constraint branches_country_code_check check (country_code in ('SA', 'AE'));

alter table public.sales_tracking_reports
  add column currency_code text default 'SAR';

alter table public.sales_tracking_reports
  alter column currency_code set not null,
  add constraint sales_tracking_reports_currency_code_check check (currency_code in ('SAR', 'AED'));

create or replace function private.sales_tracking_set_currency_snapshot()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  branch_country text;
begin
  if tg_op = 'UPDATE' then
    if new.currency_code is distinct from old.currency_code then
      raise exception 'Sales Tracking report currency is immutable' using errcode = '22023';
    end if;
    return new;
  end if;

  select branch.country_code
  into strict branch_country
  from public.branches branch
  where branch.id = new.branch_id
    and branch.organization_id = new.organization_id;

  new.currency_code := case branch_country when 'AE' then 'AED' else 'SAR' end;
  return new;
exception
  when no_data_found or too_many_rows then
    raise exception 'invalid Sales Tracking branch currency' using errcode = '22023';
end;
$$;

revoke all on function private.sales_tracking_set_currency_snapshot() from public, anon, authenticated, service_role;

create trigger sales_tracking_reports_currency_snapshot
before insert on public.sales_tracking_reports
for each row execute function private.sales_tracking_set_currency_snapshot();

create trigger sales_tracking_reports_currency_immutable
before update of currency_code on public.sales_tracking_reports
for each row execute function private.sales_tracking_set_currency_snapshot();

drop function if exists public.list_internal_admin_branches(uuid, uuid);
create function public.list_internal_admin_branches(actor_user_id uuid, target_organization_id uuid)
returns table(
  id uuid,
  name text,
  name_ar text,
  code text,
  city text,
  area text,
  address text,
  timezone text,
  country_code text,
  active boolean,
  logo_path text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;
  return query
  select branch.id, branch.name, branch.name_ar, branch.code, branch.city, branch.area,
    branch.address, branch.timezone, branch.country_code, branch.active, branch.logo_path
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.organization_id = target_organization_id and organization.active
  order by branch.active desc, pg_catalog.lower(branch.name), branch.id
  limit 500;
end;
$$;

drop function if exists public.create_internal_admin_branch(uuid,uuid,text,text,text,text,text,text,text,boolean);
create function public.create_internal_admin_branch(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_name text,
  p_branch_name_ar text,
  p_branch_code text,
  p_branch_city text,
  p_branch_area text,
  p_branch_address text,
  p_branch_timezone text,
  p_branch_country_code text,
  p_branch_active boolean
)
returns table(id uuid, organization_id uuid, name text, name_ar text, code text, city text, area text, address text, timezone text, country_code text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare created public.branches%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = p_organization_id and organization.active)
    or p_branch_timezone not in ('Asia/Riyadh', 'Asia/Dubai', 'UTC')
    or p_branch_country_code not in ('SA', 'AE')
  then
    raise exception 'invalid branch request' using errcode = '22023';
  end if;
  insert into public.branches(organization_id,name,name_ar,code,city,area,address,timezone,country_code,active)
  values(
    p_organization_id,
    pg_catalog.regexp_replace(pg_catalog.btrim(p_branch_name), '\\s+', ' ', 'g'),
    nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_name_ar,'')), '\\s+', ' ', 'g'),''),
    pg_catalog.upper(pg_catalog.btrim(p_branch_code)),
    pg_catalog.regexp_replace(pg_catalog.btrim(p_branch_city), '\\s+', ' ', 'g'),
    nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_area,'')), '\\s+', ' ', 'g'),''),
    nullif(pg_catalog.btrim(coalesce(p_branch_address,'')),''),
    p_branch_timezone,p_branch_country_code,p_branch_active
  ) returning * into created;
  return query select created.id,created.organization_id,created.name,created.name_ar,created.code,created.city,created.area,created.address,created.timezone,created.country_code,created.active;
end;
$$;

drop function if exists public.update_internal_admin_branch(uuid,uuid,uuid,text,text,text,text,text,text,text);
create function public.update_internal_admin_branch(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_branch_id uuid,
  p_branch_name text,
  p_branch_name_ar text,
  p_branch_code text,
  p_branch_city text,
  p_branch_area text,
  p_branch_address text,
  p_branch_timezone text,
  p_branch_country_code text
)
returns table(id uuid, organization_id uuid, name text, name_ar text, code text, city text, area text, address text, timezone text, country_code text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare updated public.branches%rowtype;
begin
  if not private.is_internal_admin(p_actor_user_id)
    or p_branch_timezone not in ('Asia/Riyadh', 'Asia/Dubai', 'UTC')
    or p_branch_country_code not in ('SA', 'AE')
  then
    raise exception 'invalid branch request' using errcode = '22023';
  end if;
  update public.branches branch set
    name=pg_catalog.regexp_replace(pg_catalog.btrim(p_branch_name),'\\s+',' ','g'),
    name_ar=nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_name_ar,'')),'\\s+',' ','g'),''),
    code=pg_catalog.upper(pg_catalog.btrim(p_branch_code)),
    city=pg_catalog.regexp_replace(pg_catalog.btrim(p_branch_city),'\\s+',' ','g'),
    area=nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_branch_area,'')),'\\s+',' ','g'),''),
    address=nullif(pg_catalog.btrim(coalesce(p_branch_address,'')),''),
    timezone=p_branch_timezone,
    country_code=p_branch_country_code,
    updated_at=pg_catalog.now()
  where branch.id=p_branch_id and branch.organization_id=p_organization_id
  returning * into updated;
  if updated.id is null then raise exception 'branch not found' using errcode='P0002'; end if;
  return query select updated.id,updated.organization_id,updated.name,updated.name_ar,updated.code,updated.city,updated.area,updated.address,updated.timezone,updated.country_code,updated.active;
end;
$$;

revoke all on function public.list_internal_admin_branches(uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_internal_admin_branch(uuid,uuid,text,text,text,text,text,text,text,text,boolean) from public,anon,authenticated;
revoke all on function public.update_internal_admin_branch(uuid,uuid,uuid,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.list_internal_admin_branches(uuid,uuid) to service_role;
grant execute on function public.create_internal_admin_branch(uuid,uuid,text,text,text,text,text,text,text,text,boolean) to service_role;
grant execute on function public.update_internal_admin_branch(uuid,uuid,uuid,text,text,text,text,text,text,text,text) to service_role;

create or replace function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;v_currency text;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date;
 select case branch.country_code when 'AE' then 'AED' else 'SAR' end into strict v_currency from public.branches branch where branch.id=c.branch_id and branch.organization_id=c.organization_id;
 return pg_catalog.jsonb_build_object(
  'report_id',s.id,'business_date',c.business_date,'currency_code',coalesce(s.currency_code,v_currency),'state',coalesce(s.state,'draft'),'revision',coalesce(s.branch_revision,0),
  'submitted_at',s.submitted_at,'submitted_by_user_id',s.submitted_by_user_id,'submitted_by_name_snapshot',s.submitted_by_name_snapshot,
  'periods',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',p.id,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at)order by case p.entry_period when'middle_shift'then 1 else 2 end)from public.sales_tracking_period_entries p where p.report_id=s.id),'[]'::jsonb),
  'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'actual_cash',r.actual_cash,'actual_credit',r.actual_credit,'pos_cash',r.pos_cash,'pos_credit',r.pos_credit,'online_delivery',r.online_delivery,'online_amounts',private.sales_tracking_online_amounts_for_row(r.id),'remarks',r.remarks,'actual_total',r.actual_cash+r.actual_credit+r.online_delivery,'pos_total',r.pos_cash+r.pos_credit+r.online_delivery,'variance',(r.actual_cash+r.actual_credit+r.online_delivery)-(r.pos_cash+r.pos_credit+r.online_delivery))order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_sales_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,'denom_1',r.denom_1,'denom_2',r.denom_2,'denom_5',r.denom_5,'denom_10',r.denom_10,'denom_20',r.denom_20,'denom_50',r.denom_50,'denom_100',r.denom_100,'denom_200',r.denom_200,'denom_500',r.denom_500,'remaining_cash',r.remaining_cash,'remarks',r.remarks,'cash_total',r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_cash_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'totals',pg_catalog.jsonb_build_object('actual_cash',coalesce((select sum(r.actual_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'actual_credit',coalesce((select sum(r.actual_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_cash',coalesce((select sum(r.pos_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_credit',coalesce((select sum(r.pos_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'online_delivery',coalesce((select sum(r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'actual_total',coalesce((select sum(r.actual_cash+r.actual_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'pos_total',coalesce((select sum(r.pos_cash+r.pos_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'variance',coalesce((select sum((r.actual_cash+r.actual_credit)-(r.pos_cash+r.pos_credit))from public.sales_tracking_sales_rows r where r.report_id=s.id),0),'cash_total',coalesce((select sum(r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)from public.sales_tracking_cash_rows r where r.report_id=s.id),0),'remaining_cash',coalesce((select sum(r.remaining_cash)from public.sales_tracking_cash_rows r where r.report_id=s.id),0))
 );
exception when no_data_found or too_many_rows then raise exception'sales tracking state denied'using errcode='42501';end;
$$;

create or replace function public.list_managed_sales_tracking_reports(actor_user_id uuid,target_organization_id uuid,from_date date default null,to_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)or(from_date is not null and to_date is not null and from_date>to_date)then raise exception'sales tracking report access denied'using errcode='42501';end if;
 return pg_catalog.jsonb_build_object(
 'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,'actual_cash',x.actual_cash,'actual_credit',x.actual_credit,'pos_cash',x.pos_cash,'pos_credit',x.pos_credit,'online_delivery',x.online_delivery,'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.id,'provider_key',provider.default_provider_key,'provider_name',provider.name,'amount',amount.amount) order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.created_at,provider.name,provider.id)) from public.sales_tracking_online_amounts amount join public.sales_tracking_online_order_providers provider on provider.id=amount.provider_id where amount.sales_row_id=x.id and amount.amount<>0),'[]'::jsonb),'actual_total',x.actual_cash+x.actual_credit+x.online_delivery,'pos_total',x.pos_cash+x.pos_credit+x.online_delivery,'variance',(x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit),'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_sales_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb),
 'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,'denom_1',x.denom_1,'denom_2',x.denom_2,'denom_5',x.denom_5,'denom_10',x.denom_10,'denom_20',x.denom_20,'denom_50',x.denom_50,'denom_100',x.denom_100,'denom_200',x.denom_200,'denom_500',x.denom_500,'cash_total',x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500,'remaining_cash',x.remaining_cash,'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_cash_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb));
end;
$$;

revoke all on function public.get_sales_tracking_current_state(uuid,uuid),public.list_managed_sales_tracking_reports(uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function public.get_sales_tracking_current_state(uuid,uuid),public.list_managed_sales_tracking_reports(uuid,uuid,date,date) to service_role;

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
   coalesce((select pg_catalog.sum(row.actual_cash+row.actual_credit+row.online_delivery)from public.sales_tracking_sales_rows row where row.report_id=report.id),0::numeric)total_sales,
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
   coalesce(pg_catalog.sum(total_sales),0::numeric) total_sales,coalesce(pg_catalog.sum(total_cash_collected),0::numeric) total_cash_collected,coalesce(pg_catalog.sum(total_variance),0::numeric) total_variance,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)=0)::bigint balanced_sales_report_count,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)<>0)::bigint variance_sales_report_count,
   coalesce(pg_catalog.sum(actual_cash),0::numeric)actual_cash,coalesce(pg_catalog.sum(actual_credit),0::numeric)actual_credit,coalesce(pg_catalog.sum(online_delivery),0::numeric)online_delivery,coalesce(pg_catalog.sum(pos_cash),0::numeric)pos_cash,coalesce(pg_catalog.sum(pos_credit),0::numeric)pos_credit
  from metrics group by currency_code
 ),branch_totals as materialized(
  select branch_id,branch_name,branch_name_ar,branch_code,currency_code,pg_catalog.count(*)::bigint submitted_report_count,pg_catalog.count(distinct business_date)::bigint submitted_day_count,
   coalesce(pg_catalog.sum(sales_entry_count),0)::bigint sales_entry_count,coalesce(pg_catalog.sum(cash_entry_count),0)::bigint cash_entry_count,
   coalesce(pg_catalog.sum(total_sales),0::numeric)total_sales,coalesce(pg_catalog.sum(total_cash_collected),0::numeric)total_cash_collected,coalesce(pg_catalog.sum(total_variance),0::numeric)total_variance,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)=0)::bigint balanced_sales_report_count,
   pg_catalog.count(*)filter(where sales_entry_count>0 and pg_catalog.round(total_variance,2)<>0)::bigint variance_sales_report_count,
   coalesce(pg_catalog.sum(actual_cash),0::numeric)actual_cash,coalesce(pg_catalog.sum(actual_credit),0::numeric)actual_credit,coalesce(pg_catalog.sum(online_delivery),0::numeric)online_delivery,coalesce(pg_catalog.sum(pos_cash),0::numeric)pos_cash,coalesce(pg_catalog.sum(pos_credit),0::numeric)pos_credit
  from metrics group by branch_id,branch_name,branch_name_ar,branch_code,currency_code
 )
 select pg_catalog.jsonb_build_object(
  'generated_at',pg_catalog.statement_timestamp(),
  'scope',pg_catalog.jsonb_build_object('organization_id',target_organization_id,'branch_id',branch_filter,'month',pg_catalog.to_char(target_month,'YYYY-MM'),'date_from',target_month,'date_to',(target_month+interval '1 month - 1 day')::date),
  'currency_totals',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('currency_code',total.currency_code,'submitted_report_count',total.submitted_report_count,'submitted_branch_day_count',total.submitted_branch_day_count,'reporting_branch_count',total.reporting_branch_count,'sales_entry_count',total.sales_entry_count,'cash_entry_count',total.cash_entry_count,'total_sales',total.total_sales::text,'total_cash_collected',total.total_cash_collected::text,'total_variance',total.total_variance::text,'balanced_sales_report_count',total.balanced_sales_report_count,'variance_sales_report_count',total.variance_sales_report_count,'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash',total.actual_cash::text,'actual_credit',total.actual_credit::text,'online_delivery',total.online_delivery::text,'pos_cash',total.pos_cash::text,'pos_credit',total.pos_credit::text),'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.first_provider_id,'provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text)order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id))from provider_totals provider where provider.currency_code=total.currency_code),'[]'::jsonb),'legacy_online_delivery',coalesce((select pg_catalog.sum(legacy.amount)::text from legacy_online legacy where legacy.currency_code=total.currency_code),'0'))order by total.currency_code)from currency_totals total),'[]'::jsonb),
  'branches',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('branch_id',branch.branch_id,'branch_name',branch.branch_name,'branch_name_ar',branch.branch_name_ar,'branch_code',branch.branch_code,'currency_code',branch.currency_code,'submitted_report_count',branch.submitted_report_count,'submitted_day_count',branch.submitted_day_count,'sales_entry_count',branch.sales_entry_count,'cash_entry_count',branch.cash_entry_count,'total_sales',branch.total_sales::text,'total_cash_collected',branch.total_cash_collected::text,'total_variance',branch.total_variance::text,'balanced_sales_report_count',branch.balanced_sales_report_count,'variance_sales_report_count',branch.variance_sales_report_count,'payment_breakdown',pg_catalog.jsonb_build_object('actual_cash',branch.actual_cash::text,'actual_credit',branch.actual_credit::text,'online_delivery',branch.online_delivery::text,'pos_cash',branch.pos_cash::text,'pos_credit',branch.pos_credit::text),'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.first_provider_id,'provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text)order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id))from provider_amounts provider where provider.currency_code=branch.currency_code and provider.branch_id=branch.branch_id),'[]'::jsonb),'legacy_online_delivery',coalesce((select legacy.amount::text from legacy_online legacy where legacy.currency_code=branch.currency_code and legacy.branch_id=branch.branch_id),'0'))order by branch.branch_name,branch.currency_code,branch.branch_id)from branch_totals branch),'[]'::jsonb)
 )into result;
 return result;
end;
$$;

revoke all on function public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid) to service_role;

