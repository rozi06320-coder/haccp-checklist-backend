import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const source = (path: string) => readFile(path, "utf8");

describe("Internal Admin Training credential SQL boundary", () => {
  it("reuses all three hardened Phase 2A RPCs", async () => {
    const adapter = await source("src/backend/training-credential-admin.ts");
    for (const rpc of [
      "store_internal_admin_operational_staff_training_credential",
      "revoke_internal_admin_operational_staff_training_credential",
      "get_internal_admin_operational_staff_training_credential_status",
    ]) assert.match(adapter, new RegExp(rpc));
  });

  it("keeps RPC execution service-role-only with SECURITY DEFINER and an empty search path", async () => {
    const migration = await source("supabase/migrations/20261013220000_training_lms_foundation.sql");
    for (const rpc of [
      "store_internal_admin_operational_staff_training_credential",
      "revoke_internal_admin_operational_staff_training_credential",
      "get_internal_admin_operational_staff_training_credential_status",
    ]) {
      const block = migration.slice(migration.indexOf(`create or replace function public.${rpc}`), migration.indexOf("$$;", migration.indexOf(`create or replace function public.${rpc}`)) + 3);
      assert.match(block, /security definer/); assert.match(block, /set search_path = ''/); assert.match(block, /private\.is_internal_admin/);
      assert.match(migration, new RegExp(`grant execute on function public\\.${rpc}\\([^;]+\\) to service_role;`));
    }
    assert.match(migration, /revoke all on table public\.operational_staff_training_credentials from public, anon, authenticated, service_role/);
    assert.match(migration, /alter table public\.operational_staff_training_credentials enable row level security/);
  });

  it("uses the established scrypt policy and revokes sessions on reset and revoke", async () => {
    const migration = await source("supabase/migrations/20261013220000_training_lms_foundation.sql");
    const store = migration.slice(migration.indexOf("create or replace function public.store_internal_admin_operational_staff_training_credential"), migration.indexOf("create or replace function public.revoke_internal_admin_operational_staff_training_credential"));
    assert.match(store, /new_kdf_version <> 1/); assert.match(store, /new_cost <> 16384/); assert.match(store, /new_block_size <> 8/); assert.match(store, /new_parallelization <> 1/);
    assert.match(store, /update public\.training_learner_sessions/); assert.match(store, /revoked_at = statement_timestamp\(\)/);
    const revoke = migration.slice(migration.indexOf("create or replace function public.revoke_internal_admin_operational_staff_training_credential"), migration.indexOf("create or replace function public.get_internal_admin_operational_staff_training_credential_status"));
    assert.match(revoke, /status = 'revoked'/); assert.match(revoke, /update public\.training_learner_sessions/);
  });

  it("returns only a deliberately reduced safe DTO from the backend adapter", async () => {
    const adapter = await source("src/backend/training-credential-admin.ts");
    const safeStatus = adapter.slice(adapter.indexOf("const safeStatus"), adapter.indexOf("const safeStored"));
    assert.match(safeStatus, /configured/); assert.match(safeStatus, /status/); assert.match(safeStatus, /locked_until/); assert.match(safeStatus, /updated_at/);
    assert.doesNotMatch(safeStatus, /pin_hash|salt|credential_version|failed_attempt_count/);
  });
});
