create or replace function public.delete_branch_product_sale(
  actor_user_id uuid,
  target_branch_id uuid,
  target_business_date date,
  target_product_sale_id uuid,
  expected_revision bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ctx record;
  report public.branch_product_sales_daily_reports%rowtype;
  sale public.branch_product_sales%rowtype;
begin
  begin
    select * into strict ctx
    from private.phase2_branch_context(actor_user_id, target_branch_id);
  exception
    when no_data_found or too_many_rows then
      raise exception 'product sales access denied' using errcode = '42501';
  end;

  if target_business_date is null then
    raise exception 'product sales business date required' using errcode = '22004';
  end if;
  if target_business_date > ctx.business_date then
    raise exception 'product sales future business date denied' using errcode = '22023';
  end if;
  if target_product_sale_id is null then
    raise exception 'product sale id required' using errcode = '22004';
  end if;
  if coalesce(expected_revision, -1) < 0 then
    raise exception 'invalid product sales revision' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(ctx.organization_id::text || ':' || ctx.branch_id::text || ':' || target_business_date::text || ':product_sales', 0)
  );

  select * into report
  from public.branch_product_sales_daily_reports existing
  where existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date
  for update;

  if report.id is null then
    raise exception 'product sales report not found' using errcode = 'P0002';
  end if;
  if expected_revision <> report.revision then
    raise exception 'product sales changed' using errcode = '40001';
  end if;

  select * into sale
  from public.branch_product_sales existing
  where existing.id = target_product_sale_id
    and existing.report_id = report.id
    and existing.organization_id = ctx.organization_id
    and existing.branch_id = ctx.branch_id
    and existing.business_date = target_business_date
  for update;

  if sale.id is null then
    raise exception 'product sale not found' using errcode = 'P0002';
  end if;

  delete from public.branch_product_sales existing
  where existing.id = sale.id;

  update public.branch_product_sales_daily_reports existing
  set revision = existing.revision + 1,
      updated_by_user_id = actor_user_id,
      updated_at = pg_catalog.now()
  where existing.id = report.id;

  return private.branch_product_sales_payload(actor_user_id, target_branch_id, target_business_date);
end;
$$;

revoke all on function public.delete_branch_product_sale(uuid, uuid, date, uuid, bigint) from public, anon, authenticated;
grant execute on function public.delete_branch_product_sale(uuid, uuid, date, uuid, bigint) to service_role;
