import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import { createDailyBusinessReportService, DailyBusinessReportUnavailableError } from "./daily-business-report";
import { ChecklistInputError } from "./checklist-persistence";
import { historicalDailyBusinessReportPreviewSchema } from "../lib/contracts/daily-business-report-historical";

const org = "20000000-0000-4000-8000-000000000001";
const branch = "30000000-0000-4000-8000-000000000001";
const team = "40000000-0000-4000-8000-000000000001";
const source = "50000000-0000-4000-8000-000000000001";

const historicalModule = { status: "unknown" as const, verification: "unverified" as const, required: null, expected_count: null, submitted_count: 0, missing_count: null, issue_count: null, source_report_ids: [], detail_paths: [] };

function historicalPayload(modules: Record<string, unknown>) {
  return {
    organization_id: org,
    business_date: "2026-10-26",
    schema_version: 1 as const,
    mode: "historical" as const,
    compliance_verification: "unverified" as const,
    summary: { submitted_count: 0, issues_detected_count: 0, unknown_count: 7, verified_required_count: 0, verified_missing_count: 0 },
    branches: [{ branch_id: branch, timezone: "Asia/Riyadh", evidence_basis: ["checklist_submission" as const], modules }],
  };
}

function service(rows: unknown[] = []) {
  return createDailyBusinessReportService("https://example.invalid", "test-secret", undefined, {
    historicalDataSourceProvider: async () => ({
      branches: [{ id: branch, organizationId: org, timezone: "Asia/Riyadh" }],
      evidence: rows as any,
    }),
  });
}

describe("Daily Business Report historical preview", () => {
  it("requires exactly the seven historical module keys", () => {
    const valid = { kitchen_opening: historicalModule, foh_opening: historicalModule, staff_hygiene: historicalModule, daily_audit: historicalModule, cold_storage: historicalModule, oil_tracking: historicalModule, sales_tracking: historicalModule };
    assert.doesNotThrow(() => historicalDailyBusinessReportPreviewSchema.parse(historicalPayload(valid)));

    const missing = { ...valid };
    delete missing.sales_tracking;
    assert.throws(() => historicalDailyBusinessReportPreviewSchema.parse(historicalPayload(missing)), /sales_tracking|required/i);

    const additional = { ...valid, unexpected_module: historicalModule };
    assert.throws(() => historicalDailyBusinessReportPreviewSchema.parse(historicalPayload(additional)), /unrecognized|unexpected_module/i);
  });

  it("uses the authoritative Sales Tracking read path rather than direct report state", () => {
    const source = readFileSync(resolve("src/backend/daily-business-report.ts"), "utf8");
    const start = source.indexOf("const historicalDataSourceProvider");
    const end = source.indexOf("const nowProvider", start);
    const historicalProvider = source.slice(start, end);
    assert.match(historicalProvider, /getDailyBusinessReportSalesCases/);
    assert.doesNotMatch(historicalProvider, /from\("sales_tracking_reports"\)/);
  });

  it("rejects the current applicability boundary and later dates", async () => {
    await assert.rejects(
      () => service().getHistoricalReportPreview({ actorUserId: "60000000-0000-4000-8000-000000000001", organizationId: org, businessDate: "2026-10-27" }),
      (error: unknown) => error instanceof ChecklistInputError,
    );
  });

  it("returns UNKNOWN rather than Missing or N/A when no obligation evidence exists", async () => {
    const preview = await service().getHistoricalReportPreview({ actorUserId: "60000000-0000-4000-8000-000000000001", organizationId: org, businessDate: "2026-10-26" });
    assert.equal(preview.mode, "historical");
    assert.equal(preview.compliance_verification, "unverified");
    assert.equal(preview.branches.length, 1);
    assert.equal(preview.branches[0].modules.staff_hygiene.status, "unknown");
    assert.equal(preview.branches[0].modules.staff_hygiene.required, null);
    assert.equal(preview.summary.unknown_count, 7);
    assert.equal(preview.summary.verified_missing_count, 0);
  });

  it("shows valid historical Staff Hygiene evidence per operational team", async () => {
    const preview = await service([
      { organizationId: org, id: source, branchId: branch, businessDate: "2026-10-26", moduleKey: "staff_hygiene", teamId: team, evidenceBasis: "checklist_submission" },
    ]).getHistoricalReportPreview({ actorUserId: "60000000-0000-4000-8000-000000000001", organizationId: org, businessDate: "2026-10-26" });
    const hygiene = preview.branches[0].modules.staff_hygiene;
    assert.equal(hygiene.status, "submitted");
    assert.equal(hygiene.verification, "evidence");
    assert.deepEqual(hygiene.source_report_ids, [source]);
    assert.equal(hygiene.required, null);
  });

  it("passes the verified organization scope to the historical provider", async () => {
    let requestedOrganization = "";
    const scoped = createDailyBusinessReportService("https://example.invalid", "test-secret", undefined, {
      historicalDataSourceProvider: async (organizationId) => {
        requestedOrganization = organizationId;
        return { branches: [], evidence: [] };
      },
    });
    await scoped.getHistoricalReportPreview({ actorUserId: "60000000-0000-4000-8000-000000000001", organizationId: org, businessDate: "2026-10-26" });
    assert.equal(requestedOrganization, org);
  });

  it("fails closed when historical evidence cannot be read", async () => {
    const unavailable = createDailyBusinessReportService("https://example.invalid", "test-secret", undefined, {
      historicalDataSourceProvider: async () => { throw new DailyBusinessReportUnavailableError("source unavailable"); },
    });
    await assert.rejects(
      () => unavailable.getHistoricalReportPreview({ actorUserId: "60000000-0000-4000-8000-000000000001", organizationId: org, businessDate: "2026-10-26" }),
      (error: unknown) => error instanceof DailyBusinessReportUnavailableError,
    );
  });

  it("rejects duplicate Staff Hygiene evidence for the same team and date", async () => {
    const duplicate = service([
      { organizationId: org, id: source, branchId: branch, businessDate: "2026-10-26", moduleKey: "staff_hygiene", teamId: team, evidenceBasis: "checklist_submission" },
      { organizationId: org, id: "50000000-0000-4000-8000-000000000002", branchId: branch, businessDate: "2026-10-26", moduleKey: "staff_hygiene", teamId: team, evidenceBasis: "checklist_submission" },
    ]);
    await assert.rejects(() => duplicate.getHistoricalReportPreview({ actorUserId: "60000000-0000-4000-8000-000000000001", organizationId: org, businessDate: "2026-10-26" }), DailyBusinessReportUnavailableError);
  });

  it("rejects cross-organization or wrong-date evidence instead of dropping it", async () => {
    const inconsistent = service([{ organizationId: "20000000-0000-4000-8000-000000000002", id: source, branchId: branch, businessDate: "2026-10-25", moduleKey: "staff_hygiene", teamId: team, evidenceBasis: "checklist_submission" }]);
    await assert.rejects(() => inconsistent.getHistoricalReportPreview({ actorUserId: "60000000-0000-4000-8000-000000000001", organizationId: org, businessDate: "2026-10-26" }), DailyBusinessReportUnavailableError);
  });
});
