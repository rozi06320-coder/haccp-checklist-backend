import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

test("Daily Business Report selects the authoritative Sales Tracking relationship explicitly", async () => {
  const source = await readFile(new URL("./daily-business-report.ts", import.meta.url), "utf8");
  assert.match(
    source,
    /sales_tracking_reports!sales_tracking_report_cases_authoritative_fkey!inner\(id, state, submitted_at, currency_code\)/,
  );
  assert.doesNotMatch(
    source,
    /sales_tracking_reports!inner\(id, state, submitted_at, currency_code\)/,
  );
  assert.match(source, /\.eq\("organization_id", organizationId\)/);
  assert.match(source, /\.eq\("business_date", businessDate\)/);
  assert.match(source, /\.in\("branch_id", activeBranchIds\)/);
});
