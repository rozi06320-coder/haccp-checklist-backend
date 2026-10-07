import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";
import path from "node:path";

const migrationPath=path.resolve("supabase/migrations/20261007140000_sales_tracking_supervisor_corrections.sql");

describe("Sales Tracking correction versioning migration",()=>{
 it("isolates updated_at as the protected field changed by the metadata backfill trigger",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  const foundation=await readFile(path.resolve("supabase/migrations/20260727000000_identity_tenant_foundation.sql"),"utf8");
  const phaseOne=await readFile(path.resolve("supabase/migrations/20260808060000_sales_tracking_phase1_persistence.sql"),"utf8");
  const currency=await readFile(path.resolve("supabase/migrations/20260905110000_branch_country_sales_currency.sql"),"utf8");
  assert.match(foundation,/create function private\.set_updated_at\(\)[\s\S]*new\.updated_at = now\(\)/);
  assert.match(phaseOne,/create trigger sales_tracking_reports_set_updated_at\s+before update on public\.sales_tracking_reports/);
  assert.match(currency,/create trigger sales_tracking_reports_currency_immutable\s+before update of currency_code on public\.sales_tracking_reports/);
  assert.match(sql,/update public\.sales_tracking_reports r\s+set case_id=c\.id,version_number=1/);
 });

 it("creates one logical case and immutable report versions",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  assert.match(sql,/create table public\.sales_tracking_report_cases/);
  assert.match(sql,/unique\(organization_id,branch_id,business_date\)/);
  assert.match(sql,/unique\(case_id,version_number\)/);
  assert.match(sql,/state in\('draft','submitted','superseded'\)/);
  assert.match(sql,/sales_tracking_reports_one_draft_per_case_uidx/);
 });

 it("temporarily suspends only submitted immutability and updated-at mutation for the guarded version backfill",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  const snapshot=sql.indexOf("create temporary table sales_tracking_report_version_backfill_guard");
  const disableImmutable=sql.indexOf("disable trigger sales_tracking_reports_submitted_immutable");
  const disableUpdatedAt=sql.indexOf("disable trigger sales_tracking_reports_set_updated_at");
  const backfill=sql.indexOf("set case_id=c.id,version_number=1");
  const enableUpdatedAt=sql.indexOf("enable trigger sales_tracking_reports_set_updated_at");
  const enableImmutable=sql.indexOf("enable trigger sales_tracking_reports_submitted_immutable");
  const finalTrigger=sql.indexOf("create or replace function private.prevent_submitted_sales_tracking_report_mutation");
  const snapshotDefinition=sql.slice(snapshot,disableImmutable);
  assert.ok(snapshot>0&&snapshot<disableImmutable&&disableImmutable<disableUpdatedAt&&disableUpdatedAt<backfill&&backfill<enableUpdatedAt&&enableUpdatedAt<enableImmutable&&enableImmutable<finalTrigger);
  assert.equal(sql.match(/disable trigger sales_tracking_reports_submitted_immutable/g)?.length,1);
  assert.equal(sql.match(/disable trigger sales_tracking_reports_set_updated_at/g)?.length,1);
  assert.equal(sql.match(/disable trigger /g)?.length,2);
  assert.doesNotMatch(sql,/disable trigger (?:all|user)/i);
  assert.match(sql,/expected sales tracking branch\/day uniqueness is missing/);
  assert.match(sql,/sales tracking report does not map to exactly one case/);
  assert.match(sql,/r\.updated_at as preserved_updated_at/);
  assert.match(sql,/r\.updated_at is distinct from g\.preserved_updated_at/);
  assert.match(sql,/sales tracking backfill changed historical updated_at/);
  assert.match(sql,/sales tracking backfill changed protected report data/);
  assert.match(sql,/sales tracking submitted immutability trigger was not restored/);
  assert.match(sql,/sales tracking updated-at trigger was not restored/);
  assert.match(sql,/t\.tgname='sales_tracking_reports_submitted_immutable'and not t\.tgisinternal and t\.tgenabled='O'/);
  assert.match(sql,/t\.tgname='sales_tracking_reports_set_updated_at'and not t\.tgisinternal and t\.tgenabled='O'/);
  assert.doesNotMatch(snapshotDefinition,/'updated_at'/);
  assert.match(sql,/r\.case_id is null or r\.version_number<>1/);
 });

 it("starts one copied correction without mutating source rows or evidence",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  const start=sql.slice(sql.indexOf("create function public.start_sales_tracking_correction"),sql.indexOf("create function public.save_sales_tracking_correction"));
  assert.match(start,/source\.review_status<>'needs_review'/);
  assert.match(start,/case_row\.open_correction_report_id is not null/);
  assert.match(start,/insert into public\.sales_tracking_period_entries/);
  assert.match(start,/insert into public\.sales_tracking_sales_rows/);
  assert.match(start,/insert into public\.sales_tracking_cash_rows/);
  assert.match(start,/insert into public\.sales_tracking_online_amounts/);
  assert.doesNotMatch(start,/insert into public\.sales_tracking_attachments/);
  assert.doesNotMatch(start,/update public\.sales_tracking_sales_rows/);
 });

 it("submits atomically, makes only the correction authoritative, and preserves idempotency",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  const submit=sql.slice(sql.indexOf("create function public.submit_sales_tracking_correction"),sql.indexOf("-- Make current state"));
  assert.match(submit,/state='superseded'/);
  assert.match(submit,/state='submitted'/);
  assert.match(submit,/authoritative_report_id=s\.id,open_correction_report_id=null/);
  assert.match(submit,/review_status='reviewed'/);
  assert.match(submit,/sales_tracking_submission_idempotency/);
  assert.match(submit,/prior\.report_id<>target_report_id/);
 });

 it("keeps RPCs service-role-only and blocks manager races",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  assert.match(sql,/security definer set search_path=''/g);
  assert.match(sql,/revoke all on function public\.start_sales_tracking_correction[\s\S]*from public,anon,authenticated/);
  assert.match(sql,/grant execute on function public\.start_sales_tracking_correction[\s\S]*to service_role/);
  assert.match(sql,/if case_row\.open_correction_report_id is not null then raise sqlstate'PT409'/);
 });

 it("makes every retained normal mutation overload case-aware",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  const compatibility=sql.slice(sql.indexOf("-- Normal Sales Tracking mutations"),sql.indexOf("revoke all on function public.start_sales_tracking_correction"));
  assert.match(compatibility,/private\.lock_normal_sales_tracking_case/);
  assert.match(compatibility,/create or replace function public\.ensure_sales_tracking_draft_report/);
  assert.match(compatibility,/create or replace function public\.save_sales_tracking_draft\(\s*actor_user_id uuid,target_branch_id uuid,target_business_date date/);
  assert.match(compatibility,/create or replace function public\.submit_sales_tracking\(actor_user_id uuid,target_branch_id uuid,target_business_date date/);
  assert.match(compatibility,/create or replace function public\.prepare_sales_tracking_attachment_upload/);
  assert.match(compatibility,/case_row\.authoritative_report_id is not null/);
  assert.match(compatibility,/case_row\.open_correction_report_id is not null/);
  assert.doesNotMatch(compatibility,/select\*into s from public\.sales_tracking_reports [a-z]+ where [^;]*organization_id[^;]*branch_id[^;]*business_date[^;]*for update/);
 });

 it("keeps null-report evidence preparation on an ordinary draft only",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  const prepare=sql.slice(sql.lastIndexOf("create or replace function public.prepare_sales_tracking_attachment_upload"),sql.indexOf("revoke all on function public.ensure_sales_tracking_draft_report"));
  assert.match(prepare,/target_report_id is null then select e\.report_id into target_report_id from public\.ensure_sales_tracking_draft_report/);
  assert.match(prepare,/if s\.state<>'draft'/);
  assert.doesNotMatch(prepare,/where r\.organization_id=c\.organization_id and r\.branch_id=c\.branch_id and r\.business_date=target_business_date for update/);
 });

 it("wires start, correction save, and correction submit through protected API routes",async()=>{
  const app=await readFile(path.resolve("src/backend/app.ts"),"utf8");
  const persistence=await readFile(path.resolve("src/backend/checklist-persistence.ts"),"utf8");
  assert.match(app,/sales_tracking\/:reportId\/correction"/);
  assert.match(app,/sales_tracking\/:reportId\/correction\/draft"/);
  assert.match(app,/sales_tracking\/:reportId\/correction\/submit"/);
  assert.match(persistence,/rpc\("start_sales_tracking_correction"/);
  assert.match(persistence,/rpc\("save_sales_tracking_correction"/);
  assert.match(persistence,/rpc\("submit_sales_tracking_correction"/);
 });
});
