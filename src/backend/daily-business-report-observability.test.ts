import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createDailyBusinessReportSourceReader,
  createDailyBusinessReportService,
  DailyBusinessReportUnavailableError,
} from "./daily-business-report";

describe("Daily Business Report source observability", () => {
  it("distinguishes a successful empty result from a source failure", async () => {
    const events: Array<Record<string, unknown>> = [];
    const read = createDailyBusinessReportSourceReader((event) => events.push(event));

    const rows = await read("request-1", "checklist_submissions", async () => ({ data: [], error: null }));
    assert.deepEqual(rows, []);
    assert.deepEqual(events, [{
      requestId: "request-1",
      source: "checklist_submissions",
      outcome: "success",
      category: "empty_result",
      durationMs: events[0]?.durationMs,
    }]);
    assert.equal(typeof events[0]?.durationMs, "number");

    await assert.rejects(
      () => read("request-2", "oil_tracking_submissions", async () => ({
        data: null,
        error: { code: "42501" },
      })),
      (error: unknown) => error instanceof DailyBusinessReportUnavailableError,
    );
    assert.equal(events[1]?.requestId, "request-2");
    assert.equal(events[1]?.source, "oil_tracking_submissions");
    assert.equal(events[1]?.outcome, "failure");
    assert.equal(events[1]?.category, "query_error");
    assert.equal("code" in events[1]!, false);
  });

  it("fails closed for malformed successful query data instead of treating it as empty", async () => {
    const events: Array<Record<string, unknown>> = [];
    const read = createDailyBusinessReportSourceReader((event) => events.push(event));

    await assert.rejects(
      () => read("request-3", "sales_tracking_report_cases", async () => ({ data: null, error: null })),
      (error: unknown) => error instanceof DailyBusinessReportUnavailableError,
    );
    assert.equal(events[0]?.category, "query_error");
  });

  it("does not convert a Sales Tracking summary failure into zero sales", async () => {
    const events: Array<Record<string, unknown>> = [];
    const service = createDailyBusinessReportService(
      "https://example.supabase.co",
      "test-service-key",
      {
        async getManagedSalesTrackingPeriodSummary() {
          throw new Error("provider failure");
        },
      } as never,
      {
        dataSourceProvider: async () => ({ branches: [] }),
        diagnosticLogger: (event) => events.push(event),
      },
    );

    await assert.rejects(
      () => service.getReportPreview({
        actorUserId: "10000000-0000-4000-8000-000000000001",
        organizationId: "20000000-0000-4000-8000-000000000001",
        businessDate: "2026-10-27",
        requestId: "request-4",
      }),
      (error: unknown) => error instanceof DailyBusinessReportUnavailableError,
    );
    assert.equal(events.at(-1)?.source, "sales_tracking_period_summary");
    assert.equal(events.at(-1)?.outcome, "failure");
  });
});
