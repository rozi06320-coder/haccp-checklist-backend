import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { managementOverviewSchema } from "../lib/contracts/management-overview";

const migrationPath = "supabase/migrations/20260930130000_management_percentage_branch_applicability.sql";

describe("Management percentage branch applicability", () => {
  it("configures only the two production branches with percentage-specific flags", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /sales_tracking_percentage_included boolean not null default true/);
    assert.match(sql, /oil_tracking_percentage_included boolean not null default true/);
    assert.match(sql, /03acf21e-fbca-48d0-955f-5e783d43c23e/);
    assert.match(sql, /4fafc3dc-269b-4864-8625-5d7a66d39c50/);
    assert.doesNotMatch(sql, /sales_tracking_enabled|oil_tracking_enabled/);
  });

  it("derives the successor from the effective functions and leaves raw unit populations intact", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    assert.match(sql, /pg_get_functiondef\('public\.get_phase4a_management_overview\(uuid,uuid\)'::regprocedure\)/);
    assert.match(sql, /pg_get_functiondef\('public\.get_management_overview_with_daily_audit\(uuid,uuid\)'::regprocedure\)/);
    assert.doesNotMatch(sql, /oil_unit_keys[\s\S]*?oil_tracking_percentage_included/);
    assert.doesNotMatch(sql, /sales_tracking_unit_keys[\s\S]*?sales_tracking_percentage_included/);
    assert.match(sql, /branch_percentage_metrics as materialized/);
    assert.match(sql, /filter \(where metric\.percentage_included\)/);
    assert.match(sql, /not checklist\.percentage_included or checklist\.expected_checks = 0/);
    assert.match(sql, /not checklist\.percentage_included or checklist\.answered_checks = 0/);
  });

  it("preserves raw counts while validating an independent percentage basis", () => {
    const excludedCounts = {
      expected_checks: 3,
      answered_checks: 2,
      compliant_checks: 1,
      issue_checks: 1,
      pending_checks: 1,
      percentage_expected_checks: 0,
      percentage_answered_checks: 0,
      percentage_compliant_checks: 0,
      completion_percentage: null,
      compliance_percentage: null,
    };
    const dailyCounts = {
      expected_checks: 13,
      answered_checks: 13,
      compliant_checks: 13,
      issue_checks: 0,
      pending_checks: 0,
      percentage_expected_checks: 13,
      percentage_answered_checks: 13,
      percentage_compliant_checks: 13,
      completion_percentage: 100,
      compliance_percentage: 100,
    };
    const zeroCounts = {
      expected_checks: 0,
      answered_checks: 0,
      compliant_checks: 0,
      issue_checks: 0,
      pending_checks: 0,
      percentage_expected_checks: 0,
      percentage_answered_checks: 0,
      percentage_compliant_checks: 0,
      completion_percentage: null,
      compliance_percentage: null,
    };
    const checklists = [
      ["kitchen_opening", zeroCounts],
      ["foh_opening", zeroCounts],
      ["staff_hygiene", zeroCounts],
      ["oil_tracking", excludedCounts],
      ["cold_storage", zeroCounts],
      ["sales_tracking", zeroCounts],
      ["daily_audit", dailyCounts],
    ].map(([checklist_type, counts]) => ({
      checklist_type,
      team_states: { not_started: 0, draft: 0, submitted: 0 },
      ...(counts as typeof zeroCounts),
    }));
    const totals = {
      expected_checks: 16,
      answered_checks: 15,
      compliant_checks: 14,
      issue_checks: 1,
      pending_checks: 1,
      percentage_expected_checks: 13,
      percentage_answered_checks: 13,
      percentage_compliant_checks: 13,
      completion_percentage: 100,
      compliance_percentage: 100,
    };
    const payload = {
      organization: { id: "83000000-0000-4000-8000-000000000001", name: "Organization" },
      generated_at: "2026-09-30T12:00:00Z",
      date_context: "current_branch_local_business_day",
      summary: { active_branch_count: 1, active_team_count: 1, active_supervisor_account_count: 1, active_operational_staff_count: 0 },
      totals,
      local_dates: [{ business_date: "2026-09-30", branch_count: 1 }],
      branches: [{
        branch_id: "03acf21e-fbca-48d0-955f-5e783d43c23e",
        branch_name: "Bakery Riyadh",
        branch_code: "BAKERY",
        timezone: "Asia/Riyadh",
        business_date: "2026-09-30",
        status: "ready",
        active_team_count: 1,
        totals,
        checklists,
      }],
    };

    assert.equal(managementOverviewSchema.parse(payload).totals.completion_percentage, 100);
  });
});
