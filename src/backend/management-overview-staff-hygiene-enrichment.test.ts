import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { managementOverviewSchema as frontendManagementOverviewSchema } from "/private/tmp/haccp-staff-hygiene-phase-b/src/lib/contracts/management-overview";
import { createChecklistPersistence, ManagementOverviewUnavailableError } from "./checklist-persistence";

const actor = "11000000-0000-4000-8000-000000000002";
const organization = "31000000-0000-4000-8000-000000000001";
const branch = "21000000-0000-4000-8000-000000000001";
const businessDate = "2026-10-30";
const emptyCounts = {
  expected_checks: 0,
  answered_checks: 0,
  compliant_checks: 0,
  issue_checks: 0,
  pending_checks: 0,
  completion_percentage: null,
  compliance_percentage: null,
};
const overview = {
  organization: { id: organization, name: "Organization" },
  generated_at: "2026-10-30T00:00:00Z",
  date_context: "current_branch_local_business_day" as const,
  summary: {
    active_branch_count: 1,
    active_team_count: 0,
    active_supervisor_account_count: 0,
    active_operational_staff_count: 0,
  },
  totals: emptyCounts,
  local_dates: [{ business_date: businessDate, branch_count: 1 }],
  branches: [{
    branch_id: branch,
    branch_name: "Branch",
    branch_code: "BR",
    timezone: "Asia/Riyadh",
    business_date: businessDate,
    status: "no_active_team" as const,
    active_team_count: 0,
    totals: emptyCounts,
    checklists: ["kitchen_opening", "foh_opening", "staff_hygiene", "daily_audit", "cold_storage", "oil_tracking", "sales_tracking"].map((checklist_type) => ({
      checklist_type,
      team_states: { not_started: 0, draft: 0, submitted: 0 },
      ...emptyCounts,
    })),
  }],
};

let server: Server | undefined;

async function withRpcServer(
  handler: (rpc: string) => { status: number; body: unknown },
): Promise<string> {
  server = createServer((request, response) => {
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

describe("management overview frontend contract", () => {
  it("returns the established shape and parses with the actual frontend schema", async () => {
    const calls: string[] = [];
    const origin = await withRpcServer((rpc) => {
      calls.push(rpc);
      return { status: 200, body: overview };
    });

    const result = await createChecklistPersistence(origin, "test-secret").getManagementOverview(actor, organization);
    const parsed = frontendManagementOverviewSchema.parse(result);
    assert.deepEqual(parsed, overview);
    assert.deepEqual(calls, ["get_management_overview_with_daily_audit"]);
    assert.equal("staff_hygiene_applicability" in parsed.branches[0], false);
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
});
