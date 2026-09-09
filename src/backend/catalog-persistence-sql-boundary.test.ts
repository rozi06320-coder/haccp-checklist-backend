import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL("../../supabase/migrations/20260909100000_product_inventory_recipe_catalogs.sql", import.meta.url);

describe("Product / Inventory / Recipe catalog persistence SQL boundary", () => {
  it("creates only branch-scoped catalog tables with RLS and no sales/waste/movement persistence", async () => {
    const migration = await readFile(migrationPath, "utf8");
    for (const table of ["branch_product_catalog_products", "branch_inventory_catalog_items", "branch_product_usage_mappings"]) {
      assert.match(migration, new RegExp(`create table if not exists public\\.${table}`));
      assert.match(migration, new RegExp(`${table}[\\s\\S]*organization_id uuid not null references public\\.organizations`));
      assert.match(migration, new RegExp(`${table}[\\s\\S]*branch_id uuid not null references public\\.branches`));
      assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`));
    }
    assert.doesNotMatch(migration, /product_sales|daily_waste|daily_inventory|inventory_movement|actual_closing/i);
  });

  it("enforces product, inventory, and recipe integrity at database/RPC boundary", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /inventory_behavior in \('recipe','standalone_stock','non_stock'\)/);
    assert.match(migration, /kind in \('ingredient','standalone_stock'\)/);
    assert.match(migration, /unit in \('pcs','kg','g','L','ml'\)/);
    assert.match(migration, /quantity > 0/);
    assert.match(migration, /branch_inventory_catalog_items_active_name_key/);
    assert.match(migration, /branch_product_catalog_products_active_name_key/);
    assert.match(migration, /branch_product_usage_mappings_product_item_key/);
    assert.match(migration, /if target_product\.id is null or target_product\.inventory_behavior <> 'recipe'/);
    assert.match(migration, /duplicate recipe inventory item/);
  });

  it("keeps API mutations service-role RPC only and preserves raw table write protection", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /revoke all on table public\.branch_inventory_catalog_items, public\.branch_product_catalog_products, public\.branch_product_usage_mappings from public, anon, authenticated, service_role/);
    for (const fn of ["list_branch_catalog", "create_branch_catalog_inventory_item", "update_branch_catalog_inventory_item", "create_branch_catalog_product", "save_branch_product_usage_mappings"]) {
      assert.match(migration, new RegExp(`create or replace function public\\.${fn}`));
      assert.match(migration, new RegExp(`grant execute on function[\\s\\S]*public\\.${fn}`));
    }
    assert.match(migration, /private\.require_branch_catalog_scope/);
    assert.match(migration, /membership\.role = 'branch_manager'/);
  });

  it("enforces declarative relational tenant integrity and cross-tenant reference prevention", async () => {
    const migration = await readFile(migrationPath, "utf8");
    for (const table of ["branch_inventory_catalog_items", "branch_product_catalog_products", "branch_product_usage_mappings"]) {
      assert.match(migration, new RegExp(`constraint ${table}_branch_org_fk foreign key \\(branch_id, organization_id\\) references public\\.branches\\(id, organization_id\\)`));
    }
    assert.match(migration, /constraint branch_product_catalog_products_standalone_item_fk foreign key \(branch_id, standalone_inventory_item_id\) references public\.branch_inventory_catalog_items\(branch_id, id\)/);
    assert.match(migration, /constraint branch_product_usage_mappings_product_fk foreign key \(branch_id, product_id\) references public\.branch_product_catalog_products\(branch_id, id\)/);
    assert.match(migration, /constraint branch_product_usage_mappings_inventory_item_fk foreign key \(branch_id, inventory_item_id\) references public\.branch_inventory_catalog_items\(branch_id, id\)/);
    assert.match(migration, /private\.enforce_product_catalog_behavior_and_kind/);
    assert.match(migration, /private\.enforce_inventory_item_kind_immutability/);
    assert.match(migration, /private\.enforce_recipe_mapping_product_behavior/);
    assert.match(migration, /create trigger branch_product_catalog_products_enforce_behavior/);
    assert.match(migration, /create trigger branch_inventory_catalog_items_enforce_kind/);
    assert.match(migration, /create trigger branch_product_usage_mappings_enforce_behavior/);
  });
});
