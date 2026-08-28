import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer, type Server } from "node:http";
import { type AddressInfo } from "node:net";
import { after, describe, it } from "node:test";
import { createOperationalAdmin } from "./operational";

const ids = {
  actor: "10000000-0000-4000-8000-000000000001",
  branch: "10000000-0000-4000-8000-000000000002",
};

const validPng = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x00, 0x49, 0x45, 0x4e, 0x44, 0x00, 0x00, 0x00,
  0x00,
]);

function storageFailureServer() {
  const requests: string[] = [];
  const server = createServer((request, response) => {
    requests.push(request.url ?? "");
    if (request.url?.startsWith("/storage/v1/object/maintenance-issue-photos/")) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ statusCode: "400", error: "InvalidMimeType", message: "not logged" }));
      return;
    }
    response.writeHead(500, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "unexpected_request" }));
  });
  return { server, requests };
}

async function listen(server: Server) {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

async function close(server: Server) {
  await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

describe("Maintenance service_create diagnostics", () => {
  const servers: Server[] = [];
  after(async () => {
    await Promise.allSettled(servers.map(close));
  });

  it("reports the storage upload substage with safe fields only", async () => {
    const fake = storageFailureServer();
    servers.push(fake.server);
    const origin = await listen(fake.server);
    const admin = createOperationalAdmin(origin, "service-key");
    const records: unknown[][] = [];
    const originalInfo = console.info;
    console.info = (...args: unknown[]) => {
      records.push(args);
    };
    try {
      await assert.rejects(() => admin.createSupervisorMaintenanceIssue({
        actorUserId: ids.actor,
        branchId: ids.branch,
        requestId: "diagnostic-request",
        idempotencyKey: randomUUID(),
        payload: { title: "Safe title", category: "equipment", priority: "normal", description: null, location: null },
        photos: [{ bytes: validPng, mimeType: "image/png", originalName: "before.png" }],
      }));
    } finally {
      console.info = originalInfo;
    }

    const serialized = JSON.stringify(records);
    assert.match(serialized, /diagnostic-request/);
    assert.match(serialized, /"stage":"photo_validation"/);
    assert.match(serialized, /"stage":"storage_upload_error"/);
    assert.match(serialized, /"storageErrorStatus":"400"/);
    assert.match(serialized, /"errorName":"StorageApiError"/);
    assert.match(serialized, /"stage":"exception"/);
    assert.match(serialized, /"failedStage":"storage_upload"/);
    assert.doesNotMatch(serialized, /maintenance\/|before\.png|Safe title|not logged|service-key|Bearer/i);
    assert.equal(fake.requests.some((url) => url.startsWith("/rest/v1/rpc/")), false);
  });
});
