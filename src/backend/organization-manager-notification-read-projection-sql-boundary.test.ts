import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(new URL("../../supabase/migrations/20261031140000_organization_manager_notification_read_projection.sql", import.meta.url), "utf8");

describe("Manager notification read projection SQL boundary", () => {
  it("is additive, service-role-only, and preserves legacy history", () => {
    assert.match(migration, /create function public\.list_organization_manager_notification_projection\(/);
    assert.match(migration, /create function public\.count_organization_manager_notification_projection\(/);
    assert.match(migration, /security definer\s+set search_path = ''/);
    assert.match(migration, /revoke all on function public\.list_organization_manager_notification_projection\([\s\S]*?from public,anon,authenticated,service_role/);
    assert.match(migration, /grant execute on function public\.list_organization_manager_notification_projection\([\s\S]*?to service_role/);
    assert.match(migration, /private\.assert_active_organization_manager/);
    assert.match(migration, /private\.organization_manager_notification_branch_date_closed/);
    assert.match(migration, /private\.organization_manager_category_context_valid/);
    assert.match(migration, /read_at/);
    assert.doesNotMatch(migration, /\b(insert|update|delete)\s+public\.organization_manager_notifications\b/i);
  });

  it("contains all three normalized categories and legacy maintenance deduplication", () => {
    for (const category of ["sales_tracking_missing", "maintenance_issue", "incomplete_branch_tasks"]) {
      assert.match(migration, new RegExp(`'${category}'`));
    }
    assert.match(migration, /category_notification\.category_context->'issue_ids' \? issue\.id::text/);
    assert.match(migration, /legacy_notification_id/);
    assert.match(migration, /'scope','office'/);
  });

  it("keeps deterministic cursor ordering and an authoritative count path", () => {
    assert.match(migration, /p_before is null[\s\S]*projected\.created_at<p_before/);
    assert.match(migration, /order by projected\.created_at desc,projected\.id desc/);
    assert.match(migration, /select coalesce\(sum\(item_count\),0\)::bigint from counts/);
  });
});
