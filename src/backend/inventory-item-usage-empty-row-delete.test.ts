import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { createChecklistPersistence } from "./checklist-persistence";

const migrationPath = path.resolve("supabase/migrations/20261002130000_inventory_item_usage_empty_row_delete.sql");

describe("Inventory Items empty Item Usage row deletion", () => {
  it("adds a one-way tombstone and narrowly scoped service-role RPC", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /add column if not exists deleted_at timestamptz/);
    assert.match(migration, /add column if not exists deleted_by_user_id uuid/);
    assert.match(migration, /create or replace function public\.delete_inventory_item_usage_item\(/);
    assert.match(migration, /select \* into strict ctx from private\.phase4a_actor_context\(actor_user_id, target_branch_id\)/);
    assert.match(migration, /perform private\.lock_inventory_items_month\(target_branch_id, target_inventory_month\)/);
    assert.match(migration, /for update/);
    assert.match(migration, /target_report\.state <> 'draft'/);
    assert.match(migration, /inventory item has saved usage values/);
    assert.match(migration, /deleted_at = pg_catalog\.now\(\)/);
    assert.doesNotMatch(migration, /delete from public\.inventory_item_usage_items/);
    assert.match(migration, /revoke all on function public\.delete_inventory_item_usage_item\(uuid,uuid,uuid\)[\s\S]*from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.delete_inventory_item_usage_item\(uuid,uuid,uuid\)[\s\S]*to service_role/);
  });

  it("keeps arbitrary mutations immutable and blocks stale resurrection", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function private\.protect_inventory_usage_item\(\)/);
    assert.match(migration, /old\.deleted_at is null/);
    assert.match(migration, /new\.deleted_at is not null/);
    assert.match(migration, /new\.item_name is not distinct from old\.item_name/);
    assert.match(migration, /not exists \([\s\S]*public\.inventory_item_usage_day_values/);
    assert.match(migration, /existing_item\.deleted_at is not null[\s\S]*deleted inventory item cannot be restored/);
    assert.match(migration, /and item\.deleted_at is null[\s\S]*for update;\n      if existing_item\.id is null then[\s\S]*and item\.deleted_at is not null[\s\S]*for update;[\s\S]*deleted inventory item cannot be restored/);
    assert.match(migration, /deleted inventory item cannot be restored[\s\S]*if existing_item\.id is null then[\s\S]*insert into public\.inventory_item_usage_items/);
    assert.match(migration, /item\.deleted_at is null/);
  });

  it("excludes tombstones from supervisor and manager response builders", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function private\.inventory_items_state_json\([\s\S]*item\.deleted_at is null/);
    assert.match(migration, /create or replace function public\.list_managed_inventory_items_reports\([\s\S]*item\.deleted_at is null/);
    assert.match(migration, /create or replace function public\.get_managed_operations_summary\([\s\S]*item\.deleted_at is null/);
  });

  it("calls the exact delete RPC and accepts its strict current-state response", async () => {
    const current = {
      report_id: "10000000-0000-4000-8000-000000000001",
      business_date: "2026-10-02",
      inventory_month: "2026-10-01",
      state: "draft",
      updated_at: "2026-10-02T12:00:00.000Z",
      submitted_at: null,
      beef_production_labels: { russian_label: null, australian_label: null, hunch_sauce_label: null },
      beef_rows: [],
      item_usage: { usage_month: "2026-10-01", items: [] },
    };
    const server = createServer((request, response) => {
      assert.equal(request.url, "/rest/v1/rpc/delete_inventory_item_usage_item");
      let body = "";
      request.on("data", (chunk) => { body += String(chunk); });
      request.on("end", () => {
        assert.deepEqual(JSON.parse(body), {
          actor_user_id: "20000000-0000-4000-8000-000000000001",
          target_branch_id: "30000000-0000-4000-8000-000000000001",
          target_item_usage_id: "40000000-0000-4000-8000-000000000001",
        });
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify(current));
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const persistence = createChecklistPersistence(`http://127.0.0.1:${(server.address() as AddressInfo).port}`, "test-secret");
      assert.deepEqual(await persistence.deleteInventoryItemUsageItem?.({
        actorUserId: "20000000-0000-4000-8000-000000000001",
        branchId: "30000000-0000-4000-8000-000000000001",
        itemUsageId: "40000000-0000-4000-8000-000000000001",
      }), current);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
