import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { OrganizationManagerNotificationService } from "./organization-manager-notifications";
import type { UserContext } from "./user-context";

const ids = {
  manager: "12000000-0000-4000-8000-000000000001",
  mixed: "12000000-0000-4000-8000-000000000002",
  forced: "12000000-0000-4000-8000-000000000003",
  other: "12000000-0000-4000-8000-000000000004",
  disabled: "12000000-0000-4000-8000-000000000005",
  organization: "22000000-0000-4000-8000-000000000001",
  otherOrganization: "22000000-0000-4000-8000-000000000002",
  branch: "32000000-0000-4000-8000-000000000001",
  subscription: "42000000-0000-4000-8000-000000000001",
  notification: "52000000-0000-4000-8000-000000000001",
} as const;

function managerContext(id: string, forced = false, mixed = false): UserContext {
  return {
    id, full_name: "Manager", must_change_password: forced, disabled: false,
    managed_organizations: [{ id: ids.organization, name: "Organization", role: "organization_manager" }],
    branches: mixed ? [{ id: ids.branch, name: "Branch", organization_id: ids.organization, role: "branch_manager" }] : [],
  };
}
const contexts: Record<string, UserContext> = {
  manager: managerContext(ids.manager), mixed: managerContext(ids.mixed, false, true),
  forced: managerContext(ids.forced, true),
  other: { id: ids.other, full_name: "Other", must_change_password: false, disabled: false, branches: [], managed_organizations: [] },
  disabled: { ...managerContext(ids.disabled), disabled: true },
};

const config = loadBackendConfig({
  NODE_ENV: "test", SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
  VAPID_PUBLIC_KEY: "test-public-key", VAPID_PRIVATE_KEY: "test-private-key",
  VAPID_SUBJECT: "mailto:test@example.invalid",
});

function bearer(token: string) { return { Authorization: `Bearer ${token}` }; }

describe("Organization Manager notification API", () => {
  let server: Server;
  let baseUrl: string;
  const registrationActors: string[] = [];
  const service: OrganizationManagerNotificationService = {
    getPublicKey: async () => "test-public-key",
    async registerSubscription(input) {
      registrationActors.push(input.actorUserId);
      return { subscription: { id: ids.subscription, user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: null } };
    },
    async disableSubscription(input) {
      return { subscription: { id: ids.subscription, user_id: input.actorUserId, endpoint: input.endpoint, disabled_at: "2026-10-21T10:00:00.000Z" } };
    },
    async listNotifications() {
      return { notifications: [{
        id: ids.notification, organization_id: ids.organization, event_type: "maintenance_issue_created",
        source_type: "maintenance_issue", source_id: "62000000-0000-4000-8000-000000000001",
        occurrence_key: "maintenance:62000000-0000-4000-8000-000000000001", read_at: null,
        created_at: "2026-10-21T10:00:00.000Z",
      }] };
    },
    async markRead() {
      return { notification: { id: ids.notification, read_at: "2026-10-21T10:01:00.000Z" } };
    },
  };

  before(async () => {
    const dependencies = {
      checkReadiness: async () => true,
      passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
      provisioningAdmin: { createUser: async () => ({ id: "unused" }), deleteUser: async () => {}, finalize: async () => {} },
      managementAdmin: { listUsers: async () => ({ users: [], total: 0 }) },
      branchManagementAdmin: {}, pinCrypto: {}, organizationManagerNotifications: service,
      authVerifier: { verify: async (token: string) => contexts[token] ? { userId: contexts[token]!.id, email: `${token}@example.invalid` } : null },
      createUserContext: (token: string) => ({
        getUserContext: async () => contexts[token] ?? null,
        hasOrganizationManagerAccess: async (_userId: string, organizationId: string) => contexts[token]?.managed_organizations.some((item) => item.id === organizationId) ?? false,
        validateActiveBranches: async () => false, listActiveBranches: async () => [],
      }),
    } as unknown as BackendDependencies;
    server = createServer(createApp(config, dependencies));
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject); server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address() as AddressInfo;
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  after(async () => new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));

  it("exposes only the VAPID public key to an active manager", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/push/public-key`, { headers: bearer("manager") });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { enabled: true, public_key: "test-public-key" });
  });

  it("derives the registration actor from the bearer session", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/push/subscriptions`, {
      method: "POST", headers: { ...bearer("manager"), "Content-Type": "application/json" },
      body: JSON.stringify({ endpoint: "https://fcm.googleapis.com/fcm/send/manager", keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" }, actor_user_id: ids.other }),
    });
    assert.equal(response.status, 400, "strict request schema rejects a client actor id");
    const accepted = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/push/subscriptions`, {
      method: "POST", headers: { ...bearer("manager"), "Content-Type": "application/json" },
      body: JSON.stringify({ endpoint: "https://fcm.googleapis.com/fcm/send/manager", keys: { p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret" } }),
    });
    assert.equal(accepted.status, 200);
    assert.equal(registrationActors.at(-1), ids.manager);
  });

  it("rejects cross-organization, non-manager and forced-change access", async () => {
    for (const [token, organization] of [["manager", ids.otherOrganization], ["other", ids.organization], ["forced", ids.organization], ["disabled", ids.organization]]) {
      const response = await fetch(`${baseUrl}/api/v1/management/organizations/${organization}/notifications`, { headers: bearer(token) });
      assert.equal(response.status, 403, `${token}:${organization}`);
    }
  });

  it("allows a mixed-role user only through their active manager organization", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/notifications`, { headers: bearer("mixed") });
    assert.equal(response.status, 200);
    const foreign = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.otherOrganization}/notifications`, { headers: bearer("mixed") });
    assert.equal(foreign.status, 403);
  });

  it("lists history and marks only the addressed notification read", async () => {
    const listed = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/notifications?limit=25`, { headers: bearer("manager") });
    assert.equal(listed.status, 200);
    assert.equal((await listed.json() as { notifications: unknown[] }).notifications.length, 1);
    const read = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/notifications/${ids.notification}/read`, {
      method: "PATCH", headers: { ...bearer("manager"), "Content-Type": "application/json" }, body: "{}",
    });
    assert.equal(read.status, 200);
    assert.equal((await read.json() as { notification: { id: string } }).notification.id, ids.notification);
  });
});
