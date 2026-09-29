import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20260929140000_sales_tracking_require_online_provider_breakdown.sql";

describe("Sales Tracking mandatory online provider breakdown migration", () => {
  it("replaces only the exact provider-aware seven-argument draft RPC", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /create or replace function public\.save_sales_tracking_draft\(\s*actor_user_id uuid,\s*target_branch_id uuid,\s*target_business_date date,\s*expected_revision bigint,\s*entry_period text,\s*sales_rows jsonb,\s*cash_rows jsonb\s*\)/s);
    assert.equal((sql.match(/create or replace function public\./g) ?? []).length, 1);
    assert.match(sql, /returns jsonb\s*language plpgsql\s*security definer\s*set search_path to ''/s);
  });

  it("requires a provider array for a positive aggregate and permits an empty zero aggregate", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /sales_tracking_numeric_field\(v,'online_delivery'\)>0 and pg_catalog\.jsonb_array_length\(provider_amounts\)=0/);
    assert.match(sql, /raise exception'online provider breakdown required'using errcode='22023'/);
    assert.match(sql, /provider_total<>private\.sales_tracking_numeric_field\(v,'online_delivery'\)/);
    assert.match(sql, /insert into public\.sales_tracking_online_amounts\(sales_row_id,provider_id,amount\)/);
  });

  it("preserves date, locking, revisions, period writes, cash writes, and current-state return", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    for (const pattern of [
      /v_business_date:=target_business_date/,
      /pg_advisory_xact_lock/,
      /for update/,
      /branch_revision=branch_revision\+1/,
      /insert into public\.sales_tracking_period_entries/,
      /returning\*into sales_row/,
      /insert into public\.sales_tracking_cash_rows/,
      /return public\.get_sales_tracking_current_state\(actor_user_id,target_branch_id,v_business_date\)/,
    ]) assert.match(sql, pattern);
  });

  it("keeps stale revisions on PT409 and never reintroduces 40001", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /raise sqlstate 'PT409' using message='sales tracking changed'/);
    assert.doesNotMatch(sql, /40001/);
  });

  it("maps only the known database validation to the safe HTTP 422 message", async () => {
    const [persistence, app] = await Promise.all([
      readFile(path.resolve("src/backend/checklist-persistence.ts"), "utf8"),
      readFile(path.resolve("src/backend/app.ts"), "utf8"),
    ]);
    assert.match(persistence, /code==="22023"&&message==="online provider breakdown required"/);
    assert.match(persistence, /throw new SalesTrackingOnlineProviderBreakdownRequiredError\(\)/);
    assert.match(persistence, /throwChecklistRpcError\(result\.error\.code,result\.error\.message\)/);
    assert.match(app, /SalesTrackingOnlineProviderBreakdownRequiredError/);
    assert.match(app, /422,"unprocessable_entity","Enter the online order breakdown before saving\."/);
  });
});
