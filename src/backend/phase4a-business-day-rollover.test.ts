import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20260829110000_phase4a_0300_business_day.sql");
const foundationPath = path.resolve("supabase/migrations/20260801020000_phase4a_haccp_persistence.sql");
const branchSharedPath = path.resolve("supabase/migrations/20260812041000_branch_shared_authorization_compatibility.sql");
const coldSlotsPath = path.resolve("supabase/migrations/20260811190000_cold_storage_12_20_02_slots.sql");

describe("Phase 4A 03:00 business day rollover", () => {
  it("adds a deterministic SQL helper and delegates the canonical helper through it", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function private\.phase4a_business_date_at\(tz text, as_of timestamptz\)/);
    assert.match(migration, /\(\(as_of at time zone tz\) - interval '3 hours'\)::date/);
    assert.match(migration, /create or replace function private\.phase4a_business_date\(tz text\)/);
    assert.match(migration, /select private\.phase4a_business_date_at\(tz, pg_catalog\.statement_timestamp\(\)\)/);
    assert.doesNotMatch(migration, /'Asia\/Riyadh'.*phase4a_business_date_at/);
  });

  it("matches the required boundary behavior for Riyadh and a DST-capable timezone", () => {
    assert.equal(businessDate("Asia/Riyadh", "2026-08-28T21:01:00.000Z"), "2026-08-28");
    assert.equal(businessDate("Asia/Riyadh", "2026-08-28T23:59:59.000Z"), "2026-08-28");
    assert.equal(businessDate("Asia/Riyadh", "2026-08-29T00:00:00.000Z"), "2026-08-29");
    assert.equal(businessDate("Asia/Riyadh", "2026-08-29T20:59:00.000Z"), "2026-08-29");
    assert.equal(businessDate("America/New_York", "2026-01-15T07:59:59.000Z"), "2026-01-14");
    assert.equal(businessDate("America/New_York", "2026-01-15T08:00:00.000Z"), "2026-01-15");
  });

  it("keeps the branch context callers centralized on the canonical helper", async () => {
    const [foundation, branchShared] = await Promise.all([
      readFile(foundationPath, "utf8"),
      readFile(branchSharedPath, "utf8"),
    ]);
    assert.match(foundation, /private\.phase4a_actor_context[\s\S]*private\.phase4a_business_date\(b\.timezone\)/);
    assert.match(branchShared, /private\.phase2_branch_context[\s\S]*private\.phase4a_business_date\(b\.timezone\)/);
  });

  it("keeps current-day Manager and notification support functions aligned to the 03:00 helper", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /private\.managed_financial_closing_operations_summary/);
    assert.match(migration, /private\.phase4a_business_date_at\(branch\.timezone, as_of\) business_date/);
    assert.match(migration, /when branch\.local_clock < time '03:00' then branch\.business_date/);
    assert.match(migration, /else branch\.business_date - 1/);
    assert.match(migration, /create or replace function private\.supervisor_notification_branch_scope/);
    assert.match(migration, /private\.phase4a_business_date_at\(branch\.timezone, pg_catalog\.statement_timestamp\(\)\)/);
    assert.doesNotMatch(migration, /supervisor_notification_context/);
  });

  it("preserves the 02:00 Cold Storage slot schedule and 03:00 closure boundary", async () => {
    const coldSlots = await readFile(coldSlotsPath, "utf8");
    const closed = coldSlots.slice(coldSlots.indexOf("create or replace function private.cold_storage_closed_slots_for"));
    assert.match(coldSlots, /'12:00','20:00','02:00'/);
    assert.match(closed, /if local_hour < 3 then return array\['12:00','20:00'\]::text\[\]; end if;/);
    assert.doesNotMatch(await readFile(migrationPath, "utf8"), /create or replace function private\.cold_storage_(?:due|closed)_slots_for/);
  });
});

function businessDate(timeZone: string, isoTimestamp: string) {
  const parts = new Intl.DateTimeFormat("en-US-u-ca-gregory", {
    calendar: "gregory",
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(isoTimestamp));
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const shifted = new Date(Date.UTC(Number(values.year), Number(values.month) - 1, Number(values.day), Number(values.hour) - 3, Number(values.minute), Number(values.second)));
  return `${shifted.getUTCFullYear()}-${String(shifted.getUTCMonth() + 1).padStart(2, "0")}-${String(shifted.getUTCDate()).padStart(2, "0")}`;
}
