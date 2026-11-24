import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import {
  createOperationalAdmin,
  OperationalAccessError,
  OperationalIdempotencyConflictError,
  OperationalInputError,
  OperationalTeamAlreadyAssignedError,
  OperationalTeamNameConflictError,
} from "./operational";

const ids = {
  supA: "a0000000-0000-4000-8000-000000000001",
  supB: "a0000000-0000-4000-8000-000000000002",
  disabledUser: "a0000000-0000-4000-8000-000000000003",
  pwChangeUser: "a0000000-0000-4000-8000-000000000004",
  staffUser: "a0000000-0000-4000-8000-000000000005",
  orgManager: "a0000000-0000-4000-8000-000000000006",
  internalAdmin: "a0000000-0000-4000-8000-000000000007",
  org1: "b0000000-0000-4000-8000-000000000001",
  org2: "b0000000-0000-4000-8000-000000000002",
  branchA: "c0000000-0000-4000-8000-000000000001",
  branchB: "c0000000-0000-4000-8000-000000000002",
  branchInactive: "c0000000-0000-4000-8000-000000000003",
  branchOtherOrg: "c0000000-0000-4000-8000-000000000004",
  idemKey1: "d0000000-0000-4000-8000-000000000001",
  idemKey2: "d0000000-0000-4000-8000-000000000002",
  idemKeyRevoked: "d0000000-0000-4000-8000-000000000003",
  idemKeyRawErr: "d0000000-0000-4000-8000-000000000004",
  legacyTeam1: "e0000000-0000-4000-8000-000000000001",
};

const config: BackendConfig = {
  port: 0,
  serviceRoleKey: "test-service-role-key",
  supabaseUrl: "http://127.0.0.1:54321",
};

const minimalChecklistPersistence = {
  getSupervisorDashboard: async () => ({}),
  getChecklistDetails: async () => null,
  saveChecklistDraft: async () => ({}),
  submitChecklist: async () => ({}),
} as unknown as BackendDependencies["checklistPersistence"];

const minimalSupportDeps: Pick<
  BackendDependencies,
  "checkReadiness" | "checklistPersistence" | "passwordChange" | "provisioningAdmin" | "managementAdmin" | "branchManagementAdmin" | "pinCrypto"
> = {
  checkReadiness: async () => true,
  checklistPersistence: minimalChecklistPersistence,
  passwordChange: {
    verifyCurrent: async () => true,
    updatePassword: async () => {},
    finalize: async () => {},
  },
  provisioningAdmin: {
    createUser: async () => ({ id: ids.supA }),
    deleteUser: async () => {},
    finalize: async () => {},
  },
  managementAdmin: {
    listUsers: async () => ({ users: [], total: 0 }),
  },
  branchManagementAdmin: {
    listBranches: async () => [],
    listStaff: async () => [],
    getPinMetadata: async () => ({ configured: false, updated_at: null, updated_by_name: null }),
    storePin: async () => ({ configured: false, updated_at: null, updated_by_name: null }),
    getPinCredential: async () => null,
  },
  pinCrypto: {
    hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }),
    verify: async () => false,
    issueGrant: () => "",
    verifyGrant: () => false,
  },
};

function makeAuthContext(): Pick<BackendDependencies, "authVerifier" | "createUserContext"> {
  const tokenToUser: Record<string, string> = {
    "sup-a": ids.supA,
    "sup-b": ids.supB,
    "disabled": ids.disabledUser,
    "pw-change": ids.pwChangeUser,
    "staff": ids.staffUser,
    "org-manager": ids.orgManager,
    "internal-admin": ids.internalAdmin,
  };
  return {
    authVerifier: {
      async verify(token) {
        const userId = tokenToUser[token];
        return userId ? { userId, email: `${token}@example.invalid` } : null;
      },
    },
    createUserContext: () => ({
      async getUserContext(userId) {
        if (userId === ids.supA) {
          return {
            id: ids.supA,
            full_name: "Supervisor A",
            must_change_password: false,
            disabled: false,
            branches: [
              { id: ids.branchA, name: "Branch A", organization_id: ids.org1, role: "branch_manager" },
              { id: ids.branchB, name: "Branch B", organization_id: ids.org1, role: "branch_manager" },
              { id: ids.branchInactive, name: "Branch Inactive", organization_id: ids.org1, role: "branch_manager" },
            ],
            managed_organizations: [],
          };
        }
        if (userId === ids.supB) {
          return {
            id: ids.supB,
            full_name: "Supervisor B",
            must_change_password: false,
            disabled: false,
            branches: [
              { id: ids.branchA, name: "Branch A", organization_id: ids.org1, role: "branch_manager" },
            ],
            managed_organizations: [],
          };
        }
        if (userId === ids.disabledUser) {
          return {
            id: ids.disabledUser,
            full_name: "Disabled User",
            must_change_password: false,
            disabled: true,
            branches: [{ id: ids.branchA, name: "Branch A", organization_id: ids.org1, role: "branch_manager" }],
            managed_organizations: [],
          };
        }
        if (userId === ids.pwChangeUser) {
          return {
            id: ids.pwChangeUser,
            full_name: "PW Change User",
            must_change_password: true,
            disabled: false,
            branches: [{ id: ids.branchA, name: "Branch A", organization_id: ids.org1, role: "branch_manager" }],
            managed_organizations: [],
          };
        }
        if (userId === ids.staffUser) {
          return {
            id: ids.staffUser,
            full_name: "Staff User",
            must_change_password: false,
            disabled: false,
            branches: [{ id: ids.branchA, name: "Branch A", organization_id: ids.org1, role: "staff" }],
            managed_organizations: [],
          };
        }
        if (userId === ids.orgManager) {
          return {
            id: ids.orgManager,
            full_name: "Org Manager",
            must_change_password: false,
            disabled: false,
            branches: [{ id: ids.branchA, name: "Branch A", organization_id: ids.org1, role: "branch_manager" }],
            managed_organizations: [{ id: ids.org1, name: "Org 1", role: "organization_manager" }],
          };
        }
        return {
          id: userId,
          full_name: "Internal Admin",
          must_change_password: false,
          disabled: false,
          branches: [],
          managed_organizations: [],
          is_internal_admin: true,
        };
      },
      hasOrganizationManagerAccess: async () => false,
      validateActiveBranches: async () => true,
      listActiveBranches: async () => [],
    }),
  };
}

describe("Supervisor Operational Team Onboarding - Phase 2 API", () => {
  let server: Server;
  let baseUrl: string;
  const waitingStates = new Map<string, { branch_id: string; onboarding_choice: "waiting_for_transfer"; selected_at: string }>();
  const teamsBySupervisorBranch = new Map<string, { id: string; name: string }>();
  const teamsByBranchName = new Map<string, string>();
  const idempotencyRecords = new Map<string, { name: string; team: Record<string, unknown>; revoked?: boolean }>();
  let teamCounter = 0;

  before(async () => {
    const authDeps = makeAuthContext();
    const operationalAdmin: NonNullable<BackendDependencies["operationalAdmin"]> = {
      async getBranchTimezone() { return "Asia/Riyadh"; },
      async getSupervisorTeam() { return { teams: [] }; },
      async createStaff() { return {}; },
      async updateStaff() { return {}; },
      async setDuty() { return {}; },
      async listHealthCards() { return []; },
      async upsertHealthCard() { return {}; },
      async getSupervisorTeamOnboardingState({ actorUserId, branchIds }) {
        const states = [];
        for (const branchId of branchIds) {
          if (branchId === ids.branchInactive || branchId === ids.branchOtherOrg) {
            throw new OperationalAccessError();
          }
          const found = waitingStates.get(`${actorUserId}:${branchId}`);
          if (found) states.push(found);
        }
        return { states };
      },
      async setSupervisorTeamOnboardingWaiting({ actorUserId, branchId }) {
        if (branchId === ids.branchInactive || branchId === ids.branchOtherOrg) {
          throw new OperationalAccessError();
        }
        if (teamsBySupervisorBranch.has(`${actorUserId}:${branchId}`)) {
          throw new OperationalTeamAlreadyAssignedError();
        }
        const key = `${actorUserId}:${branchId}`;
        const existing = waitingStates.get(key);
        if (existing) return existing;
        const created = {
          branch_id: branchId,
          onboarding_choice: "waiting_for_transfer" as const,
          selected_at: "2026-11-24T19:00:00.000Z",
        };
        waitingStates.set(key, created);
        return created;
      },
      async createSupervisorOwnedOperationalTeamV2({ actorUserId, branchId, name, idempotencyKey }) {
        if (branchId === ids.branchInactive || branchId === ids.branchOtherOrg) {
          throw new OperationalAccessError();
        }
        if (idempotencyKey === ids.idemKeyRawErr) {
          throw new Error("ERROR: raw postgres internal detail should never leak");
        }
        if (idempotencyKey) {
          const idemMapKey = `${actorUserId}:${branchId}:${idempotencyKey}`;
          const prev = idempotencyRecords.get(idemMapKey);
          if (prev) {
            if (prev.name !== name) {
              throw new OperationalIdempotencyConflictError();
            }
            if (prev.revoked || idempotencyKey === ids.idemKeyRevoked) {
              throw new OperationalAccessError();
            }
            return { team: prev.team };
          }
        }
        if (teamsBySupervisorBranch.has(`${actorUserId}:${branchId}`)) {
          throw new OperationalTeamAlreadyAssignedError();
        }
        if (teamsByBranchName.has(`${branchId}:${name.toLowerCase()}`)) {
          throw new OperationalTeamNameConflictError();
        }
        teamCounter += 1;
        const teamId = `f0000000-0000-4000-8000-${String(teamCounter).padStart(12, "0")}`;
        const legacyId = `f1000000-0000-4000-8000-${String(teamCounter).padStart(12, "0")}`;
        const team = {
          id: teamId,
          organization_id: ids.org1,
          branch_id: branchId,
          name,
          active: true,
          legacy_supervisor_team_id: legacyId,
          supervisor_user_id: actorUserId,
          assignment_role: "primary" as const,
          can_write: true as const,
        };
        teamsBySupervisorBranch.set(`${actorUserId}:${branchId}`, { id: teamId, name });
        teamsByBranchName.set(`${branchId}:${name.toLowerCase()}`, teamId);
        waitingStates.delete(`${actorUserId}:${branchId}`);
        if (idempotencyKey) {
          idempotencyRecords.set(`${actorUserId}:${branchId}:${idempotencyKey}`, {
            name,
            team,
            revoked: idempotencyKey === ids.idemKeyRevoked,
          });
        }
        return { team };
      },
    };

    const app = createApp(config, {
      ...minimalSupportDeps,
      ...authDeps,
      operationalAdmin,
    });
    server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const address = server.address() as AddressInfo;
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  after(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  async function req(method: string, path: string, token?: string, body?: unknown) {
    const headers: Record<string, string> = {};
    if (token) headers.authorization = `Bearer ${token}`;
    if (body !== undefined) headers["content-type"] = "application/json";
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const json = await response.json();
    return { status: response.status, json };
  }

  it("rejects unauthenticated requests across all onboarding endpoints", async () => {
    const r1 = await req("GET", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding`);
    const r2 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding/wait`, undefined, {});
    const r3 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, undefined, { name: "Alpha" });
    assert.equal(r1.status, 401);
    assert.equal(r2.status, 401);
    assert.equal(r3.status, 401);
  });

  it("rejects unauthorized roles, disabled accounts, password_change_required, and org managers", async () => {
    for (const token of ["staff", "disabled", "pw-change", "org-manager", "internal-admin"]) {
      const r1 = await req("GET", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding`, token);
      assert.equal(r1.status, 403, `GET expected 403 for ${token}`);
      assert.equal(r1.json.error.code, "ACCESS_DENIED");

      const r2 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding/wait`, token, {});
      assert.equal(r2.status, 403, `POST wait expected 403 for ${token}`);
      assert.equal(r2.json.error.code, "ACCESS_DENIED");

      const r3 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, token, { name: "Alpha" });
      assert.equal(r3.status, 403, `POST team expected 403 for ${token}`);
      assert.equal(r3.json.error.code, "ACCESS_DENIED");
    }
  });

  it("rejects cross-branch, cross-org, and inactive branch/org access", async () => {
    const crossBranch = await req("GET", `/api/v1/supervisor/branches/${ids.branchB}/team-onboarding`, "sup-b");
    assert.equal(crossBranch.status, 403);
    assert.equal(crossBranch.json.error.code, "ACCESS_DENIED");

    const crossOrg = await req("POST", `/api/v1/supervisor/branches/${ids.branchOtherOrg}/team-onboarding/wait`, "sup-a", {});
    assert.equal(crossOrg.status, 403);
    assert.equal(crossOrg.json.error.code, "ACCESS_DENIED");

    const inactiveBranch = await req("POST", `/api/v1/supervisor/branches/${ids.branchInactive}/operational-teams`, "sup-a", { name: "Alpha" });
    assert.equal(inactiveBranch.status, 403);
    assert.equal(inactiveBranch.json.error.code, "ACCESS_DENIED");
  });

  it("rejects client-supplied actor_user_id and invalid inputs with INVALID_INPUT", async () => {
    const r1 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding/wait`, "sup-a", { actor_user_id: ids.supB });
    assert.equal(r1.status, 400);
    assert.equal(r1.json.error.code, "INVALID_INPUT");

    const r2 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, "sup-a", {
      name: "Alpha",
      actor_user_id: ids.supB,
    });
    assert.equal(r2.status, 400);
    assert.equal(r2.json.error.code, "INVALID_INPUT");

    const r3 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, "sup-a", {
      name: "   ",
      idempotency_key: "not-a-uuid",
    });
    assert.equal(r3.status, 400);
    assert.equal(r3.json.error.code, "INVALID_INPUT");
  });

  it("persists waiting state per branch, handles repeated waiting idempotently, and isolates Branch A vs Branch B", async () => {
    const beforeA = await req("GET", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding`, "sup-a");
    assert.equal(beforeA.status, 200);
    assert.deepEqual(beforeA.json, { branch_id: ids.branchA, onboarding_choice: null, selected_at: null });

    const wait1 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding/wait`, "sup-a", {});
    assert.equal(wait1.status, 200);
    assert.equal(wait1.json.branch_id, ids.branchA);
    assert.equal(wait1.json.onboarding_choice, "waiting_for_transfer");
    assert.ok(wait1.json.selected_at);

    // Repeated waiting request is idempotent
    const wait2 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding/wait`, "sup-a");
    assert.equal(wait2.status, 200);
    assert.deepEqual(wait2.json, wait1.json);

    // Persisted on GET Branch A, while Branch B stays independent (null)
    const afterA = await req("GET", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding`, "sup-a");
    assert.equal(afterA.status, 200);
    assert.deepEqual(afterA.json, wait1.json);

    const branchB = await req("GET", `/api/v1/supervisor/branches/${ids.branchB}/team-onboarding`, "sup-a");
    assert.equal(branchB.status, 200);
    assert.deepEqual(branchB.json, { branch_id: ids.branchB, onboarding_choice: null, selected_at: null });
  });

  it("creates team from waiting state, clears waiting state, supports idempotent retry, and maps distinct conflict codes", async () => {
    // Create team on Branch A with idempotency_key
    const created1 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, "sup-a", {
      name: "  Alpha   Team ",
      idempotency_key: ids.idemKey1,
    });
    assert.equal(created1.status, 201);
    assert.equal(created1.json.team.name, "Alpha Team");
    assert.equal(created1.json.team.supervisor_user_id, ids.supA);

    // Waiting state on Branch A is cleared
    const stateAfterCreate = await req("GET", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding`, "sup-a");
    assert.equal(stateAfterCreate.status, 200);
    assert.deepEqual(stateAfterCreate.json, { branch_id: ids.branchA, onboarding_choice: null, selected_at: null });

    // Waiting when already having writable team -> TEAM_ALREADY_ASSIGNED
    const waitAfterTeam = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/team-onboarding/wait`, "sup-a", {});
    assert.equal(waitAfterTeam.status, 409);
    assert.equal(waitAfterTeam.json.error.code, "TEAM_ALREADY_ASSIGNED");

    // Idempotent retry with same key & name returns same team
    const retry1 = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, "sup-a", {
      name: "Alpha Team",
      idempotency_key: ids.idemKey1,
    });
    assert.equal(retry1.status, 201);
    assert.equal(retry1.json.team.id, created1.json.team.id);

    // Different name with same idempotency_key -> IDEMPOTENCY_CONFLICT
    const idemConflict = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, "sup-a", {
      name: "Different Team",
      idempotency_key: ids.idemKey1,
    });
    assert.equal(idemConflict.status, 409);
    assert.equal(idemConflict.json.error.code, "IDEMPOTENCY_CONFLICT");

    // Duplicate team name by Sup B on Branch A -> TEAM_NAME_CONFLICT
    const dupName = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, "sup-b", {
      name: "alpha team",
      idempotency_key: ids.idemKey2,
    });
    assert.equal(dupName.status, 409);
    assert.equal(dupName.json.error.code, "TEAM_NAME_CONFLICT");

    // Sup A creating another team without idempotency_key on Branch A -> TEAM_ALREADY_ASSIGNED
    const alreadyAssigned = await req("POST", `/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, "sup-a", {
      name: "Second Team",
    });
    assert.equal(alreadyAssigned.status, 409);
    assert.equal(alreadyAssigned.json.error.code, "TEAM_ALREADY_ASSIGNED");
  });

  it("rejects revoked team replay with ACCESS_DENIED and never exposes raw PostgreSQL errors", async () => {
    const first = await req("POST", `/api/v1/supervisor/branches/${ids.branchB}/operational-teams`, "sup-a", {
      name: "Branch B Team",
      idempotency_key: ids.idemKeyRevoked,
    });
    assert.equal(first.status, 201);

    const replayAfterRevoke = await req("POST", `/api/v1/supervisor/branches/${ids.branchB}/operational-teams`, "sup-a", {
      name: "Branch B Team",
      idempotency_key: ids.idemKeyRevoked,
    });
    assert.equal(replayAfterRevoke.status, 403);
    assert.equal(replayAfterRevoke.json.error.code, "ACCESS_DENIED");

    const rawErr = await req("POST", `/api/v1/supervisor/branches/${ids.branchB}/operational-teams`, "sup-a", {
      name: "Raw Err Team",
      idempotency_key: ids.idemKeyRawErr,
    });
    assert.equal(rawErr.status, 503);
    assert.equal(rawErr.json.error.code, "service_unavailable");
    assert.ok(!JSON.stringify(rawErr.json).includes("raw postgres"));
  });

  it("preserves legacy 3-arg createSupervisorOwnedOperationalTeam adapter backward compatibility", async () => {
    const legacyApp = createApp(config, {
      ...minimalSupportDeps,
      ...makeAuthContext(),
      operationalAdmin: {
        async getBranchTimezone() { return "Asia/Riyadh"; },
        async getSupervisorTeam() { return { teams: [] }; },
        async createStaff() { return {}; },
        async updateStaff() { return {}; },
        async setDuty() { return {}; },
        async listHealthCards() { return []; },
        async upsertHealthCard() { return {}; },
        async createSupervisorOwnedOperationalTeam({ actorUserId, branchId, name }) {
          return {
            team: {
              id: ids.legacyTeam1,
              organization_id: ids.org1,
              branch_id: branchId,
              name,
              active: true,
              legacy_supervisor_team_id: ids.legacyTeam1,
              supervisor_user_id: actorUserId,
              assignment_role: "primary" as const,
              can_write: true as const,
            },
          };
        },
      },
    });
    const legacyServer = createServer(legacyApp);
    await new Promise<void>((resolve) => legacyServer.listen(0, "127.0.0.1", () => resolve()));
    try {
      const addr = legacyServer.address() as AddressInfo;
      const res = await fetch(`http://127.0.0.1:${addr.port}/api/v1/supervisor/branches/${ids.branchA}/operational-teams`, {
        method: "POST",
        headers: { authorization: "Bearer sup-a", "content-type": "application/json" },
        body: JSON.stringify({ name: "Legacy Team" }),
      });
      const json = await res.json();
      assert.equal(res.status, 201);
      assert.equal(json.team.id, ids.legacyTeam1);
      assert.equal(json.team.name, "Legacy Team");
    } finally {
      await new Promise<void>((resolve) => legacyServer.close(() => resolve()));
    }
  });

  it("maps operational.ts PostgreSQL RPC error codes to distinct error classes without leaking raw SQL errors", async () => {
    const rpcResponses: Array<{ status: number; body: unknown }> = [
      { status: 409, body: { code: "23505", message: "employee team already assigned" } },
      { status: 409, body: { code: "23505", message: "employee team already exists" } },
      { status: 409, body: { code: "23505", message: "employee team idempotency conflict" } },
      { status: 403, body: { code: "42501", message: "employee team bootstrap denied" } },
      { status: 400, body: { code: "22023", message: "invalid employee team name" } },
    ];
    let idx = 0;
    const origFetch = globalThis.fetch;
    globalThis.fetch = (async () => {
      const next = rpcResponses[idx++];
      return new Response(JSON.stringify(next.body), {
        status: next.status,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;

    try {
      const admin = createOperationalAdmin("http://127.0.0.1:54321", "service-role-key");
      await assert.rejects(
        () => admin.createSupervisorOwnedOperationalTeamV2!({ actorUserId: ids.supA, branchId: ids.branchA, name: "T", idempotencyKey: ids.idemKey1 }),
        (err) => err instanceof OperationalTeamAlreadyAssignedError,
      );
      await assert.rejects(
        () => admin.createSupervisorOwnedOperationalTeamV2!({ actorUserId: ids.supA, branchId: ids.branchA, name: "T", idempotencyKey: ids.idemKey1 }),
        (err) => err instanceof OperationalTeamNameConflictError,
      );
      await assert.rejects(
        () => admin.createSupervisorOwnedOperationalTeamV2!({ actorUserId: ids.supA, branchId: ids.branchA, name: "T", idempotencyKey: ids.idemKey1 }),
        (err) => err instanceof OperationalIdempotencyConflictError,
      );
      await assert.rejects(
        () => admin.setSupervisorTeamOnboardingWaiting!({ actorUserId: ids.supA, branchId: ids.branchA }),
        (err) => err instanceof OperationalAccessError,
      );
      await assert.rejects(
        () => admin.getSupervisorTeamOnboardingState!({ actorUserId: ids.supA, branchIds: [ids.branchA] }),
        (err) => err instanceof OperationalInputError,
      );
    } finally {
      globalThis.fetch = origFetch;
    }
  });
});
