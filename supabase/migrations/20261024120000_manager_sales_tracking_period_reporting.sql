begin;

-- OPERATIONAL INDEX ROLLOUT NOTICE:
-- To prevent transactional SHARE lock contention and blocking writes on sales_tracking_report_cases
-- during deployment, this functional migration does not create the optional supporting index.
-- Existing unique constraint sales_tracking_report_cases_branch_day_key covers branch-scoped queries.
-- For organizations with extensive cross-branch historical volume, execute the following command
-- concurrently in production outside of a migration transaction block prior to rollout:
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS sales_tracking_report_cases_org_date_branch_idx
--     ON public.sales_tracking_report_cases(organization_id, business_date, branch_id)
--     INCLUDE (authoritative_report_id);

create or replace function public.get_managed_sales_tracking_period_summary(
  actor_user_id uuid,
  target_organization_id uuid,
  from_date date,
  to_date date,
  branch_filter uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  result jsonb;
begin
  if from_date is null or to_date is null or from_date > to_date or to_date - from_date > 365 then
    raise exception 'invalid sales tracking period' using errcode='22023';
  end if;
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id) then
    raise exception 'sales tracking period access denied' using errcode='42501';
  end if;
  if branch_filter is not null
    and not private.managed_active_branch(actor_user_id,target_organization_id,branch_filter)
  then
    raise exception 'sales tracking period branch denied' using errcode='42501';
  end if;

  with scoped_reports as materialized (
    select
      report.id,
      report.branch_id,
      report.business_date,
      report.currency_code,
      branch.name as branch_name,
      branch.name_ar as branch_name_ar,
      branch.code as branch_code
    from public.sales_tracking_report_cases as report_case
    join public.sales_tracking_reports as report
      on report.id=report_case.authoritative_report_id
      and report.case_id=report_case.id
      and report.organization_id=report_case.organization_id
      and report.branch_id=report_case.branch_id
      and report.business_date=report_case.business_date
    join public.branches as branch
      on branch.id=report.branch_id
      and branch.organization_id=report.organization_id
    where report_case.organization_id=target_organization_id
      and report_case.business_date between from_date and to_date
      and (branch_filter is null or report_case.branch_id=branch_filter)
      and report.state='submitted'
      and report.submitted_at is not null
  ),
  report_metrics as materialized (
    select
      report.*,
      coalesce(sales.sales_entry_count,0)::bigint as sales_entry_count,
      coalesce(cash.cash_entry_count,0)::bigint as cash_entry_count,
      coalesce(photo.evidence_photo_count,0)::bigint as evidence_photo_count,
      coalesce(sales.actual_cash,0::numeric) as actual_cash,
      coalesce(sales.actual_credit,0::numeric) as actual_credit,
      coalesce(sales.online_delivery,0::numeric) as online_delivery,
      coalesce(sales.pos_cash,0::numeric) as pos_cash,
      coalesce(sales.pos_credit,0::numeric) as pos_credit,
      coalesce(sales.gross_sales,0::numeric) as gross_sales,
      coalesce(sales.refund_total,0::numeric) as refund_total,
      coalesce(sales.net_sales,0::numeric) as net_sales,
      coalesce(sales.variance,0::numeric) as variance,
      coalesce(cash.counted_cash_total,0::numeric) as counted_cash_total
    from scoped_reports as report
    left join lateral (
      select
        pg_catalog.count(*)::bigint as sales_entry_count,
        pg_catalog.sum(row.actual_cash) as actual_cash,
        pg_catalog.sum(row.actual_credit) as actual_credit,
        pg_catalog.sum(row.online_delivery) as online_delivery,
        pg_catalog.sum(row.pos_cash) as pos_cash,
        pg_catalog.sum(row.pos_credit) as pos_credit,
        pg_catalog.sum(row.actual_cash+row.actual_credit+row.online_delivery) as gross_sales,
        pg_catalog.sum(row.refund_total) as refund_total,
        pg_catalog.sum(row.actual_cash+row.actual_credit+row.online_delivery-row.refund_total) as net_sales,
        pg_catalog.sum((row.actual_cash+row.actual_credit)-(row.pos_cash+row.pos_credit)) as variance
      from public.sales_tracking_sales_rows as row
      where row.report_id=report.id
    ) as sales on true
    left join lateral (
      select
        pg_catalog.count(*)::bigint as cash_entry_count,
        pg_catalog.sum(
          row.denom_1+row.denom_2*2+row.denom_5*5+row.denom_10*10+
          row.denom_20*20+row.denom_50*50+row.denom_100*100+
          row.denom_200*200+row.denom_500*500
        ) as counted_cash_total
      from public.sales_tracking_cash_rows as row
      where row.report_id=report.id
    ) as cash on true
    left join lateral (
      select pg_catalog.count(*)::bigint as evidence_photo_count
      from public.sales_tracking_attachments as attachment
      where attachment.report_id=report.id and attachment.deleted_at is null
    ) as photo on true
  ),
  provider_amounts as materialized (
    select
      report.currency_code,
      report.branch_id,
      case
        when provider.default_provider_key is not null then 'default:'||provider.default_provider_key
        else 'custom:'||provider.normalized_name
      end as identity_key,
      provider.default_provider_key as provider_key,
      provider.normalized_name,
      pg_catalog.min(provider.name) as display_name,
      pg_catalog.sum(amount.amount) as amount
    from scoped_reports as report
    join public.sales_tracking_sales_rows as sales_row on sales_row.report_id=report.id
    join public.sales_tracking_online_amounts as amount
      on amount.sales_row_id=sales_row.id and amount.amount<>0
    join public.sales_tracking_online_order_providers as provider on provider.id=amount.provider_id
    group by report.currency_code,report.branch_id,
      case
        when provider.default_provider_key is not null then 'default:'||provider.default_provider_key
        else 'custom:'||provider.normalized_name
      end,
      provider.default_provider_key,provider.normalized_name
  ),
  currency_providers as materialized (
    select currency_code,identity_key,provider_key,normalized_name,
      pg_catalog.min(display_name) as display_name,pg_catalog.sum(amount) as amount
    from provider_amounts
    group by currency_code,identity_key,provider_key,normalized_name
  ),
  legacy_online as materialized (
    select report.currency_code,report.branch_id,pg_catalog.sum(sales_row.online_delivery) as amount
    from scoped_reports as report
    join public.sales_tracking_sales_rows as sales_row on sales_row.report_id=report.id
    where not exists (
      select 1 from public.sales_tracking_online_amounts as amount
      where amount.sales_row_id=sales_row.id
    )
    group by report.currency_code,report.branch_id
  ),
  currency_totals as materialized (
    select
      metric.currency_code,
      pg_catalog.count(*)::bigint as submitted_report_count,
      pg_catalog.count(distinct metric.business_date)::bigint as submitted_business_day_count,
      pg_catalog.count(distinct (metric.branch_id,metric.business_date))::bigint as submitted_branch_day_count,
      pg_catalog.count(distinct metric.branch_id)::bigint as reporting_branch_count,
      pg_catalog.sum(metric.sales_entry_count)::bigint as sales_entry_count,
      pg_catalog.sum(metric.cash_entry_count)::bigint as cash_entry_count,
      pg_catalog.count(*) filter(where metric.evidence_photo_count>0)::bigint as reports_with_photos_count,
      pg_catalog.sum(metric.evidence_photo_count)::bigint as evidence_photo_count,
      pg_catalog.sum(metric.gross_sales) as gross_sales,
      pg_catalog.sum(metric.refund_total) as refund_total,
      pg_catalog.sum(metric.net_sales) as net_sales,
      pg_catalog.sum(metric.actual_cash) as actual_cash,
      pg_catalog.sum(metric.actual_credit) as actual_credit,
      pg_catalog.sum(metric.online_delivery) as online_delivery,
      pg_catalog.sum(metric.pos_cash) as pos_cash,
      pg_catalog.sum(metric.pos_credit) as pos_credit,
      pg_catalog.sum(metric.variance) as variance,
      pg_catalog.sum(metric.counted_cash_total) as counted_cash_total,
      pg_catalog.count(*) filter(where metric.sales_entry_count>0 and pg_catalog.round(metric.variance,2)=0)::bigint as balanced_report_count,
      pg_catalog.count(*) filter(where metric.sales_entry_count>0 and pg_catalog.round(metric.variance,2)<>0)::bigint as variance_report_count
    from report_metrics as metric
    group by metric.currency_code
  ),
  branch_totals as materialized (
    select
      metric.branch_id,metric.branch_name,metric.branch_name_ar,metric.branch_code,metric.currency_code,
      pg_catalog.count(*)::bigint as submitted_report_count,
      pg_catalog.count(distinct metric.business_date)::bigint as submitted_business_day_count,
      pg_catalog.sum(metric.sales_entry_count)::bigint as sales_entry_count,
      pg_catalog.sum(metric.cash_entry_count)::bigint as cash_entry_count,
      pg_catalog.count(*) filter(where metric.evidence_photo_count>0)::bigint as reports_with_photos_count,
      pg_catalog.sum(metric.evidence_photo_count)::bigint as evidence_photo_count,
      pg_catalog.sum(metric.gross_sales) as gross_sales,
      pg_catalog.sum(metric.refund_total) as refund_total,
      pg_catalog.sum(metric.net_sales) as net_sales,
      pg_catalog.sum(metric.actual_cash) as actual_cash,
      pg_catalog.sum(metric.actual_credit) as actual_credit,
      pg_catalog.sum(metric.online_delivery) as online_delivery,
      pg_catalog.sum(metric.pos_cash) as pos_cash,
      pg_catalog.sum(metric.pos_credit) as pos_credit,
      pg_catalog.sum(metric.variance) as variance,
      pg_catalog.sum(metric.counted_cash_total) as counted_cash_total,
      pg_catalog.count(*) filter(where metric.sales_entry_count>0 and pg_catalog.round(metric.variance,2)=0)::bigint as balanced_report_count,
      pg_catalog.count(*) filter(where metric.sales_entry_count>0 and pg_catalog.round(metric.variance,2)<>0)::bigint as variance_report_count
    from report_metrics as metric
    group by metric.branch_id,metric.branch_name,metric.branch_name_ar,metric.branch_code,metric.currency_code
  )
  select pg_catalog.jsonb_build_object(
    'generated_at',pg_catalog.statement_timestamp(),
    'state',case when exists(select 1 from scoped_reports)then'complete'else'empty'end,
    'scope',pg_catalog.jsonb_build_object(
      'organization_id',target_organization_id,'branch_id',branch_filter,
      'date_from',from_date,'date_to',to_date
    ),
    'currency_summaries',coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'currency_code',total.currency_code,
        'submitted_report_count',total.submitted_report_count,
        'submitted_business_day_count',total.submitted_business_day_count,
        'submitted_branch_day_count',total.submitted_branch_day_count,
        'reporting_branch_count',total.reporting_branch_count,
        'sales_entry_count',total.sales_entry_count,
        'cash_entry_count',total.cash_entry_count,
        'reports_with_photos_count',total.reports_with_photos_count,
        'evidence_photo_count',total.evidence_photo_count,
        'gross_sales',total.gross_sales::text,
        'refund_total',total.refund_total::text,
        'net_sales',total.net_sales::text,
        'actual_payments',pg_catalog.jsonb_build_object(
          'cash',total.actual_cash::text,'credit',total.actual_credit::text,
          'online',total.online_delivery::text,
          'total',(total.actual_cash+total.actual_credit+total.online_delivery)::text
        ),
        'pos_reconciliation',pg_catalog.jsonb_build_object(
          'cash',total.pos_cash::text,'credit',total.pos_credit::text,
          'online',total.online_delivery::text,
          'total',(total.pos_cash+total.pos_credit+total.online_delivery)::text,
          'variance',total.variance::text
        ),
        'counted_cash_total',total.counted_cash_total::text,
        'balanced_report_count',total.balanced_report_count,
        'variance_report_count',total.variance_report_count,
        'provider_breakdown',coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'identity_key',provider.identity_key,'provider_key',provider.provider_key,
            'normalized_name',provider.normalized_name,'display_name',provider.display_name,
            'amount',provider.amount::text
          )order by provider.identity_key)
          from currency_providers as provider
          where provider.currency_code=total.currency_code
        ),'[]'::jsonb),
        'unspecified_online_delivery',coalesce((
          select pg_catalog.sum(legacy.amount)::text from legacy_online as legacy
          where legacy.currency_code=total.currency_code
        ),'0')
      )order by total.currency_code)
      from currency_totals as total
    ),'[]'::jsonb),
    'branches',coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'branch_id',total.branch_id,'branch_name',total.branch_name,
        'branch_name_ar',total.branch_name_ar,'branch_code',total.branch_code,
        'currency_code',total.currency_code,
        'submitted_report_count',total.submitted_report_count,
        'submitted_business_day_count',total.submitted_business_day_count,
        'sales_entry_count',total.sales_entry_count,
        'cash_entry_count',total.cash_entry_count,
        'reports_with_photos_count',total.reports_with_photos_count,
        'evidence_photo_count',total.evidence_photo_count,
        'gross_sales',total.gross_sales::text,
        'refund_total',total.refund_total::text,
        'net_sales',total.net_sales::text,
        'actual_payments',pg_catalog.jsonb_build_object(
          'cash',total.actual_cash::text,'credit',total.actual_credit::text,
          'online',total.online_delivery::text,
          'total',(total.actual_cash+total.actual_credit+total.online_delivery)::text
        ),
        'pos_reconciliation',pg_catalog.jsonb_build_object(
          'cash',total.pos_cash::text,'credit',total.pos_credit::text,
          'online',total.online_delivery::text,
          'total',(total.pos_cash+total.pos_credit+total.online_delivery)::text,
          'variance',total.variance::text
        ),
        'counted_cash_total',total.counted_cash_total::text,
        'balanced_report_count',total.balanced_report_count,
        'variance_report_count',total.variance_report_count,
        'provider_breakdown',coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'identity_key',provider.identity_key,'provider_key',provider.provider_key,
            'normalized_name',provider.normalized_name,'display_name',provider.display_name,
            'amount',provider.amount::text
          )order by provider.identity_key)
          from provider_amounts as provider
          where provider.currency_code=total.currency_code and provider.branch_id=total.branch_id
        ),'[]'::jsonb),
        'unspecified_online_delivery',coalesce((
          select legacy.amount::text from legacy_online as legacy
          where legacy.currency_code=total.currency_code and legacy.branch_id=total.branch_id
        ),'0')
      )order by total.branch_name,total.currency_code,total.branch_id)
      from branch_totals as total
    ),'[]'::jsonb)
  ) into result;

  return result;
end
$$;

drop function if exists public.list_managed_sales_tracking_period_evidence(
  uuid,uuid,date,date,uuid,integer,date,uuid,uuid,smallint,uuid
);

create or replace function public.list_managed_sales_tracking_period_evidence(
  actor_user_id uuid,
  target_organization_id uuid,
  from_date date,
  to_date date,
  branch_filter uuid,
  requested_limit integer,
  cursor_business_date date default null,
  cursor_branch_id uuid default null,
  cursor_report_id uuid default null,
  cursor_display_order smallint default null,
  cursor_attachment_id uuid default null,
  cursor_authority_revision text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  cursor_count integer;
  current_authority_revision text;
begin
  if from_date is null or to_date is null or from_date > to_date or to_date-from_date>365
    or requested_limit is null or requested_limit<1 or requested_limit>51
  then
    raise exception 'invalid sales tracking evidence period' using errcode='22023';
  end if;
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id) then
    raise exception 'sales tracking evidence access denied' using errcode='42501';
  end if;
  if branch_filter is not null
    and not private.managed_active_branch(actor_user_id,target_organization_id,branch_filter)
  then
    raise exception 'sales tracking evidence branch denied' using errcode='42501';
  end if;

  select pg_catalog.md5(coalesce(
    pg_catalog.string_agg(
      report_case.business_date::text || ':' || report_case.branch_id::text || ':' || report_case.authoritative_report_id::text,
      ',' order by report_case.business_date, report_case.branch_id
    ),
    'empty'
  ))
  into current_authority_revision
  from public.sales_tracking_report_cases as report_case
  join public.sales_tracking_reports as report
    on report.id=report_case.authoritative_report_id
    and report.case_id=report_case.id
    and report.organization_id=report_case.organization_id
    and report.branch_id=report_case.branch_id
    and report.business_date=report_case.business_date
  where report_case.organization_id=target_organization_id
    and report_case.business_date between from_date and to_date
    and (branch_filter is null or report_case.branch_id=branch_filter)
    and report.state='submitted'
    and report.submitted_at is not null;

  if cursor_authority_revision is not null and cursor_authority_revision <> current_authority_revision then
    raise exception 'sales tracking evidence authority changed' using errcode='40001';
  end if;

  cursor_count:=
    (cursor_business_date is not null)::integer+
    (cursor_branch_id is not null)::integer+
    (cursor_report_id is not null)::integer+
    (cursor_display_order is not null)::integer+
    (cursor_attachment_id is not null)::integer;
  if cursor_count not in(0,5) then
    raise exception 'invalid sales tracking evidence cursor' using errcode='22023';
  end if;

  return pg_catalog.jsonb_build_object(
    'authority_revision',current_authority_revision,
    'items',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'attachment_id',item.attachment_id,
      'report_id',item.report_id,
      'business_date',item.business_date,
      'branch_id',item.branch_id,
      'branch_name',item.branch_name,
      'branch_name_ar',item.branch_name_ar,
      'branch_code',item.branch_code,
      'display_order',item.display_order,
      'original_filename',item.original_filename,
      'mime_type',item.mime_type,
      'size_bytes',item.size_bytes,
      'created_at',item.created_at,
      'storage_path',item.storage_path
    )order by item.business_date desc,item.branch_id,item.report_id,item.display_order,item.attachment_id)
    from (
      select
        attachment.id as attachment_id,
        report.id as report_id,
        report.business_date,
        report.branch_id,
        branch.name as branch_name,
        branch.name_ar as branch_name_ar,
        branch.code as branch_code,
        attachment.display_order,
        attachment.original_filename,
        attachment.mime_type,
        attachment.size_bytes,
        attachment.created_at,
        attachment.storage_path
      from public.sales_tracking_report_cases as report_case
      join public.sales_tracking_reports as report
        on report.id=report_case.authoritative_report_id
        and report.case_id=report_case.id
        and report.organization_id=report_case.organization_id
        and report.branch_id=report_case.branch_id
        and report.business_date=report_case.business_date
      join public.branches as branch
        on branch.id=report.branch_id and branch.organization_id=report.organization_id
      join public.sales_tracking_attachments as attachment
        on attachment.report_id=report.id
        and attachment.organization_id=report.organization_id
        and attachment.branch_id=report.branch_id
        and attachment.deleted_at is null
      where report_case.organization_id=target_organization_id
        and report_case.business_date between from_date and to_date
        and (branch_filter is null or report_case.branch_id=branch_filter)
        and report.state='submitted'
        and report.submitted_at is not null
        and (
          cursor_count=0
          or report.business_date<cursor_business_date
          or (report.business_date=cursor_business_date and report.branch_id>cursor_branch_id)
          or (report.business_date=cursor_business_date and report.branch_id=cursor_branch_id and report.id>cursor_report_id)
          or (report.business_date=cursor_business_date and report.branch_id=cursor_branch_id and report.id=cursor_report_id and attachment.display_order>cursor_display_order)
          or (report.business_date=cursor_business_date and report.branch_id=cursor_branch_id and report.id=cursor_report_id and attachment.display_order=cursor_display_order and attachment.id>cursor_attachment_id)
        )
      order by report.business_date desc,report.branch_id,report.id,attachment.display_order,attachment.id
      limit requested_limit
    ) as item
  ),'[]'::jsonb));
end
$$;

create or replace function public.authorize_managed_sales_tracking_evidence_renewal(
  actor_user_id uuid,
  target_organization_id uuid,
  from_date date,
  to_date date,
  branch_filter uuid,
  target_attachment_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
begin
  if from_date is null or to_date is null or from_date>to_date or to_date-from_date>365
    or coalesce(pg_catalog.cardinality(target_attachment_ids),0)<1
    or pg_catalog.cardinality(target_attachment_ids)>50
    or exists(
      select 1 from pg_catalog.unnest(target_attachment_ids) as item(id)
      group by item.id having pg_catalog.count(*)>1
    )
  then
    raise exception 'invalid sales tracking evidence renewal' using errcode='22023';
  end if;
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id) then
    raise exception 'sales tracking evidence renewal denied' using errcode='42501';
  end if;
  if branch_filter is not null
    and not private.managed_active_branch(actor_user_id,target_organization_id,branch_filter)
  then
    raise exception 'sales tracking evidence renewal branch denied' using errcode='42501';
  end if;

  return pg_catalog.jsonb_build_object('items',coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'attachment_id',attachment.id,
      'storage_path',attachment.storage_path
    )order by requested.ordinality)
    from pg_catalog.unnest(target_attachment_ids)with ordinality as requested(id,ordinality)
    join public.sales_tracking_attachments as attachment
      on attachment.id=requested.id and attachment.deleted_at is null
    join public.sales_tracking_reports as report
      on report.id=attachment.report_id
      and report.organization_id=attachment.organization_id
      and report.branch_id=attachment.branch_id
    join public.sales_tracking_report_cases as report_case
      on report_case.id=report.case_id
      and report_case.authoritative_report_id=report.id
      and report_case.organization_id=target_organization_id
      and report_case.branch_id=report.branch_id
      and report_case.business_date=report.business_date
    where report.state='submitted'
      and report.submitted_at is not null
      and report.business_date between from_date and to_date
      and (branch_filter is null or report.branch_id=branch_filter)
  ),'[]'::jsonb));
end
$$;

revoke all on function public.get_managed_sales_tracking_period_summary(uuid,uuid,date,date,uuid) from public,anon,authenticated;
revoke all on function public.list_managed_sales_tracking_period_evidence(uuid,uuid,date,date,uuid,integer,date,uuid,uuid,smallint,uuid,text) from public,anon,authenticated;
revoke all on function public.authorize_managed_sales_tracking_evidence_renewal(uuid,uuid,date,date,uuid,uuid[]) from public,anon,authenticated;

grant execute on function public.get_managed_sales_tracking_period_summary(uuid,uuid,date,date,uuid) to service_role;
grant execute on function public.list_managed_sales_tracking_period_evidence(uuid,uuid,date,date,uuid,integer,date,uuid,uuid,smallint,uuid,text) to service_role;
grant execute on function public.authorize_managed_sales_tracking_evidence_renewal(uuid,uuid,date,date,uuid,uuid[]) to service_role;

commit;
