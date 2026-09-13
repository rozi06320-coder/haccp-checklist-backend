import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL("../../supabase/migrations/20260909100000_product_inventory_recipe_catalogs.sql", import.meta.url);
const identityMigrationPath = new URL("../../supabase/migrations/20260913120000_product_usage_mapping_inventory_identity.sql", import.meta.url);

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

  it("keeps applied 20260909100000 migration untouched and puts canonical inventory identity in 20260913120000 follow-up", async () => {
    const originalMigration = await readFile(migrationPath, "utf8");
    // Original applied migration remains untouched (no inventory_item_id)
    assert.doesNotMatch(originalMigration, /recipe_row \? 'inventory_item_id'/);

    // Follow-up migration provides canonical inventory identity
    const followUpMigration = await readFile(identityMigrationPath, "utf8");
    assert.match(followUpMigration, /create or replace function public\.create_branch_catalog_product/);
    assert.match(followUpMigration, /create or replace function public\.save_branch_product_usage_mappings/);
    assert.match(followUpMigration, /recipe_row \? 'inventory_item_id'/);
    assert.match(followUpMigration, /recipe_row->>'inventory_item_id'\)::uuid/);
    assert.match(followUpMigration, /item\.branch_id = target_branch\.id/);
    assert.match(followUpMigration, /item\.organization_id = target_branch\.organization_id/);
    assert.match(followUpMigration, /inventory item unavailable/);
    assert.match(followUpMigration, /duplicate recipe inventory item/);

    // Guarantees: no mutation of inventory item master, no mutation of historical snapshots, waste, or inventory entries
    assert.doesNotMatch(followUpMigration, /update public\.branch_inventory_catalog_items/i);
    assert.doesNotMatch(followUpMigration, /delete from public\.branch_inventory_catalog_items/i);
    assert.doesNotMatch(followUpMigration, /update public\.branch_product_sales_usage_snapshots/i);
    assert.doesNotMatch(followUpMigration, /delete from public\.branch_product_sales_usage_snapshots/i);
    assert.doesNotMatch(followUpMigration, /update public\.branch_daily_waste_entries/i);
    assert.doesNotMatch(followUpMigration, /update public\.branch_daily_inventory_entries/i);
  });

  it("safely merges duplicate ingredients into canonical item in 20260913130000 without rewriting historical transactions", async () => {
    const mergeMigrationPath = new URL("../../supabase/migrations/20260913130000_catalog_inventory_item_merge.sql", import.meta.url);
    const mergeMigration = await readFile(mergeMigrationPath, "utf8");

    // Defines merge RPC with security definer and empty search path
    assert.match(mergeMigration, /create or replace function public\.merge_branch_catalog_inventory_item/);
    assert.match(mergeMigration, /security definer/);
    assert.match(mergeMigration, /set search_path = ''/);
    assert.match(mergeMigration, /private\.require_branch_catalog_scope\(actor_user_id, target_branch_id\)/);

    // Validations: self-merge, branch/org boundaries, ingredient kind, active target, unit compatibility
    assert.match(mergeMigration, /duplicate_inventory_item_id = target_inventory_item_id/);
    assert.match(mergeMigration, /source_item\.branch_id <> target_branch\.id/);
    assert.match(mergeMigration, /target_item\.branch_id <> target_branch\.id/);
    assert.match(mergeMigration, /source_item\.kind <> 'ingredient' or target_item\.kind <> 'ingredient'/);
    assert.match(mergeMigration, /not target_item\.is_active/);
    assert.match(mergeMigration, /source_item\.unit <> target_item\.unit/);

    // Collision safety: detects same-product collision and rejects with 23505
    assert.match(mergeMigration, /recipe collision in product/);
    assert.match(mergeMigration, /errcode = '23505'/);

    // Reassigns recipe mappings and archives source item
    assert.match(mergeMigration, /update public\.branch_product_usage_mappings[\s\S]*set inventory_item_id = target_item\.id/);
    assert.match(mergeMigration, /update public\.branch_inventory_catalog_items[\s\S]*set is_active = false/);

    // Service role execution only
    assert.match(mergeMigration, /revoke all on function public\.merge_branch_catalog_inventory_item\(uuid, uuid, uuid, uuid\) from public, anon, authenticated/);
    assert.match(mergeMigration, /grant execute on function public\.merge_branch_catalog_inventory_item\(uuid, uuid, uuid, uuid\) to service_role/);

    // Absolute historical isolation guarantees: zero transaction/snapshot rewrites or deletes
    assert.doesNotMatch(mergeMigration, /update public\.branch_product_sales_usage_snapshots/i);
    assert.doesNotMatch(mergeMigration, /delete from public\.branch_product_sales_usage_snapshots/i);
    assert.doesNotMatch(mergeMigration, /update public\.branch_daily_waste_entries/i);
    assert.doesNotMatch(mergeMigration, /delete from public\.branch_daily_waste_entries/i);
    assert.doesNotMatch(mergeMigration, /update public\.branch_daily_inventory_entries/i);
    assert.doesNotMatch(mergeMigration, /delete from public\.branch_daily_inventory_entries/i);
    assert.doesNotMatch(mergeMigration, /delete from public\.branch_inventory_catalog_items/i);
    assert.doesNotMatch(mergeMigration, /update public\.branch_product_catalog_products/i);
  });

  it("permits recipe replacement via ON DELETE SET NULL on snapshot foreign key in 20260913140000", async () => {
    const setNullMigrationPath = new URL("../../supabase/migrations/20260913140000_product_usage_mapping_snapshot_fk_set_null.sql", import.meta.url);
    const setNullMigration = await readFile(setNullMigrationPath, "utf8");

    // Drops RESTRICT constraint and adds ON DELETE SET NULL constraint
    assert.match(setNullMigration, /drop\s+constraint\s+if\s+exists\s+branch_product_sales_usage_snapshots_recipe_mapping_id_fkey/i);
    assert.match(setNullMigration, /foreign\s+key\s*\(recipe_mapping_id\)\s+references\s+public\.branch_product_usage_mappings\(id\)\s+on\s+delete\s+set\s+null/i);

    // Guaranteed: does NOT alter frozen snapshot business data or delete snapshots
    assert.doesNotMatch(setNullMigration, /delete\s+from/i);
    assert.doesNotMatch(setNullMigration, /update\s+public/i);
  });
});
