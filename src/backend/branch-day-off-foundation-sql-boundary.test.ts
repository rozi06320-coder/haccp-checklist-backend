import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve(
  "supabase/migrations/20261127120000_branch_day_off_foundation.sql",
);
const dbTestPath = path.resolve(
  "supabase/tests/database/branch_day_off_foundation.test.sql",
);

describe("Branch Day Off Phase 1 Foundation SQL Boundary", () => {
  it("is strictly additive and does not mutate existing submissions, branches.active, or existing RPC contracts", async () => {
    const sql = (await readFile(migrationPath, "utf8")).toLowerCase();

    assert.doesNotMatch(sql, /drop table|truncate table/);
    for (const table of [
      "branches",
      "checklist_submissions",
      "oil_tracking_submissions",
      "cold_storage_submissions",
      "sales_tracking_reports",
      "daily_audit_item_results",
      "notifications",
      "organization_manager_notifications",
    ]) {
      assert.doesNotMatch(
        sql,
        new RegExp(`(?:insert\\s+into|update|delete\\s+from)\\s+public\\.${table}\\b`),
      );
    }

    for (const existingRpc of [
      "list_internal_admin_branches",
      "create_internal_admin_branch",
      "update_internal_admin_branch",
      "get_phase4a_management_overview",
      "get_management_overview_with_daily_audit",
      "get_phase4a_supervisor_overview",
      "evaluate_supervisor_notifications",
    ]) {
      assert.doesNotMatch(
        sql,
        new RegExp(`create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.${existingRpc}\\b`),
      );
    }
  });

  it(" has zero hard coupling to daily_report_module_applicability", async () => {
    const sql = (await readFile(migrationPath, "utf8")).toLowerCase();
    assert.doesNotMatch(sql, /daily_report_module_applicability/);
  });

  it("enforces composite branch scope foreign keys and non-overlapping effective periods", async () => {
    const sql = (await readFile(migrationPath, "utf8")).toLowerCase();

    assert.match(
      sql,
      /constraint branch_weekly_day_off_schedules_branch_scope_fkey\s+foreign key\s*\(branch_id,\s*organization_id\)\s+references public\.branches\(id,\s*organization_id\)\s+on delete restrict/,
    );
    assert.match(
      sql,
      /constraint branch_closures_branch_scope_fkey\s+foreign key\s*\(branch_id,\s*organization_id\)\s+references public\.branches\(id,\s*organization_id\)\s+on delete restrict/,
    );
    assert.match(
      sql,
      /create unique index branch_weekly_day_off_schedules_open_key\s+on public\.branch_weekly_day_off_schedules\(branch_id\)\s+where effective_to_business_date is null/,
    );
    assert.match(sql, /create trigger branch_weekly_day_off_schedules_no_overlap/);
    assert.match(sql, /create trigger branch_closures_no_active_overlap/);
    assert.match(sql, /branch weekly day off schedules overlap/);
    assert.match(sql, /active branch closures overlap/);
  });

  it("preserves the 04:00 branch-local business date cutoff via private.phase4a_business_date_at", async () => {
    const sql = (await readFile(migrationPath, "utf8")).toLowerCase();

    assert.match(sql, /create or replace function private\.is_branch_day_off\(/);
    assert.match(sql, /create or replace function private\.is_branch_day_off_at\(/);
    assert.match(sql, /private\.phase4a_business_date_at\(branch\.timezone/);
    assert.match(sql, /private\.phase4a_business_date_at\(v_branch\.timezone,\s*v_now\)/);
  });

  it("secures tables with RLS and restricts all Internal Admin RPCs to service_role with 42501 auth checks and audit logs", async () => {
    const sql = (await readFile(migrationPath, "utf8")).toLowerCase();

    assert.match(sql, /alter table public\.branch_weekly_day_off_schedules enable row level security/);
    assert.match(sql, /alter table public\.branch_closures enable row level security/);
    assert.match(
      sql,
      /revoke all on table public\.branch_weekly_day_off_schedules from public,\s*anon,\s*authenticated,\s*service_role/,
    );
    assert.match(
      sql,
      /revoke all on table public\.branch_closures from public,\s*anon,\s*authenticated,\s*service_role/,
    );

    const rpcs = [
      "set_internal_admin_branch_weekly_day_off\\(uuid,\\s*uuid,\\s*uuid,\\s*smallint\\[\\],\\s*date,\\s*text\\)",
      "create_internal_admin_branch_closure\\(uuid,\\s*uuid,\\s*uuid,\\s*date,\\s*date,\\s*text\\)",
      "reopen_internal_admin_branch_closure\\(uuid,\\s*uuid,\\s*uuid,\\s*uuid,\\s*date\\)",
      "get_internal_admin_branch_day_off_config\\(uuid,\\s*uuid,\\s*uuid\\)",
    ];

    for (const rpc of rpcs) {
      assert.match(
        sql,
        new RegExp(`revoke all on function public\\.${rpc}\\s+from public,\\s*anon,\\s*authenticated`),
      );
      assert.match(
        sql,
        new RegExp(`grant execute on function public\\.${rpc}\\s+to service_role`),
      );
    }

    assert.doesNotMatch(sql, /grant execute[\s\S]*to authenticated/);
    assert.doesNotMatch(sql, /grant execute[\s\S]*to anon/);

    for (const action of [
      "branch_weekly_day_off_configured",
      "branch_closure_created",
      "branch_closure_reopened",
      "branch_closure_cancelled",
    ]) {
      assert.match(sql, new RegExp(`'${action}'`));
    }
  });

  it("includes comprehensive pgTAP database regression tests", async () => {
    const testSql = await readFile(dbTestPath, "utf8");
    assert.match(testSql, /select plan\(48\)/);
    assert.match(testSql, /Asia\/Riyadh/);
    assert.match(testSql, /Asia\/Dubai/);
    assert.match(testSql, /'UTC'/);
    assert.match(testSql, /42501/);
    assert.match(testSql, /P0002/);
    assert.match(testSql, /23505/);
  });

  it("does not drop or alter account_management_audit_logs_action_check and enforces fail-closed prerequisite assertion", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.doesNotMatch(sql, /drop\s+constraint\s+if\s+exists\s+account_management_audit_logs_action_check/i);
    assert.doesNotMatch(sql, /add\s+constraint\s+account_management_audit_logs_action_check/i);

    for (const requiredAction of [
      "branch_weekly_day_off_configured",
      "branch_closure_created",
      "branch_closure_reopened",
      "branch_closure_cancelled",
      "supervisor_team_onboarding_waiting_selected",
      "supervisor_owned_team_created",
    ]) {
      assert.match(sql, new RegExp(`'${requiredAction}'`));
    }
  });

  it("enforces empty search_path on every function and uses safe audit detail keys", async () => {
    const sql = (await readFile(migrationPath, "utf8")).toLowerCase();
    const functionDefinitions =
      sql.match(/create or replace function[\s\S]*?\$\$;/g) ?? [];
    assert.equal(functionDefinitions.length, 10);

    for (const definition of functionDefinitions) {
      assert.match(definition, /set search_path = ''/);
    }

    const auditInsertBlocks =
      sql.match(/insert into public\.account_management_audit_logs[\s\S]*?\);/g) ?? [];
    assert.equal(auditInsertBlocks.length, 3);
    for (const block of auditInsertBlocks) {
      assert.doesNotMatch(
        block,
        /password|accesstoken|refreshtoken|servicerole|secret/,
      );
    }
  });

  it("validates historical effective-date transitions, early reopening, cancellation, and weekday bounds", async () => {
    const sql = (await readFile(migrationPath, "utf8")).toLowerCase();

    // Weekday bounds 0..6 and duplicate rejection
    assert.match(sql, /curr < 0 or curr > 6 or curr <= prev/);
    assert.match(sql, /duplicate weekday in days_of_week/);

    // Historical weekly schedule preservation on transition
    assert.match(
      sql,
      /v_open\.id is not null and v_effective_from < v_open\.effective_from_business_date/,
    );
    assert.match(sql, /weekly day off schedule cannot move backward/);
    assert.match(sql, /set effective_to_business_date = v_effective_from/);

    // Early reopen vs cancellation at start_business_date
    assert.match(sql, /if v_reopen_from <= v_closure\.start_business_date then/);
    assert.match(sql, /set status = 'cancelled'/);
    assert.match(sql, /set end_business_date = v_reopen_from - 1/);
  });
});

