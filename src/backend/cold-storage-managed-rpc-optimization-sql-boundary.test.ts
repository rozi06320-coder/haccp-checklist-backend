import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migration = () => readFile("supabase/migrations/20261120130000_cold_storage_manager_rpc_dedup.sql", "utf8");

describe("Cold Storage managed RPC optimization SQL boundary", () => {
  it("keeps both public contracts and security configuration unchanged", async () => {
    const sql = await migration();
    assert.match(sql, /create or replace function public\.list_cold_storage_managed_reports\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*requested_page int default 1,\s*requested_page_size int default 20,\s*date_from date default null,\s*date_to date default null,\s*branch_filter uuid default null,\s*supervisor_filter uuid default null,\s*status_filter text default null,\s*search_term text default null\s*\)/s);
    assert.match(sql, /create or replace function public\.list_cold_storage_managed_issues\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*requested_page int default 1,\s*requested_page_size int default 20,\s*date_from date default null,\s*date_to date default null,\s*branch_filter uuid default null,\s*supervisor_filter uuid default null,\s*staff_filter uuid default null,\s*type_filter text default null,\s*status_filter text default null,\s*search_term text default null\s*\)/s);
    assert.equal((sql.match(/security definer set search_path = ''/g) ?? []).length, 2);
    assert.match(sql, /returns jsonb language plpgsql security definer set search_path = '' as \$\$/);
    assert.match(sql, /returns jsonb language plpgsql stable security definer set search_path = '' as \$\$/);
    assert.match(sql, /revoke all on function public\.list_cold_storage_managed_reports\(uuid,uuid,int,int,date,date,uuid,uuid,text,text\),/);
    assert.match(sql, /public\.list_cold_storage_managed_issues\(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text\)/);
    assert.match(sql, /grant execute on function public\.list_cold_storage_managed_reports\(uuid,uuid,int,int,date,date,uuid,uuid,text,text\),/);
    assert.match(sql, /to service_role;/);
  });

  it("materializes one filtered source for rows and totals", async () => {
    const sql = await migration();
    assert.equal((sql.match(/report_base as materialized/g) ?? []).length, 1);
    assert.equal((sql.match(/combined as materialized/g) ?? []).length, 2);
    assert.equal((sql.match(/filtered as materialized/g) ?? []).length, 2);
    assert.equal((sql.match(/private\.cold_storage_managed_missed_issue_rows\(target_organization_id\)/g) ?? []).length, 1);
    assert.match(sql, /'total', \(select count\(\*\) from filtered\)/g);
    assert.match(sql, /limit requested_page_size offset \(\(requested_page - 1\) \* requested_page_size\)/);
    assert.match(sql, /order by business_date desc, sort_time desc nulls last, id desc/);
    assert.match(sql, /order by created_at desc, id/);
  });

  it("retains date, branch, supervisor, status, search, and authorization predicates", async () => {
    const sql = await migration();
    for (const predicate of [
      "s.organization_id = target_organization_id",
      "s.business_date >= date_from",
      "s.business_date <= date_to",
      "s.branch_id = branch_filter",
      "s.supervisor_user_id = supervisor_filter",
      "status_filter is null or report_status = status_filter",
      "actor_manages_active_organization(actor_user_id, target_organization_id)",
    ]) assert.match(sql, new RegExp(predicate.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(sql, /status_filter is not null and status_filter <> 'new'/);
    assert.match(sql, /staff_filter is not null/);
    assert.match(sql, /type_filter is not null and type_filter <> 'cold_storage'/);
  });
});
