import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20260929130000_sales_tracking_restore_online_provider_amounts.sql";

describe("Sales Tracking explicit-date provider persistence migration", () => {
  it("replaces only the exact seven-argument draft RPC", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /create or replace function public\.save_sales_tracking_draft\(\s*actor_user_id uuid,\s*target_branch_id uuid,\s*target_business_date date,\s*expected_revision bigint,\s*entry_period text,\s*sales_rows jsonb,\s*cash_rows jsonb\s*\)/s);
    assert.equal((sql.match(/create or replace function public\./g) ?? []).length, 1);
    assert.match(sql, /returns jsonb\s*language plpgsql\s*security definer\s*set search_path to ''/s);
  });

  it("preserves explicit-date, lock, revision, period, cash, and current-state behavior", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /target_business_date is null/);
    assert.match(sql, /v_business_date>c\.business_date/);
    assert.match(sql, /validate_sales_tracking_entry_dates\(sales_rows,v_business_date\)/);
    assert.match(sql, /pg_advisory_xact_lock/);
    assert.match(sql, /for update/);
    assert.match(sql, /branch_revision=branch_revision\+1/);
    assert.match(sql, /insert into public\.sales_tracking_period_entries/);
    assert.match(sql, /insert into public\.sales_tracking_cash_rows/);
    assert.match(sql, /return public\.get_sales_tracking_current_state\(actor_user_id,target_branch_id,v_business_date\)/);
  });

  it("restores scoped provider validation, total validation, and row persistence", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /v->'online_amounts'/);
    assert.match(sql, /count\(distinct a->>'provider_id'\)/);
    assert.match(sql, /provider\.organization_id=c\.organization_id and provider\.branch_id=c\.branch_id and provider\.active/);
    assert.match(sql, /sales tracking online provider total mismatch/);
    assert.match(sql, /returning\*into sales_row/);
    assert.match(sql, /insert into public\.sales_tracking_online_amounts\(sales_row_id,provider_id,amount\)/);
    assert.match(sql, /select sales_row\.id,\(a->>'provider_id'\)::uuid,private\.sales_tracking_numeric_field\(a,'amount'\)/);
  });

  it("keeps the stale-revision conflict non-retryable and preserves grants", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /raise sqlstate 'PT409' using message='sales tracking changed'/);
    assert.doesNotMatch(sql, /40001/);
    assert.match(sql, /revoke all on function public\.save_sales_tracking_draft\(uuid,uuid,date,bigint,text,jsonb,jsonb\)\s*from public,anon,authenticated/);
    assert.match(sql, /grant execute on function public\.save_sales_tracking_draft\(uuid,uuid,date,bigint,text,jsonb,jsonb\)\s*to service_role/);
  });
});
