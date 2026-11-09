import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { createChecklistPersistence } from "./checklist-persistence";

const appPath = path.resolve("src/backend/app.ts");
const persistencePath = path.resolve("src/backend/checklist-persistence.ts");
const migrationPath = path.resolve("supabase/migrations/20261108120000_inventory_item_usage_edit_draft.sql");

describe("Inventory Items saved Item Usage edit API contract", () => {
  it("exposes the authenticated PATCH route with strict request validation", async () => {
    const app = await readFile(appPath, "utf8");
    assert.match(app, /app\.patch\("\/api\/v1\/supervisor\/branches\/:branchId\/inventory-items\/item-usage\/:itemUsageId"/);
    assert.match(app, /inventoryItemUsageEditBodySchema=z\.object\(\{[\s\S]*expected_report_updated_at:z\.iso\.datetime\(\{offset:true\}\)[\s\S]*expected_usage:inventoryUsageValueSchema[\s\S]*new_usage:inventoryUsageValueSchema[\s\S]*\}\)\.strict\(\)/);
    assert.match(app, /idempotencySchema\.safeParse\(request\.header\("Idempotency-Key"\)\)/);
    assert.match(app, /!dependencies\.checklistPersistence\?\.updateInventoryItemUsageEntry/);
    assert.match(app, /status\(200\)\.json\(\{current\}\)/);
  });

  it("maps validation, authorization, stale, not-found, and service failures without fabricating state", async () => {
    const app = await readFile(appPath, "utf8");
    assert.match(app, /function inventoryItemUsageEditError\(error:unknown\)/);
    assert.match(app, /ChecklistConflictError\)return new HttpError\(409/);
    assert.match(app, /ChecklistInputError\)return new HttpError\(422/);
    assert.match(app, /ChecklistAccessError\)return new HttpError\(403/);
    assert.match(app, /ChecklistNotFoundError\)return new HttpError\(404/);
    assert.match(app, /Unable to update Item Usage right now/);
    assert.match(app, /inventoryItemsCurrentSchema\.parse\(await dependencies\.checklistPersistence\.updateInventoryItemUsageEntry/);
  });

  it("calls the exact service-role RPC contract and preserves the canonical response parser", async () => {
    const persistence = await readFile(persistencePath, "utf8");
    assert.match(persistence, /updateInventoryItemUsageEntry\?\(input:\{actorUserId:string;branchId:string;itemUsageId:string;expectedReportUpdatedAt:string;expectedUsage:Record<string,string\|number>;newUsage:Record<string,string\|number>;idempotencyKey:string\}\)/);
    assert.match(persistence, /rpc\("update_inventory_item_usage_entry",\{actor_user_id:input\.actorUserId,target_branch_id:input\.branchId,target_item_usage_id:input\.itemUsageId,expected_report_updated_at:input\.expectedReportUpdatedAt,expected_usage:input\.expectedUsage,new_usage:input\.newUsage,idempotency_key:input\.idempotencyKey\}\)/);
    assert.match(persistence, /return inventoryItemsCurrent\.parse\(await rpc\("update_inventory_item_usage_entry"/);
  });

  it("serializes the RPC request and parses the authoritative persisted state", async () => {
    const current = {
      report_id: "10000000-0000-4000-8000-000000000001",
      business_date: "2026-11-08",
      inventory_month: "2026-11-01",
      state: "draft",
      updated_at: "2026-11-08T12:00:00.000Z",
      submitted_at: null,
      beef_production_labels: { russian_label: null, australian_label: null, hunch_sauce_label: null },
      beef_rows: [],
      item_usage: { usage_month: "2026-11-01", items: [] },
    };
    const calls: Array<{ url: string; body: unknown }> = [];
    const persistence = createChecklistPersistence("https://example.invalid", "test-secret", {
      storageFetch: async (input, init) => {
        calls.push({ url: String(input), body: init?.body ? JSON.parse(String(init.body)) : null });
        return new Response(JSON.stringify(current), { status: 200, headers: { "content-type": "application/json" } });
      },
    });
    assert.deepEqual(await persistence.updateInventoryItemUsageEntry?.({
      actorUserId: "20000000-0000-4000-8000-000000000001",
      branchId: "30000000-0000-4000-8000-000000000001",
      itemUsageId: "40000000-0000-4000-8000-000000000001",
      expectedReportUpdatedAt: "2026-11-08T11:00:00.000Z",
      expectedUsage: { "1": "2.5" },
      newUsage: { "1": "3.5" },
      idempotencyKey: "50000000-0000-4000-8000-000000000001",
    }), current);
    assert.equal(calls.length, 1);
    assert.match(calls[0].url, /\/rest\/v1\/rpc\/update_inventory_item_usage_entry$/);
    assert.deepEqual(calls[0].body, {
      actor_user_id: "20000000-0000-4000-8000-000000000001",
      target_branch_id: "30000000-0000-4000-8000-000000000001",
      target_item_usage_id: "40000000-0000-4000-8000-000000000001",
      expected_report_updated_at: "2026-11-08T11:00:00.000Z",
      expected_usage: { "1": "2.5" },
      new_usage: { "1": "3.5" },
      idempotency_key: "50000000-0000-4000-8000-000000000001",
    });
  });

  it("keeps the database authorization and immutable identity contract intact", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function public\.update_inventory_item_usage_entry\(/);
    assert.match(migration, /perform private\.lock_inventory_items_month\(target_branch_id, target_inventory_month\)/);
    assert.match(migration, /target_report\.updated_at is distinct from expected_report_updated_at/);
    assert.match(migration, /Item Usage day keys are immutable/);
    assert.match(migration, /revoke all on function public\.update_inventory_item_usage_entry\(uuid,uuid,uuid,timestamptz,jsonb,jsonb,uuid\)[\s\S]*from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.update_inventory_item_usage_entry\(uuid,uuid,uuid,timestamptz,jsonb,jsonb,uuid\)[\s\S]*to service_role/);
  });

  it("uses the fail-closed 403 contract for missing, deleted, and inaccessible entries", async () => {
    const [app, migration] = await Promise.all([readFile(appPath, "utf8"), readFile(migrationPath, "utf8")]);
    // The RPC deliberately collapses no-row, deleted, and cross-branch lookups
    // into SQLSTATE 42501 so the API cannot disclose item existence.
    assert.match(migration, /raise exception 'Inventory Item Usage edit denied' using errcode='42501'/);
    assert.match(app, /if\(error instanceof ChecklistAccessError\)return new HttpError\(403,"forbidden","Access is denied\."\)/);
    assert.match(app, /if\(error instanceof ChecklistAccessError\|\|error instanceof ChecklistNotFoundError\)return new HttpError\(403,"forbidden","Access is denied\."\)/);
  });
});
