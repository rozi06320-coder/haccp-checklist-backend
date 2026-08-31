import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { MAX_BEARER_TOKEN_LENGTH } from "./auth";
import { loadBackendConfig, type BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type {
  UserContext,
  UserContextRepository,
} from "./user-context";

const ids = {
  staff: "10000000-0000-4000-8000-000000000001",
  branchManager: "10000000-0000-4000-8000-000000000002",
  managerA: "10000000-0000-4000-8000-000000000003",
  disabled: "10000000-0000-4000-8000-000000000004",
  missing: "10000000-0000-4000-8000-000000000005",
  queryFailure: "10000000-0000-4000-8000-000000000006",
  organizationA: "20000000-0000-4000-8000-000000000001",
  organizationB: "20000000-0000-4000-8000-000000000002",
  branchA: "30000000-0000-4000-8000-000000000001",
  branchB: "30000000-0000-4000-8000-000000000002",
} as const;

const contexts: Record<string, UserContext> = {
  "staff-token": {
    id: ids.staff,
    full_name: "Staff User",
    must_change_password: false,
    disabled: false,
    branches: [
      {
        id: ids.branchA,
        name: "Assigned Branch",
        organization_id: ids.organizationA,
        role: "staff",
      },
    ],
    managed_organizations: [],
  },
  "branch-manager-token": {
    id: ids.branchManager,
    full_name: "Branch Manager",
    must_change_password: true,
    disabled: false,
    branches: [
      {
        id: ids.branchA,
        name: "Assigned Branch A",
        organization_id: ids.organizationA,
        role: "branch_manager",
      },
      {
        id: ids.branchB,
        name: "Assigned Branch B",
        organization_id: ids.organizationB,
        role: "branch_manager",
      },
    ],
    managed_organizations: [],
  },
  "manager-a-token": {
    id: ids.managerA,
    full_name: "Organization Manager A",
    must_change_password: false,
    disabled: false,
    branches: [],
    managed_organizations: [
      {
        id: ids.organizationA,
        name: "Organization A",
        role: "organization_manager",
      },
    ],
  },
  "disabled-token": {
    id: ids.disabled,
    full_name: "Disabled User",
    must_change_password: false,
    disabled: true,
    branches: [],
    managed_organizations: [],
  },
};

const tokenUsers: Record<string, string> = {
  "staff-token": ids.staff,
  "branch-manager-token": ids.branchManager,
  "manager-a-token": ids.managerA,
  "disabled-token": ids.disabled,
  "missing-profile-token": ids.missing,
  "query-failure-token": ids.queryFailure,
};

function repositoryFor(token: string): UserContextRepository {
  return {
    async getUserContext() {
      if (token === "query-failure-token") {
        throw new Error("RAW_MOCK_DATABASE_PASSWORD_SECRET");
      }
      return contexts[token] ?? null;
    },
    async hasOrganizationManagerAccess(_userId, organizationId) {
      if (token === "query-failure-token") {
        throw new Error("RAW_MOCK_POSTGRES_SECRET");
      }
      return (
        token === "manager-a-token" && organizationId === ids.organizationA
      );
    },
    async validateActiveBranches(organizationId, branchIds) {
      return (
        organizationId === ids.organizationA &&
        branchIds.every((id) => id === ids.branchA)
      );
    },
    async listActiveBranches(organizationId) {
      return organizationId === ids.organizationA
        ? [{ id: ids.branchA, name: "Branch A", code: "A" }]
        : [];
    },
  };
}

function dependencies(
  readiness: () => Promise<boolean> = async () => true,
): BackendDependencies {
  return {
    passwordChange: {
      async verifyCurrent() { return true; },
      async updatePassword() {},
      async finalize() {},
    },
    provisioningAdmin: {
      async createUser() {
        return { id: "40000000-0000-4000-8000-000000000001" };
      },
      async deleteUser() {},
      async finalize() {},
    },
    managementAdmin: {
      async listUsers() {
        return { users: [], total: 0 };
      },
    },
    branchManagementAdmin: {
      async listBranches() { return []; }, async listStaff() { return []; },
      async getPinMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async storePin() { return { configured: true, updated_at: null, updated_by_name: null }; },
      async getPinCredential() { return null; },
    },
    pinCrypto: {
      async hash() { throw new Error("unused"); }, async verify() { return false; },
      issueGrant() { return "unused"; }, verifyGrant() { return false; },
    },
    operationalAdmin: {
      async getBranchTimezone() { return "Asia/Riyadh"; },
      async getSupervisorTeam() { return { team: null }; },
      async createStaff() { return {}; },
      async updateStaff() { return {}; },
      async setDuty() { return {}; },
      async listHealthCards() { return { health_cards: [] }; },
      async upsertHealthCard() { return {}; },
      async listMonthlyEvaluations() { return { evaluations: [] }; },
      async saveMonthlyEvaluation() { return {}; },
      async listPurchaseLogs() { return { purchase_logs: [] }; },
      async createPurchaseLog() { return {}; },
      async updatePurchaseLogPaymentStatus() { return {}; },
      async listSupplierReceivings() { return { supplier_receivings: [] }; },
      async listBranchSuppliers() { return { suppliers: [] }; },
      async createBranchSupplier() { return {}; },
      async createSupplierReceiving() { return {}; },
      async listSupervisorMaintenanceIssues() { return { maintenance_issues: [] }; },
      async createSupervisorMaintenanceIssue() { return {}; },
      async listMaintenanceIssues() { return { maintenance_issues: [] }; },
      async updateMaintenanceIssue() { return {}; },
      async listMaintenancePurchases() { return { maintenance_purchases: [] }; },
      async createMaintenancePurchase() { return {}; },
      async reimburseMaintenancePurchase() { return {}; },
      async listManagedStaff() { return { staff: [], total: 0 }; },
      async listManagedEmployeeTeam() { return { employees: [], health_cards: [], monthly_evaluations: [] }; },
      async listManagedTeams() { return { teams: [] }; },
      async listEligibleSupervisors() { return { supervisors: [] }; },
    },
    authVerifier: {
      async verify(token) {
        if (token === "throwing-invalid-token") {
          throw new Error("RAW_MOCK_AUTH_TOKEN_SECRET");
        }
        const userId = tokenUsers[token];
        return userId
          ? { userId, email: `${userId}@example.invalid` }
          : null;
      },
    },
    checkReadiness: readiness,
    createUserContext: repositoryFor,
  };
}

const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});

async function listen(
  injectedDependencies: BackendDependencies = dependencies(),
  appConfig: BackendConfig = config,
): Promise<{ baseUrl: string; server: Server }> {
  const server = createServer(createApp(appConfig, injectedDependencies));
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address() as AddressInfo;
  return { baseUrl: `http://127.0.0.1:${address.port}`, server };
}

async function close(server: Server) {
  await new Promise<void>((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
}

async function json(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

function auth(token: string) {
  return { Authorization: `Bearer ${token}` };
}

function assertSanitized(text: string) {
  assert.doesNotMatch(
    text,
    /staff-token|manager-a-token|secret|RAW_MOCK|postgres|stack/i,
  );
  assert.doesNotMatch(text, /"password"\s*:/i);
}

describe("Express Phase 2D API", () => {
  let baseUrl: string;
  let server: Server;

  before(async () => {
    ({ baseUrl, server } = await listen());
  });

  after(async () => close(server));

  describe("health and hardening", () => {
    it("returns minimal process liveness without dependency or auth", async () => {
      const response = await fetch(`${baseUrl}/health/live`);
      assert.equal(response.status, 200);
      assert.deepEqual(await json(response), { status: "live" });
      assert.equal(response.headers.get("cache-control"), "no-store");
    });

    it("returns generic successful readiness", async () => {
      const response = await fetch(`${baseUrl}/health/ready`);
      assert.equal(response.status, 200);
      assert.deepEqual(await json(response), { status: "ready" });
    });

    it("returns generic unavailable readiness on false or thrown dependency", async () => {
      for (const check of [
        async () => false,
        async () => {
          throw new Error("RAW_MOCK_SUPABASE_SECRET");
        },
      ]) {
        const isolated = await listen(dependencies(check));
        const response = await fetch(`${isolated.baseUrl}/health/ready`);
        const text = await response.text();
        assert.equal(response.status, 503);
        assert.deepEqual(JSON.parse(text), { status: "unavailable" });
        assertSanitized(text);
        await close(isolated.server);
      }
    });

    it("returns generic JSON 404 for unknown routes", async () => {
      const response = await fetch(`${baseUrl}/unknown`);
      const body = await json(response);
      assert.equal(response.status, 404);
      assert.equal((body.error as { code: string }).code, "not_found");
      assertSanitized(JSON.stringify(body));
    });

    it("returns generic 400 for malformed JSON", async () => {
      const response = await fetch(`${baseUrl}/unknown`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: '{"broken":',
      });
      const body = await json(response);
      assert.equal(response.status, 400);
      assert.equal((body.error as { code: string }).code, "invalid_json");
      assertSanitized(JSON.stringify(body));
    });

    it("returns generic 413 for JSON over 100 KB", async () => {
      const response = await fetch(`${baseUrl}/unknown`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ value: "x".repeat(101 * 1024) }),
      });
      const body = await json(response);
      assert.equal(response.status, 413);
      assert.equal((body.error as { code: string }).code, "payload_too_large");
      assertSanitized(JSON.stringify(body));
    });

    it("sets security headers and a bounded generated request ID", async () => {
      const response = await fetch(`${baseUrl}/health/live`, {
        headers: { "X-Request-Id": "attacker-controlled-request-id".repeat(20) },
      });
      const requestId = response.headers.get("x-request-id") ?? "";
      assert.equal(response.headers.get("x-powered-by"), null);
      assert.equal(response.headers.get("x-content-type-options"), "nosniff");
      assert.match(requestId, /^[0-9a-f]{8}-[0-9a-f-]{27}$/);
      assert.equal(requestId.length, 36);
      assert.doesNotMatch(requestId, /attacker/);
    });

    it("logs temporary API route-rate diagnostics without sensitive request data", async () => {
      const productionConfig: BackendConfig = { ...config, nodeEnv: "production" };
      let userContextCalls = 0;
      const diagnosticDependencies = dependencies();
      diagnosticDependencies.createUserContext = (token) => {
        const repository = repositoryFor(token);
        return {
          ...repository,
          async getUserContext(userId) {
            userContextCalls += 1;
            return repository.getUserContext(userId);
          },
        };
      };
      const isolated = await listen(diagnosticDependencies, productionConfig);
      const originalInfo = console.info;
      const originalReleaseSha = process.env.RELEASE_SHA;
      const records: unknown[][] = [];
      console.info = (...args: unknown[]) => {
        records.push(args);
      };
      process.env.RELEASE_SHA = "diagnostic-test-sha";

      try {
        const success = await fetch(`${isolated.baseUrl}/health/live`, {
          headers: {
            Authorization: "Bearer successful-sensitive-token",
            Cookie: "sb-project-auth-token=sensitive-cookie",
          },
        });
        assert.equal(success.status, 200);
        await success.text();
        assert.equal(userContextCalls, 0);

        const matched = await fetch(
          `${isolated.baseUrl}/api/v1/management/organizations/${ids.organizationA}/overview?branch_id=${ids.branchA}`,
          {
            headers: {
              Authorization: "Bearer manager-a-token",
              Cookie: "matched-sensitive-cookie",
            },
          },
        );
        await matched.text();

        const failed = await fetch(
          `${isolated.baseUrl}/api/v1/not-found?access_token=query-sensitive-token`,
          {
            method: "POST",
            headers: {
              Authorization: "Bearer failed-sensitive-token",
              Cookie: "session=sensitive-cookie",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              email: "private@example.invalid",
              password: "secret-password",
              token: "body-sensitive-token",
              supabaseKey: "body-sensitive-supabase-key",
            }),
          },
        );
        assert.equal(failed.status, 404);
        await failed.text();
      } finally {
        console.info = originalInfo;
        if (originalReleaseSha === undefined) delete process.env.RELEASE_SHA;
        else process.env.RELEASE_SHA = originalReleaseSha;
        await close(isolated.server);
      }

      const requestRateRecords = records.filter(
        (record) =>
          typeof record[0] === "string" &&
          record[0].startsWith("API_ROUTE_RATE_DIAGNOSTIC "),
      );
      assert.equal(requestRateRecords.length, 3);

      const parseDiagnostic = (record: unknown[]) => {
        assert.equal(record.length, 1);
        const line = record[0];
        assert.equal(typeof line, "string");
        return JSON.parse(
          line.slice("API_ROUTE_RATE_DIAGNOSTIC ".length),
        ) as Record<string, unknown>;
      };

      const successDetails = parseDiagnostic(requestRateRecords[0] ?? []);
      assert.deepEqual(
        Object.keys(successDetails).sort(),
        ["durationMs", "method", "releaseSha", "requestId", "route", "status", "timestamp"],
      );
      assert.equal(successDetails.method, "GET");
      assert.equal(successDetails.route, "/health/live");
      assert.equal(successDetails.status, 200);
      assert.equal(successDetails.releaseSha, "diagnostic-test-sha");
      assert.match(
        successDetails.requestId as string,
        /^[0-9a-f]{8}-[0-9a-f-]{27}$/,
      );
      assert.equal(
        Number.isNaN(Date.parse(successDetails.timestamp as string)),
        false,
      );
      assert.equal(typeof successDetails.durationMs, "number");

      const matchedDetails = parseDiagnostic(requestRateRecords[1] ?? []);
      assert.equal(matchedDetails.method, "GET");
      assert.equal(matchedDetails.route, "/api/v1/management/organizations/:organizationId/overview");
      assert.notEqual(matchedDetails.route, `/api/v1/management/organizations/${ids.organizationA}/overview`);
      assert.equal(typeof matchedDetails.status, "number");

      const failedDetails = parseDiagnostic(requestRateRecords[2] ?? []);
      assert.equal(failedDetails.method, "POST");
      assert.equal(failedDetails.route, "/api/*");
      assert.equal(failedDetails.status, 404);

      const serialized = JSON.stringify(requestRateRecords);
      assert.doesNotMatch(
        serialized,
        /successful-sensitive-token|manager-a-token|failed-sensitive-token|sensitive-cookie|query-sensitive-token|private@example\.invalid|secret-password|body-sensitive-token|body-sensitive-supabase-key/i,
      );
      assert.doesNotMatch(serialized, /Authorization|Cookie|password|email|token|supabaseKey|branch_id/i);
    });

    it("does not trust spoofed forwarded IPs and keeps liveness live", async () => {
      const isolated = await listen();
      let response = new Response();
      for (let request = 0; request <= 100; request += 1) {
        response = await fetch(`${isolated.baseUrl}/api/v1/me`, {
          headers: {
            "X-Forwarded-For": `198.51.100.${(request % 200) + 1}`,
          },
        });
      }
      const text = await response.text();
      assert.equal(response.status, 429);
      assert.equal(JSON.parse(text).error.code, "rate_limited");
      assertSanitized(text);

      const live = await fetch(`${isolated.baseUrl}/health/live`);
      assert.equal(live.status, 200);
      assert.deepEqual(await json(live), { status: "live" });
      await close(isolated.server);
    });
  });

  describe("authentication", () => {
    const rejectedAuthorization: Array<[string, string | undefined]> = [
      ["missing", undefined],
      ["malformed", "Basic abc"],
      ["empty", "Bearer "],
      ["oversized", `Bearer ${"x".repeat(MAX_BEARER_TOKEN_LENGTH + 1)}`],
      ["invalid", "Bearer invalid-token"],
      ["throwing invalid", "Bearer throwing-invalid-token"],
    ];

    for (const [name, authorization] of rejectedAuthorization) {
      it(`returns generic 401 for ${name} authorization`, async () => {
        const response = await fetch(`${baseUrl}/api/v1/me`, {
          headers: authorization ? { Authorization: authorization } : {},
        });
        const text = await response.text();
        assert.equal(response.status, 401);
        assert.equal(JSON.parse(text).error.code, "unauthorized");
        assertSanitized(text);
      });
    }
  });

  describe("GET /api/v1/me", () => {
    it("returns only the allowed verified user context fields", async () => {
      const response = await fetch(`${baseUrl}/api/v1/me`, {
        headers: auth("staff-token"),
      });
      const body = await json(response);
      assert.equal(response.status, 200);
      assert.deepEqual(Object.keys(body).sort(), [
        "branches",
        "disabled",
        "full_name",
        "id",
        "managed_organizations",
        "must_change_password",
      ]);
      assert.equal(body.id, ids.staff);
      assert.equal(body.full_name, "Staff User");
      assert.equal(body.disabled, false);
      assertSanitized(JSON.stringify(body));
    });

    it("denies a disabled user", async () => {
      const response = await fetch(`${baseUrl}/api/v1/me`, {
        headers: auth("disabled-token"),
      });
      const text = await response.text();
      assert.equal(response.status, 403);
      assert.equal(JSON.parse(text).error.code, "forbidden");
      assertSanitized(text);
    });

    it("fails closed for a missing profile", async () => {
      const response = await fetch(`${baseUrl}/api/v1/me`, {
        headers: auth("missing-profile-token"),
      });
      const text = await response.text();
      assert.equal(response.status, 403);
      assert.equal(JSON.parse(text).error.code, "forbidden");
      assertSanitized(text);
    });

    it("fails closed and redacts membership query failures", async () => {
      const response = await fetch(`${baseUrl}/api/v1/me`, {
        headers: auth("query-failure-token"),
      });
      const text = await response.text();
      assert.equal(response.status, 503);
      assert.equal(JSON.parse(text).error.code, "service_unavailable");
      assertSanitized(text);
    });

    it("staff sees only its assigned branch", async () => {
      const response = await fetch(`${baseUrl}/api/v1/me`, {
        headers: auth("staff-token"),
      });
      const body = await json(response);
      assert.deepEqual(body.branches, contexts["staff-token"].branches);
      assert.deepEqual(body.managed_organizations, []);
      assert.doesNotMatch(JSON.stringify(body), /Assigned Branch B/);
    });

    it("branch manager sees only its assigned branches", async () => {
      const response = await fetch(`${baseUrl}/api/v1/me`, {
        headers: auth("branch-manager-token"),
      });
      const body = await json(response);
      assert.deepEqual(
        body.branches,
        contexts["branch-manager-token"].branches,
      );
      assert.deepEqual(body.managed_organizations, []);
      assert.equal((body.branches as unknown[]).length, 2);
    });

    it("organization manager sees only its managed organization", async () => {
      const response = await fetch(`${baseUrl}/api/v1/me`, {
        headers: auth("manager-a-token"),
      });
      const body = await json(response);
      assert.deepEqual(body.branches, []);
      assert.deepEqual(
        body.managed_organizations,
        contexts["manager-a-token"].managed_organizations,
      );
      assert.doesNotMatch(JSON.stringify(body), new RegExp(ids.organizationB));
    });
  });

  describe("organization-manager proof endpoint", () => {
    const accessUrl = (organizationId: string) =>
      `${baseUrl}/api/v1/management/organizations/${organizationId}/access`;

    for (const [name, token] of [
      ["staff", "staff-token"],
      ["branch manager", "branch-manager-token"],
    ]) {
      it(`denies ${name} with generic 403`, async () => {
        const response = await fetch(accessUrl(ids.organizationA), {
          headers: auth(token),
        });
        const text = await response.text();
        assert.equal(response.status, 403);
        assert.equal(JSON.parse(text).error.code, "forbidden");
        assertSanitized(text);
      });
    }

    it("allows Organization Manager A for Organization A", async () => {
      const response = await fetch(accessUrl(ids.organizationA), {
        headers: auth("manager-a-token"),
      });
      assert.equal(response.status, 200);
      assert.deepEqual(await json(response), {
        organization_id: ids.organizationA,
        role: "organization_manager",
        allowed: true,
      });
    });

    it("denies Organization Manager A for Organization B", async () => {
      const response = await fetch(accessUrl(ids.organizationB), {
        headers: auth("manager-a-token"),
      });
      const text = await response.text();
      assert.equal(response.status, 403);
      assert.equal(JSON.parse(text).error.code, "forbidden");
      assertSanitized(text);
    });

    it("rejects invalid organization UUID", async () => {
      const response = await fetch(accessUrl("not-a-uuid"), {
        headers: auth("manager-a-token"),
      });
      const text = await response.text();
      assert.equal(response.status, 400);
      assert.equal(JSON.parse(text).error.code, "bad_request");
      assertSanitized(text);
    });
  });
});
