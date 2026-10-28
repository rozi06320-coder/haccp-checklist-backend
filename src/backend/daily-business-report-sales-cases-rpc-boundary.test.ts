import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const sql = readFileSync(
  new URL("../../supabase/migrations/20261028150000_daily_business_report_sales_cases_read_rpc.sql", import.meta.url),
  "utf8",
).toLowerCase();

describe("Daily Business Report Sales Tracking cases read RPC", () => {
  it("is read-only, scoped, and hardened", () => {
    assert.match(sql, /create or replace function public\.get_daily_business_report_sales_cases/);
    assert.match(sql, /stable[\s\S]*security definer[\s\S]*set search_path\s*=\s*''/);
    assert.match(sql, /private\.actor_manages_active_organization\(p_actor_user_id, p_organization_id\)/);
    assert.match(sql, /daily_business_report_generation_jobs job/);
    assert.match(sql, /job\.lease_expires_at > pg_catalog\.statement_timestamp\(\)/);
    assert.match(sql, /cases\.organization_id = p_organization_id/);
    assert.match(sql, /cases\.business_date = p_business_date/);
    assert.match(sql, /cases\.branch_id = any \(p_branch_ids\)/);
    assert.match(sql, /report\.case_id = cases\.id/);
    assert.match(sql, /report\.organization_id = cases\.organization_id/);
    assert.match(sql, /report\.branch_id = cases\.branch_id/);
    assert.match(sql, /report\.business_date = cases\.business_date/);
    assert.doesNotMatch(sql, /\binsert\s+into\b|\bupdate\s+[^;]+\bset\b|\bdelete\s+from\b|\btruncate\b/);
  });

  it("keeps the RPC-only ACL and never grants direct table SELECT", () => {
    assert.match(sql, /revoke all on function public\.get_daily_business_report_sales_cases\(uuid, uuid, date, uuid\[\], uuid, uuid\)[\s\S]*from public, anon, authenticated, service_role/);
    assert.match(sql, /grant execute on function public\.get_daily_business_report_sales_cases\(uuid, uuid, date, uuid\[\], uuid, uuid\)[\s\S]*to service_role/);
    assert.match(sql, /revoke all on public\.sales_tracking_report_cases from public, anon, authenticated, service_role/);
    assert.doesNotMatch(sql, /grant\s+select\s+on\s+(table\s+)?public\.sales_tracking_report_cases/);
  });
});
