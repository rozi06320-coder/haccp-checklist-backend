import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, it } from "node:test";

const migrationPath = resolve(
  "supabase/migrations/20261011220000_purchasing_cancel_request.sql",
);

describe("Purchasing request cancellation migration", () => {
  it("defines an attributed, locked, service-role-only soft cancellation", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /add column if not exists cancelled_at timestamptz/);
    assert.match(sql, /add column if not exists cancelled_by uuid/);
    assert.match(sql, /cancelled_by uuid references public\.profiles\(id\) on delete restrict/i);
    assert.match(sql, /create or replace function public\.cancel_purchasing_purchase_request\(/);
    assert.match(sql, /returns jsonb[\s\S]*security definer[\s\S]*set search_path = ''/i);
    assert.match(sql, /private\.has_active_purchasing_membership\(actor_user_id, target_organization_id\)/);
    assert.match(sql, /where request\.id = target_request_id[\s\S]*request\.organization_id = target_organization_id[\s\S]*for update/i);
    assert.match(sql, /if v_request\.status = 'cancelled' then[\s\S]*private\.purchase_request_json\(v_request\)/i);
    assert.match(sql, /if v_request\.status not in \('submitted', 'processing'\) then[\s\S]*errcode = '55000'/i);
    assert.match(sql, /from public\.branch_purchase_logs purchase_log[\s\S]*source_purchase_request_id = v_request\.id/i);
    assert.match(sql, /set status = 'cancelled',[\s\S]*cancelled_at = statement_timestamp\(\),[\s\S]*cancelled_by = actor_user_id/i);
    assert.match(sql, /revoke all on function public\.cancel_purchasing_purchase_request\(uuid, uuid, uuid\) from public, anon, authenticated/);
    assert.match(sql, /grant execute on function public\.cancel_purchasing_purchase_request\(uuid, uuid, uuid\) to service_role/);
    assert.doesNotMatch(sql, /delete\s+from\s+public\.purchase_requests/i);
    assert.doesNotMatch(sql, /delete\s+from\s+public\.purchase_request_items/i);
    assert.doesNotMatch(sql, /delete\s+from\s+storage\.objects/i);
  });

  it("returns cancellation attribution in canonical purchase request JSON", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /'cancelled_at', row_data\.cancelled_at/);
    assert.match(sql, /'cancelled_by', row_data\.cancelled_by/);
    assert.match(sql, /'items',[\s\S]*purchase_request_item_attachments/i);
  });
});
