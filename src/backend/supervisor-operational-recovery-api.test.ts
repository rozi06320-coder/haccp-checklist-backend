import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { createApp } from "./app";
import {
  AdminAccessError,
  AdminConflictError,
  type ManagementAdmin,
} from "./admin";
import type { BackendDependencies } from "./dependencies";

const ids = {
  actor: "11000000-0000-4000-8000-000000000001",
  organization: "22000000-0000-4000-8000-000000000001",
  user: "33000000-0000-4000-8000-000000000001",
  branch: "44000000-0000-4000-8000-000000000001",
  assignment: "55000000-0000-4000-8000-000000000001",
};

const config = {
  internalAdminEmail: "admin@example.invalid",
  supabaseUrl: "http://127.0.0.1:54321",
  supabaseSecretKey: "test-secret",
};

function dependencies(overrides: {
  internalAdmin?: boolean;
  recoveryError?: Error;
  classificationError?: Error;
} = {}): BackendDependencies {
  const managementAdmin: ManagementAdmin = {
    async restoreSupervisorOperationalAccessForInternalAdmin(input) {
      if (overrides.recoveryError) throw overrides.recoveryError;
      return {
        organization_id: input.organizationId,
        user_id: input.userId,
        classification: "training_supervisor",
        branch_count: input.branchIds.length,
        restored_assignment_count: input.historicalAssignmentIds.length,
      };
    },
    async setSupervisorClassificationForInternalAdmin(input) {
      if (overrides.classificationError) throw overrides.classificationError;
      return {
        organization_id: input.organizationId,
        user_id: input.userId,
        classification: input.classification,
      };
    },
  };
  return {
    authVerifier: { async verify(token) { return token === "valid" ? { userId: ids.actor, email: "admin@example.invalid" } : null; } },
    async checkReadiness() { return true; },
    createUserContext() {
      return {
        async getUserContext() { return { id: ids.actor, full_name: "Admin", must_change_password: false, disabled: false, branches: [], managed_organizations: [] }; },
        async isInternalAdmin() { return overrides.internalAdmin !== false; },
        async hasOrganizationManagerAccess() { return false; },
        async validateActiveBranches() { return true; },
        async listActiveBranches() { return []; },
      };
    },
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { return { id: ids.user }; }, async deleteUser() {}, async finalize() {} },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; }, async storePin() {}, async getPinCredential() { return null; } },
    pinCrypto: { hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }), verify: async () => false, issueGrant: () => "", verifyGrant: () => false },
    managementAdmin,
  };
}

async function request(path: string, options: RequestInit = {}, deps = dependencies()) {
  const server = createServer(createApp(config, deps));
  await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
  try {
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    return await fetch(`http://127.0.0.1:${address.port}${path}`, {
      ...options,
      headers: { Authorization: "Bearer valid", "Content-Type": "application/json", ...(options.headers ?? {}) },
    });
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
}

test("Supervisor operational recovery API", async (t) => {
  await t.test("restores access and returns classification", async () => {
    const response = await request(`/api/v1/internal-admin/organizations/${ids.organization}/supervisors/${ids.user}/restore-operational-access`, {
      method: "POST",
      body: JSON.stringify({ branch_ids: [ids.branch], historical_assignment_ids: [ids.assignment] }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { recovery: {
      organization_id: ids.organization,
      user_id: ids.user,
      classification: "training_supervisor",
      branch_count: 1,
      restored_assignment_count: 1,
    } });
  });

  await t.test("maps authorization and conflict failures", async () => {
    assert.equal((await request(`/api/v1/internal-admin/organizations/${ids.organization}/supervisors/${ids.user}/classification`, { method: "PATCH", body: JSON.stringify({ classification: "training_supervisor" }) }, dependencies({ internalAdmin: false }))).status, 403);
    assert.equal((await request(`/api/v1/internal-admin/organizations/${ids.organization}/supervisors/${ids.user}/restore-operational-access`, { method: "POST", body: JSON.stringify({ branch_ids: [ids.branch], historical_assignment_ids: [] }) }, dependencies({ recoveryError: new AdminConflictError() }))).status, 409);
    assert.equal((await request(`/api/v1/internal-admin/organizations/${ids.organization}/supervisors/${ids.user}/classification`, { method: "PATCH", body: JSON.stringify({ classification: "supervisor" }) }, dependencies({ classificationError: new AdminAccessError() }))).status, 403);
  });

  await t.test("rejects malformed recovery payload", async () => {
    const response = await request(`/api/v1/internal-admin/organizations/${ids.organization}/supervisors/${ids.user}/restore-operational-access`, { method: "POST", body: JSON.stringify({ branch_ids: [ids.branch], historical_assignment_ids: ["not-a-uuid"] }) });
    assert.equal(response.status, 400);
  });
});
