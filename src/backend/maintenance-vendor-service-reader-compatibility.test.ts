import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { describe, it } from "node:test";
import { createOperationalAdmin } from "./operational";

const source = (file: string) => readFile(path.resolve(file), "utf8");

describe("authoritative Maintenance Vendor/Service reader compatibility", () => {
  it("parses service values through the authoritative managed-purchase read adapter", async () => {
    const rpc = createServer((_request, response) => {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify([{
        id: "71000000-0000-4000-8000-000000000001",
        organization_id: "11000000-0000-4000-8000-000000000001",
        branch_id: "21000000-0000-4000-8000-000000000001",
        branch_name: "Burger Hunch Al Takhassusi",
        maintenance_issue_id: null,
        purchase_type: "general",
        issue_title: null,
        issue_category: null,
        issue_status: null,
        responsible_person_name: null,
        purchase_scope: "branch",
        destination: null,
        category: "service",
        maintenance_user_id: "31000000-0000-4000-8000-000000000001",
        maintenance_user_name: "Maintenance Operator",
        item_name: "Monthly deep cleaning",
        quantity: "1",
        unit: "service",
        amount: "350.00",
        vendor_name: "Dr. Clean",
        purchase_date: "2026-09-02",
        notes: null,
        payment_status: "unpaid",
        payment_method: "cash",
        reimbursement_note: null,
        reimbursed_at: null,
        reimbursed_by: null,
        receipt_storage_path: null,
        receipt_original_name: null,
        attachments: [],
        created_at: "2026-09-02T10:00:00Z",
        updated_at: "2026-09-02T10:00:00Z",
      }]));
    });
    await new Promise<void>((resolve) => rpc.listen(0, "127.0.0.1", resolve));
    try {
      const admin = createOperationalAdmin(`http://127.0.0.1:${(rpc.address() as AddressInfo).port}`, "service-key");
      const result = await admin.listManagedMaintenancePurchases?.({
        actorUserId: "41000000-0000-4000-8000-000000000001",
        organizationId: "11000000-0000-4000-8000-000000000001",
      }) as { maintenance_purchases: Array<{ category: string; unit: string; purchase_scope: string; branch_name: string; destination: string | null }> };
      assert.deepEqual(result.maintenance_purchases[0] && {
        category: result.maintenance_purchases[0].category,
        unit: result.maintenance_purchases[0].unit,
        purchase_scope: result.maintenance_purchases[0].purchase_scope,
        branch_name: result.maintenance_purchases[0].branch_name,
        destination: result.maintenance_purchases[0].destination,
      }, {
        category: "service",
        unit: "service",
        purchase_scope: "branch",
        branch_name: "Burger Hunch Al Takhassusi",
        destination: null,
      });
    } finally {
      await new Promise<void>((resolve, reject) => rpc.close((error) => error ? reject(error) : resolve()));
    }
  });

  it("keeps strict readers compatible while the authoritative writer admits service", async () => {
    const [app, operational] = await Promise.all([
      source("src/backend/app.ts"),
      source("src/backend/operational.ts"),
    ]);

    assert.match(app, /const maintenancePurchaseUnitSchema = z\.enum\(\["pcs", "meter", "kg", "box", "bag", "roll", "set", "liter", "other", "service"\]\)/);
    assert.match(app, /const maintenancePurchaseReadUnitSchema = z\.enum\(\["pcs", "meter", "kg", "box", "bag", "roll", "set", "liter", "other", "service"\]\)/);
    assert.match(app, /const maintenancePurchaseCategorySchema = z\.enum\(\[[^\]]*"general_supplies", "other", "service"\]\)/);
    assert.match(app, /const maintenancePurchaseReadCategorySchema = z\.enum\(\[[^\]]*"general_supplies", "other", "service"\]\)/);
    assert.match(app, /const maintenancePurchaseBodySchema=z\.object\([^;]*category:maintenancePurchaseCategorySchema[^;]*unit:maintenancePurchaseUnitSchema/);
    assert.match(app, /const maintenancePurchaseRowSchema=z\.object\([^;]*category:maintenancePurchaseReadCategorySchema[^;]*unit:maintenancePurchaseReadUnitSchema/);
    assert.match(app, /const managedMaintenancePurchaseRowSchema=z\.object\([^;]*category:maintenancePurchaseReadCategorySchema[^;]*unit:maintenancePurchaseReadUnitSchema/);

    assert.match(operational, /createMaintenancePurchase\(input:[\s\S]*?payload:CanonicalMaintenancePurchasePayload/);
    assert.match(operational, /maintenancePurchaseListRpcRow=z\.object\([^;]*category:maintenancePurchaseReadCategory[^;]*unit:maintenancePurchaseReadUnit/);
    assert.match(operational, /managedMaintenancePurchaseRpcRow=z\.object\([^;]*category:maintenancePurchaseReadCategory[^;]*unit:maintenancePurchaseReadUnit/);
  });

  it("uses the Phase B canonical payload for both hashing and the v2 RPC", async () => {
    const [app, operational] = await Promise.all([
      source("src/backend/app.ts"),
      source("src/backend/operational.ts"),
    ]);
    const route = app.slice(app.indexOf('app.post("/api/v1/maintenance/purchases/general"'), app.indexOf('app.patch("/api/v1/maintenance/purchases/'));
    assert.match(route, /canonicalizeMaintenancePurchasePayload\(\{issueId:null,payload:body\.data\}\)/);
    assert.match(route, /payload:canonicalPayload/);
    const writer = operational.slice(operational.indexOf("async createMaintenancePurchase(input)"), operational.indexOf("async reimburseMaintenancePurchase(input)"));
    assert.match(writer, /const canonicalPayload=input\.payload/);
    assert.match(writer, /maintenancePurchaseRequestHash\(\{issueId:input\.issueId,payload:canonicalPayload,receipts\}\)/);
    assert.match(writer, /payload:\{\.\.\.canonicalPayload,purchase_id:/);
    assert.match(writer, /request_hash:requestHash/);
    assert.doesNotMatch(writer, /payload:\{\.\.\.input\.payload/);
  });
});
