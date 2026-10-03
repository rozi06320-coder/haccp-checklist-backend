import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError, ChecklistConflictError, ChecklistInputError, ChecklistNotFoundError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const other = "17000000-0000-4000-8000-000000000003";
const branch = "27000000-0000-4000-8000-000000000001";
const otherBranch = "27000000-0000-4000-8000-000000000002";
const org = "37000000-0000-4000-8000-000000000001";
const itemUsageId = "47000000-0000-4000-8000-000000000001";
const beefRowId = "47000000-0000-4000-8000-000000000002";
const calls: Array<{ name: string; input: unknown }> = [];
let mode: "ok" | "access" | "conflict" | "input" | "not-found" = "ok";

type BeefLabels = { russian_label: string | null; australian_label: string | null; hunch_sauce_label: string | null };

const inventoryCurrent = {
  report_id: "57000000-0000-4000-8000-000000000001",
  business_date: "2026-10-02",
  inventory_month: "2026-10-01",
  state: "draft" as const,
  updated_at: "2026-10-02T12:00:00.000Z",
  submitted_at: null,
  beef_production_labels: { russian_label: null, australian_label: null, hunch_sauce_label: null },
  beef_rows: [],
  item_usage: { usage_month: "2026-10-01", items: [] },
};

const persistence = {
  async updateInventoryBeefProductionFieldLabels(input: { actorUserId: string; branchId: string; labels: BeefLabels }) {
    calls.push({ name: "updateInventoryBeefProductionFieldLabels", input });
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "input") throw new ChecklistInputError();
    return { beef_production_labels: input.labels };
  },
  async updateInventoryBeefProductionRow(input: { actorUserId: string; branchId: string; rowId: string; expectedUpdatedAt: string; rowValues: Record<string, string> }) {
    calls.push({ name: "updateInventoryBeefProductionRow", input });
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "conflict") throw new ChecklistConflictError("40001");
    if (mode === "input") throw new ChecklistInputError();
    if (mode === "not-found") throw new ChecklistNotFoundError();
    return inventoryCurrent;
  },
  async deleteInventoryItemUsageItem(input: { actorUserId: string; branchId: string; itemUsageId: string }) {
    calls.push({ name: "deleteInventoryItemUsageItem", input });
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "conflict") throw new ChecklistConflictError("23505");
    return inventoryCurrent;
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

describe("Inventory Items Beef Production field labels API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { calls.length = 0; mode = "ok"; });

  it("renames only the branch Beef Production field labels through supervisor persistence", async () => {
    const response = await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-labels`, "supervisor", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ russian_label: "  Russian   Beef  ", australian_label: "Aussie Beef", hunch_sauce_label: "  " }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { beef_production_labels: { russian_label: "Russian Beef", australian_label: "Aussie Beef", hunch_sauce_label: null } });
    assert.deepEqual(calls, [{
      name: "updateInventoryBeefProductionFieldLabels",
      input: { actorUserId: supervisor, branchId: branch, labels: { russian_label: "Russian Beef", australian_label: "Aussie Beef", hunch_sauce_label: null } },
    }]);
  });

  it("rejects overlong labels before persistence while allowing blank clear-to-default values", async () => {
    const blank = await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-labels`, "supervisor", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ russian_label: " ", australian_label: "", hunch_sauce_label: null }),
    });
    assert.equal(blank.status, 200);
    assert.deepEqual((await blank.json()).beef_production_labels, { russian_label: null, australian_label: null, hunch_sauce_label: null });
    calls.length = 0;
    const response = await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-labels`, "supervisor", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ russian_label: "x".repeat(121), australian_label: null, hunch_sauce_label: null }),
    });
    assert.equal(response.status, 400);
    assert.deepEqual(calls, []);
  });

  it("denies non-supervisor and wrong-branch callers without broadening access", async () => {
    const body = JSON.stringify({ russian_label: "Russian", australian_label: "Australian", hunch_sauce_label: "Sauce" });
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-labels`, undefined, { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 401);
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production-labels`, "manager", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 403);
    assert.equal((await request(`/api/v1/supervisor/branches/${otherBranch}/inventory-items/beef-production-labels`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 403);
  });

  it("updates one saved Beef Production row through the narrow authoritative route", async () => {
    const body = {
      expected_updated_at: "2026-10-02T12:00:00.000Z",
      row_values: { russian_kg: "11", australian_kg: "4", fat_kg: "1", ready_patty: "20", hunch_sauce_kg: "3", wastage_grams: "100" },
    };
    const response = await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production/${beefRowId}`, "supervisor", {
      method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { current: inventoryCurrent });
    assert.deepEqual(calls, [{ name: "updateInventoryBeefProductionRow", input: { actorUserId: supervisor, branchId: branch, rowId: beefRowId, expectedUpdatedAt: body.expected_updated_at, rowValues: body.row_values } }]);
  });

  it("maps saved Beef update validation, stale, missing, and access failures safely", async () => {
    const body = JSON.stringify({ expected_updated_at: "2026-10-02T12:00:00.000Z", row_values: { russian_kg: "11", australian_kg: "4", fat_kg: "1", ready_patty: "20", hunch_sauce_kg: "3", wastage_grams: "100" } });
    const path = `/api/v1/supervisor/branches/${branch}/inventory-items/beef-production/${beefRowId}`;
    mode = "conflict";
    const conflict = await request(path, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body });
    assert.equal(conflict.status, 409);
    assert.doesNotMatch(JSON.stringify(await conflict.json()), /40001|postgres|database/i);
    mode = "input";
    assert.equal((await request(path, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 422);
    mode = "not-found";
    assert.equal((await request(path, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 404);
    mode = "access";
    assert.equal((await request(path, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 403);
    mode = "ok";
    assert.equal((await request(path, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ expected_updated_at: "bad", row_values: {} }) })).status, 400);
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/beef-production/not-a-uuid`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 400);
  });

  it("deletes an authorized empty Item Usage row and returns authoritative state", async () => {
    const response = await request(`/api/v1/supervisor/branches/${branch}/inventory-items/item-usage/${itemUsageId}`, "supervisor", { method: "DELETE" });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { current: inventoryCurrent });
    assert.deepEqual(calls, [{
      name: "deleteInventoryItemUsageItem",
      input: { actorUserId: supervisor, branchId: branch, itemUsageId },
    }]);
  });

  it("rejects populated/closed conflicts and unauthorized Item Usage deletes safely", async () => {
    mode = "conflict";
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/item-usage/${itemUsageId}`, "supervisor", { method: "DELETE" })).status, 409);
    mode = "ok";
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/item-usage/not-a-uuid`, "supervisor", { method: "DELETE" })).status, 400);
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/inventory-items/item-usage/${itemUsageId}`, "manager", { method: "DELETE" })).status, 403);
    assert.equal((await request(`/api/v1/supervisor/branches/${otherBranch}/inventory-items/item-usage/${itemUsageId}`, "supervisor", { method: "DELETE" })).status, 403);
  });
});
