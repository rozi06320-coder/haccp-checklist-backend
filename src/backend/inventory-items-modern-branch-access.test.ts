import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve(
  "supabase/migrations/20261008210000_inventory_items_modern_branch_access.sql",
);

describe("Inventory Items modern branch access migration", () => {
  it("uses phase2 branch context and keeps legacy team attribution optional", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /alter column supervisor_team_id drop not null/);
    assert.match(migration, /from private\.phase2_branch_context\(actor_user_id, target_branch_id\)/);
    assert.match(migration, /context\.legacy_team_id/);
    assert.match(migration, /private\.inventory_items_actor_context/);
    assert.doesNotMatch(migration, /\bcommit\s*;/i);
  });

  it("rewrites every ledger routine that directly used legacy authorization", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const signatures = [
      "private.inventory_items_state_json(uuid,uuid,date)",
      "public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)",
      "public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)",
      "public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)",
      "public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)",
      "public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb)",
      "public.delete_inventory_item_usage_item(uuid,uuid,uuid)",
    ];

    for (const signature of signatures) assert.ok(migration.includes(signature), signature);
    assert.match(migration, /legacy_reference_count <> 1/);
    assert.match(migration, /Inventory Items legacy authorization reference remains/);
  });

  it("preserves backend-only execution and leaves catalog contracts untouched", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /from public, anon, authenticated/);
    assert.match(migration, /to service_role/);
    assert.doesNotMatch(migration, /branch_catalog|catalog_inventory|require_branch_catalog_scope/);
  });
});
