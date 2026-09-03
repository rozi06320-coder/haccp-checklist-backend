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
  branch: "30000000-0000-4000-8000-000000000001",
  staff: "40000000-0000-4000-8000-000000000001",
  supervisor: "50000000-0000-4000-8000-000000000001",
  assignment: "60000000-0000-4000-8000-000000000001",
  team: "70000000-0000-4000-8000-000000000001",
  healthCard: "80000000-0000-4000-8000-000000000001",
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

const validDirectory = {
  people: [
    {
      person_type: "staff",
      person_id: ids.staff,
      display_name: "Kitchen Employee",
      display_name_ar: null,
      person_code: "BH-104",
      phone_number: null,
      email: "employee@example.invalid",
      country_code: "SA",
      iqama_number: null,
      iqama_expiry_date: null,
      branches: [{ id: ids.branch, name: "Al Takhassusi", name_ar: null, code: "TAK" }],
      status: "active",
      joined_at: "2026-08-01T08:00:00+00:00",
      new_until: "2026-09-01T08:00:00+00:00",
      is_new: false,
      staff_id: ids.staff,
      employment_status: "active",
      company_name: "Burger Hunch",
      supervisor_name: "Branch Supervisor",
      supervisor_name_ar: null,
      assignment_id: ids.assignment,
      operational_team_id: ids.team,
      operational_team_name: "Opening Team",
      operational_roles: ["kitchen"],
      duty_status: "on_duty",
      supervisor_training_status: null,
    },
    {
      person_type: "supervisor",
      person_id: ids.supervisor,
      display_name: "Branch Supervisor",
      display_name_ar: "مشرف الفرع",
      person_code: "SUP-12",
      phone_number: "+966500000000",
      email: "supervisor@example.invalid",
      country_code: "SA",
      iqama_number: null,
      iqama_expiry_date: null,
      branches: [{ id: ids.branch, name: "Al Takhassusi", name_ar: null, code: "TAK" }],
      status: "active",
      joined_at: "2026-07-01T08:00:00+00:00",
      new_until: "2026-08-01T08:00:00+00:00",
      is_new: false,
    },
  ],
  people_total: 2,
  people_limit: 1000,
  people_truncated: false,
  operational_teams: [{
    id: ids.team,
    branch_id: ids.branch,
    branch_name: "Al Takhassusi",
    branch_name_ar: null,
    name: "Opening Team",
    active: true,
  }],
  health_cards: [{
    id: ids.healthCard,
    operational_staff_id: ids.staff,
    display_name: "Kitchen Employee",
    branch_id: ids.branch,
    branch_name: "Al Takhassusi",
    branch_name_ar: null,
    certificate_number: "HC-104",
    status: "passed",
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
    branch_id: ids.branch,
    branch_name: "Al Takhassusi",
    branch_name_ar: null,
    evaluation_month: "2026-09-01",
    evaluator_name: "Manager",
    status: "completed",
    average_score: 4.5,
    scores: [{ section: "Hygiene", factor_key: "uniform", factor_label: "Uniform", rating: 5, comment: null }],
    updated_at: "2026-09-02T08:00:00+00:00",
  }],
} as const;

describe("Manager unified people directory API", () => {
  let rpcServer: Server;
  let apiServer: Server;
  let baseUrl = "";
  let rpcPayload: unknown = validDirectory;
  let rpcStatus = 200;
  const rpcRequests: Array<{ path: string; body: Record<string, unknown> }> = [];

  before(async () => {
    rpcServer = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;
      rpcRequests.push({ path: request.url ?? "", body: raw ? JSON.parse(raw) as Record<string, unknown> : {} });
      response.statusCode = rpcStatus;
      response.setHeader("content-type", "application/json");
      if (request.url === "/rest/v1/rpc/apply_due_operational_staff_team_moves") {
        response.end(JSON.stringify([]));
        return;
      }
      if (request.url === "/rest/v1/rpc/list_managed_employee_team") {
        response.end(JSON.stringify({ employees: [], operational_teams: [], health_cards: [], monthly_evaluations: [] }));
        return;
      }
      response.end(JSON.stringify(rpcPayload));
    });
    await new Promise<void>((resolve) => rpcServer.listen(0, "127.0.0.1", resolve));
    const rpcPort = (rpcServer.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${rpcPort}`, "service-role-test-key");
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    apiServer = createServer(createApp(config, dependencies(operationalAdmin)));
    await new Promise<void>((resolve) => apiServer.listen(0, "127.0.0.1", resolve));
    baseUrl = `http://127.0.0.1:${(apiServer.address() as AddressInfo).port}`;
  });

  after(async () => {
    apiServer.closeAllConnections();
    rpcServer.closeAllConnections();
    await new Promise<void>((resolve, reject) => apiServer.close((error) => error ? reject(error) : resolve()));
    await new Promise<void>((resolve, reject) => rpcServer.close((error) => error ? reject(error) : resolve()));
  });

  it("maps authenticated Manager filters to the new RPC and preserves both person variants and limits", async () => {
    rpcPayload = validDirectory;
    rpcStatus = 200;
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?branch_id=${ids.branch}&month=2026-09&search=%20Kitchen%20&code=%20BH-104%20`, { headers: authHeaders });
    assert.equal(response.status, 200, await response.clone().text());
    assert.equal(response.headers.get("cache-control"), "private, no-store");
    const body = await response.json() as typeof validDirectory;
    assert.deepEqual(body, validDirectory);
    assert.equal(body.people[0]?.person_type, "staff");
    assert.equal(body.people[1]?.person_type, "supervisor");
    assert.equal("staff_id" in body.people[1], false);
    assert.deepEqual({ total: body.people_total, limit: body.people_limit, truncated: body.people_truncated }, { total: 2, limit: 1000, truncated: false });
    assert.deepEqual(rpcRequests.at(-1), {
      path: "/rest/v1/rpc/list_managed_people_directory",
      body: {
        actor_user_id: ids.manager,
        target_organization_id: ids.organization,
        branch_filter: ids.branch,
        requested_month: "2026-09-01",
        search_term: "Kitchen",
        code_filter: "BH-104",
      },
    });
  });

  it("normalizes blank filters, defaults the optional month in Riyadh, and rejects client actor injection", async () => {
    rpcPayload = { ...validDirectory, people: [], people_total: 0, health_cards: [], monthly_evaluations: [] };
    rpcStatus = 200;
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?search=%20%20&code=%20`, { headers: authHeaders });
    assert.equal(response.status, 200, await response.clone().text());
    assert.deepEqual(rpcRequests.at(-1)?.body, {
      actor_user_id: ids.manager,
      target_organization_id: ids.organization,
      branch_filter: null,
      requested_month: `${currentRiyadhMonth()}-01`,
      search_term: null,
      code_filter: null,
    });
    const requestCount = rpcRequests.length;
    const injected = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?actor_user_id=${ids.supervisor}`, { headers: authHeaders });
    assert.equal(injected.status, 400);
    assert.equal(rpcRequests.length, requestCount);
  });

  it("accepts the live nullable Supervisor fields and two-letter country-code domain", async () => {
    rpcStatus = 200;
    rpcPayload = {
      ...validDirectory,
      people: [{ ...validDirectory.people[1], display_name: null, country_code: "ZZ" }],
      people_total: 1,
      monthly_evaluations: [{ ...validDirectory.monthly_evaluations[0], average_score: null }],
    };
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
    assert.equal(response.status, 200, await response.clone().text());
    const body = await response.json() as { people: Array<{ display_name: string | null; country_code: string | null }>; monthly_evaluations: Array<{ average_score: number | null }> };
    assert.deepEqual(body.people[0], { ...validDirectory.people[1], display_name: null, country_code: "ZZ" });
    assert.equal(body.monthly_evaluations[0]?.average_score, null);
  });

  it("rejects lowercase or malformed Supervisor country codes and string evaluation scores", async () => {
    rpcStatus = 200;
    for (const invalidCountryCode of ["zz", "Z1"]) {
      rpcPayload = {
        ...validDirectory,
        people: [{ ...validDirectory.people[1], country_code: invalidCountryCode }],
        people_total: 1,
      };
      const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
      assert.equal(response.status, 503, invalidCountryCode);
    }

    rpcPayload = {
      ...validDirectory,
      monthly_evaluations: [{ ...validDirectory.monthly_evaluations[0], average_score: "4.5" }],
    };
    const stringScore = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
    assert.equal(stringScore.status, 503);
    assert.match(await stringScore.text(), /People directory is temporarily unavailable/);
  });

  it("strictly rejects mixed person variants and malformed RPC result metadata with a generic 5xx", async () => {
    rpcStatus = 200;
    rpcPayload = {
      ...validDirectory,
      people: [{ ...validDirectory.people[1], staff_id: ids.staff }],
      people_total: 1,
    };
    const mixed = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
    assert.equal(mixed.status, 503);
    const mixedText = await mixed.text();
    assert.match(mixedText, /People directory is temporarily unavailable/);
    assert.doesNotMatch(mixedText, /staff_id|discriminator|Zod/);

    rpcPayload = { ...validDirectory, people_limit: 999 };
    const malformed = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
    assert.equal(malformed.status, 503);
  });

  it("does not leak raw database errors and retains the legacy employees endpoint and RPC", async () => {
    rpcStatus = 400;
    rpcPayload = { code: "P0001", message: "raw database table secret" };
    const unavailable = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
    assert.equal(unavailable.status, 503);
    const unavailableText = await unavailable.text();
    assert.match(unavailableText, /People directory is temporarily unavailable/);
    assert.doesNotMatch(unavailableText, /P0001|raw database|table secret|list_managed_people_directory/);

    rpcStatus = 200;
    const legacy = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/employees?month=2026-09`, { headers: authHeaders });
    assert.equal(legacy.status, 200, await legacy.clone().text());
    assert.deepEqual(await legacy.json(), { employees: [], operational_teams: [], health_cards: [], monthly_evaluations: [] });
    assert.equal(rpcRequests.at(-1)?.path, "/rest/v1/rpc/list_managed_employee_team");
  });

  it("maps the trusted 42501 contract to a generic 403 without leaking database details", async () => {
    rpcStatus = 400;
    rpcPayload = { code: "42501", message: "people directory access denied in list_managed_people_directory" };
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?month=2026-09`, { headers: authHeaders });
    assert.equal(response.status, 403);
    const text = await response.text();
    assert.match(text, /Access is denied/);
    assert.doesNotMatch(text, /42501|people directory access denied|list_managed_people_directory/);
  });

  it("rejects invalid branch, month, and bounded text filters before RPC execution", async () => {
    rpcPayload = validDirectory;
    rpcStatus = 200;
    for (const query of [
      "branch_id=not-a-uuid",
      "month=2026-13",
      `search=${"s".repeat(121)}`,
      `code=${"c".repeat(65)}`,
    ]) {
      const requestCount = rpcRequests.length;
      const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/people?${query}`, { headers: authHeaders });
      assert.equal(response.status, 400, query);
      assert.equal(rpcRequests.length, requestCount, query);
    }
  });
});

const authHeaders = { authorization: "Bearer manager" };

function currentRiyadhMonth() {
  const parts = new Intl.DateTimeFormat("en-US-u-ca-gregory", {
    calendar: "gregory",
    timeZone: "Asia/Riyadh",
    year: "numeric",
    month: "2-digit",
  }).formatToParts(new Date());
  const value = (type: string) => parts.find((part) => part.type === type)?.value;
  return `${value("year")}-${value("month")}`;
}

function dependencies(operationalAdmin: NonNullable<BackendDependencies["operationalAdmin"]>): BackendDependencies {
  return {
    authVerifier: {
      async verify(token) {
        return token === "manager" ? { userId: ids.manager, email: "manager@example.invalid" } : null;
      },
    },
    checkReadiness: async () => true,
    createUserContext: () => ({
      async getUserContext() { return managerContext; },
      async hasOrganizationManagerAccess() { return true; },
      async validateActiveBranches() { return true; },
      async listActiveBranches() { return []; },
    }),
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { return { id: ids.supervisor }; }, async deleteUser() {}, async finalize() {} },
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
