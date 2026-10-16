import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import type { PinCredential } from "./admin";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { TrainingCredentialAdmin, TrainingCredentialStatus } from "./training-credential-admin";

const ids = {
  actor: "b3100000-0000-4000-8000-000000000001",
  organization: "b3100000-0000-4000-8000-000000000002",
  otherOrganization: "b3100000-0000-4000-8000-000000000003",
  branch: "b3100000-0000-4000-8000-000000000004",
  team: "b3100000-0000-4000-8000-000000000005",
  employee: "b3100000-0000-4000-8000-000000000006",
  assignment: "b3100000-0000-4000-8000-000000000007",
};
const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-training-admin-secret-placeholder-32-bytes",
});
const servers: ReturnType<typeof createServer>[] = [];
const active: TrainingCredentialStatus = { configured: true, status: "active", locked_until: null, updated_at: "2026-10-16T00:00:00Z" };
const revoked: TrainingCredentialStatus = { ...active, status: "revoked" };
const hashed: PinCredential = { pin_hash: `\\x${"11".repeat(32)}`, salt: `\\x${"22".repeat(16)}`, kdf_version: 1, cost: 16384, block_size: 8, parallelization: 1 };

function deps(options: { internalAdmin?: boolean; employeeStatus?: "active" | "inactive"; calls?: Record<string, unknown> } = {}): BackendDependencies {
  const calls = options.calls ?? {};
  const credentialAdmin: TrainingCredentialAdmin = {
    async getStatus(input) { calls.status = input; return active; },
    async store(input) { calls.store = input; return active; },
    async revoke(input) { calls.revoke = input; return revoked; },
  };
  return {
    authVerifier: { async verify(token) { return token === "valid" ? { userId: ids.actor, email: "admin@example.invalid" } : null; } },
    async checkReadiness() { return true; },
    createUserContext() { return {
      async getUserContext() { return null; },
      async isInternalAdmin() { return options.internalAdmin ?? true; },
      async hasOrganizationManagerAccess() { return false; },
      async validateActiveBranches() { return false; },
      async listActiveBranches() { return []; },
    }; },
    passwordChange: { async verifyCurrent() { return false; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { return { id: ids.actor }; }, async deleteUser() {}, async finalize() {} },
    managementAdmin: {
      async listUsers() { return { users: [], total: 0 }; },
      async listBranchTeamsForInternalAdmin(_actor, organizationId) {
        calls.teamsOrganization = organizationId;
        return organizationId === ids.organization ? [{
          team_id: ids.team, organization_id: ids.organization, team_name: "Kitchen", company_name: null,
          branch_id: ids.branch, branch_name: "Branch", branch_name_ar: null, branch_code: "BR",
          current_primary_assignment_id: null, supervisor_user_id: null, supervisor_name: null,
          supervisor_email: null, supervisor_role: null, backup_supervisors: [], active: true,
          operational_staff_count: 1,
          staff: [{ staff_id: ids.employee, display_name: "Employee", company_name: null, staff_code: "EMP-1", country_code: "SA", employment_status: options.employeeStatus ?? "active", assignment_id: ids.assignment, operational_team_id: ids.team, operational_roles: ["kitchen" as const] }],
        }] : [];
      },
    },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); }, async getPinCredential() { return null; } },
    pinCrypto: { async hash(pin) { calls.plaintextSeenByHasher = pin; return hashed; }, async verify() { return false; } },
    trainingCredentialAdmin: credentialAdmin,
  };
}

async function start(dependencies: BackendDependencies) {
  const server = createServer(createApp(config, dependencies)); servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}
afterEach(async () => Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve())))));
const path = (organization = ids.organization, employee = ids.employee) => `/api/v1/internal-admin/organizations/${organization}/training/employee-credentials/${employee}`;
const headers = { Authorization: "Bearer valid", "Content-Type": "application/json" };

describe("Internal Admin Personal Training PIN API", () => {
  it("returns only safe credential and authorized employee context", async () => {
    const origin = await start(deps());
    const response = await fetch(`${origin}${path()}?branch_id=${ids.branch}`, { headers });
    assert.equal(response.status, 200); assert.equal(response.headers.get("cache-control"), "private, no-store");
    const text = await response.text();
    assert.match(text, /"status":"active"/); assert.doesNotMatch(text, /pin_hash|salt|credential_version|failed_attempt_count|token_digest/i);
  });

  it("hashes and stores a matching PIN without returning it", async () => {
    const calls: Record<string, unknown> = {}; const origin = await start(deps({ calls }));
    const response = await fetch(`${origin}${path()}`, { method: "PUT", headers, body: JSON.stringify({ branch_id: ids.branch, pin: "2468", pin_confirmation: "2468" }) });
    assert.equal(response.status, 200);
    const stored = calls.store as { credential: PinCredential; employeeId: string };
    assert.equal(stored.employeeId, ids.employee); assert.deepEqual(stored.credential, hashed); assert.equal(calls.plaintextSeenByHasher, "2468");
    assert.doesNotMatch(await response.text(), /2468|pin_hash|salt/i);
  });

  it("revokes the selected employee credential", async () => {
    const calls: Record<string, unknown> = {}; const origin = await start(deps({ calls }));
    const response = await fetch(`${origin}${path()}`, { method: "DELETE", headers, body: JSON.stringify({ branch_id: ids.branch }) });
    assert.equal(response.status, 200); assert.deepEqual(calls.revoke, { actorUserId: ids.actor, organizationId: ids.organization, employeeId: ids.employee });
  });

  it("rejects unauthorized and cross-organization requests", async () => {
    const unauthorizedOrigin = await start(deps({ internalAdmin: false }));
    assert.equal((await fetch(`${unauthorizedOrigin}${path()}?branch_id=${ids.branch}`, { headers })).status, 403);
    const otherOrigin = await start(deps());
    assert.equal((await fetch(`${otherOrigin}${path(ids.otherOrganization)}?branch_id=${ids.branch}`, { headers })).status, 404);
  });

  it("rejects unknown, inactive, mismatched, and invalid employee inputs", async () => {
    const unknownOrigin = await start(deps());
    assert.equal((await fetch(`${unknownOrigin}${path(ids.organization, ids.actor)}?branch_id=${ids.branch}`, { headers })).status, 404);
    const inactiveOrigin = await start(deps({ employeeStatus: "inactive" }));
    assert.equal((await fetch(`${inactiveOrigin}${path()}`, { method: "PUT", headers, body: JSON.stringify({ branch_id: ids.branch, pin: "2468", pin_confirmation: "2468" }) })).status, 409);
    const invalidOrigin = await start(deps());
    assert.equal((await fetch(`${invalidOrigin}${path()}`, { method: "PUT", headers, body: JSON.stringify({ branch_id: ids.branch, pin: "2468", pin_confirmation: "1357" }) })).status, 400);
  });
});
