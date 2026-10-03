import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { createChecklistPersistence } from "./checklist-persistence";

const migrationPath = path.resolve("supabase/migrations/20261003120000_inventory_beef_production_saved_row_edit.sql");

function section(source: string, start: string, end?: string) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : -1;
  return to === -1 ? source.slice(from) : source.slice(from, to);
}

describe("Inventory Items saved Beef Production row edit", () => {
  it("adds updater attribution and a service-role-only narrow RPC", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /add column if not exists updated_by_user_id uuid/);
    assert.match(migration, /references auth\.users\(id\) on delete restrict/);
    assert.match(migration, /public\.update_inventory_beef_production_row\([\s\S]*?actor_user_id uuid,[\s\S]*?target_branch_id uuid,[\s\S]*?target_row_id uuid,[\s\S]*?expected_updated_at timestamptz,[\s\S]*?row_values jsonb/);
    assert.match(migration, /revoke all on function public\.update_inventory_beef_production_row\(uuid,uuid,uuid,timestamptz,jsonb\)[\s\S]*?from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.update_inventory_beef_production_row\(uuid,uuid,uuid,timestamptz,jsonb\)[\s\S]*?to service_role/);
  });

  it("locks and scopes the row, enforces optimistic concurrency, and returns authoritative state", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const rpc = section(migration, "create or replace function public.update_inventory_beef_production_row(", "revoke all on function public.update_inventory_beef_production_row");
    assert.match(rpc, /private\.phase4a_actor_context\(actor_user_id, target_branch_id\)/);
    assert.match(rpc, /private\.lock_inventory_items_month\(target_branch_id, target_inventory_month\)/);
    assert.ok(rpc.indexOf("lock_inventory_items_month") < rpc.indexOf("for update"));
    assert.match(rpc, /target_report\.organization_id <> ctx\.organization_id[\s\S]*target_report\.branch_id <> ctx\.branch_id[\s\S]*errcode = '42501'/);
    assert.match(rpc, /target_report\.state <> 'draft'[\s\S]*errcode = '23514'/);
    assert.match(rpc, /target_row\.updated_at is distinct from expected_updated_at[\s\S]*errcode = '40001'/);
    assert.match(rpc, /return private\.inventory_items_state_json\(actor_user_id, target_branch_id, target_inventory_month\)/);
  });

  it("permits only numeric values while preserving row identity and snapshots", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const trigger = section(migration, "create or replace function private.protect_inventory_beef_daily_row()", "revoke all on function private.protect_inventory_beef_daily_row()");
    const rpc = section(migration, "create or replace function public.update_inventory_beef_production_row(", "revoke all on function public.update_inventory_beef_production_row");
    for (const immutable of ["id", "report_id", "production_date", "created_by", "created_at", "russian_label_snapshot", "australian_label_snapshot", "hunch_sauce_label_snapshot"]) {
      assert.match(trigger, new RegExp(`new\\.${immutable} is distinct from old\\.${immutable}`));
    }
    assert.match(trigger, /tg_op = 'DELETE'[\s\S]*errcode = '23505'/);
    for (const field of ["russian_kg", "australian_kg", "fat_kg", "ready_patty", "hunch_sauce_kg", "wastage_grams"]) {
      assert.match(rpc, new RegExp(`${field} = parsed_${field}`));
    }
    assert.doesNotMatch(rpc, /production_date\s*=/);
    assert.doesNotMatch(rpc, /label_snapshot\s*=/);
    assert.match(rpc, /updated_by_user_id = actor_user_id/);
  });

  it("sends the exact RPC arguments and accepts updater metadata in the strict decoder", async () => {
    const rowId = "20000000-0000-4000-8000-000000000001";
    const expectedUpdatedAt = "2026-10-03T08:00:00.000Z";
    const rowValues = { russian_kg: "11", australian_kg: "5", fat_kg: "1", ready_patty: "4", hunch_sauce_kg: "2", wastage_grams: "20" };
    const response = {
      report_id: "10000000-0000-4000-8000-000000000001",
      business_date: "2026-10-03",
      inventory_month: "2026-10-01",
      state: "draft",
      updated_at: "2026-10-03T08:01:00.000Z",
      submitted_at: null,
      beef_production_labels: { russian_label: null, australian_label: null, hunch_sauce_label: null },
      beef_rows: [{ id: rowId, production_date: "2026-10-03", ...rowValues, total_kg: "17", russian_label_snapshot: "Russian kg", australian_label_snapshot: "Australian kg", hunch_sauce_label_snapshot: "Hunch sauce kg", updated_at: "2026-10-03T08:01:00.000Z", updated_by_user_id: "30000000-0000-4000-8000-000000000001" }],
      item_usage: { usage_month: "2026-10-01", items: [] },
    };
    const server = createServer((request, result) => {
      assert.equal(request.url, "/rest/v1/rpc/update_inventory_beef_production_row");
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        assert.deepEqual(JSON.parse(body), { actor_user_id: "30000000-0000-4000-8000-000000000001", target_branch_id: "40000000-0000-4000-8000-000000000001", target_row_id: rowId, expected_updated_at: expectedUpdatedAt, row_values: rowValues });
        result.writeHead(200, { "Content-Type": "application/json" });
        result.end(JSON.stringify(response));
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const persistence = createChecklistPersistence(`http://127.0.0.1:${(server.address() as AddressInfo).port}`, "test-secret");
      const decoded = await persistence.updateInventoryBeefProductionRow?.({ actorUserId: "30000000-0000-4000-8000-000000000001", branchId: "40000000-0000-4000-8000-000000000001", rowId, expectedUpdatedAt, rowValues });
      assert.deepEqual(decoded, response);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
