import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { createChecklistPersistence, ManagementOverviewUnavailableError } from "./checklist-persistence";

const actor = "11000000-0000-4000-8000-000000000002";
const organization = "31000000-0000-4000-8000-000000000001";
const branch = "21000000-0000-4000-8000-000000000001";
const businessDate = "2026-10-30";

let server: Server | undefined;

async function withRpcServer(
  handler: (rpc: string) => { status: number; body: unknown },
): Promise<string> {
  server = createServer(async (request, response) => {
    const rpc = request.url?.split("/").at(-1) ?? "";
    const result = handler(rpc);
    response.statusCode = result.status;
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify(result.body));
  });
  await new Promise<void>((resolve, reject) => {
    server?.once("error", reject).listen(0, "127.0.0.1", resolve);
  });
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

afterEach(async () => {
  if (!server) return;
  const active = server;
  server = undefined;
  await new Promise<void>((resolve) => active.close(() => resolve()));
});

describe("management overview Staff Hygiene enrichment", () => {
  it("returns the base overview when optional enrichment fails", async () => {
    const base = { branches: [{ branch_id: branch, business_date: businessDate, status: "active" }] };
    const origin = await withRpcServer((rpc) => rpc === "get_management_overview_with_daily_audit"
      ? { status: 200, body: base }
      : { status: 400, body: { code: "PGRST204", message: "unavailable" } });

    const result = await createChecklistPersistence(origin, "test-secret").getManagementOverview(actor, organization);
    assert.deepEqual(result, base);
  });

  it("keeps primary overview failures unavailable", async () => {
    let enrichmentCalled = false;
    const origin = await withRpcServer((rpc) => {
      if (rpc === "get_daily_report_staff_hygiene_applicability") enrichmentCalled = true;
      return { status: 400, body: { code: "PGRST200", message: "primary unavailable" } };
    });

    await assert.rejects(
      () => createChecklistPersistence(origin, "test-secret").getManagementOverview(actor, organization),
      (error: unknown) => error instanceof ManagementOverviewUnavailableError,
    );
    assert.equal(enrichmentCalled, false);
  });

  it("preserves base branch values and adds successful enrichment", async () => {
    const base = { branches: [{ branch_id: branch, business_date: businessDate, status: "active", totals: { submitted: 2 } }] };
    const origin = await withRpcServer((rpc) => rpc === "get_management_overview_with_daily_audit"
      ? { status: 200, body: base }
      : { status: 200, body: [{ branch_id: branch, operational_team_id: "41000000-0000-4000-8000-000000000001", eligible_staff_count: 3, required: true }] });

    const result = await createChecklistPersistence(origin, "test-secret").getManagementOverview(actor, organization) as typeof base;
    assert.deepEqual(result.branches[0], {
      ...base.branches[0],
      staff_hygiene_applicability: [{
        business_date: businessDate,
        operational_team_id: "41000000-0000-4000-8000-000000000001",
        eligible_staff_count: 3,
        required: true,
        applicability: "required",
      }],
    });
  });
});
