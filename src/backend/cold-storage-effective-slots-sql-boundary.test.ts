import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20260830100000_cold_storage_equipment_effective_slots.sql");
const source = () => readFile(migrationPath, "utf8");

describe("Cold Storage equipment effective-slot migration", () => {
  it("keeps the repair forward-only and avoids new equipment start columns", async () => {
    const migration = await source();
    assert.match(migration, /create or replace function private\.cold_storage_master_first_eligible_slot/);
    assert.match(migration, /create or replace function private\.cold_storage_master_has_backfilled_history/);
    assert.match(migration, /create or replace function public\.get_cold_storage_current_state/);
    assert.match(migration, /create or replace function private\.upsert_cold_storage_submission/);
    assert.doesNotMatch(migration, /alter table public\.branch_cold_storage_equipment[\s\S]*add column/i);
    assert.doesNotMatch(migration, /2026-08-30 00:00:00\+00/);
    assert.doesNotMatch(migration, /delete from public\.cold_storage_readings[\s\S]*submitted_at is not null/i);
  });

  it("documents conservative first-eligible-slot boundaries using branch local time", async () => {
    const migration = await source();
    assert.match(migration, /local_created_at::time as local_time/);
    assert.match(migration, /\(local_created_at - interval '3 hours'\)::date as created_business_date/);
    assert.match(migration, /local_time >= time '03:00' and local_time < time '12:00' then '12:00'/);
    assert.match(migration, /local_time >= time '12:00' and local_time < time '20:00' then '20:00'/);
    assert.match(migration, /local_time >= time '20:00' or local_time < time '02:00' then '02:00'/);
    assert.match(migration, /local_time >= time '02:00' and local_time < time '03:00'[\s\S]*created_business_date \+ 1/);
  });

  it("returns active masters plus historical snapshots with eligibility metadata", async () => {
    const migration = await source();
    const currentState = migration.match(/create or replace function public\.get_cold_storage_current_state[\s\S]*?\n\$\$;/)?.[0] ?? "";
    assert.match(currentState, /from public\.branch_cold_storage_equipment master/);
    assert.match(currentState, /private\.cold_storage_master_has_backfilled_history\(master\.id, master\.created_at\)/);
    assert.match(currentState, /historical_snapshot/);
    assert.match(currentState, /reading\.submitted_at is not null/);
    assert.match(currentState, /'first_eligible_business_date'/);
    assert.match(currentState, /'first_eligible_slot'/);
    assert.match(currentState, /'eligible_for_active_slot'/);
    assert.doesNotMatch(currentState, /if has_submitted then[\s\S]*from public\.cold_storage_equipment e where e\.submission_id=s\.id/i);
  });

  it("appends future master equipment without replacing submitted snapshots", async () => {
    const migration = await source();
    assert.match(migration, /create or replace function private\.ensure_cold_storage_snapshot_master_equipment/);
    assert.match(migration, /insert into public\.cold_storage_equipment\(/);
    assert.match(migration, /not exists \([\s\S]*snapshot\.master_equipment_id = master\.id/);
    assert.match(migration, /perform private\.ensure_cold_storage_snapshot_master_equipment\(s\.id, c\.organization_id, c\.branch_id\)/);
    assert.doesNotMatch(migration, /submitted cold storage equipment is immutable/);
    assert.doesNotMatch(migration, /cold_storage_equipment_set_matches\(s\.id,equipment\)/);
  });

  it("validates and completes only equipment eligible for each slot", async () => {
    const migration = await source();
    const submit = migration.match(/create or replace function public\.submit_cold_storage_slot[\s\S]*?\n\$\$;/)?.[0] ?? "";
    assert.match(migration, /create or replace function private\.validate_cold_storage_slot_submit_for_eligible/);
    assert.match(migration, /create or replace function private\.cold_storage_filter_eligible_readings/);
    assert.match(migration, /create or replace function private\.cold_storage_submission_complete/);
    assert.match(submit, /private\.validate_cold_storage_slot_submit_for_eligible\(slot, snapshot_equipment, readings, s\.business_date\)/);
    assert.match(submit, /private\.cold_storage_json_equipment_slot_eligible\(equipment\.row_value, s\.business_date, submit_cold_storage_slot\.slot\)/);
    assert.match(submit, /private\.cold_storage_submission_complete\(s\.id, target_branch_id, s\.business_date\)/);
    assert.doesNotMatch(submit, /cross join\(values\('12:00'\),\('20:00'\),\('02:00'\)\)expected\(slot\)[\s\S]*e\.active/);
  });
});
