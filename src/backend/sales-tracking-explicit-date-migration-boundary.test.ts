import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20260906120000_sales_tracking_explicit_business_date.sql";

describe("Sales Tracking explicit-date migration boundary", () => {
  it("adds explicit-date overloads without replacing no-date RPC signatures", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /create or replace function public\.get_sales_tracking_current_state\(actor_user_id uuid,target_branch_id uuid,target_business_date date\)/);
    assert.match(sql, /create or replace function public\.save_sales_tracking_draft\(actor_user_id uuid,target_branch_id uuid,target_business_date date,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb\)/);
    assert.match(sql, /create or replace function public\.submit_sales_tracking\(actor_user_id uuid,target_branch_id uuid,target_business_date date,expected_revision bigint,idempotency_key uuid,request_hash text\)/);
    assert.doesNotMatch(sql, /create or replace function public\.get_sales_tracking_current_state\(actor_user_id uuid,target_branch_id uuid\)/);
    assert.doesNotMatch(sql, /create or replace function public\.save_sales_tracking_draft\(actor_user_id uuid,target_branch_id uuid,expected_revision bigint/);
    assert.doesNotMatch(sql, /create or replace function public\.submit_sales_tracking\(actor_user_id uuid,target_branch_id uuid,expected_revision bigint/);
  });

  it("requires non-null explicit dates and rejects future dates against branch business date", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.equal((sql.match(/target_business_date is null/g) ?? []).length, 3);
    assert.equal((sql.match(/sales tracking business date required/g) ?? []).length, 3);
    assert.equal((sql.match(/v_business_date>c\.business_date/g) ?? []).length, 3);
    assert.doesNotMatch(sql, /coalesce\(target_business_date,c\.business_date\)/);
    assert.doesNotMatch(sql, /current_date/i);
  });

  it("keeps row entry dates, locking, idempotency, and submitted timestamps safe", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /validate_sales_tracking_entry_dates\(sales_rows,v_business_date\)/);
    assert.match(sql, /validate_sales_tracking_entry_dates\(cash_rows,v_business_date\)/);
    const submitBody = sql.slice(sql.indexOf("create or replace function public.submit_sales_tracking"));
    assert.ok(submitBody.indexOf("pg_advisory_xact_lock") < submitBody.indexOf("select*into prior from public.sales_tracking_submission_idempotency"));
    assert.match(submitBody, /x\.business_date=v_business_date and x\.state='submitted'/);
    assert.match(submitBody, /submitted_at=now\(\)/);
    assert.doesNotMatch(submitBody, /submitted_at\s*=\s*v_business_date/);
    assert.match(submitBody, /submitted_by_name_snapshot=c\.actor_name/);
  });

  it("does not rewrite helpers, historical data, RLS, or persistent schema outside the overloads", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.doesNotMatch(sql, /create or replace function private\.phase4a_business_date/);
    assert.doesNotMatch(sql, /alter table|drop table|truncate|delete from|update public\.sales_tracking_reports set currency_code|disable row level security/i);
    assert.match(sql, /security definer set search_path=''/);
    assert.match(sql, /grant execute on function public\.get_sales_tracking_current_state\(uuid,uuid,date\)/);
  });
});
