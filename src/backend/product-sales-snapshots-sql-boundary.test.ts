import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL("../../supabase/migrations/20260910100000_product_sales_snapshots_phase3b1.sql", import.meta.url);

describe("Product Sales frozen usage snapshot SQL boundary", () => {
  it("creates only the Phase 3B1 product sales tables with RLS", async () => {
    const migration = await readFile(migrationPath, "utf8");
    for (const table of ["branch_product_sales_daily_reports", "branch_product_sales", "branch_product_sales_usage_snapshots"]) {
      assert.match(migration, new RegExp(`create table if not exists public\\.${table}`));
      assert.match(migration, new RegExp(`${table}[\\s\\S]*organization_id uuid not null references public\\.organizations`));
      assert.match(migration, new RegExp(`${table}[\\s\\S]*branch_id uuid not null references public\\.branches`));
      assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`));
      assert.match(migration, new RegExp(`create policy ${table}_select_authorized[\\s\\S]*private\\.has_branch_access\\(branch_id\\)`));
    }
    assert.doesNotMatch(migration, /daily_waste|transfer_in|transfer_out|actual_closing|expected_closing|variance|inventory_history/i);
  });

  it("keeps Product Sales writes service-role RPC only and rejects direct browser mutation", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /revoke all on table public\.branch_product_sales_daily_reports, public\.branch_product_sales, public\.branch_product_sales_usage_snapshots from public, anon, authenticated, service_role/);
    assert.match(migration, /grant select on table public\.branch_product_sales_daily_reports, public\.branch_product_sales, public\.branch_product_sales_usage_snapshots to authenticated, service_role/);
    assert.match(migration, /create or replace function public\.save_branch_product_sales/);
    assert.match(migration, /create or replace function public\.get_branch_product_sales/);
    assert.match(migration, /revoke all on function public\.get_branch_product_sales\(uuid, uuid, date\), public\.save_branch_product_sales\(uuid, uuid, date, bigint, jsonb\) from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.get_branch_product_sales\(uuid, uuid, date\), public\.save_branch_product_sales\(uuid, uuid, date, bigint, jsonb\) to service_role/);
  });

  it("authorizes and validates only server-side canonical data", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /private\.phase2_branch_context\(actor_user_id, target_branch_id\)/);
    assert.match(migration, /target_business_date > ctx\.business_date/);
    assert.match(migration, /pg_advisory_xact_lock/);
    assert.match(migration, /expected_revision/);
    assert.match(migration, /product\.organization_id = ctx\.organization_id/);
    assert.match(migration, /product\.branch_id = ctx\.branch_id/);
    assert.match(migration, /product\.is_active/);
    assert.match(migration, /duplicate product sale/);
    assert.doesNotMatch(migration, /inventory_item_id.*sale_row|quantity_per_sale.*sale_row|total_usage.*sale_row/);
  });

  it("creates frozen usage snapshots for new sales, including zero quantities", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /product_name_snapshot/);
    assert.match(migration, /inventory_behavior_snapshot/);
    assert.match(migration, /inventory_item_name_snapshot/);
    assert.match(migration, /inventory_item_unit_snapshot/);
    assert.match(migration, /quantity_per_sale_snapshot/);
    assert.match(migration, /sales_quantity_snapshot/);
    assert.match(migration, /total_usage_quantity/);
    assert.match(migration, /sale\.quantity \* mapping\.quantity/);
    assert.match(migration, /recipe product has no inventory mappings/);
    assert.match(migration, /sale\.inventory_behavior_snapshot = 'standalone_stock'/);
    assert.match(migration, /branch_product_sales_usage_sales_quantity_check check \(sales_quantity_snapshot >= 0\)/);
    assert.match(migration, /branch_product_sales_usage_total_usage_check check \(total_usage_quantity >= 0\)/);
    assert.doesNotMatch(migration, /sale\.quantity > 0/);
  });

  it("implements patch semantics with daily revision and no-op preservation", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create temp table branch_product_sales_stage/);
    assert.match(migration, /left join public\.branch_product_sales existing[\s\S]*existing\.report_id = report\.id[\s\S]*existing\.product_id = stage\.product_id/);
    assert.match(migration, /where existing\.id is null[\s\S]*or existing\.quantity <> stage\.quantity/);
    assert.doesNotMatch(migration, /delete from public\.branch_product_sales sale[\s\S]*not exists \([\s\S]*branch_product_sales_stage/);
    assert.doesNotMatch(migration, /delete from public\.branch_product_sales_usage_snapshots usage[\s\S]*where usage\.report_id = report\.id/);
    assert.doesNotMatch(migration, /select product_id, quantity[\s\S]*except[\s\S]*select product_id, quantity from branch_product_sales_stage/);
    assert.match(migration, /if not changed then[\s\S]*private\.branch_product_sales_payload/);
    assert.match(migration, /set revision = existing\.revision \+ 1/);
  });

  it("preserves existing historical snapshots instead of regenerating from current catalog", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create temp table branch_product_sales_existing/);
    assert.match(migration, /existing\.id is null[\s\S]*product\.is_active/);
    assert.match(migration, /update public\.branch_product_sales_usage_snapshots usage[\s\S]*total_usage_quantity = usage\.quantity_per_sale_snapshot \* sale\.quantity/);
    assert.match(migration, /product sales frozen usage snapshot missing/);
    assert.doesNotMatch(migration, /on conflict \(report_id, product_id\) do update set[\s\S]*product_name_snapshot = excluded\.product_name_snapshot/);
    assert.doesNotMatch(migration, /delete from public\.branch_product_sales_usage_snapshots/);
  });

  it("proves historical snapshot guarantee: recipe change (P -> A to P -> B) never alters historical snapshots", async () => {
    const salesMigration = await readFile(migrationPath, "utf8");
    const identityMigration = await readFile(new URL("../../supabase/migrations/20260913120000_product_usage_mapping_inventory_identity.sql", import.meta.url), "utf8");

    // 1. Neither catalog creation nor recipe modification migration touches sales snapshots
    assert.doesNotMatch(identityMigration, /branch_product_sales_usage_snapshots/i);
    assert.doesNotMatch(identityMigration, /branch_product_sales/i);

    // 2. In save_branch_product_sales, new snapshots are created ONLY for new sales
    // (where not exists in branch_product_sales_usage_snapshots) using mapping active at insertion time
    assert.match(salesMigration, /insert into public\.branch_product_sales_usage_snapshots[\s\S]*join public\.branch_product_usage_mappings mapping[\s\S]*not exists\s*\([\s\S]*from public\.branch_product_sales_usage_snapshots existing_usage[\s\S]*existing_usage\.product_sale_id = sale\.id\s*\)/);

    // 3. For existing sales, only total_usage_quantity is scaled by quantity change:
    // the item ID, name, and quantity_per_sale remain frozen from the original insertion
    assert.match(salesMigration, /update public\.branch_product_sales_usage_snapshots usage[\s\S]*set[\s\S]*total_usage_quantity = usage\.quantity_per_sale_snapshot \* sale\.quantity/);

    // 4. Report payload reads strictly from frozen snapshot table, never querying live recipe mappings
    const payloadFn = salesMigration.match(/create or replace function private\.branch_product_sales_payload[\s\S]*?\$\$[\s\S]*?\$\$;/)?.[0] ?? "";
    assert.ok(payloadFn.length > 0);
    assert.match(payloadFn, /from public\.branch_product_sales_usage_snapshots usage[\s\S]*where usage\.report_id = report\.id/);
    assert.doesNotMatch(payloadFn, /join public\.branch_product_usage_mappings/);
  });
});
