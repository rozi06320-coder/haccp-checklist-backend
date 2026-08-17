-- Manager read-only Sales Tracking online provider breakdown.

create or replace function public.list_managed_sales_tracking_reports(actor_user_id uuid,target_organization_id uuid,from_date date default null,to_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)or(from_date is not null and to_date is not null and from_date>to_date)then raise exception'sales tracking report access denied'using errcode='42501';end if;
 return pg_catalog.jsonb_build_object(
 'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'report_id',r.id,'row_id',x.id,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,
   'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,
   'actual_cash',x.actual_cash,'actual_credit',x.actual_credit,'pos_cash',x.pos_cash,'pos_credit',x.pos_credit,'online_delivery',x.online_delivery,
   'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.id,'provider_key',provider.default_provider_key,'provider_name',provider.name,'amount',amount.amount) order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.created_at,provider.name,provider.id)) from public.sales_tracking_online_amounts amount join public.sales_tracking_online_order_providers provider on provider.id=amount.provider_id where amount.sales_row_id=x.id and amount.amount<>0),'[]'::jsonb),
   'actual_total',x.actual_cash+x.actual_credit+x.online_delivery,'pos_total',x.pos_cash+x.pos_credit+x.online_delivery,'variance',(x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit),'remarks',x.remarks
 )order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_sales_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb),
 'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('report_id',r.id,'row_id',x.id,'business_date',r.business_date,'entry_date',x.entry_date,'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,'denom_1',x.denom_1,'denom_2',x.denom_2,'denom_5',x.denom_5,'denom_10',x.denom_10,'denom_20',x.denom_20,'denom_50',x.denom_50,'denom_100',x.denom_100,'denom_200',x.denom_200,'denom_500',x.denom_500,'cash_total',x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500,'remaining_cash',x.remaining_cash,'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)from public.sales_tracking_reports r join public.sales_tracking_cash_rows x on x.report_id=r.id left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb));
end$$;

create or replace function public.get_managed_sales_tracking_monthly_summary(
  actor_user_id uuid,
  target_organization_id uuid,
  target_month date,
  branch_filter uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  if target_month is null or target_month <> pg_catalog.date_trunc('month', target_month)::date then
    raise exception 'invalid sales tracking month' using errcode = '22023';
  end if;
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'sales tracking monthly summary access denied' using errcode = '42501';
  end if;
  if branch_filter is not null and not exists (select 1 from public.branches branch where branch.id = branch_filter and branch.organization_id = target_organization_id) then
    raise exception 'sales tracking monthly summary branch denied' using errcode = '42501';
  end if;

  with
  scoped_reports as materialized (
    select report.id, report.branch_id, report.business_date, branch.name branch_name, branch.name_ar branch_name_ar, branch.code branch_code
    from public.sales_tracking_reports report
    join public.branches branch on branch.id = report.branch_id and branch.organization_id = report.organization_id
    where report.organization_id = target_organization_id and report.state = 'submitted' and report.submitted_at is not null
      and report.business_date >= target_month and report.business_date < (target_month + interval '1 month')::date
      and (branch_filter is null or report.branch_id = branch_filter)
  ),
  sales_by_report as materialized (
    select report.id report_id, pg_catalog.count(row.id)::bigint sales_entry_count,
      coalesce(pg_catalog.sum(row.actual_cash), 0::numeric) actual_cash,
      coalesce(pg_catalog.sum(row.actual_credit), 0::numeric) actual_credit,
      coalesce(pg_catalog.sum(row.online_delivery), 0::numeric) online_delivery,
      coalesce(pg_catalog.sum(row.pos_cash), 0::numeric) pos_cash,
      coalesce(pg_catalog.sum(row.pos_credit), 0::numeric) pos_credit
    from scoped_reports report left join public.sales_tracking_sales_rows row on row.report_id = report.id
    group by report.id
  ),
  cash_by_report as materialized (
    select report.id report_id, pg_catalog.count(row.id)::bigint cash_entry_count,
      coalesce(pg_catalog.sum(row.denom_1 + row.denom_2 * 2 + row.denom_5 * 5 + row.denom_10 * 10 + row.denom_20 * 20 + row.denom_50 * 50 + row.denom_100 * 100 + row.denom_200 * 200 + row.denom_500 * 500), 0::bigint)::numeric total_cash_collected
    from scoped_reports report left join public.sales_tracking_cash_rows row on row.report_id = report.id
    group by report.id
  ),
  report_metrics as materialized (
    select report.id, report.branch_id, report.business_date, report.branch_name, report.branch_name_ar, report.branch_code,
      sales.sales_entry_count, cash.cash_entry_count, sales.actual_cash, sales.actual_credit, sales.online_delivery, sales.pos_cash, sales.pos_credit,
      sales.actual_cash + sales.actual_credit + sales.online_delivery total_sales,
      sales.actual_cash + sales.actual_credit - sales.pos_cash - sales.pos_credit total_variance,
      cash.total_cash_collected
    from scoped_reports report join sales_by_report sales on sales.report_id = report.id join cash_by_report cash on cash.report_id = report.id
  ),
  provider_amounts as materialized (
    select report.branch_id, provider.default_provider_key, provider.normalized_name, min(provider.name) provider_name, bool_or(provider.is_default) is_default, min(provider.created_at) first_created_at, min(provider.id::text)::uuid first_provider_id, sum(amount.amount) amount
    from scoped_reports report
    join public.sales_tracking_sales_rows row on row.report_id = report.id
    join public.sales_tracking_online_amounts amount on amount.sales_row_id = row.id and amount.amount <> 0
    join public.sales_tracking_online_order_providers provider on provider.id = amount.provider_id
    group by report.branch_id, provider.default_provider_key, provider.normalized_name
  ),
  provider_totals as materialized (
    select default_provider_key, normalized_name, min(provider_name) provider_name, bool_or(is_default) is_default, min(first_created_at) first_created_at, min(first_provider_id::text)::uuid first_provider_id, sum(amount) amount
    from provider_amounts
    group by default_provider_key, normalized_name
  ),
  legacy_online as materialized (
    select coalesce(sum(row.online_delivery),0::numeric) amount
    from scoped_reports report
    join public.sales_tracking_sales_rows row on row.report_id = report.id
    where not exists (select 1 from public.sales_tracking_online_amounts amount where amount.sales_row_id = row.id)
  ),
  branch_legacy_online as materialized (
    select report.branch_id, coalesce(sum(row.online_delivery),0::numeric) amount
    from scoped_reports report
    join public.sales_tracking_sales_rows row on row.report_id = report.id
    where not exists (select 1 from public.sales_tracking_online_amounts amount where amount.sales_row_id = row.id)
    group by report.branch_id
  ),
  totals as materialized (
    select pg_catalog.count(*)::bigint submitted_report_count, pg_catalog.count(distinct (branch_id, business_date))::bigint submitted_branch_day_count, pg_catalog.count(distinct branch_id)::bigint reporting_branch_count,
      coalesce(pg_catalog.sum(sales_entry_count), 0::numeric)::bigint sales_entry_count, coalesce(pg_catalog.sum(cash_entry_count), 0::numeric)::bigint cash_entry_count,
      coalesce(pg_catalog.sum(total_sales), 0::numeric) total_sales, coalesce(pg_catalog.sum(total_cash_collected), 0::numeric) total_cash_collected, coalesce(pg_catalog.sum(total_variance), 0::numeric) total_variance,
      pg_catalog.count(*) filter (where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) = 0)::bigint balanced_sales_report_count,
      pg_catalog.count(*) filter (where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) <> 0)::bigint variance_sales_report_count,
      coalesce(pg_catalog.sum(actual_cash), 0::numeric) actual_cash, coalesce(pg_catalog.sum(actual_credit), 0::numeric) actual_credit, coalesce(pg_catalog.sum(online_delivery), 0::numeric) online_delivery, coalesce(pg_catalog.sum(pos_cash), 0::numeric) pos_cash, coalesce(pg_catalog.sum(pos_credit), 0::numeric) pos_credit
    from report_metrics
  ),
  branch_totals as materialized (
    select branch_id, branch_name, branch_name_ar, branch_code, pg_catalog.count(*)::bigint submitted_report_count, pg_catalog.count(distinct business_date)::bigint submitted_day_count,
      coalesce(pg_catalog.sum(sales_entry_count), 0::numeric)::bigint sales_entry_count, coalesce(pg_catalog.sum(cash_entry_count), 0::numeric)::bigint cash_entry_count,
      coalesce(pg_catalog.sum(total_sales), 0::numeric) total_sales, coalesce(pg_catalog.sum(total_cash_collected), 0::numeric) total_cash_collected, coalesce(pg_catalog.sum(total_variance), 0::numeric) total_variance,
      pg_catalog.count(*) filter (where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) = 0)::bigint balanced_sales_report_count,
      pg_catalog.count(*) filter (where sales_entry_count > 0 and pg_catalog.round(total_variance, 2) <> 0)::bigint variance_sales_report_count,
      coalesce(pg_catalog.sum(actual_cash), 0::numeric) actual_cash, coalesce(pg_catalog.sum(actual_credit), 0::numeric) actual_credit, coalesce(pg_catalog.sum(online_delivery), 0::numeric) online_delivery, coalesce(pg_catalog.sum(pos_cash), 0::numeric) pos_cash, coalesce(pg_catalog.sum(pos_credit), 0::numeric) pos_credit
    from report_metrics
    group by branch_id, branch_name, branch_name_ar, branch_code
  )
  select pg_catalog.jsonb_build_object(
    'generated_at', pg_catalog.statement_timestamp(),
    'scope', pg_catalog.jsonb_build_object('organization_id', target_organization_id, 'branch_id', branch_filter, 'month', pg_catalog.to_char(target_month, 'YYYY-MM'), 'date_from', target_month, 'date_to', (target_month + interval '1 month - 1 day')::date),
    'totals', pg_catalog.jsonb_build_object(
      'submitted_report_count', totals.submitted_report_count, 'submitted_branch_day_count', totals.submitted_branch_day_count, 'reporting_branch_count', totals.reporting_branch_count,
      'sales_entry_count', totals.sales_entry_count, 'cash_entry_count', totals.cash_entry_count, 'total_sales', totals.total_sales::text, 'total_cash_collected', totals.total_cash_collected::text, 'total_variance', totals.total_variance::text,
      'balanced_sales_report_count', totals.balanced_sales_report_count, 'variance_sales_report_count', totals.variance_sales_report_count,
      'payment_breakdown', pg_catalog.jsonb_build_object('actual_cash', totals.actual_cash::text, 'actual_credit', totals.actual_credit::text, 'online_delivery', totals.online_delivery::text, 'pos_cash', totals.pos_cash::text, 'pos_credit', totals.pos_credit::text),
      'online_provider_breakdown', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text) order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id)) from provider_totals provider),'[]'::jsonb),
      'legacy_online_delivery', (select amount::text from legacy_online)
    ),
    'branches', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'branch_id', branch.branch_id, 'branch_name', branch.branch_name, 'branch_name_ar', branch.branch_name_ar, 'branch_code', branch.branch_code,
        'submitted_report_count', branch.submitted_report_count, 'submitted_day_count', branch.submitted_day_count, 'sales_entry_count', branch.sales_entry_count, 'cash_entry_count', branch.cash_entry_count,
        'total_sales', branch.total_sales::text, 'total_cash_collected', branch.total_cash_collected::text, 'total_variance', branch.total_variance::text,
        'balanced_sales_report_count', branch.balanced_sales_report_count, 'variance_sales_report_count', branch.variance_sales_report_count,
        'payment_breakdown', pg_catalog.jsonb_build_object('actual_cash', branch.actual_cash::text, 'actual_credit', branch.actual_credit::text, 'online_delivery', branch.online_delivery::text, 'pos_cash', branch.pos_cash::text, 'pos_credit', branch.pos_credit::text),
        'online_provider_breakdown', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('provider_id',provider.first_provider_id,'provider_key',provider.default_provider_key,'provider_name',provider.provider_name,'amount',provider.amount::text) order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.first_created_at,provider.provider_name,provider.first_provider_id)) from provider_amounts provider where provider.branch_id=branch.branch_id),'[]'::jsonb),
        'legacy_online_delivery', coalesce((select legacy.amount::text from branch_legacy_online legacy where legacy.branch_id=branch.branch_id),'0')
      ) order by branch.branch_name, branch.branch_id)
      from branch_totals branch
    ), '[]'::jsonb)
  ) into result
  from totals;

  return result;
end $$;

revoke all on function public.list_managed_sales_tracking_reports(uuid,uuid,date,date),
  public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)
  from public, anon, authenticated;
grant execute on function public.list_managed_sales_tracking_reports(uuid,uuid,date,date),
  public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid)
  to service_role;
