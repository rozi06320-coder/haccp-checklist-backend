import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261101120000_inventory_item_usage_populated_row_delete.sql");

describe("populated Item Usage one-way tombstone migration", () => {
  it("requires the modern actor contract, branch/month lock, draft report, and locked snapshot", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /private\.inventory_items_actor_context\(actor_user_id,target_branch_id\)/);
    assert.match(sql, /perform private\.lock_inventory_items_month\(target_branch_id,target_inventory_month\)/);
    assert.match(sql, /from public\.inventory_items_reports report[\s\S]*for update/);
    assert.match(sql, /from public\.inventory_item_usage_items item[\s\S]*for update/);
    assert.match(sql, /target_report\.state<>'draft'/);
    assert.match(sql, /current_usage is distinct from normalized_expected_usage[\s\S]*errcode='40001'/);
  });

  it("permits only an authorized irreversible parent tombstone and preserves history", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /old\.deleted_at is null[\s\S]*new\.deleted_at is not null/);
    assert.match(sql, /new\.deleted_by_user_id is not null/);
    assert.match(sql, /join lateral private\.inventory_items_actor_context\([\s\S]*actor\.organization_id=report\.organization_id[\s\S]*actor\.branch_id=report\.branch_id/);
    assert.match(sql, /if target_item\.deleted_at is not null then[\s\S]*return private\.inventory_items_state_json/);
    assert.match(sql, /supervisor_state_definition not like '%item\.deleted_at is null%'/);
    assert.match(sql, /manager_report_definition not like '%item\.deleted_at is null%'/);
    assert.match(sql, /manager_summary_definition not like '%item\.deleted_at is null%'/);
    assert.doesNotMatch(sql, /(?:delete|update)\s+public\.inventory_item_usage_day_values/i);
    assert.doesNotMatch(sql, /branch_inventory|stock_balance|receiv|transfer|waste/i);
  });

  it("exposes only the four-argument service-role RPC and removes the bypass", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /security definer\s+set search_path=''/);
    assert.match(sql, /revoke all on function public\.delete_inventory_item_usage_item\(uuid,uuid,uuid,jsonb\)[\s\S]*from public,anon,authenticated,service_role/);
    assert.match(sql, /grant execute on function public\.delete_inventory_item_usage_item\(uuid,uuid,uuid,jsonb\)[\s\S]*to service_role/);
    assert.match(sql, /drop function public\.delete_inventory_item_usage_item\(uuid,uuid,uuid\)/);
  });
});
