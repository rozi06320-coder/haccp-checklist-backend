import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261021120000_organization_manager_web_push_foundation.sql");

describe("Organization Manager Web Push SQL boundary", () => {
  it("is forward-only and reuses the shared subscription table", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.doesNotMatch(sql, /drop\s+(?:table|function|type|column)/i);
    assert.doesNotMatch(sql, /create table public\.push_subscriptions/i);
    assert.match(sql, /references public\.push_subscriptions\(id\) on delete set null/);
  });

  it("enforces manager scope, endpoint providers, RLS and service-role-only RPCs", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /membership\.role='organization_manager' and membership\.active/);
    assert.match(sql, /organization\.active and profile\.disabled_at is null and not profile\.must_change_password/);
    assert.match(sql, /fcm\\\.googleapis\\\.com/);
    assert.match(sql, /push\\\.apple\\\.com/);
    assert.match(sql, /push_subscriptions_safe_active_endpoint_check/);
    assert.match(sql, /update public\.push_subscriptions subscription[\s\S]*not private\.browser_push_endpoint_is_allowed/);
    assert.match(sql, /enable row level security/g);
    assert.match(sql, /revoke all on table public\.organization_manager_notifications from public,anon,authenticated,service_role/);
    assert.match(sql, /security definer set search_path=''/g);
    assert.doesNotMatch(sql, /grant execute[^;]+to\s+(?:public|anon|authenticated)/i);
  });

  it("binds immutable source history and deduplicates occurrences and deliveries", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /unique\(organization_id,recipient_user_id,occurrence_key\)/);
    assert.match(sql, /organization_manager_push_deliveries_notification_subscription_key/);
    assert.match(sql, /guard_organization_manager_notification_history/);
    assert.match(sql, /organization_manager_notification_source_matches/);
    assert.match(sql, /source\.organization_id=p_organization_id/);
  });

  it("uses atomic skip-locked claims, lease tokens, crash recovery and bounded retries", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /for update of delivery,subscription skip locked limit p_limit/);
    assert.match(sql, /lease_token=gen_random_uuid\(\)/);
    assert.match(sql, /leased_by=p_worker_id/);
    assert.match(sql, /delivery\.lease_expires_at<=statement_timestamp\(\)/);
    assert.match(sql, /attempt_count between 0 and 5/);
    assert.match(sql, /when delivery\.attempt_count>=5 then'retry_exhausted'/);
    assert.match(sql, /p_http_status in\(404,410\)/);
  });

  it("implements durable actor, organization and IP mutation limits", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /private\.organization_manager_push_rate_limits/);
    for (const dimension of ["actor", "organization", "ip"]) {
      assert.match(sql, new RegExp(`values\\(p_operation,'${dimension}'`));
    }
  });
});
