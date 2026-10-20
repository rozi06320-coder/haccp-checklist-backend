import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createOrganizationManagerPasswordResetService,
  generateTemporaryPassword,
  ManagerPasswordResetReauthenticationError,
  ManagerPasswordResetReplayError,
  ManagerPasswordResetSessionRevokedError,
  ManagerPasswordResetUnavailableError,
} from "./organization-manager-password-reset";

const ids = {
  actor: "71000000-0000-4000-8000-000000000001",
  session: "71000000-0000-4000-8000-000000000002",
  organization: "71000000-0000-4000-8000-000000000003",
  manager: "71000000-0000-4000-8000-000000000004",
  operation: "71000000-0000-4000-8000-000000000005",
  grant: "71000000-0000-4000-8000-000000000006",
};
const idempotencyKey = "71000000-0000-4000-8000-000000000007";
const fixedPassword = "generated-only-on-the-server_A7";
const fixedAuthorization = "A".repeat(43);
type Call = { name: string; args?: unknown };

function fakes(options: {
  liveSession?: boolean;
  wrongPassword?: boolean;
  replayed?: boolean;
  authError?: { status?: number } | null;
  authThrows?: boolean;
  finalizeError?: boolean;
  finalizeThrows?: boolean;
  reconciledStatus?: "succeeded" | "pending_auth";
} = {}) {
  const calls: Call[] = [];
  const client = {
    async rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      if (name === "is_backend_auth_session_active") return { data: options.liveSession ?? true, error: null };
      if (name === "validate_organization_manager_backend_session") return { data: "active", error: null };
      if (name === "consume_organization_manager_password_reset_rate_limit") return { data: { allowed: true }, error: null };
      if (name === "issue_organization_manager_password_reset_step_up") {
        return { data: { grant_id: ids.grant, expires_at: "2026-10-20T20:05:00.000Z" }, error: null };
      }
      if (name === "begin_organization_manager_password_reset") {
        return { data: { operation_id: ids.operation, status: "pending_auth", replayed: options.replayed ?? false, recovery_generation: 0 }, error: null };
      }
      if (name === "finalize_organization_manager_password_reset") {
        if (options.finalizeThrows) throw new Error("response lost");
        return options.finalizeError
          ? { data: null, error: { code: "network" } }
          : { data: { operation_id: ids.operation, status: "succeeded" }, error: null };
      }
      if (name === "get_organization_manager_password_reset_status") {
        return { data: { operation_id: ids.operation, status: options.reconciledStatus ?? "pending_auth" }, error: null };
      }
      return { data: { operation_id: ids.operation, status: String(args.p_result) }, error: null };
    },
    auth: { admin: { async updateUserById(userId: string, attributes: { password: string }) {
      calls.push({ name: "updateUserById", args: { userId, attributes } });
      if (options.authThrows) throw new Error("timeout");
      return { error: options.authError ?? null };
    } } },
  };
  const passwordClient = { auth: {
    async signInWithPassword(credentials: { email: string; password: string }) {
      calls.push({ name: "signInWithPassword", args: credentials });
      return options.wrongPassword
        ? { data: { session: null, user: null }, error: { status: 400 } }
        : { data: { session: { access_token: "not-returned" }, user: { id: ids.actor } }, error: null };
    },
    async signOut(options: { scope: "local" }) {
      calls.push({ name: "signOut", args: options });
      return { error: null };
    },
  } };
  return { calls, client, passwordClient };
}

function service(fake: ReturnType<typeof fakes>) {
  return createOrganizationManagerPasswordResetService(
    "http://unused", "publishable", "secret", "test-rate-limit-hmac-key-at-least-32-bytes", {
    client: fake.client,
    passwordClient: fake.passwordClient,
    generatePassword: () => fixedPassword,
    generateAuthorization: () => fixedAuthorization,
    },
  );
}

const scope = { actorUserId: ids.actor, actorSessionId: ids.session, organizationId: ids.organization, managerId: ids.manager };

describe("Organization Manager password reset service", () => {
  it("generates high-entropy URL-safe passwords", () => {
    const generated = new Set(Array.from({ length: 64 }, generateTemporaryPassword));
    assert.equal(generated.size, 64);
    for (const password of generated) assert.match(password, /^[A-Za-z0-9_-]{32}$/);
  });

  it("server-verifies the admin password and issues an opaque short-lived grant", async () => {
    const fake = fakes();
    assert.deepEqual(await service(fake).authorize({
      ...scope, actorEmail: "admin@example.invalid", currentPassword: "correct-password", clientIp: "127.0.0.1",
    }), { authorization: fixedAuthorization, expiresAt: "2026-10-20T20:05:00.000Z" });
    assert.deepEqual(fake.calls.map((call) => call.name), [
      "is_backend_auth_session_active", "consume_organization_manager_password_reset_rate_limit",
      "signInWithPassword", "signOut", "issue_organization_manager_password_reset_step_up",
    ]);
    assert.doesNotMatch(JSON.stringify(fake.calls.filter((call) => call.name.includes("rpc"))), /correct-password/);
  });

  it("rejects a wrong password without issuing a grant", async () => {
    const fake = fakes({ wrongPassword: true });
    await assert.rejects(service(fake).authorize({
      ...scope, actorEmail: "admin@example.invalid", currentPassword: "wrong-password", clientIp: "127.0.0.1",
    }), ManagerPasswordResetReauthenticationError);
    assert.equal(fake.calls.some((call) => call.name === "issue_organization_manager_password_reset_step_up"), false);
  });

  it("distinguishes revoked sessions from dependency failures", async () => {
    await assert.rejects(service(fakes({ liveSession: false })).reset({
      ...scope, idempotencyKey, authorization: fixedAuthorization, clientIp: "127.0.0.1",
    }), ManagerPasswordResetSessionRevokedError);
    const fake = fakes();
    fake.client.rpc = async () => { throw new Error("database unavailable"); };
    await assert.rejects(service(fake).reset({
      ...scope, idempotencyKey, authorization: fixedAuthorization, clientIp: "127.0.0.1",
    }), ManagerPasswordResetUnavailableError);
  });

  it("consumes the grant, mutates only the target, finalizes, and returns the password once", async () => {
    const fake = fakes();
    assert.deepEqual(await service(fake).reset({
      ...scope, idempotencyKey, authorization: fixedAuthorization, clientIp: "127.0.0.1",
    }), { temporaryPassword: fixedPassword });
    assert.deepEqual(fake.calls.map((call) => call.name), [
      "is_backend_auth_session_active", "consume_organization_manager_password_reset_rate_limit",
      "begin_organization_manager_password_reset", "updateUserById", "finalize_organization_manager_password_reset",
    ]);
    assert.deepEqual(fake.calls[3]?.args, { userId: ids.manager, attributes: { password: fixedPassword } });
    assert.doesNotMatch(JSON.stringify(fake.calls.filter((call) => call.name !== "updateUserById")), new RegExp(fixedPassword));
    assert.doesNotMatch(JSON.stringify(fake.calls), new RegExp(idempotencyKey));
    assert.doesNotMatch(JSON.stringify(fake.calls), new RegExp(fixedAuthorization));
  });

  it("rejects an idempotency replay before generating or changing a password", async () => {
    const fake = fakes({ replayed: true });
    await assert.rejects(service(fake).reset({
      ...scope, idempotencyKey, authorization: fixedAuthorization, clientIp: "127.0.0.1",
    }), ManagerPasswordResetReplayError);
    assert.equal(fake.calls.some((call) => call.name === "updateUserById"), false);
  });

  it("records definitive and ambiguous Auth outcomes without blind replay", async () => {
    for (const [options, expected] of [
      [{ authError: { status: 422 } }, "auth_rejected"],
      [{ authThrows: true }, "auth_outcome_unknown"],
    ] as const) {
      const fake = fakes(options);
      await assert.rejects(service(fake).reset({
        ...scope, idempotencyKey, authorization: fixedAuthorization, clientIp: "127.0.0.1",
      }), ManagerPasswordResetUnavailableError);
      assert.equal((fake.calls.at(-1)?.args as Record<string, unknown>).p_result, expected);
      assert.equal(fake.calls.filter((call) => call.name === "updateUserById").length, 1);
    }
  });

  it("reconciles a lost finalize response and quarantines unresolved success", async () => {
    const committed = fakes({ finalizeThrows: true, reconciledStatus: "succeeded" });
    assert.deepEqual(await service(committed).reset({
      ...scope, idempotencyKey, authorization: fixedAuthorization, clientIp: "127.0.0.1",
    }), { temporaryPassword: fixedPassword });
    const unresolved = fakes({ finalizeError: true, reconciledStatus: "pending_auth" });
    await assert.rejects(service(unresolved).reset({
      ...scope, idempotencyKey, authorization: fixedAuthorization, clientIp: "127.0.0.1",
    }), ManagerPasswordResetUnavailableError);
    assert.equal((unresolved.calls.at(-1)?.args as Record<string, unknown>).p_result, "auth_outcome_unknown");
  });
});
