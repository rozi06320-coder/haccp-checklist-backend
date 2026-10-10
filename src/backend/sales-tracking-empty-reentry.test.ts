import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";
import path from "node:path";

const migrationPath=path.resolve("supabase/migrations/20261010120000_sales_tracking_empty_reentry_drafts.sql");
const preflightPath=path.resolve("scripts/sales-tracking-empty-reentry-production-preflight.sql");

function functionBody(sql:string,name:string,next:string){
  const start=sql.indexOf(`create or replace function public.${name}`);
  const end=sql.indexOf(next,start);
  assert.ok(start>=0&&end>start,`${name} boundary exists`);
  return sql.slice(start,end);
}

describe("Sales Tracking empty re-entry successor",()=>{
  it("converts only exact untouched legacy copies and invalidates stale tabs",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    const start=sql.indexOf("create or replace function private.convert_untouched_sales_tracking_corrections()");
    const end=sql.indexOf("-- Needs Review starts",start);
    assert.ok(start>=0&&end>start,"guarded conversion boundary exists");
    const conversion=sql.slice(start,end);
    for(const guard of[
      /open_correction_report_id=draft\.id/,
      /authoritative_report_id=source\.id/,
      /draft\.state='draft'/,
      /source\.state='submitted'/,
      /source\.review_status='needs_review'/,
      /draft\.supersedes_report_id=source\.id/,
      /draft\.branch_revision=1/,
      /draft\.submitted_at is null/,
      /draft\.correction_created_by_user_id is not null/,
      /draft\.updated_by_user_id=draft\.correction_created_by_user_id/,
      /sales_tracking_attachments attachment where attachment\.report_id=draft\.id/,
      /sales_tracking_review_events event where event\.report_id=draft\.id/,
    ])assert.match(conversion,guard);
    assert.equal(conversion.match(/except all/g)?.length,8);
    assert.match(conversion,/for update of case_lock,source_lock,draft_lock/);
    assert.match(conversion,/pg_advisory_xact_lock/);
    assert.match(conversion,/set branch_revision=2,updated_at=pg_catalog\.now\(\)/);
    assert.match(conversion,/select private\.convert_untouched_sales_tracking_corrections\(\)/);
  });

  it("flushes provider delete validation before deleting Sales parents",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    const start=sql.indexOf("create or replace function private.convert_untouched_sales_tracking_corrections()");
    const end=sql.indexOf("-- Needs Review starts",start);
    const conversion=sql.slice(start,end);
    const immediate=conversion.indexOf("set constraints public.sales_tracking_online_amounts_total_check immediate");
    const providerDelete=conversion.indexOf("delete from public.sales_tracking_online_amounts");
    const salesDelete=conversion.indexOf("delete from public.sales_tracking_sales_rows");
    const deferred=conversion.indexOf("set constraints public.sales_tracking_online_amounts_total_check deferred");
    assert.ok(immediate>=0&&providerDelete>immediate&&salesDelete>providerDelete&&deferred>salesDelete);
    assert.doesNotMatch(conversion,/disable trigger|drop trigger|alter table/);
  });

  it("keeps ineligible and already-converted drafts untouched",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    const start=sql.indexOf("create or replace function private.convert_untouched_sales_tracking_corrections()");
    const end=sql.indexOf("-- Needs Review starts",start);
    const conversion=sql.slice(start,end);
    assert.match(conversion,/if coalesce\(eligible,false\)then/);
    assert.match(conversion,/where draft\.id=candidate\.draft_id and draft\.state='draft'and draft\.branch_revision=1/);
    assert.match(conversion,/return converted_count/);
    assert.doesNotMatch(conversion,/delete from public\.sales_tracking_attachments/);
    assert.doesNotMatch(conversion,/delete from public\.sales_tracking_reports/);
    assert.doesNotMatch(conversion,/update public\.sales_tracking_report_cases/);
  });

  it("creates empty replacement metadata without copying financial or attachment children",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    const start=functionBody(sql,"start_sales_tracking_correction","-- Re-entry periods");
    assert.match(start,/branch_revision,updated_by_user_id,currency_code,case_id,version_number/);
    assert.match(start,/source\.version_number\+1/);
    assert.match(start,/source\.id,actor_user_id,pg_catalog\.now\(\)/);
    assert.match(start,/open_correction_report_id=created\.id/);
    assert.match(start,/team\.supervisor_user_id=actor_user_id/);
    assert.match(start,/team\.active and shift\.active/);
    assert.match(start,/current_team_name/);
    assert.doesNotMatch(start,/actor_user_id,c\.legacy_team_id/);
    assert.doesNotMatch(start,/source\.supervisor_team_name_snapshot/);
    assert.doesNotMatch(start,/insert into public\.sales_tracking_period_entries/);
    assert.doesNotMatch(start,/insert into public\.sales_tracking_sales_rows/);
    assert.doesNotMatch(start,/insert into public\.sales_tracking_cash_rows/);
    assert.doesNotMatch(start,/insert into public\.sales_tracking_online_amounts/);
    assert.doesNotMatch(start,/insert into public\.sales_tracking_attachments/);
  });

  it("makes re-entry period persistence insert-only and keeps validations",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    const save=functionBody(sql,"save_sales_tracking_correction","create or replace function public.submit_sales_tracking_correction");
    assert.match(save,/open_correction_report_id<>s\.id or s\.state<>'draft'/);
    assert.match(save,/s\.branch_revision<>expected_revision/);
    assert.match(save,/sales tracking re-entry period already saved/);
    assert.match(save,/jsonb_array_length\(sales_rows\)<>1 or pg_catalog\.jsonb_array_length\(cash_rows\)<>1/);
    assert.match(save,/private\.sales_tracking_refund_field/);
    assert.match(save,/sales tracking online provider total mismatch'using errcode='23514'/);
    assert.match(save,/insert into public\.sales_tracking_period_entries/);
    assert.match(save,/insert into public\.sales_tracking_sales_rows/);
    assert.match(save,/insert into public\.sales_tracking_cash_rows/);
    assert.match(save,/insert into public\.sales_tracking_online_amounts/);
    assert.doesNotMatch(save,/delete from public\.sales_tracking_/);
  });

  it("submits only a complete open replacement and switches authority atomically",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    const submit=functionBody(sql,"submit_sales_tracking_correction","-- Preserve the daily projection");
    assert.match(submit,/s\.supersedes_report_id<>source\.id/);
    assert.match(submit,/incomplete_period_count/);
    assert.match(submit,/sales_tracking_sales_rows sales[\s\S]*<>1/);
    assert.match(submit,/sales_tracking_cash_rows cash[\s\S]*<>1/);
    assert.match(submit,/state='superseded'/);
    assert.match(submit,/review_status='reviewed'/);
    assert.match(submit,/review_revision=source\.review_revision\+1/);
    assert.match(submit,/authoritative_report_id=s\.id,open_correction_report_id=null/);
  });

  it("makes daily, attachment, and monthly Manager reads authority-pointer based",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    const daily=functionBody(sql,"list_managed_sales_tracking_reports","create or replace function public.get_managed_sales_tracking_attachments");
    const attachments=functionBody(sql,"get_managed_sales_tracking_attachments","-- Monthly totals");
    const monthly=functionBody(sql,"get_managed_sales_tracking_monthly_summary","revoke all on function");
    assert.match(daily,/join public\.sales_tracking_reports r on r\.id=case_row\.authoritative_report_id/);
    assert.doesNotMatch(daily,/from public\.sales_tracking_reports r\s+join public\.sales_tracking_sales_rows/);
    assert.match(attachments,/report\.id=case_row\.authoritative_report_id/);
    assert.match(monthly,/join public\.sales_tracking_reports report on report\.id=case_row\.authoritative_report_id/);
    assert.doesNotMatch(monthly,/get_managed_sales_tracking_monthly_summary_without_evidence_legacy/);
  });

  it("preserves hardened RPC definitions and service-role-only grants",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    assert.equal(sql.match(/security definer set search_path=''/g)?.length,7);
    assert.match(sql,/revoke all on function private\.convert_untouched_sales_tracking_corrections\(\)[\s\S]*from public,anon,authenticated,service_role/);
    assert.match(sql,/revoke all on function[\s\S]*from public,anon,authenticated/);
    assert.match(sql,/grant execute on function[\s\S]*to service_role/);
    assert.doesNotMatch(sql,/grant execute[\s\S]*to authenticated/);
  });

  it("keeps the existing frontend-compatible correction API envelope",async()=>{
    const app=await readFile(path.resolve("src/backend/app.ts"),"utf8");
    const persistence=await readFile(path.resolve("src/backend/checklist-persistence.ts"),"utf8");
    assert.match(app,/sales_tracking\/:reportId\/correction"[\s\S]*status\(201\)\.json\(\{current\}\)/);
    assert.match(app,/sales_tracking\/:reportId\/correction\/draft"[\s\S]*status\(200\)\.json\(\{current\}\)/);
    assert.match(app,/sales_tracking\/:reportId\/correction\/submit"[\s\S]*status\(201\)\.json\(\{current\}\)/);
    assert.match(persistence,/safeSalesTrackingCurrent\(await rpc\("start_sales_tracking_correction"/);
    assert.match(persistence,/safeSalesTrackingCurrent\(await runSalesTrackingCorrectionSaveRpc/);
    assert.match(persistence,/safeSalesTrackingCurrent\(await rpc\("submit_sales_tracking_correction"/);
  });

  it("ships a read-only, non-converting production preflight",async()=>{
    const sql=await readFile(preflightPath,"utf8");
    assert.match(sql,/begin transaction read only/);
    assert.match(sql,/eligible_for_controlled_emptying/);
    assert.match(sql,/grandfathered_manual_review_required/);
    assert.match(sql,/pg_get_functiondef/);
    assert.match(sql,/routine_privileges/);
    assert.match(sql,/rollback/);
    assert.doesNotMatch(sql,/^\s*(?:insert|update|delete|truncate|alter|create|drop)\b/im);
  });
});
