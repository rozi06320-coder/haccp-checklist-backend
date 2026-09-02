import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { createOperationalAdmin } from "./operational";

const ids = {
  maintenanceUser: "a1000000-0000-4000-8000-000000000003",
  organization: "b1000000-0000-4000-8000-000000000001",
  branch: "c1000000-0000-4000-8000-000000000001",
  issue: "d1000000-0000-4000-8000-000000000001",
  purchase: "f1000000-0000-4000-8000-000000000001",
  attachment: "e1000000-0000-4000-8000-000000000001",
} as const;

const rpcPurchase = {
  id: ids.purchase,
  organization_id: ids.organization,
  branch_id: ids.branch,
  branch_name: "Main Branch",
  maintenance_issue_id: ids.issue,
  purchase_type: "issue",
  issue_title: "Freezer door",
  issue_category: "refrigeration",
  issue_status: "new",
  responsible_person_name: "Maintenance technician",
  purchase_scope: "branch",
  destination: null,
  category: "spare_parts",
  maintenance_user_id: ids.maintenanceUser,
  maintenance_user_name: "Maintenance User",
  item_name: "Replacement seal",
  quantity: "2",
  unit: "meter",
  amount: "35.50",
  vendor_name: "Parts Shop",
  purchase_date: "2026-09-02",
  notes: "Urgent",
  payment_status: "unpaid",
  payment_method: "cash",
  reimbursement_note: null,
  reimbursed_at: null,
  reimbursed_by: null,
  receipt_storage_path: "maintenance/private/purchase/receipt.pdf",
  receipt_original_name: "receipt.pdf",
  attachments: [{
    id: ids.attachment,
    storage_path: "maintenance/private/purchase/receipt.pdf",
    original_filename: "receipt.pdf",
    mime_type: "application/pdf",
    size_bytes: "1200",
    position: 1,
  }],
  created_at: "2026-09-02T10:00:00.000Z",
  updated_at: "2026-09-02T10:00:00.000Z",
} as const;

async function readJsonBody(request: IncomingMessage) {
  let raw = "";
  for await (const chunk of request) raw += chunk;
  return raw ? JSON.parse(raw) as Record<string, unknown> : {};
}

function writeJson(response: ServerResponse, body: unknown, statusCode = 200) {
  response.statusCode = statusCode;
  response.setHeader("Content-Type", "application/json");
  response.end(JSON.stringify(body));
}

describe("Maintenance Purchase History public response boundary", () => {
  let supabaseServer: Server;
  let apiServer: Server;
  let apiOrigin: string;
  let admin: ReturnType<typeof createOperationalAdmin>;
  const rpcRequests: Array<{ path: string; body: Record<string, unknown> }> = [];

  before(async () => {
    supabaseServer = createServer(async (request, response) => {
      const path = request.url ?? "";
      if (path === "/rest/v1/rpc/get_maintenance_purchase_history_page") {
        const body = await readJsonBody(request);
        rpcRequests.push({ path, body });
        const page = Number(body.requested_page);
        writeJson(response, page === 2
          ? { maintenance_purchases: [], page: 2, page_size: 100, total_count: 1, has_more: false }
          : { maintenance_purchases: [rpcPurchase], page: 1, page_size: 100, total_count: "1", has_more: false });
        return;
      }
      if (path.startsWith("/storage/v1/object/sign/maintenance-purchase-receipts/")) {
        writeJson(response, { signedURL: "/object/sign/maintenance-purchase-receipts/receipt.pdf?token=test" });
        return;
      }
      writeJson(response, { message: "not found" }, 404);
    });
    await new Promise<void>((resolve, reject) => supabaseServer.listen(0, "127.0.0.1", resolve).once("error", reject));
    const supabaseOrigin = `http://127.0.0.1:${(supabaseServer.address() as AddressInfo).port}`;
    admin = createOperationalAdmin(supabaseOrigin, "service-key");

    const config: BackendConfig = {
      nodeEnv: "test",
      host: "127.0.0.1",
      port: 1,
      trustProxy: false,
      supabase: { url: supabaseOrigin, publishableKey: "test", secretKey: "service-key" },
      dailyAuditGrantSecret: "test-daily-audit-grant-secret-placeholder-32-bytes",
    };
    const dependencies = {
      checkReadiness: async () => true,
      passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
      provisioningAdmin: { createUser: async () => ({ id: "unused" }), deleteUser: async () => {}, finalize: async () => {} },
      managementAdmin: { listUsers: async () => ({ users: [], total: 0 }) },
      branchManagementAdmin: { listBranches: async () => [], listStaff: async () => [], getPinMetadata: async () => ({ configured: false, updated_at: null, updated_by_name: null }), storePin: async () => ({ configured: true, updated_at: null, updated_by_name: null }), getPinCredential: async () => null },
      pinCrypto: { hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }), verify: async () => false, issueGrant: () => "", verifyGrant: () => false },
      authVerifier: { verify: async (token: string) => token === "maintenance" ? { userId: ids.maintenanceUser, email: "maintenance@example.invalid" } : null },
      createUserContext: () => ({
        getUserContext: async () => ({ id: ids.maintenanceUser, full_name: "Maintenance User", must_change_password: false, disabled: false, branches: [], managed_organizations: [] }),
        hasOrganizationManagerAccess: async () => false,
        validateActiveBranches: async () => false,
        listActiveBranches: async () => [],
      }),
      operationalAdmin: admin,
    } as unknown as BackendDependencies;
    apiServer = createServer(createApp(config, dependencies));
    await new Promise<void>((resolve, reject) => apiServer.listen(0, "127.0.0.1", resolve).once("error", reject));
    apiOrigin = `http://127.0.0.1:${(apiServer.address() as AddressInfo).port}`;
  });

  after(async () => {
    await Promise.all([
      new Promise<void>((resolve, reject) => apiServer.close((error) => error ? reject(error) : resolve())),
      new Promise<void>((resolve, reject) => supabaseServer.close((error) => error ? reject(error) : resolve())),
    ]);
  });

  it("strips internal RPC fields while preserving the public paginated row", async () => {
    const result = await admin.listMaintenancePurchaseHistoryPage?.({
      actorUserId: ids.maintenanceUser,
      purchaseType: "all",
      page: 1,
      pageSize: 100,
    }) as { maintenance_purchases: Array<Record<string, unknown>>; page: number; page_size: number; total_count: number; has_more: boolean };
    const purchase = result.maintenance_purchases[0];

    assert.ok(purchase);
    assert.equal("maintenance_user_id" in purchase, false);
    assert.equal("receipt_storage_path" in purchase, false);
    assert.equal(purchase.maintenance_user_name, "Maintenance User");
    assert.equal(purchase.organization_id, ids.organization);
    assert.equal(purchase.branch_name, "Main Branch");
    assert.equal(purchase.issue_title, "Freezer door");
    assert.equal(purchase.payment_method, "cash");
    assert.equal(purchase.reimbursed_by, null);
    assert.match(String(purchase.receipt_url), /\/storage\/v1\/object\/sign\//);
    assert.equal("storage_path" in (purchase.attachments as Array<Record<string, unknown>>)[0], false);
    assert.deepEqual({ page: result.page, page_size: result.page_size, total_count: result.total_count, has_more: result.has_more }, { page: 1, page_size: 100, total_count: 1, has_more: false });
    assert.deepEqual(rpcRequests.at(-1), {
      path: "/rest/v1/rpc/get_maintenance_purchase_history_page",
      body: { actor_user_id: ids.maintenanceUser, purchase_type_filter: "all", requested_page: 1, requested_page_size: 100 },
    });
  });

  it("passes a realistic non-empty normalized page through the strict public route schema", async () => {
    const response = await fetch(`${apiOrigin}/api/v1/maintenance/purchases?purchase_type=all&page=1&page_size=100`, {
      headers: { Authorization: "Bearer maintenance" },
    });
    assert.equal(response.status, 200, await response.clone().text());
    const body = await response.json() as { maintenance_purchases: Array<Record<string, unknown>>; total_count: number };
    assert.equal(body.maintenance_purchases.length, 1);
    assert.equal("maintenance_user_id" in body.maintenance_purchases[0], false);
    assert.equal("receipt_storage_path" in body.maintenance_purchases[0], false);
    assert.equal(body.maintenance_purchases[0]?.maintenance_user_name, "Maintenance User");
    assert.equal(body.total_count, 1);
  });

  it("preserves the empty-page response and its pagination metadata", async () => {
    const response = await fetch(`${apiOrigin}/api/v1/maintenance/purchases?purchase_type=all&page=2&page_size=100`, {
      headers: { Authorization: "Bearer maintenance" },
    });
    assert.equal(response.status, 200, await response.clone().text());
    assert.deepEqual(await response.json(), {
      maintenance_purchases: [],
      page: 2,
      page_size: 100,
      total_count: 1,
      has_more: false,
    });
    assert.equal(rpcRequests.some(({ path }) => path.includes("create_maintenance_purchase")), false);
  });
});
