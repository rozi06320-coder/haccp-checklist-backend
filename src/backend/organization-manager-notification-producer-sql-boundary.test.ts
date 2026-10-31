import { readFileSync } from "node:fs";
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";

const migration = readFileSync(new URL(
  "../../supabase/migrations/20261030150000_organization_manager_notification_producer.sql",
  import.meta.url,
), "utf8");

describe("Organization Manager notification producer SQL boundary", () => {
  it("is additive, lease-bound, service-role-only, and does not enable a scheduler", () => {
    assert.match(migration, /get_incomplete_branch_tasks_completion\(uuid,uuid\)/);
    assert.match(migration, /get_daily_business_report_sales_cases\(uuid,uuid,date,uuid\[\],uuid,uuid\)/);
    assert.match(migration, /create_organization_manager_category_notification\(uuid,uuid,text,uuid,date,jsonb,text\)/);
    assert.match(migration, /produce_organization_manager_notification_evaluation_job\(\s*p_job_id uuid,p_lease_token uuid/s);
    assert.match(migration, /job\.state<>'running'/);
    assert.match(migration, /job\.lease_token is distinct from p_lease_token/);
    assert.match(migration, /job\.lease_expires_at<=now_at/);
    assert.match(migration, /grant execute on function public\.produce_organization_manager_notification_evaluation_job\(uuid,uuid\)\s+to service_role/);
    assert.match(migration, /revoke all on function public\.produce_organization_manager_notification_evaluation_job\(uuid,uuid\)\s+from public,anon,authenticated/);
    assert.doesNotMatch(migration, /pg_cron|cron\.schedule|create extension|http/i);
  });

  it("preserves the three categories and uses category creation for dedup/no-push", () => {
    for (const category of ["sales_tracking_missing", "maintenance_issue", "incomplete_branch_tasks"]) {
      assert.match(migration, new RegExp(`'${category}'`));
    }
    assert.match(migration, /create_organization_manager_category_notification/);
    assert.match(migration, /manager:v1:/);
    assert.match(migration, /jsonb_build_object\('schema_version'/);
    assert.doesNotMatch(migration, /create_organization_manager_notification\(/);
    assert.doesNotMatch(migration, /insert into public\.organization_manager_push_deliveries/i);
  });

  it("keeps Sales Tracking and maintenance fail-closed", () => {
    assert.match(migration, /case_count>1 then return 'unknown'/);
    assert.match(migration, /open_correction_id is not null then/);
    assert.match(migration, /correction_case_id is distinct from/);
    assert.doesNotMatch(migration, /report_review_status='needs_review' then return 'unknown'/);
    assert.match(migration, /report_review_status is null or report_review_status not in \('none','reviewed','needs_review'\) then return 'unknown'/);
    assert.match(migration, /correction_state is distinct from 'draft'/);
    assert.match(migration, /report_state is distinct from 'submitted'/);
    assert.match(migration, /return 'satisfied';/);
    assert.match(migration, /location_scope='branch'/);
    assert.match(migration, /not in \('resolved','closed'\)/);
    assert.match(migration, /maintenance_issue_updates/);
    assert.match(migration, /created_at<=close_at/);
    assert.match(migration, /source_state='unknown'/);
    assert.match(migration, /maintenance_source_unknown/);
  });

  it("guards against the superseded standalone Staff Hygiene event", () => {
    assert.match(migration, /create_organization_manager_staff_hygiene_missing_notification/);
  });
});
