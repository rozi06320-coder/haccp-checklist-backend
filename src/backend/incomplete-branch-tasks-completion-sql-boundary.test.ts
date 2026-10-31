import { readFileSync } from "node:fs";
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261030130000_incomplete_branch_tasks_completion_evaluator.sql", import.meta.url),
  "utf8",
);
const evaluator = migration.slice(
  migration.indexOf("create function public.get_incomplete_branch_tasks_completion"),
  migration.indexOf("revoke all on function public.get_incomplete_branch_tasks_completion"),
);

describe("Incomplete branch tasks completion evaluator SQL boundary", () => {
  it("returns exactly the six allowed modules and excludes Sales Tracking", () => {
    for (const moduleKey of [
      "kitchen_opening",
      "foh_opening",
      "staff_hygiene",
      "daily_audit",
      "cold_storage",
      "oil_tracking",
    ]) {
      assert.match(migration, new RegExp(`'${moduleKey}'`));
    }
    assert.doesNotMatch(migration, /'sales_tracking'/);
    assert.match(migration, /calculated_state not in\('completed','incomplete','not_required','unknown'\)/);
  });

  it("has an independent category-neutral lease foundation", () => {
    assert.match(migration, /create table private\.organization_manager_notification_evaluation_jobs/);
    assert.match(migration, /'sales_tracking_missing','maintenance_issue','incomplete_branch_tasks'/);
    assert.match(migration, /enqueue_organization_manager_notification_evaluation_job/);
    assert.match(migration, /claim_organization_manager_notification_evaluation_jobs/);
    assert.match(migration, /complete_organization_manager_notification_evaluation_job/);
    assert.doesNotMatch(migration, /organization_manager_notification_jobs/);
    assert.doesNotMatch(migration, /staff_hygiene_missing/);
  });

  it("keeps the exact job-ID and lease-token evaluator signature", () => {
    assert.match(evaluator, /get_incomplete_branch_tasks_completion\(\s*p_job_id uuid,\s*p_lease_token uuid\s*\)/);
    assert.match(migration, /job_record\.state<>'running'/);
    assert.match(migration, /job_record\.notification_category<>'incomplete_branch_tasks'/);
    assert.match(migration, /job_record\.lease_token is distinct from p_lease_token/);
    assert.match(migration, /job_record\.lease_expires_at<=server_now/);
    assert.match(migration, /language plpgsql\s+stable\s+security definer\s+set search_path=''/);
    assert.match(migration, /revoke all on function public\.get_incomplete_branch_tasks_completion\(uuid,uuid\)[\s\S]*from public,anon,authenticated,service_role/);
    assert.match(migration, /grant execute on function public\.get_incomplete_branch_tasks_completion\(uuid,uuid\)\s+to service_role/);
    assert.doesNotMatch(evaluator, /\b(?:insert|update|delete)\s+(?:into|public\.|private\.|from)/i);
  });

  it("enforces branch-local completion and the final Cold Storage boundary", () => {
    assert.match(migration, /daily_business_report_branch_close_at/);
    assert.match(migration, /if p_as_of<branch_close_at/);
    assert.match(migration, /cold_storage_closed_slots_for\(p_branch_id,p_business_date,p_as_of\)/);
    assert.match(migration, /closed_slots<@array\['12:00','20:00','02:00'\]/);
    assert.match(migration, /cold_storage_master_first_eligible_slot/);
    assert.match(migration, /cold_storage_equipment_slot_eligible/);
  });

  it("fails closed for historical roster, equipment, fryer, and malformed evidence", () => {
    assert.match(migration, /assignment\.valid_from<=p_business_date/);
    assert.match(migration, /assignment\.created_at>branch_close_at/);
    assert.doesNotMatch(migration, /staff\.employment_status='active'/);
    assert.doesNotMatch(migration, /team\.active/);
    assert.match(migration, /equipment\.master_equipment_id is null/);
    assert.match(migration, /actual_count=0 or eligible_count=0/);
    assert.match(migration, /evidence_count>1/);
    assert.match(migration, /bool_or\(states\.module_state='unknown'\)/);
  });

  it("does not create notifications, scheduler activation, or worker logic", () => {
    assert.doesNotMatch(migration, /organization_manager_notifications/);
    assert.doesNotMatch(migration, /cron\.schedule|pg_cron|scheduler|create_organization_manager_notification/i);
  });
});
