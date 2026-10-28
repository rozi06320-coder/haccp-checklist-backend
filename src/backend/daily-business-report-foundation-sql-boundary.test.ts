import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const sql = readFileSync(new URL("../../supabase/migrations/20261027120000_daily_business_report_foundation.sql", import.meta.url), "utf8").toLowerCase();

describe("Daily Business Report database foundation SQL boundary", () => {
  it("is forward-only and does not mutate authoritative reporting or notification data", () => {
    assert.doesNotMatch(sql, /drop table|truncate table/);
    for (const table of ["checklist_submissions", "oil_tracking_submissions", "cold_storage_submissions", "sales_tracking_reports"]) {
      assert.doesNotMatch(sql, new RegExp(`(?:insert\\s+into|update|delete\\s+from)\\s+public\\.${table}`));
    }
    assert.doesNotMatch(sql, /organization_manager_notifications|organization_manager_push_deliveries/);
    assert.match(sql, /does not schedule jobs, generate reports or create notifications/);
  });

  it("installs branch capture before the idempotent backfill", () => {
    const trigger = sql.indexOf("create trigger branches_capture_daily_report_lifecycle");
    const backfill = sql.indexOf("insert into public.daily_report_branch_lifecycle", trigger);
    assert.ok(trigger >= 0 && backfill > trigger);
    assert.match(sql, /on conflict\(branch_id,effective_from_business_date\)do nothing/);
    assert.match(sql, /after insert or update of active,timezone on public\.branches/);
  });

  it("serializes lifecycle and applicability overlap checks", () => {
    assert.match(sql, /pg_advisory_xact_lock/);
    assert.match(sql, /daily-report:lifecycle:/);
    assert.match(sql, /daily-report:applicability:/);
    assert.match(sql, /daily report effective periods overlap/);
  });

  it("models seven modules with explicit runtime applicability bases", () => {
    for (const module of ["kitchen_opening", "foh_opening", "staff_hygiene", "daily_audit", "cold_storage", "oil_tracking", "sales_tracking"]) {
      assert.match(sql, new RegExp(`'${module}'`));
    }
    assert.match(sql, /eligible_operational_staff/);
    assert.match(sql, /eligible_cold_storage_equipment/);
    assert.match(sql, /eligible_oil_tracking_fryers/);
    assert.doesNotMatch(sql, /'kitchen_closing'|'foh_closing'|'cash_monitoring'\s*,|'maintenance'\s*,/);
  });

  it("strictly validates payload structure, source ownership, and internal-only links", () => {
    assert.match(sql, /daily_business_report_jsonb_has_exact_keys/);
    assert.match(sql, /validate_daily_business_report_payload/);
    assert.match(sql, /checklist_submissions/);
    assert.match(sql, /sales_tracking_report_cases/);
    assert.match(sql, /cash monitoring must share the authoritative sales report/);
    assert.match(sql, /invalid daily business report detail path/);
    assert.match(sql, /detail_path!~'\^\//);
  });

  it("finalizes a revision and its claimed job atomically", () => {
    assert.doesNotMatch(sql, /create function public\.store_daily_business_report_revision/);
    assert.doesNotMatch(sql, /create function public\.complete_daily_business_report_generation_job/);
    assert.match(sql, /create function public\.finalize_daily_business_report_generation_job/);
    assert.match(sql, /job\.lease_expires_at<=server_now/);
    assert.match(sql, /job\.organization_id<>p_organization_id/);
    assert.match(sql, /job\.business_date<>p_business_date/);
    assert.match(sql, /job\.source_watermark<>p_source_watermark/);
    assert.match(sql, /state='completed'.*completed_at=server_now/s);
  });

  it("uses only server-authoritative clocks on worker paths", () => {
    assert.match(sql, /create function public\.claim_daily_business_report_generation_jobs\(\s*p_worker_id uuid,p_limit integer default 20,p_lease_seconds integer default 120\s*\)/);
    assert.doesNotMatch(sql, /p_as_of/);
    assert.match(sql, /server_now timestamptz:=pg_catalog\.statement_timestamp\(\)/);
  });

  it("allows A-B-A history while suppressing only exact current replay", () => {
    assert.match(sql, /unique\(report_id,revision\)/);
    assert.doesNotMatch(sql, /unique\(report_id,canonical_payload_hash\)/);
    assert.match(sql, /current_revision_row\.canonical_payload_hash=payload_hash/);
    assert.match(sql, /current_revision_row\.source_watermark=p_source_watermark/);
    assert.match(sql, /current_revision_row\.source_cutoff_at=p_source_cutoff_at/);
    assert.match(sql, /next_revision=1 and p_generation_reason<>'initial'/);
  });

  it("is fail-closed before activation and provides bounded audited recovery", () => {
    assert.match(sql, /daily_business_report_activations/);
    assert.match(sql, /calculated_due_at<=activation_cutoff/);
    assert.match(sql, /daily_business_report_job_recovery_audit/);
    assert.match(sql, /requeue_count between 0 and 3/);
    assert.match(sql, /job\.requeue_count>=3/);
  });

  it("keeps timezone validation on writes rather than per snapshot branch", () => {
    const closeFunction = sql.slice(sql.indexOf("create function private.daily_business_report_branch_close_at"), sql.indexOf("create function private.daily_business_report_organization_due_at"));
    assert.doesNotMatch(closeFunction, /from pg_catalog\.pg_timezone_names/);
    assert.match(sql, /insert into private\.daily_report_timezones\(name\)\s*select zone\.name from pg_catalog\.pg_timezone_names zone/);
    assert.match(sql, /tg_table_name='daily_report_branch_lifecycle'.*private\.daily_report_timezones/s);
  });

  it("uses empty search paths, RLS, closed tables, and exact service-role grants", () => {
    const definitions = sql.match(/create function[\s\S]*?\$\$;/g) ?? [];
    assert.ok(definitions.length >= 20);
    for (const definition of definitions) assert.match(definition, /security definer[\s\S]*set search_path=''/);
    for (const table of ["daily_report_timezones", "daily_business_reports", "daily_business_report_revisions", "daily_business_report_activations", "daily_business_report_generation_jobs", "daily_business_report_job_recovery_audit"]) {
      assert.match(sql, new RegExp(`alter table (?:public|private)\\.${table} enable row level security`));
      assert.match(sql, new RegExp(`revoke all on table (?:public|private)\\.${table} from public,anon,authenticated,service_role`));
    }
    assert.match(sql, /grant execute on function public\.finalize_daily_business_report_generation_job\(uuid,uuid,uuid,date,integer,timestamptz,jsonb,text,text\) to service_role/);
    assert.doesNotMatch(sql, /grant execute[\s\S]*to authenticated/);
  });
});

describe("Daily Business Report Phase 2.6 authoritative applicability SQL boundary", () => {
  const p26Sql = readFileSync(new URL("../../supabase/migrations/20261028120000_daily_business_report_authoritative_applicability.sql", import.meta.url), "utf8").toLowerCase();

  it("defines read-only stable SECURITY DEFINER RPC with empty search_path and service_role grant", () => {
    assert.match(p26Sql, /drop function if exists public\.get_daily_report_authoritative_applicability\(uuid,\s*uuid,\s*date\)/);
    assert.match(p26Sql, /create or replace function public\.get_daily_report_authoritative_applicability/);
    assert.match(p26Sql, /stable[\s\S]*security definer[\s\S]*set search_path=''/);
    assert.match(p26Sql, /grant execute on function public\.get_daily_report_authoritative_applicability\(uuid,\s*uuid,\s*date,\s*uuid,\s*uuid\)\s*to service_role/);
    assert.doesNotMatch(p26Sql, /grant execute[\s\S]*to authenticated/);
    assert.doesNotMatch(p26Sql, /grant execute[\s\S]*to anon/);
  });

  it("eliminates NULL actor bypass and enforces explicit server-only generator lease authorization", () => {
    assert.match(p26Sql, /private\.actor_manages_active_organization\(p_actor_user_id,\s*p_organization_id\)/);
    assert.match(p26Sql, /private\.is_internal_admin\(p_actor_user_id\)/);
    // Explicit server generator lease check
    assert.match(p26Sql, /elsif p_job_id is not null and p_lease_token is not null/);
    assert.match(p26Sql, /from private\.daily_business_report_generation_jobs job/);
    assert.match(p26Sql, /job\.lease_expires_at\s*>\s*pg_catalog\.statement_timestamp\(\)/);
    // Fail closed on NULL actor without valid lease
    assert.match(p26Sql, /raise exception 'daily business report applicability requires authenticated actor or authorized server lease'/);
  });

  it("enforces combinatoric completeness against expected branch/module/date combinations and duplicate prevention", () => {
    // Detect duplicates
    assert.match(p26Sql, /group by lifecycle\.branch_id,\s*applicability\.module_key/);
    assert.match(p26Sql, /having count\(\*\)\s*>\s*1/);
    assert.match(p26Sql, /daily business report module applicability duplicate records detected/);

    // Cross join 7 canonical modules against active branches
    assert.match(p26Sql, /expected_combinations as/);
    assert.match(p26Sql, /cross join expected_modules/);
    assert.match(p26Sql, /where ar\.module_key is null/);
    assert.match(p26Sql, /daily business report module applicability missing/);
  });

  it("is strictly read-only and never modifies database or business state", () => {
    assert.doesNotMatch(p26Sql, /\binsert\s+into\b/i);
    assert.doesNotMatch(p26Sql, /\bupdate\s+\w+\s+set\b/i);
    assert.doesNotMatch(p26Sql, /\bdelete\s+from\b/i);
    assert.doesNotMatch(p26Sql, /\btruncate\b/i);
  });
});
