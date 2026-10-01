import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { MaintenancePushService } from "./maintenance-push";
import { OperationalConflictError, purchaseRequestCreateRequestHash } from "./operational";

const supervisor = "18000000-0000-4000-8000-000000000001";
const purchaser = "18000000-0000-4000-8000-000000000002";
const branch = "28000000-0000-4000-8000-000000000001";
const organization = "38000000-0000-4000-8000-000000000001";
const requestId = "48000000-0000-4000-8000-000000000001";
const itemId = "58000000-0000-4000-8000-000000000001";
const key = "68000000-0000-4000-8000-000000000001";
const config: BackendConfig = { nodeEnv: "test", host: "127.0.0.1", port: 1, trustProxy: false, supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" }, dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests" };
const replay = new Map<string, string>();
let server: Server;
let origin: string;
let dispatches = 0;
let failPush = false;
let registeredActor: string | null = null;

const purchaseRequest = {
  id: requestId,
  organization_id: organization,
  branch_id: branch,
  branch_name: "Branch A",
  branch_code: "A",
  requested_by: supervisor,
  requested_by_name: "Supervisor",
  category: "kitchen" as const,
  status: "submitted" as const,
  notes: null,
  created_at: "2026-10-01T08:00:00.000Z",
  updated_at: "2026-10-01T08:00:00.000Z",
  items: [{ id: itemId, purchase_request_id: requestId, item_name: "Gloves", quantity: "1", unit: "box", notes: null, sort_order: 1, created_at: "2026-10-01T08:00:00.000Z" }],
};

const push: MaintenancePushService = {
  getPublicKey: () => "public-key",
  async registerSubscription() { throw new Error("unused"); },
  async registerSupervisorSubscription() { throw new Error("unused"); },
  async registerPurchasingSubscription(input) {
    registeredActor = input.actorUserId;
    return { subscription: { id: "78000000-0000-4000-8000-000000000001", user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: null } };
  },
  async disableSubscription(input) { return { subscription: { id: "78000000-0000-4000-8000-000000000001", user_id: purchaser, endpoint: input.endpoint, disabled_at: new Date().toISOString() } }; },
  async notifyMaintenanceIssueCreated() {},
  async notifyPurchaseRequestCreated() {
    dispatches += 1;
    if (failPush) throw new Error("provider unavailable");
  },
  async notifyDueSupervisorChecklistReminders() { return { evaluated_at: new Date().toISOString(), deliveries_attempted: 0, deliveries_sent: 0 }; },
};

function dependencies(): BackendDependencies {
  return {
    async checkReadiness() { return true; },
    authVerifier: { async verify(token) {
      if (token === "supervisor") return { userId: supervisor, email: "supervisor@example.invalid" };
      if (token === "purchasing") return { userId: purchaser, email: "buyer@example.invalid" };
      return null;
    } },
    createUserContext: (token) => ({
      async getUserContext() {
        if (token === "supervisor") return { id: supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch A", organization_id: organization, role: "branch_manager" as const }], managed_organizations: [] };
        return { id: purchaser, full_name: "Buyer", must_change_password: false, disabled: false, branches: [], managed_organizations: [], purchasing_organizations: [{ id: organization, name: "Org", role: "purchasing" as const }] };
      },
      async hasOrganizationManagerAccess() { return false; },
      async validateActiveBranches() { return false; },
      async listActiveBranches() { return []; },
    }),
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { throw new Error("unused"); }, async deleteUser() {}, async finalize() {} },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); }, async getPinCredential() { return null; } },
    pinCrypto: { async hash() { throw new Error("unused"); }, async verify() { return false; }, issueGrant() { return "unused"; }, verifyGrant() { return false; } },
    operationalAdmin: {
      async createSupervisorPurchaseRequest(input) {
        const hash = purchaseRequestCreateRequestHash(input);
        const prior = replay.get(input.idempotencyKey);
        if (prior && prior !== hash) throw new OperationalConflictError();
        const created = !prior;
        replay.set(input.idempotencyKey, hash);
        return { created, purchase_request: { ...purchaseRequest, category: input.category, notes: input.notes } };
      },
    } as BackendDependencies["operationalAdmin"],
    maintenancePush: push,
  };
}

async function request(path: string, token: string, init: RequestInit = {}) {
  return fetch(origin + path, { ...init, headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) } });
}

function create(body: Record<string, unknown>, idempotencyKey = key) {
  return request(`/api/v1/supervisor/branches/${branch}/purchase-requests`, "supervisor", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Idempotency-Key": idempotencyKey },
    body: JSON.stringify(body),
  });
}

describe("Purchasing push API", () => {
  before(async () => {
    server = createServer(createApp(config, dependencies()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { replay.clear(); dispatches = 0; failPush = false; registeredActor = null; });

  it("dispatches once for create and not for an idempotent replay", async () => {
    const body = { category: "kitchen", items: [{ name: "Gloves", quantity: 1, unit: "box" }] };
    assert.equal((await create(body)).status, 201);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(dispatches, 1);
    assert.equal((await create(body)).status, 200);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(dispatches, 1);
  });

  it("maps a reused key with changed normalized payload to 409", async () => {
    assert.equal((await create({ category: "kitchen", items: [{ name: "Gloves", quantity: 1, unit: "box" }] })).status, 201);
    assert.equal((await create({ category: "kitchen", items: [{ name: "Gloves", quantity: 2, unit: "box" }] })).status, 409);
    assert.equal(dispatches, 1);
  });

  it("keeps creation successful when push delivery rejects", async () => {
    failPush = true;
    const response = await create({ category: "kitchen", items: [{ name: "Gloves", quantity: 1, unit: "box" }] });
    assert.equal(response.status, 201);
    assert.equal((await response.json() as { purchase_request: { id: string } }).purchase_request.id, requestId);
  });

  it("exposes registration only to active Purchasing context", async () => {
    const body = JSON.stringify({ endpoint: "https://push.example/buyer", keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" } });
    const accepted = await request("/api/v1/purchasing/push/subscriptions", "purchasing", { method: "POST", headers: { "Content-Type": "application/json" }, body });
    assert.equal(accepted.status, 200);
    assert.equal(registeredActor, purchaser);
    assert.equal((await request("/api/v1/purchasing/push/subscriptions", "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body })).status, 403);
  });
});
