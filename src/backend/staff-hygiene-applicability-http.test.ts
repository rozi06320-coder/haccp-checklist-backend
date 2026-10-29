import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendDependencies } from "./dependencies";
import type { BackendConfig } from "./config";
import { ChecklistAccessError } from "./checklist-persistence";
import type { UserContext, UserContextRepository } from "./user-context";

const org = "a2000000-0000-4000-8000-000000000001";
const otherOrg = "a2000000-0000-4000-8000-000000000002";
const branch = "a3000000-0000-4000-8000-000000000001";
const otherBranch = "a3000000-0000-4000-8000-000000000002";
const teamA = "a4000000-0000-4000-8000-000000000001";
const teamB = "a4000000-0000-4000-8000-000000000002";
const managerToken = "http-manager";
const supervisorAToken = "http-supervisor-a";
const supervisorBToken = "http-supervisor-b";
const unauthorizedToken = "http-unauthorized";

const users: Record<string, UserContext> = {
  [managerToken]: { id: "a1000000-0000-4000-8000-000000000003", full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }] },
  [supervisorAToken]: { id: "a1000000-0000-4000-8000-000000000001", full_name: "Supervisor A", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] },
  [supervisorBToken]: { id: "a1000000-0000-4000-8000-000000000002", full_name: "Supervisor B", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] },
  [unauthorizedToken]: { id: "a1000000-0000-4000-8000-000000000099", full_name: "Other", must_change_password: false, disabled: false, branches: [{ id: otherBranch, name: "Other", organization_id: otherOrg, role: "branch_manager" }], managed_organizations: [{ id: otherOrg, name: "Other", role: "organization_manager" }] },
};

const repo: UserContextRepository = {
  async getUserContext(userId) { return Object.values(users).find((user) => user.id === userId) ?? null; },
  async hasOrganizationManagerAccess(userId, organizationId) { return users[managerToken]?.id === userId && organizationId === org; },
  async validateActiveBranches() { return true; },
  async listActiveBranches() { return []; },
};

describe("Staff Hygiene applicability HTTP contracts", () => {
  let server: Server;
  let baseUrl: string;
  let failRange = false;

  before(async () => {
    const persistence = {
      async getSupervisorStaffHygieneApplicability(input: { actorUserId: string; branchId: string }) {
        if (input.branchId !== branch || ![users[supervisorAToken].id, users[supervisorBToken].id].includes(input.actorUserId)) throw new ChecklistAccessError();
        return [{ branch_id: branch, business_date: "2026-10-29", operational_team_id: input.actorUserId === users[supervisorAToken].id ? teamA : teamB, eligible_staff_count: input.actorUserId === users[supervisorAToken].id ? 0 : 1, required: input.actorUserId === users[supervisorBToken].id, applicability: input.actorUserId === users[supervisorBToken].id ? "required" as const : "not_applicable" as const }];
      },
      async getDailyReportStaffHygieneApplicability() { return []; },
      async getManagerStaffHygieneApplicabilityRange() {
        if (failRange) throw new Error("internal database details");
        return [
          { branch_id: branch, business_date: "2026-10-29", operational_team_id: teamA, eligible_staff_count: 0, required: false, applicability: "not_applicable" as const },
          { branch_id: otherBranch, business_date: "2026-10-29", operational_team_id: null, eligible_staff_count: 0, required: false, applicability: "not_applicable" as const },
        ];
      },
    };
    const config: BackendConfig = { port: 0, nodeEnv: "test", supabaseUrl: "https://example.supabase.co", supabaseAnonKey: "anon", supabaseServiceRoleKey: "service", supabasePublishableKey: "publishable" };
    const deps = {
      checklistPersistence: persistence,
      authVerifier: { async verify(token: string) { const user = users[token]; return user ? { userId: user.id, email: `${token}@example.invalid` } : null; } },
      createUserContext: () => repo,
      ready: async () => true,
    } as unknown as BackendDependencies;
    server = createServer(createApp(config, deps));
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(async () => { server.closeAllConnections(); await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve())); });

  const get = (path: string, token?: string) => fetch(`${baseUrl}${path}`, token ? { headers: { Authorization: `Bearer ${token}` } } : undefined);

  it("protects the Supervisor endpoint and returns team-scoped N/A/required", async () => {
    assert.equal((await get(`/api/v1/supervisor/branches/${branch}/staff-hygiene/applicability?business_date=2026-10-29`)).status, 401);
    assert.equal((await get(`/api/v1/supervisor/branches/${otherBranch}/staff-hygiene/applicability?business_date=2026-10-29`, supervisorAToken)).status, 403);
    const noTeam = await get(`/api/v1/supervisor/branches/${branch}/staff-hygiene/applicability?business_date=2026-10-29`, supervisorAToken);
    assert.equal(noTeam.status, 200); assert.equal((await noTeam.json() as any).teams[0].applicability, "not_applicable");
    const staffed = await get(`/api/v1/supervisor/branches/${branch}/staff-hygiene/applicability?business_date=2026-10-29`, supervisorBToken);
    const staffedJson = await staffed.json() as any; assert.equal(staffed.status, 200); assert.equal(staffedJson.teams[0].operational_team_id, teamB); assert.equal(staffedJson.teams[0].required, true);
  });

  it("protects Manager exact-date applicability and validates dates", async () => {
    assert.equal((await get(`/api/v1/management/organizations/${org}/staff-hygiene/applicability?business_date=bad`, managerToken)).status, 400);
    const ok = await get(`/api/v1/management/organizations/${org}/staff-hygiene/applicability?business_date=2026-10-29`, managerToken); assert.equal(ok.status, 200);
    const json = await ok.json() as any;
    assert.equal(json.organization_id, org);
    assert.equal(json.teams.some((row: any) => row.operational_team_id === null && row.applicability === "not_applicable"), true);
    assert.equal((await get(`/api/v1/management/organizations/${org}/staff-hygiene/applicability?business_date=2026-10-29`, unauthorizedToken)).status, 403);
  });

  it("enforces the bounded range contract and fails closed", async () => {
    const ok = await get(`/api/v1/management/organizations/${org}/reports/applicability-range?date_from=2026-10-29&date_to=2026-11-28`, managerToken); const json = await ok.json() as any;
    assert.equal(ok.status, 200); assert.equal(json.dates.length, 1); assert.equal(json.dates[0].teams.some((row: any) => row.operational_team_id === null), true);
    assert.equal((await get(`/api/v1/management/organizations/${org}/reports/applicability-range?date_from=2026-10-01&date_to=2026-11-01`, managerToken)).status, 400);
    assert.equal((await get(`/api/v1/management/organizations/${otherOrg}/reports/applicability-range?date_from=2026-10-29&date_to=2026-10-29`, unauthorizedToken)).status, 403);
    failRange = true; const failed = await get(`/api/v1/management/organizations/${org}/reports/applicability-range?date_from=2026-10-29&date_to=2026-10-29`, managerToken); assert.equal(failed.status, 503); assert.doesNotMatch(await failed.text(), /internal database details/);
  });
});
