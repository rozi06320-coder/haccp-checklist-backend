import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const userId = "10000000-0000-4000-8000-000000000001";
const branchId = "30000000-0000-4000-8000-000000000001";
const idempotencyKey = "40000000-0000-4000-8000-000000000001";
const diagnosticPrefix = "OPENING_SUBMIT_403_DIAGNOSTIC ";

async function source(file: string) {
  return readFile(path.resolve(file), "utf8");
}

function dependencies(options?: { mustChangePassword?: boolean }): BackendDependencies {
  return {
    authVerifier: {
      async verify(token) {
        return token === "supervisor-token" ? { userId, email: "supervisor@example.invalid" } : null;
      },
    },
    createUserContext: () => ({
      async getUserContext() {
        return {
          id: userId,
          full_name: "Supervisor",
          must_change_password: options?.mustChangePassword ?? false,
          disabled: false,
          branches: [{ id: branchId, name: "Branch", organization_id: "20000000-0000-4000-8000-000000000001", role: "branch_manager" }],
          managed_organizations: [],
        };
      },
      async hasOrganizationManagerAccess() { return false; },
      async validateActiveBranches() { return false; },
      async listActiveBranches() { return []; },
    }),
    checkReadiness: async () => true,
    passwordChange: {},
    provisioningAdmin: {},
    managementAdmin: {},
    branchManagementAdmin: {},
    pinCrypto: {},
  } as BackendDependencies;
}

const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});

async function listen(injectedDependencies: BackendDependencies): Promise<{ baseUrl: string; server: Server }> {
  const server = createServer(createApp(config, injectedDependencies));
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address() as AddressInfo;
  return { baseUrl: `http://127.0.0.1:${address.port}`, server };
}

async function close(server: Server) {
  await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

describe("Opening submit 403 diagnostics", () => {
  const openServers: Server[] = [];

  afterEach(async () => {
    await Promise.all(openServers.splice(0).map(close));
  });

  it("logs a safe single-line diagnostic while preserving backend 403 response", async () => {
    const records: string[] = [];
    const originalWarn = console.warn;
    console.warn = (...args: unknown[]) => records.push(args.map(String).join(" "));
    try {
      const isolated = await listen(dependencies({ mustChangePassword: true }));
      openServers.push(isolated.server);
      const response = await fetch(`${isolated.baseUrl}/api/v1/supervisor/branches/${branchId}/checklists/submit`, {
        method: "POST",
        headers: {
          Authorization: "Bearer supervisor-token",
          "Content-Type": "application/json",
          "Idempotency-Key": idempotencyKey,
        },
        body: JSON.stringify({
          checklist_type: "kitchen_opening",
          expected_revision: 0,
          answers: [{ item_id: "kitchen-opening-1", answer: "completed", remark: "", evidence_id: null }],
        }),
      });
      const body = await response.json() as { error: { code: string; message: string } };
      assert.equal(response.status, 403);
      assert.equal(body.error.code, "forbidden");
      assert.equal(body.error.message, "Access is denied.");
    } finally {
      console.warn = originalWarn;
    }

    assert.equal(records.length, 1);
    assert.match(records[0], new RegExp(`^${diagnosticPrefix}`));
    const event = JSON.parse(records[0].slice(diagnosticPrefix.length)) as Record<string, unknown>;
    assert.deepEqual(Object.keys(event).sort(), ["code", "operation", "reason", "requestId", "status"].sort());
    assert.equal(event.operation, "submit_opening_checklist");
    assert.equal(event.status, 403);
    assert.equal(event.code, "forbidden");
    assert.equal(event.reason, "password_change_required");
    assert.equal(typeof event.requestId, "string");
    assert.doesNotMatch(records[0], new RegExp(`${userId}|${branchId}|supervisor-token|kitchen-opening-1|answers`, "i"));
  });

  it("does not log the opening diagnostic for Staff Hygiene requests sharing the submit route", async () => {
    const records: string[] = [];
    const originalWarn = console.warn;
    console.warn = (...args: unknown[]) => records.push(args.map(String).join(" "));
    try {
      const isolated = await listen(dependencies({ mustChangePassword: true }));
      openServers.push(isolated.server);
      const response = await fetch(`${isolated.baseUrl}/api/v1/supervisor/branches/${branchId}/checklists/submit`, {
        method: "POST",
        headers: {
          Authorization: "Bearer supervisor-token",
          "Content-Type": "application/json",
          "Idempotency-Key": idempotencyKey,
        },
        body: JSON.stringify({
          checklist_type: "staff_hygiene",
          operational_team_id: "50000000-0000-4000-8000-000000000001",
          staff: [],
        }),
      });
      assert.equal(response.status, 403);
    } finally {
      console.warn = originalWarn;
    }

    assert.equal(records.length, 0);
  });

  it("keeps opening submit 403 diagnostics focused on access categories", async () => {
    const app = await source("src/backend/app.ts");
    const route = app.slice(
      app.indexOf('app.post("/api/v1/supervisor/branches/:branchId/checklists/submit"'),
      app.indexOf('app.get("/api/v1/supervisor/branches/:branchId/submissions"'),
    );
    const diagnostic = app.slice(
      app.indexOf("function logOpeningSubmit403Diagnostic"),
      app.indexOf("function openingSubmitRouteError"),
    );

    assert.match(app, /OPENING_SUBMIT_403_DIAGNOSTIC /);
    assert.match(app, /operation: "submit_opening_checklist"/);
    assert.match(app, /password_change_required/);
    assert.match(app, /checklist_persistence_missing/);
    assert.match(app, /evidence_access_denied/);
    assert.match(app, /checklist_access_denied/);
    assert.match(route, /openingRequest=opening\.success/);
    assert.match(route, /openingSubmitRouteError\(error, request, openingRequest\)/);
    assert.doesNotMatch(diagnostic, /actorUserId|branchId|answers|authorization|token|body/i);
  });
});
