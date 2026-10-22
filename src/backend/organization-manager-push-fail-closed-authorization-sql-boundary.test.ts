import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const sql = readFileSync(
  new URL("../../supabase/migrations/20261022100000_organization_manager_push_fail_closed_authorization.sql", import.meta.url),
  "utf8",
).toLowerCase();

describe("Organization Manager push fail-closed authorization SQL boundary (MF-1)", () => {
  it("is forward-only and safely replaces authorize_organization_manager_push_delivery", () => {
    assert.match(sql, /create or replace function public\.authorize_organization_manager_push_delivery/);
    assert.doesNotMatch(sql, /drop table|truncate table|delete from public\.organization_manager/);
  });

  it("defaults to fail-closed (producer_allowed := false)", () => {
    assert.match(sql, /producer_allowed boolean := false;/);
    assert.doesNotMatch(sql, /producer_allowed boolean := true;/);
  });

  it("restricts producer authorization strictly to maintenance_issue_created", () => {
    assert.match(sql, /if notification\.event_type = 'maintenance_issue_created' then[\s\S]*coalesce\(private\.organization_manager_push_producer_enabled\(notification\.created_at\), false\)[\s\S]*else[\s\S]*producer_allowed := false;[\s\S]*end if;/);
  });

  it("terminalizes unauthorized events with producer_disabled", () => {
    assert.match(sql, /when not producer_allowed then 'producer_disabled'/);
    assert.match(sql, /set state = 'terminal'/);
  });

  it("preserves security definer, empty search_path, and service-role-only grants", () => {
    assert.match(sql, /security definer/);
    assert.match(sql, /set search_path = ''/);
    assert.match(sql, /revoke all on function public\.authorize_organization_manager_push_delivery\(uuid, uuid\) from public, anon, authenticated, service_role;/);
    assert.match(sql, /grant execute on function public\.authorize_organization_manager_push_delivery\(uuid, uuid\) to service_role;/);
    assert.doesNotMatch(sql, /grant execute on function public\.authorize_organization_manager_push_delivery.*to (authenticated|anon|public)/);
  });
});
