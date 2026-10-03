import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261003130000_delete_branch_product_sale.sql");

describe("delete one saved Product Sale migration contract", () => {
  it("uses the existing authorization, date, lock, revision, and payload contracts", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /private\.phase2_branch_context\(actor_user_id, target_branch_id\)/);
    assert.match(sql, /target_business_date > ctx\.business_date/);
    assert.match(sql, /hashtextextended\(ctx\.organization_id::text \|\| ':' \|\| ctx\.branch_id::text \|\| ':' \|\| target_business_date::text \|\| ':product_sales', 0\)/);
    assert.match(sql, /branch_product_sales_daily_reports[\s\S]*for update/);
    assert.match(sql, /branch_product_sales existing[\s\S]*for update/);
    assert.match(sql, /expected_revision <> report\.revision[\s\S]*errcode = '40001'/);
    assert.match(sql, /return private\.branch_product_sales_payload\(actor_user_id, target_branch_id, target_business_date\)/);
  });

  it("deletes only the scoped sale and advances the retained report once", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /delete from public\.branch_product_sales existing\s+where existing\.id = sale\.id/);
    assert.match(sql, /set revision = existing\.revision \+ 1/);
    assert.doesNotMatch(sql, /delete from public\.branch_product_sales_usage_snapshots/);
    assert.doesNotMatch(sql, /delete from public\.branch_product_sales_daily_reports/);
    assert.doesNotMatch(sql, /delete from public\.branch_product_catalog_products/);
    assert.doesNotMatch(sql, /delete from public\.branch_inventory_catalog_items/);
    assert.doesNotMatch(sql, /delete from public\.branch_product_usage_mappings/);
  });

  it("keeps execution service-role-only with a restricted search path", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /security definer\s+set search_path = ''/);
    assert.match(sql, /revoke all on function public\.delete_branch_product_sale\(uuid, uuid, date, uuid, bigint\) from public, anon, authenticated/);
    assert.match(sql, /grant execute on function public\.delete_branch_product_sale\(uuid, uuid, date, uuid, bigint\) to service_role/);
  });
});
