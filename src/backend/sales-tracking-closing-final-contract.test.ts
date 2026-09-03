import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath="supabase/migrations/20260903100000_sales_tracking_closing_final_workflow.sql";

describe("Sales Tracking Closing-final migration contract",()=>{
 it("keeps the authoritative signatures, locks, security, and grants",async()=>{
  const migration=await readFile(path.resolve(migrationPath),"utf8");
  assert.match(migration,/create or replace function public\.save_sales_tracking_draft\(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb\)/);
  assert.match(migration,/create or replace function public\.submit_sales_tracking\(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text\)/);
  assert.equal((migration.match(/security definer set search_path=''/g)??[]).length,2);
  assert.equal((migration.match(/pg_advisory_xact_lock/g)??[]).length,2);
  assert.equal((migration.match(/for update/g)??[]).length,2);
  assert.match(migration,/revoke execute on function public\.save_sales_tracking_draft\(uuid,uuid,bigint,text,jsonb,jsonb\),public\.submit_sales_tracking\(uuid,uuid,bigint,uuid,text\) from public,anon,authenticated/);
  assert.match(migration,/grant execute on function public\.save_sales_tracking_draft\(uuid,uuid,bigint,text,jsonb,jsonb\),public\.submit_sales_tracking\(uuid,uuid,bigint,uuid,text\) to service_role/);
 });

 it("serializes period saves and rejects Middle after Closing",async()=>{
  const migration=await readFile(path.resolve(migrationPath),"utf8");
  const save=migration.slice(migration.indexOf("create or replace function public.save_sales_tracking_draft"),migration.indexOf("create or replace function public.submit_sales_tracking"));
  const advisory=save.indexOf("pg_advisory_xact_lock");
  const reportLock=save.indexOf("for update");
  const closingGuard=save.indexOf("entry_period='middle_shift' and exists");
  const periodInsert=save.indexOf("insert into public.sales_tracking_period_entries");
  assert.ok(advisory>=0&&advisory<reportLock&&reportLock<closingGuard&&closingGuard<periodInsert);
  assert.match(save,/x\.entry_period='closing_shift'\)then raise exception'sales tracking closing period already saved'using errcode='23505'/);
  assert.match(save,/sales tracking period already saved/);
  assert.match(save,/private\.validate_sales_tracking_sales_rows/);
  assert.match(save,/private\.validate_sales_tracking_cash_rows/);
  assert.match(save,/sales_tracking_online_order_providers/);
  assert.match(save,/sales_tracking_online_amounts/);
 });

 it("requires one Closing period and permits an optional Middle period",async()=>{
  const migration=await readFile(path.resolve(migrationPath),"utf8");
  const submit=migration.slice(migration.indexOf("create or replace function public.submit_sales_tracking"));
  assert.match(submit,/count\(\*\)filter\(where p\.entry_period='closing_shift'\)/);
  assert.match(submit,/count\(\*\)filter\(where p\.entry_period not in\('middle_shift','closing_shift'\)\)/);
  assert.match(submit,/period_count<1 or period_count>2 or closing_count<>1 or invalid_period_count<>0/);
  assert.doesNotMatch(submit,/period_count<>2|count\(\*\)[^;]*<>2/);
  assert.match(submit,/sales_tracking_submission_idempotency/);
  assert.match(submit,/submitted_at=now\(\),branch_revision=branch_revision\+1/);
  assert.match(submit,/return public\.get_sales_tracking_current_state/);
 });

 it("does not alter Manager readers, totals, the business-day helper, or parent uniqueness",async()=>{
  const migration=await readFile(path.resolve(migrationPath),"utf8");
  assert.doesNotMatch(migration,/create or replace function public\.(?:list_managed|get_managed)|phase4a_business_date|alter table|create unique index|drop constraint/i);
  const periodMigration=await readFile(path.resolve("supabase/migrations/20260812041200_sales_tracking_two_period_daily_report.sql"),"utf8");
  assert.match(periodMigration,/unique\(report_id, entry_period\)/);
  const businessDayMigration=await readFile(path.resolve("supabase/migrations/20260829110000_phase4a_0300_business_day.sql"),"utf8");
  assert.match(businessDayMigration,/\(\(as_of at time zone tz\) - interval '3 hours'\)::date/);
 });
});
