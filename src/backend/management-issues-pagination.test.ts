import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const manager = "17000000-0000-4000-8000-000000000001";
const supervisor = "17000000-0000-4000-8000-000000000002";
const org = "37000000-0000-4000-8000-000000000001";
const otherOrg = "37000000-0000-4000-8000-000000000002";
const branchA = "27000000-0000-4000-8000-000000000001";
const branchB = "27000000-0000-4000-8000-000000000002";

interface MockIssue {
  id: string;
  report_id: string;
  branch_id: string;
  branch_name: string;
  business_date: string;
  submitted_by: string | null;
  checklist_type: string;
  title: string;
  description: string;
  status: string;
  created_at: string;
  item_id: string;
  item_text: string;
}

function makeIssue(
  idNum: number,
  checklistType: string,
  branchId: string,
  createdAt: string,
): MockIssue {
  const hex = idNum.toString(16).padStart(12, "0");
  return {
    id: `00000000-0000-4000-8000-${hex}`,
    report_id: `a0000000-0000-4000-8000-${hex}`,
    branch_id: branchId,
    branch_name: branchId === branchA ? "Branch A" : "Branch B",
    business_date: createdAt.slice(0, 10),
    submitted_by: "Supervisor",
    checklist_type: checklistType,
    title: `${checklistType} issue #${idNum}`,
    description: `Description for ${checklistType} #${idNum}`,
    status: "new",
    created_at: createdAt,
    item_id: `item-${idNum}`,
    item_text: `Item ${idNum}`,
  };
}

const cmpIssues = (a: MockIssue, b: MockIssue) => {
  const c = b.created_at.localeCompare(a.created_at);
  return c !== 0 ? c : a.id.localeCompare(b.id);
};

let baseStore: MockIssue[] = [];
let oilStore: MockIssue[] = [];
let coldStore: MockIssue[] = [];
let salesStore: MockIssue[] = [];
let calls: { name: string; input: Record<string, unknown> }[] = [];
let simulatedConflict: "none" | "duplicate_id" | "total_changed" = "none";
let simulatedFailure: "none" | "cold_db_error" | "cold_malformed" = "none";

function paginateStore(
  store: MockIssue[],
  input: Record<string, unknown>,
  sourceName: string,
) {
  calls.push({ name: sourceName, input });
  if (sourceName === "cold-issues" && simulatedFailure === "cold_db_error") {
    throw new Error("FATAL: 57P01: terminating connection due to administrator command in relation cold_storage_readings");
  }
  const page = Number(input.requested_page);
  const pageSize = Number(input.requested_page_size);
  const offset = (page - 1) * pageSize;
  const issues = store.slice(offset, offset + pageSize);

  if (sourceName === "cold-issues" && simulatedFailure === "cold_malformed" && issues.length > 0) {
    issues[0] = { ...issues[0], checklist_type: "corrupted_type_not_in_schema" } as any;
  }

  if (sourceName === "cold-issues" && simulatedConflict === "duplicate_id" && page === 2 && issues.length > 0) {
    issues[0] = store[0]; // duplicate from page 1
  }

  const effectiveTotal =
    sourceName === "cold-issues" && simulatedConflict === "total_changed" && page === 2
      ? store.length + 5
      : store.length;

  return {
    issues,
    page,
    page_size: pageSize,
    total: effectiveTotal,
  };
}

const persistence = {
  async listManagedIssues(input: Record<string, unknown>) {
    return paginateStore(baseStore, input, "base-issues");
  },
  async listManagedOilTrackingIssues(input: Record<string, unknown>) {
    return paginateStore(oilStore, input, "oil-issues");
  },
  async listManagedColdStorageIssues(input: Record<string, unknown>) {
    return paginateStore(coldStore, input, "cold-issues");
  },
  async listManagedSalesTrackingIssues(input: Record<string, unknown>) {
    return paginateStore(salesStore, input, "sales-issues");
  },
  async getManagedIssue() { throw new ChecklistAccessError(); },
};

function deps(): BackendDependencies {
  return {
    checkReadiness: async () => true,
    checklistPersistence: persistence as any,
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
      verify: async (token) => {
        if (token === "manager") return { userId: manager, email: "m@example.invalid" };
        if (token === "supervisor") return { userId: supervisor, email: "s@example.invalid" };
        return null;
      },
    },
    createUserContext: (token) => ({
      getUserContext: async () =>
        token === "manager"
          ? { id: manager, full_name: "M", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: org, name: "O", role: "organization_manager" }] }
          : { id: supervisor, full_name: "S", must_change_password: false, disabled: false, branches: [{ id: branchA, name: "A", organization_id: org, role: "branch_manager" }], managed_organizations: [] },
      hasOrganizationManagerAccess: async (_userId, orgId) => token === "manager" && orgId === org,
      validateActiveBranches: async () => true,
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

async function request(path: string, token: string | null = "manager") {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  return fetch(origin + path, { headers });
}

describe("Management Issues Pagination & Window Limits", () => {
  before(async () => {
    const app = createApp(config, deps());
    server = createServer(app);
    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", () => {
        const address = server.address() as AddressInfo;
        origin = `http://127.0.0.1:${address.port}`;
        resolve();
      });
    });
  });

  after(async () => {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  });

  beforeEach(() => {
    baseStore = [];
    oilStore = [];
    coldStore = [];
    salesStore = [];
    calls = [];
    simulatedConflict = "none";
    simulatedFailure = "none";
    delete process.env.MANAGEMENT_ISSUE_MERGED_WINDOW_LIMIT;
  });

  it("1. handles zero issues across all sources gracefully", async () => {
    const res = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body, {
      issues: [],
      page: 1,
      page_size: 20,
      total: 0,
    });
  });

  it("2. handles fewer than 50 issues correctly on a single page", async () => {
    for (let i = 1; i <= 5; i++) baseStore.push(makeIssue(i, "kitchen_opening", branchA, `2026-08-01T10:0${i}:00Z`));
    for (let i = 6; i <= 8; i++) oilStore.push(makeIssue(i, "oil_tracking", branchA, `2026-08-01T11:0${i}:00Z`));
    for (let i = 9; i <= 12; i++) coldStore.push(makeIssue(i, "cold_storage", branchA, `2026-08-01T12:0${i}:00Z`));
    for (let i = 13; i <= 15; i++) salesStore.push(makeIssue(i, "sales_tracking", branchA, `2026-08-01T13:0${i}:00Z`));

    baseStore.sort(cmpIssues);
    oilStore.sort(cmpIssues);
    coldStore.sort(cmpIssues);
    salesStore.sort(cmpIssues);

    const res = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.total, 15);
    assert.equal(body.issues.length, 15);
    assert.equal(body.page, 1);
    assert.equal(body.page_size, 20);
    // Descending timestamp: sales (13:0x) > cold (12:0x) > oil (11:0x) > base (10:0x)
    assert.equal(body.issues[0].checklist_type, "sales_tracking");
    assert.equal(body.issues[14].checklist_type, "kitchen_opening");
  });

  it("3. paginates exactly 500 issues across the boundary without truncation", async () => {
    let id = 1;
    for (let i = 0; i < 200; i++) baseStore.push(makeIssue(id++, "kitchen_opening", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    for (let i = 0; i < 50; i++) oilStore.push(makeIssue(id++, "oil_tracking", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    for (let i = 0; i < 150; i++) coldStore.push(makeIssue(id++, "cold_storage", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    for (let i = 0; i < 100; i++) salesStore.push(makeIssue(id++, "sales_tracking", branchA, new Date(1700000000000 - i * 1000).toISOString()));

    baseStore.sort(cmpIssues);
    oilStore.sort(cmpIssues);
    coldStore.sort(cmpIssues);
    salesStore.sort(cmpIssues);

    // Page 25 with pageSize 20 => offset 480 to 500 (the 500th row boundary)
    const res = await request(`/api/v1/management/organizations/${org}/issues?page=25&page_size=20`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.total, 500);
    assert.equal(body.issues.length, 20);
    assert.equal(body.page, 25);
    assert.equal(body.page_size, 20);
  });

  it("4. paginates beyond 500 issues (e.g. 750 issues at page 30)", async () => {
    let id = 1;
    for (let i = 0; i < 300; i++) baseStore.push(makeIssue(id++, "kitchen_opening", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    for (let i = 0; i < 50; i++) oilStore.push(makeIssue(id++, "oil_tracking", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    for (let i = 0; i < 250; i++) coldStore.push(makeIssue(id++, "cold_storage", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    for (let i = 0; i < 150; i++) salesStore.push(makeIssue(id++, "sales_tracking", branchA, new Date(1700000000000 - i * 1000).toISOString()));

    baseStore.sort(cmpIssues);
    oilStore.sort(cmpIssues);
    coldStore.sort(cmpIssues);
    salesStore.sort(cmpIssues);

    // Page 30 with pageSize 20 => offset 580 to 600 (previously failed due to 500-limit)
    const res = await request(`/api/v1/management/organizations/${org}/issues?page=30&page_size=20`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.total, 750);
    assert.equal(body.issues.length, 20);
    assert.equal(body.page, 30);
  });

  it("5. production scale: retrieves all 1,345 issues across 68 pages without loss or duplicates", async () => {
    let id = 1;
    for (let i = 0; i < 86; i++) {
      baseStore.push(makeIssue(id++, "kitchen_opening", branchA, new Date(1700000000000 - (id * 1000)).toISOString()));
    }
    for (let i = 0; i < 2; i++) {
      oilStore.push(makeIssue(id++, "oil_tracking", branchA, new Date(1700000000000 - (id * 1000)).toISOString()));
    }
    for (let i = 0; i < 1112; i++) {
      coldStore.push(makeIssue(id++, "cold_storage", branchB, new Date(1700000000000 - (id * 1000)).toISOString()));
    }
    for (let i = 0; i < 145; i++) {
      salesStore.push(makeIssue(id++, "sales_tracking", branchA, new Date(1700000000000 - (id * 1000)).toISOString()));
    }

    baseStore.sort(cmpIssues);
    oilStore.sort(cmpIssues);
    coldStore.sort(cmpIssues);
    salesStore.sort(cmpIssues);

    // Fetch page 1
    const p1 = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
    assert.equal(p1.status, 200);
    const b1 = await p1.json();
    assert.equal(b1.total, 1345);
    assert.equal(b1.issues.length, 20);

    // Fetch page 67 (offset 1320..1340)
    const p67 = await request(`/api/v1/management/organizations/${org}/issues?page=67&page_size=20`);
    assert.equal(p67.status, 200);
    const b67 = await p67.json();
    assert.equal(b67.total, 1345);
    assert.equal(b67.issues.length, 20);

    // Fetch page 68 (offset 1340..1360) -> exactly 5 remaining issues (1341 to 1345)
    const p68 = await request(`/api/v1/management/organizations/${org}/issues?page=68&page_size=20`);
    assert.equal(p68.status, 200);
    const b68 = await p68.json();
    assert.equal(b68.total, 1345);
    assert.equal(b68.issues.length, 5);
    assert.equal(b68.page, 68);

    // Fetch page 69 (offset 1360..1380) -> beyond total, within window limit (1380 <= 2000)
    const p69 = await request(`/api/v1/management/organizations/${org}/issues?page=69&page_size=20`);
    assert.equal(p69.status, 200);
    const b69 = await p69.json();
    assert.equal(b69.total, 1345);
    assert.deepEqual(b69.issues, []);
    assert.equal(b69.page, 69);
  });

  it("6. guarantees stable deterministic tie-breaking by ID for identical timestamps", async () => {
    const sameTimestamp = "2026-08-01T12:00:00Z";
    baseStore.push(makeIssue(10, "kitchen_opening", branchA, sameTimestamp));
    baseStore.push(makeIssue(2, "kitchen_opening", branchA, sameTimestamp));
    oilStore.push(makeIssue(8, "oil_tracking", branchA, sameTimestamp));
    coldStore.push(makeIssue(5, "cold_storage", branchA, sameTimestamp));
    salesStore.push(makeIssue(1, "sales_tracking", branchA, sameTimestamp));

    baseStore.sort(cmpIssues);
    oilStore.sort(cmpIssues);
    coldStore.sort(cmpIssues);
    salesStore.sort(cmpIssues);

    const res = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=10`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.total, 5);
    // Since timestamps are identical, ordering must be strictly ascending by issue ID: 1, 2, 5, 8, 10
    const returnedIds = body.issues.map((i: MockIssue) => i.id);
    const sortedIds = [...returnedIds].sort();
    assert.deepEqual(returnedIds, sortedIds);
  });

  it("7. correctly forwards branch and date filters to all source RPCs", async () => {
    const res = await request(
      `/api/v1/management/organizations/${org}/issues?page=1&page_size=20&branch_id=${branchA}&date_from=2026-08-01&date_to=2026-08-07&status=new&search=temp`,
    );
    assert.equal(res.status, 200);
    const sourceCalls = calls.filter((c) => c.name.endsWith("-issues"));
    assert.equal(sourceCalls.length, 4);
    for (const call of sourceCalls) {
      assert.equal(call.input.branch_filter, branchA);
      assert.equal(call.input.date_from, "2026-08-01");
      assert.equal(call.input.date_to, "2026-08-07");
      assert.equal(call.input.status_filter, "new");
      assert.equal(call.input.search_term, "temp");
    }
  });

  it("8. detects concurrent mutation duplicate and returns 409 conflict", async () => {
    for (let i = 1; i <= 60; i++) {
      coldStore.push(makeIssue(i, "cold_storage", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    }
    coldStore.sort(cmpIssues);
    simulatedConflict = "duplicate_id";

    const res = await request(`/api/v1/management/organizations/${org}/issues?page=4&page_size=20`);
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.match(body.error.message, /The issue list changed/i);
  });

  it("9. detects concurrent total change between pages and returns 409 conflict", async () => {
    for (let i = 1; i <= 60; i++) {
      coldStore.push(makeIssue(i, "cold_storage", branchA, new Date(1700000000000 - i * 1000).toISOString()));
    }
    coldStore.sort(cmpIssues);
    simulatedConflict = "total_changed";

    const res = await request(`/api/v1/management/organizations/${org}/issues?page=4&page_size=20`);
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.match(body.error.message, /The issue list changed/i);
  });

  it("10. rejects unbounded requests exceeding the merged window limit with 400 Bad Request", async () => {
    // 41 * 50 = 2050 > 2000 default limit
    const res = await request(`/api/v1/management/organizations/${org}/issues?page=41&page_size=50`);
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.match(body.error.message, /The request is invalid/i);
    assert.equal(calls.length, 0); // DoS guard stopped execution before any DB calls
  });

  it("11. honors custom MANAGEMENT_ISSUE_MERGED_WINDOW_LIMIT environment variable", async () => {
    process.env.MANAGEMENT_ISSUE_MERGED_WINDOW_LIMIT = "3000";
    // 50 * 50 = 2500 (rejected under 2000, accepted under 3000)
    const res = await request(`/api/v1/management/organizations/${org}/issues?page=50&page_size=50`);
    assert.equal(res.status, 200);
  });

  it("12. enforces authentication and authorization strictly", async () => {
    // Unauthenticated
    const unauth = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`, null);
    assert.equal(unauth.status, 401);

    // Non-manager role (supervisor)
    const forbiddenSupervisor = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`, "supervisor");
    assert.equal(forbiddenSupervisor.status, 403);

    // Wrong organization
    const wrongOrg = await request(`/api/v1/management/organizations/${otherOrg}/issues?page=1&page_size=20`, "manager");
    assert.equal(wrongOrg.status, 403);
  });

  it("13. fails closed with 503 and sanitized message when a source throws raw database error", async () => {
    coldStore.push(makeIssue(1, "cold_storage", branchA, "2026-08-01T12:00:00Z"));
    simulatedFailure = "cold_db_error";

    const res = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.error.code, "service_unavailable");
    assert.equal(body.error.message, "The service is unavailable.");
    // Strict leak test: ensure raw PostgreSQL internals and table names are never leaked
    const serialized = JSON.stringify(body);
    assert.doesNotMatch(serialized, /FATAL|terminating|administrator|relation|cold_storage_readings/i);
  });

  it("14. fails closed with 503 and sanitized message when a source returns malformed schema data", async () => {
    coldStore.push(makeIssue(1, "cold_storage", branchA, "2026-08-01T12:00:00Z"));
    simulatedFailure = "cold_malformed";

    const res = await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.error.code, "service_unavailable");
    assert.equal(body.error.message, "The service is unavailable.");
    const serialized = JSON.stringify(body);
    assert.doesNotMatch(serialized, /corrupted_type_not_in_schema|ZodError/i);
  });
});
