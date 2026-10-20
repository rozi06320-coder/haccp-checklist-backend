import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import {
  ManagerPasswordResetAccessError,
  ManagerPasswordResetRateLimitError,
  ManagerPasswordResetReauthenticationError,
  ManagerPasswordResetReplayError,
  ManagerPasswordResetSessionRevokedError,
  ManagerPasswordResetUnavailableError,
} from "./organization-manager-password-reset";

const ids = {
  actor: "72000000-0000-4000-8000-000000000001",
  session: "72000000-0000-4000-8000-000000000002",
  organization: "72000000-0000-4000-8000-000000000003",
  manager: "72000000-0000-4000-8000-000000000004",
  request: "72000000-0000-4000-8000-000000000005",
};
const grant = "G".repeat(43);
const temporaryPassword = "server-generated-secret_NEVER_LOG";
const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "manager-reset-test-publishable",
  DAILY_AUDIT_GRANT_SECRET: "test-manager-reset-grant-secret-at-least-32-bytes",
});
const servers: Server[] = [];

function dependencies(options: {
  sessionId?: string | null;
  internalAdmin?: boolean;
  authorizeError?: Error;
  resetError?: Error;
  protectedSession?: "active" | "revoked" | "not_applicable" | "unavailable";
  calls?: Array<{ name: string; input: unknown }>;
} = {}): BackendDependencies {
  const calls = options.calls ?? [];
  return {
    authVerifier: { async verify(token) {
      return token === "valid" ? {
        userId: ids.actor, email: "admin@example.invalid",
        ...(options.sessionId === null ? {} : { sessionId: options.sessionId ?? ids.session }),
      } : null;
    } },
    async checkReadiness() { return true; },
    createUserContext() { return {
      async getUserContext() { return null; },
      async isInternalAdmin() { return options.internalAdmin ?? true; },
      async hasOrganizationManagerAccess() { return false; },
      async validateActiveBranches() { return false; },
      async listActiveBranches() { return []; },
    }; },
    passwordChange: { async verifyCurrent() { return false; }, async updatePassword() {}, async finalize() {} },
    organizationManagerPasswordReset: {
      async validateProtectedSession() {
        if (options.protectedSession === "unavailable") throw new ManagerPasswordResetUnavailableError();
        return options.protectedSession ?? "not_applicable";
      },
      async authorize(input) {
        calls.push({ name: "authorize", input });
        if (options.authorizeError) throw options.authorizeError;
        return { authorization: grant, expiresAt: "2026-10-20T20:05:00.000Z" };
      },
      async reset(input) {
        calls.push({ name: "reset", input });
        if (options.resetError) throw options.resetError;
        return { temporaryPassword };
      },
    },
    provisioningAdmin: { async createUser() { return { id: ids.manager }; }, async deleteUser() {}, async finalize() {} },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
    branchManagementAdmin: {
      async listBranches() { return []; }, async listStaff() { return []; },
      async getPinMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async storePin() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async getPinCredential() { return null; },
    },
    pinCrypto: { async hash() { throw new Error("unused"); }, async verify() { return false; }, issueGrant() { return "unused"; }, verifyGrant() { return false; } },
  };
}

async function start(deps: BackendDependencies) {
  const server = createServer(createApp(config, deps));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

function endpoint(baseUrl: string, suffix = "") {
  return `${baseUrl}/api/v1/internal-admin/organizations/${ids.organization}/managers/${ids.manager}/reset-password${suffix}`;
}

async function stepUp(baseUrl: string, options: { token?: string | null; body?: unknown; rawBody?: string; forwardedFor?: string } = {}) {
  return fetch(endpoint(baseUrl, "/step-up"), {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(options.token === null ? {} : { Authorization: `Bearer ${options.token ?? "valid"}` }),
      ...(options.forwardedFor ? { "X-Forwarded-For": options.forwardedFor } : {}) },
    body: options.rawBody ?? JSON.stringify(options.body ?? { current_password: "correct-password" }),
  });
}

async function reset(baseUrl: string, options: { token?: string | null; authorization?: string | null; idempotencyKey?: string | null; body?: unknown } = {}) {
  return fetch(endpoint(baseUrl), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(options.token === null ? {} : { Authorization: `Bearer ${options.token ?? "valid"}` }),
      ...(options.authorization === null ? {} : { "X-Password-Reset-Step-Up": options.authorization ?? grant }),
      ...(options.idempotencyKey === null ? {} : { "Idempotency-Key": options.idempotencyKey ?? ids.request }),
    },
    body: JSON.stringify(options.body ?? {}),
  });
}

afterEach(async () => Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve())))));

describe("Organization Manager password reset API", () => {
  it("reauthenticates and returns only an opaque no-store grant", async () => {
    const calls: Array<{ name: string; input: unknown }> = [];
    const response = await stepUp(await start(dependencies({ calls })), { forwardedFor: "203.0.113.99" });
    assert.equal(response.status, 200);
    assert.match(response.headers.get("cache-control") ?? "", /private, no-store/);
    assert.deepEqual(await response.json(), { step_up_grant: grant, expires_at: "2026-10-20T20:05:00.000Z" });
    assert.equal(calls[0]?.name, "authorize");
    assert.equal((calls[0]?.input as { actorEmail: string }).actorEmail, "admin@example.invalid");
    assert.notEqual((calls[0]?.input as { clientIp: string }).clientIp, "203.0.113.99");
  });

  it("returns the generated password once and never accepts a client password", async () => {
    const calls: Array<{ name: string; input: unknown }> = [];
    const baseUrl = await start(dependencies({ calls }));
    const response = await reset(baseUrl);
    assert.equal(response.status, 200);
    assert.match(response.headers.get("cache-control") ?? "", /no-store/);
    assert.deepEqual(await response.json(), { temporary_password: temporaryPassword, must_change_password: true });
    assert.equal(calls[0]?.name, "reset");
    assert.equal((calls[0]?.input as { authorization: string }).authorization, grant);
    assert.equal((await reset(baseUrl, { body: { temporary_password: "client-choice" } })).status, 400);
  });

  it("requires authentication, Internal Admin access, a session, and the step-up grant", async () => {
    assert.equal((await stepUp(await start(dependencies()), { token: null })).status, 401);
    assert.equal((await stepUp(await start(dependencies({ internalAdmin: false })))).status, 403);
    assert.equal((await stepUp(await start(dependencies({ sessionId: null })))).status, 401);
    assert.equal((await reset(await start(dependencies()), { authorization: null })).status, 400);
  });

  it("maps revocation, dependency outage, reauthentication, replay, and durable throttling distinctly", async () => {
    for (const [phase, error, expected] of [
      ["authorize", new ManagerPasswordResetReauthenticationError(), 403],
      ["authorize", new ManagerPasswordResetRateLimitError(), 429],
      ["reset", new ManagerPasswordResetSessionRevokedError(), 401],
      ["reset", new ManagerPasswordResetReplayError(), 409],
      ["reset", new ManagerPasswordResetUnavailableError(), 503],
      ["reset", new ManagerPasswordResetAccessError(), 403],
    ] as const) {
      const baseUrl = await start(dependencies(phase === "authorize" ? { authorizeError: error } : { resetError: error }));
      const response = phase === "authorize" ? await stepUp(baseUrl) : await reset(baseUrl);
      assert.equal(response.status, expected);
      assert.match(response.headers.get("cache-control") ?? "", /private, no-store/);
      assert.doesNotMatch(await response.text(), /access_token|refresh_token|server-generated-secret/i);
    }
  });

  it("sets no-store even for authentication and body-parser middleware failures", async () => {
    const baseUrl = await start(dependencies());
    for (const response of [
      await reset(baseUrl, { token: null }),
      await stepUp(baseUrl, { rawBody: "{" }),
    ]) assert.match(response.headers.get("cache-control") ?? "", /private, no-store/);
  });

  it("enforces Organization Manager route revocation and distinguishes database outages", async () => {
    for (const [status, expected] of [["revoked", 401], ["unavailable", 503]] as const) {
      const baseUrl = await start(dependencies({ protectedSession: status }));
      const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/overview`, {
        headers: { Authorization: "Bearer valid" },
      });
      assert.equal(response.status, expected);
    }
  });
});
