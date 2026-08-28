import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { OperationalAccessError, OperationalAttachmentNotFoundError } from "./operational";
import type { UserContext } from "./user-context";

const ids = {
  supervisor: "10000000-0000-4000-8000-000000000001",
  manager: "10000000-0000-4000-8000-000000000002",
  branch: "20000000-0000-4000-8000-000000000001",
  organization: "30000000-0000-4000-8000-000000000001",
  otherOrganization: "30000000-0000-4000-8000-000000000099",
  purchaseLog: "a0000000-0000-4000-8000-000000000001",
  supplierReceiving: "b0000000-0000-4000-8000-000000000001",
  maintenancePurchase: "c0000000-0000-4000-8000-000000000001",
  maintenancePurchaseAttachment: "d0000000-0000-4000-8000-000000000001",
} as const;

const contexts: Record<string, UserContext> = {
  supervisor: {
    id: ids.supervisor,
    full_name: "Supervisor",
    disabled: false,
    must_change_password: false,
    branches: [{ id: ids.branch, name: "Branch", organization_id: ids.organization, role: "branch_manager" }],
    managed_organizations: [],
  },
  manager: {
    id: ids.manager,
    full_name: "Manager",
    disabled: false,
    must_change_password: false,
    branches: [],
    managed_organizations: [{ id: ids.organization, name: "Organization", role: "organization_manager" }],
  },
};

describe("Management receipt read URLs", () => {
  let server: Server;
  let baseUrl = "";
  const calls: Array<Record<string, unknown>> = [];

  before(async () => {
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    server = createServer(createApp(config, dependencies(calls)));
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(async () => new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));

  it("lets a Manager create a fresh Purchase Log receipt read URL inside their organization", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/purchase-logs/${ids.purchaseLog}/receipt/read-url`, { headers: headers("manager") });
    assert.equal(response.status, 200);
    const text = await response.text();
    assert.doesNotMatch(text, /branches\/|invoice_storage_path|storage_path/);
    assert.deepEqual(JSON.parse(text), { signed_url: "https://storage.example.invalid/manager-purchase", expires_in: 300, original_name: "invoice.pdf" });
    assert.deepEqual(calls.at(-1), { method: "managedPurchaseLogReceiptReadUrl", actorUserId: ids.manager, organizationId: ids.organization, purchaseLogId: ids.purchaseLog });
  });

  it("lets a Manager create a fresh Supplier Receiving photo read URL inside their organization", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/supplier-receivings/${ids.supplierReceiving}/photo/read-url`, { headers: headers("manager") });
    assert.equal(response.status, 200);
    const text = await response.text();
    assert.doesNotMatch(text, /branches\/|photo_storage_path|storage_path/);
    assert.deepEqual(JSON.parse(text), { signed_url: "https://storage.example.invalid/manager-supplier", expires_in: 300, original_name: "photo.jpg" });
    assert.deepEqual(calls.at(-1), { method: "managedSupplierReceivingPhotoReadUrl", actorUserId: ids.manager, organizationId: ids.organization, supplierReceivingId: ids.supplierReceiving });
  });

  it("lets a Manager create a fresh Maintenance Purchase receipt read URL inside their organization", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/maintenance-purchases/${ids.maintenancePurchase}/receipt/read-url`, { headers: headers("manager") });
    assert.equal(response.status, 200);
    const text = await response.text();
    assert.doesNotMatch(text, /maintenance\/|receipt_storage_path|storage_path/);
    assert.deepEqual(JSON.parse(text), { signed_url: "https://storage.example.invalid/manager-maintenance-purchase", expires_in: 300, original_name: "receipt.pdf" });
    assert.deepEqual(calls.at(-1), { method: "managedMaintenancePurchaseReceiptReadUrl", actorUserId: ids.manager, organizationId: ids.organization, purchaseId: ids.maintenancePurchase, attachmentId: null });

    const attachment = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/maintenance-purchases/${ids.maintenancePurchase}/receipt/read-url?attachment_id=${ids.maintenancePurchaseAttachment}`, { headers: headers("manager") });
    assert.equal(attachment.status, 200);
    assert.deepEqual(await attachment.json(), { signed_url: "https://storage.example.invalid/manager-maintenance-purchase-attachment", expires_in: 300, original_name: "receipt-2.jpg" });
    assert.deepEqual(calls.at(-1), { method: "managedMaintenancePurchaseReceiptReadUrl", actorUserId: ids.manager, organizationId: ids.organization, purchaseId: ids.maintenancePurchase, attachmentId: ids.maintenancePurchaseAttachment });
  });

  it("rejects unauthorized, invalid, and missing management receipt access safely", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/purchase-logs/${ids.purchaseLog}/receipt/read-url`, { headers: headers("supervisor") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.otherOrganization}/purchase-logs/${ids.purchaseLog}/receipt/read-url`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/purchase-logs/not-a-uuid/receipt/read-url`, { headers: headers("manager") })).status, 400);
    const missing = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/purchase-logs/a0000000-0000-4000-8000-000000000099/receipt/read-url`, { headers: headers("manager") });
    assert.equal(missing.status, 404);
    assert.doesNotMatch(await missing.text(), /branches\/|storage_path|invoice_storage_path/);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/maintenance-purchases/${ids.maintenancePurchase}/receipt/read-url`, { headers: headers("supervisor") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.otherOrganization}/maintenance-purchases/${ids.maintenancePurchase}/receipt/read-url`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/maintenance-purchases/not-a-uuid/receipt/read-url`, { headers: headers("manager") })).status, 400);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/maintenance-purchases/${ids.maintenancePurchase}/receipt/read-url?attachment_id=not-a-uuid`, { headers: headers("manager") })).status, 400);
    const missingMaintenance = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/maintenance-purchases/c0000000-0000-4000-8000-000000000099/receipt/read-url`, { headers: headers("manager") });
    assert.equal(missingMaintenance.status, 404);
    assert.doesNotMatch(await missingMaintenance.text(), /maintenance\/|storage_path|receipt_storage_path/);
  });

  it("keeps existing Supervisor receipt endpoints intact", async () => {
    const purchase = await fetch(`${baseUrl}/api/v1/supervisor/purchase-logs/${ids.purchaseLog}/receipt/read-url`, { headers: headers("supervisor") });
    assert.equal(purchase.status, 200);
    assert.deepEqual(await purchase.json(), { signed_url: "https://storage.example.invalid/supervisor-purchase", expires_in: 300, original_name: "invoice.pdf" });
    const supplier = await fetch(`${baseUrl}/api/v1/supervisor/supplier-receivings/${ids.supplierReceiving}/photo/read-url`, { headers: headers("supervisor") });
    assert.equal(supplier.status, 200);
    assert.deepEqual(await supplier.json(), { signed_url: "https://storage.example.invalid/supervisor-supplier", expires_in: 300, original_name: "photo.jpg" });
  });
});

function headers(token: string) {
  return { authorization: `Bearer ${token}`, "content-type": "application/json" };
}

function dependencies(calls: Array<Record<string, unknown>>): BackendDependencies {
  return {
    authVerifier: {
      async verify(token) {
        const context = contexts[token];
        return context ? { userId: context.id, email: `${token}@example.invalid` } : null;
      },
    },
    checkReadiness: async () => true,
    createUserContext: (token) => ({
      async getUserContext() { return contexts[token] ?? null; },
      async hasOrganizationManagerAccess() { return token === "manager"; },
      async validateActiveBranches() { return true; },
      async listActiveBranches() { return []; },
    }),
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { return { id: ids.supervisor }; }, async deleteUser() {}, async finalize() {} },
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
    operationalAdmin: {
      async getBranchTimezone() { return "Asia/Riyadh"; },
      async getSupervisorTeam() { return { teams: [] }; },
      async createStaff() { throw new Error("unused"); },
      async updateStaff() { throw new Error("unused"); },
      async setDuty() { throw new Error("unused"); },
      async listHealthCards() { return { health_cards: [] }; },
      async upsertHealthCard() { throw new Error("unused"); },
      async listMonthlyEvaluations() { return { evaluations: [] }; },
      async saveMonthlyEvaluation() { throw new Error("unused"); },
      async listPurchaseLogs() { return { purchase_logs: [] }; },
      async createPurchaseLogReceiptReadUrl(input) {
        calls.push({ method: "purchaseLogReceiptReadUrl", ...input });
        if (input.actorUserId !== ids.supervisor) throw new OperationalAccessError();
        return { signed_url: "https://storage.example.invalid/supervisor-purchase", expires_in: 300, original_name: "invoice.pdf" };
      },
      async createManagedPurchaseLogReceiptReadUrl(input) {
        calls.push({ method: "managedPurchaseLogReceiptReadUrl", ...input });
        if (input.actorUserId !== ids.manager || input.organizationId !== ids.organization) throw new OperationalAccessError();
        if (input.purchaseLogId !== ids.purchaseLog) throw new OperationalAttachmentNotFoundError();
        return { signed_url: "https://storage.example.invalid/manager-purchase", expires_in: 300, original_name: "invoice.pdf" };
      },
      async createPurchaseLog() { throw new Error("unused"); },
      async updatePurchaseLogPaymentStatus() { throw new Error("unused"); },
      async listSupplierReceivings() { return { supplier_receivings: [] }; },
      async createSupplierReceivingPhotoReadUrl(input) {
        calls.push({ method: "supplierReceivingPhotoReadUrl", ...input });
        if (input.actorUserId !== ids.supervisor) throw new OperationalAccessError();
        return { signed_url: "https://storage.example.invalid/supervisor-supplier", expires_in: 300, original_name: "photo.jpg" };
      },
      async createManagedSupplierReceivingPhotoReadUrl(input) {
        calls.push({ method: "managedSupplierReceivingPhotoReadUrl", ...input });
        if (input.actorUserId !== ids.manager || input.organizationId !== ids.organization) throw new OperationalAccessError();
        if (input.supplierReceivingId !== ids.supplierReceiving) throw new OperationalAttachmentNotFoundError();
        return { signed_url: "https://storage.example.invalid/manager-supplier", expires_in: 300, original_name: "photo.jpg" };
      },
      async createManagedMaintenancePurchaseReceiptReadUrl(input) {
        calls.push({ method: "managedMaintenancePurchaseReceiptReadUrl", ...input });
        if (input.actorUserId !== ids.manager || input.organizationId !== ids.organization) throw new OperationalAccessError();
        if (input.purchaseId !== ids.maintenancePurchase) throw new OperationalAttachmentNotFoundError();
        if (input.attachmentId) return { signed_url: "https://storage.example.invalid/manager-maintenance-purchase-attachment", expires_in: 300, original_name: "receipt-2.jpg" };
        return { signed_url: "https://storage.example.invalid/manager-maintenance-purchase", expires_in: 300, original_name: "receipt.pdf" };
      },
      async listBranchSuppliers() { return { suppliers: [] }; },
      async createBranchSupplier() { throw new Error("unused"); },
      async createSupplierReceiving() { throw new Error("unused"); },
      async listSupervisorMaintenanceIssues() { return { maintenance_issues: [] }; },
      async createSupervisorMaintenanceIssue() { throw new Error("unused"); },
      async listMaintenanceIssues() { return { maintenance_issues: [] }; },
      async updateMaintenanceIssue() { throw new Error("unused"); },
      async listMaintenancePurchases() { return { maintenance_purchases: [] }; },
      async reimburseMaintenancePurchase() { throw new Error("unused"); },
      async listManagedStaff() { return { staff: [], total: 0 }; },
      async listManagedTeams() { return { teams: [] }; },
      async listEligibleSupervisors() { return { supervisors: [] }; },
    },
  };
}
