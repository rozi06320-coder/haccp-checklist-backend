import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";
import path from "node:path";

const migrationPath=path.resolve("supabase/migrations/20261007140000_sales_tracking_supervisor_corrections.sql");

describe("Sales Tracking correction versioning migration",()=>{
 it("creates one logical case and immutable report versions",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  assert.match(sql,/create table public\.sales_tracking_report_cases/);
  assert.match(sql,/unique\(organization_id,branch_id,business_date\)/);
  assert.match(sql,/unique\(case_id,version_number\)/);
  assert.match(sql,/state in\('draft','submitted','superseded'\)/);
  assert.match(sql,/sales_tracking_reports_one_draft_per_case_uidx/);
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
