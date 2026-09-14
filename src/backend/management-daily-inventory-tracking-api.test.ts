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
const itemBread = "c1000000-0000-4000-8000-000000000001";
const itemPatty = "c1000000-0000-4000-8000-000000000002";
const productBurger = "d1000000-0000-4000-8000-000000000001";

const mockReconciliationRow = {
  business_date: "2026-09-02",
  branch_id: branchA,
  branch_name: "Branch Alpha",
  inventory_item_id: itemBread,
  inventory_item_name: "Artisan Brioche Bun",
  inventory_item_unit: "pcs",
  opening_quantity: 15,
  receiving_quantity: 20,
  transfer_in_quantity: 5,
  transfer_out_quantity: 2,
  sales_usage_quantity: 12,
  wastage_quantity: 1,
  expected_closing_quantity: 25, // 15 + 20 + 5 - 2 - 12 - 1 = 25
  actual_closing_quantity: 24,
  variance_quantity: -1, // 24 - 25 = -1 (Short by 1)
  report_revision: 2,
  report_created_at: "2026-09-02T10:00:00.000Z",
  report_updated_at: "2026-09-02T12:30:00.000Z",
  created_by_user_id: supervisor,
};

const mockNullOpeningReconciliationRow = {
  business_date: "2026-09-02",
  branch_id: branchA,
  branch_name: "Branch Alpha",
  inventory_item_id: itemPatty,
  inventory_item_name: "Beef Patty",
  inventory_item_unit: "pcs",
  opening_quantity: null,
  receiving_quantity: 20,
  transfer_in_quantity: 5,
  transfer_out_quantity: 2,
  sales_usage_quantity: 12,
  wastage_quantity: 1,
  expected_closing_quantity: null,
  actual_closing_quantity: 24,
  variance_quantity: null,
  report_revision: 1,
  report_created_at: "2026-09-02T10:00:00.000Z",
  report_updated_at: "2026-09-02T12:30:00.000Z",
  created_by_user_id: supervisor,
};

const mockUsageRow = {
  business_date: "2026-09-02",
  branch_id: branchA,
  branch_name: "Branch Alpha",
  product_id: productBurger,
  product_name_snapshot: "Classic Cheeseburger",
  product_unit_snapshot: "pcs",
  inventory_behavior_snapshot: "recipe" as const,
  inventory_item_id: itemBread,
  inventory_item_name_snapshot: "Artisan Brioche Bun",
  inventory_item_unit_snapshot: "pcs",
  sales_quantity: 12,
  quantity_per_sale_snapshot: 1,
  total_usage_quantity: 12,
  report_revision: 1,
  report_created_at: "2026-09-02T10:00:00.000Z",
  report_updated_at: "2026-09-02T10:00:00.000Z",
};

const mockWasteRow = {
  business_date: "2026-09-02",
  branch_id: branchA,
  branch_name: "Branch Alpha",
  inventory_item_id: itemBread,
  inventory_item_name_snapshot: "Artisan Brioche Bun",
  inventory_item_unit_snapshot: "pcs",
  quantity: 1,
  note: "Dropped during rush",
  report_revision: 1,
  report_created_at: "2026-09-02T11:00:00.000Z",
  report_updated_at: "2026-09-02T11:00:00.000Z",
};

let lastReconQuery: Record<string, unknown> | null = null;
let lastUsageQuery: Record<string, unknown> | null = null;
let lastWasteQuery: Record<string, unknown> | null = null;

const persistence = {
  async listManagedDailyInventoryReconciliation(input: Record<string, unknown>) {
    lastReconQuery = input;
    if (input.actorUserId !== manager || input.organizationId !== organization) throw new ChecklistAccessError();
    if (input.fromDate && input.toDate && String(input.fromDate) > String(input.toDate)) throw new ChecklistInputError();
    const allRows = input.inventoryItemId === itemPatty ? [mockNullOpeningReconciliationRow] : [mockReconciliationRow];
    const page = Number(input.page ?? 1);
    const pageSize = Number(input.pageSize ?? 50);
    const offset = (page - 1) * pageSize;
    const rows = offset >= allRows.length ? [] : allRows.slice(offset, offset + pageSize);
    return {
      rows,
      page,
      page_size: pageSize,
      total_rows: allRows.length,
      total_pages: allRows.length === 0 ? 0 : Math.ceil(allRows.length / pageSize),
      from_date: input.fromDate,
      to_date: input.toDate,
    };
  },
  async listManagedProductSalesUsage(input: Record<string, unknown>) {
    lastUsageQuery = input;
    if (input.actorUserId !== manager || input.organizationId !== organization) throw new ChecklistAccessError();
    return {
      rows: [mockUsageRow],
      page: input.page ?? 1,
      page_size: input.pageSize ?? 50,
      total_rows: 1,
      total_pages: 1,
      from_date: input.fromDate,
      to_date: input.toDate,
    };
  },
  async listManagedDailyWaste(input: Record<string, unknown>) {
    lastWasteQuery = input;
    if (input.actorUserId !== manager || input.organizationId !== organization) throw new ChecklistAccessError();
    return {
      rows: [mockWasteRow],
      page: input.page ?? 1,
      page_size: input.pageSize ?? 50,
      total_rows: 1,
      total_pages: 1,
      from_date: input.fromDate,
      to_date: input.toDate,
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
      verify: async (token) => (token === "manager" ? { userId: manager, email: "manager@example.invalid" } : token === "supervisor" ? { userId: supervisor, email: "supervisor@example.invalid" } : null),
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

describe("Manager Daily Inventory, Usage, and Waste Tracking API", () => {
  before(async () => {
    server = createServer(createApp(config, dependencies()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(() => new Promise<void>((resolve) => server.close(() => resolve())));

  describe("1. Authorization & Tenant Isolation", () => {
    it("1. valid organization Manager can read daily inventory", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02`);
      assert.equal(res.status, 200);
      const data = await res.json();
      assert.equal(data.rows.length, 1);
      assert.equal(data.rows[0].branch_name, "Branch Alpha");
    });

    it("2. non-manager supervisor is denied (403)", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02`, "supervisor");
      assert.equal(res.status, 403);
    });

    it("3. manager cannot read an organization they do not manage (403)", async () => {
      const res = await request(`/api/v1/management/organizations/${otherOrganization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02`);
      assert.equal(res.status, 403);
    });

    it("4. branch filter cannot escape manager organization (403)", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02&branch_id=${externalBranch}`);
      assert.equal(res.status, 403);
    });
  });

  describe("2. Date Range & Pagination Validation", () => {
    it("5. missing date range rejected (400)", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory`);
      assert.equal(res.status, 400);
    });

    it("6. inverted date range rejected (from_date > to_date)", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-10&to_date=2026-09-01`);
      assert.equal(res.status, 400);
    });

    it("7. date range > 90 days rejected", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-01-01&to_date=2026-05-01`);
      assert.equal(res.status, 400);
    });

    it("8. page_size > 100 rejected", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02&page_size=101`);
      assert.equal(res.status, 400);
    });

    it("9. default pagination applied when omitted (page=1, page_size=50)", async () => {
      lastReconQuery = null;
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02`);
      assert.equal(res.status, 200);
      assert.equal(lastReconQuery?.page, 1);
      assert.equal(lastReconQuery?.pageSize, 50);
    });

    it("9b. page beyond last returns empty rows while preserving total_rows and total_pages (page=10, total_rows=1)", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02&page=10&page_size=50`);
      assert.equal(res.status, 200);
      const data = await res.json();
      assert.deepEqual(data.rows, []);
      assert.equal(data.page, 10);
      assert.equal(data.page_size, 50);
      assert.equal(data.total_rows, 1);
      assert.equal(data.total_pages, 1);
    });
  });

  describe("3. Daily Inventory Reconciliation Contract & Semantics", () => {
    it("10. returns item-level reconciliation with exact expected closing and variance", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02`);
      assert.equal(res.status, 200);
      const data = await res.json();
      assert.equal(data.total_rows, 1);
      assert.equal(data.total_pages, 1);

      const row = data.rows[0];
      assert.equal(row.business_date, "2026-09-02");
      assert.equal(row.inventory_item_id, itemBread);
      assert.equal(row.inventory_item_name, "Artisan Brioche Bun");
      assert.equal(row.inventory_item_unit, "pcs");

      // Verify formula components:
      // opening (15) + receiving (20) + transfer_in (5) - transfer_out (2) - sales_usage (12) - wastage (1) = 25
      assert.equal(row.opening_quantity, 15);
      assert.equal(row.receiving_quantity, 20);
      assert.equal(row.transfer_in_quantity, 5);
      assert.equal(row.transfer_out_quantity, 2);
      assert.equal(row.sales_usage_quantity, 12);
      assert.equal(row.wastage_quantity, 1);
      assert.equal(row.expected_closing_quantity, 25);
      assert.equal(row.actual_closing_quantity, 24);
      assert.equal(row.variance_quantity, -1);
      assert.equal(row.report_revision, 2);
    });

    it("10b. null opening quantity yields null expected closing and null variance", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02&inventory_item_id=${itemPatty}`);
      assert.equal(res.status, 200);
      const data = await res.json();
      assert.equal(data.rows.length, 1);

      const row = data.rows[0];
      assert.equal(row.business_date, "2026-09-02");
      assert.equal(row.inventory_item_id, itemPatty);
      assert.equal(row.inventory_item_name, "Beef Patty");
      assert.equal(row.opening_quantity, null);
      assert.equal(row.actual_closing_quantity, 24);
      assert.equal(row.expected_closing_quantity, null);
      assert.equal(row.variance_quantity, null);
    });

    it("11. passes optional branch_id and inventory_item_id to persistence", async () => {
      lastReconQuery = null;
      const res = await request(`/api/v1/management/organizations/${organization}/daily-inventory?from_date=2026-09-01&to_date=2026-09-02&branch_id=${branchA}&inventory_item_id=${itemBread}`);
      assert.equal(res.status, 200);
      assert.equal(lastReconQuery?.branchId, branchA);
      assert.equal(lastReconQuery?.inventoryItemId, itemBread);
    });
  });

  describe("4. Product Sales & Daily Usage Contract", () => {
    it("12. returns historical frozen usage snapshots without live recipe recomputation", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-usage?from_date=2026-09-01&to_date=2026-09-02`);
      assert.equal(res.status, 200);
      const data = await res.json();
      assert.equal(data.rows.length, 1);

      const row = data.rows[0];
      assert.equal(row.business_date, "2026-09-02");
      assert.equal(row.product_id, productBurger);
      assert.equal(row.product_name_snapshot, "Classic Cheeseburger");
      assert.equal(row.inventory_behavior_snapshot, "recipe");
      assert.equal(row.inventory_item_id, itemBread);
      assert.equal(row.inventory_item_name_snapshot, "Artisan Brioche Bun");
      assert.equal(row.sales_quantity, 12);
      assert.equal(row.quantity_per_sale_snapshot, 1);
      assert.equal(row.total_usage_quantity, 12);
    });

    it("13. passes optional filters to daily-usage persistence", async () => {
      lastUsageQuery = null;
      const res = await request(`/api/v1/management/organizations/${organization}/daily-usage?from_date=2026-09-01&to_date=2026-09-02&branch_id=${branchA}&inventory_item_id=${itemBread}`);
      assert.equal(res.status, 200);
      assert.equal(lastUsageQuery?.branchId, branchA);
      assert.equal(lastUsageQuery?.inventoryItemId, itemBread);
    });
  });

  describe("5. Daily Wastage Contract", () => {
    it("14. returns historical wastage entries with item snapshot and note", async () => {
      const res = await request(`/api/v1/management/organizations/${organization}/daily-waste?from_date=2026-09-01&to_date=2026-09-02`);
      assert.equal(res.status, 200);
      const data = await res.json();
      assert.equal(data.rows.length, 1);

      const row = data.rows[0];
      assert.equal(row.business_date, "2026-09-02");
      assert.equal(row.branch_name, "Branch Alpha");
      assert.equal(row.inventory_item_id, itemBread);
      assert.equal(row.inventory_item_name_snapshot, "Artisan Brioche Bun");
      assert.equal(row.inventory_item_unit_snapshot, "pcs");
      assert.equal(row.quantity, 1);
      assert.equal(row.note, "Dropped during rush");
    });

    it("15. passes optional filters to daily-waste persistence", async () => {
      lastWasteQuery = null;
      const res = await request(`/api/v1/management/organizations/${organization}/daily-waste?from_date=2026-09-01&to_date=2026-09-02&branch_id=${branchA}&inventory_item_id=${itemBread}`);
      assert.equal(res.status, 200);
      assert.equal(lastWasteQuery?.branchId, branchA);
      assert.equal(lastWasteQuery?.inventoryItemId, itemBread);
    });
  });
});
