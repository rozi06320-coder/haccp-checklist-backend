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
  type SaveBranchProductSalesInput,
} from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const other = "17000000-0000-4000-8000-000000000003";
const branch = "27000000-0000-4000-8000-000000000001";
const otherBranch = "27000000-0000-4000-8000-000000000002";
const org = "37000000-0000-4000-8000-000000000001";
const productId = "47000000-0000-4000-8000-000000000001";
const productId2 = "47000000-0000-4000-8000-000000000002";
const reportId = "87000000-0000-4000-8000-000000000001";
const saleId = "97000000-0000-4000-8000-000000000001";
const usageSnapshotId = "a7000000-0000-4000-8000-000000000001";
const ingredientId = "57000000-0000-4000-8000-000000000001";
const recipeMappingId = "67000000-0000-4000-8000-000000000001";

const calls: Array<{ name: string; input: unknown }> = [];
let mode:
  | "empty"
  | "populated"
  | "string_numbers"
  | "conflict"
  | "access"
  | "future_date"
  | "recipe_no_mapping"
  | "db_integrity_error" = "empty";

function emptyProductSales() {
  return {
    report_id: null,
    organization_id: org,
    branch_id: branch,
    business_date: "2026-09-10",
    current_business_date: "2026-09-10",
    revision: 0,
    created_at: null,
    updated_at: null,
    sales: [],
    usage_snapshots: [],
  };
}

function populatedProductSales() {
  const stringNumbers = mode === "string_numbers";
  return {
    report_id: reportId,
    organization_id: org,
    branch_id: branch,
    business_date: "2026-09-10",
    current_business_date: "2026-09-10",
    revision: 1,
    created_at: "2026-09-10T08:00:00.000Z",
    updated_at: "2026-09-10T08:00:00.000Z",
    sales: [
      {
        id: saleId,
        product_id: productId,
        product_name_snapshot: "Smoky Beef",
        inventory_behavior_snapshot: "recipe",
        product_unit_snapshot: null,
        quantity: stringNumbers ? "2.5" : 12,
        created_at: "2026-09-10T08:00:00.000Z",
        updated_at: "2026-09-10T08:00:00.000Z",
      },
    ],
    usage_snapshots: [
      {
        id: usageSnapshotId,
        product_sale_id: saleId,
        product_id: productId,
        product_name_snapshot: "Smoky Beef",
        inventory_behavior_snapshot: "recipe",
        inventory_item_id: ingredientId,
        inventory_item_name_snapshot: "Beef Patty",
        inventory_item_unit_snapshot: "pcs",
        quantity_per_sale_snapshot: stringNumbers ? "2.5" : 1,
        sales_quantity_snapshot: stringNumbers ? "3" : 12,
        total_usage_quantity: stringNumbers ? "7.5" : 12,
        recipe_mapping_id: recipeMappingId,
        created_at: "2026-09-10T08:00:00.000Z",
      },
    ],
  };
}

const persistence = {
  async getBranchProductSales(actorUserId: string, branchId: string, businessDate: string) {
    calls.push({ name: "getBranchProductSales", input: { actorUserId, branchId, businessDate } });
    if (mode === "access" || branchId !== branch) throw new ChecklistAccessError();
    if (mode === "future_date") throw new ChecklistInputError();
    if (mode === "db_integrity_error") throw new Error("fatal: snapshot corrupt");
    return mode === "populated" || mode === "string_numbers" ? populatedProductSales() : emptyProductSales();
  },
  async saveBranchProductSales(input: SaveBranchProductSalesInput) {
    calls.push({ name: "saveBranchProductSales", input });
    if (mode === "conflict") throw new ChecklistConflictError();
    if (mode === "access" || input.branchId !== branch) throw new ChecklistAccessError();
    if (mode === "future_date" || mode === "recipe_no_mapping") throw new ChecklistInputError();
    if (mode === "db_integrity_error") throw new Error("fatal: transaction aborted");
    mode = "populated";
    return populatedProductSales();
  },
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
  port: 1,
  trustProxy: false,
  supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" },
  dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests",
};

let server: Server;
let origin: string;

async function request(path: string, token?: string, init: RequestInit = {}) {
  return fetch(origin + path, {
    ...init,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : { "x-no-auth": "1" }),
      ...(init.headers ?? {}),
    },
  });
}

describe("Supervisor Product Sales API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(() => new Promise<void>((resolve) => server.close(() => resolve())));

  beforeEach(() => {
    calls.length = 0;
    mode = "empty";
  });

  // 1. GET validates branch ID
  it("GET validates branch ID", async () => {
    const res = await request(
      "/api/v1/supervisor/branches/not-a-uuid/inventory/product-sales?business_date=2026-09-10",
      "supervisor",
    );
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error.code, "bad_request");
    assert.equal(calls.length, 0);
  });

  // 2. GET validates business_date
  it("GET validates business_date strictly as YYYY-MM-DD", async () => {
    // Missing business_date
    const resMissing = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
    );
    assert.equal(resMissing.status, 400);

    // Malformed format
    const resInvalid = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-9-1`,
      "supervisor",
    );
    assert.equal(resInvalid.status, 400);

    // Non-date string
    const resNotDate = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=invalid-date`,
      "supervisor",
    );
    assert.equal(resNotDate.status, 400);
    assert.equal(calls.length, 0);
  });

  // 3. GET invokes exact RPC params
  it("GET invokes exact RPC params", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], {
      name: "getBranchProductSales",
      input: {
        actorUserId: supervisor,
        branchId: branch,
        businessDate: "2026-09-10",
      },
    });
  });

  // 4. GET returns revision 0 empty state correctly
  it("GET returns revision 0 empty state correctly without creating rows", async () => {
    mode = "empty";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.report_id, null);
    assert.equal(body.revision, 0);
    assert.equal(body.business_date, "2026-09-10");
    assert.deepEqual(body.sales, []);
    assert.deepEqual(body.usage_snapshots, []);
  });

  // 5. GET returns persisted sales + frozen usage
  it("GET returns persisted sales + frozen usage snapshots", async () => {
    mode = "populated";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.report_id, reportId);
    assert.equal(body.revision, 1);
    assert.equal(body.sales.length, 1);
    assert.equal(body.sales[0].product_id, productId);
    assert.equal(body.sales[0].quantity, 12);
    assert.equal(body.usage_snapshots.length, 1);
    assert.equal(body.usage_snapshots[0].inventory_item_id, ingredientId);
    assert.equal(body.usage_snapshots[0].total_usage_quantity, 12);
  });

  // 6. PATCH validates expected_revision
  it("PATCH validates expected_revision integer >= 0", async () => {
    const resNeg = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: -1,
          sales: [],
        }),
      },
    );
    assert.equal(resNeg.status, 400);

    const resFloat = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 1.5,
          sales: [],
        }),
      },
    );
    assert.equal(resFloat.status, 400);

    const resMissing = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          sales: [],
        }),
      },
    );
    assert.equal(resMissing.status, 400);
  });

  // 7. validates product IDs
  it("validates each product_id as UUID", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: "not-a-uuid", quantity: 5 }],
        }),
      },
    );
    assert.equal(res.status, 400);
  });

  // 8. rejects negative quantity
  it("rejects negative quantity", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: -1 }],
        }),
      },
    );
    assert.equal(res.status, 400);
  });

  // 9. rejects duplicate product IDs
  it("rejects duplicate product IDs in request before RPC", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [
            { product_id: productId, quantity: 5 },
            { product_id: productId, quantity: 10 },
          ],
        }),
      },
    );
    assert.equal(res.status, 400);
    assert.equal(calls.length, 0);
  });

  // 10. does not accept trusted snapshot/ingredient fields
  it("does not accept trusted snapshot/ingredient fields from client", async () => {
    // Attempting to send usage_snapshots or ingredient calculation
    const resWithUsage = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [
            {
              product_id: productId,
              quantity: 5,
              total_usage_quantity: 5,
            },
          ],
        }),
      },
    );
    assert.equal(resWithUsage.status, 400);

    // Attempting to send top-level usage snapshots or recipe rows
    const resWithTopLevel = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 5 }],
          recipe_rows: [{ ingredient: "Beef", quantity: 1 }],
        }),
      },
    );
    assert.equal(resWithTopLevel.status, 400);
    assert.equal(calls.length, 0);
  });

  // 11. invokes exact save RPC params
  it("invokes exact save RPC params for PATCH", async () => {
    const payload = {
      business_date: "2026-09-10",
      expected_revision: 0,
      sales: [
        { product_id: productId, quantity: 12 },
        { product_id: productId2, quantity: 0 },
      ],
    };
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      },
    );
    assert.equal(res.status, 200);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], {
      name: "saveBranchProductSales",
      input: {
        actorUserId: supervisor,
        branchId: branch,
        businessDate: "2026-09-10",
        expectedRevision: 0,
        sales: [
          { product_id: productId, quantity: 12 },
          { product_id: productId2, quantity: 0 },
        ],
      },
    });
  });

  it("does not register PUT for product sales", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(res.status, 404);
    assert.equal(calls.length, 0);
  });

  // 12. stale revision maps to 409
  it("stale revision maps to 409 Conflict", async () => {
    mode = "conflict";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.equal(body.error.code, "conflict");
    assert.equal(body.error.message, "Product sales data has been modified by another request.");
  });

  // 13. branch authorization failure maps safely
  it("branch authorization failure maps safely to 403 Forbidden", async () => {
    // Cross-branch access denied
    const resOtherBranch = await request(
      `/api/v1/supervisor/branches/${otherBranch}/inventory/product-sales?business_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(resOtherBranch.status, 403);

    // Persistence access error
    mode = "access";
    const resAccess = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(resAccess.status, 403);
    const body = await resAccess.json();
    assert.equal(body.error.code, "forbidden");
    assert.equal(body.error.message, "Access is denied.");
  });

  // 14. future date error maps safely
  it("future business date error maps safely to 422 Unprocessable Entity", async () => {
    mode = "future_date";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-15",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.equal(body.error.code, "unprocessable_entity");
    assert.equal(body.error.message, "The product sales request is invalid or violates a business rule.");
  });

  // 15. recipe-without-mapping error maps safely
  it("recipe-without-mapping error maps safely to 422 Unprocessable Entity", async () => {
    mode = "recipe_no_mapping";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.equal(body.error.code, "unprocessable_entity");
    assert.equal(body.error.message, "The product sales request is invalid or violates a business rule.");
  });

  // 16. database integrity error does not leak raw backend details
  it("database integrity error does not leak raw backend details", async () => {
    mode = "db_integrity_error";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.error.code, "service_unavailable");
    assert.equal(body.error.message, "The service is unavailable.");
    assert.equal(JSON.stringify(body).includes("fatal: transaction aborted"), false);
    assert.equal(JSON.stringify(body).includes("corrupt"), false);
  });

  // 17. manager mutation remains rejected
  it("manager mutation remains rejected with 403 Forbidden", async () => {
    // GET by manager
    const resGet = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-09-10`,
      "manager",
    );
    assert.equal(resGet.status, 403);

    // PATCH by manager
    const resPatch = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "manager",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(resPatch.status, 403);

    assert.equal(calls.length, 0);
  });

  it("allows target-branch supervisors who also manage other organizations", async () => {
    const resGet = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-09-10`,
      "dual",
    );
    assert.equal(resGet.status, 200);

    const resPatch = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "dual",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(resPatch.status, 200);
    assert.deepEqual(calls.map((call) => call.name), ["getBranchProductSales", "saveBranchProductSales"]);
  });

  it("normalizes product sales response quantities to JSON numbers", async () => {
    mode = "string_numbers";
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-09-10`,
      "supervisor",
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(typeof body.sales[0].quantity, "number");
    assert.equal(body.sales[0].quantity, 2.5);
    assert.equal(typeof body.usage_snapshots[0].quantity_per_sale_snapshot, "number");
    assert.equal(body.usage_snapshots[0].quantity_per_sale_snapshot, 2.5);
    assert.equal(typeof body.usage_snapshots[0].sales_quantity_snapshot, "number");
    assert.equal(body.usage_snapshots[0].sales_quantity_snapshot, 3);
    assert.equal(typeof body.usage_snapshots[0].total_usage_quantity, "number");
    assert.equal(body.usage_snapshots[0].total_usage_quantity, 7.5);
  });

  it("maps product sales SQLSTATE classes without leaking raw database details", async () => {
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
      const originalGet = persistence.getBranchProductSales;
      persistence.getBranchProductSales = async () => {
        throw errorFactory();
      };
      try {
        const res = await request(
          `/api/v1/supervisor/branches/${branch}/inventory/product-sales?business_date=2026-09-10`,
          "supervisor",
        );
        assert.equal(res.status, status, sqlstate);
        const body = await res.json();
        assert.equal(body.error.code, code, sqlstate);
        assert.equal(JSON.stringify(body).includes(sqlstate), false, sqlstate);
        assert.equal(JSON.stringify(body).includes("postgres"), false, sqlstate);
        assert.equal(JSON.stringify(body).includes("constraint"), false, sqlstate);
      } finally {
        persistence.getBranchProductSales = originalGet;
      }
    }
  });

  it("translates Product Sales RPC SQLSTATEs narrowly in persistence", async () => {
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
          () => realPersistence.getBranchProductSales?.(supervisor, branch, "2026-09-10"),
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

  // 18. Product Sales path does not add waste/transfer/closing behavior
  it("Product Sales path does not add waste/transfer/closing behavior", async () => {
    const res = await request(
      `/api/v1/supervisor/branches/${branch}/inventory/product-sales`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          business_date: "2026-09-10",
          expected_revision: 0,
          sales: [{ product_id: productId, quantity: 12 }],
        }),
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();

    // Verify response schema strictly contains only product sales & usage snapshots, no inventory operations
    const keys = Object.keys(body);
    assert.deepEqual(keys.sort(), [
      "branch_id",
      "business_date",
      "created_at",
      "current_business_date",
      "organization_id",
      "report_id",
      "revision",
      "sales",
      "updated_at",
      "usage_snapshots",
    ].sort());

    assert.equal("daily_waste" in body, false);
    assert.equal("transfers" in body, false);
    assert.equal("transfer_in" in body, false);
    assert.equal("transfer_out" in body, false);
    assert.equal("actual_closing" in body, false);
    assert.equal("variance" in body, false);

    // Verify calls made on persistence are only saveBranchProductSales
    assert.equal(calls.length, 1);
    assert.equal(calls[0].name, "saveBranchProductSales");
  });
});
