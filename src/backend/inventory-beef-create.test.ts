import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { createChecklistPersistence } from "./checklist-persistence";

const migrationPath = path.resolve("supabase/migrations/20261003140000_inventory_beef_production_create.sql");

function rpcSection(source: string) {
  const start = source.indexOf("create or replace function public.create_inventory_beef_production_row(");
  const end = source.indexOf("revoke all on function public.create_inventory_beef_production_row", start);
  assert.notEqual(start, -1);
  assert.notEqual(end, -1);
  return source.slice(start, end);
}

describe("Inventory Items Beef Production create", () => {
  it("defines a service-role-only Beef-only RPC with canonical locking and response", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const rpc = rpcSection(migration);
    assert.match(migration, /public\.create_inventory_beef_production_row\([\s\S]*actor_user_id uuid,[\s\S]*target_branch_id uuid,[\s\S]*production_date date,[\s\S]*row_values jsonb/);
    assert.match(rpc, /private\.phase4a_actor_context\(actor_user_id, target_branch_id\)/);
    assert.match(rpc, /private\.lock_inventory_items_month\(target_branch_id, target_inventory_month\)/);
    assert.ok(rpc.indexOf("lock_inventory_items_month") < rpc.indexOf("for update"));
    assert.match(rpc, /target_report\.state <> 'draft'[\s\S]*errcode = '22023'/);
    assert.match(rpc, /inventory beef production date already exists'[\s\S]*errcode = '23505'/);
    assert.match(rpc, /return private\.inventory_items_state_json\(actor_user_id, target_branch_id, target_inventory_month\)/);
    assert.doesNotMatch(rpc, /item_usage|validate_inventory_item_usage|persist_inventory_items_daily_values/);
    assert.match(migration, /revoke all on function public\.create_inventory_beef_production_row\(uuid,uuid,date,jsonb\)[\s\S]*from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.create_inventory_beef_production_row\(uuid,uuid,date,jsonb\)[\s\S]*to service_role/);
  });

  it("validates only the six numeric fields and derives trusted label snapshots", async () => {
    const rpc = rpcSection(await readFile(migrationPath, "utf8"));
    for (const field of ["russian_kg", "australian_kg", "fat_kg", "ready_patty", "hunch_sauce_kg", "wastage_grams"]) {
      assert.match(rpc, new RegExp(`inventory_items_numeric_field\\(row_values, '${field}'\\)`));
    }
    assert.match(rpc, /coalesce\(settings\.beef_russian_label, 'Russian kg'\)/);
    assert.match(rpc, /coalesce\(settings\.beef_australian_label, 'Australian kg'\)/);
    assert.match(rpc, /coalesce\(settings\.beef_hunch_sauce_label, 'Hunch sauce kg'\)/);
    assert.match(rpc, /updated_by_user_id,[\s\S]*actor_user_id,[\s\S]*null,/);
    assert.doesNotMatch(rpc, /inventory_items_label_snapshot\(row_values|row_values\s*->>?\s*'[^']*label_snapshot/);
  });

  it("sends the exact create RPC arguments and decodes authoritative state", async () => {
    const productionDate = "2026-10-03";
    const rowValues = { russian_kg: "11", australian_kg: "5", fat_kg: "1", ready_patty: "4", hunch_sauce_kg: "2", wastage_grams: "20" };
    const response = { report_id: "10000000-0000-4000-8000-000000000001", business_date: productionDate, inventory_month: "2026-10-01", state: "draft", updated_at: "2026-10-03T08:01:00.000Z", submitted_at: null, beef_production_labels: { russian_label: null, australian_label: null, hunch_sauce_label: null }, beef_rows: [], item_usage: { usage_month: "2026-10-01", items: [] } };
    const server = createServer((request, result) => {
      assert.equal(request.url, "/rest/v1/rpc/create_inventory_beef_production_row");
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        assert.deepEqual(JSON.parse(body), { actor_user_id: "30000000-0000-4000-8000-000000000001", target_branch_id: "40000000-0000-4000-8000-000000000001", production_date: productionDate, row_values: rowValues });
        result.writeHead(200, { "Content-Type": "application/json" });
        result.end(JSON.stringify(response));
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const persistence = createChecklistPersistence(`http://127.0.0.1:${(server.address() as AddressInfo).port}`, "test-secret");
      assert.deepEqual(await persistence.createInventoryBeefProductionRow?.({ actorUserId: "30000000-0000-4000-8000-000000000001", branchId: "40000000-0000-4000-8000-000000000001", productionDate, rowValues }), response);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
