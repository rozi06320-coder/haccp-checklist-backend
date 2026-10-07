import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";
import path from "node:path";

const migrationPath=path.resolve("supabase/migrations/20261007170000_sales_tracking_dated_submit_period_rule.sql");

describe("Sales Tracking dated submit period rule",()=>{
 it("replaces only the explicit-date submit overload",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  assert.match(sql,/create or replace function public\.submit_sales_tracking\(\s*actor_user_id uuid,target_branch_id uuid,target_business_date date,\s*expected_revision bigint,idempotency_key uuid,request_hash text\)/);
  assert.equal(sql.match(/create or replace function/g)?.length,1);
  assert.doesNotMatch(sql,/create or replace function public\.submit_sales_tracking\(actor_user_id uuid,target_branch_id uuid,expected_revision bigint/);
  assert.doesNotMatch(sql,/alter table|create table|drop table|update public\.sales_tracking_report_cases/i);
 });

 it("accepts one or two periods only when exactly one is Closing",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  assert.match(sql,/count\(\*\)filter\(where p\.entry_period='closing_shift'\)/);
  assert.match(sql,/count\(\*\)filter\(where p\.entry_period not in\('middle_shift','closing_shift'\)\)/);
  assert.match(sql,/period_count<1 or period_count>2 or closing_count<>1 or invalid_period_count<>0/);
  assert.match(sql,/sales tracking periods incomplete'using errcode='22023'/);
  assert.doesNotMatch(sql,/where p\.report_id=s\.id\)<>2/);
 });

 it("preserves case resolution, locking, revision, idempotency, and submission attribution",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  assert.match(sql,/private\.phase2_branch_context/);
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/private\.lock_normal_sales_tracking_case/);
  assert.match(sql,/where r\.case_id=case_row\.id and r\.state='draft'for update/);
  assert.match(sql,/coalesce\(expected_revision,-1\)<>s\.branch_revision/);
  assert.match(sql,/sales_tracking_submission_idempotency/);
  assert.match(sql,/state='submitted',submitted_at=pg_catalog\.now\(\),branch_revision=r\.branch_revision\+1/);
  assert.match(sql,/submitted_by_user_id=actor_user_id,submitted_by_name_snapshot=c\.actor_name/);
 });

 it("keeps the RPC hardened and service-role-only",async()=>{
  const sql=await readFile(migrationPath,"utf8");
  assert.match(sql,/security definer set search_path=''/);
  assert.match(sql,/revoke all on function public\.submit_sales_tracking\(uuid,uuid,date,bigint,uuid,text\)from public,anon,authenticated/);
  assert.match(sql,/grant execute on function public\.submit_sales_tracking\(uuid,uuid,date,bigint,uuid,text\)to service_role/);
 });
});
