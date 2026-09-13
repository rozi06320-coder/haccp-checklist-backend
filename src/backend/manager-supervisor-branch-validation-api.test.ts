import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { AdminConflictError } from "./admin";

const id = {
  manager: "10000000-0000-4000-8000-000000000001",
  otherManager: "10000000-0000-4000-8000-000000000002",
  organization: "20000000-0000-4000-8000-000000000001",
  otherOrganization: "20000000-0000-4000-8000-000000000002",
  branch: "30000000-0000-4000-8000-000000000001",
  validOtherSameOrgBranch: "30000000-0000-4000-8000-000000000002",
  crossOrgBranch: "30000000-0000-4000-8000-000000000099",
  staff: "40000000-0000-4000-8000-000000000001",
  staffMissingBranch: "40000000-0000-4000-8000-000000000002",
  staffPromoted: "40000000-0000-4000-8000-000000000003",
  createdUser: "50000000-0000-4000-8000-000000000001",
};

const calls: Array<Record<string, unknown>> = [];

function testDependencies(): BackendDependencies {
  return {
    checkReadiness: async () => true,
    authVerifier: {
      async verify(token) {
        if (token === "manager") return { userId: id.manager, email: "manager@example.invalid" };
        if (token === "unauthorized_manager") return { userId: id.otherManager, email: "other@example.invalid" };
        return null;
      },
    },
    createUserContext: (token) => ({
      async getUserContext() {
        if (token === "manager") {
          return {
            id: id.manager,
            full_name: "Manager User",
            disabled: false,
            must_change_password: false,
            branches: [],
            managed_organizations: [
              { id: id.organization, name: "Test Org", role: "organization_manager" },
              { id: id.otherOrganization, name: "Other Org", role: "organization_manager" },
            ],
          };
        }
        if (token === "unauthorized_manager") {
          return {
            id: id.otherManager,
            full_name: "Other Manager",
            disabled: false,
            must_change_password: false,
            branches: [],
            managed_organizations: [{ id: "20000000-0000-4000-8000-000000000099", name: "Foreign Org", role: "organization_manager" }],
          };
        }
        return null;
      },
      async hasOrganizationManagerAccess(orgId) {
        return token === "manager" && (orgId === id.organization || orgId === id.otherOrganization);
      },
      async validateActiveBranches(orgId, branchIds) {
        if (orgId !== id.organization) return false;
        const allowedActiveBranches = new Set([id.branch, id.validOtherSameOrgBranch]);
        return branchIds.every((branchId) => allowedActiveBranches.has(branchId));
      },
      async listActiveBranches() { return []; },
    }),
    provisioningAdmin: {
      async createUser(input) {
        calls.push({ method: "createUser", ...input });
        if (input.email === "conflict@example.invalid") {
          throw new AdminConflictError("User exists");
        }
        return { id: id.createdUser };
      },
      async deleteUser(userId) {
        calls.push({ method: "deleteUser", userId });
      },
      async finalize() {},
    },
    operationalAdmin: {
      async getManagedOperationalStaffSupervisorTrainingPromotionState(input) {
        calls.push({ method: "getPromotionState", ...input });
        if (input.staffId === id.staffMissingBranch) {
          return {
            staff_id: input.staffId,
            branch_id: null,
            branch_id_at_start: null,
            status: "training",
          };
        }
        if (input.staffId === id.staffPromoted) {
          return {
            staff_id: input.staffId,
            branch_id: id.branch,
            branch_id_at_start: id.branch,
            status: "promoted",
            promoted_supervisor_user_id: id.createdUser,
          };
        }
        return {
          staff_id: input.staffId,
          branch_id: id.branch,
          branch_id_at_start: id.branch,
          status: "training",
        };
      },
      async promoteManagedOperationalStaffSupervisorTraining(input) {
        calls.push({ method: "promoteSupervisorTraining", ...input });
        return {
          staff_id: input.staffId,
          status: "promoted",
          promoted_supervisor_user_id: input.newSupervisorUserId,
          assigned_branch: id.branch,
        };
      },
    } as unknown as BackendDependencies["operationalAdmin"],
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
    branchManagementAdmin: {
      async listBranches() { return []; },
      async listStaff() { return []; },
      async getPinMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async storePin() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async getPinCredential() { return null; },
    },
    pinCrypto: {
      async hash() { throw new Error("unused"); },
      async verify() { return false; },
      issueGrant() { return ""; },
      verifyGrant() { return false; },
    },
  };
}

const config: BackendConfig = {
  nodeEnv: "test",
  host: "127.0.0.1",
  port: 1,
  trustProxy: false
};

let server: Server;
let baseUrl: string;

function promoteUrl(staffId: string = id.staff, orgId: string = id.organization): string {
  return baseUrl + "/api/v1/management/organizations/" + orgId + "/operational-staff/" + staffId + "/supervisor-training/promote";
}

function request(url: string, body: Record<string, unknown>, token: string = "manager"): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("Manager Supervisor Promotion Explicit Branch Validation (Backend API)", () => {
  before(async () => {
    server = createServer(createApp(config, testDependencies()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    baseUrl = "http://127.0.0.1:" + (server.address() as AddressInfo).port;
  });

  after(() => new Promise<void>((resolve) => server.close(() => resolve())));

  beforeEach(() => {
    calls.length = 0;
  });

  it("1. missing branch_id returns 400 bad_request", async () => {
    const response = await request(promoteUrl(), {
      full_name: "Promoted Supervisor",
      email: "supervisor@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 400);
    const body = await response.json() as { error: { code: string } };
    assert.equal(body.error.code, "bad_request");
  });

  it("2. invalid non-UUID branch_id returns 400 bad_request", async () => {
    const response = await request(promoteUrl(), {
      branch_id: "not-a-valid-uuid",
      full_name: "Promoted Supervisor",
      email: "supervisor@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 400);
    const body = await response.json() as { error: { code: string } };
    assert.equal(body.error.code, "bad_request");
  });

  it("3. valid branch matching canonical staff branch succeeds with 201 Created", async () => {
    const response = await request(promoteUrl(), {
      branch_id: id.branch,
      full_name: "Promoted Supervisor",
      email: "supervisor1@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 201);
    const body = await response.json() as { status: string; promoted_supervisor_user_id: string };
    assert.equal(body.status, "promoted");
    assert.equal(body.promoted_supervisor_user_id, id.createdUser);
  });

  it("4. missing canonical staff branch returns 409 conflict with safe error message", async () => {
    const response = await request(promoteUrl(id.staffMissingBranch), {
      branch_id: id.branch,
      full_name: "Promoted Supervisor",
      email: "supervisor2@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 409);
    const body = await response.json() as { error: { code: string; message: string } };
    assert.equal(body.error.code, "conflict");
    assert.equal(body.error.message, "Employee branch assignment is unavailable.");
  });

  it("5. valid same-org different branch succeeds with 201 Created and forwards target branch", async () => {
    const response = await request(promoteUrl(), {
      branch_id: id.validOtherSameOrgBranch,
      full_name: "Promoted Supervisor",
      email: "supervisor3@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 201);
    const body = await response.json() as { status: string; promoted_supervisor_user_id: string };
    assert.equal(body.status, "promoted");
    const lastCall = calls.find((c) => c.method === "promoteSupervisorTraining" && c.branchId === id.validOtherSameOrgBranch);
    assert.ok(lastCall);
  });

  it("6. cross-org / inactive branch returns 403 forbidden", async () => {
    const response = await request(promoteUrl(), {
      branch_id: id.crossOrgBranch,
      full_name: "Promoted Supervisor",
      email: "supervisor4@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 403);
  });

  it("6b. branch submitted against wrong organization returns 403 forbidden", async () => {
    const response = await request(promoteUrl(id.staff, id.otherOrganization), {
      branch_id: id.branch,
      full_name: "Promoted Supervisor",
      email: "supervisor4b@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 403);
  });

  it("7. unauthorized manager receives 403 forbidden", async () => {
    const response = await request(promoteUrl(), {
      branch_id: id.branch,
      full_name: "Promoted Supervisor",
      email: "supervisor5@example.invalid",
      temporary_password: "secretpassword1",
    }, "unauthorized_manager");
    assert.equal(response.status, 403);
  });

  it("8 & 9. branch validation happens before createUser; missing/cross-org branch creates no auth user", async () => {
    await request(promoteUrl(id.staffMissingBranch), {
      branch_id: id.branch,
      full_name: "Missing Canonical",
      email: "missing@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(calls.some((c) => c.method === "createUser"), false);

    await request(promoteUrl(), {
      branch_id: id.crossOrgBranch,
      full_name: "Cross Org",
      email: "crossorg@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(calls.some((c) => c.method === "createUser"), false);
  });

  it("10 & 11. successful promotion calls DB RPC with target_branch_id while staff origin branch is preserved", async () => {
    const response = await request(promoteUrl(), {
      branch_id: id.validOtherSameOrgBranch,
      full_name: "Clean Supervisor",
      email: "clean@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 201);

    const promoteCall = calls.find((c) => c.method === "promoteSupervisorTraining" && c.branchId === id.validOtherSameOrgBranch);
    assert.ok(promoteCall);
    assert.equal(promoteCall.branchId, id.validOtherSameOrgBranch);
    assert.deepEqual(Object.keys(promoteCall).sort(), [
      "actorUserId",
      "branchId",
      "fullName",
      "fullNameAr",
      "method",
      "newSupervisorUserId",
      "organizationId",
      "staffId",
    ].sort());
  });

  it("12. temporary password provisioning conflict rolls back gracefully", async () => {
    const response = await request(promoteUrl(), {
      branch_id: id.branch,
      full_name: "Conflict Supervisor",
      email: "conflict@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(response.status, 409);
    const body = await response.json() as { error: { code: string; message: string } };
    assert.equal(body.error.code, "conflict");
    assert.equal(body.error.message, "An account with that email already exists.");
  });

  it("13. already-promoted state cannot bypass branch authorization", async () => {
    const crossOrgResponse = await request(promoteUrl(id.staffPromoted), {
      branch_id: id.crossOrgBranch,
      full_name: "Already Promoted",
      email: "already@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(crossOrgResponse.status, 403);

    const sameOrgResponse = await request(promoteUrl(id.staffPromoted), {
      branch_id: id.validOtherSameOrgBranch,
      full_name: "Already Promoted",
      email: "already@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(sameOrgResponse.status, 200);
    const body = await sameOrgResponse.json() as { status: string };
    assert.equal(body.status, "promoted");
    assert.equal(calls.some((c) => c.method === "createUser"), false);

    const validResponse = await request(promoteUrl(id.staffPromoted), {
      branch_id: id.branch,
      full_name: "Already Promoted",
      email: "already@example.invalid",
      temporary_password: "secretpassword1",
    });
    assert.equal(validResponse.status, 200);
    assert.equal(calls.some((c) => c.method === "createUser"), false);
  });
});
