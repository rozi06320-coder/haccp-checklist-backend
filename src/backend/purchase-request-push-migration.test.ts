import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261001120000_purchase_request_web_push.sql");

describe("Purchase Request web push migration contract", () => {
  it("adds actor-scoped idempotency and replaces only the idempotent create signature", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /create table public\.purchase_request_creation_idempotency/);
    assert.match(sql, /primary key \(actor_user_id, idempotency_key\)/);
    assert.match(sql, /request_hash ~ '\^\[0-9a-f\]\{64\}\$'/);
    assert.match(sql, /pg_advisory_xact_lock/);
    assert.match(sql, /v_existing\.request_hash <> request_hash[\s\S]*errcode = '23505'/);
    assert.match(sql, /'created', false/);
    assert.match(sql, /'created', true/);
    assert.match(sql, /drop function public\.create_supervisor_purchase_request\(uuid, uuid, text, text, jsonb\)/);
    assert.match(sql, /create function public\.create_supervisor_purchase_request\([\s\S]*idempotency_key uuid,[\s\S]*request_hash text/);
  });

  it("reuses push_subscriptions with exact Purchasing recipient restrictions", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.doesNotMatch(sql, /create table public\.push_subscriptions/);
    assert.match(sql, /create function public\.register_purchasing_push_subscription/);
    assert.match(sql, /from public\.purchasing_memberships membership[\s\S]*membership\.active[\s\S]*organization\.active[\s\S]*profile\.disabled_at is null[\s\S]*not profile\.must_change_password/);
    assert.match(sql, /create function public\.list_purchase_request_push_subscriptions/);
    assert.match(sql, /membership\.organization_id = target\.organization_id/);
    assert.match(sql, /subscription\.disabled_at is null/);
    assert.match(sql, /distinct on \(subscription\.endpoint\)/);
  });

  it("keeps direct mutation revoked and grants only service_role execution", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /revoke all on table public\.purchase_request_creation_idempotency from public, anon, authenticated, service_role/);
    for (const signature of [
      "create_supervisor_purchase_request\\(uuid, uuid, uuid, text, text, text, jsonb\\)",
      "register_purchasing_push_subscription\\(uuid, text, text, text, text\\)",
      "list_purchase_request_push_subscriptions\\(uuid\\)",
    ]) {
      assert.match(sql, new RegExp(`revoke all on function public\\.${signature} from public, anon, authenticated`));
      assert.match(sql, new RegExp(`grant execute on function public\\.${signature} to service_role`));
    }
  });
});
