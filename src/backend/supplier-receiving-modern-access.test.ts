import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { createOperationalAdmin } from "./operational";

const ids = {
  actor: "10000000-0000-4000-8000-000000000001",
  organization: "20000000-0000-4000-8000-000000000001",
  branch: "30000000-0000-4000-8000-000000000001",
  supplier: "40000000-0000-4000-8000-000000000001",
  receiving: "50000000-0000-4000-8000-000000000001",
} as const;

const timestamp = "2026-10-06T09:00:00.000Z";

async function requestBody(request: IncomingMessage) {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  const bytes = Buffer.concat(chunks);
  if (bytes.length === 0) return null;
  try {
    return JSON.parse(bytes.toString("utf8")) as Record<string, unknown>;
  } catch {
    return bytes;
  }
}

describe("Supplier Receiving modern-only Supervisor response parsing", () => {
  let supabaseServer: Server;
  let apiServer: Server;
  let apiOrigin = "";
  let malformedReceivingResponse = false;
  const events: Array<{ method: string; path: string; body: unknown }> = [];

  before(async () => {
    supabaseServer = createServer(async (request, response) => {
      const path = request.url ?? "";
      const body = await requestBody(request);
      events.push({ method: request.method ?? "", path, body });
      response.setHeader("content-type", "application/json");

      if (request.method === "POST" && path.startsWith("/storage/v1/object/branch-supplier-receiving-photos/")) {
        response.end(JSON.stringify({ Key: "uploaded" }));
        return;
      }
      if (request.method === "DELETE" && path === "/storage/v1/object/branch-supplier-receiving-photos") {
        response.end(JSON.stringify([]));
        return;
      }
      if (request.method === "POST" && path === "/rest/v1/rpc/create_branch_supplier") {
        response.end(JSON.stringify([{
          id: ids.supplier,
          organization_id: ids.organization,
          branch_id: ids.branch,
          supervisor_team_id: null,
          supplier_name_en: "Modern Supplier",
          supplier_name_ar: null,
          created_by: ids.actor,
          created_at: timestamp,
          updated_at: timestamp,
        }]));
        return;
      }
      if (request.method === "POST" && path === "/rest/v1/rpc/create_branch_supplier_receiving") {
        const rpcBody = body as { payload?: { photo_storage_path?: string | null; photo_original_name?: string | null } };
        response.end(JSON.stringify([{
          id: ids.receiving,
          organization_id: ids.organization,
          branch_id: ids.branch,
          supervisor_team_id: null,
          supplier_id: ids.supplier,
          category: "raw",
          supplier_name_en: "Modern Supplier",
          supplier_name_ar: null,
          piv_pos: null,
          quantity: "2.500",
          unit: "kg",
          notes: null,
          photo_storage_path: rpcBody.payload?.photo_storage_path ?? null,
          photo_original_name: rpcBody.payload?.photo_original_name ?? null,
          created_by: malformedReceivingResponse ? null : ids.actor,
          created_at: timestamp,
          updated_at: timestamp,
        }]));
        return;
      }

      response.statusCode = 404;
      response.end(JSON.stringify({ message: "unexpected test request" }));
    });
    await new Promise<void>((resolve, reject) => supabaseServer.listen(0, "127.0.0.1", resolve).once("error", reject));
    const supabaseOrigin = `http://127.0.0.1:${(supabaseServer.address() as AddressInfo).port}`;
    const operationalAdmin = createOperationalAdmin(supabaseOrigin, "test-service-role-key");
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: supabaseOrigin,
      SUPABASE_PUBLISHABLE_KEY: "test-publishable-key",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    const dependencies = {
      checkReadiness: async () => true,
      authVerifier: {
        async verify(token: string) {
          return token === "modern-supervisor" ? { userId: ids.actor, email: "modern@example.invalid" } : null;
        },
      },
      createUserContext: () => ({
        async getUserContext() {
          return {
            id: ids.actor,
            full_name: "Modern Supervisor",
            disabled: false,
            must_change_password: false,
            branches: [{ id: ids.branch, name: "Branch", organization_id: ids.organization, role: "branch_manager" }],
            managed_organizations: [],
          };
        },
      }),
      operationalAdmin,
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

  beforeEach(() => {
    malformedReceivingResponse = false;
    events.length = 0;
  });

  it("returns 201 when a modern-only Supervisor creates a receiving with null legacy attribution", async () => {
    const response = await fetch(`${apiOrigin}/api/v1/supervisor/branches/${ids.branch}/supplier-receivings`, {
      method: "POST",
      headers: { authorization: "Bearer modern-supervisor", "content-type": "application/json" },
      body: JSON.stringify({ category: "raw", supplier_id: ids.supplier, quantity: 2.5, unit: "kg" }),
    });

    assert.equal(response.status, 201);
    const body = await response.json() as { supplier_receiving: Record<string, unknown> };
    assert.equal(body.supplier_receiving.id, ids.receiving);
    assert.equal(body.supplier_receiving.quantity, 2.5);
    assert.equal("supervisor_team_id" in body.supplier_receiving, false);
    assert.equal("organization_id" in body.supplier_receiving, false);
    assert.equal("photo_storage_path" in body.supplier_receiving, false);
    assert.doesNotMatch(JSON.stringify(body), /service_unavailable/);
  });

  it("returns 201 when a modern-only Supervisor creates a supplier with null legacy attribution", async () => {
    const response = await fetch(`${apiOrigin}/api/v1/supervisor/branches/${ids.branch}/suppliers`, {
      method: "POST",
      headers: { authorization: "Bearer modern-supervisor", "content-type": "application/json" },
      body: JSON.stringify({ supplier_name_en: "Modern Supplier", supplier_name_ar: null }),
    });

    assert.equal(response.status, 201);
    const body = await response.json() as { supplier: Record<string, unknown> };
    assert.equal(body.supplier.id, ids.supplier);
    assert.equal("supervisor_team_id" in body.supplier, false);
    assert.equal("organization_id" in body.supplier, false);
    assert.equal("created_by" in body.supplier, false);
    assert.doesNotMatch(JSON.stringify(body), /service_unavailable/);
  });

  it("documents that a post-RPC parser failure cleans storage but cannot roll back the committed row", async () => {
    malformedReceivingResponse = true;
    const operationalAdmin = createOperationalAdmin(
      `http://127.0.0.1:${(supabaseServer.address() as AddressInfo).port}`,
      "test-service-role-key",
    );

    await assert.rejects(() => operationalAdmin.createSupplierReceiving({
      actorUserId: ids.actor,
      branchId: ids.branch,
      payload: { category: "raw", supplier_id: ids.supplier, quantity: 2.5, unit: "kg" },
      photo: {
        bytes: Buffer.from([0xff, 0xd8, 0xff, 0x00, 0xff, 0xd9]),
        mimeType: "image/jpeg",
        originalName: "receiving.jpg",
      },
    }));

    const uploadIndex = events.findIndex((event) => event.method === "POST" && event.path.startsWith("/storage/v1/object/branch-supplier-receiving-photos/"));
    const rpcIndex = events.findIndex((event) => event.path === "/rest/v1/rpc/create_branch_supplier_receiving");
    const cleanupIndex = events.findIndex((event) => event.method === "DELETE" && event.path === "/storage/v1/object/branch-supplier-receiving-photos");
    assert.ok(uploadIndex >= 0 && rpcIndex > uploadIndex && cleanupIndex > rpcIndex);

    const rpcPayload = events[rpcIndex]?.body as { payload: { photo_storage_path: string } };
    const cleanupPayload = events[cleanupIndex]?.body as { prefixes: string[] };
    assert.ok(rpcPayload.payload.photo_storage_path);
    assert.deepEqual(cleanupPayload.prefixes, [rpcPayload.payload.photo_storage_path]);
  });
});
