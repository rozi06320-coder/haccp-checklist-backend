import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath="supabase/migrations/20261007120000_sales_tracking_manager_review_status.sql";

describe("Sales Tracking Manager review status",()=>{
 it("adds review-only metadata with independent optimistic concurrency",async()=>{
  const sql=await readFile(path.resolve(migrationPath),"utf8");
  assert.match(sql,/review_status text not null default 'none'/);
  assert.match(sql,/review_revision bigint not null default 0/);
  assert.match(sql,/reviewed_by_user_id uuid references public\.profiles\(id\) on delete restrict/);
  assert.match(sql,/state <> 'draft'[\s\S]*review_status = 'none'[\s\S]*review_revision = 0/);
  assert.match(sql,/report\.review_revision <> expected_review_revision[\s\S]*raise sqlstate 'PT409'/);
 });

 it("uses the canonical Manager guard and service-role-only definer RPC",async()=>{
  const sql=await readFile(path.resolve(migrationPath),"utf8");
  assert.match(sql,/create function public\.set_managed_sales_tracking_review_status\([\s\S]*security definer[\s\S]*set search_path = ''/);
  assert.match(sql,/private\.actor_manages_active_organization\(actor_user_id, target_organization_id\)/);
  assert.match(sql,/where r\.id = target_report_id and r\.organization_id = target_organization_id[\s\S]*for update/);
  assert.match(sql,/revoke all on function public\.set_managed_sales_tracking_review_status[\s\S]*from public, anon, authenticated/);
  assert.match(sql,/grant execute on function public\.set_managed_sales_tracking_review_status[\s\S]*to service_role/);
 });

 it("keeps submitted financial data immutable while allowing only a revisioned review transition",async()=>{
  const sql=await readFile(path.resolve(migrationPath),"utf8");
  assert.match(sql,/to_jsonb\(new\) - array\['review_status','review_revision','reviewed_at','reviewed_by_user_id','updated_at'\]/);
  assert.match(sql,/new\.review_revision = old\.review_revision \+ 1/);
  assert.match(sql,/raise exception 'submitted sales tracking report is immutable' using errcode = '55000'/);
  assert.match(sql,/create table public\.sales_tracking_review_events/);
 });

 it("preserves totals and only decorates existing read models",async()=>{
  const sql=await readFile(path.resolve(migrationPath),"utf8");
  assert.match(sql,/list_managed_sales_tracking_reports_without_review_legacy/);
  assert.match(sql,/row_value \|\| private\.sales_tracking_review_json/);
  assert.doesNotMatch(sql,/actual_cash\s*=|actual_credit\s*=|refund_total\s*=/);
 });

 it("maps review conflicts safely and accepts nullable Phase 2 team attribution",async()=>{
  const [app,persistence]=await Promise.all([readFile(path.resolve("src/backend/app.ts"),"utf8"),readFile(path.resolve("src/backend/checklist-persistence.ts"),"utf8")]);
  assert.match(app,/sales-tracking\/:reportId\/review-status/);
  assert.match(app,/409,"conflict","This review status changed\. Refresh and try again\."/);
  assert.match(app,/supervisor_team_id:z\.uuid\(\)\.nullable\(\)\.optional\(\)/);
  assert.match(persistence,/set_managed_sales_tracking_review_status/);
  assert.match(persistence,/supervisor_team_id:z\.uuid\(\)\.nullable\(\)\.optional\(\)/);
 });

 it("limits Manager review authority to requesting correction",async()=>{
  const [sql,app,persistence]=await Promise.all([
   readFile(path.resolve("supabase/migrations/20261007150000_sales_tracking_automatic_review_completion.sql"),"utf8"),
   readFile(path.resolve("src/backend/app.ts"),"utf8"),
   readFile(path.resolve("src/backend/checklist-persistence.ts"),"utf8"),
  ]);
  const managerRpc=sql.slice(sql.indexOf("create or replace function public.set_managed_sales_tracking_review_status"),sql.indexOf("-- Normal Sales Tracking mutations"));
  assert.match(managerRpc,/target_review_status<>'needs_review'/);
  assert.match(managerRpc,/report\.review_status not in\('none','reviewed'\)/);
  assert.doesNotMatch(managerRpc,/target_review_status not in\('needs_review','reviewed'\)/);
  assert.match(app,/review_status:z\.literal\("needs_review"\)/);
  assert.match(persistence,/reviewStatus:"needs_review"/);
 });
});
