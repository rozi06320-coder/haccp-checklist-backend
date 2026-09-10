import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL("../../supabase/migrations/20260910110000_daily_waste_phase3b2.sql", import.meta.url);

describe("Daily Waste Phase 3B2 SQL boundary", () => {
  it("creates only Phase 3B2 daily waste tables with RLS and proper tenant constraints", async () => {
    const migration = await readFile(migrationPath, "utf8");
    for (const table of ["branch_daily_waste_reports", "branch_daily_waste_entries"]) {
      assert.match(migration, new RegExp(`create table if not exists public\\.${table}`));
      assert.match(migration, new RegExp(`${table}[\\s\\S]*organization_id uuid not null references public\\.organizations`));
      assert.match(migration, new RegExp(`${table}[\\s\\S]*branch_id uuid not null references public\\.branches`));
      assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`));
      assert.match(migration, new RegExp(`drop policy if exists ${table}_select_authorized on public\\.${table}`));
      assert.match(migration, new RegExp(`create policy ${table}_select_authorized[\\s\\S]*private\\.has_branch_access\\(branch_id\\)`));
    }
    // Ensures no kind snapshot column and no unrelated tables created
    assert.doesNotMatch(migration, /kind_snapshot text/i);
    assert.doesNotMatch(migration, /create table (if not exists )?public\.(daily_waste|transfer_in|transfer_out|actual_closing|expected_closing|variance|inventory_movement)/i);
  });

  it("keeps Daily Waste writes service-role RPC only and revokes direct browser mutations", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /revoke all on table public\.branch_daily_waste_reports, public\.branch_daily_waste_entries from public, anon, authenticated, service_role/);
    assert.match(migration, /grant select on table public\.branch_daily_waste_reports, public\.branch_daily_waste_entries to authenticated, service_role/);
    assert.match(migration, /create or replace function public\.save_branch_daily_waste/);
    assert.match(migration, /create or replace function public\.get_branch_daily_waste/);
    assert.match(migration, /if \(end_date - start_date\) > 62 then/);
    assert.match(migration, /daily waste date range exceeds maximum of 62 days/);
    assert.match(migration, /revoke all on function public\.get_branch_daily_waste\(uuid, uuid, date, date\), public\.save_branch_daily_waste\(uuid, uuid, date, bigint, jsonb\) from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.get_branch_daily_waste\(uuid, uuid, date, date\), public\.save_branch_daily_waste\(uuid, uuid, date, bigint, jsonb\) to service_role/);
  });

  it("authorizes and validates only server-side canonical data with advisory lock", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /private\.phase2_branch_context\(actor_user_id, target_branch_id\)/);
    assert.match(migration, /target_business_date > ctx\.business_date/);
    assert.match(migration, /pg_advisory_xact_lock/);
    assert.match(migration, /expected_revision/);
    assert.match(migration, /item\.organization_id = ctx\.organization_id/);
    assert.match(migration, /item\.branch_id = ctx\.branch_id/);
    assert.match(migration, /item\.is_active/);
    assert.match(migration, /duplicate daily waste inventory item/);
    assert.match(migration, /jsonb_object_keys\(item_row\) as k/);
    assert.match(migration, /k not in \('inventory_item_id', 'quantity', 'note'\)/);
    assert.match(migration, /invalid daily waste payload: unexpected field/);
  });

  it("enforces private threshold helper and note requirements", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function private\.is_daily_waste_note_required\(p_unit text, p_quantity numeric\)/);
    assert.match(migration, /revoke all on function private\.is_daily_waste_note_required\(text, numeric\) from public, anon, authenticated/);
    assert.match(migration, /pcs quantity must be an integer/);
    assert.match(migration, /note required when waste exceeds threshold for unit/);
    assert.match(migration, /daily waste note exceeds maximum length/);
  });

  it("implements partial patch semantics with revision increment on change and no-op preservation", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create temp table branch_daily_waste_stage/);
    assert.match(migration, /delete from public\.branch_daily_waste_entries entry[\s\S]*stage\.quantity = 0/);
    assert.match(migration, /if not changed then[\s\S]*private\.branch_daily_waste_payload/);
    assert.match(migration, /set revision = existing\.revision \+ 1/);
  });

  it("preserves frozen historical name and unit snapshots during correction without re-reading catalog", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create temp table branch_daily_waste_existing/);
    assert.match(migration, /update public\.branch_daily_waste_entries entry[\s\S]*set quantity = stage\.quantity,\s*note = stage\.note,\s*updated_at = now\(\)/);
    assert.doesNotMatch(migration, /update public\.branch_daily_waste_entries[\s\S]*inventory_item_name_snapshot = /);
    assert.doesNotMatch(migration, /update public\.branch_daily_waste_entries[\s\S]*inventory_item_unit_snapshot = /);
  });
});
