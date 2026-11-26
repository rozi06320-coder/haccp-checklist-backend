import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { createOperationalAdmin } from "./operational";
import type { UserContext } from "./user-context";

const ids = {
  manager: "10000000-0000-4000-8000-000000000001",
  organization: "20000000-0000-4000-8000-000000000001",
  otherOrganization: "20000000-0000-4000-8000-000000000099",
  branch1: "30000000-0000-4000-8000-000000000001",
  branch2: "30000000-0000-4000-8000-000000000002",
  staff: "40000000-0000-4000-8000-000000000001",
  supervisorPrimary: "50000000-0000-4000-8000-000000000001",
  supervisorUnsavedBackup: "50000000-0000-4000-8000-000000000002",
  assignment: "60000000-0000-4000-8000-000000000001",
  team1: "70000000-0000-4000-8000-000000000001",
  team2: "70000000-0000-4000-8000-000000000002",
  healthCard: "80000000-0000-4000-8000-000000000001",
  supervisorHealthCard: "80000000-0000-4000-8000-000000000002",
  evaluation: "90000000-0000-4000-8000-000000000001",
} as const;

const managerContext: UserContext = {
  id: ids.manager,
  full_name: "Manager",
  disabled: false,
  must_change_password: false,
  branches: [],
  managed_organizations: [{ id: ids.organization, name: "Organization", role: "organization_manager" }],
};

const baseDirectoryV2 = {
  people: [
    {
      person_type: "staff" as const,
      person_id: ids.staff,
      display_name: "Kitchen Employee",
      display_name_ar: null,
      person_code: "BH-104",
      phone_number: null,
      email: "employee@example.invalid",
      country_code: "SA",
      iqama_number: null,
      iqama_expiry_date: null,
      branches: [{ id: ids.branch1, name: "Al Takhassusi", name_ar: null, code: "TAK" }],
      status: "active" as const,
      joined_at: "2026-08-01T08:00:00+00:00",
      new_until: "2026-09-01T08:00:00+00:00",
      is_new: false,
      staff_id: ids.staff,
      employment_status: "active" as const,
      company_name: "Burger Hunch",
      supervisor_name: "Branch Supervisor",
      supervisor_name_ar: null,
      assignment_id: ids.assignment,
      operational_team_id: ids.team1,
      operational_team_name: "Opening Team",
      operational_roles: ["kitchen" as const],
      duty_status: "on_duty" as const,
      supervisor_training_status: null,
    },
    {
      person_type: "supervisor" as const,
      person_id: ids.supervisorPrimary,
      display_name: "Branch Supervisor",
      display_name_ar: "مشرف الفرع",
      person_code: "SUP-12",
      phone_number: "+966500000000",
      email: "supervisor@example.invalid",
      country_code: "SA",
      iqama_number: null,
      iqama_expiry_date: null,
      branches: [{ id: ids.branch1, name: "Al Takhassusi", name_ar: null, code: "TAK" }],
      status: "active" as const,
      joined_at: "2026-07-01T08:00:00+00:00",
      new_until: "2026-08-01T08:00:00+00:00",
      is_new: false,
      supervisor_role: "supervisor" as const,
    },
  ],
  people_total: 2,
  people_limit: 1000 as const,
  people_truncated: false,
  operational_teams: [{
    id: ids.team1,
    branch_id: ids.branch1,
    branch_name: "Al Takhassusi",
    branch_name_ar: null,
    name: "Opening Team",
    active: true,
  }],
  health_cards: [{
    id: ids.healthCard,
    operational_staff_id: ids.staff,
    display_name: "Kitchen Employee",
    branch_id: ids.branch1,
    branch_name: "Al Takhassusi",
    branch_name_ar: null,
    certificate_number: "HC-104",
    status: "passed" as const,
    place_of_issue: "Riyadh",
    expiry_date: "2027-08-01",
    date_issue: "2026-08-01",
    occupation: "Kitchen",
    company: "Burger Hunch",
    branch_name_snapshot: "Al Takhassusi",
    notes: null,
    updated_at: "2026-08-01T08:00:00+00:00",
  }],
  monthly_evaluations: [{
    id: ids.evaluation,
    operational_staff_id: ids.staff,
    display_name: "Kitchen Employee",
    branch_id: ids.branch1,
    branch_name: "Al Takhassusi",
    branch_name_ar: null,
    evaluation_month: "2026-09-01",
    evaluator_name: "Manager",
    status: "completed" as const,
    average_score: 4.5,
    scores: [{
      section: "Hygiene",
      factor_key: "uniform",
      factor_label: "Uniform",
      rating: 5,
      comment: null,
    }],
    updated_at: "2026-09-02T08:00:00+00:00",
  }],
};

const directoryV3WithSupervisors = {
  ...baseDirectoryV2,
  supervisor_health_cards: [
    {
      id: ids.supervisorHealthCard,
      supervisor_user_id: ids.supervisorPrimary,
      display_name: "Branch Supervisor",
      display_name_ar: "مشرف الفرع",
      person_code: "SUP-12",
      assignment_role: "primary" as const,
      branch_id: ids.branch1,
      branch_name: "Al Takhassusi, Olaya",
      branch_name_ar: "التخصصي، العليا",
      branches: [
        { id: ids.branch1, name: "Al Takhassusi", name_ar: "التخصصي" },
        { id: ids.branch2, name: "Olaya", name_ar: "العليا" },
      ],
      operational_team_ids: [ids.team1, ids.team2],
      team_assignment_roles: {
        [ids.team1]: "primary" as const,
        [ids.team2]: "backup" as const,
      },
      certificate_number: "SHC-001",
      status: "passed" as const,
      place_of_issue: "Riyadh",
      expiry_date: "2027-10-01",
      date_issue: "2026-10-01",
      occupation: "Supervisor",
      company: "Burger Hunch",
      branch_name_snapshot: "Al Takhassusi",
      notes: "Verified",
      updated_at: "2026-10-01T08:00:00+00:00",
    },
    {
      id: null,
      supervisor_user_id: ids.supervisorUnsavedBackup,
      display_name: "Backup Supervisor",
      display_name_ar: null,
      person_code: null,
      assignment_role: "backup" as const,
      branch_id: ids.branch2,
      branch_name: "Olaya",
      branch_name_ar: null,
      branches: [
        { id: ids.branch2, name: "Olaya", name_ar: null },
      ],
      operational_team_ids: [ids.team2],
      team_assignment_roles: {
        [ids.team2]: "backup" as const,
      },
      certificate_number: null,
      status: "not_done" as const,
      place_of_issue: null,
      expiry_date: null,
      date_issue: null,
      occupation: null,
      company: null,
      branch_name_snapshot: null,
      notes: null,
      updated_at: null,
    },
  ],
};

const authHeaders = { authorization: "Bearer manager" };

function buildDependencies(operationalAdmin: NonNullable<BackendDependencies["operationalAdmin"]>): BackendDependencies {
  return {
    authVerifier: {
      async verify(token) {
        return token === "manager" ? { userId: ids.manager, email: "manager@example.invalid" } : null;
      },
    },
    checkReadiness: async () => true,
    createUserContext: () => ({
      async getUserContext() { return managerContext; },
      async hasOrganizationManagerAccess(_u, organizationId) { return organizationId === ids.organization; },
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
    pinCrypto: {
      async hash() { throw new Error("unused"); },
      async verify() { return false; },
      issueGrant() { return ""; },
      verifyGrant() { return false; },
    },
    operationalAdmin,
  };
}

describe("Manager Supervisor Health Cards API (Phase 2)", () => {
  let rpcServer: Server;
  let apiServer: Server;
  let baseUrl: string;
  let rpcStatus = 200;
  let rpcPayload: unknown = baseDirectoryV2;
  const rpcRequests: Array<{ path: string; body: unknown }> = [];

  before(async () => {
    rpcServer = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        rpcRequests.push({
          path: req.url ?? "",
          body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
        });
        res.writeHead(rpcStatus, { "content-type": "application/json" });
        res.end(JSON.stringify(rpcPayload));
      });
    });
    await new Promise<void>((resolve) => rpcServer.listen(0, "127.0.0.1", () => resolve()));
    const rpcUrl = `http://127.0.0.1:${(rpcServer.address() as AddressInfo).port}`;
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    const operationalAdmin = createOperationalAdmin(rpcUrl, "service-role-test-key");
    apiServer = createServer(createApp(config, buildDependencies(operationalAdmin)));
    await new Promise<void>((resolve) => apiServer.listen(0, "127.0.0.1", () => resolve()));
    baseUrl = `http://127.0.0.1:${(apiServer.address() as AddressInfo).port}`;
  });

  after(async () => {
    apiServer.closeAllConnections();
    rpcServer.closeAllConnections();
    await new Promise<void>((resolve, reject) => apiServer.close((error) => error ? reject(error) : resolve()));
    await new Promise<void>((resolve, reject) => rpcServer.close((error) => error ? reject(error) : resolve()));
  });

  it("preserves legacy v2 response contract when opt-in query parameter is omitted or false", async () => {
    rpcStatus = 200;
    rpcPayload = baseDirectoryV2;

    const legacyRes = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
    assert.equal(legacyRes.status, 200, await legacyRes.clone().text());
    const legacyBody = await legacyRes.json() as Record<string, unknown>;
    assert.deepEqual(legacyBody, baseDirectoryV2);
    assert.equal("supervisor_health_cards" in legacyBody, false);
    assert.equal(rpcRequests.at(-1)?.path, "/rest/v1/rpc/list_managed_people_directory_v2");

    const explicitFalseRes = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09&include_supervisor_health_cards=false`, { headers: authHeaders });
    assert.equal(explicitFalseRes.status, 200, await explicitFalseRes.clone().text());
    const explicitFalseBody = await explicitFalseRes.json() as Record<string, unknown>;
    assert.deepEqual(explicitFalseBody, baseDirectoryV2);
    assert.equal("supervisor_health_cards" in explicitFalseBody, false);
    assert.equal(rpcRequests.at(-1)?.path, "/rest/v1/rpc/list_managed_people_directory_v2");
  });

  it("calls v3 RPC and returns supervisor_health_cards with nullable fields, primary/backup roles, deduplicated multi-branch data, and unchanged employee health_cards & counters when opted in", async () => {
    rpcStatus = 200;
    rpcPayload = directoryV3WithSupervisors;

    const response = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09&include_supervisor_health_cards=true`,
      { headers: authHeaders },
    );
    assert.equal(response.status, 200, await response.clone().text());
    assert.equal(response.headers.get("cache-control"), "private, no-store");
    const body = await response.json() as typeof directoryV3WithSupervisors;

    assert.equal(rpcRequests.at(-1)?.path, "/rest/v1/rpc/list_managed_people_directory_v3");
    assert.deepEqual(body.health_cards, baseDirectoryV2.health_cards);
    assert.equal(body.people_total, baseDirectoryV2.people_total);
    assert.equal(body.people_limit, baseDirectoryV2.people_limit);
    assert.equal(body.people_truncated, baseDirectoryV2.people_truncated);
    assert.equal(body.supervisor_health_cards.length, 2);

    const primary = body.supervisor_health_cards[0];
    assert.equal(primary?.assignment_role, "primary");
    assert.equal(primary?.branches.length, 2);
    assert.deepEqual(primary?.operational_team_ids, [ids.team1, ids.team2]);
    assert.deepEqual(primary?.team_assignment_roles, { [ids.team1]: "primary", [ids.team2]: "backup" });

    const unsavedBackup = body.supervisor_health_cards[1];
    assert.equal(unsavedBackup?.id, null);
    assert.equal(unsavedBackup?.status, "not_done");
    assert.equal(unsavedBackup?.assignment_role, "backup");
    assert.equal(unsavedBackup?.expiry_date, null);
    assert.equal(unsavedBackup?.date_issue, null);
    assert.equal(unsavedBackup?.certificate_number, null);
    assert.equal(unsavedBackup?.updated_at, null);
  });

  it("forwards branch_id filter accurately to v3 RPC", async () => {
    rpcStatus = 200;
    rpcPayload = {
      ...directoryV3WithSupervisors,
      supervisor_health_cards: [directoryV3WithSupervisors.supervisor_health_cards[1]],
    };

    const response = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.organization}/people?branch_id=${ids.branch2}&month=2026-09&include_supervisor_health_cards=true`,
      { headers: authHeaders },
    );
    assert.equal(response.status, 200, await response.clone().text());
    assert.deepEqual(rpcRequests.at(-1), {
      path: "/rest/v1/rpc/list_managed_people_directory_v3",
      body: {
        actor_user_id: ids.manager,
        target_organization_id: ids.organization,
        branch_filter: ids.branch2,
        requested_month: "2026-09-01",
        search_term: null,
        code_filter: null,
      },
    });
    const body = await response.json() as typeof directoryV3WithSupervisors;
    assert.equal(body.supervisor_health_cards.length, 1);
    assert.equal(body.supervisor_health_cards[0]?.supervisor_user_id, ids.supervisorUnsavedBackup);
  });

  it("rejects unauthorized, cross-organization, and invalid query requests and keeps manager write access unavailable", async () => {
    const requestCountBefore = rpcRequests.length;

    const unauth = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?include_supervisor_health_cards=true`);
    assert.equal(unauth.status, 401);

    const crossOrg = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.otherOrganization}/people?include_supervisor_health_cards=true`,
      { headers: authHeaders },
    );
    assert.equal(crossOrg.status, 403);

    const badOptIn = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.organization}/people?include_supervisor_health_cards=yes`,
      { headers: authHeaders },
    );
    assert.equal(badOptIn.status, 400);

    const writePeoplePost = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.organization}/people`,
      { method: "POST", headers: authHeaders },
    );
    assert.ok(writePeoplePost.status === 404 || writePeoplePost.status === 405);

    const writeSupervisorCardPut = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards/${ids.supervisorPrimary}`,
      {
        method: "PUT",
        headers: { ...authHeaders, "content-type": "application/json" },
        body: JSON.stringify({ status: "passed" }),
      },
    );
    assert.equal(writeSupervisorCardPut.status, 403);

    assert.equal(rpcRequests.length, requestCountBefore);
  });

  it("surfaces RPC 42501 as 403 and v3 failures/malformed payloads as 503 without silently falling back to v2", async () => {
    rpcStatus = 403;
    rpcPayload = { code: "42501", message: "people directory access denied" };
    const denied = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.organization}/people?include_supervisor_health_cards=true`,
      { headers: authHeaders },
    );
    assert.equal(denied.status, 403);
    assert.equal(rpcRequests.at(-1)?.path, "/rest/v1/rpc/list_managed_people_directory_v3");

    rpcStatus = 500;
    rpcPayload = { code: "P0001", message: "internal v3 failure" };
    const failed = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.organization}/people?include_supervisor_health_cards=true`,
      { headers: authHeaders },
    );
    assert.equal(failed.status, 503);
    assert.equal(rpcRequests.at(-1)?.path, "/rest/v1/rpc/list_managed_people_directory_v3");

    // Malformed v3 payload missing supervisor_health_cards must fail closed (503), not silently succeed
    rpcStatus = 200;
    rpcPayload = baseDirectoryV2;
    const missingField = await fetch(
      `${baseUrl}/api/v1/management/organizations/${ids.organization}/people?include_supervisor_health_cards=true`,
      { headers: authHeaders },
    );
    assert.equal(missingField.status, 503);
    assert.equal(rpcRequests.at(-1)?.path, "/rest/v1/rpc/list_managed_people_directory_v3");
  });
});
