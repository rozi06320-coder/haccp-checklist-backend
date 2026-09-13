import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { UserContext } from "./user-context";

import { OperationalAccessError } from "./operational";

const ids = {
  maintenance: "19000000-0000-4000-8000-000000000001",
  manager: "19000000-0000-4000-8000-000000000002",
  supervisor: "19000000-0000-4000-8000-000000000003",
  branch: "39000000-0000-4000-8000-000000000001",
  otherBranch: "39000000-0000-4000-8000-000000000002",
  issue: "49000000-0000-4000-8000-000000000001",
} as const;

const contexts: Record<string, UserContext> = {
  maintenance: {
    id: ids.maintenance,
    full_name: "Maintenance User",
    must_change_password: false,
    disabled: false,
    branches: [],
    managed_organizations: [],
  },
  manager: {
    id: ids.manager,
    full_name: "Manager User",
    must_change_password: false,
    disabled: false,
    branches: [],
    managed_organizations: [{ id: "29000000-0000-4000-8000-000000000001", name: "Org", role: "organization_manager" }],
  },
  supervisor: {
    id: ids.supervisor,
    full_name: "Supervisor User",
    must_change_password: false,
    disabled: false,
    branches: [{ id: ids.branch, name: "Assigned Branch", organization_id: "29000000-0000-4000-8000-000000000001", role: "branch_manager" }],
    managed_organizations: [],
  },
};

const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});

function authHeaders(token: string, extra?: Record<string, string>) {
  return {
    Authorization: `Bearer ${token}`,
    ...extra,
  };
}

describe("Supervisor Maintenance submit photo raw middleware scoping", () => {
  let server: Server;
  let baseUrl: string;
  let lastSupervisorCreateInput: Record<string, unknown> | null = null;
  let lastMaintenanceUpdateInput: Record<string, unknown> | null = null;

  before(async () => {
    const dependencies = {
      checkReadiness: async () => true,
      authVerifier: {
        verify: async (token: string) => (contexts[token] ? { userId: contexts[token].id, email: `${token}@example.invalid` } : null),
      },
      createUserContext: (token: string) => ({
        getUserContext: async () => contexts[token] ?? null,
        hasOrganizationManagerAccess: async () => false,
        validateActiveBranches: async () => false,
        listActiveBranches: async () => [],
      }),
      operationalAdmin: {
        listSupervisorMaintenanceIssues: async () => [],
        createSupervisorMaintenanceIssue: async (input: Record<string, unknown>) => {
          lastSupervisorCreateInput = input;
          if (input.branchId !== ids.branch) {
            throw new OperationalAccessError();
          }
          return {
            maintenance_issue: {
              id: ids.issue,
              branch_id: input.branchId,
              branch_name: "Assigned Branch",
              title: (input.payload as Record<string, unknown>)?.title ?? "Test Issue",
              category: (input.payload as Record<string, unknown>)?.category ?? "equipment",
              priority: (input.payload as Record<string, unknown>)?.priority ?? "normal",
              status: "new",
              description: (input.payload as Record<string, unknown>)?.description ?? null,
              location: (input.payload as Record<string, unknown>)?.location ?? null,
              reported_by: input.actorUserId,
              reporter_name: "Supervisor User",
              assigned_to: null,
              responsible_person_name: (input.payload as Record<string, unknown>)?.responsible_person_name ?? null,
              revision: 0,
              planned_repair_date: null,
              created_at: "2026-09-14T00:00:00.000Z",
              updated_at: "2026-09-14T00:00:00.000Z",
              updates: [],
              before_photos: [],
              after_photos: [],
            },
            created: true,
          };
        },
        listMaintenanceIssues: async () => ({ maintenance_issues: [] }),
        updateMaintenanceIssue: async (input: Record<string, unknown>) => {
          lastMaintenanceUpdateInput = input;
          return {
            maintenance_issue: {
              id: input.issueId,
              branch_id: ids.branch,
              branch_name: "Assigned Branch",
              title: "Existing Issue",
              category: "equipment",
              priority: "normal",
              status: input.status,
              description: null,
              location: null,
              reported_by: ids.supervisor,
              reporter_name: "Supervisor User",
              assigned_to: null,
              responsible_person_name: null,
              revision: 1,
              planned_repair_date: null,
              created_at: "2026-09-14T00:00:00.000Z",
              updated_at: "2026-09-14T00:00:00.000Z",
              updates: [],
              before_photos: [],
              after_photos: [],
            },
          };
        },
      },
    } as unknown as BackendDependencies;

    server = createServer(createApp(config, dependencies));
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => resolve());
    });
    const address = server.address() as AddressInfo;
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  after(async () => {
    await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  });

  it("1. application/json photo-less Supervisor Maintenance submit succeeds", async () => {
    lastSupervisorCreateInput = null;
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", {
        "Content-Type": "application/json",
        "X-Maintenance-Contract": "phase1",
      }),
      body: JSON.stringify({
        title: "Broken fryer knob",
        category: "equipment",
        priority: "high",
        description: "The knob is loose and won't turn",
        location: "Kitchen Line 2",
        responsible_person_name: "Ahmed",
      }),
    });

    assert.equal(response.status, 201);
    const body = (await response.json()) as { maintenance_issue: { id: string; title: string; status: string } };
    assert.equal(body.maintenance_issue.id, ids.issue);
    assert.equal(body.maintenance_issue.title, "Broken fryer knob");
    assert.equal(body.maintenance_issue.status, "new");
  });

  it("2. application/json is NOT converted to Buffer by photo raw middleware", async () => {
    assert.ok(lastSupervisorCreateInput !== null);
    assert.equal(typeof lastSupervisorCreateInput.payload, "object");
    assert.ok(!Buffer.isBuffer(lastSupervisorCreateInput.payload));
    assert.deepEqual(lastSupervisorCreateInput.payload, {
      title: "Broken fryer knob",
      category: "equipment",
      priority: "high",
      description: "The knob is loose and won't turn",
      location: "Kitchen Line 2",
      responsible_person_name: "Ahmed",
    });
    assert.deepEqual(lastSupervisorCreateInput.photos, []);
  });

  it("2b. application/json with charset parameter succeeds and is not converted to Buffer", async () => {
    lastSupervisorCreateInput = null;
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", {
        "Content-Type": "application/json; charset=utf-8",
        "X-Maintenance-Contract": "phase1",
      }),
      body: JSON.stringify({
        title: "Cold room gasket torn",
        category: "refrigeration",
        priority: "urgent",
      }),
    });

    assert.equal(response.status, 201);
    assert.ok(lastSupervisorCreateInput !== null);
    assert.ok(!Buffer.isBuffer(lastSupervisorCreateInput.payload));
    assert.equal((lastSupervisorCreateInput.payload as Record<string, unknown>)?.title, "Cold room gasket torn");
  });

  it("3. vendor MIME photo submission still succeeds with raw buffer parsing", async () => {
    lastSupervisorCreateInput = null;
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", {
        "Content-Type": "application/vnd.maintenance-issue+json",
        "X-Maintenance-Contract": "phase1",
      }),
      body: JSON.stringify({
        issue: {
          title: "Leaking prep sink faucet",
          category: "plumbing",
          priority: "normal",
          description: "Drips continuously",
          location: "Prep Area",
        },
        before_photos: [
          {
            original_name: "faucet.jpg",
            mime_type: "image/jpeg",
            content_base64: Buffer.from("fake-jpeg-binary-data").toString("base64"),
          },
        ],
      }),
    });

    assert.equal(response.status, 201);
    assert.ok(lastSupervisorCreateInput !== null);
    assert.equal((lastSupervisorCreateInput.payload as Record<string, unknown>)?.title, "Leaking prep sink faucet");
    const photos = lastSupervisorCreateInput.photos as Array<{ originalName: string; mimeType: string; bytes: Buffer }>;
    assert.equal(photos.length, 1);
    assert.equal(photos[0]?.originalName, "faucet.jpg");
    assert.equal(photos[0]?.mimeType, "image/jpeg");
    assert.ok(Buffer.isBuffer(photos[0]?.bytes));
  });

  it("3b. vendor MIME with charset parameter still succeeds with raw buffer parsing", async () => {
    lastSupervisorCreateInput = null;
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", {
        "Content-Type": "application/vnd.maintenance-issue+json; charset=utf-8",
        "X-Maintenance-Contract": "phase1",
      }),
      body: JSON.stringify({
        issue: {
          title: "Flickering kitchen light",
          category: "electrical",
          priority: "low",
        },
        before_photos: [
          {
            original_name: "light.png",
            mime_type: "image/png",
            content_base64: Buffer.from("fake-png-binary-data").toString("base64"),
          },
        ],
      }),
    });

    assert.equal(response.status, 201);
    assert.ok(lastSupervisorCreateInput !== null);
    assert.equal((lastSupervisorCreateInput.payload as Record<string, unknown>)?.title, "Flickering kitchen light");
    const photos = lastSupervisorCreateInput.photos as Array<{ originalName: string; mimeType: string; bytes: Buffer }>;
    assert.equal(photos.length, 1);
    assert.equal(photos[0]?.originalName, "light.png");
  });

  it("4. unsupported malformed vendor payload still returns 400", async () => {
    // Malformed JSON with vendor MIME
    const malformedJsonResponse = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", {
        "Content-Type": "application/vnd.maintenance-issue+json",
      }),
      body: "{ not-valid-json",
    });
    assert.equal(malformedJsonResponse.status, 400);

    // Missing 'issue' key in vendor envelope
    const missingIssueKeyResponse = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", {
        "Content-Type": "application/vnd.maintenance-issue+json",
      }),
      body: JSON.stringify({
        title: "Missing envelope wrapper",
        category: "equipment",
      }),
    });
    assert.equal(missingIssueKeyResponse.status, 400);

    // Unsupported Content-Type (text/plain)
    const textPlainResponse = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", {
        "Content-Type": "text/plain",
      }),
      body: "plain text body",
    });
    assert.equal(textPlainResponse.status, 400);
  });

  it("5. existing auth/branch authorization still applies", async () => {
    // Missing Authorization header -> 401
    const unauthResponse = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Issue", category: "equipment", priority: "normal" }),
    });
    assert.equal(unauthResponse.status, 401);

    // Manager role forbidden on supervisor route -> 403
    const managerResponse = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("manager", { "Content-Type": "application/json" }),
      body: JSON.stringify({ title: "Issue", category: "equipment", priority: "normal" }),
    });
    assert.equal(managerResponse.status, 403);
  });

  it("6. cross-branch unauthorized request still rejected", async () => {
    const crossBranchResponse = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.otherBranch}/maintenance-issues`, {
      method: "POST",
      headers: authHeaders("supervisor", { "Content-Type": "application/json" }),
      body: JSON.stringify({ title: "Issue", category: "equipment", priority: "normal" }),
    });
    assert.equal(crossBranchResponse.status, 403);
  });

  it("7. no standalone Maintenance behavior changed", async () => {
    // Standalone Maintenance list works for maintenance user
    const maintList = await fetch(`${baseUrl}/api/v1/maintenance/issues`, {
      headers: authHeaders("maintenance"),
    });
    assert.equal(maintList.status, 200);

    // Standalone Maintenance list forbidden for supervisor
    const supervisorStandalone = await fetch(`${baseUrl}/api/v1/maintenance/issues`, {
      headers: authHeaders("supervisor"),
    });
    assert.equal(supervisorStandalone.status, 403);

    // Standalone Maintenance patch works with application/json
    const patchJson = await fetch(`${baseUrl}/api/v1/maintenance/issues/${ids.issue}`, {
      method: "PATCH",
      headers: authHeaders("maintenance", {
        "Content-Type": "application/json",
        "X-Maintenance-Contract": "phase1",
      }),
      body: JSON.stringify({
        status: "in_progress",
        note: "Working on it",
        expected_revision: 0,
        planned_repair_date: null,
      }),
    });
    assert.equal(patchJson.status, 200);
    assert.equal(lastMaintenanceUpdateInput?.status, "in_progress");

    // Standalone Maintenance patch works with vendor MIME
    const patchVendor = await fetch(`${baseUrl}/api/v1/maintenance/issues/${ids.issue}`, {
      method: "PATCH",
      headers: authHeaders("maintenance", {
        "Content-Type": "application/vnd.maintenance-issue+json",
        "X-Maintenance-Contract": "phase1",
      }),
      body: JSON.stringify({
        issue: {
          status: "resolved",
          note: "Fixed",
          expected_revision: 1,
          planned_repair_date: null,
        },
        repair_photos: [
          {
            original_name: "repair.jpg",
            mime_type: "image/jpeg",
            content_base64: Buffer.from("repair-jpeg-data").toString("base64"),
          },
        ],
      }),
    });
    assert.equal(patchVendor.status, 200);
    assert.equal(lastMaintenanceUpdateInput?.status, "resolved");
  });
});
