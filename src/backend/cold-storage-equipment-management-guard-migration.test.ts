import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, it } from "node:test";

const migrationPath = resolve(
  "supabase/migrations/20260916130000_cold_storage_equipment_management_guard_variable_names.sql",
);

describe("Cold Storage equipment management guard migration", () => {
  it("uses non-conflicting PL/pgSQL variable names in the guard body", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /create or replace function private\.cold_storage_equipment_management_guard\(\)/);
    assert.match(sql, /security definer/);
    assert.match(sql, /set search_path to ''/);
    assert.match(sql, /v_business_date date;/);
    assert.match(sql, /v_current_slot text;/);
    assert.match(sql, /v_submission_id uuid;/);
    assert.match(sql, /v_organization_id uuid;/);
    assert.match(sql, /v_branch_id uuid;/);
    assert.match(sql, /pg_catalog\.pg_advisory_xact_lock/);
    assert.match(sql, /for update;/);
    assert.match(sql, /into\s+strict\s+v_business_date,\s*v_current_slot/i);
    assert.match(sql, /and branch\.active/);
    assert.match(sql, /snapshot\.master_equipment_id\s*=\s*old\.id/);
    assert.match(sql, /tg_op\s*=\s*'DELETE'[\s\S]*tg_op\s*=\s*'UPDATE'\s+and\s+not\s+coalesce\(new\.active,\s*false\)/);
    assert.match(sql, /from public\.cold_storage_equipment snapshot\s+join public\.cold_storage_readings reading/i);
    assert.match(sql, /reading\.submitted_at\s+is\s+null/);
    assert.match(sql, /reading\.temperature_c\s+is\s+not\s+null[\s\S]*pg_catalog\.length\(\s*pg_catalog\.btrim\(coalesce\(reading\.corrective_action,\s*''\)\)\s*\)\s*>\s*0/);
    assert.match(sql, /return case when tg_op\s*=\s*'DELETE' then old else new end;/);
    assert.match(sql, /cold storage equipment management locked/);
    assert.match(sql, /cold storage equipment has current draft/);

    assert.doesNotMatch(sql, /\bbusiness_date date;/);
    assert.doesNotMatch(sql, /\bcurrent_slot text;/);
    assert.doesNotMatch(sql, /\bsubmission_id uuid;/);
    assert.doesNotMatch(sql, /\borganization_id uuid;/);
    assert.doesNotMatch(sql, /\bbranch_id uuid;/);
    assert.doesNotMatch(sql, /branch\.organization_id = organization_id/);
    assert.doesNotMatch(sql, /submission\.branch_id = branch_id/);
    assert.doesNotMatch(sql, /submission\.business_date = business_date/);
    assert.doesNotMatch(sql, /reading\.submission_id = submission_id/);
    assert.doesNotMatch(sql, /reading\.status\s*<>/);
    assert.doesNotMatch(sql, /if v_business_date is null/);
    assert.doesNotMatch(sql, /if v_current_slot is null/);
    assert.doesNotMatch(sql, /if v_submission_id is null/);
  });
});
