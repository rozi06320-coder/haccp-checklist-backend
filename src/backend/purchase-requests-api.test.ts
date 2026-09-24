import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { OperationalAccessError, OperationalInputError } from "./operational";

const supervisor = "17000000-0000-4000-8000-000000000001";
const purchaser = "17000000-0000-4000-8000-000000000002";
const manager = "17000000-0000-4000-8000-000000000003";
const inactivePurchaser = "17000000-0000-4000-8000-000000000004";
const branch = "27000000-0000-4000-8000-000000000001";
const otherBranch = "27000000-0000-4000-8000-000000000002";
const organization = "37000000-0000-4000-8000-000000000001";
const otherOrganization = "37000000-0000-4000-8000-000000000002";
const requestId = "47000000-0000-4000-8000-000000000001";
const purchaseLogId = "67000000-0000-4000-8000-000000000001";

const config: BackendConfig = { nodeEnv: "test", host: "127.0.0.1", port: 1, trustProxy: false, supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" }, dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests" };
let server: Server;
let origin: string;
const calls: Array<{ name: string; input: unknown }> = [];

const purchaseRequest = {
  id: requestId,
  organization_id: organization,
  branch_id: branch,
  branch_name: "Branch A",
  branch_code: "A",
  requested_by: supervisor,
  requested_by_name: "Supervisor",
  category: "kitchen",
  status: "submitted",
  notes: "Need stock",
  created_at: "2026-09-21T08:00:00.000Z",
  updated_at: "2026-09-21T08:00:00.000Z",
  items: [{ id: "57000000-0000-4000-8000-000000000001", purchase_request_id: requestId, item_name: "Gloves", quantity: "3", unit: "box", notes: null, sort_order: 1, created_at: "2026-09-21T08:00:00.000Z" }],
};
const purchaseLog = {
  id: purchaseLogId,
  branch_id: branch,
  branch_name: "Branch A",
  category: "kitchen",
  item_name: "Oil",
  quantity: "2",
  amount: "115",
  before_tax_amount: "100",
  tax_amount: "15",
  vendor_name: "Food Vendor",
  purchase_date: "2026-09-22",
  notes: null,
  payment_status: "unpaid",
  reimbursement_note: null,
  reimbursed_at: null,
  reimbursed_by: null,
  invoice_original_name: null,
  invoice_number: "INV-100",
  created_by: supervisor,
  created_by_name: "Supervisor",
  created_at: "2026-09-22T08:00:00.000Z",
  updated_at: "2026-09-22T08:00:00.000Z",
  revision: 1,
};

function deps(options: { transitionError?: boolean } = {}): BackendDependencies {
  return {
    async checkReadiness() { return true; },
    authVerifier: { async verify(token) {
      if (token === "supervisor") return { userId: supervisor, email: "s@example.invalid" };
      if (token === "purchasing") return { userId: purchaser, email: "p@example.invalid" };
      if (token === "manager") return { userId: manager, email: "m@example.invalid" };
      if (token === "inactive-purchasing") return { userId: inactivePurchaser, email: "inactive@example.invalid" };
      return null;
    } },
    createUserContext: (token) => ({
      async getUserContext() {
        if (token === "supervisor") return { id: supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch A", organization_id: organization, role: "branch_manager" as const }], managed_organizations: [] };
        if (token === "purchasing") return { id: purchaser, full_name: "Buyer", must_change_password: false, disabled: false, branches: [], managed_organizations: [], purchasing_organizations: [{ id: organization, name: "Org", role: "purchasing" as const }] };
        if (token === "manager") return { id: manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: organization, name: "Org", role: "organization_manager" as const }] };
        return { id: inactivePurchaser, full_name: "Inactive Buyer", must_change_password: false, disabled: false, branches: [], managed_organizations: [], purchasing_organizations: [] };
      },
      async hasOrganizationManagerAccess() { return token === "manager"; },
      async validateActiveBranches() { return token === "manager"; },
      async listActiveBranches() { return []; },
      async isInternalAdmin() { return false; },
    }),
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { throw new Error("unused"); }, async deleteUser() {}, async finalize() {} },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); }, async getPinCredential() { throw new Error("unused"); } },
    pinCrypto: { async hash() { throw new Error("unused"); }, async verify() { return false; }, issueGrant() { return "unused"; }, verifyGrant() { return false; } },
    operationalAdmin: {
      async listSupervisorPurchaseRequests(actorUserId, branchId) {
        calls.push({ name: "list-supervisor", input: { actorUserId, branchId } });
        if (branchId !== branch) throw new OperationalAccessError();
        return { purchase_requests: [purchaseRequest] };
      },
      async createSupervisorPurchaseRequest(input) {
        calls.push({ name: "create-supervisor", input });
        if (input.branchId !== branch) throw new OperationalAccessError();
        return { purchase_request: { ...purchaseRequest, category: input.category, notes: input.notes, items: input.items.map((item, index) => ({ id: `57000000-0000-4000-8000-00000000000${index + 1}`, purchase_request_id: requestId, item_name: item.name, quantity: String(item.quantity), unit: item.unit ?? null, notes: item.notes ?? null, sort_order: index + 1, created_at: "2026-09-21T08:00:00.000Z" })) } };
      },
      async listPurchasingPurchaseRequests(input) {
        calls.push({ name: "list-purchasing", input });
        if (input.organizationId !== organization) throw new OperationalAccessError();
        return { purchase_requests: [purchaseRequest] };
      },
      async setPurchasingPurchaseRequestStatus(input) {
        calls.push({ name: "status-purchasing", input });
        if (input.organizationId !== organization) throw new OperationalAccessError();
        if (options.transitionError) throw new OperationalInputError();
        return {
          purchase_request: {
            ...purchaseRequest,
            status: input.status,
            items: purchaseRequest.items.map((item) => ({
              ...item,
              vendor_name: input.purchaseDetails?.[0]?.vendor_name ?? null,
              invoice_number: input.purchaseDetails?.[0]?.invoice_number ?? null,
              purchased_quantity: input.purchaseDetails?.[0]?.purchased_quantity ?? null,
              actual_unit_cost: input.purchaseDetails?.[0]?.actual_unit_cost ?? null,
              actual_total_cost: input.purchaseDetails?.[0]?.actual_total_cost ?? null,
              before_tax_amount: input.purchaseDetails?.[0]?.before_tax_amount ?? null,
              tax_amount: input.purchaseDetails?.[0]?.tax_amount ?? null,
              total_amount: input.purchaseDetails?.[0]?.total_amount ?? input.purchaseDetails?.[0]?.actual_total_cost ?? null,
              payment_source: input.purchaseDetails?.[0]?.payment_source ?? null,
              purchasing_notes: input.purchaseDetails?.[0]?.purchasing_notes ?? null,
              attachments: [],
            })),
          },
        };
      },
      async savePurchasingPurchaseRequestDetails(input) {
        calls.push({ name: "save-purchasing-details", input });
        if (input.organizationId !== organization) throw new OperationalAccessError();
        return {
          purchase_request: {
            ...purchaseRequest,
            status: "processing",
            items: purchaseRequest.items.map((item) => ({
              ...item,
              vendor_name: input.purchaseDetails?.[0]?.vendor_name ?? null,
              invoice_number: input.purchaseDetails?.[0]?.invoice_number ?? null,
              purchased_quantity: input.purchaseDetails?.[0]?.purchased_quantity ?? null,
              actual_unit_cost: input.purchaseDetails?.[0]?.actual_unit_cost ?? null,
              actual_total_cost: input.purchaseDetails?.[0]?.actual_total_cost ?? null,
              before_tax_amount: input.purchaseDetails?.[0]?.before_tax_amount ?? null,
              tax_amount: input.purchaseDetails?.[0]?.tax_amount ?? null,
              total_amount: input.purchaseDetails?.[0]?.total_amount ?? input.purchaseDetails?.[0]?.actual_total_cost ?? null,
              payment_source: input.purchaseDetails?.[0]?.payment_source ?? null,
              purchasing_notes: input.purchaseDetails?.[0]?.purchasing_notes ?? null,
              attachments: [{ id: "77000000-0000-4000-8000-000000000001", original_filename: "receipt.pdf", mime_type: "application/pdf", size_bytes: 128, position: 1, url: "https://signed.example.invalid/receipt.pdf" }],
            })),
          },
        };
      },
      async listPurchasingPurchaseLogs(input) {
        calls.push({ name: "list-purchasing-purchase-logs", input });
        if (input.organizationId !== organization) throw new OperationalAccessError();
        return { purchase_logs: [purchaseLog] };
      },
      async reimbursePurchasingPurchaseRequestItem(input) {
        calls.push({ name: "reimburse-purchasing-item", input });
        if (input.organizationId !== organization) throw new OperationalAccessError();
        return {
          purchase_request: {
            ...purchaseRequest,
            status: "purchased",
            items: purchaseRequest.items.map((item) => ({
              ...item,
              payment_source: "personal",
              purchase_log_id: purchaseLogId,
              purchase_log_payment_status: "reimbursed",
              purchase_log_reimbursement_note: input.reimbursementNote ?? null,
              purchase_log_reimbursed_at: "2026-09-22T09:00:00.000Z",
              purchase_log_reimbursed_by: purchaser,
              attachments: [],
            })),
          },
        };
      },
      async createPurchaseLog(input) {
        calls.push({ name: "create-purchase-log", input });
        throw new Error("Purchase Request must not create Purchase Log");
      },
    } as unknown as BackendDependencies["operationalAdmin"],
  };
}

async function request(path: string, token: string, init: RequestInit = {}) {
  return fetch(origin + path, { ...init, headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) } });
}

describe("Purchase Request API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { calls.length = 0; });

  it("lets a Supervisor create a multi-item request for the route branch only", async () => {
    const response = await request(`/api/v1/supervisor/branches/${branch}/purchase-requests`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ category: "kitchen", notes: " Need stock ", items: [{ name: "Gloves", quantity: 3, unit: "box" }] }) });
    assert.equal(response.status, 201);
    assert.equal(calls[0]?.name, "create-supervisor");
    assert.deepEqual((calls[0]?.input as { branchId: string; category: string }).branchId, branch);
    assert.equal(calls.some((call) => call.name === "create-purchase-log"), false);
  });

  it("does not trust Supervisor supplied organization or requester identifiers", async () => {
    const response = await request(`/api/v1/supervisor/branches/${branch}/purchase-requests`, "supervisor", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        organization_id: otherOrganization,
        requested_by: manager,
        category: "kitchen",
        items: [{ name: "Gloves", quantity: 1 }],
      }),
    });
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  });

  it("denies Supervisor creation for an unauthorized branch through the authoritative backend check", async () => {
    const response = await request(`/api/v1/supervisor/branches/${otherBranch}/purchase-requests`, "supervisor", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ category: "kitchen", items: [{ name: "Gloves", quantity: 1 }] }),
    });
    assert.equal(response.status, 403);
    assert.equal(calls[0]?.name, "create-supervisor");
  });

  it("rejects zero items, invalid category, and invalid quantity before persistence", async () => {
    for (const body of [
      { category: "kitchen", items: [] },
      { category: "equipment", items: [{ name: "Gloves", quantity: 1 }] },
      { category: "kitchen", items: [{ name: "Gloves", quantity: 0 }] },
    ]) {
      const response = await request(`/api/v1/supervisor/branches/${branch}/purchase-requests`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      assert.equal(response.status, 400);
    }
    assert.equal(calls.length, 0);
  });

  it("lists requests for active Purchasing membership only", async () => {
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests`, "purchasing")).status, 200);
    assert.equal((await request(`/api/v1/purchasing/organizations/${otherOrganization}/purchase-requests`, "purchasing")).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests`, "manager")).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests`, "supervisor")).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests`, "inactive-purchasing")).status, 403);
  });

  it("allows only Phase 1B purchasing status transitions through the purchasing endpoint", async () => {
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/status`, "purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status: "processing" }) })).status, 200);
    const purchased = await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/status`, "purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status: "purchased", items: [{ item_id: purchaseRequest.items[0].id, vendor_name: "Office Vendor", invoice_number: "INV-1", purchased_quantity: 3, actual_unit_cost: "10.00", before_tax_amount: "30.00", tax_amount: "4.50", total_amount: "34.50", payment_source: "company", purchasing_notes: "Delivered" }] }) });
    assert.equal(purchased.status, 200);
    assert.deepEqual((calls.at(-1)?.input as { purchaseDetails?: unknown }).purchaseDetails, [{ item_id: purchaseRequest.items[0].id, vendor_name: "Office Vendor", invoice_number: "INV-1", purchased_quantity: 3, actual_unit_cost: "10.00", before_tax_amount: "30.00", tax_amount: "4.50", total_amount: "34.50", payment_source: "company", purchasing_notes: "Delivered" }]);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/status`, "purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status: "received" }) })).status, 400);
    assert.equal(calls.some((call) => call.name === "create-purchase-log"), false);
  });

  it("requires purchase details before Purchasing marks a request purchased", async () => {
    const response = await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/status`, "purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status: "purchased" }) });
    assert.equal(response.status, 400);
    assert.equal(calls.some((call) => call.name === "status-purchasing"), false);
  });

  it("lets active Purchasing save financial item details and attachment without changing status", async () => {
    const response = await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/items`, "purchasing", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ items: [{ item_id: purchaseRequest.items[0].id, vendor_name: "Food Vendor", invoice_number: "INV-9", purchased_quantity: 3, actual_unit_cost: "10.00", before_tax_amount: "30.00", tax_amount: "4.50", total_amount: "34.50", payment_source: "personal", purchasing_notes: "Saved", attachments: [{ original_name: "receipt.pdf", mime_type: "application/pdf", content_base64: Buffer.from("%PDF-1.4").toString("base64") }] }] }),
    });
    assert.equal(response.status, 200);
    const call = calls.at(-1);
    assert.equal(call?.name, "save-purchasing-details");
    const details = (call?.input as { purchaseDetails: Array<{ attachments?: Array<{ bytes: Buffer; mimeType: string; originalName: string }> }> }).purchaseDetails;
    assert.equal(details[0]?.attachments?.[0]?.mimeType, "application/pdf");
    assert.deepEqual({ ...details[0], attachments: undefined }, { item_id: purchaseRequest.items[0].id, vendor_name: "Food Vendor", invoice_number: "INV-9", purchased_quantity: 3, actual_unit_cost: "10.00", before_tax_amount: "30.00", tax_amount: "4.50", total_amount: "34.50", payment_source: "personal", purchasing_notes: "Saved", attachments: undefined });
    assert.equal(calls.some((entry) => entry.name === "create-purchase-log"), false);
  });

  it("rejects unsafe Purchase Request attachment payloads before persistence", async () => {
    const baseItem = { item_id: purchaseRequest.items[0].id, vendor_name: "Food Vendor", before_tax_amount: "30.00", tax_amount: "4.50", total_amount: "34.50" };
    const unsafePayloads = [
      { items: [{ ...baseItem, attachments: [{ original_name: "receipt.gif", mime_type: "image/gif", content_base64: Buffer.from("gif").toString("base64") }] }], expectedStatus: 400 },
      { items: [{ ...baseItem, attachments: Array.from({ length: 4 }, (_, index) => ({ original_name: `receipt-${index}.pdf`, mime_type: "application/pdf", content_base64: Buffer.from("%PDF-1.4").toString("base64") })) }], expectedStatus: 400 },
      { items: [{ ...baseItem, attachments: [{ original_name: "large.pdf", mime_type: "application/pdf", content_base64: Buffer.alloc(5 * 1024 * 1024 + 1, 1).toString("base64") }] }], expectedStatus: 413 },
    ];
    for (const payload of unsafePayloads) {
      const response = await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/items`, "purchasing", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ items: payload.items }),
      });
      assert.equal(response.status, payload.expectedStatus);
    }
    assert.equal(calls.some((entry) => entry.name === "save-purchasing-details"), false);
  });

  it("denies Purchase Request detail saves without exact active Purchasing membership", async () => {
    const body = JSON.stringify({ items: [{ item_id: purchaseRequest.items[0].id, vendor_name: "Food Vendor", before_tax_amount: "30.00", tax_amount: "4.50", total_amount: "34.50" }] });
    assert.equal((await request(`/api/v1/purchasing/organizations/${otherOrganization}/purchase-requests/${requestId}/items`, "purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/items`, "manager", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/items`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/items`, "inactive-purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body })).status, 403);
  });

  it("lists Purchase Logs read-only for active Purchasing organization membership only", async () => {
    const response = await request(`/api/v1/purchasing/organizations/${organization}/purchase-logs?payment_status=unpaid&date_from=2026-09-01&date_to=2026-09-30&search=oil`, "purchasing");
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), { name: "list-purchasing-purchase-logs", input: { actorUserId: purchaser, organizationId: organization, branchId: undefined, paymentStatus: "unpaid", dateFrom: "2026-09-01", dateTo: "2026-09-30", search: "oil" } });
    assert.equal((await request(`/api/v1/purchasing/organizations/${otherOrganization}/purchase-logs`, "purchasing")).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-logs`, "manager")).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-logs`, "supervisor")).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-logs`, "inactive-purchasing")).status, 403);
  });

  it("reimburses personal central purchasing items through active Purchasing membership only", async () => {
    const response = await request(`/api/v1/purchasing/organizations/${organization}/purchase-request-items/${purchaseRequest.items[0].id}/reimbursement`, "purchasing", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reimbursement_note: " Paid " }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), {
      name: "reimburse-purchasing-item",
      input: { actorUserId: purchaser, organizationId: organization, itemId: purchaseRequest.items[0].id, reimbursementNote: "Paid" },
    });
    assert.equal((await request(`/api/v1/purchasing/organizations/${otherOrganization}/purchase-request-items/${purchaseRequest.items[0].id}/reimbursement`, "purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) })).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-request-items/${purchaseRequest.items[0].id}/reimbursement`, "manager", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) })).status, 403);
    assert.equal((await request(`/api/v1/purchasing/organizations/${organization}/purchase-request-items/${purchaseRequest.items[0].id}/reimbursement`, "inactive-purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) })).status, 403);
  });

  it("returns a safe failure when the RPC rejects an invalid status jump", async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    server = createServer(createApp(config, deps({ transitionError: true })));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const response = await request(`/api/v1/purchasing/organizations/${organization}/purchase-requests/${requestId}/status`, "purchasing", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status: "purchased", items: [{ item_id: purchaseRequest.items[0].id, vendor_name: "Office Vendor", actual_total_cost: "30.00", payment_source: "company" }] }) });
    assert.equal(response.status, 422);
  });
});
