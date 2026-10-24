import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath=path.resolve("supabase/migrations/20261024120000_manager_sales_tracking_period_reporting.sql");

describe("Manager Sales Tracking period reporting SQL boundary",()=>{
  it("keeps all read RPCs service-role-only with empty search paths",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    assert.equal((sql.match(/security definer\s+set search_path=''/g)??[]).length,3);
    assert.equal((sql.match(/grant execute on function public\./g)??[]).length,3);
    assert.equal((sql.match(/to service_role/g)??[]).length,3);
    assert.equal((sql.match(/from public,anon,authenticated/g)??[]).length,3);
    assert.doesNotMatch(sql,/grant execute[\s\S]*to (?:anon|authenticated)/);
    assert.doesNotMatch(sql,/\bexecute\s+format\s*\(/i);
  });

  it("binds reads to current authority, tenant, branch, state, and bounded dates",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    assert.equal((sql.match(/report\.id=report_case\.authoritative_report_id/g)??[]).length>=2,true);
    assert.equal((sql.match(/report_case\.organization_id=target_organization_id/g)??[]).length>=2,true);
    assert.equal((sql.match(/branch_filter is null or report_case\.branch_id=branch_filter/g)??[]).length>=2,true);
    assert.equal((sql.match(/report\.state='submitted'/g)??[]).length>=3,true);
    assert.equal((sql.match(/to_date-from_date>365|to_date - from_date > 365/g)??[]).length,3);
    assert.match(sql,/attachment\.deleted_at is null/);
    assert.match(sql,/requested_limit>51/);
    assert.match(sql,/pg_catalog\.cardinality\(target_attachment_ids\)>50/);
  });

  it("is additive and leaves submission, correction, and attachment persistence untouched",async()=>{
    const sql=await readFile(migrationPath,"utf8");
    assert.doesNotMatch(sql,/\balter table\b|\bupdate public\.|\bdelete from public\.|\binsert into public\./i);
    assert.match(sql,/CREATE INDEX CONCURRENTLY IF NOT EXISTS sales_tracking_report_cases_org_date_branch_idx/);
    assert.doesNotMatch(sql,/^\s*create index\b/mi);
    assert.match(sql,/join public\.sales_tracking_reports as report/);
    assert.match(sql,/join public\.sales_tracking_attachments as attachment/);
  });
});
