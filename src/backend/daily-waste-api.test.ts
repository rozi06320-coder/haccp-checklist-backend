import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import {
  ChecklistAccessError,
  ChecklistConflictError,
  ChecklistInputError,
  createChecklistPersistence,
  type SaveBranchDailyWasteInput,
} from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const other = "17000000-0000-4000-8000-000000000003";
const branch = "27000000-0000-4000-8000-000000000001";
const otherBranch = "27000000-0000-4000-8000-000000000002";
const org = "37000000-0000-4000-8000-000000000001";
const inventoryItemId = "47000000-0000-4000-8000-000000000001";
const inventoryItemId2 = "47000000-0000-4000-8000-000000000002";
const reportId = "87000000-0000-4000-8000-000000000001";
const entryId = "97000000-0000-4000-8000-000000000001";

const calls: Array<{ name: string; input: unknown }> = [];
let mode:
  | "empty"
  | "populated"
  | "string_numbers"
  | "conflict"
  | "access"
  | "range_exceeded"
  | "threshold_note_required"
  | "inactive_item"
  | "db_integrity_error" = "empty";

function emptyDailyWasteGet() {
  return {
    organization_id: org,
    branch_id: branch,
    start_date: "2026-09-01",
    end_date: "2026-09-10",
    current_business_date: "2026-09-10",
    reports: [],
  };
}

function populatedDailyWasteGet() {
  const stringNumbers = mode === "string_numbers";
  return {
    organization_id: org,
    branch_id: branch,
    start_date: "2026-09-01",
    end_date: "2026-09-10",
    current_business_date: "2026-09-10",
    reports: [
      {
        report_id: reportId,
        business_date: "2026-09-10",
        revision: 1,
        created_at: "2026-09-10T08:00:00.000Z",
        updated_at: "2026-09-10T08:00:00.000Z",
        entries: [
          {
            entry_id: entryId,
            inventory_item_id: inventoryItemId,
            inventory_item_name_snapshot: "Beef Patty",
            inventory_item_unit_snapshot: "pcs",
            quantity: stringNumbers ? "6.5" : 6,
            note: "Damaged during prep",
            created_at: "2026-09-10T08:00:00.000Z",
            updated_at: "2026-09-10T08:00:00.000Z",
          },
        ],
      },
    ],
  };
}

function savedDailyWastePatch(input?: SaveBranchDailyWasteInput) {
  const stringNumbers = mode === "string_numbers";
  return {
    report_id: reportId,
    organization_id: org,
    branch_id: branch,
    business_date: input?.businessDate ?? "2026-09-10",
    current_business_date: "2026-09-10",
    revision: (input?.expectedRevision ?? 0) + 1,
    created_at: "2026-09-10T08:00:00.000Z",
    updated_at: "2026-09-10T08:00:00.000Z",
    entries: (input?.waste ?? []).filter((w) => w.quantity > 0).map((w, idx) => ({
      entry_id: `97000000-0000-4000-8000-00000000000${idx + 1}`,
      inventory_item_id: w.inventory_item_id,
      inventory_item_name_snapshot: "Inventory Item",
      inventory_item_unit_snapshot: "pcs",
      quantity: stringNumbers ? String(w.quantity) : w.quantity,
      note: w.note ?? null,
      created_at: "2026-09-10T08:00:00.000Z",
      updated_at: "2026-09-10T08:00:00.000Z",
    })),
  };
}

const persistence = {
  async getBranchDailyWaste(actorUserId: string, branchId: string, startDate: string, endDate: string) {
    calls.push({ name: "getBranchDailyWaste", input: { actorUserId, branchId, startDate, endDate } });
    if (mode === "access" || branchId !== branch) throw new ChecklistAccessError();
    if (mode === "range_exceeded") throw new ChecklistInputError();
    if (mode === "db_integrity_error") throw new Error("fatal: waste table corrupt");
    return mode === "populated" || mode === "string_numbers" ? populatedDailyWasteGet() : emptyDailyWasteGet();
  },
  async saveBranchDailyWaste(input: SaveBranchDailyWasteInput) {
    calls.push({ name: "saveBranchDailyWaste", input });
    if (mode === "conflict") throw new ChecklistConflictError();
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "threshold_note_required" || mode === "inactive_item") throw new ChecklistInputError();
    if (mode === "db_integrity_error") throw new Error("fatal: transaction aborted");
    mode = "populated";
    return savedDailyWastePatch(input);
  },
  async getBranchProductSales() { throw new Error("unused"); },
  async saveBranchProductSales() { throw new Error("unused"); },
  async getOverview() { throw new Error("unused"); },
  async getCurrentState() { throw new Error("unused"); },
  async saveDraft() { throw new Error("unused"); },
  async saveHygieneDraft() { throw new Error("unused"); },
  async submitOpening() { throw new Error("unused"); },
  async submitHygiene() { throw new Error("unused"); },
  async listSupervisor() { throw new Error("unused"); },
  async getReport() { throw new ChecklistAccessError(); },
  async listManagedReports() { return { reports: [], page: 1, page_size: 20, total: 0 }; },
  async listManagedIssues() { return { issues: [], page: 1, page_size: 20, total: 0 }; },
  async getManagedIssue() { throw new Error("unused"); },
} as BackendDependencies["checklistPersistence"];

function deps(): BackendDependencies {
  return {
    checkReadiness: async () => true,
    checklistPersistence: persistence,
    passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
    provisioningAdmin: { createUser: async () => ({ id: supervisor }), deleteUser: async () => {}, finalize: async () => {} },
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
      verifyGrant: async () => false,
    },
    authVerifier: {
      verify: async (token) =>
        token === "supervisor"
          ? { userId: supervisor, email: "s@example.invalid" }
          : token === "manager"
            ? { userId: manager, email: "m@example.invalid" }
            : token === "other"
              ? { userId: other, email: "o@example.invalid" }
              : token === "dual"
                ? { userId: supervisor, email: "dual@example.invalid" }
                : null,
    },
    createUserContext: (token) => ({
      getUserContext: async () =>
        token === "supervisor" || token === "dual"
          ? {
              id: supervisor,
              full_name: "Supervisor",
              must_change_password: false,
              disabled: false,
              branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }],
              managed_organizations:
                token === "dual" ? [{ id: "37000000-0000-4000-8000-000000000099", name: "Other Org", role: "organization_manager" }] : [],
            }
          : token === "manager"
            ? {
                id: manager,
                full_name: "Manager",
                must_change_password: false,
                disabled: false,
                branches: [],
                managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }],
              }
            : {
                id: other,
                full_name: "Other",
                must_change_password: false,
                disabled: false,
                branches: [],
                managed_organizations: [],
              },
      isInternalAdmin: async () => false,
      hasOrganizationManagerAccess: async () => false,
      validateActiveBranches: async () => false,
      listActiveBranches: async () => [],
    }),
  };
}

const config: BackendConfig = {
  nodeEnv: "test",
  host: "127.0.0.1",
  port: 0,
  trustProxy: false,
  corsOrigins: [],
  rateLimit: {
    publicWindowMs: 60000,
    publicMaxRequests: 1000,
    protectedWindowMs: 60000,
    protectedMaxRequests: 1000,
    authWindowMs: 60000,
    authMaxRequests: 1000,
  },
  supabase: { url: "http://127.0.0.1:54321", anonKey: "anon", serviceRoleKey: "service" },
  evidence: { bucket: "evidence", uploadTtlSeconds: 300, downloadTtlSeconds: 300 },
  branding: { bucket: "branding", logoMaxBytes: 1048576, allowedMimeTypes: ["image/png"] },
  serviceAuthSecret: "test-secret-min-32-chars-long-123456",
  securityAuditWebhookUrl: null,
};

describe("Supervisor Daily Waste API", () => {
  let server: Server;
  let origin = "";

  before(async () => {
    const app = createApp(config, deps());
    server = createServer(app);
    await new Promise<void>((resolve, reject) => {
      server.listen(0, "127.0.0.1", () => resolve()).once("error", reject);
    });
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  beforeEach(() => {
    calls.length = 0;
    mode = "empty";
  });

  async function request(path: string, token: string | null = "supervisor", init?: RequestInit) {
    const headers = new Headers(init?.headers);
    if (token) headers.set("Authorization", `Bearer ${token}`);
    return fetch(`${origin}${path}`, { ...init, headers });
  }

  // 1. authorized supervisor own branch => 200
  it("GET 1: authorized supervisor own branch => 200", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=2026-09-01&end_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.branch_id, branch);
    assert.equal(body.organization_id, org);
    assert.equal(body.start_date, "2026-09-01");
    assert.equal(body.end_date, "2026-09-10");
    assert.deepEqual(body.reports, []);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], {
      name: "getBranchDailyWaste",
      input: {
        actorUserId: supervisor,
        branchId: branch,
        startDate: "2026-09-01",
        endDate: "2026-09-10",
      },
    });
  });

  // 2. unauthorized branch => 403
  it("GET 2: unauthorized branch => 403", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${otherBranch}/inventory/daily-waste?start_date=2026-09-01&end_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 403);
    const body = await res.json();
    assert.equal(body.error.code, "forbidden");
    assert.equal(calls.length, 0);
  });

  // 3. missing start_date => 400
  it("GET 3: missing start_date => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?end_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 4. missing end_date => 400
  it("GET 4: missing end_date => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=2026-09-01`,
      "supervisor",
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 5. invalid date format => 400
  it("GET 5: invalid date format => 400", async () => {
    for (const bad of ["2026/09/01", "2026-9-1", "invalid-date", "2026-02-30"]) {
      const res = await request(
        `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=${encodeURIComponent(bad)}&end_date=2026-09-10`,
        "supervisor",
      );
      assert.equal(res.status, 400, bad);
      const body = await res.json();
      assert.equal(body.error.code, "bad_request", bad);
    }
    assert.equal(calls.length, 0);
  });

  // 6. start > end => 400
  it("GET 6: start > end => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=2026-09-15&end_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 7. DB range >62 mapping => 422
  it("GET 7: DB range >62 mapping => 422", async () => {
    mode = "range_exceeded";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=2026-06-01&end_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.equal(body.error.code, "unprocessable_entity");
    assert.equal(calls.length, 1);
  });

  // 8. quantities normalized to numbers
  it("GET 8: quantities normalized to numbers", async () => {
    mode = "string_numbers";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=2026-09-01&end_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(typeof body.reports[0].entries[0].quantity, "number");
    assert.equal(body.reports[0].entries[0].quantity, 6.5);
  });

  // 9. authorized save => 200
  it("PATCH 9: authorized save => 200", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [
            {
              inventory_item_id: inventoryItemId,
              quantity: 6,
              note: "Damaged during prep",
            },
          ],
        }),
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.branch_id, branch);
    assert.equal(body.revision, 1);
    assert.equal(body.entries.length, 1);
    assert.equal(body.entries[0].quantity, 6);
    assert.equal(body.entries[0].note, "Damaged during prep");
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], {
      name: "saveBranchDailyWaste",
      input: {
        actorUserId: supervisor,
        branchId: branch,
        businessDate: "2026-09-10",
        expectedRevision: 0,
        waste: [
          {
            inventory_item_id: inventoryItemId,
            quantity: 6,
            note: "Damaged during prep",
          },
        ],
      },
    });
  });

  // 10. unauthorized branch => 403
  it("PATCH 10: unauthorized branch => 403", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${otherBranch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: inventoryItemId, quantity: 1 }],
        }),
      },
    );
    assert.equal(res.status, 403);
    const body = await res.json();
    assert.equal(body.error.code, "forbidden");
    assert.equal(calls.length, 0);
  });

  // 11. PUT => 404 / unavailable
  it("PATCH 11: PUT => 404 / unavailable", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [],
        }),
      },
    );
    assert.equal(res.status, 404);
    assert.equal(calls.length, 0);
  });

  // 12. missing business_date => 400
  it("PATCH 12: missing business_date => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          expected_revision: 0,
          waste: [],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 13. missing expected_revision => 400
  it("PATCH 13: missing expected_revision => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          waste: [],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 14. null expected_revision => 400
  it("PATCH 14: null expected_revision => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: null,
          waste: [],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 15. negative revision => 400
  it("PATCH 15: negative revision => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: -1,
          waste: [],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 16. non-integer revision => 400
  it("PATCH 16: non-integer revision => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 1.5,
          waste: [],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 17. waste not array => 400
  it("PATCH 17: waste not array => 400", async () => {
    for (const bad of [null, "not-array", 123, {}]) {
      const res = await request(
        `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
        "supervisor",
        {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            business_date: "2026-09-10",
            expected_revision: 0,
            waste: bad,
          }),
        },
      );
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.equal(body.error.code, "bad_request");
    }
    assert.equal(calls.length, 0);
  });

  // 18. malformed inventory_item_id => 400
  it("PATCH 18: malformed inventory_item_id => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: "not-a-uuid", quantity: 1 }],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 19. negative quantity => 400
  it("PATCH 19: negative quantity => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: inventoryItemId, quantity: -0.5 }],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 20. NaN/infinite-equivalent invalid JSON handling => 400
  it("PATCH 20: NaN/infinite-equivalent invalid JSON handling => 400", async () => {
    // In JSON strings or non-numeric representations
    for (const bad of ["NaN", "Infinity", null]) {
      const res = await request(
        `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
        "supervisor",
        {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            business_date: "2026-09-10",
            expected_revision: 0,
            waste: [{ inventory_item_id: inventoryItemId, quantity: bad }],
          }),
        },
      );
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.equal(body.error.code, "bad_request");
    }
    assert.equal(calls.length, 0);
  });

  // 21. note wrong type => 400
  it("PATCH 21: note wrong type => 400", async () => {
    for (const bad of [123, true, [], {}]) {
      const res = await request(
        `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
        "supervisor",
        {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            business_date: "2026-09-10",
            expected_revision: 0,
            waste: [{ inventory_item_id: inventoryItemId, quantity: 1, note: bad }],
          }),
        },
      );
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.equal(body.error.code, "bad_request");
    }
    assert.equal(calls.length, 0);
  });

  // 22. unknown top-level field rejected => 400
  it("PATCH 22: unknown top-level field rejected => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [],
          unexpected_field: "foo",
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 23. unknown waste item field rejected => 400
  it("PATCH 23: unknown waste item field rejected => 400", async () => {
    for (const badField of [
      { inventory_item_name_snapshot: "Hacked" },
      { inventory_item_unit_snapshot: "kg" },
      { kind: "ingredient" },
      { foo: "bar" },
    ]) {
      const res = await request(
        `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
        "supervisor",
        {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            business_date: "2026-09-10",
            expected_revision: 0,
            waste: [
              {
                inventory_item_id: inventoryItemId,
                quantity: 1,
                ...badField,
              },
            ],
          }),
        },
      );
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.equal(body.error.code, "bad_request");
    }
    assert.equal(calls.length, 0);
  });

  // 24. duplicate inventory_item_id rejected => 400
  it("PATCH 24: duplicate inventory_item_id rejected => 400", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [
            { inventory_item_id: inventoryItemId, quantity: 1 },
            { inventory_item_id: inventoryItemId, quantity: 2 },
          ],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 25. quantity 0 accepted and forwarded
  it("PATCH 25: quantity 0 accepted and forwarded", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 1,
          waste: [{ inventory_item_id: inventoryItemId, quantity: 0 }],
        }),
      },
    );
    assert.equal(res.status, 200);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].input, {
      actorUserId: supervisor,
      branchId: branch,
      businessDate: "2026-09-10",
      expectedRevision: 1,
      waste: [{ inventory_item_id: inventoryItemId, quantity: 0, note: null }],
    });
  });

  // 26. empty waste array accepted
  it("PATCH 26: empty waste array accepted", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [],
        }),
      },
    );
    assert.equal(res.status, 200);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].input, {
      actorUserId: supervisor,
      branchId: branch,
      businessDate: "2026-09-10",
      expectedRevision: 0,
      waste: [],
    });
  });

  // 27. DB threshold-note validation maps to 422
  it("PATCH 27: DB threshold-note validation maps to 422", async () => {
    mode = "threshold_note_required";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: inventoryItemId, quantity: 10 }],
        }),
      },
    );
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.equal(body.error.code, "unprocessable_entity");
    assert.equal(calls.length, 1);
  });

  // 28. stale revision maps to 409
  it("PATCH 28: stale revision maps to 409", async () => {
    mode = "conflict";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: inventoryItemId, quantity: 1 }],
        }),
      },
    );
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.equal(body.error.code, "conflict");
    assert.equal(calls.length, 1);
  });

  // 29. inactive new item DB rejection maps correctly to 422
  it("PATCH 29: inactive new item DB rejection maps correctly", async () => {
    mode = "inactive_item";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: inventoryItemId, quantity: 1 }],
        }),
      },
    );
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.equal(body.error.code, "unprocessable_entity");
    assert.equal(calls.length, 1);
  });

  // 30. DB integrity failure maps to 503
  it("PATCH 30: DB integrity failure maps to 503", async () => {
    mode = "db_integrity_error";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: inventoryItemId, quantity: 1 }],
        }),
      },
    );
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.error.code, "service_unavailable");
    assert.equal(calls.length, 1);
  });

  // 31. raw DB errors never leak
  it("31: maps Daily Waste SQLSTATE classes without leaking raw database details", async () => {
    const cases: Array<[string, number, string, () => Error]> = [
      ["40001", 409, "conflict", () => new ChecklistConflictError("40001")],
      ["23505", 409, "conflict", () => new ChecklistConflictError("23505")],
      ["22023", 422, "unprocessable_entity", () => new ChecklistInputError("raw db 22023")],
      ["22004", 422, "unprocessable_entity", () => new ChecklistInputError("raw db 22004")],
      ["42501", 403, "forbidden", () => new ChecklistAccessError("raw db 42501")],
      ["23514", 503, "service_unavailable", () => new Error("raw postgres 23514 constraint failure")],
      ["55000", 503, "service_unavailable", () => new Error("raw postgres 55000 object not in prerequisite state")],
      ["22000", 503, "service_unavailable", () => new Error("raw postgres 22000 data exception")],
      ["XX999", 503, "service_unavailable", () => new Error("raw postgres unexpected error")],
    ];
    for (const [sqlstate, status, code, errorFactory] of cases) {
      const originalGet = persistence.getBranchDailyWaste;
      persistence.getBranchDailyWaste = async () => {
        throw errorFactory();
      };
      try {
        const res = await request(
          `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=2026-09-01&end_date=2026-09-10`,
          "supervisor",
        );
        assert.equal(res.status, status, sqlstate);
        const body = await res.json();
        assert.equal(body.error.code, code, sqlstate);
        assert.equal(JSON.stringify(body).includes(sqlstate), false, sqlstate);
        assert.equal(JSON.stringify(body).includes("postgres"), false, sqlstate);
        assert.equal(JSON.stringify(body).includes("constraint"), false, sqlstate);
      } finally {
        persistence.getBranchDailyWaste = originalGet;
      }
    }
  });

  // RPC translation test with real createChecklistPersistence
  it("translates Daily Waste RPC SQLSTATEs narrowly in persistence", async () => {
    const cases: Array<[string, new (...args: never[]) => Error]> = [
      ["40001", ChecklistConflictError],
      ["23505", ChecklistConflictError],
      ["22023", ChecklistInputError],
      ["22004", ChecklistInputError],
      ["42501", ChecklistAccessError],
      ["23514", Error],
      ["55000", Error],
      ["22000", Error],
      ["XX999", Error],
    ];

    for (const [sqlstate, expectedError] of cases) {
      const rpcServer = createServer((_, res) => {
        res.statusCode = 400;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ code: sqlstate, message: "raw database text", details: "constraint name" }));
      });
      await new Promise<void>((resolve, reject) => rpcServer.listen(0, "127.0.0.1", resolve).once("error", reject));
      const rpcOrigin = `http://127.0.0.1:${(rpcServer.address() as AddressInfo).port}`;
      const realPersistence = createChecklistPersistence(rpcOrigin, "secret");
      try {
        await assert.rejects(
          () => realPersistence.getBranchDailyWaste?.(supervisor, branch, "2026-09-01", "2026-09-10"),
          (error: unknown) => {
            assert.equal(error instanceof expectedError, true, sqlstate);
            if (sqlstate === "23514" || sqlstate === "55000" || sqlstate === "22000" || sqlstate === "XX999") {
              assert.equal(error instanceof ChecklistConflictError, false, sqlstate);
              assert.equal(error instanceof ChecklistInputError, false, sqlstate);
              assert.equal(error instanceof ChecklistAccessError, false, sqlstate);
            }
            return true;
          },
        );
      } finally {
        await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
      }
    }
  });

  // Isolation: verify no direct table writes, only RPC calls, and Product Sales unchanged
  it("verifies only RPC calls used and Product Sales unchanged", async () => {
    // 1. GET daily waste calls getBranchDailyWaste only
    const resGet = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste?start_date=2026-09-01&end_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(resGet.status, 200);

    // 2. PATCH daily waste calls saveBranchDailyWaste only
    const resPatch = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-waste`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          waste: [{ inventory_item_id: inventoryItemId, quantity: 3, note: "Test" }],
        }),
      },
    );
    assert.equal(resPatch.status, 200);
    assert.deepEqual(calls.map((call) => call.name), ["getBranchDailyWaste", "saveBranchDailyWaste"]);

    // 3. Response shape contains only Daily Waste fields
    const body = await resPatch.json();
    const keys = Object.keys(body).sort();
    assert.deepEqual(keys, [
      "branch_id",
      "business_date",
      "created_at",
      "current_business_date",
      "entries",
      "organization_id",
      "report_id",
      "revision",
      "updated_at",
    ].sort());

    assert.equal("sales" in body, false);
    assert.equal("usage_snapshots" in body, false);
    assert.equal("transfers" in body, false);
    assert.equal("closing" in body, false);
  });
});
