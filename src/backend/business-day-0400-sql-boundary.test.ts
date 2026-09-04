import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20260904100000_phase4a_0400_business_day.sql");
const dryRunPath = "/tmp/business-day-0400-production-dry-run.sql";

describe("04:00 branch-local business day migration", () => {
  it("replaces current business-day boundaries without rewriting history", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /\(\(as_of at time zone tz\) - interval '4 hours'\)::date/);
    assert.match(migration, /extract\(hour from as_of at time zone branch_timezone\) >= 4/);
    assert.match(migration, /private\.managed_financial_closing_operations_summary/);
    assert.match(migration, /private\.phase4a_managed_missed_issue_rows/);
    assert.match(migration, /private\.oil_tracking_managed_missed_issue_rows/);
    assert.match(migration, /private\.sales_tracking_managed_issue_rows/);
    assert.match(migration, /public\.get_phase4a_management_overview/);
    assert.doesNotMatch(migration, /\b(?:update|delete from|insert into|truncate)\s+public\.(?:checklist_submissions|oil_tracking_submissions|cold_storage_submissions|sales_tracking_reports|financial_closing_reports)\b/i);
  });

  it("keeps fixed Cold Storage 02:00 eligibility and closure at 03:00", async () => {
    const [migration, eligibility, fixedSlots] = await Promise.all([
      readFile(migrationPath, "utf8"),
      readFile(path.resolve("supabase/migrations/20260829113000_cold_storage_slot_eligibility.sql"), "utf8"),
      readFile(path.resolve("supabase/migrations/20260811190000_cold_storage_12_20_02_slots.sql"), "utf8"),
    ]);
    assert.match(eligibility, /value >= time '02:00' and value < time '03:00' then '02:00'/);
    assert.match(fixedSlots, /if local_hour < 3 then return array\['12:00','20:00'\]::text\[\]/);
    assert.doesNotMatch(migration, /create or replace function private\.cold_storage_(?:eligible_slot_at|closed_slots_for)/);
    assert.match(migration, /local_time >= time '02:00' and local_time < time '04:00'/);
  });

  it("supersedes optional configurable schedule date partitions after their older migrations", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /cold_storage_slot_occurrence_local\(date,text\)/);
    assert.match(migration, /target_slot::time < time ''04:00''/);
    assert.match(migration, /cold_storage_schedule_context_at\(uuid,timestamptz\)/);
    assert.match(migration, /local_as_of - interval ''4 hours''/);
    assert.match(migration, /cold_storage_master_first_eligible_slot\(uuid,timestamptz\)/);
    assert.doesNotMatch(migration, /target_business_date\+1\)::timestamp\+time ''04:00''/);
  });

  it("preserves notification clock rules", async () => {
    const [migration, notifications] = await Promise.all([
      readFile(migrationPath, "utf8"),
      readFile(path.resolve("supabase/migrations/20260824130000_supervisor_time_based_notifications.sql"), "utf8"),
    ]);
    for (const time of ["18:00", "20:00", "22:00", "23:00", "02:00"]) assert.match(notifications, new RegExp(`time '${time}'`));
    assert.doesNotMatch(migration, /notification_rules|reminder_time/);
  });

  it("keeps Sales Closing-final behavior untouched and inherited through phase2 context", async () => {
    const [migration, sales, context] = await Promise.all([
      readFile(migrationPath, "utf8"),
      readFile(path.resolve("supabase/migrations/20260903100000_sales_tracking_closing_final_workflow.sql"), "utf8"),
      readFile(path.resolve("supabase/migrations/20260812041000_branch_shared_authorization_compatibility.sql"), "utf8"),
    ]);
    assert.match(context, /private\.phase4a_business_date\(b\.timezone\)/);
    assert.match(sales, /entry_period not in\('middle_shift','closing_shift'\)/);
    assert.match(sales, /entry_period='middle_shift' and exists[\s\S]*entry_period='closing_shift'/);
    assert.match(sales, /period_count<1 or period_count>2 or closing_count<>1/);
    assert.doesNotMatch(migration, /create or replace function public\.(?:save_sales_tracking_draft|submit_sales_tracking)/);
  });

  it("embeds the migration byte-identically in a read-only transactional dry-run", async () => {
    const [migration, dryRun] = await Promise.all([readFile(migrationPath, "utf8"), readFile(dryRunPath, "utf8")]);
    const marker = "-- BEGIN BYTE-IDENTICAL MIGRATION\n";
    const start = dryRun.indexOf(marker) + marker.length;
    const end = dryRun.indexOf("-- END BYTE-IDENTICAL MIGRATION", start);
    assert.ok(start >= marker.length && end > start);
    assert.equal(dryRun.slice(start, end), migration);
    assert.match(dryRun, /begin;[\s\S]*rollback;/i);
    assert.match(dryRun, /00:59:59\.999\+00[\s\S]*04:00 business-date boundary assertion failed/);
    assert.match(dryRun, /fixed Cold Storage 03:00 deadline changed/);
    const postRollback = dryRun.slice(dryRun.indexOf("do $post_rollback_assert$"));
    for (const signature of [
      "private.phase4a_business_date_at(text,timestamptz)",
      "private.phase4a_business_date(text)",
      "private.management_branch_closed(text,timestamptz)",
      "private.managed_financial_closing_operations_summary(uuid,uuid,timestamptz)",
      "private.phase4a_managed_missed_issue_rows(uuid)",
      "private.oil_tracking_managed_missed_issue_rows(uuid)",
      "private.sales_tracking_managed_issue_rows(uuid)",
      "public.get_phase4a_management_overview(uuid,uuid)",
      "private.cold_storage_master_first_eligible_slot(text,timestamptz)",
      "private.cold_storage_slot_occurrence_local(date,text)",
      "private.cold_storage_schedule_context_at(uuid,timestamptz)",
      "private.cold_storage_slot_order(text)",
      "private.cold_storage_master_first_eligible_slot(uuid,timestamptz)",
    ]) assert.match(postRollback, new RegExp(signature.replace(/[().]/g, "\\$&")));
    for (const message of [
      "canonical business-day helper",
      "canonical business-day delegate",
      "Manager close boundary",
      "financial closing summary",
      "Manager missed-check helper",
      "oil missed-check helper",
      "sales missed-check helper",
      "management overview",
      "fixed Cold Storage equipment eligibility",
      "configurable slot occurrence",
      "configurable schedule context",
      "configurable slot ordering",
      "configurable equipment eligibility",
    ]) assert.match(postRollback, new RegExp(`rollback did not restore ${message}`));
    assert.doesNotMatch(postRollback, /create\s+temp|\\gset/i);
    const harness = dryRun.slice(0, start) + dryRun.slice(end);
    assert.doesNotMatch(harness, /\b(?:insert\s+into|update|delete\s+from|truncate)\s+public\./i);
    assert.doesNotMatch(harness, /\\(?:gset|set|i|include)\b|create\s+temp/i);
  });
});
