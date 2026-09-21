import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { AdminAccessError, AdminConflictError, AdminNotFoundError } from "./admin";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const ids = {
  actor: "18000000-0000-4000-8000-000000000001",
  organization: "28000000-0000-4000-8000-000000000001",
  otherOrganization: "28000000-0000-4000-8000-000000000002",
  purchasingUser: "38000000-0000-4000-8000-000000000001",
};
const config = loadBackendConfig({ NODE_ENV: "test", SUPABASE_URL: "http://127.0.0.1:54321", SUPABASE_PUBLISHABLE_KEY: "test-placeholder", DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes" });
const servers: ReturnType<typeof createServer>[] = [];

function deps(options: { manager?: boolean; internalAdmin?: boolean; conflict?: boolean; notFound?: boolean; denied?: boolean; calls?: Record<string, unknown> } = {}): BackendDependencies {
  const calls = options.calls ?? {};
  return {
    authVerifier: { async verify(token) { return token === "valid" ? { userId: ids.actor, email: "actor@example.invalid" } : null; } },
    async checkReadiness() { return true; },
    createUserContext() {
      return {
        async getUserContext() { return { id: ids.actor, full_name: "Actor", must_change_password: false, disabled: false, branches: [], managed_organizations: [] }; },
        async isInternalAdmin() { return options.internalAdmin ?? false; },
        async hasOrganizationManagerAccess(_actor, organizationId) { return (options.manager ?? true) && organizationId === ids.organization; },
        async validateActiveBranches() { return false; },
        async listActiveBranches() { return []; },
      };
    },
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: {
      async createUser(input) { calls.createAuthUser = input; if (options.conflict) throw new AdminConflictError(); return { id: ids.purchasingUser }; },
      async deleteUser(userId) { calls.deleteAuthUser = userId; },
      async finalize() {},
      async finalizePurchasing(input) { calls.finalizePurchasing = input; },
    },
    managementAdmin: {
      async listUsers() { return { users: [], total: 0 }; },
      async listPurchasingUsers(actorUserId, organizationId) {
        calls.listPurchasingUsers = { actorUserId, organizationId };
        if (options.denied) throw new AdminAccessError();
        return [{ id: ids.purchasingUser, full_name: "Buyer", full_name_ar: null, email: "buyer@example.invalid", active: true, must_change_password: false, disabled: false, created_at: "2026-09-21T00:00:00Z", updated_at: "2026-09-21T00:00:00Z", updated_by_name: "Actor" }];
      },
      async grantExistingPurchasingUser(input) {
        calls.grantExistingPurchasingUser = input;
        if (options.notFound) throw new AdminNotFoundError();
        if (options.denied) throw new AdminAccessError();
      },
      async setPurchasingUserActive(input) {
        calls.setPurchasingUserActive = input;
        if (options.denied) throw new AdminAccessError();
      },
    },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); }, async getPinCredential() { throw new Error("unused"); } },
    pinCrypto: { async hash() { throw new Error("unused"); }, async verify() { return false; }, issueGrant() { return "unused"; }, verifyGrant() { return false; } },
  };
}

async function start(dependencies: BackendDependencies) {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

afterEach(async () => Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve())))));
const request = (origin: string, path: string, init: RequestInit = {}) => fetch(`${origin}${path}`, { ...init, headers: { Authorization: "Bearer valid", ...(init.headers ?? {}) } });

describe("Purchasing access API", () => {
  it("lets an organization manager list, grant, deactivate, and reactivate Purchasing users only in their organization", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ calls, manager: true }));
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/purchasing-users`)).status, 200);
    const grant = await request(origin, `/api/v1/management/organizations/${ids.organization}/purchasing-users/existing`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: " buyer@example.invalid " }) });
    assert.equal(grant.status, 204);
    assert.deepEqual(calls.grantExistingPurchasingUser, { actorUserId: ids.actor, organizationId: ids.organization, email: "buyer@example.invalid" });
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/purchasing-users/${ids.purchasingUser}`, { method: "DELETE" })).status, 204);
    assert.deepEqual(calls.setPurchasingUserActive, { actorUserId: ids.actor, organizationId: ids.organization, userId: ids.purchasingUser, active: false });
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/purchasing-users/${ids.purchasingUser}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ active: true }) })).status, 204);
    assert.deepEqual(calls.setPurchasingUserActive, { actorUserId: ids.actor, organizationId: ids.organization, userId: ids.purchasingUser, active: true });
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.otherOrganization}/purchasing-users`)).status, 403);
  });

  it("lets verified Internal Admin provision Purchasing users without leaking credentials", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ calls, manager: false, internalAdmin: true }));
    const response = await request(origin, `/api/v1/internal-admin/organizations/${ids.organization}/purchasing-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ full_name: "  Buyer  ", email: "BUYER@EXAMPLE.INVALID", temporary_password: "temporary-secret" }) });
    assert.equal(response.status, 201, await response.clone().text());
    assert.deepEqual(await response.json(), { id: ids.purchasingUser, full_name: "Buyer", full_name_ar: null, email: "buyer@example.invalid", role: "purchasing", organization_id: ids.organization, must_change_password: true });
    assert.deepEqual(calls.createAuthUser, { email: "buyer@example.invalid", password: "temporary-secret" });
    assert.deepEqual(calls.finalizePurchasing, { actorUserId: ids.actor, organizationId: ids.organization, newUserId: ids.purchasingUser, fullName: "Buyer", fullNameAr: null });
  });

  it("denies unauthorized users and invalid Purchasing payloads", async () => {
    const origin = await start(deps({ manager: false, internalAdmin: false }));
    assert.equal((await fetch(`${origin}/api/v1/management/organizations/${ids.organization}/purchasing-users`)).status, 401);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/purchasing-users`)).status, 403);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/purchasing-users/existing`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: "bad" }) })).status, 400);
    assert.equal((await request(origin, `/api/v1/internal-admin/organizations/${ids.organization}/purchasing-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ full_name: "Buyer", email: "buyer@example.invalid", temporary_password: "secret1" }) })).status, 403);
  });
});

describe("Purchasing membership migration boundary", () => {
  it("creates a dedicated Purchasing membership model and service-role RPCs without reusing other role tables", async () => {
    const migration = await readFile(path.resolve("supabase/migrations/20260921120000_purchasing_memberships.sql"), "utf8");
    assert.match(migration, /create table public\.purchasing_memberships/);
    assert.match(migration, /constraint purchasing_memberships_organization_user_key unique \(organization_id, user_id\)/);
    assert.match(migration, /alter table public\.purchasing_memberships enable row level security/);
    assert.match(migration, /private\.has_active_purchasing_membership/);
    assert.match(migration, /grant execute on function public\.grant_existing_purchasing_membership\(uuid, uuid, text\) to service_role/);
    assert.match(migration, /grant execute on function public\.set_purchasing_membership_active\(uuid, uuid, uuid, boolean\) to service_role/);
    assert.doesNotMatch(migration, /insert into public\.maintenance_memberships|update public\.maintenance_memberships/i);
    assert.doesNotMatch(migration, /insert into public\.organization_memberships|update public\.organization_memberships/i);
    assert.doesNotMatch(migration, /purchase_requests|purchasing_inbox/i);
  });
});
