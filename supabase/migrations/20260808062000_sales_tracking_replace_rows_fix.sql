-- Fix Sales Tracking row replacement helper parameter ambiguity.

drop function private.replace_sales_tracking_rows(uuid,jsonb,jsonb);

create function private.replace_sales_tracking_rows(p_report_id uuid, sales_rows jsonb, cash_rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.sales_tracking_sales_rows where report_id = p_report_id;
  delete from public.sales_tracking_cash_rows where report_id = p_report_id;

  insert into public.sales_tracking_sales_rows(
    report_id, entry_date, actual_cash, actual_credit, pos_cash, pos_credit, online_delivery, remarks
  )
  select p_report_id,
    private.sales_tracking_date_field(row_value, 'entry_date'),
    private.sales_tracking_numeric_field(row_value, 'actual_cash'),
    private.sales_tracking_numeric_field(row_value, 'actual_credit'),
    private.sales_tracking_numeric_field(row_value, 'pos_cash'),
    private.sales_tracking_numeric_field(row_value, 'pos_credit'),
    private.sales_tracking_numeric_field(row_value, 'online_delivery'),
    nullif(pg_catalog.btrim(coalesce(row_value ->> 'remarks', '')), '')
  from pg_catalog.jsonb_array_elements(sales_rows) entry(row_value);

  insert into public.sales_tracking_cash_rows(
    report_id, entry_date, denom_1, denom_2, denom_5, denom_10, denom_20, denom_50,
    denom_100, denom_200, denom_500, remaining_cash, remarks
  )
  select p_report_id,
    private.sales_tracking_date_field(row_value, 'entry_date'),
    private.sales_tracking_integer_field(row_value, 'denom_1'),
    private.sales_tracking_integer_field(row_value, 'denom_2'),
    private.sales_tracking_integer_field(row_value, 'denom_5'),
    private.sales_tracking_integer_field(row_value, 'denom_10'),
    private.sales_tracking_integer_field(row_value, 'denom_20'),
    private.sales_tracking_integer_field(row_value, 'denom_50'),
    private.sales_tracking_integer_field(row_value, 'denom_100'),
    private.sales_tracking_integer_field(row_value, 'denom_200'),
    private.sales_tracking_integer_field(row_value, 'denom_500'),
    private.sales_tracking_numeric_field(row_value, 'remaining_cash'),
    nullif(pg_catalog.btrim(coalesce(row_value ->> 'remarks', '')), '')
  from pg_catalog.jsonb_array_elements(cash_rows) entry(row_value);
end $$;
revoke all on function private.replace_sales_tracking_rows(uuid,jsonb,jsonb) from public, anon, authenticated;
