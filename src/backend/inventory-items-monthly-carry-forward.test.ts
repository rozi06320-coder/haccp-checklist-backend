import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve(
  "supabase/migrations/20261010130000_inventory_items_monthly_item_carry_forward.sql",
);

describe("Inventory Items monthly Item Usage carry-forward", () => {
  it("projects from the latest submitted month in the same organization and branch", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /create or replace function private\.inventory_items_carry_forward_items_json\(/);
    assert.match(migration, /source_report\.organization_id = target_organization_id/);
    assert.match(migration, /source_report\.branch_id = target_branch_id/);
    assert.match(migration, /source_report\.inventory_month < target_inventory_month/);
    assert.match(migration, /source_report\.state = 'submitted'/);
    assert.match(migration, /source_report\.submitted_at is not null/);
    assert.match(migration, /source_item\.deleted_at is null/);
    assert.match(migration, /source_report\.inventory_month desc,[\s\S]*source_report\.submitted_at desc,[\s\S]*source_report\.id desc/);
  });

  it("suppresses seeding for all target Item Usage history including tombstones", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /target_report_id is not null and exists \([\s\S]*target_item\.report_id = target_report_id/);
    assert.match(migration, /when exists \([\s\S]*target_item\.report_id = report\.id[\s\S]*then coalesce/);
    assert.doesNotMatch(migration, /target_item\.deleted_at is null/);
  });

  it("returns deterministic id-less names with empty usage and no copied values", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const helper = migration.slice(
      migration.indexOf("create or replace function private.inventory_items_carry_forward_items_json"),
      migration.indexOf("revoke all on function private.inventory_items_carry_forward_items_json"),
    );

    assert.match(helper, /partition by[\s\S]*lower\(pg_catalog\.regexp_replace[\s\S]*group_name[\s\S]*lower\(pg_catalog\.regexp_replace[\s\S]*item_name/);
    assert.match(helper, /where source_item\.identity_rank = 1/);
    assert.match(helper, /'group_name', source_item\.group_name/);
    assert.match(helper, /'item_name', source_item\.item_name/);
    assert.match(helper, /'usage', '\{\}'::jsonb/);
    assert.doesNotMatch(helper, /'id', source_item\.id/);
    assert.doesNotMatch(helper, /inventory_item_usage_day_values/);
    assert.doesNotMatch(helper, /inventory_beef_production_rows/);
  });

  it("keeps reads side-effect free and preserves the hardened state boundary", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.doesNotMatch(migration, /\binsert\s+into\b/i);
    assert.doesNotMatch(migration, /\bupdate\s+public\./i);
    assert.doesNotMatch(migration, /\bdelete\s+from\b/i);
    assert.match(migration, /select \* into strict ctx from private\.inventory_items_actor_context\(p_actor_user_id, p_target_branch_id\)/);
    assert.match(migration, /returns jsonb language plpgsql security definer set search_path = ''/);
    assert.match(migration, /revoke all on function private\.inventory_items_carry_forward_items_json\(uuid,uuid,date,uuid\)[\s\S]*from public, anon, authenticated/);
    assert.match(migration, /revoke all on function private\.inventory_items_state_json\(uuid,uuid,date\)[\s\S]*from public, anon, authenticated/);
    assert.doesNotMatch(migration, /grant execute/i);
  });

  it("preserves public RPC signatures by replacing only private state behavior", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /create or replace function private\.inventory_items_state_json\(/);
    assert.match(migration, /private\.inventory_items_carry_forward_items_json\([\s\S]*ctx\.organization_id,[\s\S]*ctx\.branch_id,[\s\S]*selected_month,[\s\S]*report\.id/);
    assert.doesNotMatch(migration, /create or replace function public\./);
    assert.doesNotMatch(migration, /branch_inventory_catalog_items/);
  });
});
