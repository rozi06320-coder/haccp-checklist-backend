import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError, ChecklistInputError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const other = "17000000-0000-4000-8000-000000000003";
const branch = "27000000-0000-4000-8000-000000000001";
const otherBranch = "27000000-0000-4000-8000-000000000002";
const org = "37000000-0000-4000-8000-000000000001";
const calls: Array<{ name: string; input: unknown }> = [];
let mode: "ok" | "access" | "input" = "ok";

const persistence = {
  async updateInventoryBeefProductionLabel(input: { actorUserId: string; branchId: string; label: string }) {
    calls.push({ name: "updateInventoryBeefProductionLabel", input });
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "input") throw new ChecklistInputError();
    return { beef_production_label: input.label };
  },
  async getOverview() { throw new Error("unused"); },
  async getCurrentState() { throw new Error("unused"); },
  async saveDraft() { throw new Error("unused"); },
  async saveHygieneDraft() { throw new Error("unused"); },
  async submitOpening() { throw new Error("unused"); },
  async submitHygiene() { throw new Error("unused"); },
  async listSupervisor() { throw new Error("unused"); },
  async getReport() { throw new ChecklistAccessError(); },
  async listManagedReports() { return { reports: [], page: 1, page_size: 20, total: 0 }; },
  async listManagedIssues() { return { issues: [], page: 1, page_size: 20, total: 0 }; },
  async getManagedIssue() { throw new Error("unused"); },
} as BackendDependencies["checklistPersistence"];

function deps(): BackendDependencies {
  return {
    checkReadiness: async () => true,
    checklistPersistence: persistence,
    passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
    provisioningAdmin: { createUser: async () => ({ id: supervisor }), deleteUser: async () => {}, finalize: async () => {} },
    managementAdmin: { listUsers: async () => ({ users: [], total: 0 }) },
    branchManagementAdmin: { listBranches: async () => [], listStaff: async () => [], getPinMetadata: async () => ({ configured: false, updated_at: null, updated_by_name: null }), storePin: async () => ({ configured: false, updated_at: null, updated_by_name: null }), getPinCredential: async () => null },
    pinCrypto: { hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }), verify: async () => false, issueGrant: () => "", verifyGrant: async () => false },
    authVerifier: {
      verify: async (token) =>
        token === "supervisor"
          ? { userId: supervisor, email: "s@example.invalid" }
          : token === "manager"
            ? { userId: manager, email: "m@example.invalid" }
            : token === "other"
              ? { userId: other, email: "o@example.invalid" }
              : null,
    },
    createUserContext: (token) => ({
      getUserContext: async () =>
        token === "supervisor"
          ? { id: supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] }
          : token === "manager"
            ? { id: manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }] }
            : { id: other, full_name: "Other", must_change_password: false, disabled: false, branches: [], managed_organizations: [] },
      isInternalAdmin: async () => false,
      hasOrganizationManagerAccess: async () => false,
      validateActiveBranches: async () => false,
      listActiveBranches: async () => [],
    }),
  };
}

const config: BackendConfig = { nodeEnv: "test", host: "127.0.0.1", port: 1, trustProxy: false, supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" }, dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests" };
let server: Server;
let origin: string;

async function request(path: string, token?: string, init: RequestInit = {}) {
  return fetch(origin + path, { ...init, headers: { ...(token ? { Authorization: `Bearer ${token}` } : { "x-no-auth": "1" }), ...(init.headers ?? {}) } });
}

describe("Inventory Items Beef Production label API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { calls.length = 0; mode = "ok"; });

  it("renames only the branch Beef Production label through supervisor persistence", async () => {
    const response = await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-label`, "supervisor", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ label: "  Hunch   Sauce Production  " }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { beef_production_label: "Hunch Sauce Production" });
    assert.deepEqual(calls, [{
      name: "updateInventoryBeefProductionLabel",
      input: { actorUserId: supervisor, branchId: branch, label: "Hunch Sauce Production" },
    }]);
  });

  it("rejects empty and overlong labels before persistence", async () => {
    for (const label of ["   ", "x".repeat(121)]) {
      const response = await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-label`, "supervisor", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ label }),
      });
      assert.equal(response.status, 400);
    }
    assert.deepEqual(calls, []);
  });

  it("denies non-supervisor and wrong-branch callers without broadening access", async () => {
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-label`, undefined, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ label: "New Label" }) })).status, 401);
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-label`, "manager", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ label: "New Label" }) })).status, 403);
    assert.equal((await request(`/api/v1/supervisor/branches/${otherBranch}/inventory-items/beef-production-label`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ label: "New Label" }) })).status, 403);
  });
});
