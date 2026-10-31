import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migration = (name: string) => path.resolve("supabase/migrations", name);
const preflight = (name: string) => path.resolve("supabase/preflight", name);
const databaseTest = (name: string) => path.resolve("supabase/tests/database", name);

const privilegeName = "20261101130000_inventory_items_client_write_privilege_hardening";
const carryName = "20261101140000_inventory_items_carry_forward_compatibility";

describe("Inventory Items Production dependency remediations", () => {
  it("leaves the approved populated-delete migration byte-identical", async () => {
    const bytes = await readFile(migration("20261101120000_inventory_item_usage_populated_row_delete.sql"));
    assert.equal(
      createHash("sha256").update(bytes).digest("hex"),
      "2ee815a4c72ccc80e9a897611d886745b74f6fe805d8aaeff3e28875e731c444",
    );
  });

  it("limits the privilege migration to the confirmed client write grants", async () => {
    const sql = await readFile(migration(`${privilegeName}.sql`), "utf8");
    assert.match(sql, /revoke insert,update,delete\s+on table public\.inventory_items_reports,public\.inventory_item_usage_day_values\s+from anon,authenticated/);
    assert.doesNotMatch(sql, /revoke all\s+on table/i);
    assert.doesNotMatch(sql, /\b(?:insert into|update|delete from)\s+public\./i);
    assert.match(sql, /num_nonnulls\([\s\S]*delete_inventory_item_usage_item\(uuid,uuid,uuid\)[\s\S]*delete_inventory_item_usage_item\(uuid,uuid,uuid,jsonb\)/);
    assert.match(sql, /has_function_privilege\('service_role'/);
    assert.doesNotMatch(sql, /organization_manager|sales_tracking|maintenance|purchase/i);
  });

  it("restores the exact carry-forward behavior without Inventory table DML", async () => {
    const sql = await readFile(migration(`${carryName}.sql`), "utf8");
    assert.match(sql, /create or replace function private\.inventory_items_carry_forward_items_json\([\s\S]*target_organization_id uuid,[\s\S]*target_branch_id uuid,[\s\S]*target_inventory_month date,[\s\S]*target_report_id uuid/);
    assert.equal([...sql.matchAll(/source_item\.deleted_at is null/g)].length, 2);
    assert.match(sql, /where target_item\.report_id = target_report_id/);
    assert.match(sql, /row_number\(\) over \([\s\S]*partition by[\s\S]*source_item\.group_name[\s\S]*source_item\.item_name/);
    assert.match(sql, /where source_item\.identity_rank = 1/);
    assert.match(sql, /carry_overload_count=0[\s\S]*carry_overload_count=1/);
    assert.match(sql, /Existing Inventory Items carry-forward contract is partial or incompatible/);
    assert.match(sql, /else private\.inventory_items_carry_forward_items_json\([\s\S]*ctx\.organization_id,[\s\S]*ctx\.branch_id,[\s\S]*selected_month,[\s\S]*report\.id/);
    assert.doesNotMatch(sql, /^\s*(?:insert|update|delete|truncate)\s+(?:into\s+|from\s+)?public\./gim);
    assert.doesNotMatch(sql, /organization_manager|sales_tracking|maintenance|purchase/i);
  });

  it("keeps both Production diagnostics SELECT-only and fail-closed", async () => {
    for (const name of [privilegeName, carryName]) {
      const sql = await readFile(preflight(`${name}.production_read_only.sql`), "utf8");
      assert.match(sql, /overall_readiness/);
      assert.doesNotMatch(sql, /^\s*(?:begin|commit|rollback|insert|update|delete|alter|create|drop|truncate|grant|revoke|call|do)\b/gim);
    }
  });

  it("keeps both SQL Editor preflights rollback-only with bounded timeouts", async () => {
    for (const name of [privilegeName, carryName]) {
      const sql = await readFile(preflight(`${name}.transactional.sql`), "utf8");
      assert.match(sql, /^begin;/m);
      assert.match(sql, /set local lock_timeout='5s'/);
      assert.match(sql, /set local statement_timeout=/);
      assert.match(sql, /rollback;\s*$/);
      assert.doesNotMatch(sql, /^commit;/m);
    }
  });

  it("adds focused rollback-only pgTAP coverage", async () => {
    const privilegeTest = await readFile(databaseTest("inventory_items_client_write_privilege_hardening.test.sql"), "utf8");
    const carryTest = await readFile(databaseTest("inventory_items_carry_forward_compatibility.test.sql"), "utf8");
    assert.match(privilegeTest, /select plan\(13\)/);
    assert.equal([...privilegeTest.matchAll(/^select (?:ok|is|has_function|throws_ok|lives_ok)\(/gm)].length, 13);
    assert.match(carryTest, /select plan\(17\)/);
    assert.equal([...carryTest.matchAll(/^select (?:ok|is|has_function|throws_ok|lives_ok)\(/gm)].length, 17);
    assert.match(carryTest, /source tombstone is excluded/);
    assert.match(carryTest, /target-month history, including a tombstone, prevents reseeding/);
    assert.match(carryTest, /organization and branch isolated/);
    assert.match(privilegeTest, /service_role retains/);
    assert.match(privilegeTest, /browser roles cannot execute/);
    assert.match(privilegeTest, /rollback;\s*$/);
    assert.match(carryTest, /rollback;\s*$/);
  });
});
