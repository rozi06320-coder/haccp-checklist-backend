import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { createChecklistPersistence } from "./checklist-persistence";

const migrationPath = path.resolve(
  "supabase/migrations/20260930150000_inventory_beef_label_snapshot_repair.sql",
);

function functionSection(source: string, signature: RegExp, nextMarker?: RegExp) {
  const start = source.search(signature);
  assert.notEqual(start, -1, `missing function matching ${signature}`);
  const remainder = source.slice(start);
  const end = nextMarker ? remainder.slice(1).search(nextMarker) : -1;
  return end === -1 ? remainder : remainder.slice(0, end + 1);
}

describe("Inventory Items Beef label/snapshot production repair", () => {
  it("converges missing and partial schema without rewriting historical rows", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /create table if not exists public\.branch_inventory_items_settings/);
    assert.match(migration, /add column if not exists beef_russian_label text/);
    assert.match(migration, /add column if not exists beef_australian_label text/);
    assert.match(migration, /add column if not exists beef_hunch_sauce_label text/);
    assert.match(migration, /add column if not exists russian_label_snapshot text/);
    assert.match(migration, /add column if not exists australian_label_snapshot text/);
    assert.match(migration, /add column if not exists hunch_sauce_label_snapshot text/);
    assert.match(migration, /drop column if exists beef_production_label/);
    assert.doesNotMatch(migration, /update public\.inventory_beef_production_rows/);
  });

  it("restores the final label helper, settings RPC, immutable snapshots, and response shape", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const state = functionSection(
      migration,
      /create or replace function private\.inventory_items_state_json\(/,
      /create or replace function public\.update_inventory_beef_production_field_labels\(/,
    );
    const persist = functionSection(
      migration,
      /create or replace function private\.persist_inventory_items_daily_values\(/,
      /create or replace function public\.submit_inventory_items\(/,
    );

    assert.match(migration, /private\.inventory_items_label_snapshot\(row_value jsonb, field_name text, default_label text\)/);
    assert.match(migration, /public\.update_inventory_beef_production_field_labels\([\s\S]*?actor_user_id uuid,[\s\S]*?target_branch_id uuid,[\s\S]*?russian_label text,[\s\S]*?australian_label text,[\s\S]*?hunch_sauce_label text/);
    assert.match(state, /'beef_production_labels'/);
    assert.doesNotMatch(state, /'beef_production_label'/);
    assert.match(state, /'russian_label_snapshot', row\.russian_label_snapshot/);
    assert.match(state, /'australian_label_snapshot', row\.australian_label_snapshot/);
    assert.match(state, /'hunch_sauce_label_snapshot', row\.hunch_sauce_label_snapshot/);
    assert.match(persist, /on conflict\(report_id, production_date\) do nothing/);
    assert.match(persist, /existing_beef\.russian_kg is distinct from parsed_russian_kg/);
    assert.doesNotMatch(persist, /update public\.inventory_beef_production_rows/);
    assert.doesNotMatch(persist, /delete from public\.inventory_item_usage/);
  });

  it("preserves the exact guarded submit flow and service-role-only execution", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const submit = functionSection(
      migration,
      /create or replace function public\.submit_inventory_items\(/,
    );

    assert.match(submit, /p_actor_user_id uuid,[\s\S]*p_target_branch_id uuid,[\s\S]*p_idempotency_key uuid,[\s\S]*p_request_hash text,[\s\S]*beef_rows jsonb,[\s\S]*item_usage jsonb/);
    assert.match(submit, /perform private\.lock_inventory_items_month\(p_target_branch_id, usage_month\)/);
    assert.match(submit, /current_month_last_date := \(current_month \+ interval '1 month - 1 day'\)::date/);
    assert.match(submit, /raise exception 'inventory month cannot be closed yet' using errcode = '22023'/);
    assert.match(submit, /where exists \(select 1 from pg_catalog\.jsonb_each\(item -> 'usage'\)\)/);
    assert.doesNotMatch(submit, /jsonb_object_length/);
    assert.match(submit, /perform private\.persist_inventory_items_daily_values\(/);
    assert.match(submit, /response_json := private\.inventory_items_state_json\(/);
    assert.ok(
      submit.indexOf("return existing_idempotency.response_json") <
        submit.indexOf("inventory month cannot be closed yet"),
      "idempotent replay remains available before the close-date guard",
    );
    assert.match(migration, /revoke all on function public\.submit_inventory_items\(uuid,uuid,uuid,text,jsonb,jsonb\)[\s\S]*from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.submit_inventory_items\(uuid,uuid,uuid,text,jsonb,jsonb\)[\s\S]*to service_role/);
  });

  it("accepts the repaired submit response through the strict backend decoder", async () => {
    const response = {
      report_id: "10000000-0000-4000-8000-000000000001",
      business_date: "2026-09-30",
      inventory_month: "2026-09-01",
      state: "submitted",
      updated_at: "2026-09-30T20:00:00.000Z",
      submitted_at: "2026-09-30T20:00:00.000Z",
      beef_production_labels: {
        russian_label: "Beef A",
        australian_label: null,
        hunch_sauce_label: "Sauce X",
      },
      beef_rows: [{
        id: "20000000-0000-4000-8000-000000000001",
        production_date: "2026-09-30",
        russian_kg: 10,
        australian_kg: 5,
        fat_kg: 0,
        total_kg: 15,
        ready_patty: 4,
        hunch_sauce_kg: 2,
        wastage_grams: 0,
        russian_label_snapshot: "Beef A",
        australian_label_snapshot: "Australian kg",
        hunch_sauce_label_snapshot: "Sauce X",
      }],
      item_usage: {
        usage_month: "2026-09-01",
        items: [{
          id: "30000000-0000-4000-8000-000000000001",
          group_name: "Liwa",
          item_name: "Burger",
          usage: { "30": 2 },
        }],
      },
    };
    const server = createServer((request, result) => {
      assert.equal(request.url, "/rest/v1/rpc/submit_inventory_items");
      result.writeHead(200, { "Content-Type": "application/json" });
      result.end(JSON.stringify(response));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
      const persistence = createChecklistPersistence(origin, "test-secret");
      const decoded = await persistence.submitInventoryItems?.({
        actorUserId: "40000000-0000-4000-8000-000000000001",
        branchId: "50000000-0000-4000-8000-000000000001",
        idempotencyKey: "60000000-0000-4000-8000-000000000001",
        payload: {
          beef_rows: [{
            production_date: "2026-09-30",
            russian_kg: 10,
            australian_kg: 5,
            fat_kg: 0,
            ready_patty: 4,
            hunch_sauce_kg: 2,
            wastage_grams: 0,
          }],
          item_usage: { usage_month: "2026-09-01", items: [] },
        },
      });
      assert.deepEqual(decoded, response);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
