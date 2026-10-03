import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL(
  "../../supabase/migrations/20261003150000_phase2_modern_branch_access.sql",
  import.meta.url,
);

describe("Phase 2 modern branch access SQL boundary", () => {
  it("makes only the remaining Phase 2 legacy attribution columns nullable", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const tables = [
      "oil_tracking_submissions",
      "cold_storage_submissions",
      "sales_tracking_reports",
      "checklist_submissions",
      "checklist_issue_evidence",
      "branch_suppliers",
      "branch_supplier_receivings",
    ];

    for (const table of tables) {
      assert.match(
        migration,
        new RegExp(`alter table public\\.${table}\\s+alter column supervisor_team_id drop not null`, "i"),
      );
    }
    assert.equal((migration.match(/alter column supervisor_team_id drop not null/gi) ?? []).length, tables.length);
    assert.doesNotMatch(migration, /drop constraint|drop column|delete from|update public\./i);
  });

  it("preserves the context contract and delegates authorization to the canonical helper", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /create or replace function private\.phase2_branch_context\(actor uuid, target_branch uuid\)/);
    assert.match(
      migration,
      /returns table\(\s*organization_id uuid,\s*branch_id uuid,\s*legacy_team_id uuid,\s*business_date date,\s*branch_name text,\s*branch_code text,\s*actor_name text\s*\)/,
    );
    assert.match(migration, /language sql\s+stable\s+security definer\s+set search_path = ''/);
    assert.match(migration, /private\.actor_can_read_operational_branch\(actor, target_branch\)/);
    assert.match(migration, /profile\.disabled_at is null/);
    assert.match(migration, /not profile\.must_change_password/);
    assert.doesNotMatch(migration, /organization_memberships|branch_operational_team_supervisors/);
  });

  it("keeps legacy attribution deterministic and optional without changing privileges", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /left join lateral \([\s\S]*from public\.branch_supervisor_teams legacy/);
    assert.match(migration, /legacy\.supervisor_user_id = actor/);
    assert.match(migration, /legacy\.branch_id = branch\.id/);
    assert.match(migration, /legacy\.organization_id = branch\.organization_id/);
    assert.match(migration, /order by legacy\.active desc, legacy\.created_at, legacy\.id\s+limit 1/);
    assert.doesNotMatch(migration, /\bgrant\b|\brevoke\b/i);
  });
});
