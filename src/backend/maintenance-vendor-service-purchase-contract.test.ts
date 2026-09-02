import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve(
  "supabase/migrations/20260902140000_maintenance_vendor_service_purchase_contract.sql",
);
const repairedMigrationPath = path.resolve(
  "supabase/migrations/20260902120000_maintenance_phase1_nullif_runtime_repair.sql",
);
const source = () => readFile(migrationPath, "utf8");

// Phase B follow-up: canonicalize the general-purchase payload before hashing, hash that
// canonical payload, and pass the exact same payload to the RPC. Required equivalences are
// omitted scope == explicit `other`, omitted office destination == canonical `Office`, and
// branch scope hashes the validated branch_id with destination == null.

describe("Maintenance Vendor / Service purchase database contract", () => {
  it("is a forward-only constraint replacement with no data rewrite", async () => {
    const migration = await source();
    const validateAt = migration.indexOf("validate constraint maintenance_purchase_type_contract_v2_check");
    const dropAt = migration.indexOf("drop constraint maintenance_purchase_type_check");

    assert.ok(validateAt >= 0 && dropAt > validateAt);
    assert.match(migration, /add constraint maintenance_purchase_unit_contract_v2_check[\s\S]*'service'[\s\S]*not valid/);
    assert.match(migration, /add constraint maintenance_purchase_category_contract_v2_check[\s\S]*'service'[\s\S]*not valid/);
    assert.match(migration, /validate constraint maintenance_purchase_service_shape_check/);
    assert.doesNotMatch(migration, /\b(?:update|delete from|truncate)\s+public\.maintenance_purchase_logs\b/i);
  });

  it("preserves historical enums and enforces the service pair and provider shape", async () => {
    const migration = await source();
    for (const unit of ["pcs", "meter", "kg", "box", "bag", "roll", "set", "liter", "other", "service"]) {
      assert.match(migration, new RegExp(`'${unit}'`));
    }
    for (const category of [
      "spare_parts", "tools_equipment", "electrical", "plumbing", "hvac_refrigeration",
      "kitchen_equipment", "fuel_petrol", "transportation", "technician_contractor",
      "building_facility", "safety_equipment", "it_network", "general_supplies", "other", "service",
    ]) {
      assert.match(migration, new RegExp(`'${category}'`));
    }
    assert.match(migration, /\(category <> 'service' and unit <> 'service'\)[\s\S]*purchase_type = 'general'[\s\S]*category = 'service'[\s\S]*unit = 'service'[\s\S]*quantity = 1[\s\S]*upper\(vendor_name\) <> 'N\/A'/);
  });

  it("makes general branch, office, and other rows canonical", async () => {
    const migration = await source();
    assert.match(migration, /purchase_scope = 'branch' and branch_id is not null and destination is null/);
    assert.match(migration, /purchase_scope = 'office' and branch_id is null and destination = 'Office'/);
    assert.match(migration, /purchase_scope = 'other' and branch_id is null and destination is not null/);
    assert.match(migration, /saved_scope := coalesce\(requested_scope, 'other'\)/);
    assert.match(migration, /select branch\.id into target_branch\s+from public\.branches branch\s+where branch\.id = requested_branch_id\s+and branch\.organization_id = target_organization\s+and branch\.active\s+for share;/);
    assert.match(migration, /raise exception 'maintenance purchase access denied' using errcode = '42501'/);
  });

  it("keeps the repaired CASE-based UUID parsing and existing mutation boundaries", async () => {
    const [migration, repairedMigration] = await Promise.all([source(), readFile(repairedMigrationPath, "utf8")]);
    const preservedFragments = [
      "when payload->>'purchase_id' is null or payload->>'purchase_id' = '' then null",
      "when payload->>'branch_id' is null or payload->>'branch_id' = '' then null",
      "when payload->>'idempotency_key' is null or payload->>'idempotency_key' = '' then null",
      "on conflict (organization_id, maintenance_issue_id, idempotency_key)",
      "on conflict (organization_id, idempotency_key)",
      "maintenance purchase idempotency payload changed",
      "jsonb_array_elements(coalesce(payload->'attachments', '[]'::jsonb)) with ordinality",
      "attachment_mime not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')",
      "attachment_size <= 0 or attachment_size > 5242880",
      "return next private.maintenance_purchase_json(saved)",
    ];

    for (const fragment of preservedFragments) {
      assert.ok(repairedMigration.includes(fragment), `repair source should contain ${fragment}`);
      assert.ok(migration.includes(fragment), `new migration should preserve ${fragment}`);
    }
    assert.doesNotMatch(migration, /nullif\(payload->>'(?:purchase_id|branch_id|idempotency_key)'/i);
  });

  it("changes only the general target branch insert while leaving issue routing intact", async () => {
    const migration = await source();
    assert.match(migration, /if target_issue_id is not null then[\s\S]*issue := private\.require_maintenance_purchase_issue[\s\S]*saved_type := 'issue'/);
    assert.match(migration, /purchase_id, target_organization, target_branch, target_issue_id, saved_type, saved_scope/);
    assert.match(migration, /purchase_id, target_organization, target_branch, null, saved_type, saved_scope, saved_destination/);
    assert.match(migration, /if purchase_category = 'service' or purchase_unit = 'service' then[\s\S]*saved_type <> 'general'[\s\S]*qty <> 1/);
  });

  it("retains the exact service-role-only RPC security boundary", async () => {
    const migration = await source();
    assert.match(migration, /create or replace function public\.create_maintenance_purchase_log_v2\(\s*actor_user_id uuid,\s*target_issue_id uuid,\s*payload jsonb\s*\)/);
    assert.match(migration, /returns setof jsonb[\s\S]*security definer[\s\S]*set search_path = ''/);
    assert.match(migration, /revoke all on function public\.create_maintenance_purchase_log_v2\(uuid, uuid, jsonb\)\s*from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.create_maintenance_purchase_log_v2\(uuid, uuid, jsonb\)\s*to service_role/);
  });
});
