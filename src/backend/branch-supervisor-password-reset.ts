import { createHash, createHmac, randomBytes } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

const nonPersistentAuth = { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false } as const;
const resetStatusSchema = z.enum([
  "pending_auth", "auth_outcome_unknown", "succeeded", "auth_rejected", "superseded",
]);
const beginResultSchema = z.object({
  operation_id: z.string().uuid(),
  status: resetStatusSchema,
  replayed: z.boolean(),
  recovery_generation: z.number().int().min(0).max(3),
}).strict();
const operationResultSchema = z.object({ operation_id: z.string().uuid(), status: resetStatusSchema }).strict();
const stepUpResultSchema = z.object({
  grant_id: z.string().uuid(),
  expires_at: z.string().datetime({ offset: true }),
}).strict();

export class BranchSupervisorPasswordResetAccessError extends Error {}
export class BranchSupervisorPasswordResetReauthenticationError extends Error {}
export class BranchSupervisorPasswordResetConflictError extends Error {}
export class BranchSupervisorPasswordResetReplayError extends Error {}
export class BranchSupervisorPasswordResetRateLimitError extends Error {}
export class BranchSupervisorPasswordResetSessionRevokedError extends Error {}
export class BranchSupervisorPasswordResetUnavailableError extends Error {}

export type BranchSupervisorPasswordResetService = {
  validateProtectedSession(input: { actorUserId: string; actorSessionId: string }): Promise<"active" | "revoked" | "not_applicable">;
  authorize(input: {
    actorUserId: string;
    actorEmail: string;
    actorSessionId: string;
    organizationId: string;
    supervisorId: string;
    currentPassword: string;
    clientIp: string;
  }): Promise<{ authorization: string; expiresAt: string }>;
  reset(input: {
    actorUserId: string;
    actorSessionId: string;
    organizationId: string;
    supervisorId: string;
    idempotencyKey: string;
    authorization: string;
    clientIp: string;
  }): Promise<{ temporaryPassword: string }>;
};

type RpcError = { code?: string; message?: string; status?: number };
type ResetRpcClient = {
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: RpcError | null }>;
  auth: { admin: { updateUserById(userId: string, attributes: { password: string }): Promise<{ error: RpcError | null }> } };
};
type PasswordVerificationClient = {
  auth: {
    signInWithPassword(credentials: { email: string; password: string }): Promise<{
      data: { session: { access_token: string } | null; user: { id: string } | null };
      error: RpcError | null;
    }>;
    signOut(options: { scope: "local" }): Promise<{ error: RpcError | null }>;
  };
};

function sha256(value: string) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export function generateTemporaryPassword(): string {
  return randomBytes(24).toString("base64url");
}

function mapRpcError(error: RpcError) {
  if (error.code === "42501") return new BranchSupervisorPasswordResetAccessError();
  if (error.code === "P0001" && error.message?.includes("rate limited")) return new BranchSupervisorPasswordResetRateLimitError();
  if (error.code === "P0001" && error.message?.includes("step-up required")) return new BranchSupervisorPasswordResetReplayError();
  if (error.code === "55000" || error.code === "23505") return new BranchSupervisorPasswordResetConflictError();
  return new BranchSupervisorPasswordResetUnavailableError();
}

function authFailureIsDefinitive(error: RpcError): boolean {
  return typeof error.status === "number" && error.status >= 400 && error.status < 500
    && error.status !== 408 && error.status !== 429;
}

export function createBranchSupervisorPasswordResetService(
  url: string,
  publishableKey: string,
  secretKey: string,
  rateLimitHmacKey: string,
  options: {
    authTimeoutMs?: number;
    generatePassword?: () => string;
    generateAuthorization?: () => string;
    client?: ResetRpcClient;
    passwordClient?: PasswordVerificationClient;
  } = {},
): BranchSupervisorPasswordResetService {
  const authTimeoutMs = options.authTimeoutMs ?? 10_000;
  const timedFetch = async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const timeout = AbortSignal.timeout(authTimeoutMs);
    return fetch(input, { ...init, signal: init?.signal ? AbortSignal.any([init.signal, timeout]) : timeout });
  };
  const client: ResetRpcClient = options.client ?? createClient(url, secretKey, {
    auth: nonPersistentAuth, global: { fetch: timedFetch },
  }) as unknown as ResetRpcClient;
  const createPasswordClient = (): PasswordVerificationClient => options.passwordClient ?? createClient(
    url,
    publishableKey,
    { auth: nonPersistentAuth, global: { fetch: timedFetch } },
  ) as unknown as PasswordVerificationClient;
  const generatePassword = options.generatePassword ?? generateTemporaryPassword;
  const generateAuthorization = options.generateAuthorization ?? (() => randomBytes(32).toString("base64url"));

  function clientAddressHash(clientIp: string) {
    return createHmac("sha256", rateLimitHmacKey)
      .update("branch-supervisor-password-reset-ip\0", "utf8")
      .update(clientIp, "utf8")
      .digest("hex");
  }

  async function rpc(name: string, args: Record<string, unknown>) {
    let result: Awaited<ReturnType<ResetRpcClient["rpc"]>>;
    try { result = await client.rpc(name, args); } catch { throw new BranchSupervisorPasswordResetUnavailableError(); }
    if (result.error) throw mapRpcError(result.error);
    return result.data;
  }

  async function requireLiveSession(actorUserId: string, actorSessionId: string) {
    const data = await rpc("is_backend_auth_session_active", {
      p_user_id: actorUserId, p_session_id: actorSessionId,
    });
    if (data === false) throw new BranchSupervisorPasswordResetSessionRevokedError();
    if (data !== true) throw new BranchSupervisorPasswordResetUnavailableError();
  }

  async function consumeRateLimit(input: {
    actorUserId: string; organizationId: string; supervisorId: string; clientIp: string; phase: "step_up" | "reset";
  }) {
    const result = await rpc("consume_branch_supervisor_password_reset_rate_limit", {
      p_actor_user_id: input.actorUserId,
      p_organization_id: input.organizationId,
      p_target_user_id: input.supervisorId,
      p_client_address_hash: clientAddressHash(input.clientIp),
      p_phase: input.phase,
    });
    if (!result || typeof result !== "object" || (result as { allowed?: unknown }).allowed !== true) {
      throw new BranchSupervisorPasswordResetRateLimitError();
    }
  }

  async function recordFailure(operationId: string, input: {
    actorUserId: string; organizationId: string; supervisorId: string;
  }, result: "auth_rejected" | "auth_outcome_unknown") {
    const parsed = operationResultSchema.safeParse(await rpc("fail_branch_supervisor_password_reset", {
      p_operation_id: operationId,
      p_actor_user_id: input.actorUserId,
      p_organization_id: input.organizationId,
      p_target_user_id: input.supervisorId,
      p_result: result,
    }));
    if (!parsed.success) throw new BranchSupervisorPasswordResetUnavailableError();
    return parsed.data.status;
  }

  return {
    async validateProtectedSession(input) {
      const data = await rpc("validate_branch_supervisor_backend_session", {
        p_actor_user_id: input.actorUserId, p_actor_session_id: input.actorSessionId,
      });
      if (data !== "active" && data !== "revoked" && data !== "not_applicable") {
        throw new BranchSupervisorPasswordResetUnavailableError();
      }
      return data;
    },

    async authorize(input) {
      await requireLiveSession(input.actorUserId, input.actorSessionId);
      await consumeRateLimit({ ...input, phase: "step_up" });
      try {
        // Supabase clients retain an in-memory Auth session even with
        // persistence disabled. A fresh client prevents concurrent step-up
        // requests from signing out or observing one another's session state.
        const passwordClient = createPasswordClient();
        const result = await passwordClient.auth.signInWithPassword({
          email: input.actorEmail, password: input.currentPassword,
        });
        if (result.data.session) {
          const signedOut = await passwordClient.auth.signOut({ scope: "local" });
          if (signedOut.error) throw new BranchSupervisorPasswordResetUnavailableError();
        }
        if (result.error || result.data.user?.id !== input.actorUserId
          || !result.data.session?.access_token) {
          if (result.error?.status === 429) throw new BranchSupervisorPasswordResetRateLimitError();
          if (result.error && !authFailureIsDefinitive(result.error)) throw new BranchSupervisorPasswordResetUnavailableError();
          throw new BranchSupervisorPasswordResetReauthenticationError();
        }
      } catch (error) {
        if (error instanceof BranchSupervisorPasswordResetRateLimitError
          || error instanceof BranchSupervisorPasswordResetReauthenticationError
          || error instanceof BranchSupervisorPasswordResetUnavailableError) throw error;
        throw new BranchSupervisorPasswordResetUnavailableError();
      }

      const authorization = generateAuthorization();
      const issued = stepUpResultSchema.safeParse(await rpc("issue_branch_supervisor_password_reset_step_up", {
        p_actor_user_id: input.actorUserId,
        p_actor_session_id: input.actorSessionId,
        p_organization_id: input.organizationId,
        p_target_user_id: input.supervisorId,
        p_grant_secret_hash: sha256(authorization),
      }));
      if (!issued.success) throw new BranchSupervisorPasswordResetUnavailableError();
      return { authorization, expiresAt: issued.data.expires_at };
    },

    async reset(input) {
      await requireLiveSession(input.actorUserId, input.actorSessionId);
      await consumeRateLimit({ ...input, phase: "reset" });
      const begin = beginResultSchema.safeParse(await rpc("begin_branch_supervisor_password_reset", {
        p_actor_user_id: input.actorUserId,
        p_actor_session_id: input.actorSessionId,
        p_organization_id: input.organizationId,
        p_target_user_id: input.supervisorId,
        p_request_key_hash: sha256(input.idempotencyKey),
        p_step_up_secret_hash: sha256(input.authorization),
      }));
      if (!begin.success) throw new BranchSupervisorPasswordResetUnavailableError();
      if (begin.data.replayed) throw new BranchSupervisorPasswordResetReplayError();
      if (begin.data.status !== "pending_auth") throw new BranchSupervisorPasswordResetConflictError();

      const temporaryPassword = generatePassword();
      let authError: RpcError | null = null;
      try {
        ({ error: authError } = await client.auth.admin.updateUserById(input.supervisorId, { password: temporaryPassword }));
      } catch { authError = {}; }
      if (authError) {
        await recordFailure(begin.data.operation_id, input,
          authFailureIsDefinitive(authError) ? "auth_rejected" : "auth_outcome_unknown");
        throw new BranchSupervisorPasswordResetUnavailableError();
      }

      let finalized: { data: unknown; error: RpcError | null } = {
        data: null,
        error: { code: "transport_failure" },
      };
      try {
        finalized = await client.rpc("finalize_branch_supervisor_password_reset", {
          p_operation_id: begin.data.operation_id,
          p_actor_user_id: input.actorUserId,
          p_organization_id: input.organizationId,
          p_target_user_id: input.supervisorId,
        });
      } catch {
        // The transaction may have committed even if its response was lost.
        // Reconcile below; never repeat the Auth password mutation.
      }
      if (!finalized.error) {
        const parsed = operationResultSchema.safeParse(finalized.data);
        if (parsed.success && parsed.data.status === "succeeded") return { temporaryPassword };
      }

      const status = operationResultSchema.safeParse(await rpc("get_branch_supervisor_password_reset_status", {
        p_operation_id: begin.data.operation_id,
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_target_user_id: input.supervisorId,
      }));
      if (status.success && status.data.status === "succeeded") return { temporaryPassword };
      if (status.success && status.data.status === "pending_auth") {
        await recordFailure(begin.data.operation_id, input, "auth_outcome_unknown");
      }
      throw new BranchSupervisorPasswordResetUnavailableError();
    },
  };
}
