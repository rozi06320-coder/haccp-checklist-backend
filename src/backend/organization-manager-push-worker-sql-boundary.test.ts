import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const sql = readFileSync(new URL("../../supabase/migrations/20261021130000_organization_manager_push_delivery_worker.sql", import.meta.url), "utf8").toLowerCase();
const worker = readFileSync(new URL("./organization-manager-push-worker.ts", import.meta.url), "utf8");

describe("Organization Manager push worker SQL boundary", () => {
  it("is forward-only and preserves the Phase 1A migration", () => {
    assert.match(sql, /create or replace function public\.claim_organization_manager_push_deliveries/);
    assert.match(sql, /create function public\.authorize_organization_manager_push_delivery/);
    assert.doesNotMatch(sql, /drop table|truncate table|delete from public\.organization_manager/);
  });

  it("keeps claims skip-locked and performs final lease-bound authorization", () => {
    assert.match(sql, /for update of delivery skip locked/);
    assert.match(sql, /delivery\.lease_token <> p_lease_token/);
    assert.match(sql, /delivery\.lease_expires_at <= statement_timestamp\(\)/);
    assert.match(sql, /subscription\.disabled_at is not null/);
    assert.match(sql, /profile\.disabled_at is null[\s\S]*not profile\.must_change_password/);
  });

  it("terminalizes orphaned queue rows and preserves bounded retry behavior", () => {
    assert.match(sql, /delivery\.push_subscription_id is null/);
    assert.match(sql, /terminal_reason = 'subscription_disabled'/);
    assert.match(sql, /delivery\.attempt_count >= 5/);
    assert.match(sql, /pg_catalog\.power\(2, delivery\.attempt_count - 1\)/);
  });

  it("creates maintenance notifications in the issue transaction without sensitive payload columns", () => {
    assert.match(sql, /after insert on public\.maintenance_issues/);
    assert.match(sql, /'maintenance_issue_created'[\s\S]*'maintenance_issue'/);
    assert.match(sql, /'maintenance-issue:' \|\| new\.id::text/);
    assert.doesNotMatch(sql, /new\.title|new\.description|new\.responsible_person_name/);
    assert.match(sql, /organization_manager_push_producer_enabled\(new\.created_at\)/);
    assert.match(sql, /enabled boolean not null default false/);
    assert.match(sql, /revoke all on function private\.configure_organization_manager_push_producer[\s\S]*service_role/);
  });

  it("keeps all new privileged functions service-role-only with empty search paths", () => {
    assert.match(sql, /authorize_organization_manager_push_delivery\([\s\S]*security definer[\s\S]*set search_path = ''/);
    assert.match(sql, /revoke all on function public\.authorize_organization_manager_push_delivery\(uuid, uuid\) from public, anon, authenticated, service_role/);
    assert.match(sql, /grant execute on function public\.authorize_organization_manager_push_delivery\(uuid, uuid\) to service_role/);
  });

  it("pins validated DNS results and bounds timeout, response size and concurrency without redirect following", () => {
    assert.match(worker, /addresses\.some\(\(item\) => !isPublicPushAddress/);
    assert.match(worker, /lookup: \(_hostname, _options, callback\) => callback\(null, selected\.address/);
    assert.match(worker, /agent,/);
    assert.match(worker, /rejectUnauthorized: true/);
    assert.match(worker, /checkServerIdentity: tls\.checkServerIdentity/);
    assert.match(worker, /transport\.prepare[\s\S]*authorize_organization_manager_push_delivery[\s\S]*destination\.send/);
    assert.match(worker, /responseBytes > responseLimitBytes/);
    assert.match(worker, /requestTimeoutMs \?\? 5_000/);
    assert.match(worker, /Math\.min\(options\.concurrency \?\? 4, 8\)/);
    assert.doesNotMatch(worker, /followredirect|location.*request|fetch\(/i);
  });
});
