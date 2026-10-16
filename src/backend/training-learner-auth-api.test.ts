import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { createPinCrypto, type PinCredential } from "./admin";
import { createApp, serializeTrainingLearnerSessionCookie } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { TrainingLearnerAuthService, TrainingLearnerCredential, TrainingLearnerSession } from "./training-learner-auth";

const ids = {
  organization: "a3100000-0000-4000-8000-000000000001",
  branch: "a3100000-0000-4000-8000-000000000002",
  branchCredential: "a3100000-0000-4000-8000-000000000003",
  employee: "a3100000-0000-4000-8000-000000000004",
  employeeCredential: "a3100000-0000-4000-8000-000000000005",
  session: "a3100000-0000-4000-8000-000000000006",
};
const allowedOrigin = "http://training.test";
const secret = "test-training-learner-auth-secret-placeholder-32-bytes";
const baseCrypto = createPinCrypto(secret);
const branchGrant = baseCrypto.issueTrainingGrant?.(
  ids.organization,
  ids.branch,
  ids.branchCredential,
  Date.now(),
) ?? "";
const storedCredential: TrainingLearnerCredential = {
  employee_id: ids.employee,
  organization_id: ids.organization,
  branch_id: ids.branch,
  display_name: "Training Employee",
  employee_code: "EMP-001",
  pin_hash: `\\x${"11".repeat(32)}`,
  salt: `\\x${"22".repeat(16)}`,
  kdf_version: 1,
  cost: 16384,
  block_size: 8,
  parallelization: 1,
  credential_version: ids.employeeCredential,
  credential_status: "active",
  failed_attempt_count: 0,
  locked_until: null,
};
const storedSession: TrainingLearnerSession = {
  session_id: ids.session,
  organization_id: ids.organization,
  organization_name: "Training Org",
  organization_name_ar: null,
  branch_id: ids.branch,
  branch_name: "Training Branch",
  branch_name_ar: null,
  employee_id: ids.employee,
  display_name: "Training Employee",
  employee_code: "EMP-001",
  issued_at: "2026-10-15T08:00:00.000Z",
  expires_at: "2026-10-15T20:00:00.000Z",
  idle_expires_at: "2026-10-15T09:00:00.000Z",
};
const servers: ReturnType<typeof createServer>[] = [];

function config(enabled = true) {
  return loadBackendConfig({
    NODE_ENV: "test",
    SUPABASE_URL: "http://127.0.0.1:54321",
    SUPABASE_PUBLISHABLE_KEY: "test-placeholder",
    DAILY_AUDIT_GRANT_SECRET: secret,
    TRAINING_ORGANIZATION_SLUG: "training-org",
    TRAINING_LEARNER_AUTH_ENABLED: enabled ? "true" : "false",
    ...(enabled ? { TRAINING_LEARNER_ALLOWED_ORIGIN: allowedOrigin } : {}),
  });
}

function dependencies(options: {
  credential?: TrainingLearnerCredential | null;
  personalPinValid?: boolean;
  validatedSession?: TrainingLearnerSession | null;
  completeSession?: TrainingLearnerSession | null;
  calls?: Record<string, unknown>;
} = {}): BackendDependencies {
  const calls = options.calls ?? {};
  const credential = options.credential === undefined ? storedCredential : options.credential;
  const learnerAuth: TrainingLearnerAuthService = {
    async getLoginCredential(input) {
      calls.credentialLookup = input;
      return credential;
    },
    async completeLogin(input) {
      calls.completeLogin = input;
      return options.completeSession === undefined
        ? input.authenticationSucceeded ? storedSession : null
        : options.completeSession;
    },
    async validateSession(tokenDigest) {
      calls.validateDigest = tokenDigest;
      return options.validatedSession === undefined ? storedSession : options.validatedSession;
    },
    async revokeSession(tokenDigest) {
      calls.revokeDigest = tokenDigest;
    },
  };
  const placeholderCredential: PinCredential = {
    pin_hash: `\\x${"33".repeat(32)}`,
    salt: `\\x${"44".repeat(16)}`,
    kdf_version: 1,
    cost: 16384,
    block_size: 8,
    parallelization: 1,
  };
  return {
    authVerifier: { async verify() { return null; } },
    async checkReadiness() { return true; },
    createUserContext() {
      return {
        async getUserContext() { return null; },
        async hasOrganizationManagerAccess() { return false; },
        async validateActiveBranches() { return false; },
        async listActiveBranches() { return []; },
      };
    },
    passwordChange: { async verifyCurrent() { return false; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { return { id: ids.employee }; }, async deleteUser() {}, async finalize() {} },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
    branchManagementAdmin: {
      async listBranches() { return []; }, async listStaff() { return []; },
      async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); },
      async getPinCredential() { return null; },
    },
    pinCrypto: {
      ...baseCrypto,
      async hash(pin) { calls.dummyHashPinLength = pin.length; return placeholderCredential; },
      async verify(pin, checked) {
        calls.personalPinLength = pin.length;
        calls.checkedCredential = checked;
        return options.personalPinValid ?? pin === "2468";
      },
    },
    trainingBranchAccessAdmin: {
      async listForInternalAdmin() { return []; },
      async storeForInternalAdmin() { throw new Error("unused"); },
      async listPublicBranches() { return null; },
      async getCredential() { return null; },
      async validateSession(input) {
        calls.branchValidation = input;
        return {
          organization_id: ids.organization,
          organization_name: "Training Org",
          organization_name_ar: null,
          branch_id: ids.branch,
          branch_name: "Training Branch",
          branch_name_ar: null,
        };
      },
      async listEmployees() { return []; },
      async validateEmployee() { return null; },
    },
    trainingLearnerAuthService: learnerAuth,
  };
}

async function start(enabled: boolean, deps: BackendDependencies) {
  const server = createServer(createApp(config(enabled), deps));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

afterEach(async () => Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve())))));

function branchCookie() {
  return `training_access=${branchGrant}`;
}

describe("secure Training learner authentication API", () => {
  it("keeps the new endpoints disabled by default", async () => {
    const origin = await start(false, dependencies());
    const response = await fetch(`${origin}/api/v1/training/learner/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Cookie: branchCookie(), Origin: allowedOrigin },
      body: JSON.stringify({ employee_code: "EMP-001", personal_pin: "2468" }),
    });
    assert.equal(response.status, 404);
  });

  it("uses the branch session, employee code, and personal PIN to issue an opaque cookie", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(true, dependencies({ calls }));
    const response = await fetch(`${origin}/api/v1/training/learner/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Cookie: branchCookie(), Origin: allowedOrigin },
      body: JSON.stringify({ employee_code: " EMP-001 ", personal_pin: "2468" }),
    });
    assert.equal(response.status, 200);
    const cookie = response.headers.get("set-cookie") ?? "";
    assert.match(cookie, /^training_learner_session=[A-Za-z0-9_-]{43};/);
    assert.match(cookie, /Max-Age=43200/);
    assert.match(cookie, /Path=\//);
    assert.match(cookie, /HttpOnly/);
    assert.match(cookie, /SameSite=Strict/);
    assert.match(cookie, /Priority=High/);
    assert.equal((calls.completeLogin as { employeeId: string }).employeeId, ids.employee);
    assert.match((calls.completeLogin as { tokenDigest: string }).tokenDigest, /^[0-9a-f]{64}$/);
    const text = await response.text();
    assert.doesNotMatch(text, /pin_hash|salt|credential_version|token_digest|2468/i);
    assert.match(text, /branch_pin_employee_pin/);
  });

  it("returns the same generic failure for a wrong PIN and an unknown employee", async () => {
    const wrongOrigin = await start(true, dependencies({ personalPinValid: false }));
    const wrong = await fetch(`${wrongOrigin}/api/v1/training/learner/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Cookie: branchCookie(), Origin: allowedOrigin },
      body: JSON.stringify({ employee_code: "EMP-001", personal_pin: "9999" }),
    });
    const unknownCalls: Record<string, unknown> = {};
    const unknownOrigin = await start(true, dependencies({ credential: null, calls: unknownCalls }));
    const unknown = await fetch(`${unknownOrigin}/api/v1/training/learner/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Cookie: branchCookie(), Origin: allowedOrigin },
      body: JSON.stringify({ employee_code: "UNKNOWN", personal_pin: "9999" }),
    });
    assert.equal(wrong.status, 403);
    assert.equal(unknown.status, 403);
    const wrongBody = await wrong.json() as { error: { code: string; message: string } };
    const unknownBody = await unknown.json() as { error: { code: string; message: string } };
    assert.deepEqual(
      { code: wrongBody.error.code, message: wrongBody.error.message },
      { code: unknownBody.error.code, message: unknownBody.error.message },
    );
    assert.equal(unknownCalls.dummyHashPinLength, 4);
  });

  it("requires an exact configured Origin for login mutations", async () => {
    const origin = await start(true, dependencies());
    for (const suppliedOrigin of [undefined, "http://evil.example.invalid", `${allowedOrigin}/path`]) {
      const response = await fetch(`${origin}/api/v1/training/learner/login`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Cookie: branchCookie(),
          ...(suppliedOrigin ? { Origin: suppliedOrigin } : {}),
        },
        body: JSON.stringify({ employee_code: "EMP-001", personal_pin: "2468" }),
      });
      assert.equal(response.status, 403);
    }
  });

  it("validates only a digest, refreshes safe session context, and clears forged sessions", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(true, dependencies({ calls }));
    const valid = await fetch(`${origin}/api/v1/training/learner/session`, {
      headers: { Cookie: `training_learner_session=${"a".repeat(43)}` },
    });
    assert.equal(valid.status, 200);
    assert.match(String(calls.validateDigest), /^[0-9a-f]{64}$/);
    assert.doesNotMatch(await valid.text(), /token|digest|pin_hash|salt/i);

    const invalid = await fetch(`${origin}/api/v1/training/learner/session`, {
      headers: { Cookie: "training_learner_session=forged" },
    });
    assert.equal(invalid.status, 401);
    assert.match(invalid.headers.get("set-cookie") ?? "", /^training_learner_session=; Max-Age=0/);
  });

  it("revokes logout by digest and remains safe when logout is repeated", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(true, dependencies({ calls }));
    const cookie = `training_learner_session=${"b".repeat(43)}`;
    for (let index = 0; index < 2; index += 1) {
      const response = await fetch(`${origin}/api/v1/training/learner/logout`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Cookie: cookie, Origin: allowedOrigin },
        body: JSON.stringify({}),
      });
      assert.equal(response.status, 204);
      assert.match(response.headers.get("set-cookie") ?? "", /^training_learner_session=; Max-Age=0/);
    }
    assert.match(String(calls.revokeDigest), /^[0-9a-f]{64}$/);
    assert.notEqual(calls.revokeDigest, "b".repeat(43));
  });

  it("serializes Secure in production without exposing the token outside the cookie", () => {
    const cookie = serializeTrainingLearnerSessionCookie("opaque", "production", 43_200);
    assert.match(cookie, /HttpOnly; SameSite=Strict; Priority=High; Secure$/);
  });
});
