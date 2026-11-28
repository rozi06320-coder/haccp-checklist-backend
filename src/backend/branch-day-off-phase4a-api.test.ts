import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError, ChecklistOperationError } from "./checklist-persistence";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { UserContext } from "./user-context";

const ids = {
  supervisorPrimary: "10000000-0000-4000-8000-000000000001",
  supervisorBackup: "10000000-0000-4000-8000-000000000002",
  manager: "10000000-0000-4000-8000-000000000003",
  organization: "20000000-0000-4000-8000-000000000001",
  otherOrganization: "20000000-0000-4000-8000-000000000099",
  branchA: "30000000-0000-4000-8000-000000000001",
  branchB: "30000000-0000-4000-8000-000000000002",
  unassignedBranch: "30000000-0000-4000-8000-000000000099",
} as const;

function buildSupervisorOverviewPayload(options: { withDayOffFields?: boolean; isDayOff?: boolean; reason?: string | null } = {}) {
  const isDayOff = options.isDayOff ?? false;
  const checklists = [
    {
      checklist_type: "kitchen_opening",
      state: isDayOff ? "not_started" : "submitted",
      expected_checks: isDayOff ? 0 : 17,
      answered_checks: isDayOff ? 0 : 17,
      compliant_checks: isDayOff ? 0 : 17,
      issue_checks: 0,
      pending_checks: 0,
      completion_percentage: isDayOff ? null : 100,
      compliance_percentage: isDayOff ? null : 100,
    },
    { checklist_type: "foh_opening", state: "not_started", expected_checks: isDayOff ? 0 : 18, answered_checks: 0, compliant_checks: 0, issue_checks: 0, pending_checks: isDayOff ? 0 : 18, completion_percentage: isDayOff ? null : 0, compliance_percentage: null },
    { checklist_type: "staff_hygiene", state: "not_started", expected_checks: 0, answered_checks: 0, compliant_checks: 0, issue_checks: 0, pending_checks: 0, completion_percentage: null, compliance_percentage: null },
    { checklist_type: "oil_tracking", state: "not_started", expected_checks: isDayOff ? 0 : 2, answered_checks: 0, compliant_checks: 0, issue_checks: 0, pending_checks: isDayOff ? 0 : 2, completion_percentage: isDayOff ? null : 0, compliance_percentage: null },
    { checklist_type: "cold_storage", state: "not_started", expected_checks: 0, answered_checks: 0, compliant_checks: 0, issue_checks: 0, pending_checks: 0, completion_percentage: null, compliance_percentage: null },
  ];
  const totals = {
    expected_checks: checklists.reduce((s, r) => s + r.expected_checks, 0),
    answered_checks: checklists.reduce((s, r) => s + r.answered_checks, 0),
    compliant_checks: checklists.reduce((s, r) => s + r.compliant_checks, 0),
    issue_checks: 0,
    pending_checks: checklists.reduce((s, r) => s + r.pending_checks, 0),
    completion_percentage: isDayOff ? null : Math.round((17 * 100) / 37),
    compliance_percentage: isDayOff ? null : 100,
  };
  return {
    business_date: "2026-11-27",
    ...(options.withDayOffFields ? { is_day_off: isDayOff, day_off_reason: options.reason ?? null } : {}),
    totals,
    checklists,
  };
}

function buildManagerOverviewPayload(options: { withDayOffFields?: boolean; isDayOff?: boolean; reason?: string | null } = {}) {
  const isDayOff = options.isDayOff ?? false;
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
    "kitchen_opening",
    "foh_opening",
    "staff_hygiene",
    "oil_tracking",
    "cold_storage",
    "sales_tracking",
    "daily_audit",
  ].map((checklist_type) => ({
    checklist_type,
    team_states: { not_started: isDayOff ? 0 : 1, draft: 0, submitted: 0 },
    ...zeroCounts,
  }));
  return {
    organization: { id: ids.organization, name: "Test Org" },
    generated_at: "2026-11-27T10:00:00+03:00",
    date_context: "current_branch_local_business_day" as const,
    summary: {
      active_branch_count: 1,
      active_team_count: 1,
      active_supervisor_account_count: 1,
      active_operational_staff_count: 1,
    },
    totals: zeroCounts,
    local_dates: [{ business_date: "2026-11-27", branch_count: 1 }],
    branches: [
      {
        branch_id: ids.branchA,
        branch_name: "Al Takhassusi",
        branch_code: "TAK",
        timezone: "Asia/Riyadh",
        business_date: "2026-11-27",
        ...(options.withDayOffFields ? { is_day_off: isDayOff, day_off_reason: options.reason ?? null } : {}),
        status: "ready" as const,
        active_team_count: 1,
        totals: zeroCounts,
        checklists,
      },
    ],
  };
}

describe("Branch Day Off Phase 4A Backend Compatibility & Supervisor Status API", () => {
  let server: Server;
  let baseUrl = "";
  let supervisorOverviewPayload: unknown = buildSupervisorOverviewPayload();
  let managerOverviewPayload: unknown = buildManagerOverviewPayload();
  let dayOffStatusHandler: (input: { actorUserId: string; branchId: string }) => Promise<unknown> = async ({ branchId }) => ({
    branch_id: branchId,
    business_date: "2026-11-27",
    timezone: "Asia/Riyadh",
    is_day_off: true,
    day_off_reason: "Weekly Day Off",
  });

  const contexts: Record<string, UserContext> = {
    primary: {
      id: ids.supervisorPrimary,
      full_name: "Primary Supervisor",
      disabled: false,
      must_change_password: false,
      branches: [{ id: ids.branchA, name: "Al Takhassusi", code: "TAK", role: "branch_manager" }],
      managed_organizations: [],
    },
    backup: {
      id: ids.supervisorBackup,
      full_name: "Backup Supervisor",
      disabled: false,
      must_change_password: false,
      branches: [{ id: ids.branchA, name: "Al Takhassusi", code: "TAK", role: "branch_manager" }],
      managed_organizations: [],
    },
    manager: {
      id: ids.manager,
      full_name: "Manager",
      disabled: false,
      must_change_password: false,
      branches: [],
      managed_organizations: [{ id: ids.organization, name: "Test Org", role: "organization_manager" }],
    },
    mustChange: {
      id: ids.supervisorPrimary,
      full_name: "Primary Supervisor",
      disabled: false,
      must_change_password: true,
      branches: [{ id: ids.branchA, name: "Al Takhassusi", code: "TAK", role: "branch_manager" }],
      managed_organizations: [],
    },
  };

  before(async () => {
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    const deps: BackendDependencies = {
      authVerifier: {
        async verify(token) {
          if (token === "primary") return { userId: ids.supervisorPrimary, email: "primary@example.invalid" };
          if (token === "backup") return { userId: ids.supervisorBackup, email: "backup@example.invalid" };
          if (token === "manager") return { userId: ids.manager, email: "manager@example.invalid" };
          if (token === "mustChange") return { userId: ids.supervisorPrimary, email: "primary@example.invalid" };
          return null;
        },
      },
      checkReadiness: async () => true,
      createUserContext: () => ({
        async getUserContext(userId) {
          if (userId === ids.supervisorBackup) return contexts.backup;
          if (userId === ids.manager) return contexts.manager;
          return contexts.primary;
        },
        async hasOrganizationManagerAccess(_u, orgId) { return orgId === ids.organization; },
        async validateActiveBranches() { return true; },
        async listActiveBranches() { return []; },
      }),
      passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
      provisioningAdmin: { async createUser() { return { id: ids.supervisorPrimary }; }, async deleteUser() {}, async finalize() {} },
      managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
      branchManagementAdmin: {
        async listBranches() { return []; },
        async listStaff() { return []; },
        async getPinMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; },
        async storePin() { return { configured: false, updated_at: null, updated_by_name: null }; },
        async getPinCredential() { return null; },
      },
      pinCrypto: { async hash() { throw new Error("unused"); }, async verify() { return false; }, issueGrant() { return ""; }, verifyGrant() { return false; } },
      checklistPersistence: {
        async getOverview() { return supervisorOverviewPayload; },
        async getManagementOverview() { return managerOverviewPayload; },
        async getSupervisorBranchDayOffStatus(input) { return dayOffStatusHandler(input); },
        async getCurrentState() { throw new Error("unused"); },
        async saveDraft() { throw new Error("unused"); },
        async saveHygieneDraft() { throw new Error("unused"); },
        async submitOpening() { throw new Error("unused"); },
        async submitHygiene() { throw new Error("unused"); },
        async listReports() { throw new Error("unused"); },
        async getReport() { throw new Error("unused"); },
        async listIssues() { throw new Error("unused"); },
        async getIssue() { throw new Error("unused"); },
        async listManagedReports() { throw new Error("unused"); },
        async getManagedReport() { throw new Error("unused"); },
        async listManagedIssues() { throw new Error("unused"); },
        async getManagedIssue() { throw new Error("unused"); },
      },
    };
    server = createServer(createApp(config, deps));
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
  });

  it("accepts both old and new Day Off fields in Supervisor Overview and Manager Overview while rejecting malformed payloads", async () => {
    // Old DB responses without is_day_off / day_off_reason
    supervisorOverviewPayload = buildSupervisorOverviewPayload({ withDayOffFields: false });
    const supOld = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/overview`, { headers: { authorization: "Bearer primary" } });
    assert.equal(supOld.status, 200);

    managerOverviewPayload = buildManagerOverviewPayload({ withDayOffFields: false });
    const mgrOld = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/overview`, { headers: { authorization: "Bearer manager" } });
    assert.equal(mgrOld.status, 200);

    // New DB responses with is_day_off / day_off_reason
    supervisorOverviewPayload = buildSupervisorOverviewPayload({ withDayOffFields: true, isDayOff: true, reason: "Weekly Day Off" });
    const supNew = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/overview`, { headers: { authorization: "Bearer primary" } });
    assert.equal(supNew.status, 200);
    const supNewBody = await supNew.json() as { is_day_off: boolean; day_off_reason: string | null };
    assert.equal(supNewBody.is_day_off, true);
    assert.equal(supNewBody.day_off_reason, "Weekly Day Off");

    managerOverviewPayload = buildManagerOverviewPayload({ withDayOffFields: true, isDayOff: true, reason: "Holiday Closure" });
    const mgrNew = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/overview`, { headers: { authorization: "Bearer manager" } });
    assert.equal(mgrNew.status, 200);
    const mgrNewBody = await mgrNew.json() as { branches: Array<{ is_day_off: boolean; day_off_reason: string | null }> };
    assert.equal(mgrNewBody.branches[0]?.is_day_off, true);
    assert.equal(mgrNewBody.branches[0]?.day_off_reason, "Holiday Closure");

    // Malformed payloads must still be rejected with 503
    supervisorOverviewPayload = { ...buildSupervisorOverviewPayload({ withDayOffFields: true, isDayOff: true }), extra_unexpected: true };
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/overview`, { headers: { authorization: "Bearer primary" } })).status, 503);

    const malformedMgr = buildManagerOverviewPayload({ withDayOffFields: true, isDayOff: true });
    (malformedMgr.branches[0] as Record<string, unknown>).is_day_off = "yes";
    managerOverviewPayload = malformedMgr;
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/overview`, { headers: { authorization: "Bearer manager" } })).status, 503);
  });

  it("serves Supervisor Day Off status for primary and backup supervisors with Cache-Control: private, no-store", async () => {
    for (const token of ["primary", "backup"]) {
      const res = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/day-off`, {
        headers: { authorization: `Bearer ${token}` },
      });
      assert.equal(res.status, 200);
      assert.equal(res.headers.get("cache-control"), "private, no-store");
      assert.deepEqual(await res.json(), {
        branch_id: ids.branchA,
        business_date: "2026-11-27",
        timezone: "Asia/Riyadh",
        is_day_off: true,
        day_off_reason: "Weekly Day Off",
      });
    }
  });

  it("enforces auth, branch validation, access denial, and fail-closed RPC/response handling on Supervisor Day Off status", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/day-off`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/not-a-uuid/day-off`, { headers: { authorization: "Bearer primary" } })).status, 400);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/day-off?extra=1`, { headers: { authorization: "Bearer primary" } })).status, 400);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/day-off`, { headers: { authorization: "Bearer manager" } })).status, 403);

    dayOffStatusHandler = async () => { throw new ChecklistAccessError(); };
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.unassignedBranch}/day-off`, { headers: { authorization: "Bearer primary" } })).status, 403);

    dayOffStatusHandler = async () => { throw new ChecklistOperationError(); };
    const unavailableRes = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/day-off`, { headers: { authorization: "Bearer primary" } });
    assert.equal(unavailableRes.status, 503);
    assert.doesNotMatch(await unavailableRes.text(), /PGRST|42501|SQL/);

    // Branch mismatch or malformed payload must fail closed (503)
    dayOffStatusHandler = async () => ({
      branch_id: ids.branchB,
      business_date: "2026-11-27",
      timezone: "Asia/Riyadh",
      is_day_off: false,
      day_off_reason: null,
    });
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branchA}/day-off`, { headers: { authorization: "Bearer primary" } })).status, 503);
  });
});
