-- Read-only production preflight. Run with a role that can inspect pg_catalog
-- and the Sales Tracking tables. This script performs no writes.
begin transaction read only;

-- 1. Deployed function fingerprints and security properties.
select
  namespace.nspname as schema_name,
  routine.proname as function_name,
  pg_catalog.pg_get_function_identity_arguments(routine.oid) as identity_arguments,
  pg_catalog.md5(pg_catalog.pg_get_functiondef(routine.oid)) as definition_md5,
  routine.prosecdef as security_definer,
  routine.proconfig as function_settings
from pg_catalog.pg_proc routine
join pg_catalog.pg_namespace namespace on namespace.oid=routine.pronamespace
where namespace.nspname='public'
  and routine.proname in(
    'start_sales_tracking_correction',
    'save_sales_tracking_correction',
    'submit_sales_tracking_correction',
    'get_sales_tracking_current_state',
    'list_managed_sales_tracking_reports',
    'get_managed_sales_tracking_attachments',
    'get_managed_sales_tracking_monthly_summary'
  )
order by routine.proname,pg_catalog.pg_get_function_identity_arguments(routine.oid);

-- 2. Effective routine grants. Public/authenticated must not have EXECUTE;
-- service_role must have EXECUTE on the public RPC signatures.
select routine_schema,routine_name,grantee,privilege_type
from information_schema.routine_privileges
where routine_schema='public'
  and routine_name in(
    'start_sales_tracking_correction',
    'save_sales_tracking_correction',
    'submit_sales_tracking_correction',
    'list_managed_sales_tracking_reports',
    'get_managed_sales_tracking_attachments',
    'get_managed_sales_tracking_monthly_summary'
  )
order by routine_name,grantee,privilege_type;

-- 3. Open replacement inventory and non-financial activity counts.
select
  case_row.id as case_id,
  case_row.organization_id,
  case_row.branch_id,
  case_row.business_date,
  case_row.authoritative_report_id,
  case_row.open_correction_report_id,
  authority.version_number as authoritative_version,
  authority.state as authoritative_state,
  authority.review_status as authoritative_review_status,
  draft.version_number as open_version,
  draft.state as open_state,
  draft.branch_revision as open_revision,
  (select count(*)from public.sales_tracking_period_entries p where p.report_id=draft.id)as period_count,
  (select count(*)from public.sales_tracking_sales_rows s where s.report_id=draft.id)as sales_row_count,
  (select count(*)from public.sales_tracking_cash_rows c where c.report_id=draft.id)as cash_row_count,
  (select count(*)from public.sales_tracking_online_amounts a where a.report_id=draft.id)as provider_row_count,
  (select count(*)from public.sales_tracking_attachments a where a.report_id=draft.id and a.deleted_at is null)as attachment_count
from public.sales_tracking_report_cases case_row
join public.sales_tracking_reports authority on authority.id=case_row.authoritative_report_id
join public.sales_tracking_reports draft on draft.id=case_row.open_correction_report_id
order by case_row.business_date,case_row.branch_id;

-- 4. Conservative legacy eligibility report. This reports candidates only;
-- it does not delete or update anything. Any false condition means manual review.
with open_drafts as(
  select case_row.id case_id,case_row.organization_id,case_row.branch_id,case_row.business_date,
    authority.id authority_id,draft.id draft_id,draft.state,draft.branch_revision,
    draft.submitted_at,draft.supersedes_report_id,draft.correction_created_by_user_id,draft.updated_by_user_id
  from public.sales_tracking_report_cases case_row
  join public.sales_tracking_reports authority on authority.id=case_row.authoritative_report_id
  join public.sales_tracking_reports draft on draft.id=case_row.open_correction_report_id
),checks as(
 select open_drafts.*,
  not exists(select 1 from public.sales_tracking_attachments a where a.report_id=draft_id and a.deleted_at is null)as no_replacement_attachments,
  not exists(select 1 from public.sales_tracking_review_events event where event.report_id=draft_id)as no_replacement_review_events,
  not exists(
   (select p.entry_period from public.sales_tracking_period_entries p where p.report_id=draft_id
    except select p.entry_period from public.sales_tracking_period_entries p where p.report_id=authority_id)
   union all
   (select p.entry_period from public.sales_tracking_period_entries p where p.report_id=authority_id
    except select p.entry_period from public.sales_tracking_period_entries p where p.report_id=draft_id)
  )as periods_equivalent,
  not exists(
   (select p.entry_period,s.entry_date,s.actual_cash,s.actual_credit,s.pos_cash,s.pos_credit,s.online_delivery,s.refund_total,s.remarks
    from public.sales_tracking_sales_rows s join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where s.report_id=draft_id
    except
    select p.entry_period,s.entry_date,s.actual_cash,s.actual_credit,s.pos_cash,s.pos_credit,s.online_delivery,s.refund_total,s.remarks
    from public.sales_tracking_sales_rows s join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where s.report_id=authority_id)
   union all
   (select p.entry_period,s.entry_date,s.actual_cash,s.actual_credit,s.pos_cash,s.pos_credit,s.online_delivery,s.refund_total,s.remarks
    from public.sales_tracking_sales_rows s join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where s.report_id=authority_id
    except
    select p.entry_period,s.entry_date,s.actual_cash,s.actual_credit,s.pos_cash,s.pos_credit,s.online_delivery,s.refund_total,s.remarks
    from public.sales_tracking_sales_rows s join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where s.report_id=draft_id)
  )as sales_equivalent,
  not exists(
   (select p.entry_period,c.entry_date,c.denom_1,c.denom_2,c.denom_5,c.denom_10,c.denom_20,c.denom_50,c.denom_100,c.denom_200,c.denom_500,c.remaining_cash,c.remarks
    from public.sales_tracking_cash_rows c join public.sales_tracking_period_entries p on p.id=c.period_entry_id
    where c.report_id=draft_id
    except
    select p.entry_period,c.entry_date,c.denom_1,c.denom_2,c.denom_5,c.denom_10,c.denom_20,c.denom_50,c.denom_100,c.denom_200,c.denom_500,c.remaining_cash,c.remarks
    from public.sales_tracking_cash_rows c join public.sales_tracking_period_entries p on p.id=c.period_entry_id
    where c.report_id=authority_id)
   union all
   (select p.entry_period,c.entry_date,c.denom_1,c.denom_2,c.denom_5,c.denom_10,c.denom_20,c.denom_50,c.denom_100,c.denom_200,c.denom_500,c.remaining_cash,c.remarks
    from public.sales_tracking_cash_rows c join public.sales_tracking_period_entries p on p.id=c.period_entry_id
    where c.report_id=authority_id
    except
    select p.entry_period,c.entry_date,c.denom_1,c.denom_2,c.denom_5,c.denom_10,c.denom_20,c.denom_50,c.denom_100,c.denom_200,c.denom_500,c.remaining_cash,c.remarks
    from public.sales_tracking_cash_rows c join public.sales_tracking_period_entries p on p.id=c.period_entry_id
    where c.report_id=draft_id)
  )as cash_equivalent,
  not exists(
   (select p.entry_period,a.provider_id,a.amount
    from public.sales_tracking_online_amounts a
    join public.sales_tracking_sales_rows s on s.id=a.sales_row_id
    join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where a.report_id=draft_id
    except
    select p.entry_period,a.provider_id,a.amount
    from public.sales_tracking_online_amounts a
    join public.sales_tracking_sales_rows s on s.id=a.sales_row_id
    join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where a.report_id=authority_id)
   union all
   (select p.entry_period,a.provider_id,a.amount
    from public.sales_tracking_online_amounts a
    join public.sales_tracking_sales_rows s on s.id=a.sales_row_id
    join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where a.report_id=authority_id
    except
    select p.entry_period,a.provider_id,a.amount
    from public.sales_tracking_online_amounts a
    join public.sales_tracking_sales_rows s on s.id=a.sales_row_id
    join public.sales_tracking_period_entries p on p.id=s.period_entry_id
    where a.report_id=draft_id)
  )as provider_rows_equivalent
 from open_drafts
)
select
 case_id,organization_id,branch_id,business_date,authority_id,draft_id,
 state,branch_revision,no_replacement_attachments,no_replacement_review_events,
 periods_equivalent,sales_equivalent,cash_equivalent,provider_rows_equivalent,
 (state='draft'and branch_revision=1 and submitted_at is null
  and supersedes_report_id=authority_id and correction_created_by_user_id is not null
  and updated_by_user_id=correction_created_by_user_id
  and no_replacement_attachments and no_replacement_review_events
  and periods_equivalent and sales_equivalent and cash_equivalent and provider_rows_equivalent)as eligible_for_controlled_emptying,
 case when state='draft'and branch_revision=1 and submitted_at is null
  and supersedes_report_id=authority_id and correction_created_by_user_id is not null
  and updated_by_user_id=correction_created_by_user_id
  and no_replacement_attachments and no_replacement_review_events
  and periods_equivalent and sales_equivalent and cash_equivalent and provider_rows_equivalent
  then'candidate_only_no_conversion_in_phase_1'else'grandfathered_manual_review_required'end as rollout_status
from checks
order by business_date,branch_id;

-- 5. Current Manager read-model body for review before deployment.
select pg_catalog.pg_get_functiondef(
 'public.list_managed_sales_tracking_reports(uuid,uuid,date,date)'::pg_catalog.regprocedure
)as manager_read_model_body;

rollback;
