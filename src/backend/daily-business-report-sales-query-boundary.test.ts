import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

test("Daily Business Report uses the scoped authoritative Sales Tracking read RPC", async () => {
  const source = await readFile(new URL("./daily-business-report.ts", import.meta.url), "utf8");
  assert.match(source, /getDailyBusinessReportSalesCases/);
  assert.doesNotMatch(source, /\.from\("sales_tracking_report_cases"\)/);
  assert.match(source, /branchIds: activeBranchIds/);
  assert.match(source, /currencyCode: c\.currency_code/);
});
