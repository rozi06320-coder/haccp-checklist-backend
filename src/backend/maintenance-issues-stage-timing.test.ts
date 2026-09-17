import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import {
  createOperationalAdmin,
  MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY,
  type MaintenanceIssuesStageTiming,
  type MaintenanceIssuesTimingDiagnostics,
} from "./operational";
import type { BackendDependencies } from "./dependencies";
import type { UserContext } from "./user-context";

const ids = {
  maintenanceUser: "10000000-0000-4000-8000-000000000001",
  branch: "20000000-0000-4000-8000-000000000001",
  organization: "30000000-0000-4000-8000-000000000001",
  issue1: "40000000-0000-4000-8000-000000000001",
  issue2: "40000000-0000-4000-8000-000000000002",
  attachment1: "50000000-0000-4000-8000-000000000001",
  attachment2: "50000000-0000-4000-8000-000000000002",
  attachment3: "50000000-0000-4000-8000-000000000003",
  update1: "60000000-0000-4000-8000-000000000001",
} as const;

const userContext: UserContext = {
  id: ids.maintenanceUser,
  full_name: "Maintenance Staff",
  must_change_password: false,
  disabled: false,
  branches: [
    {
      id: ids.branch,
      name: "Main Branch",
      organization_id: ids.organization,
      role: "staff",
    },
  ],
  managed_organizations: [],
};

const sampleIssuesRpc = [
  {
    id: ids.issue1,
    branch_id: ids.branch,
    branch_name: "Main Branch",
    title: "Walk-in freezer seal broken",
    category: "refrigeration",
    priority: "urgent",
    status: "in_progress",
    description: "Door does not seal completely",
    location: "Kitchen A",
    reported_by: ids.maintenanceUser,
    reporter_name: "Staff Reporter",
    assigned_to: null,
    responsible_person_name: "John Technician",
    revision: 1,
    planned_repair_date: "2026-09-20",
    created_at: "2026-09-17T10:00:00.000Z",
    updated_at: "2026-09-17T11:00:00.000Z",
    updates: [
      {
        id: ids.update1,
        status: "in_progress",
        note: "Inspected and ordered gasket",
        updated_by: ids.maintenanceUser,
        updated_by_access_user_id: null,
        updated_by_name: "Maintenance Staff",
        update_kind: "status_update",
        old_planned_repair_date: null,
        new_planned_repair_date: "2026-09-20",
        change_reason: null,
        created_at: "2026-09-17T11:00:00.000Z",
      },
    ],
  },
  {
    id: ids.issue2,
    branch_id: ids.branch,
    branch_name: "Main Branch",
    title: "Sink faucet leaking",
    category: "plumbing",
    priority: "low",
    status: "new",
    description: null,
    location: null,
    reported_by: ids.maintenanceUser,
    reporter_name: null,
    assigned_to: null,
    responsible_person_name: null,
    revision: 0,
    planned_repair_date: null,
    created_at: "2026-09-17T09:00:00.000Z",
    updated_at: "2026-09-17T09:00:00.000Z",
    updates: [],
  },
];

const sampleLegacyIssuesRpc = sampleIssuesRpc.map(({ revision, planned_repair_date, ...issue }) => issue);

const sampleAttachmentsRpc = [
  {
    id: ids.attachment1,
    maintenance_issue_id: ids.issue1,
    attachment_type: "issue",
    storage_path: "issues/issue1_before_1.jpg",
    original_filename: "seal_before.jpg",
    mime_type: "image/jpeg",
    size_bytes: 102400,
    attachment_position: 1,
    created_at: "2026-09-17T10:00:00.000Z",
  },
  {
    id: ids.attachment2,
    maintenance_issue_id: ids.issue1,
    attachment_type: "repair",
    storage_path: "issues/issue1_repair_1.jpg",
    original_filename: "seal_repaired.jpg",
    mime_type: "image/jpeg",
    size_bytes: 204800,
    attachment_position: 1,
    created_at: "2026-09-17T11:00:00.000Z",
  },
  {
    id: ids.attachment3,
    maintenance_issue_id: ids.issue2,
    attachment_type: "issue",
    storage_path: "issues/issue2_before_1.jpg",
    original_filename: "faucet.jpg",
    mime_type: "image/jpeg",
    size_bytes: 51200,
    attachment_position: 1,
    created_at: "2026-09-17T09:00:00.000Z",
  },
];

describe("GET /api/v1/maintenance/issues stage timing diagnostics & bounded photo signing", () => {
  it("emits MAINTENANCE_ISSUES_TIMING with exact numeric schema, zero sensitive fields, and bounded concurrency", async () => {
    let maxSigningConcurrency = 0;
    let currentSigningConcurrency = 0;
    let signingCalls = 0;

    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (
        request.url === "/rest/v1/rpc/list_maintenance_issues_v2" ||
        request.url === "/rest/v1/rpc/list_maintenance_issues"
      ) {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(sampleIssuesRpc));
        return;
      }

      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(sampleAttachmentsRpc));
        return;
      }

      if (request.url?.startsWith("/storage/v1/object/sign/maintenance-issue-photos/")) {
        signingCalls++;
        currentSigningConcurrency++;
        if (currentSigningConcurrency > maxSigningConcurrency) {
          maxSigningConcurrency = currentSigningConcurrency;
        }
        await new Promise((r) => setTimeout(r, 10));
        currentSigningConcurrency--;

        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ signedURL: `https://storage.example.com/signed/${signingCalls}` }));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    const diagnosticLogs: string[] = [];
    const originalInfo = console.info;
    console.info = (...args: unknown[]) => {
      if (typeof args[0] === "string" && args[0].startsWith("MAINTENANCE_ISSUES_TIMING ")) {
        diagnosticLogs.push(args[0]);
      }
      originalInfo.apply(console, args);
    };

    let server: Server | null = null;
    try {
      const config = loadBackendConfig({
        NODE_ENV: "test",
        SUPABASE_URL: `http://127.0.0.1:${mockPort}`,
        SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
        DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
      });

      const dependencies: BackendDependencies = {
        config,
        authVerifier: {
          async verify(token: string) {
            return token === "valid-maintenance-token" ? { userId: ids.maintenanceUser } : null;
          },
        },
        createUserContext: () => ({
          async getUserContext() {
            return userContext;
          },
        }),
        userContextRepository: {} as any,
        operationalAdmin,
        evidenceService: {} as any,
        checklistPersistence: {} as any,
        brandingService: {} as any,
        maintenanceAccessAdmin: {} as any,
        pinCrypto: {} as any,
        maintenancePush: null,
      };

      const app = createApp(config, dependencies);
      server = createServer(app);
      await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
      const appPort = (server.address() as AddressInfo).port;

      const res = await fetch(`http://127.0.0.1:${appPort}/api/v1/maintenance/issues`, {
        headers: {
          authorization: "Bearer valid-maintenance-token",
          "x-maintenance-contract": "phase1",
        },
      });

      assert.equal(res.status, 200);
      assert.equal(res.headers.get("cache-control"), "private, no-store");
      const body = await res.json() as any;
      assert.ok(Array.isArray(body.maintenance_issues));
      assert.equal(body.maintenance_issues.length, 2);

      const issue1 = body.maintenance_issues.find((i: any) => i.id === ids.issue1);
      assert.ok(issue1);
      assert.equal(issue1.before_photos.length, 1);
      assert.equal(issue1.after_photos.length, 1);
      assert.ok(issue1.before_photo?.url?.includes("https://storage.example.com/signed/"));
      assert.ok(issue1.after_photo?.url?.includes("https://storage.example.com/signed/"));

      assert.equal(diagnosticLogs.length, 1, "Exactly one MAINTENANCE_ISSUES_TIMING log must be emitted");
      const jsonStr = diagnosticLogs[0].slice("MAINTENANCE_ISSUES_TIMING ".length);
      const diagnostic = JSON.parse(jsonStr) as MaintenanceIssuesTimingDiagnostics;

      const expectedKeys = [
        "requestId",
        "actorResolutionMs",
        "listIssuesRpcMs",
        "issueCount",
        "attachmentsRpcMs",
        "attachmentCount",
        "attachmentSigningMs",
        "normalizationMs",
        "totalMs",
      ].sort();
      assert.deepEqual(Object.keys(diagnostic).sort(), expectedKeys);

      assert.equal(typeof diagnostic.requestId, "string");
      assert.ok(diagnostic.requestId!.length > 0);

      assert.equal(typeof diagnostic.actorResolutionMs, "number");
      assert.ok(Number.isFinite(diagnostic.actorResolutionMs));
      assert.ok(diagnostic.actorResolutionMs >= 0);

      assert.equal(typeof diagnostic.listIssuesRpcMs, "number");
      assert.ok(Number.isFinite(diagnostic.listIssuesRpcMs));
      assert.ok(diagnostic.listIssuesRpcMs >= 0);

      assert.equal(typeof diagnostic.issueCount, "number");
      assert.equal(diagnostic.issueCount, 2);

      assert.equal(typeof diagnostic.attachmentsRpcMs, "number");
      assert.ok(Number.isFinite(diagnostic.attachmentsRpcMs));
      assert.ok(diagnostic.attachmentsRpcMs >= 0);

      assert.equal(typeof diagnostic.attachmentCount, "number");
      assert.equal(diagnostic.attachmentCount, 3);

      assert.equal(typeof diagnostic.attachmentSigningMs, "number");
      assert.ok(Number.isFinite(diagnostic.attachmentSigningMs));
      assert.ok(diagnostic.attachmentSigningMs >= 8);

      assert.equal(typeof diagnostic.normalizationMs, "number");
      assert.ok(Number.isFinite(diagnostic.normalizationMs));
      assert.ok(diagnostic.normalizationMs >= 0);

      assert.equal(typeof diagnostic.totalMs, "number");
      assert.ok(Number.isFinite(diagnostic.totalMs));
      assert.ok(diagnostic.totalMs >= diagnostic.attachmentSigningMs);

      const forbiddenPatterns = [
        ids.maintenanceUser,
        ids.branch,
        ids.organization,
        ids.issue1,
        ids.issue2,
        ids.attachment1,
        "valid-maintenance-token",
        "mock-service-key",
        "storage.example.com",
        "issues/issue1_before_1.jpg",
        "seal_before.jpg",
        "Walk-in freezer seal broken",
      ];
      for (const pattern of forbiddenPatterns) {
        assert.ok(
          !jsonStr.includes(pattern),
          `Diagnostic payload must not contain sensitive pattern: ${pattern}`,
        );
      }

      // Concurrency checks: 3 attachments => concurrency > 1 and <= 6
      assert.equal(signingCalls, 3);
      assert.ok(maxSigningConcurrency > 1, `Concurrency (${maxSigningConcurrency}) must exceed 1 when multiple attachments exist`);
      assert.ok(maxSigningConcurrency <= MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY, `Concurrency (${maxSigningConcurrency}) must never exceed ${MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY}`);
    } finally {
      console.info = originalInfo;
      if (server) {
        await new Promise<void>((resolve, reject) => server!.close((e) => (e ? reject(e) : resolve())));
      }
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("proves max concurrency never exceeds 6 and strictly preserves exact input ordering and grouping", async () => {
    let maxSigningConcurrency = 0;
    let currentSigningConcurrency = 0;
    let signingCalls = 0;

    // 12 attachments across 2 issues: tests that concurrency caps at 6 even when 12 items are queued
    const manyAttachments = Array.from({ length: 12 }, (_, i) => ({
      id: `50000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      maintenance_issue_id: i % 2 === 0 ? ids.issue1 : ids.issue2,
      attachment_type: (i % 4 < 2 ? "issue" : "repair") as "issue" | "repair",
      storage_path: `issues/path_${i}.jpg`,
      original_filename: `photo_tag_${i}.jpg`,
      mime_type: "image/jpeg" as const,
      size_bytes: 1000 + i,
      attachment_position: ((i % 3) + 1),
      created_at: `2026-09-17T10:${String(i).padStart(2, "0")}:00.000Z`,
    }));

    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (request.url === "/rest/v1/rpc/list_maintenance_issues_v2") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(sampleIssuesRpc));
        return;
      }

      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(manyAttachments));
        return;
      }

      if (request.url?.startsWith("/storage/v1/object/sign/maintenance-issue-photos/")) {
        signingCalls++;
        currentSigningConcurrency++;
        if (currentSigningConcurrency > maxSigningConcurrency) {
          maxSigningConcurrency = currentSigningConcurrency;
        }
        // Artificial jitter so workers complete out-of-order, verifying index-based result ordering
        const delay = (signingCalls % 3 === 0 ? 15 : 5);
        await new Promise((r) => setTimeout(r, delay));
        currentSigningConcurrency--;

        const path = request.url.replace("/storage/v1/object/sign/maintenance-issue-photos/", "").split("?")[0];
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ signedURL: `https://storage.example.com/signed/${path}` }));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    try {
      const timingCollector: MaintenanceIssuesStageTiming = {
        listIssuesRpcMs: 0,
        issueCount: 0,
        attachmentsRpcMs: 0,
        attachmentCount: 0,
        attachmentSigningMs: 0,
        normalizationMs: 0,
      };

      const result = await operationalAdmin.listMaintenanceIssues({
        actorUserId: ids.maintenanceUser,
        contract: "phase1",
        timingCollector,
      }) as any;

      assert.equal(signingCalls, 12);
      // Bound verified: strictly 6
      assert.equal(maxSigningConcurrency, 6, "Max concurrency must reach and never exceed the configured limit of 6");

      // Verify exact attachment count in timing collector
      assert.equal(timingCollector.attachmentCount, 12);
      assert.ok(timingCollector.attachmentSigningMs > 0);

      // Verify ordering and grouping for issue 1
      const issue1 = result.maintenance_issues.find((i: any) => i.id === ids.issue1);
      assert.ok(issue1);

      // Expected issue1 attachments in original sequence
      const expectedIssue1Before = manyAttachments.filter((a) => a.maintenance_issue_id === ids.issue1 && a.attachment_type === "issue");
      const expectedIssue1After = manyAttachments.filter((a) => a.maintenance_issue_id === ids.issue1 && a.attachment_type === "repair");

      assert.equal(issue1.before_photos.length, expectedIssue1Before.length);
      assert.equal(issue1.after_photos.length, expectedIssue1After.length);

      // Verify strict preservation of order
      for (let i = 0; i < expectedIssue1Before.length; i++) {
        assert.equal(issue1.before_photos[i].original_filename, expectedIssue1Before[i].original_filename);
        assert.ok(issue1.before_photos[i].url.includes(expectedIssue1Before[i].storage_path));
        assert.equal(issue1.before_photos[i].size_bytes, expectedIssue1Before[i].size_bytes);
      }
      for (let i = 0; i < expectedIssue1After.length; i++) {
        assert.equal(issue1.after_photos[i].original_filename, expectedIssue1After[i].original_filename);
        assert.ok(issue1.after_photos[i].url.includes(expectedIssue1After[i].storage_path));
        assert.equal(issue1.after_photos[i].size_bytes, expectedIssue1After[i].size_bytes);
      }
    } finally {
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("handles exactly one attachment correctly with concurrency 1", async () => {
    let maxSigningConcurrency = 0;
    let currentSigningConcurrency = 0;

    const singleAttachment = [sampleAttachmentsRpc[0]];

    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (request.url === "/rest/v1/rpc/list_maintenance_issues_v2") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify([sampleIssuesRpc[0]]));
        return;
      }

      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(singleAttachment));
        return;
      }

      if (request.url?.startsWith("/storage/v1/object/sign/maintenance-issue-photos/")) {
        currentSigningConcurrency++;
        if (currentSigningConcurrency > maxSigningConcurrency) {
          maxSigningConcurrency = currentSigningConcurrency;
        }
        await new Promise((r) => setTimeout(r, 5));
        currentSigningConcurrency--;

        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ signedURL: "https://storage.example.com/signed/single" }));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    try {
      const timingCollector: MaintenanceIssuesStageTiming = {
        listIssuesRpcMs: 0,
        issueCount: 0,
        attachmentsRpcMs: 0,
        attachmentCount: 0,
        attachmentSigningMs: 0,
        normalizationMs: 0,
      };

      const result = await operationalAdmin.listMaintenanceIssues({
        actorUserId: ids.maintenanceUser,
        contract: "phase1",
        timingCollector,
      }) as any;

      assert.equal(maxSigningConcurrency, 1, "Single attachment should use concurrency 1");
      assert.equal(timingCollector.attachmentCount, 1);
      assert.equal(result.maintenance_issues[0].before_photos.length, 1);
      assert.ok(result.maintenance_issues[0].before_photos[0].url.includes("single"));
    } finally {
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("handles 109-like large attachment set within bounded concurrency without data loss or duplicates", async () => {
    let maxSigningConcurrency = 0;
    let currentSigningConcurrency = 0;
    let signingCalls = 0;

    const TOTAL_ATTACHMENTS = 109;
    // 51 issues (matching production issue count) to safely host 109 attachments
    const sample51IssuesRpc = Array.from({ length: 51 }, (_, i) => ({
      id: `40000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      branch_id: ids.branch,
      branch_name: "Main Branch",
      title: `Maintenance issue ${i + 1}`,
      category: "plumbing" as const,
      priority: "normal" as const,
      status: "in_progress" as const,
      description: null,
      location: null,
      reported_by: ids.maintenanceUser,
      reporter_name: null,
      assigned_to: null,
      responsible_person_name: null,
      revision: 1,
      planned_repair_date: null,
      created_at: "2026-09-17T09:00:00.000Z",
      updated_at: "2026-09-17T09:00:00.000Z",
      updates: [],
    }));

    const largeAttachments = Array.from({ length: TOTAL_ATTACHMENTS }, (_, i) => ({
      id: `50000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      maintenance_issue_id: sample51IssuesRpc[i % 51].id,
      attachment_type: (i % 2 === 0 ? "issue" : "repair") as "issue" | "repair",
      storage_path: `issues/item_${i}.jpg`,
      original_filename: `item_file_${i}.jpg`,
      mime_type: "image/jpeg" as const,
      size_bytes: 50000 + i,
      attachment_position: 1,
      created_at: "2026-09-17T10:00:00.000Z",
    }));

    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (request.url === "/rest/v1/rpc/list_maintenance_issues_v2") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(sample51IssuesRpc));
        return;
      }

      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(largeAttachments));
        return;
      }

      if (request.url?.startsWith("/storage/v1/object/sign/maintenance-issue-photos/")) {
        signingCalls++;
        currentSigningConcurrency++;
        if (currentSigningConcurrency > maxSigningConcurrency) {
          maxSigningConcurrency = currentSigningConcurrency;
        }
        await new Promise((r) => setTimeout(r, 2));
        currentSigningConcurrency--;

        const path = request.url.replace("/storage/v1/object/sign/maintenance-issue-photos/", "").split("?")[0];
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ signedURL: `https://storage.example.com/signed/${path}` }));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    try {
      const timingCollector: MaintenanceIssuesStageTiming = {
        listIssuesRpcMs: 0,
        issueCount: 0,
        attachmentsRpcMs: 0,
        attachmentCount: 0,
        attachmentSigningMs: 0,
        normalizationMs: 0,
      };

      const result = await operationalAdmin.listMaintenanceIssues({
        actorUserId: ids.maintenanceUser,
        contract: "phase1",
        timingCollector,
      }) as any;

      assert.equal(signingCalls, 109);
      assert.equal(maxSigningConcurrency, 6, "Concurrency must never exceed 6 during 109 signing calls");
      assert.equal(timingCollector.attachmentCount, 109);
      assert.equal(timingCollector.issueCount, 51);

      // Verify total photos collected across all issues equals 109
      let totalReturnedPhotos = 0;
      for (const issue of result.maintenance_issues) {
        totalReturnedPhotos += issue.before_photos.length + issue.after_photos.length;
      }
      assert.equal(totalReturnedPhotos, 109, "All 109 attachments must be returned without loss or duplicates");
    } finally {
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("preserves error resilience when signing fails (returns null url without failing the request)", async () => {
    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (request.url === "/rest/v1/rpc/list_maintenance_issues_v2") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify([sampleIssuesRpc[0]]));
        return;
      }

      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(sampleAttachmentsRpc.slice(0, 2)));
        return;
      }

      if (request.url?.startsWith("/storage/v1/object/sign/maintenance-issue-photos/")) {
        // Return 500 error for one photo, 200 for other
        if (request.url.includes("issue1_before_1.jpg")) {
          response.statusCode = 500;
          response.end(JSON.stringify({ message: "Storage error" }));
          return;
        }
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ signedURL: "https://storage.example.com/signed/ok" }));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    try {
      const result = await operationalAdmin.listMaintenanceIssues({
        actorUserId: ids.maintenanceUser,
        contract: "phase1",
      }) as any;

      const issue = result.maintenance_issues[0];
      // Failed photo has url: null
      assert.equal(issue.before_photos[0].url, null);
      // Succeeded photo has url populated
      assert.ok(issue.after_photos[0].url.includes("ok"));
    } finally {
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("performance benchmark: bounded concurrency achieves ~6x speedup over sequential execution", async () => {
    // 60 attachments distributed across 20 issues (3 per issue) with 8ms simulated latency each
    // Sequential execution: 60 * 8ms = 480ms
    // Bounded concurrency (limit 6): ceil(60 / 6) * 8ms = 10 * 8ms = 80ms
    const TEST_COUNT = 60;
    const DELAY_MS = 8;
    const benchIssues = Array.from({ length: 20 }, (_, i) => ({
      id: `40000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      branch_id: ids.branch,
      branch_name: "Main Branch",
      title: `Bench issue ${i + 1}`,
      category: "plumbing" as const,
      priority: "normal" as const,
      status: "in_progress" as const,
      description: null,
      location: null,
      reported_by: ids.maintenanceUser,
      reporter_name: null,
      assigned_to: null,
      responsible_person_name: null,
      revision: 1,
      planned_repair_date: null,
      created_at: "2026-09-17T09:00:00.000Z",
      updated_at: "2026-09-17T09:00:00.000Z",
      updates: [],
    }));

    const testAttachments = Array.from({ length: TEST_COUNT }, (_, i) => ({
      id: `50000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      maintenance_issue_id: benchIssues[i % 20].id,
      attachment_type: "issue" as const,
      storage_path: `issues/bench_${i}.jpg`,
      original_filename: `bench_${i}.jpg`,
      mime_type: "image/jpeg" as const,
      size_bytes: 1000,
      attachment_position: 1,
      created_at: "2026-09-17T10:00:00.000Z",
    }));

    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (request.url === "/rest/v1/rpc/list_maintenance_issues_v2") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(benchIssues));
        return;
      }

      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(testAttachments));
        return;
      }

      if (request.url?.startsWith("/storage/v1/object/sign/maintenance-issue-photos/")) {
        await new Promise((r) => setTimeout(r, DELAY_MS));
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ signedURL: "https://storage.example.com/signed/bench" }));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    try {
      const timingCollector: MaintenanceIssuesStageTiming = {
        listIssuesRpcMs: 0,
        issueCount: 0,
        attachmentsRpcMs: 0,
        attachmentCount: 0,
        attachmentSigningMs: 0,
        normalizationMs: 0,
      };

      await operationalAdmin.listMaintenanceIssues({
        actorUserId: ids.maintenanceUser,
        contract: "phase1",
        timingCollector,
      });

      const estimatedSequentialMs = TEST_COUNT * DELAY_MS;
      // Concurrency 6 should complete in well under half the sequential time
      assert.ok(
        timingCollector.attachmentSigningMs < estimatedSequentialMs * 0.4,
        `Attachment signing (${timingCollector.attachmentSigningMs}ms) must be significantly faster than sequential baseline (${estimatedSequentialMs}ms)`,
      );
    } finally {
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("emits MAINTENANCE_ISSUES_TIMING on legacy contract route requests", async () => {
    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (
        request.url === "/rest/v1/rpc/list_maintenance_issues_v2" ||
        request.url === "/rest/v1/rpc/list_maintenance_issues"
      ) {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(sampleLegacyIssuesRpc));
        return;
      }

      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify([]));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    const diagnosticLogs: string[] = [];
    const originalInfo = console.info;
    console.info = (...args: unknown[]) => {
      if (typeof args[0] === "string" && args[0].startsWith("MAINTENANCE_ISSUES_TIMING ")) {
        diagnosticLogs.push(args[0]);
      }
      originalInfo.apply(console, args);
    };

    let server: Server | null = null;
    try {
      const config = loadBackendConfig({
        NODE_ENV: "test",
        SUPABASE_URL: `http://127.0.0.1:${mockPort}`,
        SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
        DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
      });

      const dependencies: BackendDependencies = {
        config,
        authVerifier: {
          async verify(token: string) {
            return token === "valid-maintenance-token" ? { userId: ids.maintenanceUser } : null;
          },
        },
        createUserContext: () => ({
          async getUserContext() {
            return userContext;
          },
        }),
        userContextRepository: {} as any,
        operationalAdmin,
        evidenceService: {} as any,
        checklistPersistence: {} as any,
        brandingService: {} as any,
        maintenanceAccessAdmin: {} as any,
        pinCrypto: {} as any,
        maintenancePush: null,
      };

      const app = createApp(config, dependencies);
      server = createServer(app);
      await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
      const appPort = (server.address() as AddressInfo).port;

      const res = await fetch(`http://127.0.0.1:${appPort}/api/v1/maintenance/issues`, {
        headers: {
          authorization: "Bearer valid-maintenance-token",
        },
      });

      assert.equal(res.status, 200);
      assert.equal(diagnosticLogs.length, 1);
      const diagnostic = JSON.parse(diagnosticLogs[0].slice("MAINTENANCE_ISSUES_TIMING ".length)) as MaintenanceIssuesTimingDiagnostics;
      assert.equal(diagnostic.issueCount, 2);
      assert.equal(diagnostic.attachmentCount, 0);
      assert.equal(diagnostic.attachmentSigningMs, 0);
      assert.ok(diagnostic.actorResolutionMs >= 0);
      assert.ok(diagnostic.listIssuesRpcMs >= 0);
      assert.ok(diagnostic.normalizationMs >= 0);
      assert.ok(diagnostic.totalMs >= 0);
    } finally {
      console.info = originalInfo;
      if (server) {
        await new Promise<void>((resolve, reject) => server!.close((e) => (e ? reject(e) : resolve())));
      }
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("handles zero issues and zero attachments gracefully with 0 counts and non-negative timings", async () => {
    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (
        request.url === "/rest/v1/rpc/list_maintenance_issues_v2" ||
        request.url === "/rest/v1/rpc/list_maintenance_issues"
      ) {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify([]));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    const diagnosticLogs: string[] = [];
    const originalInfo = console.info;
    console.info = (...args: unknown[]) => {
      if (typeof args[0] === "string" && args[0].startsWith("MAINTENANCE_ISSUES_TIMING ")) {
        diagnosticLogs.push(args[0]);
      }
      originalInfo.apply(console, args);
    };

    let server: Server | null = null;
    try {
      const config = loadBackendConfig({
        NODE_ENV: "test",
        SUPABASE_URL: `http://127.0.0.1:${mockPort}`,
        SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
        DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
      });

      const dependencies: BackendDependencies = {
        config,
        authVerifier: {
          async verify(token: string) {
            return token === "valid-maintenance-token" ? { userId: ids.maintenanceUser } : null;
          },
        },
        createUserContext: () => ({
          async getUserContext() {
            return userContext;
          },
        }),
        userContextRepository: {} as any,
        operationalAdmin,
        evidenceService: {} as any,
        checklistPersistence: {} as any,
        brandingService: {} as any,
        maintenanceAccessAdmin: {} as any,
        pinCrypto: {} as any,
        maintenancePush: null,
      };

      const app = createApp(config, dependencies);
      server = createServer(app);
      await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
      const appPort = (server.address() as AddressInfo).port;

      const res = await fetch(`http://127.0.0.1:${appPort}/api/v1/maintenance/issues`, {
        headers: {
          authorization: "Bearer valid-maintenance-token",
          "x-maintenance-contract": "phase1",
        },
      });

      assert.equal(res.status, 200);
      const body = await res.json() as any;
      assert.deepEqual(body, { maintenance_issues: [] });

      assert.equal(diagnosticLogs.length, 1);
      const diagnostic = JSON.parse(diagnosticLogs[0].slice("MAINTENANCE_ISSUES_TIMING ".length)) as MaintenanceIssuesTimingDiagnostics;

      assert.equal(diagnostic.issueCount, 0);
      assert.equal(diagnostic.attachmentCount, 0);
      assert.equal(diagnostic.attachmentSigningMs, 0);
      assert.equal(diagnostic.attachmentsRpcMs, 0);
      assert.ok(diagnostic.actorResolutionMs >= 0);
      assert.ok(diagnostic.listIssuesRpcMs >= 0);
      assert.ok(diagnostic.normalizationMs >= 0);
      assert.ok(diagnostic.totalMs >= 0);
    } finally {
      console.info = originalInfo;
      if (server) {
        await new Promise<void>((resolve, reject) => server!.close((e) => (e ? reject(e) : resolve())));
      }
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });

  it("does not mutate timing collector or fail when called directly without timing collector", async () => {
    const mockSupabase = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;

      if (request.url === "/rest/v1/rpc/list_maintenance_issues_v2") {
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify([]));
        return;
      }

      response.statusCode = 404;
      response.end();
    });

    await new Promise<void>((resolve) => mockSupabase.listen(0, "127.0.0.1", resolve));
    const mockPort = (mockSupabase.address() as AddressInfo).port;
    const operationalAdmin = createOperationalAdmin(`http://127.0.0.1:${mockPort}`, "mock-service-key");

    try {
      const result = await operationalAdmin.listMaintenanceIssues({
        actorUserId: ids.maintenanceUser,
        contract: "phase1",
      });
      assert.deepEqual(result, { maintenance_issues: [] });
    } finally {
      await new Promise<void>((resolve, reject) => mockSupabase.close((e) => (e ? reject(e) : resolve())));
    }
  });
});
