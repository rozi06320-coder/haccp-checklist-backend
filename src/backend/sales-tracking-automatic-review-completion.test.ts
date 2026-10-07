import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { describe, it } from "node:test";
import path from "node:path";

const migrations=path.resolve("supabase/migrations");
const baselinePath=path.join(migrations,"20261007140000_sales_tracking_supervisor_corrections.sql");
const successorPath=path.join(migrations,"20261007150000_sales_tracking_automatic_review_completion.sql");

describe("Sales Tracking automatic review completion migration history",()=>{
 it("keeps the applied 1400 behavior as the historical baseline",async()=>{
  const sql=await readFile(baselinePath,"utf8");
  assert.match(sql,/target_review_status not in\('needs_review','reviewed'\)/);
  assert.match(sql,/reviewed_by_user_id=actor_user_id where r\.id=s\.id/);
  assert.doesNotMatch(sql,/automatic review completion/i);
 });

 it("orders the successor after the review and correction foundations",async()=>{
  const files=(await readdir(migrations)).filter((file)=>file.endsWith(".sql")).sort();
  const review=files.indexOf("20261007120000_sales_tracking_manager_review_status.sql");
  const readModel=files.indexOf("20261007130000_sales_tracking_manager_review_read_model.sql");
  const correction=files.indexOf("20261007140000_sales_tracking_supervisor_corrections.sql");
  const automatic=files.indexOf("20261007150000_sales_tracking_automatic_review_completion.sql");
  assert.ok(review>=0&&review<readModel&&readModel<correction&&correction<automatic);
 });

 it("replaces only the review policy, correction submit, and review consistency constraint",async()=>{
  const sql=await readFile(successorPath,"utf8");
  assert.equal(sql.match(/create or replace function public\./g)?.length,2);
  assert.match(sql,/create or replace function public\.set_managed_sales_tracking_review_status/);
  assert.match(sql,/create or replace function public\.submit_sales_tracking_correction/);
  assert.equal(sql.match(/alter table public\.sales_tracking_reports/g)?.length,2);
  assert.equal(sql.match(/sales_tracking_reports_review_actor_check/g)?.length,2);
  assert.doesNotMatch(sql,/drop constraint (?!sales_tracking_reports_review_actor_check)/);
 });

 it("allows only Manager correction requests and preserves optimistic locking",async()=>{
  const sql=await readFile(successorPath,"utf8");
  const manager=sql.slice(sql.indexOf("create or replace function public.set_managed_sales_tracking_review_status"),sql.indexOf("create or replace function public.submit_sales_tracking_correction"));
  assert.match(manager,/private\.actor_manages_active_organization/);
  assert.match(manager,/target_review_status<>'needs_review'/);
  assert.match(manager,/report\.review_status not in\('none','reviewed'\)/);
  assert.match(manager,/report\.review_revision<>expected_review_revision[\s\S]*PT409/);
  assert.match(manager,/for update/);
  assert.match(manager,/sales_tracking_review_events/);
 });

 it("completes review automatically without claiming a human reviewer",async()=>{
  const sql=await readFile(successorPath,"utf8");
  const submit=sql.slice(sql.indexOf("create or replace function public.submit_sales_tracking_correction"),sql.indexOf("revoke all on function"));
  assert.match(submit,/state='superseded'/);
  assert.match(submit,/state='submitted'/);
  assert.match(submit,/authoritative_report_id=s\.id,open_correction_report_id=null/);
  assert.match(submit,/review_status='reviewed'/);
  assert.match(submit,/review_revision=source\.review_revision\+1/);
  assert.match(submit,/reviewed_by_user_id=null/);
  assert.match(submit,/sales_tracking_review_events[\s\S]*'needs_review','reviewed',actor_user_id/);
 });

 it("keeps historical attribution compatible and preserves RPC security",async()=>{
  const sql=await readFile(successorPath,"utf8");
  assert.match(sql,/review_status='none'and reviewed_at is null and reviewed_by_user_id is null/);
  assert.match(sql,/review_status='needs_review'and reviewed_at is not null and reviewed_by_user_id is not null/);
  assert.match(sql,/review_status='reviewed'and reviewed_at is not null/);
  assert.doesNotMatch(sql,/review_status='reviewed'and reviewed_by_user_id is null/);
  assert.equal(sql.match(/security definer set search_path=''/g)?.length,2);
  assert.match(sql,/revoke all on function[\s\S]*from public,anon,authenticated/);
  assert.match(sql,/grant execute on function[\s\S]*to service_role/);
 });
});
