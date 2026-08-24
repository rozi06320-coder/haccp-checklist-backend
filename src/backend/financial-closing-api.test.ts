import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError, ChecklistConflictError, ChecklistInputError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "16000000-0000-4000-8000-000000000001";
const manager = "16000000-0000-4000-8000-000000000002";
const other = "16000000-0000-4000-8000-000000000003";
const branch = "26000000-0000-4000-8000-000000000001";
const otherBranch = "26000000-0000-4000-8000-000000000002";
const org = "36000000-0000-4000-8000-000000000001";
const reportId = "46000000-0000-4000-8000-000000000001";
const itemKeys = ["sales_closing", "collections", "exceptions", "purchases", "transfers", "production", "waste", "petty_cash", "pending_documents", "exception_escalation"] as const;
const calls: Array<{ name: string; input: unknown }> = [];

function current(overrides: Record<string, unknown> = {}) {
  return {
    report_id: null,
    branch_id: branch,
    business_date: "2026-08-24",
    state: "draft",
    revision: 0,
    branch_name: "Financial Branch",
    branch_code: "HUN-RUH-001",
    branch_city: "Riyadh",
    submitted_at: null,
    submitted_by_user_id: null,
    submitted_by_name_snapshot: null,
    updated_at: null,
    completion: 0,
    not_completed_count: 0,
    items: itemKeys.map((item_key) => ({ item_key, status: null, reason: "", follow_up: "" })),
    ...overrides,
  };
}

const completeItems = itemKeys.map((item_key) => ({ item_key, status: "completed", reason: "", follow_up: "" }));
const persistence = {
  async getFinancialClosingCurrentState(actorUserId: string, branchId: string) {
    calls.push({ name: "current", input: { actorUserId, branchId } });
    if (actorUserId !== supervisor || branchId !== branch) throw new ChecklistAccessError();
    return current();
  },
  async saveFinancialClosingDraft(input: unknown) {
    calls.push({ name: "draft", input });
    const branchId = (input as { branchId: string }).branchId;
    if (branchId !== branch) throw new ChecklistAccessError();
    return current({ revision: 1 });
  },
  async submitFinancialClosing(input: unknown) {
    calls.push({ name: "submit", input });
    const payload = input as { branchId: string; expectedRevision: number; items: Array<{ status: string | null }> };
    if (payload.branchId !== branch) throw new ChecklistAccessError();
    if (payload.expectedRevision === 99) throw new ChecklistConflictError();
    if (payload.items.some((item) => item.status === null)) throw new ChecklistInputError();
    return current({ report_id: reportId, state: "submitted", revision: 2, completion: 100, submitted_at: "2026-08-24T20:43:00.000Z", submitted_by_user_id: supervisor, submitted_by_name_snapshot: "Supervisor" });
  },
  async listManagedFinancialClosingReports(input: unknown) {
    calls.push({ name: "manager-list", input });
    return { reports: [{ id: reportId, branch_id: branch, branch_name: "Financial Branch", branch_code: "HUN-RUH-001", checklist_type: "financial_closing", business_date: "2026-08-24", submitted_at: "2026-08-24T20:43:00.000Z", submitted_by: "Supervisor", completion: 100, issue_count: 0, status: "compliant" }], page: 1, page_size: 20, total: 1 };
  },
  async getOverview() { throw new Error("unused"); },
  async getManagementOverview() { throw new Error("unused"); },
  async getCurrentState() { throw new Error("unused"); },
  async saveDraft() { throw new Error("unused"); },
  async saveHygieneDraft() { throw new Error("unused"); },
  async submitOpening() { throw new Error("unused"); },
  async submitHygiene() { throw new Error("unused"); },
  async listSupervisor() { throw new Error("unused"); },
  async getReport() { throw new ChecklistAccessError(); },
  async listManagedReports() { return { reports: [], page: 1, page_size: 20, total: 0 }; },
  async listManagedIssues() { throw new Error("unused"); },
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
    pinCrypto: { hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }), verify: async () => false, issueGrant: () => "", verifyGrant: () => false },
    authVerifier: { verify: async (token) => token === "supervisor" ? { userId: supervisor, email: "s@example.invalid" } : token === "manager" ? { userId: manager, email: "m@example.invalid" } : token === "other" ? { userId: other, email: "o@example.invalid" } : null },
    createUserContext: (token) => ({
      getUserContext: async () => token === "supervisor"
        ? { id: supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Financial Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] }
        : token === "manager"
          ? { id: manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }] }
          : { id: other, full_name: "Other", must_change_password: false, disabled: false, branches: [], managed_organizations: [] },
      isInternalAdmin: async () => false,
      hasOrganizationManagerAccess: async (_actorUserId, organizationId) => token === "manager" && organizationId === org,
      validateActiveBranches: async () => true,
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

describe("Financial Closing API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { calls.length = 0; });

  it("requires Supervisor branch authority for current-state", async () => {
    const path = `/api/v1/supervisor/branches/${branch}/checklists/financial_closing/current-state`;
    assert.equal((await request(path)).status, 401);
    assert.equal((await request(path, "manager")).status, 403);
    const response = await request(path, "supervisor");
    assert.equal(response.status, 200);
    assert.equal((await response.json()).current.items.length, 10);
    assert.deepEqual(calls.at(-1), { name: "current", input: { actorUserId: supervisor, branchId: branch } });
  });

  it("saves draft without accepting client organization, business date, or submitter fields", async () => {
    const response = await request(`/api/v1/supervisor/branches/${branch}/checklists/financial_closing/draft`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ expected_revision: 0, items: [{ item_key: "sales_closing", status: null, reason: "", follow_up: "" }] }) });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), { name: "draft", input: { actorUserId: supervisor, branchId: branch, expectedRevision: 0, items: [{ item_key: "sales_closing", status: null, reason: "", follow_up: "" }] } });
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/financial_closing/draft`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ expected_revision: 0, organization_id: org, business_date: "2026-01-01", items: [] }) })).status, 400);
  });

  it("requires idempotency header and maps validation/conflict errors safely on submit", async () => {
    const path = `/api/v1/supervisor/branches/${branch}/checklists/financial_closing/submit`;
    assert.equal((await request(path, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ expected_revision: 0, items: completeItems }) })).status, 400);
    assert.equal((await request(path, "supervisor", { method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": "56000000-0000-4000-8000-000000000001" }, body: JSON.stringify({ expected_revision: 0, items: completeItems.map((item, index) => index === 0 ? { ...item, status: null } : item) }) })).status, 422);
    assert.equal((await request(path, "supervisor", { method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": "56000000-0000-4000-8000-000000000002" }, body: JSON.stringify({ expected_revision: 99, items: completeItems }) })).status, 409);
    const response = await request(path, "supervisor", { method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": "56000000-0000-4000-8000-000000000003" }, body: JSON.stringify({ expected_revision: 0, items: completeItems }) });
    assert.equal(response.status, 201);
    assert.equal((await response.json()).current.state, "submitted");
  });

  it("keeps Manager access read-only through reports", async () => {
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/financial_closing/draft`, "manager", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ expected_revision: 0, items: [] }) })).status, 403);
    const response = await request(`/api/v1/management/organizations/${org}/reports?checklist_type=financial_closing`, "manager");
    assert.equal(response.status, 200);
    assert.equal((await response.json()).reports[0].branch_code, "HUN-RUH-001");
    assert.equal((await request(`/api/v1/supervisor/branches/${otherBranch}/checklists/financial_closing/current-state`, "supervisor")).status, 403);
  });
});
