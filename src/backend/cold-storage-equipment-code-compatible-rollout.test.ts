import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve(
  "supabase/migrations/20260829150000_cold_storage_equipment_code_compatible_rollout.sql",
);

const legacyMutationSignatures = [
  "public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text)",
  "public.update_supervisor_cold_storage_equipment(uuid, uuid, uuid, text, text)",
] as const;

const newMutationSignatures = [
  "public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text, text)",
  "public.update_supervisor_cold_storage_equipment(uuid, uuid, uuid, text, text, text)",
] as const;

const existingMutationSignatures = [
  "public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text)",
  "public.archive_supervisor_cold_storage_equipment(uuid, uuid, uuid)",
] as const;

describe("Cold Storage equipment code compatible rollout migration", () => {
  it("adds nullable equipment code schema without forcing a backfill or dropping legacy RPCs", async () => {
    const migration = await readMigration();

    assert.match(
      migration,
      /alter table public\.branch_cold_storage_equipment\s+add column if not exists equipment_code text null;/i,
    );
    assert.match(
      migration,
      /alter table public\.cold_storage_equipment\s+add column if not exists equipment_code text null;/i,
    );
    assert.match(migration, /branch_cold_storage_equipment_code_check/i);
    assert.match(migration, /cold_storage_equipment_code_check/i);
    assert.match(migration, /equipment_code = pg_catalog\.upper\(pg_catalog\.btrim\(equipment_code\)\)/);
    assert.match(migration, /pg_catalog\.length\(equipment_code\) between 1 and 24/);
    assert.match(migration, /equipment_code ~ '\^\[A-Z0-9-\]\+\$'/);
    assert.match(migration, /branch_cold_storage_equipment_active_equipment_code_key/i);
    assert.match(migration, /where active and equipment_code is not null;/i);
    assert.doesNotMatch(migration, /equipment_code\s+set\s+not\s+null/i);
    assert.doesNotMatch(migration, /drop function public\.create_supervisor_cold_storage_equipment\(uuid, uuid, text, text\)/i);
    assert.doesNotMatch(migration, /drop function public\.update_supervisor_cold_storage_equipment\(uuid, uuid, uuid, text, text\)/i);
  });

  it("extends the DTO and recreates every DTO-returning equipment RPC with equipment_code", async () => {
    const migration = await readMigration();

    assert.match(migration, /alter type public\.supervisor_cold_storage_equipment_dto\s+add attribute equipment_code text;/i);
    for (const functionName of [
      "list_supervisor_cold_storage_equipment",
      "create_supervisor_cold_storage_equipment",
      "update_supervisor_cold_storage_equipment",
      "rename_supervisor_cold_storage_equipment",
      "archive_supervisor_cold_storage_equipment",
    ]) {
      assert.match(migration, new RegExp(`create or replace function public\\.${functionName}\\(`, "i"));
    }
    assert.match(migration, /equipment\.updated_at,\s+equipment\.equipment_code\s+from public\.branch_cold_storage_equipment equipment/i);
    assert.match(migration, /created_equipment\.updated_at,\s+created_equipment\.equipment_code;/i);
    assert.match(migration, /updated_equipment\.updated_at,\s+updated_equipment\.equipment_code;/i);
    assert.match(migration, /renamed_equipment\.updated_at,\s+renamed_equipment\.equipment_code;/i);
    assert.match(migration, /archived_equipment\.updated_at,\s+archived_equipment\.equipment_code;/i);
  });

  it("preserves legacy create/update behavior while adding equipment-code-aware overloads", async () => {
    const migration = await readMigration();
    const legacyCreate = functionBlock(migration, "public.create_supervisor_cold_storage_equipment", "actor_user_id uuid,\n  target_branch_id uuid,\n  equipment_name text,\n  equipment_type text");
    const newCreate = functionBlock(migration, "public.create_supervisor_cold_storage_equipment", "actor_user_id uuid,\n  target_branch_id uuid,\n  equipment_code text,\n  equipment_name text,\n  equipment_type text");
    const legacyUpdate = functionBlock(migration, "public.update_supervisor_cold_storage_equipment", "actor_user_id uuid,\n  target_branch_id uuid,\n  target_equipment_id uuid,\n  equipment_name text,\n  equipment_type text");
    const newUpdate = functionBlock(migration, "public.update_supervisor_cold_storage_equipment", "actor_user_id uuid,\n  target_branch_id uuid,\n  target_equipment_id uuid,\n  equipment_code text,\n  equipment_name text,\n  equipment_type text");

    assert.match(legacyCreate, /equipment_code,\s+name,\s+equipment_type/i);
    assert.match(legacyCreate, /null,\s+clean_name,\s+equipment_type/i);
    assert.doesNotMatch(legacyCreate, /clean_cold_storage_equipment_code/i);

    assert.match(newCreate, /clean_code text := private\.clean_cold_storage_equipment_code\(equipment_code\);/);
    assert.match(newCreate, /existing\.equipment_code = clean_code/i);
    assert.match(newCreate, /clean_code,\s+clean_name,\s+equipment_type/i);

    assert.doesNotMatch(legacyUpdate, /set equipment_code/i);
    assert.match(legacyUpdate, /set name = clean_name,\s+equipment_type = update_supervisor_cold_storage_equipment\.equipment_type/i);

    assert.match(newUpdate, /clean_code text := private\.clean_cold_storage_equipment_code\(equipment_code\);/);
    assert.match(newUpdate, /existing\.equipment_code = clean_code/i);
    assert.match(newUpdate, /set equipment_code = clean_code,\s+name = clean_name,/i);
  });

  it("propagates equipment_code through snapshots, current state, and report detail JSON", async () => {
    const migration = await readMigration();

    assert.match(migration, /create or replace function private\.resolve_cold_storage_equipment_roster/i);
    assert.match(migration, /private\.clean_cold_storage_equipment_code\(entry ->> 'equipment_code'\)/);
    assert.match(migration, /'equipment_code', master\.equipment_code/);
    assert.match(migration, /create or replace function private\.cold_storage_snapshot_equipment/i);
    assert.match(migration, /'equipment_code', equipment\.equipment_code/);
    assert.match(migration, /create or replace function private\.replace_cold_storage_equipment/i);
    assert.match(migration, /insert into public\.cold_storage_equipment\(\s+submission_id,\s+equipment_id,\s+equipment_code,/i);
    assert.match(migration, /'equipment_code',e\.equipment_code/);
    assert.match(migration, /'equipment_code', e\.equipment_code/);
  });

  it("keeps legacy and new mutation overloads service-role-only", async () => {
    const migration = await readMigration();

    for (const signature of [
      ...legacyMutationSignatures,
      ...newMutationSignatures,
      ...existingMutationSignatures,
    ]) {
      assert.match(migration, new RegExp(`revoke execute on function ${escapeRegExp(signature)} from public;`, "i"));
      assert.match(migration, new RegExp(`revoke execute on function ${escapeRegExp(signature)} from anon;`, "i"));
      assert.match(migration, new RegExp(`revoke execute on function ${escapeRegExp(signature)} from authenticated;`, "i"));
      assert.match(migration, new RegExp(`grant execute on function ${escapeRegExp(signature)} to service_role;`, "i"));
    }
    assert.doesNotMatch(migration, /grant execute on function public\.[^;]+ to anon;/i);
    assert.doesNotMatch(migration, /grant execute on function public\.[^;]+ to authenticated;/i);
  });

  it("does not replace slot eligibility, business-day, or refrigerator internal identifiers", async () => {
    const migration = await readMigration();

    assert.doesNotMatch(migration, /create or replace function private\.cold_storage_eligible_slot_at/i);
    assert.doesNotMatch(migration, /create or replace function public\.save_cold_storage_draft/i);
    assert.doesNotMatch(migration, /create or replace function public\.submit_cold_storage_slot/i);
    assert.match(migration, /row_value ->> 'equipment_type'/);
    assert.match(migration, /scheduled Chiller & Freezer check/);
    assert.doesNotMatch(migration, /scheduled Refrigerator & Freezer check/);
  });
});

async function readMigration(): Promise<string> {
  return readFile(migrationPath, "utf8");
}

function functionBlock(sql: string, qualifiedName: string, args: string): string {
  const start = sql.indexOf(`create or replace function ${qualifiedName}(\n  ${args}\n)`);
  assert.notEqual(start, -1, `missing function block for ${qualifiedName}(${args})`);
  const next = sql.indexOf("\ncreate or replace function ", start + 1);
  return next === -1 ? sql.slice(start) : sql.slice(start, next);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/ /g, "\\s+");
}
