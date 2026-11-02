import { readFileSync } from "node:fs";
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";

const migration = readFileSync(new URL(
  "../../supabase/migrations/20261102120000_organization_manager_notification_scheduler.sql",
  import.meta.url,
), "utf8");

describe("Organization Manager notification scheduler SQL boundary", () => {
  it("enforces security definer, empty search_path, and service-role-only grants", () => {
    assert.match(migration, /create function public\.enqueue_due_organization_manager_notification_evaluation_jobs/);
    assert.match(migration, /language plpgsql\s+security definer\s+set search_path\s*=\s*''/s);
    assert.match(migration, /revoke all on function public\.enqueue_due_organization_manager_notification_evaluation_jobs\(integer,\s*timestamptz\)\s+from public,\s*anon,\s*authenticated,\s*service_role;/);
    assert.match(migration, /grant execute on function public\.enqueue_due_organization_manager_notification_evaluation_jobs\(integer,\s*timestamptz\)\s+to service_role;/);
    assert.doesNotMatch(migration, /grant execute .* to (?:anon|authenticated|public)\b/);
  });

  it("evaluates exactly the three approved categories and bounds catch-up window", () => {
    for (const category of ["sales_tracking_missing", "maintenance_issue", "incomplete_branch_tasks"]) {
      assert.match(migration, new RegExp(`'${category}'`));
    }
    assert.doesNotMatch(migration, /staff_hygiene_missing/);
    assert.match(migration, /p_catch_up_days not between 1 and 7/);
  });

  it("respects branch-local 04:00 cutoff and canonical lifecycle closure", () => {
    assert.match(migration, /04:00:00/);
    assert.match(migration, /branch_local_time\s*>=\s*time '04:00:00'/);
    assert.match(migration, /private\.organization_manager_notification_branch_date_closed/);
    assert.match(migration, /lifecycle\.active = true/);
    assert.match(migration, /lifecycle\.effective_to_business_date is null/);
  });

  it("is strictly idempotent and does not create push deliveries or activate cron", () => {
    assert.match(migration, /on conflict\s*\(organization_id,\s*branch_id,\s*business_date,\s*notification_category\)\s*do nothing/);
    assert.doesNotMatch(migration, /pg_cron|cron\.schedule/i);
    assert.doesNotMatch(migration, /organization_manager_push_deliveries/i);
  });
});
