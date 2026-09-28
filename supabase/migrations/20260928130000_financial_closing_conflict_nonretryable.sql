create or replace function public.save_financial_closing_draft(actor_user_id uuid, target_branch_id uuid, expected_revision bigint, report_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c record;
  report public.financial_closing_reports%rowtype;
  current_city text;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);
  perform pg_advisory_xact_lock(hashtextextended(c.organization_id::text || ':' || c.branch_id::text || ':' || c.business_date::text || ':financial_closing', 0));
  perform 1 from private.validate_financial_closing_items(report_items, false);
  select branch.city into current_city from public.branches branch where branch.id = c.branch_id and branch.organization_id = c.organization_id;

  select * into report
  from public.financial_closing_reports saved
  where saved.organization_id = c.organization_id and saved.branch_id = c.branch_id and saved.business_date = c.business_date
  for update;

  if report.id is null then
    if expected_revision <> 0 then raise sqlstate 'PT409' using message = 'financial closing changed'; end if;
    insert into public.financial_closing_reports(
      organization_id, branch_id, business_date, state, revision,
      branch_name_snapshot, branch_code_snapshot, branch_city_snapshot, updated_by_user_id
    )
    values(c.organization_id, c.branch_id, c.business_date, 'draft', 0, c.branch_name, c.branch_code, current_city, actor_user_id)
    returning * into report;
  else
    if report.state = 'submitted' then raise exception 'financial closing already submitted' using errcode = '55000'; end if;
    if report.revision <> expected_revision then raise sqlstate 'PT409' using message = 'financial closing changed'; end if;
  end if;

  delete from public.financial_closing_items item where item.report_id = report.id;
  insert into public.financial_closing_items(report_id, item_key, status, reason, follow_up)
  select report.id, item.item_key, item.status, item.reason, item.follow_up
  from private.validate_financial_closing_items(report_items, false) item;

  update public.financial_closing_reports
  set revision = revision + 1,
      updated_at = now(),
      updated_by_user_id = actor_user_id
  where id = report.id;

  return private.financial_closing_payload(actor_user_id, target_branch_id);
exception when no_data_found or too_many_rows then
  raise exception 'financial closing access denied' using errcode = '42501';
end
$$;

create or replace function public.submit_financial_closing(actor_user_id uuid, target_branch_id uuid, expected_revision bigint, report_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c record;
  report public.financial_closing_reports%rowtype;
  current_city text;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);
  perform pg_advisory_xact_lock(hashtextextended(c.organization_id::text || ':' || c.branch_id::text || ':' || c.business_date::text || ':financial_closing', 0));
  perform 1 from private.validate_financial_closing_items(report_items, true);
  select branch.city into current_city from public.branches branch where branch.id = c.branch_id and branch.organization_id = c.organization_id;

  select * into report
  from public.financial_closing_reports saved
  where saved.organization_id = c.organization_id and saved.branch_id = c.branch_id and saved.business_date = c.business_date
  for update;

  if report.id is null then
    if expected_revision <> 0 then raise sqlstate 'PT409' using message = 'financial closing changed'; end if;
    insert into public.financial_closing_reports(
      organization_id, branch_id, business_date, state, revision,
      branch_name_snapshot, branch_code_snapshot, branch_city_snapshot, updated_by_user_id
    )
    values(c.organization_id, c.branch_id, c.business_date, 'draft', 0, c.branch_name, c.branch_code, current_city, actor_user_id)
    returning * into report;
  else
    if report.state = 'submitted' then raise exception 'financial closing already submitted' using errcode = '55000'; end if;
    if report.revision <> expected_revision then raise sqlstate 'PT409' using message = 'financial closing changed'; end if;
  end if;

  delete from public.financial_closing_items item where item.report_id = report.id;
  insert into public.financial_closing_items(report_id, item_key, status, reason, follow_up)
  select report.id, item.item_key, item.status, item.reason, item.follow_up
  from private.validate_financial_closing_items(report_items, true) item;

  update public.financial_closing_reports
  set state = 'submitted',
      revision = revision + 1,
      branch_name_snapshot = c.branch_name,
      branch_code_snapshot = c.branch_code,
      branch_city_snapshot = current_city,
      submitted_by_user_id = actor_user_id,
      submitted_by_name_snapshot = c.actor_name,
      submitted_at = now(),
      updated_at = now(),
      updated_by_user_id = actor_user_id
  where id = report.id;

  return private.financial_closing_payload(actor_user_id, target_branch_id);
exception when no_data_found or too_many_rows then
  raise exception 'financial closing access denied' using errcode = '42501';
end
$$;

revoke all on function public.save_financial_closing_draft(uuid, uuid, bigint, jsonb) from public, anon, authenticated;
revoke all on function public.submit_financial_closing(uuid, uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.save_financial_closing_draft(uuid, uuid, bigint, jsonb) to postgres, service_role;
grant execute on function public.submit_financial_closing(uuid, uuid, bigint, jsonb) to postgres, service_role;
