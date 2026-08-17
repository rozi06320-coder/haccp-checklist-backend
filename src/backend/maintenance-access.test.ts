import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { AdminAccessError, AdminConflictError, type MaintenanceAccessCredential, type PinCredential } from "./admin";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const ids = {
  actor: "17000000-0000-4000-8000-000000000001",
  organization: "27000000-0000-4000-8000-000000000001",
  otherOrganization: "27000000-0000-4000-8000-000000000002",
  accessUser: "37000000-0000-4000-8000-000000000001",
  maintenanceUser: "37000000-0000-4000-8000-000000000002",
  version: "47000000-0000-4000-8000-000000000001",
};
const config = loadBackendConfig({ NODE_ENV: "test", SUPABASE_URL: "http://127.0.0.1:54321", SUPABASE_PUBLISHABLE_KEY: "test-placeholder", DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes" });
const servers: ReturnType<typeof createServer>[] = [];
const credential: PinCredential = { pin_hash: "\\x" + "11".repeat(32), salt: "\\x" + "22".repeat(16), kdf_version: 1, cost: 16384, block_size: 8, parallelization: 1, credential_version: ids.version };
const accessCredential: MaintenanceAccessCredential = {
  ...credential,
  organization_id: ids.organization,
  organization_name: "Maintenance Org",
  access_user_id: ids.accessUser,
  display_name: "Maintenance Tech",
  credential_version: ids.version,
};

function deps(options: { manager?: boolean; internalAdmin?: boolean; conflict?: boolean; denied?: boolean; verified?: boolean; noCredential?: boolean; noSession?: boolean; finalizeFails?: boolean; calls?: Record<string, unknown> } = {}): BackendDependencies {
  const calls = options.calls ?? {};
  return {
    authVerifier: { async verify(token) { return token === "valid" ? { userId: ids.actor, email: "actor@example.invalid" } : null; } },
    async checkReadiness() { return true; },
    createUserContext() { return { async getUserContext() { return { id: ids.actor, full_name: "Actor", must_change_password: false, disabled: false, branches: [], managed_organizations: [] }; }, async isInternalAdmin() { return options.internalAdmin ?? false; }, async hasOrganizationManagerAccess() { return options.manager ?? true; }, async validateActiveBranches() { return false; }, async listActiveBranches() { return []; } }; },
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: {
      async createUser(input) {
        calls.createAuthUser = input;
        if (options.conflict) throw new AdminConflictError();
        return { id: ids.maintenanceUser };
      },
      async deleteUser(userId) { calls.deleteAuthUser = userId; },
      async finalize() {},
      async finalizeMaintenance(input) {
        calls.finalizeMaintenance = input;
        if (options.finalizeFails) throw new Error("finalize failed");
      },
    },
    managementAdmin: {
      async listOrganizationsForInternalAdmin(actorUserId) {
        calls.listOrganizationsForInternalAdmin = actorUserId;
        if (options.denied) throw new AdminAccessError();
        return [{ id: ids.organization, name: "Maintenance Org", active: true }];
      },
      async listUsers() { return { users: [], total: 0 }; },
      async listMaintenanceUsers(actorUserId, organizationId) {
        calls.listMaintenanceUsers = { actorUserId, organizationId };
        if (options.denied) throw new AdminAccessError();
        return [{
          id: ids.maintenanceUser,
          full_name: "Maintenance Worker",
          full_name_ar: null,
          email: "maintenance@example.invalid",
          active: true,
          must_change_password: true,
          created_at: "2026-08-07T00:00:00Z",
          updated_at: "2026-08-07T00:00:00Z",
          updated_by_name: "Manager",
        }];
      },
      async deactivateMaintenanceUser(input) {
        calls.deactivateMaintenanceUser = input;
        if (options.denied) throw new AdminAccessError();
      },
    },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); }, async getPinCredential() { throw new Error("unused"); } },
    dailyAuditPinAdmin: { async listManagers() { return []; }, async storeManagerPin() { throw new Error("unused"); }, async listCredentials() { return []; }, async recordGrant() {}, async validateGrant() { return false; } },
    maintenanceAccessAdmin: {
      async listAccessUsers(actorUserId, organizationId) {
        calls.list = { actorUserId, organizationId };
        if (options.denied) throw new AdminAccessError();
        return [{ id: ids.accessUser, organization_id: ids.organization, display_name: "Maintenance Tech", active: true, created_at: "2026-08-07T00:00:00Z", updated_at: "2026-08-07T00:00:00Z", updated_by_name: "Manager" }];
      },
      async createAccessUser(input) {
        calls.create = input;
        if (options.conflict) throw new AdminConflictError();
        if (options.denied) throw new AdminAccessError();
      },
      async deactivateAccessUser(input) {
        calls.deactivate = input;
        if (options.denied) throw new AdminAccessError();
      },
      async getAccessCredential(input) {
        calls.lookup = input;
        if (options.denied) throw new AdminAccessError();
        return options.noCredential ? null : accessCredential;
      },
      async validateAccessGrant(input) {
        calls.validateGrant = input;
        if (options.denied) throw new AdminAccessError();
        return options.noSession ? null : {
          organization_id: ids.organization,
          organization_name: "Maintenance Org",
          access_user_id: ids.accessUser,
          display_name: "Maintenance Tech",
        };
      },
    },
    pinCrypto: {
      async hash(pin) { calls.hashedPin = pin; return credential; },
      async verify(pin, checked) { calls.verifyCredential = { pin, checked }; return options.verified ?? false; },
      issueMaintenanceGrant(organizationId, accessUserId, credentialVersion) { calls.maintenanceGrantBinding = { organizationId, accessUserId, credentialVersion }; return "opaque-maintenance-grant"; },
      verifyMaintenanceGrant(grant) { calls.maintenanceGrant = grant; return grant === "opaque-maintenance-grant" ? { organizationId: ids.organization, accessUserId: ids.accessUser, credentialVersion: ids.version } : null; },
      issueGrant() { return "unused"; },
      verifyGrant() { return false; },
    },
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

describe("Maintenance Access API", () => {
  it("lets an Internal Admin list organizations, create, list, and deactivate authenticated Maintenance users", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ calls, internalAdmin: true }));
    const organizations = await request(origin, "/api/v1/internal-admin/organizations");
    assert.equal(organizations.status, 200);
    assert.match(await organizations.text(), /Maintenance Org/);
    assert.equal(calls.listOrganizationsForInternalAdmin, ids.actor);

    const list = await request(origin, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`);
    assert.equal(list.status, 200);
    const listText = await list.text();
    assert.match(listText, /Maintenance Worker/);
    assert.match(listText, /maintenance@example\.invalid/);
    assert.doesNotMatch(listText, /temporary_password|pin_hash|salt/i);

    const create = await request(origin, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ full_name: "  Maintenance Worker  ", email: "  MAINTENANCE@EXAMPLE.INVALID ", temporary_password: "temporary-secret" }),
    });
    assert.equal(create.status, 201);
    const created = await create.json();
    assert.deepEqual(created, {
      id: ids.maintenanceUser,
      full_name: "Maintenance Worker",
      full_name_ar: null,
      email: "maintenance@example.invalid",
      role: "maintenance_user",
      organization_id: ids.organization,
      must_change_password: true,
    });
    assert.deepEqual(calls.createAuthUser, { email: "maintenance@example.invalid", password: "temporary-secret" });
    assert.deepEqual(calls.finalizeMaintenance, {
      actorUserId: ids.actor,
      organizationId: ids.organization,
      newUserId: ids.maintenanceUser,
      fullName: "Maintenance Worker",
      fullNameAr: null,
    });

    const deactivate = await request(origin, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users/${ids.maintenanceUser}`, { method: "DELETE" });
    assert.equal(deactivate.status, 204);
    assert.deepEqual(calls.deactivateMaintenanceUser, {
      actorUserId: ids.actor,
      organizationId: ids.organization,
      userId: ids.maintenanceUser,
    });
  });

  it("creates authenticated Maintenance users with optional Arabic full names", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ calls, internalAdmin: true }));
    const create = await request(origin, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        full_name: "Maintenance Worker",
        full_name_ar: "  فني   الصيانة  ",
        email: "maintenance-ar@example.invalid",
        temporary_password: "temporary-secret",
      }),
    });
    assert.equal(create.status, 201);
    const created = await create.json();
    assert.equal(created.full_name_ar, "فني الصيانة");
    assert.deepEqual(calls.finalizeMaintenance, {
      actorUserId: ids.actor,
      organizationId: ids.organization,
      newUserId: ids.maintenanceUser,
      fullName: "Maintenance Worker",
      fullNameAr: "فني الصيانة",
    });
  });

  it("denies Internal Admin Maintenance user endpoints to non-admins and invalid payloads", async () => {
    const origin = await start(deps({ internalAdmin: false }));
    assert.equal((await fetch(`${origin}/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`)).status, 401);
    assert.equal((await request(origin, "/api/v1/internal-admin/organizations")).status, 403);
    assert.equal((await request(origin, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`)).status, 403);
    const admin = await start(deps({ internalAdmin: true }));
    assert.equal((await request(admin, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ full_name: "Maintenance", email: "bad", temporary_password: "secret1" }) })).status, 400);
    assert.equal((await request(admin, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users/not-a-uuid`, { method: "DELETE" })).status, 400);
  });

  it("keeps Manager authenticated Maintenance user endpoints fail closed", async () => {
    const origin = await start(deps({ manager: true }));
    assert.equal((await fetch(`${origin}/api/v1/management/organizations/${ids.organization}/maintenance-users`)).status, 401);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-users`)).status, 403);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ full_name: "Maintenance", email: "maintenance@example.invalid", temporary_password: "secret1" }) })).status, 403);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-users/${ids.maintenanceUser}`, { method: "DELETE" })).status, 403);
  });

  it("maps duplicate auth email and finalize failure to safe Internal Admin Maintenance user responses", async () => {
    const duplicate = await start(deps({ conflict: true, internalAdmin: true }));
    const duplicateResponse = await request(duplicate, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ full_name: "Maintenance", email: "maintenance@example.invalid", temporary_password: "secret1" }) });
    assert.equal(duplicateResponse.status, 409);
    assert.doesNotMatch(await duplicateResponse.text(), /postgres|duplicate key|temporary-secret|service_role/i);

    const calls: Record<string, unknown> = {};
    const finalizeFailed = await start(deps({ calls, finalizeFails: true, internalAdmin: true }));
    const failed = await request(finalizeFailed, `/api/v1/internal-admin/organizations/${ids.organization}/maintenance-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ full_name: "Maintenance", email: "maintenance@example.invalid", temporary_password: "secret1" }) });
    assert.equal(failed.status, 503);
    assert.equal(calls.deleteAuthUser, ids.maintenanceUser);
    assert.doesNotMatch(await failed.text(), /finalize failed|postgres|service_role/i);
  });

  it("lets a Manager list, create, and deactivate organization-wide maintenance users", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ calls }));
    const list = await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users`);
    assert.equal(list.status, 200);
    const listText = await list.text();
    assert.match(listText, /Maintenance Tech/);
    assert.doesNotMatch(listText, /pin_hash|salt|1234|credential|branch_id/i);
    const create = await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ display_name: "  Maintenance Tech  ", pin: "1234", pin_confirmation: "1234" }) });
    assert.equal(create.status, 204);
    const deactivate = await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users/${ids.accessUser}`, { method: "DELETE" });
    assert.equal(deactivate.status, 204);
    assert.equal(calls.hashedPin, "1234");
    assert.deepEqual(calls.create, { actorUserId: ids.actor, organizationId: ids.organization, displayName: "Maintenance Tech", credential });
    assert.deepEqual(calls.deactivate, { actorUserId: ids.actor, organizationId: ids.organization, accessUserId: ids.accessUser });
  });

  it("denies anonymous, supervisor, unrelated manager, and invalid payload access", async () => {
    const origin = await start(deps({ manager: false }));
    assert.equal((await fetch(`${origin}/api/v1/management/organizations/${ids.organization}/maintenance-access-users`)).status, 401);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users`)).status, 403);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ branch_id: ids.organization, display_name: "Maintenance Tech", pin: "1234", pin_confirmation: "1234" }) })).status, 400);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ display_name: "Maintenance Tech", pin: "12ab", pin_confirmation: "12ab" }) })).status, 400);
    assert.equal((await request(origin, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users/not-a-uuid`, { method: "DELETE" })).status, 400);
  });

  it("maps duplicate and database access denial to safe responses", async () => {
    const duplicate = await start(deps({ conflict: true }));
    const duplicateResponse = await request(duplicate, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ display_name: "Maintenance Tech", pin: "1234", pin_confirmation: "1234" }) });
    assert.equal(duplicateResponse.status, 409);
    assert.doesNotMatch(await duplicateResponse.text(), /postgres|duplicate key|pin_hash|salt/i);
    const denied = await start(deps({ denied: true }));
    assert.equal((await request(denied, `/api/v1/management/organizations/${ids.organization}/maintenance-access-users`)).status, 403);
  });

  it("verifies a valid active maintenance credential and returns only safe context", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ calls, verified: true }));
    const response = await fetch(`${origin}/api/v1/maintenance/access/verify`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ organization: "maintenance-org", display_name: "  Maintenance Tech  ", pin: "1234" }) });
    assert.equal(response.status, 200);
    assert.match(response.headers.get("set-cookie") ?? "", /maintenance_access=opaque-maintenance-grant/);
    const text = await response.text();
    assert.match(text, /Maintenance Org/);
    assert.match(text, /Maintenance Tech/);
    assert.doesNotMatch(text, /pin_hash|salt|1234|credential_version/i);
    assert.deepEqual(calls.lookup, { organizationIdentifier: "maintenance-org", displayName: "Maintenance Tech" });
    assert.deepEqual(calls.maintenanceGrantBinding, { organizationId: ids.organization, accessUserId: ids.accessUser, credentialVersion: ids.version });
  });

  it("denies invalid PIN, inactive users, and other organization lookups with a safe error", async () => {
    for (const options of [{ verified: false }, { noCredential: true }]) {
      const origin = await start(deps(options));
      const response = await fetch(`${origin}/api/v1/maintenance/access/verify`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ organization: "maintenance-org", display_name: "Maintenance Tech", pin: "1234" }) });
      assert.equal(response.status, 403);
      assert.doesNotMatch(await response.text(), /pin_hash|salt|postgres|credential/i);
    }
    const invalidPayload = await fetch(`${await start(deps())}/api/v1/maintenance/access/verify`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ organization: ids.otherOrganization, display_name: "Maintenance Tech", pin: "12ab" }) });
    assert.equal(invalidPayload.status, 400);
  });

  it("validates and clears Maintenance dashboard sessions from the signed cookie", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ calls }));
    const valid = await fetch(`${origin}/api/v1/maintenance/access/session`, { headers: { Cookie: "maintenance_access=opaque-maintenance-grant" } });
    assert.equal(valid.status, 200);
    assert.match(await valid.text(), /Maintenance Tech/);
    assert.deepEqual(calls.validateGrant, { organizationId: ids.organization, accessUserId: ids.accessUser, credentialVersion: ids.version });
    const invalid = await fetch(`${origin}/api/v1/maintenance/access/session`, { headers: { Cookie: "maintenance_access=bad" } });
    assert.equal(invalid.status, 401);
    assert.match(invalid.headers.get("set-cookie") ?? "", /maintenance_access=; Max-Age=0/);
    const inactive = await fetch(`${await start(deps({ noSession: true }))}/api/v1/maintenance/access/session`, { headers: { Cookie: "maintenance_access=opaque-maintenance-grant" } });
    assert.equal(inactive.status, 401);
  });
});
