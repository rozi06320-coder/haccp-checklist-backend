begin;

create or replace function public.list_managed_sales_tracking_reports(
  actor_user_id uuid,
  target_organization_id uuid,
  from_date date default null,
  to_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (from_date is not null and to_date is not null and from_date > to_date)
  then
    raise exception 'sales tracking report access denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'sales_rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'report_id', r.id,
        'row_id', x.id,
        'currency_code', r.currency_code,
        'business_date', r.business_date,
        'entry_date', x.entry_date,
        'entry_period', p.entry_period,
        'entered_by', p.entered_by_name_snapshot,
        'entered_at', p.entered_at,
        'branch_id', r.branch_id,
        'branch_name', r.branch_name_snapshot,
        'supervisor_user_id', r.supervisor_user_id,
        'submitted_by', coalesce(submitter.full_name, r.supervisor_name_snapshot),
        'supervisor_team_id', r.supervisor_team_id,
        'supervisor_team_name', r.supervisor_team_name_snapshot,
        'submitted_at', r.submitted_at,
        'review_status', coalesce(r.review_status, 'none'),
        'review_revision', coalesce(r.review_revision, 0),
        'reviewed_at', r.reviewed_at,
        'reviewed_by_user_id', r.reviewed_by_user_id,
        'reviewed_by', reviewer.full_name,
        'actual_cash', x.actual_cash,
        'actual_credit', x.actual_credit,
        'pos_cash', x.pos_cash,
        'pos_credit', x.pos_credit,
        'online_delivery', x.online_delivery,
        'refund_total', x.refund_total,
        'online_provider_breakdown', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'provider_id', provider.id,
            'provider_key', provider.default_provider_key,
            'provider_name', provider.name,
            'amount', amount.amount
          ) order by private.sales_tracking_online_provider_sort(
            provider.default_provider_key,
            provider.is_default,
            provider.created_at,
            provider.name,
            provider.id
          ))
          from public.sales_tracking_online_amounts amount
          join public.sales_tracking_online_order_providers provider on provider.id = amount.provider_id
          where amount.sales_row_id = x.id and amount.amount <> 0
        ), '[]'::jsonb),
        'actual_total', x.actual_cash + x.actual_credit + x.online_delivery,
        'gross_sales', x.actual_cash + x.actual_credit + x.online_delivery,
        'net_sales', x.actual_cash + x.actual_credit + x.online_delivery - x.refund_total,
        'evidence_filename', (
          select attachment.original_filename
          from public.sales_tracking_attachments attachment
          where attachment.report_id = r.id and attachment.deleted_at is null
          order by attachment.display_order, attachment.created_at, attachment.id
          limit 1
        ),
        'evidence_filenames', coalesce((
          select pg_catalog.jsonb_agg(attachment.original_filename order by attachment.display_order, attachment.created_at, attachment.id)
          from public.sales_tracking_attachments attachment
          where attachment.report_id = r.id and attachment.deleted_at is null
        ), '[]'::jsonb),
        'evidence_count', (
          select pg_catalog.count(*)
          from public.sales_tracking_attachments attachment
          where attachment.report_id = r.id and attachment.deleted_at is null
        ),
        'evidence_available', exists(
          select 1
          from public.sales_tracking_attachments attachment
          where attachment.report_id = r.id and attachment.deleted_at is null
        ),
        'pos_total', x.pos_cash + x.pos_credit + x.online_delivery,
        'variance', (x.actual_cash + x.actual_credit) - (x.pos_cash + x.pos_credit),
        'remarks', x.remarks
      ) order by r.business_date desc, r.branch_name_snapshot, p.entry_period, x.id)
      from public.sales_tracking_reports r
      join public.sales_tracking_sales_rows x on x.report_id = r.id
      left join public.sales_tracking_period_entries p on p.id = x.period_entry_id
      left join public.profiles submitter on submitter.id = coalesce(r.submitted_by_user_id, r.supervisor_user_id)
      left join public.profiles reviewer on reviewer.id = r.reviewed_by_user_id
      where r.organization_id = target_organization_id
        and r.state = 'submitted'
        and r.submitted_at is not null
        and (from_date is null or r.business_date >= from_date)
        and (to_date is null or r.business_date <= to_date)
    ), '[]'::jsonb),
    'cash_rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'report_id', r.id,
        'row_id', x.id,
        'currency_code', r.currency_code,
        'business_date', r.business_date,
        'entry_date', x.entry_date,
        'entry_period', p.entry_period,
        'entered_by', p.entered_by_name_snapshot,
        'entered_at', p.entered_at,
        'branch_id', r.branch_id,
        'branch_name', r.branch_name_snapshot,
        'supervisor_user_id', r.supervisor_user_id,
        'submitted_by', coalesce(submitter.full_name, r.supervisor_name_snapshot),
        'supervisor_team_id', r.supervisor_team_id,
        'supervisor_team_name', r.supervisor_team_name_snapshot,
        'submitted_at', r.submitted_at,
        'review_status', coalesce(r.review_status, 'none'),
        'review_revision', coalesce(r.review_revision, 0),
        'reviewed_at', r.reviewed_at,
        'reviewed_by_user_id', r.reviewed_by_user_id,
        'reviewed_by', reviewer.full_name,
        'denom_1', x.denom_1,
        'denom_2', x.denom_2,
        'denom_5', x.denom_5,
        'denom_10', x.denom_10,
        'denom_20', x.denom_20,
        'denom_50', x.denom_50,
        'denom_100', x.denom_100,
        'denom_200', x.denom_200,
        'denom_500', x.denom_500,
        'cash_total', x.denom_1 + x.denom_2 * 2 + x.denom_5 * 5 + x.denom_10 * 10
          + x.denom_20 * 20 + x.denom_50 * 50 + x.denom_100 * 100 + x.denom_200 * 200 + x.denom_500 * 500,
        'remaining_cash', x.remaining_cash,
        'remarks', x.remarks
      ) order by r.business_date desc, r.branch_name_snapshot, p.entry_period, x.id)
      from public.sales_tracking_reports r
      join public.sales_tracking_cash_rows x on x.report_id = r.id
      left join public.sales_tracking_period_entries p on p.id = x.period_entry_id
      left join public.profiles submitter on submitter.id = coalesce(r.submitted_by_user_id, r.supervisor_user_id)
      left join public.profiles reviewer on reviewer.id = r.reviewed_by_user_id
      where r.organization_id = target_organization_id
        and r.state = 'submitted'
        and r.submitted_at is not null
        and (from_date is null or r.business_date >= from_date)
        and (to_date is null or r.business_date <= to_date)
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function public.list_managed_sales_tracking_reports(uuid, uuid, date, date)
  from public, anon, authenticated;
grant execute on function public.list_managed_sales_tracking_reports(uuid, uuid, date, date)
  to service_role;

commit;
