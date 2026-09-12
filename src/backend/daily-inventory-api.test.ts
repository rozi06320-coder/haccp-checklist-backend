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
  type GetBranchDailyInventoryInput,
  type SaveBranchDailyInventoryInput,
} from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const other = "17000000-0000-4000-8000-000000000003";
const branch = "27000000-0000-4000-8000-000000000001";
const org = "37000000-0000-4000-8000-000000000001";
const inventoryItemId = "47000000-0000-4000-8000-000000000001";
const reportId = "87000000-0000-4000-8000-000000000001";
const entryId = "97000000-0000-4000-8000-000000000001";

const calls: Array<{ name: string; input: unknown }> = [];
let mode:
  | "empty"
  | "single_populated"
  | "range_populated"
  | "conflict"
  | "access"
  | "input_error"
  | "db_error" = "empty";

function mockSingleDailyInventory(businessDate = "2026-09-12", revision = 0) {
  return {
    report_id: revision > 0 ? reportId : null,
    organization_id: org,
    branch_id: branch,
    business_date: businessDate,
    current_business_date: "2026-09-12",
    revision,
    created_at: revision > 0 ? "2026-09-12T08:00:00.000Z" : null,
    updated_at: revision > 0 ? "2026-09-12T08:00:00.000Z" : null,
    entries:
      revision > 0
        ? [
            {
              id: entryId,
              inventory_item_id: inventoryItemId,
              inventory_item_name_snapshot: "Beef Patty",
              inventory_item_unit_snapshot: "pcs",
              manual_opening_quantity: null,
              opening_quantity: 10,
              is_opening_manual: false,
              receiving_quantity: 5,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
              actual_closing_quantity: 15,
              created_at: "2026-09-12T08:00:00.000Z",
              updated_at: "2026-09-12T08:00:00.000Z",
            },
          ]
        : [],
  };
}

function mockRangeDailyInventory(startDate = "2026-09-01", endDate = "2026-09-12") {
  const single = mockSingleDailyInventory(endDate, 1);
  const { current_business_date, ...reportWithoutCurrentDate } = single;
  return {
    organization_id: org,
    branch_id: branch,
    start_date: startDate,
    end_date: endDate,
    current_business_date: "2026-09-12",
    reports: [reportWithoutCurrentDate],
  };
}

function mockSavedDailyInventory(input: SaveBranchDailyInventoryInput) {
  const rev = input.expectedRevision + 1;
  return {
    report_id: reportId,
    organization_id: org,
    branch_id: input.branchId,
    business_date: input.businessDate,
    current_business_date: "2026-09-12",
    revision: rev,
    created_at: "2026-09-12T08:00:00.000Z",
    updated_at: "2026-09-12T08:00:00.000Z",
    entries: input.entries.map((e, idx) => ({
      id: `97000000-0000-4000-8000-00000000000${idx + 1}`,
      inventory_item_id: e.inventory_item_id,
      inventory_item_name_snapshot: "Item Name",
      inventory_item_unit_snapshot: "pcs",
      manual_opening_quantity: e.manual_opening_quantity,
      opening_quantity: e.manual_opening_quantity ?? 10,
      is_opening_manual: e.manual_opening_quantity !== null,
      receiving_quantity: e.receiving_quantity,
      transfer_in_quantity: e.transfer_in_quantity,
      transfer_out_quantity: e.transfer_out_quantity,
      actual_closing_quantity: e.actual_closing_quantity,
      created_at: "2026-09-12T08:00:00.000Z",
      updated_at: "2026-09-12T08:00:00.000Z",
    })),
  };
}

const persistence = {
  async getBranchDailyInventory(input: GetBranchDailyInventoryInput) {
    calls.push({ name: "getBranchDailyInventory", input });
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "input_error") throw new ChecklistInputError();
    if (mode === "db_error") throw new Error("fatal: table corrupt raw postgres details");
    if (input.businessDate) {
      return mode === "single_populated"
        ? mockSingleDailyInventory(input.businessDate, 1)
        : mockSingleDailyInventory(input.businessDate, 0);
    }
    if (input.startDate && input.endDate) {
      return mode === "range_populated"
        ? mockRangeDailyInventory(input.startDate, input.endDate)
        : {
            organization_id: org,
            branch_id: input.branchId,
            start_date: input.startDate,
            end_date: input.endDate,
            current_business_date: "2026-09-12",
            reports: [],
          };
    }
    throw new ChecklistInputError();
  },
  async saveBranchDailyInventory(input: SaveBranchDailyInventoryInput) {
    calls.push({ name: "saveBranchDailyInventory", input });
    if (mode === "conflict") throw new ChecklistConflictError();
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "input_error") throw new ChecklistInputError();
    if (mode === "db_error") throw new Error("fatal: relation does not exist raw postgres error");
    return mockSavedDailyInventory(input);
  },
} as unknown as BackendDependencies["checklistPersistence"];

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
              : null,
    },
    createUserContext: (token) => ({
      getUserContext: async () =>
        token === "supervisor"
          ? {
              id: supervisor,
              full_name: "Supervisor",
              must_change_password: false,
              disabled: false,
              branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }],
              managed_organizations: [],
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
  supabase: { url: "http://127.0.0.1:54321", publishableKey: "anon", secretKey: "service" },
  evidence: { bucket: "evidence", uploadTtlSeconds: 300, downloadTtlSeconds: 300 },
  branding: { bucket: "branding", logoMaxBytes: 1048576, allowedMimeTypes: ["image/png"] },
  serviceAuthSecret: "test-secret-min-32-chars-long-123456",
  securityAuditWebhookUrl: null,
};

describe("Supervisor Daily Inventory API", () => {
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

  // ==========================================
  // GET TESTS
  // ==========================================

  // 1. single-date success
  it("GET 1: single-date success", async () => {
    mode = "single_populated";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?business_date=2026-09-12`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Cache-Control"), "private, no-store");
    const body = await res.json();
    assert.equal(body.branch_id, branch);
    assert.equal(body.business_date, "2026-09-12");
    assert.equal(body.revision, 1);
    assert.equal(body.entries.length, 1);
    assert.equal(body.entries[0].inventory_item_id, inventoryItemId);
    assert.equal(body.entries[0].receiving_quantity, 5);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], {
      name: "getBranchDailyInventory",
      input: {
        actorUserId: supervisor,
        branchId: branch,
        businessDate: "2026-09-12",
      },
    });
  });

  // 2. range success
  it("GET 2: range success", async () => {
    mode = "range_populated";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?start_date=2026-09-01&end_date=2026-09-12`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Cache-Control"), "private, no-store");
    const body = await res.json();
    assert.equal(body.branch_id, branch);
    assert.equal(body.start_date, "2026-09-01");
    assert.equal(body.end_date, "2026-09-12");
    assert.equal(Array.isArray(body.reports), true);
    assert.equal(body.reports.length, 1);
    assert.deepEqual(calls[0], {
      name: "getBranchDailyInventory",
      input: {
        actorUserId: supervisor,
        branchId: branch,
        startDate: "2026-09-01",
        endDate: "2026-09-12",
      },
    });
  });

  // 3. no date params rejected
  it("GET 3: no date params rejected", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 4. mixed single/range params rejected
  it("GET 4: mixed single/range params rejected", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?business_date=2026-09-12&start_date=2026-09-01&end_date=2026-09-12`,
      "supervisor",
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 5. incomplete range rejected
  it("GET 5: incomplete range rejected", async () => {
    const res1 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?start_date=2026-09-01`,
      "supervisor",
    );
    assert.equal(res1.status, 400);

    const res2 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?end_date=2026-09-12`,
      "supervisor",
    );
    assert.equal(res2.status, 400);
    assert.equal(calls.length, 0);
  });

  // 6. malformed dates rejected
  it("GET 6: malformed dates rejected", async () => {
    const res1 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?business_date=not-a-date`,
      "supervisor",
    );
    assert.equal(res1.status, 400);

    const res2 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?start_date=2026-09-15&end_date=2026-09-01`,
      "supervisor",
    );
    assert.equal(res2.status, 400);
    assert.equal(calls.length, 0);
  });

  // 7. access denied mapped correctly
  it("GET 7: access denied mapped correctly", async () => {
    // Unauthenticated -> 401
    const resUnauth = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?business_date=2026-09-12`,
      null,
    );
    assert.equal(resUnauth.status, 401);

    // Non-supervisor/unauthorized branch -> 403
    const resOther = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?business_date=2026-09-12`,
      "other",
    );
    assert.equal(resOther.status, 403);

    // Persistence throws ChecklistAccessError -> 403
    mode = "access";
    const resAccess = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory?business_date=2026-09-12`,
      "supervisor",
    );
    assert.equal(resAccess.status, 403);
    const body = await resAccess.json();
    assert.equal(body.error.code, "forbidden");
  });

  // ==========================================
  // PATCH TESTS
  // ==========================================

  // 8. create with expected_revision=0
  it("PATCH 8: create with expected_revision=0", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              manual_opening_quantity: 100,
              receiving_quantity: 20,
              transfer_in_quantity: 5,
              transfer_out_quantity: 2,
              actual_closing_quantity: 110,
            },
          ],
        }),
      },
    );
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Cache-Control"), "private, no-store");
    const body = await res.json();
    assert.equal(body.revision, 1);
    assert.equal(body.business_date, "2026-09-12");
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], {
      name: "saveBranchDailyInventory",
      input: {
        actorUserId: supervisor,
        branchId: branch,
        businessDate: "2026-09-12",
        expectedRevision: 0,
        entries: [
          {
            inventory_item_id: inventoryItemId,
            manual_opening_quantity: 100,
            receiving_quantity: 20,
            transfer_in_quantity: 5,
            transfer_out_quantity: 2,
            actual_closing_quantity: 110,
          },
        ],
      },
    });
  });

  // 9. update existing revision
  it("PATCH 9: update existing revision", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 1,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              receiving_quantity: 25,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
            },
          ],
        }),
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.revision, 2);
    assert.deepEqual(calls[0].input, {
      actorUserId: supervisor,
      branchId: branch,
      businessDate: "2026-09-12",
      expectedRevision: 1,
      entries: [
        {
          inventory_item_id: inventoryItemId,
          manual_opening_quantity: null,
          receiving_quantity: 25,
          transfer_in_quantity: 0,
          transfer_out_quantity: 0,
          actual_closing_quantity: null,
        },
      ],
    });
  });

  // 10. revision conflict -> 409
  it("PATCH 10: revision conflict -> 409", async () => {
    mode = "conflict";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [],
        }),
      },
    );
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.equal(body.error.code, "conflict");
  });

  // 11. duplicate inventory_item_id rejected
  it("PATCH 11: duplicate inventory_item_id rejected", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              receiving_quantity: 1,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
            },
            {
              inventory_item_id: inventoryItemId,
              receiving_quantity: 2,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
            },
          ],
        }),
      },
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 12. negative quantity rejected
  it("PATCH 12: negative quantity rejected", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              receiving_quantity: -5,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
            },
          ],
        }),
      },
    );
    assert.equal(res.status, 400);
    assert.equal(calls.length, 0);
  });

  // 13. malformed UUID rejected
  it("PATCH 13: malformed UUID rejected", async () => {
    const res1 = await request(
      `/api/v1/supervisor/branches/not-a-uuid/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [],
        }),
      },
    );
    assert.equal(res1.status, 400);

    const res2 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [
            {
              inventory_item_id: "invalid-uuid",
              receiving_quantity: 0,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
            },
          ],
        }),
      },
    );
    assert.equal(res2.status, 400);
    assert.equal(calls.length, 0);
  });

  // 14. nullable actual_closing accepted
  it("PATCH 14: nullable actual_closing accepted", async () => {
    // null value
    const res1 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              receiving_quantity: 10,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
              actual_closing_quantity: null,
            },
          ],
        }),
      },
    );
    assert.equal(res1.status, 200);
    const body1 = await res1.json();
    assert.equal(body1.entries[0].actual_closing_quantity, null);

    // non-null value
    const res2 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 1,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              receiving_quantity: 10,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
              actual_closing_quantity: 35.5,
            },
          ],
        }),
      },
    );
    assert.equal(res2.status, 200);
    const body2 = await res2.json();
    assert.equal(body2.entries[0].actual_closing_quantity, 35.5);
  });

  // 15. nullable manual_opening accepted
  it("PATCH 15: nullable manual_opening accepted", async () => {
    // omitted / null
    const res1 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              receiving_quantity: 5,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
            },
          ],
        }),
      },
    );
    assert.equal(res1.status, 200);
    const body1 = await res1.json();
    assert.equal(body1.entries[0].manual_opening_quantity, null);

    // explicit number
    const res2 = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 1,
          entries: [
            {
              inventory_item_id: inventoryItemId,
              manual_opening_quantity: 50,
              receiving_quantity: 5,
              transfer_in_quantity: 0,
              transfer_out_quantity: 0,
            },
          ],
        }),
      },
    );
    assert.equal(res2.status, 200);
    const body2 = await res2.json();
    assert.equal(body2.entries[0].manual_opening_quantity, 50);
  });

  // 16. DB business-rule error mapped generically/safely
  it("PATCH 16: DB business-rule error mapped generically/safely", async () => {
    mode = "input_error";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [],
        }),
      },
    );
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.equal(body.error.code, "unprocessable_entity");
    assert.equal(
      body.error.message,
      "The daily inventory request is invalid or violates a business rule.",
    );
  });

  // 17. raw DB error content not leaked
  it("PATCH 17: raw DB error content not leaked", async () => {
    mode = "db_error";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [],
        }),
      },
    );
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.error.code, "service_unavailable");
    const jsonStr = JSON.stringify(body);
    assert.equal(jsonStr.includes("postgres"), false);
    assert.equal(jsonStr.includes("relation"), false);
    assert.equal(jsonStr.includes("corrupt"), false);
  });

  // ==========================================
  // PERSISTENCE WRAPPER TESTS
  // ==========================================

  // 18. single-date RPC signature
  it("WRAPPER 18: single-date RPC signature", async () => {
    let capturedRpcName = "";
    let capturedRpcArgs: Record<string, unknown> = {};

    const rpcServer = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        capturedRpcName = req.url?.replace("/rest/v1/rpc/", "") ?? "";
        capturedRpcArgs = body ? JSON.parse(body) : {};
        res.statusCode = 200;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(mockSingleDailyInventory("2026-09-12", 1)));
      });
    });
    await new Promise<void>((resolve, reject) => rpcServer.listen(0, "127.0.0.1", () => resolve()).once("error", reject));
    const rpcOrigin = `http://127.0.0.1:${(rpcServer.address() as AddressInfo).port}`;
    const realPersistence = createChecklistPersistence(rpcOrigin, "secret");

    try {
      const result = await realPersistence.getBranchDailyInventory?.({
        actorUserId: supervisor,
        branchId: branch,
        businessDate: "2026-09-12",
      });
      assert.equal(capturedRpcName, "get_branch_daily_inventory");
      assert.deepEqual(capturedRpcArgs, {
        actor_user_id: supervisor,
        target_branch_id: branch,
        target_business_date: "2026-09-12",
      });
      assert.ok(result);
    } finally {
      await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
    }
  });

  // 19. range RPC signature
  it("WRAPPER 19: range RPC signature", async () => {
    let capturedRpcName = "";
    let capturedRpcArgs: Record<string, unknown> = {};

    const rpcServer = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        capturedRpcName = req.url?.replace("/rest/v1/rpc/", "") ?? "";
        capturedRpcArgs = body ? JSON.parse(body) : {};
        res.statusCode = 200;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(mockRangeDailyInventory("2026-09-01", "2026-09-12")));
      });
    });
    await new Promise<void>((resolve, reject) => rpcServer.listen(0, "127.0.0.1", () => resolve()).once("error", reject));
    const rpcOrigin = `http://127.0.0.1:${(rpcServer.address() as AddressInfo).port}`;
    const realPersistence = createChecklistPersistence(rpcOrigin, "secret");

    try {
      const result = await realPersistence.getBranchDailyInventory?.({
        actorUserId: supervisor,
        branchId: branch,
        startDate: "2026-09-01",
        endDate: "2026-09-12",
      });
      assert.equal(capturedRpcName, "get_branch_daily_inventory");
      assert.deepEqual(capturedRpcArgs, {
        actor_user_id: supervisor,
        target_branch_id: branch,
        start_date: "2026-09-01",
        end_date: "2026-09-12",
      });
      assert.ok(result);

      // Verify mixed params throw ChecklistInputError
      await assert.rejects(
        async () => {
          await realPersistence.getBranchDailyInventory?.({
            actorUserId: supervisor,
            branchId: branch,
            businessDate: "2026-09-12",
            startDate: "2026-09-01",
          });
        },
        ChecklistInputError,
      );
    } finally {
      await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
    }
  });

  // 20. save RPC signature / params
  it("WRAPPER 20: save RPC signature / params", async () => {
    let capturedRpcName = "";
    let capturedRpcArgs: Record<string, unknown> = {};

    const rpcServer = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        capturedRpcName = req.url?.replace("/rest/v1/rpc/", "") ?? "";
        capturedRpcArgs = body ? JSON.parse(body) : {};
        res.statusCode = 200;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(mockSingleDailyInventory("2026-09-12", 1)));
      });
    });
    await new Promise<void>((resolve, reject) => rpcServer.listen(0, "127.0.0.1", () => resolve()).once("error", reject));
    const rpcOrigin = `http://127.0.0.1:${(rpcServer.address() as AddressInfo).port}`;
    const realPersistence = createChecklistPersistence(rpcOrigin, "secret");

    try {
      const entries = [
        {
          inventory_item_id: inventoryItemId,
          manual_opening_quantity: 10,
          receiving_quantity: 5,
          transfer_in_quantity: 0,
          transfer_out_quantity: 0,
          actual_closing_quantity: 15,
        },
      ];
      await realPersistence.saveBranchDailyInventory?.({
        actorUserId: supervisor,
        branchId: branch,
        businessDate: "2026-09-12",
        expectedRevision: 0,
        entries,
      });
      assert.equal(capturedRpcName, "save_branch_daily_inventory");
      assert.deepEqual(capturedRpcArgs, {
        actor_user_id: supervisor,
        target_branch_id: branch,
        target_business_date: "2026-09-12",
        expected_revision: 0,
        entries,
      });
    } finally {
      await new Promise<void>((resolve) => rpcServer.close(() => resolve()));
    }
  });

  // 21. actor identity comes from backend auth context, not request body
  it("SECURITY 21: actor identity comes from backend auth context, not request body", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          actor_user_id: "00000000-0000-0000-0000-000000000000",
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [],
        }),
      },
    );
    // Because dailyInventoryBodySchema is strict, passing actor_user_id in body causes 400 Bad Request
    assert.equal(res.status, 400);
    assert.equal(calls.length, 0);

    // When valid body without actor_user_id is passed, persistence receives the verified auth context actorUserId
    const resValid = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/daily-inventory`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-12",
          expected_revision: 0,
          entries: [],
        }),
      },
    );
    assert.equal(resValid.status, 200);
    assert.equal(calls.length, 1);
    assert.equal((calls[0].input as { actorUserId: string }).actorUserId, supervisor);
  });
});
