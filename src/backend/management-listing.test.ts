import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const ids = {
  manager: "14000000-0000-4000-8000-000000000001",
  staff: "14000000-0000-4000-8000-000000000002",
  orgA: "24000000-0000-4000-8000-000000000001",
  orgB: "24000000-0000-4000-8000-000000000002",
  branch: "34000000-0000-4000-8000-000000000001",
  user: "44000000-0000-4000-8000-000000000001",
};
const servers: ReturnType<typeof createServer>[] = [];
const config = loadBackendConfig({ NODE_ENV: "test", SUPABASE_URL: "http://127.0.0.1:54321", SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder", DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes" });

function deps(tokenRole: "manager" | "staff" = "manager", rawError = false): BackendDependencies {
  const branchRows = [{ id: ids.branch, name: "Active A", code: "AA" }];
  return {
    authVerifier: { async verify(token) { return token === "valid" ? { userId: tokenRole === "manager" ? ids.manager : ids.staff, email: "actor@example.invalid" } : null; } },
    async checkReadiness() { return true; },
    createUserContext() { return {
      async getUserContext() { return { id: tokenRole === "manager" ? ids.manager : ids.staff, full_name: "Actor", must_change_password: false, disabled: false, branches: [], managed_organizations: [] }; },
      async hasOrganizationManagerAccess(_user, organization) { return tokenRole === "manager" && organization === ids.orgA; },
      async validateActiveBranches() { return true; },
      async listActiveBranches() { if (rawError) throw new Error("RAW_DATABASE_SECRET"); return branchRows; },
    }; },
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { return { id: ids.user }; }, async deleteUser() {}, async finalize() {} },
    managementAdmin: { async listUsers() {
      if (rawError) throw new Error("RAW_RPC_AUTH_SECRET");
      return { total: 1, users: [{ id: ids.user, full_name: "Person", email: "person@example.invalid", role: "staff", branches: [{ id: ids.branch, name: "Active A", code: "AA" }], disabled: false, must_change_password: false, created_at: "2026-07-28T00:00:00Z" }] };
    }, async createBranch(input) {
      if (rawError) throw new Error("RAW_RPC_BRANCH_SECRET");
      if (input.name === "Active A") {
        const { AdminConflictError } = await import("./admin");
        throw new AdminConflictError();
      }
      const branch = { id: `34000000-0000-4000-8000-${String(branchRows.length + 1).padStart(12, "0")}`, name: input.name, code: input.code, city: input.city, area: input.area ?? null, address: input.address ?? null, timezone: input.timezone, active: input.active };
      branchRows.push({ id: branch.id, name: branch.name, code: branch.code });
      return branch;
    } },
    branchManagementAdmin: {
      async listBranches() { return []; }, async listStaff() { return []; },
      async getPinMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async storePin() { return { configured: true, updated_at: null, updated_by_name: null }; },
      async getPinCredential() { return null; },
    },
    pinCrypto: {
      async hash() { throw new Error("unused"); }, async verify() { return false; },
      issueGrant() { return "unused"; }, verifyGrant() { return false; },
    },
  };
}
async function get(path: string, dependencies = deps()) {
  const server = createServer(createApp(config, dependencies)); servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`http://127.0.0.1:${(server.address() as AddressInfo).port}${path}`, { headers: { Authorization: "Bearer valid" } });
}
async function post(path: string, body: unknown, dependencies = deps()) {
  const server = createServer(createApp(config, dependencies)); servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`http://127.0.0.1:${(server.address() as AddressInfo).port}${path}`, { method: "POST", headers: { Authorization: "Bearer valid", "Content-Type": "application/json" }, body: JSON.stringify(body) });
}
afterEach(async () => Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve())))));

describe("management listing endpoints", () => {
  it("denies staff and cross-organization access on both endpoints", async () => {
    for (const suffix of ["branches", "users"]) {
      assert.equal((await get(`/api/v1/management/organizations/${ids.orgA}/${suffix}`, deps("staff"))).status, 403);
      assert.equal((await get(`/api/v1/management/organizations/${ids.orgB}/${suffix}`)).status, 403);
    }
  });
  it("rejects invalid organization and invalid/broad user queries", async () => {
    for (const path of [
      "/api/v1/management/organizations/not-a-uuid/branches",
      `/api/v1/management/organizations/${ids.orgA}/users?page=0`,
      `/api/v1/management/organizations/${ids.orgA}/users?page_size=51`,
      `/api/v1/management/organizations/${ids.orgA}/users?role=organization_manager`,
      `/api/v1/management/organizations/${ids.orgA}/users?extra=true`,
    ]) assert.equal((await get(path)).status, 400);
  });
  it("returns bounded minimal branch and account contracts", async () => {
    const branchResponse = await get(`/api/v1/management/organizations/${ids.orgA}/branches`);
    assert.deepEqual(await branchResponse.json(), { branches: [{ id: ids.branch, name: "Active A", code: "AA" }] });
    const userResponse = await get(`/api/v1/management/organizations/${ids.orgA}/users?page=1&page_size=20&search=Person&role=staff&branch_id=${ids.branch}&lifecycle=active`);
    const text = await userResponse.text();
    assert.equal(userResponse.status, 200);
    assert.deepEqual(Object.keys(JSON.parse(text)).sort(), ["pagination", "users"]);
    assert.doesNotMatch(text, /temporary_password|access_token|refresh_token|metadata|identities|secret/i);
  });
  it("lets a manager create a branch and then list it", async () => {
    const dependencies = deps();
    const response = await post(`/api/v1/management/organizations/${ids.orgA}/branches`, { name: "Burger Hunch Al Takhassusi", code: " hun-ruh ", city: " Riyadh ", area: " Olaya ", address: " Main Road ", timezone: "Asia/Riyadh", active: true }, dependencies);
    assert.equal(response.status, 201);
    assert.deepEqual(await response.json(), { branch: { id: "34000000-0000-4000-8000-000000000002", name: "Burger Hunch Al Takhassusi", code: "HUN-RUH", city: "Riyadh", area: "Olaya", address: "Main Road", timezone: "Asia/Riyadh", active: true } });
    const duplicateCodeResponse = await post(`/api/v1/management/organizations/${ids.orgA}/branches`, { name: "Burger Hunch Olaya", code: "HUN-RUH", city: "Riyadh", area: "Olaya", address: "Olaya Road", timezone: "Asia/Riyadh", active: true }, dependencies);
    assert.equal(duplicateCodeResponse.status, 201);
    assert.deepEqual(await duplicateCodeResponse.json(), { branch: { id: "34000000-0000-4000-8000-000000000003", name: "Burger Hunch Olaya", code: "HUN-RUH", city: "Riyadh", area: "Olaya", address: "Olaya Road", timezone: "Asia/Riyadh", active: true } });
    const branchResponse = await get(`/api/v1/management/organizations/${ids.orgA}/branches`, dependencies);
    assert.deepEqual(await branchResponse.json(), { branches: [
      { id: ids.branch, name: "Active A", code: "AA" },
      { id: "34000000-0000-4000-8000-000000000002", name: "Burger Hunch Al Takhassusi", code: "HUN-RUH" },
      { id: "34000000-0000-4000-8000-000000000003", name: "Burger Hunch Olaya", code: "HUN-RUH" },
    ] });
  });
  it("rejects invalid, duplicate, unauthorized, and cross-organization branch creation", async () => {
    assert.equal((await post(`/api/v1/management/organizations/${ids.orgA}/branches`, { name: " ", code: "MLT-RUH-002", city: "Riyadh" })).status, 400);
    assert.equal((await post(`/api/v1/management/organizations/${ids.orgA}/branches`, { name: "Branch", code: "BAD/CODE", city: "Riyadh" })).status, 400);
    assert.equal((await post(`/api/v1/management/organizations/${ids.orgA}/branches`, { name: "Branch", code: "MLT-RUH-002", city: " " })).status, 400);
    assert.equal((await post(`/api/v1/management/organizations/${ids.orgA}/branches`, { name: "Active A", code: "MLT-RUH-002", city: "Riyadh", timezone: "Asia/Riyadh", active: true })).status, 409);
    assert.equal((await post(`/api/v1/management/organizations/${ids.orgA}/branches`, { name: "Staff Branch", code: "MLT-RUH-003", city: "Riyadh", timezone: "Asia/Riyadh", active: true }, deps("staff"))).status, 403);
    assert.equal((await post(`/api/v1/management/organizations/${ids.orgB}/branches`, { name: "Cross Branch", code: "MLT-RUH-004", city: "Riyadh", timezone: "Asia/Riyadh", active: true })).status, 403);
  });
  it("redacts raw branch and RPC errors", async () => {
    for (const suffix of ["branches", "users"]) {
      const response = await get(`/api/v1/management/organizations/${ids.orgA}/${suffix}`, deps("manager", true));
      const text = await response.text();
      assert.equal(response.status, 503);
      assert.doesNotMatch(text, /RAW_|DATABASE|AUTH_SECRET/i);
    }
  });
});
