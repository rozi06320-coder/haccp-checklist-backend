import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { AdminAccessError, AdminConflictError, AdminDuplicatePersonCodeError, AdminDuplicateStaffCodeError, AdminInputError, AdminNotFoundError, ProvisioningStageError, type FinalizeProvisionedOrganizationManagerInput, type FinalizeProvisionedUserInput } from "./admin";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const ids = {
  actor: "10000000-0000-4000-8000-000000000001",
  created: "10000000-0000-4000-8000-000000000002",
  orgA: "20000000-0000-4000-8000-000000000001",
  orgB: "20000000-0000-4000-8000-000000000002",
  branch: "30000000-0000-4000-8000-000000000001",
  team: "40000000-0000-4000-8000-000000000001",
};
const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});
const servers: ReturnType<typeof createServer>[] = [];

function deps(options: {
  manager?: boolean;
  internalAdmin?: boolean;
  branches?: boolean;
  createError?: Error;
  finalizeError?: Error;
  finalizeManagerError?: Error;
  branchError?: Error;
  organizationLifecycleError?: Error;
  branchLifecycleError?: Error;
  supervisorProfileError?: Error;
  deleteError?: Error;
  contextError?: Error;
  calls?: Record<string, unknown>;
} = {}): BackendDependencies {
  const calls = options.calls ?? {};
  return {
    authVerifier: { async verify(token) { return token === "valid" ? { userId: ids.actor, email: "actor@example.invalid" } : null; } },
    async checkReadiness() { return true; },
    createUserContext() {
      return {
        async getUserContext() {
          if (options.contextError) throw options.contextError;
          return { id: ids.actor, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [] };
        },
        async isInternalAdmin() { return options.internalAdmin ?? true; },
        async hasOrganizationManagerAccess(_actor, organization) {
          return (options.manager ?? true) && organization === ids.orgA;
        },
        async validateActiveBranches() { return options.branches ?? true; },
        async listActiveBranches() { return []; },
      };
    },
    passwordChange: {
      async verifyCurrent() { return true; },
      async updatePassword() {},
      async finalize() {},
    },
    provisioningAdmin: {
      async createUser(input) {
        calls.create = input;
        if (options.createError) throw options.createError;
        return { id: ids.created };
      },
      async finalize(input) {
        calls.finalize = input;
        if (options.finalizeError) throw options.finalizeError;
      },
      async finalizeOrganizationManager(input) {
        calls.finalizeOrganizationManager = input;
        if (options.finalizeManagerError) throw options.finalizeManagerError;
      },
      async deleteUser(id) {
        calls.deleted = id;
        if (options.deleteError) throw options.deleteError;
      },
    },
    managementAdmin: {
      async listUsers() { return { users: [], total: 0 }; },
      async createOrganizationForInternalAdmin(input) {
        calls.createOrganization = input;
        if (input.name === "Duplicate Org") throw new AdminConflictError();
        return { id: ids.orgA, name: input.name, slug: "created-org", active: true };
      },
      async updateOrganizationForInternalAdmin(input) {
        calls.updateOrganization = input;
        if (options.organizationLifecycleError) throw options.organizationLifecycleError;
        return { id: input.organizationId, name: input.name, name_ar: input.nameAr ?? null, slug: "stable-org", active: true };
      },
      async deactivateOrganizationForInternalAdmin(input) {
        calls.deactivateOrganization = input;
        if (options.organizationLifecycleError) throw options.organizationLifecycleError;
        return { id: input.organizationId, name: "Organization A", slug: "stable-org", active: false };
      },
      async reactivateOrganizationForInternalAdmin(input) {
        calls.reactivateOrganization = input;
        if (options.organizationLifecycleError) throw options.organizationLifecycleError;
        return { id: input.organizationId, name: "Organization A", slug: "stable-org", active: true };
      },
      async listOrganizationsForInternalAdmin(input) {
        calls.listOrganizations = input;
        return [
          { id: ids.orgA, name: "AlKhaleejiah Food Specialized Trading co", active: true },
          { id: ids.orgB, name: "Burger Hunch Demo", active: true },
        ];
      },
      async listOrganizationManagersForInternalAdmin() {
        return [{
          id: ids.created,
          full_name: "Organization Manager",
          email: "manager@example.invalid",
          organization_id: ids.orgA,
          organization_name: "Organization A",
          active: true,
          must_change_password: true,
          disabled: false,
          created_at: "2026-08-08T00:00:00Z",
          updated_at: "2026-08-08T00:00:00Z",
        }];
      },
      async deactivateOrganizationManagerForInternalAdmin(input) {
        calls.deactivateOrganizationManager = input;
      },
      async listBranchesForInternalAdmin(_actorUserId, organizationId) {
        if (!(options.branches ?? true) || organizationId !== ids.orgA) return [];
        return [{ id: ids.branch, name: "Branch", code: "BR", city: null, area: null, address: null, timezone: "Asia/Riyadh", active: true }];
      },
      async createBranch(input) {
        calls.createBranch = input;
        return { id: ids.branch, name: input.name, code: input.code, city: input.city, area: input.area ?? null, address: input.address ?? null, timezone: input.timezone, active: input.active };
      },
      async createBranchForInternalAdmin(input) {
        calls.createBranchForInternalAdmin = input;
        if (options.branchError) throw options.branchError;
        return {
          id: ids.branch,
          organization_id: input.organizationId,
          name: input.name,
          name_ar: input.nameAr ?? null,
          code: input.code,
          city: input.city,
          area: input.area ?? null,
          address: input.address ?? null,
          timezone: input.timezone,
          active: input.active,
        };
      },
      async updateBranchForInternalAdmin(input) {
        calls.updateBranchForInternalAdmin = input;
        if (options.branchLifecycleError) throw options.branchLifecycleError;
        return {
          id: input.branchId,
          organization_id: input.organizationId,
          name: input.name,
          name_ar: input.nameAr ?? null,
          code: input.code,
          city: input.city,
          area: input.area ?? null,
          address: input.address ?? null,
          timezone: input.timezone,
          active: true,
        };
      },
      async deactivateBranchForInternalAdmin(input) {
        calls.deactivateBranchForInternalAdmin = input;
        if (options.branchLifecycleError) throw options.branchLifecycleError;
        return {
          id: input.branchId,
          organization_id: input.organizationId,
          name: "Branch",
          code: "BR",
          timezone: "Asia/Riyadh",
          active: false,
        };
      },
      async reactivateBranchForInternalAdmin(input) {
        calls.reactivateBranchForInternalAdmin = input;
        if (options.branchLifecycleError) throw options.branchLifecycleError;
        return {
          id: input.branchId,
          organization_id: input.organizationId,
          name: "Branch",
          code: "BR",
          timezone: "Asia/Riyadh",
          active: true,
        };
      },
      async listSupervisorsForInternalAdmin() { return []; },
      async updateSupervisorProfileForInternalAdmin(input) {
        calls.updateSupervisorProfile = input;
        if (options.supervisorProfileError) throw options.supervisorProfileError;
        return {
          id: input.userId,
          full_name: input.fullName,
          full_name_ar: input.fullNameAr ?? null,
          person_code: input.personCode ?? null,
          phone_number: input.phoneNumber ?? null,
          country_code: input.countryCode ?? null,
          iqama_number: input.iqamaNumber ?? null,
          iqama_expiry_date: input.iqamaExpiryDate ?? null,
          email: "supervisor@example.invalid",
          updated_at: "2026-08-15T10:00:00Z",
        };
      },
      async deactivateSupervisorForInternalAdmin(input) { calls.deactivateSupervisor = input; },
      async reactivateSupervisorForInternalAdmin(input) { calls.reactivateSupervisor = input; },
      async grantExistingSupervisorForInternalAdmin(input) { calls.grantExistingSupervisor = input; },
      async listBranchTeamsForInternalAdmin() {
        return [{
          team_id: "40000000-0000-4000-8000-000000000001",
          organization_id: ids.orgA,
          team_name: "Kitchen Team",
          company_name: "Manual Company",
          branch_id: ids.branch,
          branch_name: "Branch",
          branch_code: "BR",
          supervisor_user_id: ids.created,
          supervisor_name: "Supervisor",
          supervisor_email: "supervisor@example.invalid",
          supervisor_role: "branch_manager",
          backup_supervisors: [],
          active: true,
          operational_staff_count: 0,
          staff: [{
            staff_id: "50000000-0000-4000-8000-000000000001",
            display_name: "Kitchen Staff",
            company_name: "Manual Company",
            staff_code: "KS-01",
            country_code: "SA",
            employment_status: "active",
            assignment_id: "60000000-0000-4000-8000-000000000001",
            operational_roles: ["kitchen"],
          }],
        }];
      },
      async createBranchTeamForInternalAdmin(input) {
        calls.createBranchTeam = input;
        return {
          team_id: "40000000-0000-4000-8000-000000000001",
          organization_id: input.organizationId,
          team_name: input.teamName,
          company_name: input.companyName,
          branch_id: input.branchId,
          branch_name: "Branch",
          branch_code: "BR",
          supervisor_user_id: input.primarySupervisorUserId,
          supervisor_name: "Supervisor",
          supervisor_email: "supervisor@example.invalid",
          supervisor_role: "branch_manager",
          backup_supervisors: [],
          active: true,
          operational_staff_count: input.initialStaff?.length ?? 0,
          staff: [],
        };
      },
      async createBranchTeamStaffForInternalAdmin(input) {
        calls.createBranchTeamStaff = input;
        if (input.staffCode === "DUPLICATE") throw new AdminDuplicateStaffCodeError();
        return {
          staff_id: "50000000-0000-4000-8000-000000000001",
          assignment_id: "60000000-0000-4000-8000-000000000001",
          duplicate_name_warning: false,
        };
      },
      async reactivateOrganizationManagerForInternalAdmin(input) { calls.reactivateOrganizationManager = input; },
      async grantExistingOrganizationManagerForInternalAdmin(input) {
        calls.grantExistingOrganizationManager = input;
        if (input.email === "missing@example.invalid") throw new AdminNotFoundError();
      },
      async listMaintenanceUsers() { return []; },
      async deactivateMaintenanceUser(input) { calls.deactivateMaintenanceUser = input; },
      async reactivateMaintenanceUser(input) { calls.reactivateMaintenanceUser = input; },
      async grantExistingMaintenanceUser(input) {
        calls.grantExistingMaintenanceUser = input;
        if (input.email === "missing@example.invalid") throw new AdminNotFoundError();
      },
    },
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

async function post(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid", appConfig = config) {
  const server = createServer(createApp(appConfig, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/supervisors`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function patchSupervisorProfile(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, supervisor = ids.created, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/supervisors/${supervisor}/profile`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postManager(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/management/organizations/${organization}/users`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postOrganizationManager(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/managers`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postExistingOrganizationManager(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/managers/existing`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postInternalAdminBranch(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/branches`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postInternalAdminBranchTeam(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/branch-teams`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postInternalAdminBranchTeamStaff(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, team = "40000000-0000-4000-8000-000000000001", token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/branch-teams/${team}/staff`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postInternalAdminOrganization(dependencies: BackendDependencies, body: unknown, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function patchInternalAdminOrganization(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postInternalAdminOrganizationLifecycle(dependencies: BackendDependencies, action: "deactivate" | "reactivate", organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/${action}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
}

async function patchInternalAdminBranch(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, branch = ids.branch, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/branches/${branch}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function postInternalAdminBranchLifecycle(dependencies: BackendDependencies, action: "deactivate" | "reactivate", organization = ids.orgA, branch = ids.branch, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/branches/${branch}/${action}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
}

async function deleteOrganizationManager(dependencies: BackendDependencies, userId = ids.created, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/managers/${userId}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
}

async function patchOrganizationManager(dependencies: BackendDependencies, userId = ids.created, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/managers/${userId}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ active: true }),
  });
}

async function postExistingSupervisor(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/supervisors/existing`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function patchSupervisor(dependencies: BackendDependencies, userId = ids.created, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/supervisors/${userId}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ active: true }),
  });
}

async function postExistingMaintenanceUser(dependencies: BackendDependencies, body: unknown, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/maintenance-users/existing`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function patchMaintenanceUser(dependencies: BackendDependencies, userId = ids.created, organization = ids.orgA, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}/api/v1/internal-admin/organizations/${organization}/maintenance-users/${userId}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ active: true }),
  });
}

async function get(dependencies: BackendDependencies, path: string, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}${path}`, { headers: { Authorization: `Bearer ${token}` } });
}

function origin(server: ReturnType<typeof createServer>) {
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

const valid = {
  full_name: "  New   Person ",
  email: " New.Person@Example.Invalid ",
  temporary_password: ` ${"p".repeat(14)} `,
  branch_ids: [ids.branch],
  supervisor_team_assignments: [{ operational_team_id: ids.team, assignment_role: "primary" }],
};
const validOrganizationManager = {
  full_name: "  Organization   Manager ",
  email: " Manager@Example.Invalid ",
  temporary_password: "temporary-secret",
};
const numericOnlyPassword = Array.from(
  { length: 6 },
  (_, index) => String((index + 1) % 10),
).join("");
const letterOnlyPassword = "p".repeat(6);

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

describe("internal-admin supervisor provisioning", () => {
  it("denies missing/invalid tokens, non-admins, and inactive organizations", async () => {
    for (const [dependency, organization, token, status] of [
      [deps(), ids.orgA, "invalid", 401],
      [deps({ internalAdmin: false }), ids.orgA, "valid", 403],
      [deps(), ids.orgB, "valid", 404],
    ] as const) assert.equal((await post(dependency, valid, organization, token)).status, status);
  });

  it("lists Internal Admin branches and supervisors", async () => {
    const branches = await get(deps(), `/api/v1/internal-admin/organizations/${ids.orgA}/branches`);
    assert.equal(branches.status, 200);
    const branchesText = await branches.text();
    assert.match(branchesText, /Branch/);
    assert.match(branchesText, /Asia\/Riyadh/);
    const supervisors = await get(deps(), `/api/v1/internal-admin/organizations/${ids.orgA}/supervisors`);
    assert.equal(supervisors.status, 200);
    assert.match(await supervisors.text(), /supervisors/);
    const managers = await get(deps(), `/api/v1/internal-admin/organizations/${ids.orgA}/managers`);
    assert.equal(managers.status, 200);
    const managerText = await managers.text();
    assert.match(managerText, /Organization Manager/);
    assert.doesNotMatch(managerText, /temporary_password|service_role|token/i);
  });

  it("lists all Internal Admin organizations without requiring manager membership or active-only filtering", async () => {
    const calls: Record<string, unknown> = {};
    const response = await get(deps({ manager: false, calls }), "/api/v1/internal-admin/organizations");
    assert.equal(response.status, 200);
    assert.equal(calls.listOrganizations, ids.actor);
    assert.deepEqual(await response.json(), {
      organizations: [
        { id: ids.orgA, name: "AlKhaleejiah Food Specialized Trading co", name_ar: null, active: true, logo_url: null },
        { id: ids.orgB, name: "Burger Hunch Demo", name_ar: null, active: true, logo_url: null },
      ],
    });
  });

  it("lists Internal Admin organizations without loading manager or supervisor user context", async () => {
    const calls: Record<string, unknown> = {};
    const response = await get(deps({
      calls,
      contextError: new Error("non-admin membership context unavailable"),
      manager: false,
    }), "/api/v1/internal-admin/organizations");

    assert.equal(response.status, 200);
    assert.equal(calls.listOrganizations, ids.actor);
    const body = await response.json();
    assert.equal(body.organizations[0].active, true);
  });

  it("denies organization listing to anonymous and non-Internal Admin users", async () => {
    assert.equal((await get(deps(), "/api/v1/internal-admin/organizations", "invalid")).status, 401);
    assert.equal((await get(deps({ internalAdmin: false }), "/api/v1/internal-admin/organizations")).status, 403);
  });

  it("lets Internal Admin create organizations with safe output", async () => {
    const calls: Record<string, unknown> = {};
    const response = await postInternalAdminOrganization(deps({ calls }), { name: "  Created   Org " });
    const text = await response.text();
    assert.equal(response.status, 201);
    assert.deepEqual(calls.createOrganization, {
      actorUserId: ids.actor,
      name: "Created Org",
      nameAr: null,
    });
    assert.deepEqual(JSON.parse(text), {
      organization: { id: ids.orgA, name: "Created Org", name_ar: null, slug: "created-org", active: true },
    });
    assert.doesNotMatch(text, /service_role|token|password|secret|stack/i);
  });

  it("denies organization creation to non-admins and handles invalid or duplicate names safely", async () => {
    assert.equal((await postInternalAdminOrganization(deps(), { name: "Org" }, "invalid")).status, 401);
    assert.equal((await postInternalAdminOrganization(deps({ internalAdmin: false }), { name: "Org" })).status, 403);
    assert.equal((await postInternalAdminOrganization(deps(), { name: " " })).status, 400);
    const duplicate = await postInternalAdminOrganization(deps(), { name: "Duplicate Org" });
    assert.equal(duplicate.status, 409);
    assert.doesNotMatch(await duplicate.text(), /postgres|duplicate key|service_role|stack/i);
  });

  it("lets Internal Admin edit and deactivate/reactivate organizations without changing stable identity", async () => {
    const calls: Record<string, unknown> = {};
    const update = await patchInternalAdminOrganization(deps({ calls }), { name: "  Renamed   Org ", name_ar: " منظمة " });
    assert.equal(update.status, 200);
    assert.deepEqual(calls.updateOrganization, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      name: "Renamed Org",
      nameAr: "منظمة",
    });
    assert.deepEqual(await update.json(), {
      organization: { id: ids.orgA, name: "Renamed Org", name_ar: "منظمة", slug: "stable-org", active: true },
    });

    const deactivate = await postInternalAdminOrganizationLifecycle(deps({ calls }), "deactivate");
    assert.equal(deactivate.status, 200);
    assert.deepEqual(calls.deactivateOrganization, { actorUserId: ids.actor, organizationId: ids.orgA });
    assert.equal((await deactivate.json()).organization.active, false);

    const reactivate = await postInternalAdminOrganizationLifecycle(deps({ calls }), "reactivate");
    assert.equal(reactivate.status, 200);
    assert.deepEqual(calls.reactivateOrganization, { actorUserId: ids.actor, organizationId: ids.orgA });
    assert.equal((await reactivate.json()).organization.active, true);
  });

  it("maps Internal Admin organization lifecycle errors safely", async () => {
    assert.equal((await patchInternalAdminOrganization(deps(), { name: "Org" }, ids.orgA, "invalid")).status, 401);
    assert.equal((await patchInternalAdminOrganization(deps({ internalAdmin: false }), { name: "Org" })).status, 403);
    assert.equal((await patchInternalAdminOrganization(deps(), { name: " " })).status, 400);

    const duplicate = await patchInternalAdminOrganization(deps({ organizationLifecycleError: new AdminConflictError() }), { name: "Org" });
    assert.equal(duplicate.status, 409);
    assert.match(await duplicate.text(), /Organization already exists/);

    const missing = await patchInternalAdminOrganization(deps({ organizationLifecycleError: new AdminNotFoundError() }), { name: "Org" });
    assert.equal(missing.status, 404);
    assert.match(await missing.text(), /Organization is unavailable/);
    assert.doesNotMatch(await (await postInternalAdminOrganizationLifecycle(deps({ organizationLifecycleError: new Error("raw postgres failure") }), "deactivate")).text(), /postgres|raw|stack/i);
  });

  it("lets Internal Admin create an empty branch through the branch creation adapter", async () => {
    const calls: Record<string, unknown> = {};
    const response = await postInternalAdminBranch(deps({ calls }), {
      name: "  New   Branch ",
      code: " hun-ruh-001 ",
      city: "  Riyadh   North ",
      area: " Al   Takhassusi ",
      address: " 123 King Road ",
      timezone: "Asia/Riyadh",
      active: true,
    });
    const text = await response.text();
    assert.equal(response.status, 201);
    assert.deepEqual(calls.createBranchForInternalAdmin, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      name: "New Branch",
      nameAr: null,
      code: "HUN-RUH-001",
      city: "Riyadh North",
      area: "Al Takhassusi",
      address: "123 King Road",
      timezone: "Asia/Riyadh",
      active: true,
    });
    assert.deepEqual(JSON.parse(text), {
      branch: {
        id: ids.branch,
        organization_id: ids.orgA,
        name: "New Branch",
        name_ar: null,
        code: "HUN-RUH-001",
        city: "Riyadh North",
        area: "Al Takhassusi",
        address: "123 King Road",
        timezone: "Asia/Riyadh",
        active: true,
      },
    });
    assert.doesNotMatch(text, /supervisor_team|operational_staff|password|service_role/i);
  });

  it("lets Internal Admin edit branch code and deactivate/reactivate branches without changing branch id", async () => {
    const calls: Record<string, unknown> = {};
    const update = await patchInternalAdminBranch(deps({ calls }), { name: "  Renamed   Branch ", name_ar: " فرع ", code: " hun-ruh-001 ", city: " Jeddah ", area: " Al   Hamra ", address: "  Sea Road  ", timezone: "UTC" });
    assert.equal(update.status, 200);
    assert.deepEqual(calls.updateBranchForInternalAdmin, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      branchId: ids.branch,
      name: "Renamed Branch",
      nameAr: "فرع",
      code: "HUN-RUH-001",
      city: "Jeddah",
      area: "Al Hamra",
      address: "Sea Road",
      timezone: "UTC",
    });
    assert.deepEqual(await update.json(), {
      branch: {
        id: ids.branch,
        organization_id: ids.orgA,
        name: "Renamed Branch",
        name_ar: "فرع",
        code: "HUN-RUH-001",
        city: "Jeddah",
        area: "Al Hamra",
        address: "Sea Road",
        timezone: "UTC",
        active: true,
      },
    });

    const deactivate = await postInternalAdminBranchLifecycle(deps({ calls }), "deactivate");
    assert.equal(deactivate.status, 200);
    assert.deepEqual(calls.deactivateBranchForInternalAdmin, { actorUserId: ids.actor, organizationId: ids.orgA, branchId: ids.branch });
    assert.equal((await deactivate.json()).branch.active, false);

    const reactivate = await postInternalAdminBranchLifecycle(deps({ calls }), "reactivate");
    assert.equal(reactivate.status, 200);
    assert.deepEqual(calls.reactivateBranchForInternalAdmin, { actorUserId: ids.actor, organizationId: ids.orgA, branchId: ids.branch });
    assert.equal((await reactivate.json()).branch.active, true);
  });

  it("maps Internal Admin branch lifecycle errors safely", async () => {
    const validUpdateBody = { name: "Branch", code: "HUN-RUH-001", city: "Riyadh", timezone: "UTC" };
    assert.equal((await patchInternalAdminBranch(deps(), validUpdateBody, ids.orgA, ids.branch, "invalid")).status, 401);
    assert.equal((await patchInternalAdminBranch(deps({ internalAdmin: false }), validUpdateBody)).status, 403);
    assert.equal((await patchInternalAdminBranch(deps(), { name: " ", code: "HUN-RUH-001", city: "Riyadh", timezone: "UTC" })).status, 400);
    assert.equal((await patchInternalAdminBranch(deps(), { name: "Branch", code: " ", city: "Riyadh", timezone: "UTC" })).status, 400);
    assert.equal((await patchInternalAdminBranch(deps(), { name: "Branch", code: "BAD/CODE", city: "Riyadh", timezone: "UTC" })).status, 400);
    assert.equal((await patchInternalAdminBranch(deps(), { name: "Branch", code: "HUN-RUH-001", city: " ", timezone: "UTC" })).status, 400);
    assert.equal((await patchInternalAdminBranch(deps(), { name: "Branch", code: "HUN-RUH-001", city: "Riyadh", timezone: "Bad/Zone" })).status, 400);

    const duplicate = await patchInternalAdminBranch(deps({ branchLifecycleError: new AdminConflictError() }), validUpdateBody);
    assert.equal(duplicate.status, 409);
    assert.match(await duplicate.text(), /Branch already exists/);

    const invalidDetails = await patchInternalAdminBranch(deps({ branchLifecycleError: new AdminInputError() }), validUpdateBody);
    assert.equal(invalidDetails.status, 422);
    assert.match(await invalidDetails.text(), /valid branch details/);

    const missing = await patchInternalAdminBranch(deps({ branchLifecycleError: new AdminNotFoundError() }), validUpdateBody);
    assert.equal(missing.status, 404);
    assert.match(await missing.text(), /Organization is unavailable/);
    assert.doesNotMatch(await (await postInternalAdminBranchLifecycle(deps({ branchLifecycleError: new Error("raw postgres failure") }), "deactivate")).text(), /postgres|raw|stack/i);
  });

  it("lists and creates Internal Admin Branch Teams without staff creation output", async () => {
    const calls: Record<string, unknown> = {};
    const list = await get(deps({ calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/branch-teams`);
    const listText = await list.text();
    assert.equal(list.status, 200);
    assert.match(listText, /"teams"/);
    assert.match(listText, /supervisor@example\.invalid/);
    assert.match(listText, /"team_name":"Kitchen Team"/);
    assert.match(listText, /"company_name":"Manual Company"/);
    assert.match(listText, /"branch_code":"BR"/);
    assert.match(listText, /"supervisor_role":"branch_manager"/);
    assert.match(listText, /"display_name":"Kitchen Staff"/);
    assert.match(listText, /"staff_code":"KS-01"/);
    assert.match(listText, /"country_code":"SA"/);
    assert.match(listText, /"operational_roles":\["kitchen"\]/);
    assert.doesNotMatch(listText, /password|service_role|token|secret/i);

    const create = await postInternalAdminBranchTeam(deps({ calls }), {
      team_name: "Kitchen Team",
      company_name: "Manual Company",
      branch_id: ids.branch,
      primary_supervisor_user_id: ids.created,
      initial_staff: [{
        display_name: "Cashier Staff",
        company_name: "Manual Company",
        staff_code: "CS-01",
        country_code: "SA",
        primary_role: "cashier",
      }],
    });
    const createText = await create.text();
    assert.equal(create.status, 201);
    assert.deepEqual(calls.createBranchTeam, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      teamName: "Kitchen Team",
      companyName: "Manual Company",
      branchId: ids.branch,
      primarySupervisorUserId: ids.created,
      backupSupervisorUserId: null,
      initialStaff: [{
        displayName: "Cashier Staff",
        companyName: "Manual Company",
        staffCode: "CS-01",
        countryCode: "SA",
        roles: ["cashier"],
      }],
    });
    assert.match(createText, /"team"/);
    assert.match(createText, /"team_name":"Kitchen Team"/);
    assert.match(createText, /"operational_staff_count":1/);
    assert.match(createText, /"company_name":"Manual Company"/);
    assert.match(createText, /"branch_code":"BR"/);
    assert.match(createText, /"supervisor_role":"branch_manager"/);
    assert.doesNotMatch(createText, /temporary_password|service_role|secret|stack/i);
  });

  it("lets Internal Admin create Operational Staff under a Branch Team", async () => {
    const calls: Record<string, unknown> = {};
    const response = await postInternalAdminBranchTeamStaff(deps({ calls }), {
      display_name: "  Kitchen   Staff ",
      company_name: " Manual Company ",
      staff_code: " KS-01 ",
      country_code: "id",
      primary_role: "kitchen",
      secondary_role: "dispatcher",
    });
    const text = await response.text();
    assert.equal(response.status, 201);
    assert.deepEqual(calls.createBranchTeamStaff, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      teamId: "40000000-0000-4000-8000-000000000001",
      displayName: "Kitchen Staff",
      companyName: "Manual Company",
      staffCode: "KS-01",
      countryCode: "ID",
      roles: ["kitchen", "dispatcher"],
    });
    assert.match(text, /"staff_id"/);
    assert.doesNotMatch(text, /temporary_password|service_role|secret|stack/i);
  });

  it("returns a structured Internal Admin conflict for duplicate employee codes", async () => {
    const response = await postInternalAdminBranchTeamStaff(deps(), {
      display_name: "Kitchen Staff",
      company_name: "Manual Company",
      staff_code: "DUPLICATE",
      primary_role: "cashier",
    });
    const text = await response.text();
    assert.equal(response.status, 409);
    assert.match(text, /duplicate_employee_code/);
    assert.doesNotMatch(text, /postgres|duplicate key|service_role|stack/i);
  });

  it("denies Internal Admin branch creation to non-admins and invalid payloads", async () => {
    assert.equal((await postInternalAdminBranch(deps(), { name: "Branch" }, ids.orgA, "invalid")).status, 401);
    assert.equal((await postInternalAdminBranch(deps({ internalAdmin: false }), { name: "Branch", code: "HUN-RUH-002", city: "Riyadh", timezone: "Asia/Riyadh" })).status, 403);
    assert.equal((await postInternalAdminBranch(deps(), { name: " ", code: "HUN-RUH-002", city: "Riyadh", timezone: "Asia/Riyadh" })).status, 400);
    assert.equal((await postInternalAdminBranch(deps(), { name: "Branch", code: "BAD/CODE", city: "Riyadh", timezone: "Asia/Riyadh" })).status, 400);
    assert.equal((await postInternalAdminBranch(deps(), { name: "Branch", code: "HUN-RUH-002", city: " ", timezone: "Asia/Riyadh" })).status, 400);
    assert.equal((await postInternalAdminBranch(deps(), { name: "Branch", code: "HUN-RUH-002", city: "Riyadh", timezone: "Bad/Zone" })).status, 400);
  });

  it("maps Internal Admin branch creation failures to safe responses", async () => {
    const duplicate = await postInternalAdminBranch(deps({ branchError: new AdminConflictError() }), { name: "Branch", code: "HUN-RUH-003", city: "Riyadh", timezone: "Asia/Riyadh" });
    assert.equal(duplicate.status, 409);
    assert.match(await duplicate.text(), /Branch already exists/);

    const invalidDetails = await postInternalAdminBranch(deps({ branchError: new AdminInputError() }), { name: "Branch", code: "HUN-RUH-003", city: "Riyadh", timezone: "Asia/Riyadh" });
    assert.equal(invalidDetails.status, 422);
    assert.match(await invalidDetails.text(), /valid branch details/);

    const missingOrganization = await postInternalAdminBranch(deps({ branchError: new AdminNotFoundError() }), { name: "Branch", code: "HUN-RUH-003", city: "Riyadh", timezone: "Asia/Riyadh" });
    assert.equal(missingOrganization.status, 404);
    assert.match(await missingOrganization.text(), /Organization is unavailable/);
  });

  it("denies Internal Admin Branch Teams to non-admins and invalid payloads", async () => {
    assert.equal((await postInternalAdminBranchTeam(deps(), { team_name: "Kitchen Team", company_name: "Manual Company", branch_id: ids.branch, primary_supervisor_user_id: ids.created }, ids.orgA, "invalid")).status, 401);
    assert.equal((await postInternalAdminBranchTeam(deps({ internalAdmin: false }), { team_name: "Kitchen Team", company_name: "Manual Company", branch_id: ids.branch, primary_supervisor_user_id: ids.created })).status, 403);
    assert.equal((await postInternalAdminBranchTeam(deps(), { team_name: "Kitchen Team", company_name: "Manual Company", branch_id: "bad", primary_supervisor_user_id: ids.created })).status, 400);
    assert.equal((await postInternalAdminBranchTeam(deps(), { branch_id: ids.branch })).status, 400);
    assert.equal((await postInternalAdminBranchTeam(deps(), { team_name: "   ", company_name: "Manual Company", branch_id: ids.branch, primary_supervisor_user_id: ids.created })).status, 400);
    assert.equal((await postInternalAdminBranchTeamStaff(deps(), { display_name: "Staff", company_name: "Manual Company", primary_role: "kitchen" }, ids.orgA, "bad")).status, 400);
    assert.equal((await postInternalAdminBranchTeamStaff(deps({ internalAdmin: false }), { display_name: "Staff", company_name: "Manual Company", primary_role: "kitchen" })).status, 403);
    assert.equal((await postInternalAdminBranchTeamStaff(deps(), { display_name: "Staff", company_name: "Manual Company", primary_role: "kitchen", secondary_role: "kitchen" })).status, 400);
  });

  it("returns safe Branch Team creation errors", async () => {
    const dependencies = deps();
    dependencies.managementAdmin.createBranchTeamForInternalAdmin = async () => {
      throw new Error("RAW_SUPABASE_BRANCH_TEAM_SECRET");
    };
    const response = await postInternalAdminBranchTeam(dependencies, {
      team_name: "Kitchen Team",
      company_name: "Manual Company",
      branch_id: ids.branch,
      primary_supervisor_user_id: ids.created,
    });
    const text = await response.text();
    assert.equal(response.status, 400);
    assert.doesNotMatch(text, /RAW_|supabase|service_role|secret|stack/i);
  });

  it("keeps the old Manager supervisor creation endpoint fail closed", async () => {
    const calls: Record<string, unknown> = {};
    const managerProvisioningBody = {
      full_name: valid.full_name,
      email: valid.email,
      temporary_password: valid.temporary_password,
      branch_ids: valid.branch_ids,
    };
    const response = await postManager(deps({ manager: true, calls }), managerProvisioningBody);
    assert.equal(response.status, 403);
    assert.equal(calls.create, undefined);
    assert.equal(calls.finalize, undefined);
  });

  it("rejects invalid path/body/name/email/password/role/branch arrays", async () => {
    const cases: Array<[unknown, string?]> = [
      [{ ...valid, extra: true }],
      [{ ...valid, full_name: " \t " }],
      [{ ...valid, email: "bad" }],
      [{ ...valid, temporary_password: "p".repeat(5) }],
      [{ ...valid, temporary_password: "x".repeat(129) }],
      [{ ...valid, role: "staff" }],
      [{ ...valid, role: "organization_manager" }],
      [{ ...valid, role: "owner" }],
      [{ ...valid, branch_ids: [] }],
      [{ ...valid, branch_ids: [ids.branch, ids.branch] }],
      [{ ...valid, branch_ids: Array.from({ length: 51 }, (_, i) => `30000000-0000-4000-8000-${String(i).padStart(12, "0")}`) }],
      [{ ...valid, supervisor_team_assignments: [{ operational_team_id: ids.team, assignment_role: "primary" }, { operational_team_id: ids.team, assignment_role: "backup" }] }],
      [{ ...valid, supervisor_team_assignments: [{ operational_team_id: ids.team, assignment_role: "assigned" }] }],
      [valid, "not-a-uuid"],
    ];
    for (const [body, organization] of cases) assert.equal((await post(deps(), body, organization)).status, 400);
  });

  it("accepts generated six-character numeric-only and letter-only temporary passwords unchanged", async () => {
    for (const temporaryPassword of [
      numericOnlyPassword,
      letterOnlyPassword,
    ]) {
      const calls: Record<string, unknown> = {};
      const response = await post(
        deps({ calls }),
        { ...valid, temporary_password: temporaryPassword },
      );
      const text = await response.text();
      assert.equal(response.status, 201);
      assert.deepEqual(calls.create, {
        email: "new.person@example.invalid",
        password: temporaryPassword,
      });
      assert.doesNotMatch(
        text,
        new RegExp(temporaryPassword.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
      );
    }
  });

  it("denies missing, inactive, or cross-organization branches before Auth creation", async () => {
    for (const value of ["missing", "inactive", "cross-org"]) {
      const calls: Record<string, unknown> = {};
      const response = await post(deps({ branches: false, calls }), valid);
      assert.equal(response.status, 404, value);
      assert.equal(calls.create, undefined);
    }
  });

  it("creates only a Branch Supervisor with normalized minimal output and unchanged password", async () => {
      const calls: Record<string, unknown> = {};
      const response = await post(deps({ calls }), valid);
      const text = await response.text();
      assert.equal(response.status, 201);
      assert.deepEqual(JSON.parse(text), {
        id: ids.created, full_name: "New Person", full_name_ar: null, person_code: null, phone_number: null, country_code: null, iqama_number: null, iqama_expiry_date: null, role: "branch_manager", branch_ids: [ids.branch], must_change_password: true,
      });
      assert.deepEqual(calls.create, { email: "new.person@example.invalid", password: valid.temporary_password });
      assert.deepEqual(calls.finalize, {
        actorUserId: ids.actor, organizationId: ids.orgA, newUserId: ids.created,
        fullName: "New Person", fullNameAr: null, role: "branch_manager", branchIds: [ids.branch],
        personCode: null, phoneNumber: null, countryCode: null, iqamaNumber: null, iqamaExpiryDate: null,
        supervisorTeamAssignments: [{ operationalTeamId: ids.team, assignmentRole: "primary" }],
      } satisfies FinalizeProvisionedUserInput);
      assert.doesNotMatch(text, /temporary_password|email|token|secret/i);
  });

  it("creates a Branch Supervisor with canonical person profile fields", async () => {
    const calls: Record<string, unknown> = {};
    const response = await post(deps({ calls }), {
      ...valid,
      person_code: "  SUP 001 ",
      phone_number: " +966500000000 ",
      country_code: "np",
      iqama_number: " 0099887766 ",
      iqama_expiry_date: "2027-12-31",
      supervisor_team_assignments: [],
    });
    const body = await response.json();
    assert.equal(response.status, 201);
    assert.deepEqual(body, {
      id: ids.created,
      full_name: "New Person",
      full_name_ar: null,
      person_code: "SUP 001",
      phone_number: "+966500000000",
      country_code: "NP",
      iqama_number: "0099887766",
      iqama_expiry_date: "2027-12-31",
      role: "branch_manager",
      branch_ids: [ids.branch],
      must_change_password: true,
    });
    assert.deepEqual(calls.finalize, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      newUserId: ids.created,
      fullName: "New Person",
      fullNameAr: null,
      personCode: "SUP 001",
      phoneNumber: "+966500000000",
      countryCode: "NP",
      iqamaNumber: "0099887766",
      iqamaExpiryDate: "2027-12-31",
      role: "branch_manager",
      branchIds: [ids.branch],
      supervisorTeamAssignments: [],
    } satisfies FinalizeProvisionedUserInput);
  });

  it("creates a Branch Supervisor with zero operational team assignments", async () => {
    const calls: Record<string, unknown> = {};
    const response = await post(deps({ calls }), { ...valid, supervisor_team_assignments: [] });
    const text = await response.text();
    assert.equal(response.status, 201);
    assert.deepEqual(JSON.parse(text), {
      id: ids.created, full_name: "New Person", full_name_ar: null, person_code: null, phone_number: null, country_code: null, iqama_number: null, iqama_expiry_date: null, role: "branch_manager", branch_ids: [ids.branch], must_change_password: true,
    });
    assert.deepEqual(calls.finalize, {
      actorUserId: ids.actor, organizationId: ids.orgA, newUserId: ids.created,
      fullName: "New Person", fullNameAr: null, role: "branch_manager", branchIds: [ids.branch],
      personCode: null, phoneNumber: null, countryCode: null, iqamaNumber: null, iqamaExpiryDate: null,
      supervisorTeamAssignments: [],
    } satisfies FinalizeProvisionedUserInput);
    assert.doesNotMatch(text, /temporary_password|email|token|secret/i);
  });

  it("rejects invalid supervisor person fields safely", async () => {
    const invalidCountry = await post(deps(), { ...valid, country_code: "ZZ" });
    assert.equal(invalidCountry.status, 422);
    assert.match(await invalidCountry.text(), /Select a valid country/);

    const invalidExpiry = await post(deps(), { ...valid, iqama_expiry_date: "2027-02-30" });
    assert.equal(invalidExpiry.status, 422);
    assert.match(await invalidExpiry.text(), /valid Gregorian Iqama expiry date/);

    const duplicateCode = await post(deps({ finalizeError: new AdminDuplicatePersonCodeError() }), { ...valid, person_code: "SUP-1" });
    assert.equal(duplicateCode.status, 409);
    const duplicateText = await duplicateCode.text();
    assert.match(duplicateText, /Supervisor code already exists/);
    assert.doesNotMatch(duplicateText, /profiles_person_code|SQLSTATE|duplicate key|stack/i);
  });

  it("lets Internal Admin update only canonical Branch Supervisor profile fields", async () => {
    const calls: Record<string, unknown> = {};
    const response = await patchSupervisorProfile(deps({ calls }), {
      full_name: "  Updated   Supervisor  ",
      full_name_ar: "  مشرف محدّث  ",
      person_code: " SUP-002 ",
      phone_number: " +966511111111 ",
      country_code: "ph",
      iqama_number: " 000112233 ",
      iqama_expiry_date: "2028-01-31",
    });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.deepEqual(calls.updateSupervisorProfile, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      userId: ids.created,
      fullName: "Updated Supervisor",
      fullNameAr: "مشرف محدّث",
      personCode: "SUP-002",
      phoneNumber: "+966511111111",
      countryCode: "PH",
      iqamaNumber: "000112233",
      iqamaExpiryDate: "2028-01-31",
    });
    assert.deepEqual(body, {
      supervisor: {
        id: ids.created,
        full_name: "Updated Supervisor",
        full_name_ar: "مشرف محدّث",
        person_code: "SUP-002",
        phone_number: "+966511111111",
        country_code: "PH",
        iqama_number: "000112233",
        iqama_expiry_date: "2028-01-31",
        email: "supervisor@example.invalid",
        updated_at: "2026-08-15T10:00:00Z",
      },
    });
    assert.notEqual(body.supervisor.email, "changed@example.invalid");
  });

  it("rejects invalid or unauthorized Branch Supervisor profile updates safely", async () => {
    const invalidCountry = await patchSupervisorProfile(deps(), {
      full_name: "Supervisor",
      country_code: "ZZ",
    });
    assert.equal(invalidCountry.status, 422);
    assert.match(await invalidCountry.text(), /Select a valid country/);

    const invalidExpiry = await patchSupervisorProfile(deps(), {
      full_name: "Supervisor",
      iqama_expiry_date: "2028-02-30",
    });
    assert.equal(invalidExpiry.status, 422);
    assert.match(await invalidExpiry.text(), /valid Gregorian Iqama expiry date/);

    const duplicateCode = await patchSupervisorProfile(deps({ supervisorProfileError: new AdminDuplicatePersonCodeError() }), {
      full_name: "Supervisor",
      person_code: "SUP-001",
    });
    assert.equal(duplicateCode.status, 409);
    const duplicateText = await duplicateCode.text();
    assert.match(duplicateText, /Supervisor code already exists/);
    assert.doesNotMatch(duplicateText, /profiles_person_code|SQLSTATE|duplicate key|stack/i);

    const nonAdmin = await patchSupervisorProfile(deps({ internalAdmin: false }), {
      full_name: "Supervisor",
    });
    assert.equal(nonAdmin.status, 403);
  });

  it("creates and deactivates Organization Managers with safe minimal output", async () => {
    const calls: Record<string, unknown> = {};
    const response = await postOrganizationManager(deps({ calls }), validOrganizationManager);
    const text = await response.text();
    assert.equal(response.status, 201);
    assert.deepEqual(JSON.parse(text), {
      id: ids.created,
      full_name: "Organization Manager",
      full_name_ar: null,
      email: "manager@example.invalid",
      role: "organization_manager",
      organization_id: ids.orgA,
      must_change_password: true,
    });
    assert.deepEqual(calls.create, { email: "manager@example.invalid", password: "temporary-secret" });
    assert.deepEqual(calls.finalizeOrganizationManager, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      newUserId: ids.created,
      fullName: "Organization Manager",
      fullNameAr: null,
    } satisfies FinalizeProvisionedOrganizationManagerInput);
    assert.doesNotMatch(text, /temporary_password|token|secret|service_role/i);

    const arabicCalls: Record<string, unknown> = {};
    const arabicResponse = await postOrganizationManager(deps({ calls: arabicCalls }), {
      ...validOrganizationManager,
      full_name_ar: "  مدير   المنظمة  ",
    });
    assert.equal(arabicResponse.status, 201);
    assert.deepEqual(await arabicResponse.json(), {
      id: ids.created,
      full_name: "Organization Manager",
      full_name_ar: "مدير المنظمة",
      email: "manager@example.invalid",
      role: "organization_manager",
      organization_id: ids.orgA,
      must_change_password: true,
    });
    assert.deepEqual(arabicCalls.finalizeOrganizationManager, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      newUserId: ids.created,
      fullName: "Organization Manager",
      fullNameAr: "مدير المنظمة",
    } satisfies FinalizeProvisionedOrganizationManagerInput);

    const deactivate = await deleteOrganizationManager(deps({ calls }));
    assert.equal(deactivate.status, 204);
    assert.deepEqual(calls.deactivateOrganizationManager, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      userId: ids.created,
    });
  });

  it("grants, reactivates, and removes existing Organization Manager access without Auth creation", async () => {
    const calls: Record<string, unknown> = {};
    const grant = await postExistingOrganizationManager(deps({ calls }), { email: " Existing.Manager@Example.Invalid " });
    assert.equal(grant.status, 204);
    assert.equal(calls.create, undefined);
    assert.deepEqual(calls.grantExistingOrganizationManager, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      email: "existing.manager@example.invalid",
    });

    const reactivate = await patchOrganizationManager(deps({ calls }));
    assert.equal(reactivate.status, 204);
    assert.deepEqual(calls.reactivateOrganizationManager, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      userId: ids.created,
    });
  });

  it("denies Organization Manager endpoints to anonymous, non-admins, invalid input, and duplicate email", async () => {
    assert.equal((await postOrganizationManager(deps(), valid, ids.orgA, "invalid")).status, 401);
    assert.equal((await postOrganizationManager(deps({ internalAdmin: false }), validOrganizationManager)).status, 403);
    assert.equal((await postOrganizationManager(deps(), { full_name: "Bad", email: "bad", temporary_password: "secret1" })).status, 400);
    assert.equal((await deleteOrganizationManager(deps(), "not-a-uuid")).status, 400);
    const duplicate = await postOrganizationManager(deps({ createError: new AdminConflictError() }), {
      full_name: "Organization Manager",
      email: "manager@example.invalid",
      temporary_password: "secret1",
    });
    assert.equal(duplicate.status, 409);
    assert.doesNotMatch(await duplicate.text(), /postgres|duplicate key|temporary_password|service_role/i);
    const missing = await postExistingOrganizationManager(deps(), { email: "missing@example.invalid" });
    assert.equal(missing.status, 404);
    assert.doesNotMatch(await missing.text(), /postgres|auth\.users|service_role|stack/i);
  });

  it("grants existing supervisor and maintenance access, and reactivates membership-only access", async () => {
    const calls: Record<string, unknown> = {};
    const supervisorGrant = await postExistingSupervisor(deps({ calls }), {
      email: " Existing.Supervisor@Example.Invalid ",
      branch_ids: [ids.branch],
      supervisor_team_assignments: [],
    });
    assert.equal(supervisorGrant.status, 204);
    assert.equal(calls.create, undefined);
    assert.deepEqual(calls.grantExistingSupervisor, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      email: "existing.supervisor@example.invalid",
      branchIds: [ids.branch],
      supervisorTeamAssignments: [],
    });
    assert.equal((await patchSupervisor(deps({ calls }))).status, 204);
    assert.deepEqual(calls.reactivateSupervisor, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      userId: ids.created,
    });

    const maintenanceGrant = await postExistingMaintenanceUser(deps({ calls }), { email: " Existing.Maintenance@Example.Invalid " });
    assert.equal(maintenanceGrant.status, 204);
    assert.deepEqual(calls.grantExistingMaintenanceUser, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      email: "existing.maintenance@example.invalid",
    });
    assert.equal((await patchMaintenanceUser(deps({ calls }))).status, 204);
    assert.deepEqual(calls.reactivateMaintenanceUser, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      userId: ids.created,
    });
  });

  it("denies existing-user grants and reactivation to non-admins or invalid targets", async () => {
    const validExistingSupervisorGrant = { email: "user@example.invalid", branch_ids: [ids.branch], supervisor_team_assignments: [{ operational_team_id: ids.team, assignment_role: "backup" }] };
    assert.equal((await postExistingSupervisor(deps({ internalAdmin: false }), validExistingSupervisorGrant)).status, 403);
    assert.equal((await postExistingSupervisor(deps(), { ...validExistingSupervisorGrant, branch_ids: [] })).status, 400);
    assert.equal((await postExistingSupervisor(deps({ branches: false }), validExistingSupervisorGrant)).status, 404);
    assert.equal((await postExistingMaintenanceUser(deps({ internalAdmin: false }), { email: "user@example.invalid" })).status, 403);
    assert.equal((await patchMaintenanceUser(deps({ internalAdmin: false }))).status, 403);
  });

  it("compensates Organization Manager finalization failure safely", async () => {
    const calls: Record<string, unknown> = {};
    const response = await postOrganizationManager(deps({ calls, finalizeManagerError: new Error("RAW_DB_SECRET") }), {
      full_name: "Organization Manager",
      email: "manager@example.invalid",
      temporary_password: "secret1",
    });
    assert.equal(response.status, 503);
    assert.equal(calls.deleted, ids.created);
    assert.doesNotMatch(await response.text(), /RAW_|password|email|token|secret|stack/i);
  });

  it("returns generic conflict and never finalizes when Auth creation conflicts or fails", async () => {
    for (const [error, status] of [[new AdminConflictError(), 409], [new Error("RAW_AUTH_SECRET"), 503]] as const) {
      const calls: Record<string, unknown> = {};
      const response = await post(deps({ createError: error, calls }), valid);
      const text = await response.text();
      assert.equal(response.status, status);
      assert.equal(calls.finalize, undefined);
      assert.doesNotMatch(text, /RAW_AUTH|password|token|secret|stack/i);
    }
  });

  it("compensates finalization failure and stays generic if deletion also fails", async () => {
    for (const deleteError of [undefined, new Error("RAW_DELETE_SECRET")]) {
      const calls: Record<string, unknown> = {};
      const response = await post(deps({ finalizeError: new Error("RAW_DB_PASSWORD"), deleteError, calls }), valid);
      const text = await response.text();
      assert.equal(response.status, 503);
      assert.equal(calls.deleted, ids.created);
      assert.doesNotMatch(text, /RAW_|password|email|token|secret|stack/i);
      assert.ok(response.headers.get("x-request-id"));
    }
  });

  it("preserves supervisor provisioning duplicate and access response semantics", async () => {
    assert.equal((await post(deps({ createError: new AdminConflictError() }), valid)).status, 409);
    assert.equal((await post(deps({ internalAdmin: false }), valid)).status, 403);

    const calls: Record<string, unknown> = {};
    const response = await post(deps({ finalizeError: new AdminAccessError(), calls }), valid);
    assert.equal(response.status, 403);
    assert.equal(calls.deleted, ids.created);
  });

  it("compensates supervisor team assignment conflicts without leaking DB details", async () => {
    const calls: Record<string, unknown> = {};
    const response = await post(deps({ finalizeError: new AdminConflictError(), calls }), valid);
    const text = await response.text();
    assert.equal(response.status, 409);
    assert.equal(calls.deleted, ids.created);
    assert.match(text, /Supervisor team assignment conflicts/);
    assert.doesNotMatch(text, /postgres|duplicate key|service_role|stack|password/i);
  });

  it("logs sanitized supervisor provisioning diagnostics for generic 503 stages", async () => {
    const appConfig = { ...config, nodeEnv: "production" as const };
    const original = console.error;
    const records: unknown[][] = [];
    console.error = (...args) => records.push(args);
    try {
      assert.equal(
        (await post(
          deps({ createError: new ProvisioningStageError("auth_create", "operation_failed", 500) }),
          valid,
          ids.orgA,
          "valid",
          appConfig,
        )).status,
        503,
      );
      assert.equal(
        (await post(
          deps({ finalizeError: new ProvisioningStageError("database_finalize", "rpc_failed", null, "23503") }),
          valid,
          ids.orgA,
          "valid",
          appConfig,
        )).status,
        503,
      );
    } finally {
      console.error = original;
    }

    assert.deepEqual(records.map((record) => record[0]), [
      "[supervisor-provisioning] failed",
      "[supervisor-provisioning] failed",
    ]);
    assert.deepEqual(
      records.map((record) => {
        const details = record[1] as Record<string, unknown>;
        return {
          stage: details.stage,
          reason: details.reason,
          upstreamStatus: details.upstreamStatus,
          databaseCode: details.databaseCode,
          hasRequestId: typeof details.requestId === "string" && /^[0-9a-f-]{36}$/.test(details.requestId),
        };
      }),
      [
        { stage: "auth_create", reason: "operation_failed", upstreamStatus: 500, databaseCode: undefined, hasRequestId: true },
        { stage: "database_finalize", reason: "rpc_failed", upstreamStatus: undefined, databaseCode: "23503", hasRequestId: true },
      ],
    );
    assert.doesNotMatch(JSON.stringify(records), /new\.person|example\.invalid|temporary_password|password|Bearer|cookie|token|secret|10000000|20000000|30000000/i);
  });

  it("uses fixed sanitized provisioning diagnostics", () => {
    const failure = new ProvisioningStageError("database_finalize", "rpc_failed", 400, "23503");
    assert.deepEqual(
      { stage: failure.stage, category: failure.category, status: failure.status, databaseCode: failure.databaseCode },
      { stage: "database_finalize", category: "rpc_failed", status: 400, databaseCode: "23503" },
    );
    assert.doesNotMatch(failure.message, /email|password|token|secret|postgres|supabase/i);
  });
});
