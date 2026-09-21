import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.join(process.cwd(), "supabase/migrations/20260921130000_purchase_requests_phase1b.sql");

describe("Purchase Request migration contract", () => {
  it("creates a separate request and item domain with no Purchase Log or expense coupling", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /create table public\.purchase_requests/i);
    assert.match(sql, /create table public\.purchase_request_items/i);
    assert.match(sql, /category text not null check \(category in \('stationary','kitchen','other'\)\)/i);
    assert.match(sql, /status text not null default 'submitted'/i);
    assert.match(sql, /quantity numeric not null check \(quantity > 0\)/i);
    assert.doesNotMatch(sql, /branch_purchase_logs|expense|reimbursement|invoice/i);
  });

  it("keeps mutations behind service-role RPCs with explicit supervisor and purchasing gates", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /public\.create_supervisor_purchase_request/);
    assert.match(sql, /private\.purchase_request_actor_branch_scope/);
    assert.match(sql, /membership\.role = 'branch_manager'/);
    assert.match(sql, /private\.has_active_purchasing_membership\(actor_user_id, target_organization_id\)/);
    assert.match(sql, /grant execute on function public\.create_supervisor_purchase_request\(uuid, uuid, text, text, jsonb\) to service_role/i);
    assert.match(sql, /grant execute on function public\.list_purchasing_purchase_requests\(uuid, uuid, text\) to service_role/i);
    assert.doesNotMatch(sql, /grant execute .* to authenticated/i);
  });

  it("allows only Phase 1B purchasing status transitions", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /v_request\.status = 'submitted' and next_status = 'processing'/);
    assert.match(sql, /v_request\.status = 'processing' and next_status = 'purchased'/);
    assert.doesNotMatch(sql, /next_status = 'received'/);
  });
});
