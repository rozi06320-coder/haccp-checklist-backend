import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const userId = "15000000-0000-4000-8000-000000000001";
const verifiedEmail = "verified@example.invalid";
const shortCurrentPassword = "c".repeat(3);
const currentPassword = ` ${"c".repeat(18)} `;
const newPassword = ` ${"n".repeat(18)} `;
const numericOnlyPassword = Array.from(
  { length: 6 },
  (_, index) => String((index + 1) % 10),
).join("");
const letterOnlyPassword = "n".repeat(6);
const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "password-test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});
const servers: Server[] = [];

function dependencies(options: {
  profile?: "active" | "disabled" | "missing" | "complete";
  verified?: boolean;
  verifyError?: boolean;
  updateError?: boolean;
  finalizeError?: boolean;
  calls?: Array<{ operation: string; args: unknown[] }>;
} = {}): BackendDependencies {
  const calls = options.calls ?? [];
  return {
    authVerifier: {
      async verify(token) {
        return token === "valid-token"
          ? { userId, email: verifiedEmail }
          : null;
      },
    },
    async checkReadiness() { return true; },
    createUserContext() {
      return {
        async getUserContext() {
          if (options.profile === "missing") return null;
          return {
            id: userId,
            full_name: "Provisioned User",
            must_change_password: options.profile !== "complete",
            disabled: options.profile === "disabled",
            branches: [],
            managed_organizations: [],
          };
        },
        async hasOrganizationManagerAccess() { return false; },
        async validateActiveBranches() { return false; },
        async listActiveBranches() { return []; },
      };
    },
    passwordChange: {
      async verifyCurrent(email, password) {
        calls.push({ operation: "verify", args: [email, password] });
        if (options.verifyError) throw new Error("internal verification failure");
        return options.verified ?? true;
      },
      async updatePassword(id, password) {
        calls.push({ operation: "update", args: [id, password] });
        if (options.updateError) throw new Error("internal update failure");
      },
      async finalize(id) {
        calls.push({ operation: "finalize", args: [id] });
        if (options.finalizeError) throw new Error("internal rpc failure");
      },
    },
    provisioningAdmin: {
      async createUser() { return { id: userId }; },
      async deleteUser() {},
      async finalize() {},
    },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
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
  };
}

async function start(deps = dependencies()) {
  const server = createServer(createApp(config, deps));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

async function post(baseUrl: string, body: unknown, token?: string) {
  return fetch(`${baseUrl}/api/v1/account/change-password`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) => new Promise<void>((resolve) => server.close(() => resolve())),
    ),
  );
});

describe("POST /api/v1/account/change-password", () => {
  it("denies missing/invalid bearer and missing/disabled/completed profiles", async () => {
    for (const [deps, token, status] of [
      [dependencies(), undefined, 401],
      [dependencies(), "invalid-token", 401],
      [dependencies({ profile: "missing" }), "valid-token", 403],
      [dependencies({ profile: "disabled" }), "valid-token", 403],
      [dependencies({ profile: "complete" }), "valid-token", 403],
    ] as const) {
      const baseUrl = await start(deps);
      assert.equal(
        (await post(baseUrl, { current_password: currentPassword, new_password: newPassword }, token)).status,
        status,
      );
    }
  });

  it("strictly rejects unknown fields, empty/oversized current values, invalid new lengths, and equal values", async () => {
    for (const body of [
      { current_password: currentPassword, new_password: newPassword, user_id: userId },
      { current_password: "", new_password: newPassword },
      { current_password: currentPassword, new_password: "n".repeat(5) },
      { current_password: "x".repeat(129), new_password: newPassword },
      { current_password: currentPassword, new_password: "x".repeat(129) },
      { current_password: currentPassword, new_password: currentPassword },
    ]) {
      const calls: Array<{ operation: string; args: unknown[] }> = [];
      const response = await post(await start(dependencies({ calls })), body, "valid-token");
      assert.equal(response.status, 400);
      assert.deepEqual(calls, []);
    }
  });

  it("accepts a short non-empty current password and forwards it unchanged", async () => {
    const calls: Array<{ operation: string; args: unknown[] }> = [];
    const response = await post(
      await start(dependencies({ calls })),
      { current_password: shortCurrentPassword, new_password: letterOnlyPassword },
      "valid-token",
    );
    assert.equal(response.status, 200);
    assert.deepEqual(calls[0], {
      operation: "verify",
      args: [verifiedEmail, shortCurrentPassword],
    });
  });

  it("accepts generated numeric-only and letter-only new passwords at the six-character boundary", async () => {
    for (const candidate of [numericOnlyPassword, letterOnlyPassword]) {
      const response = await post(
        await start(),
        {
          current_password: shortCurrentPassword,
          new_password: candidate,
        },
        "valid-token",
      );
      assert.equal(response.status, 200);
    }
  });

  it("accepts a new password at the 128-character boundary", async () => {
    const response = await post(
      await start(),
      {
        current_password: shortCurrentPassword,
        new_password: "n".repeat(128),
      },
      "valid-token",
    );
    assert.equal(response.status, 200);
  });

  it("forwards password bytes unchanged and updates only the verified user ID", async () => {
    const calls: Array<{ operation: string; args: unknown[] }> = [];
    const response = await post(
      await start(dependencies({ calls })),
      { current_password: currentPassword, new_password: newPassword },
      "valid-token",
    );
    assert.equal(response.status, 200);
    const text = await response.text();
    assert.deepEqual(JSON.parse(text), { success: true });
    assert.doesNotMatch(text, new RegExp(currentPassword));
    assert.doesNotMatch(text, new RegExp(newPassword));
    assert.deepEqual(calls, [
      { operation: "verify", args: [verifiedEmail, currentPassword] },
      { operation: "update", args: [userId, newPassword] },
      { operation: "finalize", args: [userId] },
    ]);
  });

  it("returns a generic current-password error without update or RPC", async () => {
    const calls: Array<{ operation: string; args: unknown[] }> = [];
    const response = await post(
      await start(dependencies({ verified: false, calls })),
      { current_password: currentPassword, new_password: newPassword },
      "valid-token",
    );
    const text = await response.text();
    assert.equal(response.status, 400);
    assert.deepEqual(calls.map((call) => call.operation), ["verify"]);
    assert.doesNotMatch(text, new RegExp(currentPassword.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.doesNotMatch(text, new RegExp(newPassword.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.doesNotMatch(text, /verified@example|valid-token|internal/i);
  });

  it("does not finalize when verification throws or Auth update fails", async () => {
    for (const options of [{ verifyError: true }, { updateError: true }]) {
      const calls: Array<{ operation: string; args: unknown[] }> = [];
      const response = await post(
        await start(dependencies({ ...options, calls })),
        { current_password: currentPassword, new_password: newPassword },
        "valid-token",
      );
      assert.equal(response.status, 503);
      assert.equal(calls.some((call) => call.operation === "finalize"), false);
    }
  });

  it("returns generic 503 after Auth success when finalization fails", async () => {
    const calls: Array<{ operation: string; args: unknown[] }> = [];
    const response = await post(
      await start(dependencies({ finalizeError: true, calls })),
      { current_password: currentPassword, new_password: newPassword },
      "valid-token",
    );
    const text = await response.text();
    assert.equal(response.status, 503);
    assert.deepEqual(calls.map((call) => call.operation), ["verify", "update", "finalize"]);
    assert.match(text, /retry using your latest password/i);
    assert.doesNotMatch(text, /internal|verified@example|valid-token/i);
  });

  it("applies a stricter five-attempt rate limit", async () => {
    const baseUrl = await start();
    for (let attempt = 0; attempt < 5; attempt += 1) {
      assert.equal(
        (await post(baseUrl, { current_password: currentPassword, new_password: newPassword }, "valid-token")).status,
        200,
      );
    }
    const limited = await post(
      baseUrl,
      { current_password: currentPassword, new_password: newPassword },
      "valid-token",
    );
    assert.equal(limited.status, 429);
  });
});
