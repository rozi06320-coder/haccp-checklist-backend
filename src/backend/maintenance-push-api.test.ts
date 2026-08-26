import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { createMaintenancePushService, MaintenancePushAccessError, type MaintenancePushService } from "./maintenance-push";
import type { UserContext } from "./user-context";

const ids = {
  maintenance: "19000000-0000-4000-8000-000000000001",
  manager: "19000000-0000-4000-8000-000000000002",
  supervisor: "19000000-0000-4000-8000-000000000003",
  branch: "39000000-0000-4000-8000-000000000001",
  issue: "49000000-0000-4000-8000-000000000001",
} as const;

const contexts: Record<string, UserContext> = {
  maintenance: { id: ids.maintenance, full_name: "Maintenance User", must_change_password: false, disabled: false, branches: [], managed_organizations: [] },
  manager: { id: ids.manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: "29000000-0000-4000-8000-000000000001", name: "Org", role: "organization_manager" }] },
  supervisor: { id: ids.supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: ids.branch, name: "Branch", organization_id: "29000000-0000-4000-8000-000000000001", role: "branch_manager" }], managed_organizations: [] },
};

const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
  VAPID_PUBLIC_KEY: "test-public-key",
  VAPID_PRIVATE_KEY: "test-private-key",
  VAPID_SUBJECT: "mailto:test@example.invalid",
});

function auth(token: string) {
  return { Authorization: `Bearer ${token}` };
}

async function json(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

function baseDependencies(push: MaintenancePushService, createIssue = async () => ({
  maintenance_issue: {
    id: ids.issue,
    branch_id: ids.branch,
    branch_name: "Main Branch",
    title: "Freezer not cooling",
    category: "refrigeration",
    priority: "urgent",
    status: "new",
    description: null,
    location: null,
    reported_by: ids.supervisor,
    reporter_name: "Supervisor",
    assigned_to: null,
    created_at: "2026-08-15T10:00:00.000Z",
    updated_at: "2026-08-15T10:00:00.000Z",
    updates: [],
  },
})) {
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
      hasOrganizationManagerAccess: async () => false,
      validateActiveBranches: async () => false,
      listActiveBranches: async () => [],
    }),
    operationalAdmin: {
      createSupervisorMaintenanceIssue: createIssue,
    },
    maintenancePush: push,
  } as unknown as BackendDependencies;
}

async function listen(push: MaintenancePushService, createIssue?: Parameters<typeof baseDependencies>[1]) {
  const server = createServer(createApp(config, baseDependencies(push, createIssue)));
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address() as AddressInfo;
  return { server, baseUrl: `http://127.0.0.1:${address.port}` };
}

async function close(server: Server) {
  await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

describe("Maintenance push notification API", () => {
  let server: Server;
  let baseUrl: string;
  let registeredActor: string | null = null;
  let disabledEndpoint: string | null = null;
  let notifyInput: unknown = null;
  let notifyAttempts = 0;

  before(async () => {
    const push: MaintenancePushService = {
      getPublicKey: () => "test-public-key",
      async registerSubscription(input) {
        registeredActor = input.actorUserId;
        if (input.endpoint.includes("inactive")) throw new MaintenancePushAccessError();
        return { subscription: { id: "59000000-0000-4000-8000-000000000001", user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: null } };
      },
      async disableSubscription(input) {
        disabledEndpoint = input.endpoint;
        return { subscription: { id: "59000000-0000-4000-8000-000000000001", user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: "2026-08-15T10:00:00.000Z" } };
      },
      async registerSupervisorSubscription(input) {
        return { subscription: { id: "59000000-0000-4000-8000-000000000001", user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: null } };
      },
      async notifyMaintenanceIssueCreated(input) {
        notifyAttempts += 1;
        notifyInput = input;
        throw new Error("push transport failed");
      },
      async notifyDueSupervisorChecklistReminders() {
        return { evaluated_at: "2026-08-15T10:00:00.000Z", deliveries_attempted: 0, deliveries_sent: 0 };
      },
    };
    ({ server, baseUrl } = await listen(push));
  });

  after(async () => close(server));

  it("returns the VAPID public key for authenticated Maintenance users", async () => {
    const response = await fetch(`${baseUrl}/api/v1/maintenance/push/public-key`, { headers: auth("maintenance") });
    assert.equal(response.status, 200);
    assert.deepEqual(await json(response), { enabled: true, public_key: "test-public-key" });
  });

  it("reports push as unconfigured without exposing a public key", async () => {
    const push: MaintenancePushService = {
      getPublicKey: () => null,
      async registerSubscription() {
        return { subscription: null };
      },
      async disableSubscription() {
        return { subscription: null };
      },
      async registerSupervisorSubscription() {
        return { subscription: null };
      },
      async notifyMaintenanceIssueCreated() {},
      async notifyDueSupervisorChecklistReminders() {
        return { evaluated_at: "2026-08-15T10:00:00.000Z", deliveries_attempted: 0, deliveries_sent: 0 };
      },
    };
    const instance = await listen(push);
    try {
      const response = await fetch(`${instance.baseUrl}/api/v1/maintenance/push/public-key`, { headers: auth("maintenance") });
      assert.equal(response.status, 200);
      assert.deepEqual(await json(response), { enabled: false, public_key: null });
    } finally {
      await close(instance.server);
    }
  });

  it("registers a subscription for the authenticated actor only", async () => {
    const response = await fetch(`${baseUrl}/api/v1/maintenance/push/subscriptions`, {
      method: "POST",
      headers: { ...auth("maintenance"), "Content-Type": "application/json" },
      body: JSON.stringify({ endpoint: "https://push.example/subscription-a", keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" } }),
    });
    assert.equal(response.status, 200);
    assert.equal(registeredActor, ids.maintenance);
    assert.equal((await json(response)).subscription !== null, true);
  });

  it("rejects non-Maintenance dashboard actors before registering", async () => {
    const response = await fetch(`${baseUrl}/api/v1/maintenance/push/subscriptions`, {
      method: "POST",
      headers: { ...auth("manager"), "Content-Type": "application/json" },
      body: JSON.stringify({ endpoint: "https://push.example/manager", keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" } }),
    });
    assert.equal(response.status, 403);
  });

  it("soft-disables the current user's subscription", async () => {
    const response = await fetch(`${baseUrl}/api/v1/maintenance/push/subscriptions`, {
      method: "DELETE",
      headers: { ...auth("maintenance"), "Content-Type": "application/json" },
      body: JSON.stringify({ endpoint: "https://push.example/subscription-a" }),
    });
    assert.equal(response.status, 200);
    assert.equal(disabledEndpoint, "https://push.example/subscription-a");
  });

  it("persists Maintenance issue success even when push sending fails", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: { ...auth("supervisor"), "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Freezer not cooling", category: "refrigeration", priority: "urgent", description: null, location: null }),
    });
    assert.equal(response.status, 201);
    const body = await json(response);
    assert.equal((body.maintenance_issue as { id: string }).id, ids.issue);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(notifyAttempts, 1);
    assert.deepEqual(notifyInput, { issueId: ids.issue, branchId: ids.branch, branchName: "Main Branch", priority: "urgent", title: "Freezer not cooling" });
  });

  it("fans out new issue pushes to every organization Maintenance subscription without branch filtering", async () => {
    const sent: Array<{ endpoint: string; payload: Record<string, unknown> }> = [];
    const disabled: Array<Record<string, unknown>> = [];
    const rpcCalls: Array<{ name: string; args: Record<string, unknown> }> = [];
    const row = (subscriptionId: string, userId: string, endpoint: string) => ({
      subscription_id: subscriptionId,
      user_id: userId,
      endpoint,
      p256dh: "abcdefghijklmnopqrstuvwxyz",
      auth: "authsecret",
      organization_id: "29000000-0000-4000-8000-000000000001",
      branch_id: ids.branch,
      organization_name: "Push Org",
      branch_name: "Burger Hunch Al Takhassusi",
      issue_title: "Freezer not cooling",
    });
    const service = createMaintenancePushService(loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
      SUPABASE_SECRET_KEY: "test-secret-placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
      VAPID_PUBLIC_KEY: "test-public-key",
      VAPID_PRIVATE_KEY: "test-private-key",
      VAPID_SUBJECT: "mailto:test@example.invalid",
    }), {
      supabase: {
        async rpc(name, args) {
          rpcCalls.push({ name, args });
          if (name === "list_maintenance_issue_push_subscriptions") {
            return { data: [
              row("59000000-0000-4000-8000-000000000101", "19000000-0000-4000-8000-000000000101", "https://push.example/maint-a-laptop"),
              row("59000000-0000-4000-8000-000000000102", "19000000-0000-4000-8000-000000000101", "https://push.example/maint-a-phone"),
              row("59000000-0000-4000-8000-000000000103", "19000000-0000-4000-8000-000000000102", "https://push.example/maint-b-phone"),
              row("59000000-0000-4000-8000-000000000104", "19000000-0000-4000-8000-000000000102", "https://push.example/maint-b-stale"),
              row("59000000-0000-4000-8000-000000000105", "19000000-0000-4000-8000-000000000102", "https://push.example/maint-a-laptop"),
            ], error: null };
          }
          if (name === "disable_push_subscription_delivery") {
            disabled.push(args);
            return { data: true, error: null };
          }
          return { data: [], error: null };
        },
      },
      webPush: {
        setVapidDetails() {},
        async sendNotification(subscription, payload) {
          if (subscription.endpoint.endsWith("stale")) {
            const error = new Error("stale subscription") as Error & { statusCode: number };
            error.statusCode = 410;
            throw error;
          }
          sent.push({ endpoint: subscription.endpoint, payload: JSON.parse(String(payload)) as Record<string, unknown> });
        },
      },
    });

    await service.notifyMaintenanceIssueCreated({ issueId: ids.issue, branchId: ids.branch, branchName: "Burger Hunch Al Takhassusi", priority: "urgent", title: "Freezer not cooling" });

    assert.deepEqual(rpcCalls[0], { name: "list_maintenance_issue_push_subscriptions", args: { target_issue_id: ids.issue } });
    assert.deepEqual(sent.map((item) => item.endpoint).sort(), [
      "https://push.example/maint-a-laptop",
      "https://push.example/maint-a-phone",
      "https://push.example/maint-b-phone",
    ]);
    assert.equal(sent.filter((item) => item.endpoint === "https://push.example/maint-a-laptop").length, 1);
    assert.deepEqual(disabled, [{ target_subscription_id: "59000000-0000-4000-8000-000000000104", target_endpoint: "https://push.example/maint-b-stale" }]);
    for (const delivery of sent) {
      assert.equal(delivery.payload.type, "maintenance_issue_created");
      assert.equal(delivery.payload.branch_id, ids.branch);
      assert.equal(delivery.payload.priority, "urgent");
      assert.equal(delivery.payload.body, "Burger Hunch Al Takhassusi · Urgent priority\nFreezer not cooling");
      assert.doesNotMatch(JSON.stringify(delivery.payload), /p256dh|authsecret|endpoint|subscription/i);
    }
  });
});
