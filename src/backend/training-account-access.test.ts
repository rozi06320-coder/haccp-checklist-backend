import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { AdminAccessError, AdminConflictError, type TrainingAccountContext } from "./admin";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const ids = {
  actor: "10000000-0000-4000-8000-000000000001",
  created: "10000000-0000-4000-8000-000000000002",
  training: "10000000-0000-4000-8000-000000000003",
  orgA: "20000000-0000-4000-8000-000000000001",
  orgB: "20000000-0000-4000-8000-000000000002",
  branchA: "30000000-0000-4000-8000-000000000001",
  branchB: "30000000-0000-4000-8000-000000000002",
  branchOther: "30000000-0000-4000-8000-000000000003",
};

const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});

const servers: ReturnType<typeof createServer>[] = [];
const validCreate = {
  account_name: "Eastern Region Training",
  email: "training.eastern@example.invalid",
  temporary_password: "temporary-secret",
  branch_ids: [ids.branchA, ids.branchB],
  active: true,
};
const context: TrainingAccountContext = {
  user_id: ids.training,
  account_name: "Eastern Region Training",
  email: "training.eastern@example.invalid",
  organization_id: ids.orgA,
  organization_name: "Organization A",
  organization_name_ar: null,
  active: true,
  branches: [
    { id: ids.branchA, name: "Tarout", name_ar: null, code: "HUN-RUH", active: true },
    { id: ids.branchB, name: "Qatif", name_ar: null, code: "HUN-RUH", active: true },
  ],
};

function origin(server: ReturnType<typeof createServer>) {
  const address = server.address() as AddressInfo;
  return `http://127.0.0.1:${address.port}`;
}

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

function deps(options: {
  internalAdmin?: boolean;
  createError?: Error;
  finalizeError?: Error;
  listError?: Error;
  updateError?: Error;
  authorizeResetError?: Error;
  finalizeResetError?: Error;
  contextError?: Error;
  disabled?: boolean;
  mustChangePassword?: boolean;
  calls?: Record<string, unknown>;
} = {}): BackendDependencies {
  const calls = options.calls ?? {};
  return {
    authVerifier: { async verify(token) { return token === "valid" || token === "training" ? { userId: token === "training" ? ids.training : ids.actor, email: `${token}@example.invalid` } : null; } },
    async checkReadiness() { return true; },
    createUserContext() {
      return {
        async getUserContext(userId) {
          return { id: userId, full_name: "Actor", must_change_password: options.mustChangePassword ?? false, disabled: options.disabled ?? false, branches: [], managed_organizations: [] };
        },
        async isInternalAdmin() { return options.internalAdmin ?? true; },
        async hasOrganizationManagerAccess() { return false; },
        async validateActiveBranches() { return false; },
        async listActiveBranches() { return []; },
      };
    },
    passwordChange: {
      async verifyCurrent() { return true; },
      async updatePassword(userId, password) {
        calls.updatePassword = { userId, password };
      },
      async finalize() {},
    },
    provisioningAdmin: {
      async createUser(input) {
        calls.createUser = input;
        if (options.createError) throw options.createError;
        return { id: ids.created };
      },
      async deleteUser(userId) {
        calls.deleteUser = userId;
      },
      async finalize() {},
      async finalizeTrainingAccount(input) {
        calls.finalizeTrainingAccount = input;
        if (options.finalizeError) throw options.finalizeError;
      },
    },
    managementAdmin: {
      async listUsers() { return { users: [], total: 0 }; },
      async listTrainingAccountsForInternalAdmin(actorUserId, organizationId) {
        calls.listTrainingAccounts = { actorUserId, organizationId };
        if (options.listError) throw options.listError;
        return [{
          id: ids.training,
          account_name: "Eastern Region Training",
          email: "training.eastern@example.invalid",
          organization_id: ids.orgA,
          active: true,
          must_change_password: false,
          created_at: "2026-08-25T00:00:00.000Z",
          updated_at: "2026-08-25T00:00:00.000Z",
          updated_by_name: "Internal Admin",
          branches: [
            { id: ids.branchA, name: "Tarout", name_ar: null, code: "HUN-RUH", active: true },
            { id: ids.branchB, name: "Qatif", name_ar: null, code: "HUN-RUH", active: true },
          ],
        }];
      },
      async updateTrainingAccountForInternalAdmin(input) {
        calls.updateTrainingAccount = input;
        if (options.updateError) throw options.updateError;
      },
      async authorizeTrainingAccountPasswordReset(input) {
        calls.authorizeReset = input;
        if (options.authorizeResetError) throw options.authorizeResetError;
      },
      async finalizeTrainingAccountPasswordReset(input) {
        calls.finalizeReset = input;
        if (options.finalizeResetError) throw options.finalizeResetError;
      },
      async getTrainingAccountContext(actorUserId) {
        calls.trainingContext = actorUserId;
        if (options.contextError) throw options.contextError;
        return context;
      },
    },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); }, async getPinCredential() { throw new Error("unused"); } },
    pinCrypto: { async hash() { throw new Error("unused"); }, async verify() { return false; }, issueGrant() { return ""; }, verifyGrant() { return false; } },
  };
}

async function request(dependencies: BackendDependencies, pathName: string, init: RequestInit = {}, token = "valid") {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return fetch(`${origin(server)}${pathName}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) },
  });
}

describe("Training Account Phase 2A API", () => {
  it("lets an Internal Admin create a Training Account with multiple branches through Supabase Auth provisioning", async () => {
    const calls: Record<string, unknown> = {};
    const response = await request(deps({ calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(validCreate),
    });
    const body = await response.json();

    assert.equal(response.status, 201);
    assert.deepEqual(calls.createUser, { email: "training.eastern@example.invalid", password: "temporary-secret" });
    assert.deepEqual(calls.finalizeTrainingAccount, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      newUserId: ids.created,
      accountName: "Eastern Region Training",
      branchIds: [ids.branchA, ids.branchB],
      active: true,
    });
    assert.deepEqual(body.branch_ids, [ids.branchA, ids.branchB]);
    assert.doesNotMatch(JSON.stringify(body), /temporary-secret|temporary_password/i);
  });

  it("rejects non-Internal-Admin provisioning before creating an Auth user", async () => {
    const calls: Record<string, unknown> = {};
    const response = await request(deps({ internalAdmin: false, calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(validCreate),
    });
    assert.equal(response.status, 403);
    assert.equal(calls.createUser, undefined);
  });

  it("rejects cross-organization or foreign-branch finalization and compensates the Auth user", async () => {
    const calls: Record<string, unknown> = {};
    const response = await request(deps({ finalizeError: new AdminAccessError(), calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...validCreate, branch_ids: [ids.branchOther] }),
    });
    assert.equal(response.status, 403);
    assert.equal(calls.deleteUser, ids.created);
    assert.doesNotMatch(await response.text(), /temporary-secret|service_role|postgres|stack/i);
  });

  it("safely rejects duplicate email and partial provisioning failures", async () => {
    const duplicateCalls: Record<string, unknown> = {};
    const duplicate = await request(deps({ createError: new AdminConflictError(), calls: duplicateCalls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(validCreate),
    });
    assert.equal(duplicate.status, 409);
    assert.equal(duplicateCalls.finalizeTrainingAccount, undefined);
    assert.doesNotMatch(await duplicate.text(), /temporary-secret|token|stack/i);

    const failureCalls: Record<string, unknown> = {};
    const failed = await request(deps({ finalizeError: new Error("RAW_DB_PASSWORD"), calls: failureCalls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(validCreate),
    });
    assert.equal(failed.status, 503);
    assert.equal(failureCalls.deleteUser, ids.created);
    assert.doesNotMatch(await failed.text(), /RAW_DB_PASSWORD|temporary-secret|service_role|stack/i);
  });

  it("lists organization Training Accounts with branch IDs and duplicate branch codes without using code identity", async () => {
    const calls: Record<string, unknown> = {};
    const response = await request(deps({ calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts`);
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.deepEqual(calls.listTrainingAccounts, { actorUserId: ids.actor, organizationId: ids.orgA });
    assert.deepEqual(body.accounts[0].branches.map((branch: { id: string }) => branch.id), [ids.branchA, ids.branchB]);
    assert.deepEqual(body.accounts[0].branches.map((branch: { code: string }) => branch.code), ["HUN-RUH", "HUN-RUH"]);
    assert.doesNotMatch(JSON.stringify(body), /temporary-secret|temporary_password/i);
  });

  it("updates assigned branches and deactivates Training Accounts through Internal Admin scope", async () => {
    const calls: Record<string, unknown> = {};
    const response = await request(deps({ calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts/${ids.training}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ account_name: "Eastern Region Training", branch_ids: [ids.branchA, ids.branchB], active: false }),
    });
    assert.equal(response.status, 204);
    assert.deepEqual(calls.updateTrainingAccount, {
      actorUserId: ids.actor,
      organizationId: ids.orgA,
      userId: ids.training,
      accountName: "Eastern Region Training",
      active: false,
      branchIds: [ids.branchA, ids.branchB],
    });
  });

  it("resets Training Account passwords only after authorization and never returns the password", async () => {
    const calls: Record<string, unknown> = {};
    const response = await request(deps({ calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts/${ids.training}/reset-password`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ temporary_password: "replacement-secret" }),
    });
    assert.equal(response.status, 204);
    assert.deepEqual(calls.authorizeReset, { actorUserId: ids.actor, organizationId: ids.orgA, userId: ids.training });
    assert.deepEqual(calls.updatePassword, { userId: ids.training, password: "replacement-secret" });
    assert.deepEqual(calls.finalizeReset, { actorUserId: ids.actor, organizationId: ids.orgA, userId: ids.training });
    assert.equal(await response.text(), "");
  });

  it("rejects mixed-role Training password reset targets before changing the password", async () => {
    const calls: Record<string, unknown> = {};
    const response = await request(deps({ authorizeResetError: new AdminAccessError(), calls }), `/api/v1/internal-admin/organizations/${ids.orgA}/training-accounts/${ids.training}/reset-password`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ temporary_password: "replacement-secret" }),
    });
    assert.equal(response.status, 403);
    assert.deepEqual(calls.authorizeReset, { actorUserId: ids.actor, organizationId: ids.orgA, userId: ids.training });
    assert.equal(calls.updatePassword, undefined);
    assert.equal(calls.finalizeReset, undefined);
  });

  it("authorizes active Training Accounts and rejects inactive or ordinary authenticated users", async () => {
    const allowed = await request(deps(), "/api/v1/training/account", {}, "training");
    assert.equal(allowed.status, 200);
    const body = await allowed.json();
    assert.equal(body.account.user_id, ids.training);
    assert.equal(body.account.email, "training.eastern@example.invalid");
    assert.equal(body.account.active, true);
    assert.deepEqual(body.account.branches.map((branch: { id: string }) => branch.id), [ids.branchA, ids.branchB]);

    assert.equal((await request(deps({ contextError: new AdminAccessError() }), "/api/v1/training/account", {}, "valid")).status, 403);
    assert.equal((await request(deps({ disabled: true }), "/api/v1/training/account", {}, "training")).status, 403);
    assert.equal((await request(deps({ mustChangePassword: true }), "/api/v1/training/account", {}, "training")).status, 403);
    assert.equal((await fetch(`${origin(await started(deps()))}/api/v1/training/account`)).status, 401);
  });
});

async function started(dependencies: BackendDependencies) {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server;
}

describe("Training Account Phase 2A migration contract", () => {
  it("defines durable Training membership tables, RLS, service-role RPCs, and branch-ID identity", async () => {
    const migration = await readFile(path.resolve("supabase/migrations/20260825130000_training_account_access_phase_2a.sql"), "utf8");
    assert.match(migration, /create table public\.training_memberships/);
    assert.match(migration, /create table public\.training_membership_branches/);
    assert.match(migration, /references auth\.users\(id\) on delete cascade/);
    assert.match(migration, /foreign key \(organization_id, branch_id\)/);
    assert.match(migration, /references public\.branches\(organization_id, id\)/);
    assert.match(migration, /alter table public\.training_memberships enable row level security/);
    assert.match(migration, /alter table public\.training_membership_branches enable row level security/);
    assert.match(migration, /private\.is_internal_admin/);
    assert.match(migration, /private\.actor_has_active_training_membership/);
    assert.match(migration, /finalize_provisioned_training_account/);
    assert.match(migration, /list_internal_admin_training_accounts/);
    assert.match(migration, /update_internal_admin_training_account/);
    assert.match(migration, /get_training_account_context/);
    assert.match(migration, /grant execute .* to service_role/);
    assert.doesNotMatch(migration, /training_pin|branch_code.*primary/i);
    assert.doesNotMatch(migration, /create or replace function private\.has_branch_access/);
    assert.doesNotMatch(migration, /create or replace function private\.has_organization_access/);
    const trainingMembershipsTable =
      migration.match(
        /create table public\.training_memberships \([\s\S]*?\n\);/,
      )?.[0] ?? "";
    const trainingBranchesTable =
      migration.match(
        /create table public\.training_membership_branches \([\s\S]*?\n\);/,
      )?.[0] ?? "";
    assert.doesNotMatch(trainingMembershipsTable, /password/i);
    assert.doesNotMatch(trainingBranchesTable, /password/i);
  });

  it("preserves hardened shared branch and organization access helpers", async () => {
    const trainingMigration = await readFile(path.resolve("supabase/migrations/20260825130000_training_account_access_phase_2a.sql"), "utf8");
    const lifecycleHardening = await readFile(path.resolve("supabase/migrations/20260812041700_lifecycle_authorization_hardening.sql"), "utf8");
    const maintenanceHardening = await readFile(path.resolve("supabase/migrations/20260807122000_maintenance_membership_organization_access.sql"), "utf8");

    for (const required of ["profile.disabled_at is null", "not profile.must_change_password", "membership.active", "branch.active", "organization.active"]) {
      assert.match(lifecycleHardening, new RegExp(required.replace(/[.]/g, "\\.")));
    }
    for (const required of ["membership.active", "branch.active", "organization.active"]) {
      assert.match(maintenanceHardening, new RegExp(required.replace(/[.]/g, "\\.")));
    }
    assert.doesNotMatch(trainingMigration, /private\.has_branch_access\(target_branch_id uuid\)/);
    assert.doesNotMatch(trainingMigration, /private\.has_organization_access\(target_organization_id uuid\)/);
  });

  it("hardens Training password reset to dedicated Training identities only", async () => {
    const migration = await readFile(path.resolve("supabase/migrations/20260825130000_training_account_access_phase_2a.sql"), "utf8");
    assert.match(migration, /private\.training_account_target_is_dedicated\(target_user_id uuid\)/);
    for (const table of ["internal_admin_memberships", "organization_memberships", "branch_memberships", "maintenance_memberships"]) {
      assert.match(migration, new RegExp(`from public\\.${table}`));
    }
    const authorizeReset = migration.match(/create function public\.authorize_training_account_password_reset[\s\S]*?\n\$\$;/)?.[0] ?? "";
    const finalizeReset = migration.match(/create function public\.finalize_training_account_password_reset[\s\S]*?\n\$\$;/)?.[0] ?? "";
    const finalizeProvisioning = migration.match(/create function public\.finalize_provisioned_training_account[\s\S]*?\n\$\$;/)?.[0] ?? "";
    const updateAccount = migration.match(/create function public\.update_internal_admin_training_account[\s\S]*?\n\$\$;/)?.[0] ?? "";
    assert.match(finalizeProvisioning, /private\.training_account_target_is_dedicated\(p_new_user_id\)/);
    assert.match(updateAccount, /private\.training_account_target_is_dedicated\(target_user_id\)/);
    assert.match(authorizeReset, /private\.training_account_target_is_dedicated\(target_user_id\)/);
    assert.match(finalizeReset, /private\.training_account_target_is_dedicated\(target_user_id\)/);
    assert.doesNotMatch(finalizeReset, /disabled_at\s*=\s*null/i);
  });

  it("returns the explicit Training context contract expected by the frontend", async () => {
    const migration = await readFile(path.resolve("supabase/migrations/20260825130000_training_account_access_phase_2a.sql"), "utf8");
    const contextFunction = migration.match(/create function public\.get_training_account_context[\s\S]*?\n\$\$;/)?.[0] ?? "";
    assert.match(contextFunction, /user_id uuid/);
    assert.match(contextFunction, /email text/);
    assert.match(contextFunction, /active boolean/);
    assert.match(contextFunction, /membership\.active/);
    assert.match(contextFunction, /organization\.active/);
    assert.match(contextFunction, /branch\.active/);
  });
});
