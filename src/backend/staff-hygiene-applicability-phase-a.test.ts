import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(new URL("../../supabase/migrations/20261028170000_staff_hygiene_operational_applicability.sql", import.meta.url), "utf8");
const reportSource = readFileSync(new URL("./daily-business-report.ts", import.meta.url), "utf8");
const contractMigration = readFileSync(new URL("../../supabase/migrations/20261029120000_staff_hygiene_supervisor_read_contract.sql", import.meta.url), "utf8");
const rangeMigration = readFileSync(new URL("../../supabase/migrations/20261029130000_staff_hygiene_manager_range_read_contract.sql", import.meta.url), "utf8");
const appSource = readFileSync(new URL("./app.ts", import.meta.url), "utf8");

describe("Staff Hygiene operational-team applicability Phase A", () => {
  it("uses branch, team, active employment, effective dates, duty date, and the 04:00 business date supplied by the caller", () => {
    assert.match(migration, /operational_staff_assignments/);
    assert.match(migration, /assignment\.operational_team_id/);
    assert.match(migration, /assignment\.valid_from <= p_business_date/);
    assert.match(migration, /assignment\.valid_to is null or assignment\.valid_to >= p_business_date/);
    assert.match(migration, /staff\.employment_status = 'active'/);
    assert.match(migration, /duty\.duty_date = p_business_date/);
    assert.match(migration, /coalesce\(duty\.duty_status, 'on_duty'\)/);
    assert.match(migration, /private\.phase4a_business_date|p_business_date/);
  });

  it("fails closed for unauthorized actors and invalid or expired generator leases", () => {
    assert.match(migration, /private\.actor_manages_active_organization/);
    assert.match(migration, /private\.is_internal_admin/);
    assert.match(migration, /job\.lease_token = p_lease_token/);
    assert.match(migration, /job\.state = 'running'/);
    assert.match(migration, /job\.lease_expires_at > pg_catalog\.statement_timestamp\(\)/);
    assert.match(migration, /using errcode = '42501'/);
    assert.doesNotMatch(migration, /grant execute[\s\S]*to authenticated/i);
    assert.doesNotMatch(migration, /grant execute[\s\S]*to anon/i);
  });

  it("keeps zero-eligible teams not applicable and blocks only new zero-eligible writes", () => {
    assert.match(migration, /count\(distinct staff\.id\) filter \(where coalesce\(duty\.duty_status, 'on_duty'\) = 'on_duty'\)::bigint/);
    assert.match(migration, /count\(distinct staff\.id\) filter \(where coalesce\(duty\.duty_status, 'on_duty'\) = 'on_duty'\) > 0/);
    assert.match(migration, /staff hygiene not applicable/);
    assert.match(migration, /historical submitted rows[\s\S]*remain readable/i);
    assert.match(reportSource, /hygieneRequired = hygieneApp\.required && eligibleTeamsCount > 0/);
    assert.match(reportSource, /expected_count: hygieneExpected/);
  });

  it("does not replace the protected table with a direct DBR read and preserves service-role-only execution", () => {
    assert.match(migration, /security definer/);
    assert.match(migration, /set search_path = ''/);
    assert.match(migration, /revoke all on function public\.get_daily_report_staff_hygiene_applicability/);
    assert.match(migration, /grant execute on function public\.get_daily_report_staff_hygiene_applicability[\s\S]*to service_role/);
  assert.match(reportSource, /getDailyReportStaffHygieneApplicability/);
  assert.match(appSource, /getManagerStaffHygieneApplicabilityRange/);
    assert.doesNotMatch(reportSource, /from\("branch_operational_teams"\)/);
  });

  it("adds a supervisor-scoped read contract without widening the Phase A RPC", () => {
    assert.match(contractMigration, /get_supervisor_staff_hygiene_applicability/);
    assert.match(contractMigration, /supervisor_team\.supervisor_user_id = p_actor_user_id/);
    assert.match(contractMigration, /private\.actor_can_read_operational_branch\(p_actor_user_id, p_branch_id\)/);
    assert.match(contractMigration, /supervisor_team\.branch_id = p_branch_id/);
    assert.match(contractMigration, /private\.phase4a_business_date/);
    assert.match(contractMigration, /daily_report_branch_lifecycle/);
    assert.match(contractMigration, /operational_team_id uuid/);
    assert.match(contractMigration, /'not_applicable'/);
    assert.match(contractMigration, /set search_path = ''/);
    assert.match(contractMigration, /revoke all on function public\.get_supervisor_staff_hygiene_applicability/);
    assert.match(contractMigration, /grant execute on function public\.get_supervisor_staff_hygiene_applicability[\s\S]*to service_role/);
    assert.doesNotMatch(contractMigration, /grant execute[\s\S]*to authenticated/i);
    assert.doesNotMatch(contractMigration, /grant execute[\s\S]*to anon/i);
  });

  it("exposes additive fail-closed Manager, Reports, and Supervisor routes", () => {
    assert.match(appSource, /supervisor\/branches\/:branchId\/staff-hygiene\/applicability/);
    assert.match(appSource, /organizations\/:organizationId\/staff-hygiene\/applicability/);
    assert.match(appSource, /organizations\/:organizationId\/reports\/applicability/);
    assert.match(appSource, /staffHygieneApplicabilityRowSchema/);
    assert.match(appSource, /applicability-range/);
    assert.match(appSource, /Date range exceeds 31 business dates/);
    assert.match(appSource, /managerStaffHygieneApplicabilityRangeResponseSchema/);
    assert.match(appSource, /getSupervisorStaffHygieneApplicability/);
    assert.doesNotMatch(appSource, /staffHygieneApplicabilityRead[\s\S]*getDailyReportStaffHygieneApplicability/);
    assert.match(appSource, /getManagerStaffHygieneApplicabilityRange/);
    assert.match(rangeMigration, /generate_series\(p_date_from, p_date_to/);
    assert.match(rangeMigration, /p_date_to - p_date_from >= 31/);
    assert.match(rangeMigration, /operational_team_id uuid/);
    assert.match(rangeMigration, /set search_path = ''/);
    assert.match(rangeMigration, /grant execute on function public\.get_manager_staff_hygiene_applicability_range[\s\S]*to service_role/);
  });
});
