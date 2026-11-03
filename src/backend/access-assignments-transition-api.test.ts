import assert from "node:assert/strict";
import test from "node:test";
import { createApp } from "./app";
import type { BackendDependencies } from "./dependencies";
import {
  AdminAccessError,
  AdminConflictError,
  AdminInputError,
  AdminNotFoundError,
} from "./admin";

const ids = {
  actor: "11000000-0000-4000-8000-000000000001",
  org: "22000000-0000-4000-8000-000000000001",
  branch1: "33000000-0000-4000-8000-000000000001",
  branch2: "33000000-0000-4000-8000-000000000002",
  team1: "55000000-0000-4000-8000-000000000001",
  targetUser: "44000000-0000-4000-8000-000000000001",
};

function createMockDependencies(overrides: {
  isInternalAdmin?: boolean;
  authenticated?: boolean;
  transitionError?: Error;
  transitionResult?: {
    userId: string;
    previousRole: "supervisor" | "training_supervisor";
    newRole: "supervisor" | "training_supervisor";
    updatedAt: string;
  };
} = {}): { deps: BackendDependencies; calls: Record<string, unknown> } {
  const calls: Record<string, unknown> = {};
  const deps: BackendDependencies = {
    authVerifier: {
      async verify() {
        if (overrides.authenticated === false) return null;
        return {
          userId: ids.actor,
          email: "admin@example.com",
          role: "authenticated",
        };
      },
    },
    async checkReadiness() { return true; },
    createUserContext() {
      return {
        async getUserContext() {
          return {
            id: ids.actor,
            must_change_password: false,
            disabled: false,
            branches: [],
            managed_organizations: [],
          };
        },
        async isInternalAdmin() {
          return overrides.isInternalAdmin !== undefined ? overrides.isInternalAdmin : true;
        },
        async hasOrganizationManagerAccess() { return false; },
        async validateActiveBranches() { return true; },
        async listActiveBranches() { return []; },
      };
    },
    passwordChange: {
      async verifyCurrent() { return true; },
      async updatePassword() {},
      async finalize() {},
    },
    provisioningAdmin: {
      async createUser() { return { id: "test-user-id" }; },
      async deleteUser() {},
      async finalize() {},
      async finalizeMaintenance() {},
      async finalizeOrganizationManager() {},
      async finalizePurchasing() {},
      async finalizeTrainingAccount() {},
    },
    dailyAuditPinAdmin: {
      async getMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async setPin() {},
      async removePin() {},
      async verifyPin() { return false; },
      async establishSupervisorSession() { return null; },
      async getSupervisorContext() { return null; },
      async setAccountName() {},
    },
    notificationAdmin: {
      async countUnread() { return 0; },
      async list() { return []; },
      async markAsRead() {},
      async markAllAsRead() {},
      async registerSubscription() {},
      async unregisterSubscription() {},
    },
    managementAdmin: {
      async transitionAccessRoleForInternalAdmin(input) {
        calls.transitionAccessRole = input;
        if (overrides.transitionError) throw overrides.transitionError;
        return overrides.transitionResult ?? {
          userId: input.userId,
          previousRole: input.expectedSourceRole,
          newRole: input.destinationRole,
          updatedAt: "2026-11-03T10:00:00.000Z",
        };
      },
    },
  };

  return { deps, calls };
}

const config = {
  internalAdminEmail: "admin@example.com",
  supabaseUrl: "http://localhost:54321",
  supabaseSecretKey: "secret-key",
};

test("Atomic Role Transition API: POST /access-assignments/transition", async (t) => {
  await t.test("successfully transitions supervisor to training_supervisor", async () => {
    const { deps, calls } = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "training_supervisor",
            branch_ids: [ids.branch1, ids.branch2],
          }),
        }
      );

      assert.equal(response.status, 200);
      const data = await response.json();
      assert.deepEqual(data, {
        user_id: ids.targetUser,
        previous_role: "supervisor",
        new_role: "training_supervisor",
        updated_at: "2026-11-03T10:00:00.000Z",
      });
      assert.deepEqual(calls.transitionAccessRole, {
        actorUserId: ids.actor,
        organizationId: ids.org,
        userId: ids.targetUser,
        expectedSourceRole: "supervisor",
        destinationRole: "training_supervisor",
        branchIds: [ids.branch1, ids.branch2],
        supervisorTeamAssignments: undefined,
      });
    } finally {
      server.close();
    }
  });

  await t.test("successfully transitions training_supervisor to supervisor with team assignments", async () => {
    const { deps, calls } = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "training_supervisor",
            destination_role: "supervisor",
            branch_ids: [ids.branch1],
            supervisor_team_assignments: [
              { operational_team_id: ids.team1, assignment_role: "primary" },
            ],
          }),
        }
      );

      assert.equal(response.status, 200);
      const data = await response.json();
      assert.equal(data.user_id, ids.targetUser);
      assert.equal(data.previous_role, "training_supervisor");
      assert.equal(data.new_role, "supervisor");
      assert.deepEqual(calls.transitionAccessRole, {
        actorUserId: ids.actor,
        organizationId: ids.org,
        userId: ids.targetUser,
        expectedSourceRole: "training_supervisor",
        destinationRole: "supervisor",
        branchIds: [ids.branch1],
        supervisorTeamAssignments: [
          { operationalTeamId: ids.team1, assignmentRole: "primary" },
        ],
      });
    } finally {
      server.close();
    }
  });

  await t.test("rejects unauthenticated request with 401", async () => {
    const { deps } = createMockDependencies({ authenticated: false });
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "training_supervisor",
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 401);
    } finally {
      server.close();
    }
  });

  await t.test("rejects non-internal-admin with 403", async () => {
    const { deps } = createMockDependencies({ isInternalAdmin: false });
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "training_supervisor",
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 403);
    } finally {
      server.close();
    }
  });

  await t.test("rejects identical expected_source_role and destination_role with 400", async () => {
    const { deps } = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "supervisor",
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 400);
    } finally {
      server.close();
    }
  });

  await t.test("rejects duplicate branch_ids with 400", async () => {
    const { deps } = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "training_supervisor",
            branch_ids: [ids.branch1, ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 400);
    } finally {
      server.close();
    }
  });

  await t.test("maps AdminConflictError to 409", async () => {
    const { deps } = createMockDependencies({ transitionError: new AdminConflictError() });
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "training_supervisor",
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 409);
    } finally {
      server.close();
    }
  });

  await t.test("maps AdminNotFoundError to 404", async () => {
    const { deps } = createMockDependencies({ transitionError: new AdminNotFoundError() });
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "training_supervisor",
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 404);
    } finally {
      server.close();
    }
  });

  await t.test("maps AdminInputError to 422", async () => {
    const { deps } = createMockDependencies({ transitionError: new AdminInputError() });
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/transition`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.targetUser,
            expected_source_role: "supervisor",
            destination_role: "training_supervisor",
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 422);
    } finally {
      server.close();
    }
  });
});
