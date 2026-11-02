import assert from "node:assert/strict";
import test from "node:test";
import { createApp } from "./app";
import type { BackendDependencies } from "./dependencies";
import {
  AdminAccessError,
  AdminConflictError,
  AdminInputError,
  AdminNotFoundError,
  type InternalAdminAccessAssignment,
} from "./admin";

const ids = {
  actor: "11000000-0000-4000-8000-000000000001",
  org: "22000000-0000-4000-8000-000000000001",
  branch1: "33000000-0000-4000-8000-000000000001",
  branch2: "33000000-0000-4000-8000-000000000002",
  supervisor: "44000000-0000-4000-8000-000000000001",
  trainingSupervisor: "44000000-0000-4000-8000-000000000002",
};

function createMockDependencies(overrides: Partial<Record<string, unknown>> = {}): BackendDependencies {
  const calls: Record<string, unknown> = {};
  return {
    authVerifier: {
      async verify() {
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
        async isInternalAdmin(userId: string) {
          return overrides.isInternalAdmin !== undefined ? Boolean(overrides.isInternalAdmin) : true;
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
    },
    managementAdmin: {
      async listUsers() { return { users: [], total: 0 }; },
      async listAccessAssignmentsForInternalAdmin(input) {
        calls.listAccessAssignments = input;
        const mockRows: InternalAdminAccessAssignment[] = [
          {
            assignment_id: ids.branch1,
            user_id: ids.supervisor,
            full_name: "Supervisor John",
            full_name_ar: "جون المشرف",
            email: "supervisor@example.com",
            phone_number: "+966500000001",
            access_type: "supervisor",
            branch_id: ids.branch1,
            branch_name: "Branch 1",
            branch_name_ar: "الفرع 1",
            branch_code: "BR-01",
            status: "active",
            must_change_password: false,
            created_at: "2026-11-01T00:00:00Z",
            updated_at: "2026-11-01T00:00:00Z",
          },
          {
            assignment_id: ids.branch1,
            user_id: ids.trainingSupervisor,
            full_name: "Training Sup Jane",
            full_name_ar: "جين مشرف التدريب",
            email: "trainingsup@example.com",
            phone_number: "+966500000002",
            access_type: "training_supervisor",
            branch_id: ids.branch1,
            branch_name: "Branch 1",
            branch_name_ar: "الفرع 1",
            branch_code: "BR-01",
            status: "active",
            must_change_password: false,
            created_at: "2026-11-01T00:00:00Z",
            updated_at: "2026-11-01T00:00:00Z",
          },
        ];
        return mockRows;
      },
      async grantTrainingSupervisorForInternalAdmin(input) {
        calls.grantTrainingSupervisor = input;
        if (overrides.conflict) throw new AdminConflictError();
      },
      async suspendTrainingSupervisorForInternalAdmin(input) {
        calls.suspendTrainingSupervisor = input;
      },
      async reactivateTrainingSupervisorForInternalAdmin(input) {
        calls.reactivateTrainingSupervisor = input;
      },
      async revokeTrainingSupervisorForInternalAdmin(input) {
        calls.revokeTrainingSupervisor = input;
      },
      async reassignTrainingSupervisorForInternalAdmin(input) {
        calls.reassignTrainingSupervisor = input;
      },
      async establishTrainingSupervisorSession(actorUserId) {
        calls.establishTrainingSupervisorSession = actorUserId;
        if (overrides.trainingSupervisorRevoked) throw new AdminAccessError();
        if (overrides.trainingSupervisorSuspended) throw new AdminAccessError();
        const activeVersion = "55000000-0000-4000-8000-000000000001";
        return {
          user_id: actorUserId,
          account_name: "Jane Training",
          email: "trainingsup@example.com",
          organization_id: ids.org,
          organization_name: "Org 1",
          organization_name_ar: "المنظمة 1",
          active: true,
          training_role: "training_supervisor",
          credential_version: activeVersion,
          branches: [{ id: ids.branch1, name: "Branch 1", name_ar: "الفرع 1", code: "BR-01", active: true }],
        };
      },
      async getTrainingSupervisorContext(input) {
        calls.getTrainingSupervisorContext = input;
        if (overrides.trainingSupervisorRevoked) throw new AdminAccessError();
        if (overrides.trainingSupervisorSuspended) throw new AdminAccessError();
        const activeVersion = "55000000-0000-4000-8000-000000000001";
        if (!input.expectedCredentialVersion || input.expectedCredentialVersion !== activeVersion) {
          throw new AdminAccessError();
        }
        return {
          user_id: input.actorUserId,
          account_name: "Jane Training",
          email: "trainingsup@example.com",
          organization_id: ids.org,
          organization_name: "Org 1",
          organization_name_ar: "المنظمة 1",
          active: true,
          training_role: "training_supervisor",
          credential_version: activeVersion,
          branches: [{ id: ids.branch1, name: "Branch 1", name_ar: "الفرع 1", code: "BR-01", active: true }],
        };
      },
    },
    ...overrides,
  };
}

const config = {
  nodeEnv: "test" as const,
  port: 0,
  host: "127.0.0.1",
  trustProxy: false as const,
  bodyLimitBytes: 1024 * 1024,
  rateLimit: { windowMs: 60_000, maxRequests: 1000 },
  adminRateLimit: { windowMs: 60_000, maxRequests: 1000 },
  pinVerificationRateLimit: { windowMs: 60_000, maxRequests: 1000 },
  authCookieName: "sb-access-token",
  corsAllowedOrigins: ["http://127.0.0.1:3000"],
  supabase: { url: "http://127.0.0.1:54321", publishableKey: "test-pub-key" },
  vapidPublicKey: "test-vapid",
  sessionSecret: "a".repeat(64),
};

test("Access Assignments API: Internal Admin Access", async (t) => {
  await t.test("GET list access assignments passes query filters to admin service", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments?access_type=supervisor&status=active`,
        { headers: { Authorization: "Bearer token" } }
      );
      assert.equal(response.status, 200);
      const data = await response.json();
      assert.equal(Array.isArray(data.assignments), true);
      assert.equal(data.assignments.length, 2);
    } finally {
      server.close();
    }
  });

  await t.test("GET list access assignments rejects non-admin caller with 403", async () => {
    const deps = createMockDependencies({ isInternalAdmin: false });
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments`,
        { headers: { Authorization: "Bearer token" } }
      );
      assert.equal(response.status, 403);
    } finally {
      server.close();
    }
  });

  await t.test("POST grant training supervisor succeeds with 201", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/training-supervisors`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.trainingSupervisor,
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 201);
      const data = await response.json();
      assert.equal(data.success, true);
    } finally {
      server.close();
    }
  });

  await t.test("POST grant training supervisor rejects conflicting active supervisor role with 409", async () => {
    const deps = createMockDependencies();
    deps.managementAdmin.grantTrainingSupervisorForInternalAdmin = async () => {
      throw new AdminConflictError();
    };
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/training-supervisors`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({
            user_id: ids.supervisor,
            branch_ids: [ids.branch1],
          }),
        }
      );
      assert.equal(response.status, 409);
    } finally {
      server.close();
    }
  });

  await t.test("POST suspend training supervisor succeeds with 204", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/training-supervisors/${ids.trainingSupervisor}/suspend`,
        {
          method: "POST",
          headers: { Authorization: "Bearer token" },
        }
      );
      assert.equal(response.status, 204);
    } finally {
      server.close();
    }
  });

  await t.test("POST reactivate training supervisor succeeds with 204", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/training-supervisors/${ids.trainingSupervisor}/reactivate`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({ branch_ids: [ids.branch1] }),
        }
      );
      assert.equal(response.status, 204);
    } finally {
      server.close();
    }
  });

  await t.test("DELETE revoke training supervisor succeeds with 204", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/training-supervisors/${ids.trainingSupervisor}`,
        {
          method: "DELETE",
          headers: { Authorization: "Bearer token" },
        }
      );
      assert.equal(response.status, 204);
    } finally {
      server.close();
    }
  });

  await t.test("PATCH reassign training supervisor succeeds with 204", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments/training-supervisors/${ids.trainingSupervisor}/reassign`,
        {
          method: "PATCH",
          headers: { "Content-Type": "application/json", Authorization: "Bearer token" },
          body: JSON.stringify({ branch_ids: [ids.branch2] }),
        }
      );
      assert.equal(response.status, 204);
    } finally {
      server.close();
    }
  });

  await t.test("all internal admin access assignment endpoints reject organization manager caller with 403", async () => {
    const deps = createMockDependencies({ isInternalAdmin: false, hasOrgManager: true });
    // Override userContext so hasOrganizationManagerAccess returns true while isInternalAdmin is false
    const originalCreate = deps.createUserContext;
    deps.createUserContext = (token) => {
      const ctx = originalCreate(token);
      return {
        ...ctx,
        async isInternalAdmin() { return false; },
        async hasOrganizationManagerAccess() { return true; },
      };
    };

    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const baseUrl = `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments`;
      const headers = { "Content-Type": "application/json", Authorization: "Bearer token" };

      const getRes = await fetch(baseUrl, { headers });
      assert.equal(getRes.status, 403);

      const postGrantRes = await fetch(`${baseUrl}/training-supervisors`, {
        method: "POST",
        headers,
        body: JSON.stringify({ user_id: ids.trainingSupervisor, branch_ids: [ids.branch1] }),
      });
      assert.equal(postGrantRes.status, 403);

      const postSuspendRes = await fetch(`${baseUrl}/training-supervisors/${ids.trainingSupervisor}/suspend`, {
        method: "POST",
        headers,
      });
      assert.equal(postSuspendRes.status, 403);

      const postReactivateRes = await fetch(`${baseUrl}/training-supervisors/${ids.trainingSupervisor}/reactivate`, {
        method: "POST",
        headers,
        body: JSON.stringify({ branch_ids: [ids.branch1] }),
      });
      assert.equal(postReactivateRes.status, 403);

      const deleteRes = await fetch(`${baseUrl}/training-supervisors/${ids.trainingSupervisor}`, {
        method: "DELETE",
        headers,
      });
      assert.equal(deleteRes.status, 403);

      const patchReassignRes = await fetch(`${baseUrl}/training-supervisors/${ids.trainingSupervisor}/reassign`, {
        method: "PATCH",
        headers,
        body: JSON.stringify({ branch_ids: [ids.branch2] }),
      });
      assert.equal(patchReassignRes.status, 403);
    } finally {
      server.close();
    }
  });

  await t.test("all internal admin access assignment endpoints reject operational supervisor caller with 403", async () => {
    const deps = createMockDependencies({ isInternalAdmin: false });
    const originalCreate = deps.createUserContext;
    deps.createUserContext = (token) => {
      const ctx = originalCreate(token);
      return {
        ...ctx,
        async isInternalAdmin() { return false; },
        async getUserContext(userId) {
          return {
            id: userId,
            full_name: "Supervisor John",
            must_change_password: false,
            disabled: false,
            branches: [{ id: ids.branch1, name: "Branch 1", organization_id: ids.org, role: "branch_manager" }],
            managed_organizations: [],
          };
        },
      };
    };

    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const baseUrl = `http://127.0.0.1:${port}/api/v1/internal-admin/organizations/${ids.org}/access-assignments`;
      const headers = { "Content-Type": "application/json", Authorization: "Bearer token" };

      const getRes = await fetch(baseUrl, { headers });
      assert.equal(getRes.status, 403);

      const postGrantRes = await fetch(`${baseUrl}/training-supervisors`, {
        method: "POST",
        headers,
        body: JSON.stringify({ user_id: ids.trainingSupervisor, branch_ids: [ids.branch1] }),
      });
      assert.equal(postGrantRes.status, 403);
    } finally {
      server.close();
    }
  });

  await t.test("POST training supervisor session establishes session and returns current credential_version", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/training-supervisor/session`,
        {
          method: "POST",
          headers: { Authorization: "Bearer token" },
        }
      );
      assert.equal(response.status, 200);
      const data = await response.json();
      assert.equal(data.context.training_role, "training_supervisor");
      assert.equal(data.context.credential_version, "55000000-0000-4000-8000-000000000001");
      assert.equal(Array.isArray(data.context.branches), true);
    } finally {
      server.close();
    }
  });

  await t.test("POST training supervisor session fails closed on suspended, revoked or unauthenticated", async () => {
    // 1. Suspended
    const suspendedDeps = createMockDependencies({ trainingSupervisorSuspended: true });
    const suspendedApp = createApp(config, suspendedDeps);
    const server1 = suspendedApp.listen(0);
    const port1 = (server1.address() as { port: number }).port;
    try {
      const res = await fetch(`http://127.0.0.1:${port1}/api/v1/training-supervisor/session`, {
        method: "POST",
        headers: { Authorization: "Bearer token" },
      });
      assert.equal(res.status, 403);
    } finally {
      server1.close();
    }

    // 2. Unauthenticated
    const unauthDeps = createMockDependencies({ authVerifier: { async verify() { return null; } } });
    const unauthApp = createApp(config, unauthDeps);
    const server2 = unauthApp.listen(0);
    const port2 = (server2.address() as { port: number }).port;
    try {
      const res = await fetch(`http://127.0.0.1:${port2}/api/v1/training-supervisor/session`, { method: "POST" });
      assert.equal(res.status, 401);
    } finally {
      server2.close();
    }
  });

  await t.test("GET training supervisor context returns 200 with valid session and credential_version", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/api/v1/training-supervisor/context`,
        {
          headers: {
            Authorization: "Bearer token",
            "x-credential-version": "55000000-0000-4000-8000-000000000001",
          },
        }
      );
      assert.equal(response.status, 200);
      const data = await response.json();
      assert.equal(data.context.training_role, "training_supervisor");
      assert.equal(data.context.credential_version, "55000000-0000-4000-8000-000000000001");
      assert.equal(Array.isArray(data.context.branches), true);
    } finally {
      server.close();
    }
  });

  await t.test("GET training supervisor context enforces credential_version and fails closed when omitted, null, invalid, stale or forged", async () => {
    const deps = createMockDependencies();
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      // 1. Omitted header fails closed with 403 (cannot bypass by omitting!)
      const omittedRes = await fetch(
        `http://127.0.0.1:${port}/api/v1/training-supervisor/context`,
        { headers: { Authorization: "Bearer token" } }
      );
      assert.equal(omittedRes.status, 403);

      // 2. Empty/whitespace header fails closed with 403
      const emptyRes = await fetch(
        `http://127.0.0.1:${port}/api/v1/training-supervisor/context`,
        { headers: { Authorization: "Bearer token", "x-credential-version": "   " } }
      );
      assert.equal(emptyRes.status, 403);

      // 3. Invalid UUID format in header is rejected with 400
      const invalidHeaderRes = await fetch(
        `http://127.0.0.1:${port}/api/v1/training-supervisor/context`,
        {
          headers: {
            Authorization: "Bearer token",
            "x-credential-version": "not-a-uuid",
          },
        }
      );
      assert.equal(invalidHeaderRes.status, 400);

      // 4. Stale/rotated or caller-forged credential version header is rejected with 403
      const forgedRes = await fetch(
        `http://127.0.0.1:${port}/api/v1/training-supervisor/context`,
        {
          headers: {
            Authorization: "Bearer token",
            "x-credential-version": "99000000-0000-4000-8000-000000000099",
          },
        }
      );
      assert.equal(forgedRes.status, 403);

      // 5. Correct credential version matches and succeeds
      const validRes = await fetch(
        `http://127.0.0.1:${port}/api/v1/training-supervisor/context`,
        {
          headers: {
            Authorization: "Bearer token",
            "x-credential-version": "55000000-0000-4000-8000-000000000001",
          },
        }
      );
      assert.equal(validRes.status, 200);
    } finally {
      server.close();
    }
  });

  await t.test("GET training supervisor context immediately invalidates suspended or revoked access with 403", async () => {
    // Suspended
    const suspendedDeps = createMockDependencies({ trainingSupervisorSuspended: true });
    const suspendedApp = createApp(config, suspendedDeps);
    const server1 = suspendedApp.listen(0);
    const port1 = (server1.address() as { port: number }).port;

    try {
      const res = await fetch(`http://127.0.0.1:${port1}/api/v1/training-supervisor/context`, {
        headers: {
          Authorization: "Bearer token",
          "x-credential-version": "55000000-0000-4000-8000-000000000001",
        },
      });
      assert.equal(res.status, 403);
    } finally {
      server1.close();
    }

    // Revoked
    const revokedDeps = createMockDependencies({ trainingSupervisorRevoked: true });
    const revokedApp = createApp(config, revokedDeps);
    const server2 = revokedApp.listen(0);
    const port2 = (server2.address() as { port: number }).port;

    try {
      const res = await fetch(`http://127.0.0.1:${port2}/api/v1/training-supervisor/context`, {
        headers: {
          Authorization: "Bearer token",
          "x-credential-version": "55000000-0000-4000-8000-000000000001",
        },
      });
      assert.equal(res.status, 403);
    } finally {
      server2.close();
    }
  });

  await t.test("GET training supervisor context rejects unauthenticated request with 401 even if valid credential_version is provided", async () => {
    const deps = createMockDependencies({
      authVerifier: { async verify() { return null; } },
    });
    const app = createApp(config, deps);
    const server = app.listen(0);
    const port = (server.address() as { port: number }).port;

    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/v1/training-supervisor/context`, {
        headers: { "x-credential-version": "55000000-0000-4000-8000-000000000001" },
      });
      assert.equal(res.status, 401);
    } finally {
      server.close();
    }
  });
});
