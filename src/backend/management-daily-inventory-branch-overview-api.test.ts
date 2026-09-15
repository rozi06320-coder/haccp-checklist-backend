import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError, ChecklistInputError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const manager = "b1000000-0000-4000-8000-000000000001";
const supervisor = "b1000000-0000-4000-8000-000000000002";
const organization = "b2000000-0000-4000-8000-000000000001";
const otherOrganization = "b2000000-0000-4000-8000-000000000002";
const branchA = "b3000000-0000-4000-8000-000000000001";
const branchB = "b3000000-0000-4000-8000-000000000002";
const externalBranch = "b3000000-0000-4000-8000-000000000099";

const mockBranchOverviewResponse = {
  business_date: "2026-09-02",
  rows: [
    {
      branch_id: branchA,
      branch_name: "Branch Alpha",
      branch_code: "BA1",
      business_date: "2026-09-02",
      has_submission: true,
      total_entries_count: 10,
      items_checked_count: 10,
      variance_items_count: 0,
      missing_closing_count: 0,
      unreconciled_items_count: 0,
      attention_status: "clear" as const,
    },
    {
      branch_id: branchB,
      branch_name: "Branch Beta",
      branch_code: "BB1",
      business_date: "2026-09-02",
      has_submission: false,
      total_entries_count: 0,
      items_checked_count: 0,
      variance_items_count: 0,
      missing_closing_count: 0,
      unreconciled_items_count: 0,
      attention_status: "no_submission" as const,
    },
  ],
  total_branches: 2,
  needs_attention_count: 0,
  no_submission_count: 1,
  clear_count: 1,
};

let lastOverviewQuery: Record<string, unknown> | null = null;
let simulateDbError = false;

const persistence = {
  async listManagedDailyInventoryBranchOverview(input: Record<string, unknown>) {
    lastOverviewQuery = input;
    if (simulateDbError) throw new Error("database connection timeout");
    if (input.actorUserId !== manager || input.organizationId !== organization) throw new ChecklistAccessError();
    if (input.attentionFilter && !["all", "needs_attention", "no_submission"].includes(String(input.attentionFilter))) {
      throw new ChecklistInputError();
    }
    const filter = input.attentionFilter;
    const branchId = input.branchId;
    let filteredRows = mockBranchOverviewResponse.rows;
    if (branchId) {
      filteredRows = filteredRows.filter((r) => r.branch_id === branchId);
    }
    if (filter && filter !== "all") {
      filteredRows = filteredRows.filter((r) => r.attention_status === filter);
    }
    return {
      business_date: input.businessDate,
      rows: filteredRows,
      total_branches: branchId ? 1 : mockBranchOverviewResponse.total_branches,
      needs_attention_count: mockBranchOverviewResponse.needs_attention_count,
      no_submission_count: mockBranchOverviewResponse.no_submission_count,
      clear_count: mockBranchOverviewResponse.clear_count,
    };
  },
};

function dependencies(): BackendDependencies {
  return {
    checkReadiness: async () => true,
    checklistPersistence: persistence,
    passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
    provisioningAdmin: { createUser: async () => ({ id: manager }), deleteUser: async () => {}, finalize: async () => {} },
    managementAdmin: { listUsers: async () => ({ users: [], total: 0 }) },
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
    authVerifier: {
      verify: async (token) =>
        token === "manager"
          ? { userId: manager, email: "manager@example.invalid" }
          : token === "supervisor"
            ? { userId: supervisor, email: "supervisor@example.invalid" }
            : null,
    },
    createUserContext: (token) => ({
      getUserContext: async () =>
        token === "manager"
          ? {
              id: manager,
              full_name: "Operations Manager",
              must_change_password: false,
              disabled: false,
              branches: [],
              managed_organizations: [{ id: organization, name: "Burger HQ", role: "organization_manager" }],
            }
          : {
              id: supervisor,
              full_name: "Branch Supervisor",
              must_change_password: false,
              disabled: false,
              branches: [{ id: branchA, name: "Branch Alpha", organization_id: organization, role: "branch_manager" }],
              managed_organizations: [],
            },
      hasOrganizationManagerAccess: async (_userId, orgId) => token === "manager" && orgId === organization,
      validateActiveBranches: async (_orgId, branchIds) => branchIds.every((id) => id === branchA || id === branchB),
      listActiveBranches: async () => [],
    }),
  };
}

const config: BackendConfig = {
  nodeEnv: "test",
  host: "127.0.0.1",
  port: 1,
  trustProxy: false,
  supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" },
  dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests",
};

let server: Server;
let origin: string;

async function request(path: string, token = "manager", method = "GET") {
  return fetch(`${origin}${path}`, { method, headers: { Authorization: `Bearer ${token}` } });
}

describe("Manager Daily Inventory Branch Overview API", () => {
  before(async () => {
    server = createServer(createApp(config, dependencies()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  describe("1. Validation & Bad Requests (400)", () => {
    it("rejects request without business_date", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview`);
      assert.equal(res.status, 400);
      const json = await res.json();
      assert.equal(json.error.code, "bad_request");
    });

    it("rejects request with malformed business_date format", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=not-a-date`);
      assert.equal(res.status, 400);
      const json = await res.json();
      assert.equal(json.error.code, "bad_request");
    });

    it("rejects request with impossible Gregorian date (e.g. 2026-02-31)", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-02-31`);
      assert.equal(res.status, 400);
      const json = await res.json();
      assert.equal(json.error.code, "bad_request");
    });

    it("rejects invalid organization UUID", async () => {
      const res = await request(`/api/v1/management/organizations/not-a-uuid/daily-inventory/branch-overview?business_date=2026-09-02`);
      assert.equal(res.status, 400);
      const json = await res.json();
      assert.equal(json.error.code, "bad_request");
    });

    it("rejects invalid branch UUID format", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02&branch_id=invalid-uuid`);
      assert.equal(res.status, 400);
      const json = await res.json();
      assert.equal(json.error.code, "bad_request");
    });

    it("rejects invalid attention filter enum value", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02&attention=invalid_filter`);
      assert.equal(res.status, 400);
      const json = await res.json();
      assert.equal(json.error.code, "bad_request");
    });
  });

  describe("2. Authorization & Tenant Boundary (403)", () => {
    it("denies access to non-manager supervisor", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02`, "supervisor");
      assert.equal(res.status, 403);
      const json = await res.json();
      assert.equal(json.error.code, "forbidden");
    });

    it("denies manager access to another organization", async () => {
      const res = await request(`/api/v1/management/organizations/${otherOrganization}/daily-inventory/branch-overview?business_date=2026-09-02`);
      assert.equal(res.status, 403);
      const json = await res.json();
      assert.equal(json.error.code, "forbidden");
    });

    it("denies manager access when filtering by branch outside organization", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02&branch_id=${externalBranch}`);
      assert.equal(res.status, 403);
      const json = await res.json();
      assert.equal(json.error.code, "forbidden");
    });
  });

  describe("3. Safe Generic Error Handling (503)", () => {
    it("returns safe generic error shape and leaks no SQL or internal details on DB failure", async () => {
      simulateDbError = true;
      try {
        const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02`);
        assert.equal(res.status, 503);
        const json = await res.json();
        assert.equal(json.error.code, "service_unavailable");
        assert.equal(json.error.message, "The service is unavailable.");
        assert.equal(JSON.stringify(json).includes("timeout"), false);
        assert.equal(JSON.stringify(json).includes("postgres"), false);
        assert.equal(JSON.stringify(json).includes("RPC"), false);
      } finally {
        simulateDbError = false;
      }
    });
  });

  describe("4. Success Contract & Filter Behaviors (200)", () => {
    it("returns successful response matching contract", async () => {
      lastOverviewQuery = null;
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02`);
      assert.equal(res.status, 200);
      assert.equal(res.headers.get("Cache-Control"), "private, no-store");
      const json = await res.json();
      assert.equal(json.business_date, "2026-09-02");
      assert.equal(json.total_branches, 2);
      assert.equal(json.needs_attention_count, 0);
      assert.equal(json.no_submission_count, 1);
      assert.equal(json.clear_count, 1);
      assert.equal(json.rows.length, 2);
      assert.equal(json.rows[0].branch_id, branchA);
      assert.equal(json.rows[0].branch_name, "Branch Alpha");
      assert.equal(json.rows[0].branch_code, "BA1");
      assert.equal(json.rows[0].has_submission, true);
      assert.equal(json.rows[0].total_entries_count, 10);
      assert.equal(json.rows[0].items_checked_count, 10);
      assert.equal(json.rows[0].variance_items_count, 0);
      assert.equal(json.rows[0].missing_closing_count, 0);
      assert.equal(json.rows[0].unreconciled_items_count, 0);
      assert.equal(json.rows[0].attention_status, "clear");
    });

    it("passes optional branch_id filter to persistence", async () => {
      lastOverviewQuery = null;
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02&branch_id=${branchA}`);
      assert.equal(res.status, 200);
      assert.equal(lastOverviewQuery?.branchId, branchA);
      const json = await res.json();
      assert.equal(json.rows.length, 1);
      assert.equal(json.rows[0].branch_id, branchA);
    });

    it("passes attention filter to persistence and receives filtered rows while summary counters represent full population", async () => {
      lastOverviewQuery = null;
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory/branch-overview?business_date=2026-09-02&attention=no_submission`);
      assert.equal(res.status, 200);
      assert.equal(lastOverviewQuery?.attentionFilter, "no_submission");
      const json = await res.json();
      assert.equal(json.rows.length, 1);
      assert.equal(json.rows[0].branch_id, branchB);
      assert.equal(json.rows[0].attention_status, "no_submission");
      assert.equal(json.total_branches, 2);
      assert.equal(json.clear_count, 1);
      assert.equal(json.no_submission_count, 1);
    });
  });
});
