import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

const nonPersistentAuth = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
} as const;

const learnerCredentialSchema = z.object({
  employee_id: z.string().uuid(),
  organization_id: z.string().uuid(),
  branch_id: z.string().uuid(),
  display_name: z.string(),
  employee_code: z.string(),
  pin_hash: z.string().regex(/^\\x[0-9a-f]{64}$/),
  salt: z.string().regex(/^\\x[0-9a-f]{32}$/),
  kdf_version: z.literal(1),
  cost: z.literal(16384),
  block_size: z.literal(8),
  parallelization: z.literal(1),
  credential_version: z.string().uuid(),
  credential_status: z.enum(["active", "locked", "revoked"]),
  failed_attempt_count: z.number().int().nonnegative(),
  locked_until: z.string().nullable(),
}).strict();

const learnerSessionSchema = z.object({
  session_id: z.string().uuid(),
  organization_id: z.string().uuid(),
  organization_name: z.string(),
  organization_name_ar: z.string().nullable(),
  branch_id: z.string().uuid(),
  branch_name: z.string(),
  branch_name_ar: z.string().nullable(),
  employee_id: z.string().uuid(),
  display_name: z.string(),
  employee_code: z.string().nullable(),
  issued_at: z.string(),
  expires_at: z.string(),
  idle_expires_at: z.string(),
}).strict();

export type TrainingLearnerCredential = z.infer<typeof learnerCredentialSchema>;
export type TrainingLearnerSession = z.infer<typeof learnerSessionSchema>;

export type TrainingLearnerAuthService = {
  getLoginCredential(input: {
    organizationId: string;
    branchId: string;
    employeeCode: string;
  }): Promise<TrainingLearnerCredential | null>;
  completeLogin(input: {
    organizationId: string;
    branchId: string;
    employeeId: string;
    credentialVersion: string;
    authenticationSucceeded: boolean;
    tokenDigest: string;
  }): Promise<TrainingLearnerSession | null>;
  validateSession(tokenDigest: string): Promise<TrainingLearnerSession | null>;
  revokeSession(tokenDigest: string): Promise<void>;
};

export class TrainingLearnerAuthUnavailableError extends Error {
  constructor() {
    super("Training learner authentication is unavailable.");
    this.name = "TrainingLearnerAuthUnavailableError";
  }
}

export function createTrainingLearnerAuthService(
  url: string,
  secretKey: string,
): TrainingLearnerAuthService {
  const admin = createClient(url, secretKey, { auth: nonPersistentAuth });

  async function rpc(name: string, input: Record<string, unknown>) {
    const result = await admin.rpc(name, input);
    if (result.error || !Array.isArray(result.data)) {
      throw new TrainingLearnerAuthUnavailableError();
    }
    return result.data;
  }

  return {
    async getLoginCredential(input) {
      const rows = z.array(learnerCredentialSchema).max(1).parse(await rpc(
        "get_training_learner_login_credential",
        {
          target_organization_id: input.organizationId,
          target_branch_id: input.branchId,
          target_employee_code: input.employeeCode,
        },
      ));
      return rows[0] ?? null;
    },

    async completeLogin(input) {
      const rows = z.array(learnerSessionSchema).max(1).parse(await rpc(
        "complete_training_learner_login",
        {
          target_organization_id: input.organizationId,
          target_branch_id: input.branchId,
          target_employee_id: input.employeeId,
          expected_credential_version: input.credentialVersion,
          authentication_succeeded: input.authenticationSucceeded,
          new_token_digest: input.tokenDigest,
        },
      ));
      return rows[0] ?? null;
    },

    async validateSession(tokenDigest) {
      const rows = z.array(learnerSessionSchema).max(1).parse(await rpc(
        "validate_training_learner_session",
        { target_token_digest: tokenDigest },
      ));
      return rows[0] ?? null;
    },

    async revokeSession(tokenDigest) {
      const rows = z.array(z.object({ revoked: z.boolean() }).strict()).length(1).parse(await rpc(
        "revoke_training_learner_session",
        { target_token_digest: tokenDigest },
      ));
      void rows;
    },
  };
}
