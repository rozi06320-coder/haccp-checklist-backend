import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationUrl = new URL(
  "../../supabase/migrations/20261028130000_supervisor_cold_storage_three_stage_progress.sql",
  import.meta.url,
);

describe("Supervisor Overview Cold Storage stage progress migration", () => {
  it("uses the three canonical slots and requires every active unit to submit", async () => {
    const sql = await readFile(migrationUrl, "utf8");

    assert.match(sql, /values \('12:00'\),\('20:00'\),\('02:00'\)/);
    assert.match(sql, /count\(distinct e\.equipment_id\)/);
    assert.match(sql, /r\.submitted_at is not null/);
    assert.match(sql, /r\.temperature_c is not null/);
    assert.match(sql, /r\.status in \('pass','fail'\)/);
    assert.match(sql, /valid_reading_count=active_equipment_count/);
    assert.match(sql, /then 3 else 0 end/);
    assert.match(sql, /raise exception 'failed to locate Supervisor Overview cold-storage metrics'/);
  });

  it("does not replace authorization, tenant, or business-date predicates", async () => {
    const sql = await readFile(migrationUrl, "utf8");

    assert.match(sql, /public\.get_phase4a_supervisor_overview\(uuid,uuid\)/);
    assert.match(sql, /where s\.organization_id=c\.organization_id/);
    assert.match(sql, /and s\.branch_id=c\.branch_id/);
    assert.match(sql, /and s\.business_date=c\.business_date/);
    assert.match(sql, /execute updated_definition/);
  });
});
