import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20260902120000_maintenance_phase1_nullif_runtime_repair.sql";
const source = () => readFile(path.resolve(migrationPath), "utf8");

describe("Maintenance Phase 1 NULLIF runtime repair", () => {
  it("replaces only the two affected runtime functions without a NULLIF workaround", async () => {
    const sql = await source();
    assert.deepEqual(
      [...sql.matchAll(/create or replace function\s+([^\s(]+)/gi)].map((match) => match[1]),
      ["private.create_maintenance_issue_core", "public.create_maintenance_purchase_log_v2"],
    );
    assert.doesNotMatch(sql, /\bnullif\s*\(/i);
    assert.doesNotMatch(sql, /pg_catalog\.nullif/i);
    assert.equal((sql.match(/set search_path = ''/g) ?? []).length, 2);
  });

  it("preserves issue defaults and controlled UUID validation", async () => {
    const sql = await source();
    const issue = sql.slice(
      sql.indexOf("create or replace function private.create_maintenance_issue_core"),
      sql.indexOf("create or replace function public.create_maintenance_purchase_log_v2"),
    );
    assert.match(issue, /case when payload->>'category' = '' then null else payload->>'category' end,[\s\S]*'other'/);
    assert.match(issue, /case when payload->>'priority' = '' then null else payload->>'priority' end,[\s\S]*'normal'/);
    assert.match(issue, /when payload->>'issue_id' is null or payload->>'issue_id' = '' then null[\s\S]*else \(payload->>'issue_id'\)::uuid/);
    assert.match(issue, /exception when others then[\s\S]*invalid maintenance issue payload'[\s\S]*errcode = '22023'/);
    assert.match(issue, /require_supervisor_maintenance_branch/);
    assert.match(issue, /actor_manages_active_organization/);
  });

  it("preserves purchase UUID fallback, payment, and idempotency semantics", async () => {
    const sql = await source();
    const purchase = sql.slice(sql.indexOf("create or replace function public.create_maintenance_purchase_log_v2"));
    for (const field of ["purchase_id", "branch_id", "idempotency_key"] as const) {
      assert.match(purchase, new RegExp(`when payload->>'${field}' is null or payload->>'${field}' = '' then null`));
    }
    assert.match(purchase, /when payload->>'request_hash' = '' then null/);
    assert.match(purchase, /when attachment->>'id' is null or attachment->>'id' = '' then null[\s\S]*else \(attachment->>'id'\)::uuid/);
    assert.match(purchase, /attachment_id := case[\s\S]*exception when others then[\s\S]*invalid maintenance purchase payload'[\s\S]*errcode = '22023'/);
    assert.match(purchase, /private\.clean_maintenance_payment_method\(payload->>'payment_method'\)/);
    assert.match(purchase, /on conflict \(organization_id, maintenance_issue_id, idempotency_key\)[\s\S]*purchase_type = 'issue'/);
    assert.match(purchase, /on conflict \(organization_id, idempotency_key\)[\s\S]*purchase_type = 'general'/);
    assert.match(purchase, /saved\.request_hash is distinct from request_fingerprint[\s\S]*errcode = '40001'/);
  });
});
