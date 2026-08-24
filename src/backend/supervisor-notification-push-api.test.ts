import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { MaintenancePushService } from "./maintenance-push";
import type { UserContext } from "./user-context";

const ids = {
  supervisor: "18000000-0000-4000-8000-000000000001",
  manager: "18000000-0000-4000-8000-000000000002",
  staff: "18000000-0000-4000-8000-000000000003",
  otherUser: "18000000-0000-4000-8000-000000000004",
  branch: "28000000-0000-4000-8000-000000000001",
  otherBranch: "28000000-0000-4000-8000-000000000002",
  org: "38000000-0000-4000-8000-000000000001",
} as const;

const schedulerSecret = "test-supervisor-notification-scheduler-secret";
const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
  VAPID_PUBLIC_KEY: "test-public-key",
  VAPID_PRIVATE_KEY: "test-private-key",
  VAPID_SUBJECT: "mailto:test@example.invalid",
  SUPERVISOR_NOTIFICATION_SCHEDULER_SECRET: schedulerSecret,
});

const contexts: Record<string, UserContext> = {
  supervisor: { id: ids.supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: ids.branch, name: "Branch", organization_id: ids.org, role: "branch_manager" }], managed_organizations: [] },
  manager: { id: ids.manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: ids.org, name: "Org", role: "organization_manager" }] },
  staff: { id: ids.staff, full_name: "Staff", must_change_password: false, disabled: false, branches: [{ id: ids.branch, name: "Branch", organization_id: ids.org, role: "staff" }], managed_organizations: [] },
};

const calls: Array<{ name: string; input: unknown }> = [];

function push(): MaintenancePushService {
  return {
    getPublicKey: () => "test-public-key",
    async registerSubscription(input) {
      calls.push({ name: "maintenance-register", input });
      return { subscription: { id: "48000000-0000-4000-8000-000000000001", user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: null } };
    },
    async disableSubscription(input) {
      calls.push({ name: "disable", input });
      return { subscription: { id: "48000000-0000-4000-8000-000000000001", user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: "2026-08-24T12:00:00.000Z" } };
    },
    async registerSupervisorSubscription(input) {
      calls.push({ name: "supervisor-register", input });
      return { subscription: { id: "48000000-0000-4000-8000-000000000001", user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: null } };
    },
    async notifyMaintenanceIssueCreated() {},
    async notifyDueSupervisorChecklistReminders(input) {
      calls.push({ name: "scheduler", input: { asOf: input.asOf.toISOString() } });
      return { evaluated_at: input.asOf.toISOString(), deliveries_attempted: 4, deliveries_sent: 3 };
    },
  };
}

function deps(maintenancePush: MaintenancePushService = push()): BackendDependencies {
  return {
    checkReadiness: async () => true,
    passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
    provisioningAdmin: { createUser: async () => ({ id: "unused" }), deleteUser: async () => {}, finalize: async () => {} },
    managementAdmin: { listUsers: async () => ({ users: [], total: 0 }) },
    branchManagementAdmin: { listBranches: async () => [], listStaff: async () => [], getPinMetadata: async () => ({ configured: false, updated_at: null, updated_by_name: null }), storePin: async () => ({ configured: true, updated_at: null, updated_by_name: null }), getPinCredential: async () => null },
    pinCrypto: { hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }), verify: async () => false, issueGrant: () => "", verifyGrant: () => false },
    authVerifier: { verify: async (token: string) => contexts[token] ? { userId: contexts[token].id, email: `${token}@example.invalid` } : null },
    createUserContext: (token: string) => ({
      getUserContext: async () => contexts[token] ?? null,
      isInternalAdmin: async () => false,
      hasOrganizationManagerAccess: async () => false,
      validateActiveBranches: async () => false,
      listActiveBranches: async () => [],
    }),
    maintenancePush,
    now: () => new Date("2026-08-24T19:00:00.000Z"),
  } as unknown as BackendDependencies;
}

async function listen(maintenancePush: MaintenancePushService = push()) {
  const instance = createServer(createApp(config, deps(maintenancePush)));
  await new Promise<void>((resolve, reject) => instance.listen(0, "127.0.0.1", resolve).once("error", reject));
  return {
    server: instance,
    baseUrl: `http://127.0.0.1:${(instance.address() as AddressInfo).port}`,
  };
}

async function close(instance: Server) {
  await new Promise<void>((resolve) => instance.close(() => resolve()));
}

function auth(token: string) {
  return { Authorization: `Bearer ${token}` };
}

async function json(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

let server: Server;
let baseUrl: string;

describe("Supervisor notification browser push API", () => {
  before(async () => {
    ({ server, baseUrl } = await listen());
  });
  after(() => close(server));
  beforeEach(() => { calls.length = 0; });

  it("returns the shared VAPID public key only for Supervisor users without exposing the private key", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/push/public-key`, { headers: auth("supervisor") });
    assert.equal(response.status, 200);
    const body = await json(response);
    assert.deepEqual(body, { enabled: true, public_key: "test-public-key" });
    assert.equal(JSON.stringify(body).includes("test-private-key"), false);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/push/public-key`, { headers: auth("manager") })).status, 403);
  });

  it("reports Supervisor browser push as disabled when VAPID transport is unconfigured", async () => {
    const disabledPush = push();
    disabledPush.getPublicKey = () => null;
    const instance = await listen(disabledPush);
    try {
      const response = await fetch(`${instance.baseUrl}/api/v1/supervisor/push/public-key`, { headers: auth("supervisor") });
      assert.equal(response.status, 200);
      assert.deepEqual(await json(response), { enabled: false, public_key: null });
    } finally {
      await close(instance.server);
    }
  });

  it("registers an eligible authenticated Supervisor through the shared push subscription infrastructure", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/push/subscriptions`, {
      method: "POST",
      headers: { ...auth("supervisor"), "Content-Type": "application/json", "User-Agent": "Node Test" },
      body: JSON.stringify({ endpoint: "https://push.example/supervisor", keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" } }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), { name: "supervisor-register", input: { actorUserId: ids.supervisor, endpoint: "https://push.example/supervisor", p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret", userAgent: "Node Test" } });
    assert.equal(JSON.stringify(calls.at(-1)).includes("example.invalid"), false);
    assert.equal((await json(response)).subscription !== null, true);
  });

  it("rejects non-Supervisor branch users before registration", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/push/subscriptions`, {
      method: "POST",
      headers: { ...auth("staff"), "Content-Type": "application/json" },
      body: JSON.stringify({ endpoint: "https://push.example/staff", keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" } }),
    });
    assert.equal(response.status, 403);
    assert.equal(calls.length, 0);
  });

  it("does not let clients choose arbitrary push user or branch scope", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/push/subscriptions`, {
      method: "POST",
      headers: { ...auth("supervisor"), "Content-Type": "application/json" },
      body: JSON.stringify({
        user_id: ids.otherUser,
        branch_id: ids.otherBranch,
        endpoint: "https://push.example/spoofed",
        keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" },
      }),
    });
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  });

  it("rejects email recipient lists as a routing authority", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/push/subscriptions`, {
      method: "POST",
      headers: { ...auth("supervisor"), "Content-Type": "application/json" },
      body: JSON.stringify({
        endpoint: "https://push.example/email-list",
        keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" },
        emails: ["maintenance@example.invalid"],
      }),
    });
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  });

  it("disables only the authenticated Supervisor user's matching subscription", async () => {
    const disabled = await fetch(`${baseUrl}/api/v1/supervisor/push/subscriptions`, {
      method: "DELETE",
      headers: { ...auth("supervisor"), "Content-Type": "application/json" },
      body: JSON.stringify({ endpoint: "https://push.example/supervisor" }),
    });
    assert.equal(disabled.status, 200);
    assert.deepEqual(calls.at(-1), { name: "disable", input: { actorUserId: ids.supervisor, endpoint: "https://push.example/supervisor" } });

    calls.length = 0;
    const spoofed = await fetch(`${baseUrl}/api/v1/supervisor/push/subscriptions`, {
      method: "DELETE",
      headers: { ...auth("supervisor"), "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: ids.otherUser, endpoint: "https://push.example/supervisor" }),
    });
    assert.equal(spoofed.status, 400);
    assert.equal(calls.length, 0);
  });

  it("requires the scheduler secret before running due reminder delivery", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/internal/supervisor-notifications/push/run`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/internal/supervisor-notifications/push/run`, { method: "POST", headers: { "Content-Type": "application/json", "X-Scheduler-Secret": "wrong-secret" }, body: "{}" })).status, 401);

    const response = await fetch(`${baseUrl}/api/v1/internal/supervisor-notifications/push/run`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Scheduler-Secret": schedulerSecret },
      body: "{}",
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await json(response), { evaluated_at: "2026-08-24T19:00:00.000Z", deliveries_attempted: 4, deliveries_sent: 3 });
    assert.deepEqual(calls.at(-1), { name: "scheduler", input: { asOf: "2026-08-24T19:00:00.000Z" } });
  });
});
