import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve(
  "supabase/migrations/20261011230000_management_overview_modern_operational_teams.sql",
);

describe("Manager Overview modern operational-team model", () => {
  it("uses modern, date-valid Supervisor assignments for active-team eligibility", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /from public\.branch_operational_teams team/);
    assert.match(sql, /from public\.branch_operational_team_supervisors assignment/);
    assert.match(sql, /assignment\.operational_team_id = team\.id/);
    assert.match(sql, /assignment\.branch_id = team\.branch_id/);
    assert.match(sql, /assignment\.organization_id = team\.organization_id/);
    assert.match(sql, /assignment\.active/);
    assert.match(sql, /assignment\.valid_from <= branch\.business_date/);
    assert.match(sql, /assignment\.valid_to is null or assignment\.valid_to >= branch\.business_date/);
    assert.match(sql, /membership\.role = 'branch_manager'/);
    assert.match(sql, /membership\.active/);
    assert.match(sql, /profile\.disabled_at is null/);
    assert.match(sql, /not profile\.must_change_password/);
    assert.doesNotMatch(sql, /from public\.branch_supervisor_teams/);
  });

  it("keeps Staff Hygiene team-owned and branch checklists branch-owned", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /eligible_hygiene_roster[\s\S]*assignment\.operational_team_id/);
    assert.match(sql, /candidate\.operational_team_id = unit\.team_id/);
    assert.match(sql, /select branch\.id branch_id, branch\.id team_id[\s\S]*opening_units/);
    assert.match(sql, /oil_selected_units[\s\S]*from active_branches branch/);
    assert.match(sql, /cold_selected_units[\s\S]*from active_branches branch/);
    assert.match(sql, /sales_tracking_selected_units[\s\S]*from active_branches branch/);
    assert.doesNotMatch(sql, /join eligible_teams team on team\.branch_id = branch\.id[\s\S]*oil_selected_units/);
  });

  it("retains bounded legacy attribution only for historical Hygiene reads", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /team\.legacy_supervisor_team_id/);
    assert.match(sql, /submission\.supervisor_team_id legacy_supervisor_team_id/);
    assert.match(sql, /candidate\.operational_team_id is null[\s\S]*candidate\.supervisor_team_id = unit\.legacy_supervisor_team_id/);
    assert.doesNotMatch(sql, /branch_supervisor_teams team/);
  });

  it("preserves the effective function contract and hardened privileges", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /pg_get_functiondef\([\s\S]*public\.get_phase4a_management_overview\(uuid,uuid\)/);
    assert.match(sql, /management overview work-unit block changed/);
    assert.match(sql, /revoke all on function public\.get_phase4a_management_overview\(uuid,uuid\)[\s\S]*from public, anon, authenticated/);
    assert.match(sql, /grant execute on function public\.get_phase4a_management_overview\(uuid,uuid\)[\s\S]*to service_role/);
    assert.doesNotMatch(sql, /create synthetic|insert into public\.branch_supervisor_teams/i);
  });
});
