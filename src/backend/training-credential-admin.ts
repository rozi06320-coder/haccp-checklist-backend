import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  AdminAccessError,
  AdminConflictError,
  AdminInputError,
  AdminNotFoundError,
  AdminOperationError,
  type PinCredential,
} from "./admin";

const nonPersistentAuth = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
} as const;

const credentialRowSchema = z.object({
  employee_id: z.string().uuid(),
  organization_id: z.string().uuid(),
  status: z.enum(["active", "locked", "revoked"]),
  credential_version: z.string().uuid(),
  failed_attempt_count: z.number().int().nonnegative(),
  locked_until: z.string().nullable(),
  created_at: z.string(),
  updated_at: z.string(),
}).strict();

const credentialStatusRowSchema = credentialRowSchema.extend({
  configured: z.boolean(),
  status: z.enum(["active", "locked", "revoked"]).nullable(),
  credential_version: z.string().uuid().nullable(),
  created_at: z.string().nullable(),
  updated_at: z.string().nullable(),
}).strict();

export type TrainingCredentialStatus = {
  configured: boolean;
  status: "active" | "locked" | "revoked" | null;
  locked_until: string | null;
  updated_at: string | null;
};

export type TrainingCredentialAdmin = {
  getStatus(input: { actorUserId: string; organizationId: string; employeeId: string }): Promise<TrainingCredentialStatus>;
  store(input: { actorUserId: string; organizationId: string; employeeId: string; credential: PinCredential }): Promise<TrainingCredentialStatus>;
  revoke(input: { actorUserId: string; organizationId: string; employeeId: string }): Promise<TrainingCredentialStatus>;
};

export function createTrainingCredentialAdmin(url: string, secretKey: string): TrainingCredentialAdmin {
  const admin = createClient(url, secretKey, { auth: nonPersistentAuth });

  async function rpc(name: string, input: Record<string, unknown>) {
    const result = await admin.rpc(name, input);
    if (result.error) {
      if (result.error.code === "42501") throw new AdminAccessError();
      if (result.error.code === "P0002") throw new AdminNotFoundError();
      if (result.error.code === "22023") throw new AdminInputError();
      if (["23505", "23514", "40001"].includes(result.error.code)) throw new AdminConflictError();
      throw new AdminOperationError();
    }
    if (!Array.isArray(result.data)) throw new AdminOperationError();
    return result.data;
  }

  const safeStatus = (row: z.infer<typeof credentialStatusRowSchema>): TrainingCredentialStatus => ({
    configured: row.configured,
    status: row.status,
    locked_until: row.locked_until,
    updated_at: row.updated_at,
  });

  const safeStored = (row: z.infer<typeof credentialRowSchema>): TrainingCredentialStatus => ({
    configured: true,
    status: row.status,
    locked_until: row.locked_until,
    updated_at: row.updated_at,
  });

  return {
    async getStatus(input) {
      const rows = z.array(credentialStatusRowSchema).length(1).parse(await rpc(
        "get_internal_admin_operational_staff_training_credential_status",
        {
          actor_user_id: input.actorUserId,
          target_organization_id: input.organizationId,
          target_employee_id: input.employeeId,
        },
      ));
      return safeStatus(rows[0]);
    },

    async store(input) {
      const rows = z.array(credentialRowSchema).length(1).parse(await rpc(
        "store_internal_admin_operational_staff_training_credential",
        {
          actor_user_id: input.actorUserId,
          target_organization_id: input.organizationId,
          target_employee_id: input.employeeId,
          new_pin_hash: input.credential.pin_hash,
          new_salt: input.credential.salt,
          new_kdf_version: input.credential.kdf_version,
          new_cost: input.credential.cost,
          new_block_size: input.credential.block_size,
          new_parallelization: input.credential.parallelization,
        },
      ));
      return safeStored(rows[0]);
    },

    async revoke(input) {
      const rows = z.array(credentialRowSchema).length(1).parse(await rpc(
        "revoke_internal_admin_operational_staff_training_credential",
        {
          actor_user_id: input.actorUserId,
          target_organization_id: input.organizationId,
          target_employee_id: input.employeeId,
        },
      ));
      return safeStored(rows[0]);
    },
  };
}
