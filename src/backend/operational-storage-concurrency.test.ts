import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, beforeEach, describe, it } from "node:test";
import {
  createOperationalAdmin,
  DEFAULT_STORAGE_SIGNING_CONCURRENCY,
  MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY,
} from "./operational";

describe("Operational Storage Signing Concurrency", () => {
  let server: Server;
  let baseUrl: string;
  let activeConcurrency = 0;
  let maxConcurrency = 0;
  let totalSigningCalls = 0;
  let shouldFailSigning = false;

  let rpcResponse: unknown = [];

  beforeEach(async () => {
    activeConcurrency = 0;
    maxConcurrency = 0;
    totalSigningCalls = 0;
    shouldFailSigning = false;
    rpcResponse = [];

    server = createServer(async (req, res) => {
      let body = "";
      for await (const chunk of req) body += chunk;

      // Handle RPC routes
      if (req.url?.startsWith("/rest/v1/rpc/")) {
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(rpcResponse));
        return;
      }

      // Handle Storage signing routes
      if (req.url?.startsWith("/storage/v1/object/sign/")) {
        totalSigningCalls++;
        activeConcurrency++;
        if (activeConcurrency > maxConcurrency) {
          maxConcurrency = activeConcurrency;
        }

        // Simulate network delay to observe concurrency
        await new Promise((r) => setTimeout(r, 20));
        activeConcurrency--;

        if (shouldFailSigning) {
          res.statusCode = 500;
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ error: "Storage error", message: "Failed", statusCode: "500" }));
          return;
        }

        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ signedURL: `https://storage.mock/signed/${encodeURIComponent(req.url)}` }));
        return;
      }

      res.statusCode = 404;
      res.end();
    });

    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;
    baseUrl = `http://127.0.0.1:${port}`;
  });

  afterEach(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  it("exports DEFAULT_STORAGE_SIGNING_CONCURRENCY = 6 and backwards-compatible alias", () => {
    assert.strictEqual(DEFAULT_STORAGE_SIGNING_CONCURRENCY, 6);
    assert.strictEqual(MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY, 6);
  });

  it("normalizePurchaseRows bounds concurrency <= 6 and preserves row order", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    const count = 15;
    const mockRows = Array.from({ length: count }, (_, i) => ({
      id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      branch_id: "10000000-0000-4000-8000-000000000001",
      category: "stationery",
      item_name: `Item ${i + 1}`,
      quantity: 5,
      amount: 100,
      vendor_name: "Vendor Inc",
      purchase_date: "2026-09-18",
      notes: null,
      payment_status: "unpaid",
      reimbursement_note: null,
      reimbursed_at: null,
      reimbursed_by: null,
      invoice_storage_path: `invoices/inv_${i + 1}.pdf`,
      invoice_original_name: `invoice_${i + 1}.pdf`,
      invoice_number: `INV-${i + 1}`,
      created_by: "20000000-0000-4000-8000-000000000001",
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));
    rpcResponse = mockRows;

    const result = await admin.listPurchaseLogs(
      "20000000-0000-4000-8000-000000000001",
      "10000000-0000-4000-8000-000000000001",
    );

    assert.strictEqual(result.purchase_logs.length, count);
    assert.strictEqual(totalSigningCalls, count);
    assert.ok(maxConcurrency <= 6, `Max concurrency was ${maxConcurrency}, expected <= 6`);
    assert.ok(maxConcurrency > 1, `Max concurrency was ${maxConcurrency}, expected concurrent execution`);

    // Verify order and URLs
    for (let i = 0; i < count; i++) {
      assert.strictEqual(result.purchase_logs[i].id, mockRows[i].id);
      assert.ok(result.purchase_logs[i].invoice_url?.includes(`inv_${i + 1}.pdf`));
    }
  });

  it("listPurchaseLogs accepts all-time history beyond the old 500-row validation cap", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    const count = 501;
    rpcResponse = Array.from({ length: count }, (_, i) => ({
      id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      branch_id: "10000000-0000-4000-8000-000000000001",
      category: "stationery",
      item_name: `Item ${i + 1}`,
      quantity: 1,
      amount: 10,
      before_tax_amount: null,
      tax_amount: null,
      vendor_name: "Vendor Inc",
      purchase_date: i % 2 === 0 ? "2026-08-18" : "2026-09-18",
      notes: null,
      payment_status: i % 2 === 0 ? "unpaid" : "reimbursed",
      reimbursement_note: null,
      reimbursed_at: null,
      reimbursed_by: null,
      invoice_storage_path: null,
      invoice_original_name: null,
      invoice_number: null,
      created_by: "20000000-0000-4000-8000-000000000001",
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));

    const result = await admin.listPurchaseLogs(
      "20000000-0000-4000-8000-000000000001",
      "10000000-0000-4000-8000-000000000001",
    );

    assert.strictEqual(result.purchase_logs.length, count);
    assert.strictEqual(result.purchase_logs[0].purchase_date, "2026-08-18");
    assert.strictEqual(result.purchase_logs.at(-1)?.payment_status, "unpaid");
  });

  it("normalizeManagedPurchaseRows bounds concurrency <= 6 and preserves row order", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    const count = 12;
    const mockRows = Array.from({ length: count }, (_, i) => ({
      id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      branch_id: "10000000-0000-4000-8000-000000000001",
      category: "kitchen",
      item_name: `Managed Item ${i + 1}`,
      quantity: 10,
      amount: 250,
      vendor_name: "Supplier Co",
      purchase_date: "2026-09-18",
      notes: null,
      payment_status: "unpaid",
      reimbursement_note: null,
      reimbursed_at: null,
      reimbursed_by: null,
      invoice_storage_path: `invoices/managed_${i + 1}.pdf`,
      invoice_original_name: `managed_${i + 1}.pdf`,
      invoice_number: `M-INV-${i + 1}`,
      created_by: "20000000-0000-4000-8000-000000000001",
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));
    rpcResponse = mockRows;

    const result = await admin.listManagedPurchaseLogs({
      actorUserId: "20000000-0000-4000-8000-000000000001",
      organizationId: "30000000-0000-4000-8000-000000000001",
    });

    assert.strictEqual(result.purchase_logs.length, count);
    assert.strictEqual(totalSigningCalls, count);
    assert.ok(maxConcurrency <= 6, `Max concurrency was ${maxConcurrency}, expected <= 6`);
    assert.ok(maxConcurrency > 1, `Max concurrency was ${maxConcurrency}, expected concurrent execution`);

    for (let i = 0; i < count; i++) {
      assert.strictEqual(result.purchase_logs[i].id, mockRows[i].id);
      assert.ok(result.purchase_logs[i].invoice_url?.includes(`managed_${i + 1}.pdf`));
    }
  });

  it("normalizeSupplierReceivingRows bounds concurrency <= 6 and preserves row order", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    const count = 12;
    const mockRows = Array.from({ length: count }, (_, i) => ({
      id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      branch_id: "10000000-0000-4000-8000-000000000001",
      supplier_id: null,
      category: "raw",
      supplier_name_en: `Supplier ${i + 1}`,
      supplier_name_ar: null,
      quantity: 20,
      unit: "kg",
      notes: null,
      photo_storage_path: `supplier_receivings/photo_${i + 1}.jpg`,
      photo_original_name: `photo_${i + 1}.jpg`,
      created_by: "20000000-0000-4000-8000-000000000001",
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));
    rpcResponse = mockRows;

    const result = await admin.listSupplierReceivings({
      actorUserId: "20000000-0000-4000-8000-000000000001",
      branchId: "10000000-0000-4000-8000-000000000001",
    });

    assert.strictEqual(result.supplier_receivings.length, count);
    assert.strictEqual(totalSigningCalls, count);
    assert.ok(maxConcurrency <= 6, `Max concurrency was ${maxConcurrency}, expected <= 6`);
    assert.ok(maxConcurrency > 1, `Max concurrency was ${maxConcurrency}, expected concurrent execution`);

    for (let i = 0; i < count; i++) {
      assert.strictEqual(result.supplier_receivings[i].id, mockRows[i].id);
      assert.ok(result.supplier_receivings[i].photo_url?.includes(`photo_${i + 1}.jpg`));
    }
  });

  it("normalizeManagedSupplierReceivingRows bounds concurrency <= 6 and preserves row order", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    const count = 12;
    const mockRows = Array.from({ length: count }, (_, i) => ({
      id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      branch_id: "10000000-0000-4000-8000-000000000001",
      supplier_id: null,
      category: "frozen",
      supplier_name_en: `Managed Supplier ${i + 1}`,
      supplier_name_ar: null,
      quantity: 50,
      unit: "box",
      notes: null,
      photo_storage_path: `supplier_receivings/managed_photo_${i + 1}.jpg`,
      photo_original_name: `managed_photo_${i + 1}.jpg`,
      created_by: "20000000-0000-4000-8000-000000000001",
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));
    rpcResponse = mockRows;

    const result = await admin.listManagedSupplierReceivings({
      actorUserId: "20000000-0000-4000-8000-000000000001",
      organizationId: "30000000-0000-4000-8000-000000000001",
    });

    assert.strictEqual(result.supplier_receivings.length, count);
    assert.strictEqual(totalSigningCalls, count);
    assert.ok(maxConcurrency <= 6, `Max concurrency was ${maxConcurrency}, expected <= 6`);
    assert.ok(maxConcurrency > 1, `Max concurrency was ${maxConcurrency}, expected concurrent execution`);

    for (let i = 0; i < count; i++) {
      assert.strictEqual(result.supplier_receivings[i].id, mockRows[i].id);
      assert.ok(result.supplier_receivings[i].photo_url?.includes(`managed_photo_${i + 1}.jpg`));
    }
  });

  it("normalizeMaintenancePurchaseRows bounds multi-attachment signing <= 6 and preserves attachment order", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    // 5 rows each with 3 attachments = 15 signing calls
    const mockRows = Array.from({ length: 5 }, (_, r) => ({
      id: `00000000-0000-4000-8000-${String(r + 1).padStart(12, "0")}`,
      branch_id: "10000000-0000-4000-8000-000000000001",
      purchase_type: "general",
      purchase_scope: "branch",
      destination: null,
      category: "tools_equipment",
      item_name: `Wrench ${r + 1}`,
      quantity: 1,
      unit: "pcs",
      amount: 45,
      vendor_name: "Hardware Store",
      purchase_date: "2026-09-18",
      notes: null,
      payment_status: "unpaid",
      payment_method: null,
      reimbursement_note: null,
      reimbursed_at: null,
      reimbursed_by: null,
      receipt_storage_path: null,
      receipt_original_name: null,
      attachments: [1, 2, 3].map((pos) => ({
        id: `a0000000-0000-4000-8000-${String(r * 3 + pos).padStart(12, "0")}`,
        storage_path: `purchases/row_${r + 1}_att_${pos}.jpg`,
        original_filename: `receipt_${r + 1}_${pos}.jpg`,
        mime_type: "image/jpeg",
        size_bytes: 10240,
        position: pos,
      })),
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));
    rpcResponse = mockRows;

    const result = await admin.listMaintenancePurchases("20000000-0000-4000-8000-000000000001");

    assert.strictEqual(result.maintenance_purchases.length, 5);
    assert.strictEqual(totalSigningCalls, 15);
    assert.ok(maxConcurrency <= 6, `Max concurrency was ${maxConcurrency}, expected <= 6`);
    assert.ok(maxConcurrency > 1, `Max concurrency was ${maxConcurrency}, expected concurrent execution`);

    // Verify row order, attachments order, and receipt_url = attachments[0].url
    for (let r = 0; r < 5; r++) {
      const p = result.maintenance_purchases[r];
      assert.strictEqual(p.id, mockRows[r].id);
      assert.strictEqual(p.attachments.length, 3);
      for (let pos = 0; pos < 3; pos++) {
        assert.strictEqual(p.attachments[pos].position, pos + 1);
        assert.ok(p.attachments[pos].url?.includes(`row_${r + 1}_att_${pos + 1}.jpg`));
      }
      assert.strictEqual(p.receipt_url, p.attachments[0].url);
      assert.strictEqual(p.receipt_original_name, p.attachments[0].original_filename);
    }
  });

  it("handles fallback receipt signing when attachments are empty and never returns raw path", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    rpcResponse = [
      {
        id: "00000000-0000-4000-8000-000000000001",
        branch_id: "10000000-0000-4000-8000-000000000001",
        purchase_type: "general",
        purchase_scope: "branch",
        destination: null,
        category: "spare_parts",
        item_name: "Bolt",
        quantity: 10,
        unit: "pcs",
        amount: 20,
        vendor_name: "Shop",
        purchase_date: "2026-09-18",
        notes: null,
        payment_status: "unpaid",
        payment_method: null,
        reimbursement_note: null,
        reimbursed_at: null,
        reimbursed_by: null,
        receipt_storage_path: "purchases/legacy_receipt.jpg",
        receipt_original_name: "legacy_receipt.jpg",
        attachments: [],
        created_at: "2026-09-18T00:00:00.000Z",
        updated_at: "2026-09-18T00:00:00.000Z",
      },
      {
        id: "00000000-0000-4000-8000-000000000002",
        branch_id: "10000000-0000-4000-8000-000000000001",
        purchase_type: "general",
        purchase_scope: "branch",
        destination: null,
        category: "spare_parts",
        item_name: "Nut",
        quantity: 10,
        unit: "pcs",
        amount: 15,
        vendor_name: "Shop",
        purchase_date: "2026-09-18",
        notes: null,
        payment_status: "unpaid",
        payment_method: null,
        reimbursement_note: null,
        reimbursed_at: null,
        reimbursed_by: null,
        receipt_storage_path: null,
        receipt_original_name: null,
        attachments: [],
        created_at: "2026-09-18T00:00:00.000Z",
        updated_at: "2026-09-18T00:00:00.000Z",
      },
    ];

    const result = await admin.listMaintenancePurchases("20000000-0000-4000-8000-000000000001");

    assert.strictEqual(result.maintenance_purchases.length, 2);
    // Row 1 had fallback path, so 1 signing call
    // Row 2 had null path and 0 attachments, so 0 signing calls
    assert.strictEqual(totalSigningCalls, 1);

    // Row 1 fallback signed
    assert.ok(result.maintenance_purchases[0].receipt_url?.includes("legacy_receipt.jpg"));
    assert.notStrictEqual(result.maintenance_purchases[0].receipt_url, "purchases/legacy_receipt.jpg");
    assert.strictEqual(result.maintenance_purchases[0].receipt_original_name, "legacy_receipt.jpg");

    // Row 2 null
    assert.strictEqual(result.maintenance_purchases[1].receipt_url, null);
    assert.strictEqual(result.maintenance_purchases[1].receipt_original_name, null);
  });

  it("normalizeManagedMaintenancePurchases bounds concurrency <= 6 and omits sensitive fields", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    const count = 10;
    const mockRows = Array.from({ length: count }, (_, i) => ({
      id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      organization_id: "30000000-0000-4000-8000-000000000001",
      branch_id: "10000000-0000-4000-8000-000000000001",
      branch_name: "Main Branch",
      maintenance_issue_id: null,
      purchase_type: "general",
      issue_title: null,
      issue_category: null,
      issue_status: null,
      responsible_person_name: null,
      purchase_scope: "branch",
      destination: null,
      category: "plumbing",
      maintenance_user_id: "20000000-0000-4000-8000-000000000001",
      maintenance_user_name: "Tech",
      item_name: `Pipe ${i + 1}`,
      quantity: 2,
      unit: "pcs",
      amount: 60,
      vendor_name: "Plumbing Supplies",
      purchase_date: "2026-09-18",
      notes: null,
      payment_status: "unpaid",
      payment_method: null,
      reimbursement_note: null,
      reimbursed_at: null,
      reimbursed_by: null,
      receipt_storage_path: null,
      receipt_original_name: null,
      attachments: [
        {
          id: `a0000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
          storage_path: `purchases/pipe_${i + 1}.jpg`,
          original_filename: `pipe_${i + 1}.jpg`,
          mime_type: "image/jpeg",
          size_bytes: 5000,
          position: 1,
        },
      ],
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));
    rpcResponse = mockRows;

    const result = await admin.listManagedMaintenancePurchases({
      actorUserId: "20000000-0000-4000-8000-000000000001",
      organizationId: "30000000-0000-4000-8000-000000000001",
    });

    assert.strictEqual(result.maintenance_purchases.length, count);
    assert.strictEqual(totalSigningCalls, count);
    assert.ok(maxConcurrency <= 6, `Max concurrency was ${maxConcurrency}, expected <= 6`);
    assert.ok(maxConcurrency > 1, `Max concurrency was ${maxConcurrency}, expected concurrent execution`);

    for (let i = 0; i < count; i++) {
      const p = result.maintenance_purchases[i];
      assert.strictEqual(p.id, mockRows[i].id);
      assert.ok(!("organization_id" in p), "organization_id must be omitted");
      assert.ok(!("receipt_storage_path" in p), "receipt_storage_path must be omitted");
      assert.ok(p.receipt_url?.includes(`pipe_${i + 1}.jpg`));
    }
  });

  it("normalizeMaintenancePurchaseHistoryPage bounds concurrency <= 6 and preserves pagination", async () => {
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    const count = 10;
    const mockPurchases = Array.from({ length: count }, (_, i) => ({
      id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      organization_id: "30000000-0000-4000-8000-000000000001",
      branch_id: "10000000-0000-4000-8000-000000000001",
      branch_name: "Main Branch",
      maintenance_issue_id: null,
      purchase_type: "issue",
      issue_title: "Broken AC",
      issue_category: "refrigeration",
      issue_status: "in_progress",
      responsible_person_name: "Bob",
      purchase_scope: "branch",
      destination: null,
      category: "hvac_refrigeration",
      maintenance_user_id: "20000000-0000-4000-8000-000000000001",
      maintenance_user_name: "Tech",
      item_name: `Filter ${i + 1}`,
      quantity: 1,
      unit: "pcs",
      amount: 120,
      vendor_name: "HVAC Direct",
      purchase_date: "2026-09-18",
      notes: null,
      payment_status: "reimbursed",
      payment_method: null,
      reimbursement_note: "Approved",
      reimbursed_at: "2026-09-18T10:00:00.000Z",
      reimbursed_by: "30000000-0000-4000-8000-000000000001",
      receipt_storage_path: null,
      receipt_original_name: null,
      attachments: [
        {
          id: `a0000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
          storage_path: `purchases/filter_${i + 1}.jpg`,
          original_filename: `filter_${i + 1}.jpg`,
          mime_type: "image/jpeg",
          size_bytes: 8000,
          position: 1,
        },
      ],
      created_at: "2026-09-18T00:00:00.000Z",
      updated_at: "2026-09-18T00:00:00.000Z",
    }));
    rpcResponse = {
      maintenance_purchases: mockPurchases,
      page: 1,
      page_size: 10,
      total_count: 50,
      has_more: true,
    };

    const result = await admin.listMaintenancePurchaseHistoryPage({
      actorUserId: "20000000-0000-4000-8000-000000000001",
      purchaseType: "issue",
      page: 1,
      pageSize: 10,
    });

    assert.strictEqual(result.maintenance_purchases.length, count);
    assert.strictEqual(result.page, 1);
    assert.strictEqual(result.page_size, 10);
    assert.strictEqual(result.total_count, 50);
    assert.strictEqual(result.has_more, true);
    assert.strictEqual(totalSigningCalls, count);
    assert.ok(maxConcurrency <= 6, `Max concurrency was ${maxConcurrency}, expected <= 6`);
    assert.ok(maxConcurrency > 1, `Max concurrency was ${maxConcurrency}, expected concurrent execution`);

    for (let i = 0; i < count; i++) {
      const p = result.maintenance_purchases[i];
      assert.strictEqual(p.id, mockPurchases[i].id);
      assert.ok(!("maintenance_user_id" in p), "maintenance_user_id must be omitted");
      assert.ok(!("receipt_storage_path" in p), "receipt_storage_path must be omitted");
      assert.ok(p.receipt_url?.includes(`filter_${i + 1}.jpg`));
    }
  });

  it("handles storage signing errors gracefully without throwing, setting url to null", async () => {
    shouldFailSigning = true;
    const admin = createOperationalAdmin(baseUrl, "mock-key");
    rpcResponse = [
      {
        id: "00000000-0000-4000-8000-000000000001",
        branch_id: "10000000-0000-4000-8000-000000000001",
        category: "stationery",
        item_name: "Pens",
        quantity: 10,
        amount: 20,
        vendor_name: "Store",
        purchase_date: "2026-09-18",
        notes: null,
        payment_status: "unpaid",
        reimbursement_note: null,
        reimbursed_at: null,
        reimbursed_by: null,
        invoice_storage_path: "invoices/failed.pdf",
        invoice_original_name: "failed.pdf",
        invoice_number: null,
        created_by: "20000000-0000-4000-8000-000000000001",
        created_at: "2026-09-18T00:00:00.000Z",
        updated_at: "2026-09-18T00:00:00.000Z",
      },
    ];

    const result = await admin.listPurchaseLogs(
      "20000000-0000-4000-8000-000000000001",
      "10000000-0000-4000-8000-000000000001",
    );

    assert.strictEqual(result.purchase_logs.length, 1);
    assert.strictEqual(result.purchase_logs[0].invoice_url, null);
  });
});
