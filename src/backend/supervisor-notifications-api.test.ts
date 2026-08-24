import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const other = "17000000-0000-4000-8000-000000000002";
const manager = "17000000-0000-4000-8000-000000000003";
const branch = "27000000-0000-4000-8000-000000000001";
const org = "37000000-0000-4000-8000-000000000001";
const notificationId = "47000000-0000-4000-8000-000000000001";
const calls: Array<{ name: string; input: unknown }> = [];

function notification(overrides: Record<string, unknown> = {}) {
  return {
    id: notificationId,
    organization_id: org,
    branch_id: branch,
    business_date: "2026-08-24",
    notification_type: "financial_closing_overdue",
    checklist_type: "financial_closing",
    rule_key: "financial_closing_0200_overdue",
    severity: "urgent",
    read_at: null,
    resolved_at: null,
    created_at: "2026-08-24T23:00:00.000Z",
    payload: { checklist_type: "financial_closing", rule_key: "financial_closing_0200_overdue", branch_name: "Branch", branch_code: "HUN-RUH-001", reminder_time: "02:00:00" },
    ...overrides,
  };
}

const persistence = {
  async listSupervisorNotifications(actorUserId: string) {
    calls.push({ name: "list", input: { actorUserId } });
    if (actorUserId !== supervisor) throw new ChecklistAccessError();
    return [notification(), notification({ id: "47000000-0000-4000-8000-000000000002", rule_key: "oil_tracking_1800", notification_type: "oil_tracking_reminder", checklist_type: "oil_tracking", severity: "warning", read_at: "2026-08-24T18:05:00.000Z" })];
  },
  async markSupervisorNotificationRead(actorUserId: string, id: string) {
    calls.push({ name: "read", input: { actorUserId, id } });
    if (actorUserId !== supervisor || id !== notificationId) throw new ChecklistAccessError();
    return [notification({ read_at: "2026-08-24T23:02:00.000Z" })];
  },
  async getOverview() { throw new Error("unused"); },
  async getManagementOverview() { throw new Error("unused"); },
  async getCurrentState() { throw new Error("unused"); },
  async saveDraft() { throw new Error("unused"); },
  async saveHygieneDraft() { throw new Error("unused"); },
  async submitOpening() { throw new Error("unused"); },
  async submitHygiene() { throw new Error("unused"); },
  async listSupervisor() { throw new Error("unused"); },
  async getReport() { throw new Error("unused"); },
  async listManagedReports() { throw new Error("unused"); },
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
    authVerifier: { verify: async (token) => token === "supervisor" ? { userId: supervisor, email: "s@example.invalid" } : token === "other" ? { userId: other, email: "o@example.invalid" } : token === "manager" ? { userId: manager, email: "m@example.invalid" } : null },
    createUserContext: (token) => ({
      getUserContext: async () => token === "supervisor"
        ? { id: supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] }
        : token === "manager"
          ? { id: manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }] }
          : { id: other, full_name: "Other", must_change_password: false, disabled: false, branches: [], managed_organizations: [] },
      isInternalAdmin: async () => false,
      hasOrganizationManagerAccess: async () => false,
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

describe("Supervisor notifications API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { calls.length = 0; });

  it("evaluates and lists only the authenticated Supervisor notification rows", async () => {
    assert.equal((await request("/api/v1/supervisor/notifications")).status, 401);
    assert.equal((await request("/api/v1/supervisor/notifications", "manager")).status, 403);
    const response = await request("/api/v1/supervisor/notifications", "supervisor");
    assert.equal(response.status, 200);
    const body = await response.json() as { notifications: unknown[]; unread_count: number };
    assert.equal(body.notifications.length, 2);
    assert.equal(body.unread_count, 1);
    assert.deepEqual(calls.at(-1), { name: "list", input: { actorUserId: supervisor } });
  });

  it("marks only the current Supervisor notification as read", async () => {
    const response = await request(`/api/v1/supervisor/notifications/${notificationId}/read`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: "{}" });
    assert.equal(response.status, 200);
    const body = await response.json() as { notification: { read_at: string | null } };
    assert.ok(body.notification.read_at);
    assert.deepEqual(calls.at(-1), { name: "read", input: { actorUserId: supervisor, id: notificationId } });
    assert.equal((await request(`/api/v1/supervisor/notifications/${notificationId}/read`, "other", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: "{}" })).status, 403);
  });
});
