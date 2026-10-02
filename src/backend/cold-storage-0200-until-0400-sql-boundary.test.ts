import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261002120000_cold_storage_0200_slot_until_0400.sql");

describe("Cold Storage 02:00 slot through 04:00 migration", () => {
  it("changes only the four authoritative schedule boundaries", async () => {
    const migration = await readFile(migrationPath, "utf8");
    for (const signature of [
      "private.cold_storage_eligible_slot_at",
      "private.cold_storage_slot_occurrence_local",
      "private.cold_storage_schedule_context_at",
      "private.cold_storage_closed_slots_for",
    ]) assert.match(migration, new RegExp(`create or replace function ${signature.replaceAll(".", "\\.")}`));
    for (const untouched of [
      "private.phase4a_business_date_at",
      "private.cold_storage_due_slots_for",
      "private.cold_storage_current_eligible_slot",
      "private.enforce_cold_storage_requested_slot",
      "public.submit_cold_storage_slot",
      "private.upsert_cold_storage_submission",
      "public.get_cold_storage_current_state",
    ]) assert.doesNotMatch(migration, new RegExp(`create or replace function ${untouched.replaceAll(".", "\\.")}`));
  });

  it("uses the canonical business date and closes the final occurrence at 04:00", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /target_business_date := private\.phase4a_business_date_at\(branch_timezone, as_of\)/);
    assert.match(migration, /target_slot::time < time '04:00'/);
    assert.equal((migration.match(/\(target_business_date \+ 1\)::timestamp \+ time '04:00'/g) ?? []).length, 2);
    assert.doesNotMatch(migration, /interval '3 hours'|time '03:00'/);
  });

  it("extends fixed eligibility and missed-slot closure without touching persistence", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /value >= time '02:00' and value < time '04:00' then '02:00'/);
    assert.match(migration, /if local_hour < 4 then return array\['12:00','20:00'\]::text\[\]/);
    assert.doesNotMatch(migration, /\b(?:insert into|update|delete from|truncate)\s+public\./i);
    assert.doesNotMatch(migration, /grant\s|revoke\s/i);
  });

  it("preserves submit idempotency, duplicate, revision, and management guards by inheritance", async () => {
    const [migration, submitSource, runtimeSource] = await Promise.all([
      readFile(migrationPath, "utf8"),
      readFile(path.resolve("supabase/migrations/20260829113000_cold_storage_slot_eligibility.sql"), "utf8"),
      readFile(path.resolve("supabase/migrations/20260830100000_cold_storage_equipment_effective_slots.sql"), "utf8"),
    ]);
    assert.match(submitSource, /idempotency conflict/);
    assert.match(submitSource, /cold storage slot already submitted/);
    assert.match(runtimeSource, /cold storage changed/);
    assert.doesNotMatch(migration, /cold_storage_submission_idempotency|cold storage slot already submitted|cold storage changed|management_locked\s*:=/i);
  });

  it("keeps optional schedule installation compatible with fresh repository databases", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /to_regclass\('public\.cold_storage_schedule_versions'\) is not null/);
    assert.match(migration, /to_regprocedure\('private\.cold_storage_schedule_context_at\(uuid,timestamptz\)'\) is not null/);
    assert.match(migration, /else[\s\S]*create or replace function private\.cold_storage_closed_slots_for/);
  });
});
