import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = () => readFile(new URL("./app.ts", import.meta.url), "utf8");

test("management list lifecycle diagnostics cover finished and client-aborted responses", async () => {
  const app = await source();
  assert.match(app, /MANAGEMENT_LIST_REQUEST_DIAGNOSTIC/);
  assert.match(app, /response\.once\("finish"/);
  assert.match(app, /response\.once\("close"/);
  assert.match(app, /outcome: "finished" \| "aborted"/);
  assert.match(app, /!response\.writableFinished/);
  assert.doesNotMatch(app, /MANAGEMENT_LIST_REQUEST_DIAGNOSTIC[\s\S]{0,500}(?:authorization|password|sql|payload)/i);
});

test("unfiltered Reports and Issues emit sanitized diagnostics for every source", async () => {
  const app = await source();
  assert.match(app, /MANAGEMENT_LIST_SOURCE_DIAGNOSTIC/);
  for (const sourceName of ["base", "oil_tracking", "cold_storage", "daily_audit", "financial_closing", "sales_tracking"]) {
    assert.match(app, new RegExp(`source:"${sourceName}"`));
  }
  assert.match(app, /runManagementListSource/);
  assert.match(app, /durationMs/);
  assert.match(app, /managementListErrorCategory/);
  const diagnosticBlock = app.slice(app.indexOf("MANAGEMENT_LIST_SOURCE_DIAGNOSTIC") - 1000, app.indexOf("MANAGEMENT_LIST_SOURCE_DIAGNOSTIC") + 1000);
  assert.doesNotMatch(diagnosticBlock, /JSON\.stringify\(error\)|error\.message|error\.stack/);
});
