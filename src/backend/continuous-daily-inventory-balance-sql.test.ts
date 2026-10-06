import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL(
  "../../supabase/migrations/20261006150000_continuous_daily_inventory_balance.sql",
  import.meta.url,
);

describe("continuous Daily Inventory balance migration", () => {
  it("uses one canonical recursive balance read model", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /branch_daily_inventory_entries_branch_item_date_idx/);
    assert.match(sql, /create or replace function private\.branch_daily_inventory_balance_rows/);
    assert.match(sql, /with recursive/);
    assert.match(sql, /from balance prior/);
    assert.match(sql, /private\.branch_daily_inventory_balance_rows\(ctx\.organization_id, ctx\.branch_id, target_business_date\)/);
    assert.match(sql, /private\.branch_daily_inventory_balance_rows\(target_organization_id, branch\.id, to_date\)/);
  });

  it("uses the earliest manual opening as a continuous initial baseline", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /select distinct on \(entry\.inventory_item_id\)/);
    assert.match(sql, /entry\.manual_opening_quantity is not null/);
    assert.match(sql, /order by entry\.inventory_item_id, entry\.business_date/);
    assert.doesNotMatch(sql, /extract\(day from .*business_date\) = 1 then/);
  });

  it("applies Product Sales and Waste without requiring an inventory row", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /from public\.branch_product_sales_usage_snapshots usage/);
    assert.match(sql, /sum\(usage\.total_usage_quantity\)/);
    assert.match(sql, /from public\.branch_daily_waste_entries waste/);
    assert.match(sql, /left join sales_movements sales/);
    assert.match(sql, /left join waste_movements waste/);
    assert.match(sql, /- coalesce\(sales\.quantity, 0\)/);
    assert.match(sql, /- coalesce\(waste\.quantity, 0\)/);
  });

  it("preserves NULL physical counts and explicit physical zero", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /coalesce\(prior\.actual_closing_quantity, prior\.calculated_closing_quantity\) as opening_quantity/);
    assert.match(sql, /when inv\.actual_closing_quantity is not null/);
    assert.doesNotMatch(sql, /coalesce\(inv\.actual_closing_quantity, 0\)/);
  });

  it("does not double-count movements on a checkpoint date", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /\(prior\.business_date \+ 1\)::date/);
    assert.match(sql, /coalesce\(prior\.actual_closing_quantity, prior\.calculated_closing_quantity\)/);
    assert.doesNotMatch(sql, /prior\.actual_closing_quantity[^\n]+sales\.quantity/);
  });

  it("makes manager reconciliation movement-driven", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /balance\.entry_id is not null\s+or balance\.sales_usage_quantity <> 0\s+or balance\.wastage_quantity <> 0/);
    assert.match(sql, /'report_revision', coalesce\(row\.report_revision, 0\)/);
    assert.match(sql, /'report_created_at', row\.report_created_at/);
  });

  it("keeps Actual Closing optional in manager attention classification", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /count\(\*\) filter \(where balance\.inventory_item_id is not null and balance\.actual_closing_quantity is null\)::integer as missing_closing_count/);
    assert.doesNotMatch(sql, /when total_entries_count = 0 or missing_closing_count > 0/);
  });
});
