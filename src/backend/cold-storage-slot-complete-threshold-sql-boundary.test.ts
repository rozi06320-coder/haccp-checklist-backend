import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261026020000_cold_storage_slot_complete_equipment_threshold.sql");

describe("Cold Storage slot complete equipment threshold SQL boundary", () => {
  it("enforces explicit transaction boundaries", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /^\s*begin\s*;/i);
    assert.match(migration, /;\s*commit\s*;\s*$/i);
  });

  it("targets only private.cold_storage_managed_missed_issue_rows_at and its permissions", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function private\.cold_storage_managed_missed_issue_rows_at\s*\(/);
    // Does not redefine other modules
    assert.doesNotMatch(migration, /create or replace function private\.phase4a_/);
    assert.doesNotMatch(migration, /create or replace function private\.oil_tracking_/);
    assert.doesNotMatch(migration, /create or replace function private\.sales_tracking_/);
  });

  it("enforces full equipment threshold: all active equipment required per slot", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(
      migration,
      /having\s+pg_catalog\.count\(\s*distinct\s+reading\.equipment_id\s*\)\s*>=\s*unit\.active_count\s+and\s+unit\.active_count\s*>\s*0/i,
    );
    assert.match(migration, /reading\.submitted_at\s+is\s+not\s+null/i);
    assert.match(migration, /equipment\.active/i);
  });

  it("maintains strict SECURITY DEFINER and search_path hygiene", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /security\s+definer/i);
    assert.match(migration, /set\s+search_path\s*=\s*''/i);
    assert.match(
      migration,
      /revoke\s+all\s+on\s+function\s+private\.cold_storage_managed_missed_issue_rows_at\(uuid,\s*timestamptz\)\s+from\s+public,\s*anon,\s*authenticated;/i,
    );
    assert.match(
      migration,
      /grant\s+execute\s+on\s+function\s+private\.cold_storage_managed_missed_issue_rows_at\(uuid,\s*timestamptz\)\s+to\s+service_role;/i,
    );
  });

  it("preserves deterministic single-issue-per-slot cardinality", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /private\.cold_storage_missed_issue_id\(\s*unit\.submission_id,\s*missed\.slot\s*\)/);
    assert.match(migration, /private\.management_missed_issue_id\(\s*'cold_storage:missed:'/);
  });

  it("contains no table mutations or destructive DDL", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.doesNotMatch(migration, /\b(insert\s+into|update|delete\s+from|truncate|drop\s+table)\b/i);
  });
});
