import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  BranchSupervisorPasswordResetAccessError,
  BranchSupervisorPasswordResetRateLimitError,
  BranchSupervisorPasswordResetUnavailableError,
  createBranchSupervisorPasswordResetService,
  type BranchSupervisorPasswordResetDiagnostic,
} from "./branch-supervisor-password-reset";

const appSource = readFileSync(new URL("./app.ts", import.meta.url), "utf8");

const input = {
  actorUserId: "11111111-1111-4111-8111-111111111111",
  actorEmail: "admin@example.test",
  actorSessionId: "22222222-2222-4222-8222-222222222222",
  organizationId: "33333333-3333-4333-8333-333333333333",
  supervisorId: "44444444-4444-4444-8444-444444444444",
  currentPassword: "not-a-real-password",
  clientIp: "127.0.0.1",
  requestId: "55555555-5555-4555-8555-555555555555",
};

function serviceFor(
  rpc: (name: string) => Promise<{ data: unknown; error: { status?: number } | null }>,
  passwordClient: {
    auth: {
      signInWithPassword: PasswordClient["auth"]["signInWithPassword"];
      signOut: PasswordClient["auth"]["signOut"];
    };
  },
  diagnostics: BranchSupervisorPasswordResetDiagnostic[],
) {
  return createBranchSupervisorPasswordResetService("https://supabase.example", "publishable", "secret", "rate-secret", {
    client: { rpc, auth: { admin: { updateUserById: async () => ({ error: null }) } } },
    passwordClient,
    emitDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
    now: (() => { let value = 100; return () => value++; })(),
  });
}

type PasswordClient = {
  auth: {
    signInWithPassword: (credentials: { email: string; password: string }) => Promise<{
      data: { session: { access_token: string } | null; user: { id: string } | null };
      error: { status?: number } | null;
    }>;
    signOut: (options: { scope: "local" }) => Promise<{ error: { status?: number } | null }>;
  };
};

const successfulPasswordClient: PasswordClient = {
  auth: {
    signInWithPassword: async () => ({ data: { session: { access_token: "opaque" }, user: { id: input.actorUserId } }, error: null }),
    signOut: async () => ({ error: null }),
  },
};

test("records live-session RPC failures without sensitive fields", async () => {
  const diagnostics: BranchSupervisorPasswordResetDiagnostic[] = [];
  const service = serviceFor(async () => { throw new Error("transport"); }, successfulPasswordClient, diagnostics);
  await assert.rejects(() => service.authorize(input), BranchSupervisorPasswordResetUnavailableError);
  assert.equal(diagnostics[0]?.stage, "live_session_rpc");
  assert.equal(diagnostics[0]?.status, 503);
  assert.equal(JSON.stringify(diagnostics), JSON.stringify(diagnostics.map(({ requestId, stage, category, status, durationMs }) => ({ requestId, stage, category, status, durationMs }))));
});

test("route diagnostics cover dependency and unexpected-error boundaries", () => {
  assert.match(appSource, /stage: "dependency_initialization"/);
  assert.match(appSource, /stage: "unexpected_error"/);
  assert.match(appSource, /requestId: request\.id/);
});

test("records rate-limit RPC failures and preserves the service error", async () => {
  let calls = 0;
  const diagnostics: BranchSupervisorPasswordResetDiagnostic[] = [];
  const service = serviceFor(async () => {
    calls += 1;
    return calls === 1 ? { data: true, error: null } : { data: null, error: { status: 503 } };
  }, successfulPasswordClient, diagnostics);
  await assert.rejects(() => service.authorize(input), BranchSupervisorPasswordResetUnavailableError);
  assert.equal(diagnostics[0]?.stage, "rate_limit_rpc");
});

test("records Auth reauthentication failures", async () => {
  const diagnostics: BranchSupervisorPasswordResetDiagnostic[] = [];
  const passwordClient: PasswordClient = {
    auth: {
      signInWithPassword: async () => { throw new Error("timeout"); },
      signOut: async () => ({ error: null }),
    },
  };
  const service = serviceFor(async (name) => {
    if (name === "is_backend_auth_session_active") return { data: true, error: null };
    return { data: { allowed: true }, error: null };
  }, passwordClient, diagnostics);
  await assert.rejects(() => service.authorize(input), BranchSupervisorPasswordResetUnavailableError);
  assert.equal(diagnostics[0]?.stage, "auth_reauthentication");
});

test("records Auth sign-out failures separately", async () => {
  const diagnostics: BranchSupervisorPasswordResetDiagnostic[] = [];
  const passwordClient: PasswordClient = {
    auth: {
      signInWithPassword: async () => ({ data: { session: { access_token: "opaque" }, user: { id: input.actorUserId } }, error: null }),
      signOut: async () => ({ error: { status: 503 } }),
    },
  };
  const service = serviceFor(async (name) => {
    if (name === "is_backend_auth_session_active") return { data: true, error: null };
    return { data: { allowed: true }, error: null };
  }, passwordClient, diagnostics);
  await assert.rejects(() => service.authorize(input), BranchSupervisorPasswordResetUnavailableError);
  assert.equal(diagnostics[0]?.stage, "auth_sign_out");
});

test("records step-up issuance RPC failures", async () => {
  const diagnostics: BranchSupervisorPasswordResetDiagnostic[] = [];
  const service = serviceFor(async (name) => {
    if (name === "is_backend_auth_session_active") return { data: true, error: null };
    if (name === "consume_branch_supervisor_password_reset_rate_limit") return { data: { allowed: true }, error: null };
    return { data: null, error: { status: 503 } };
  }, successfulPasswordClient, diagnostics);
  await assert.rejects(() => service.authorize(input), BranchSupervisorPasswordResetUnavailableError);
  assert.equal(diagnostics[0]?.stage, "step_up_issue_rpc");
});

test("maps known access and rate-limit failures without logging secrets", async () => {
  const diagnostics: BranchSupervisorPasswordResetDiagnostic[] = [];
  const accessService = serviceFor(async () => ({ data: null, error: { code: "42501", status: 403 } }), successfulPasswordClient, diagnostics);
  await assert.rejects(() => accessService.authorize(input), BranchSupervisorPasswordResetAccessError);
  assert.equal(diagnostics[0]?.category, "access_denied");

  let calls = 0;
  const rateDiagnostics: BranchSupervisorPasswordResetDiagnostic[] = [];
  const rateService = serviceFor(async () => {
    calls += 1;
    return calls === 1 ? { data: true, error: null } : { data: { allowed: false }, error: null };
  }, successfulPasswordClient, rateDiagnostics);
  await assert.rejects(() => rateService.authorize(input), BranchSupervisorPasswordResetRateLimitError);
  assert.equal(rateDiagnostics[0]?.status, 429);
});
