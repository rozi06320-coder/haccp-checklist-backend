import { readFileSync } from "node:fs";
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261030140000_organization_manager_notification_categories.sql", import.meta.url),
  "utf8",
);

describe("Organization Manager notification category storage SQL boundary", () => {
  it("adds only the approved category events and typed branch/date context", () => {
    assert.match(migration, /'sales_tracking_missing','maintenance_issue','incomplete_branch_tasks'/);
    assert.match(migration, /add column branch_id uuid/);
    assert.match(migration, /add column business_date date/);
    assert.match(migration, /add column category_context jsonb/);
    assert.match(migration, /organization_manager_notifications_branch_scope_fkey/);
    assert.match(migration, /category_context_check/);
    assert.match(migration, /create function private\.organization_manager_category_context_scope_valid\(/);
    assert.match(migration, /issue\.organization_id=p_organization_id/);
    assert.match(migration, /issue\.branch_id=p_branch_id/);
    assert.doesNotMatch(migration, /staff_hygiene_missing/);
  });

  it("uses a service-role-only SECURITY DEFINER insertion path", () => {
    assert.match(migration, /create function public\.create_organization_manager_category_notification\(/);
    assert.match(migration, /language plpgsql\s+security definer\s+set search_path = ''/);
    assert.match(migration, /revoke all on function public\.create_organization_manager_category_notification\([\s\S]*?from public,anon,authenticated,service_role/);
    assert.match(migration, /grant execute on function public\.create_organization_manager_category_notification\([\s\S]*?\)\s+to service_role/);
    assert.match(migration, /assert_active_organization_manager\(p_recipient_user_id,p_organization_id\)/);
    assert.match(migration, /expected_key:='manager:v1:'/);
    assert.match(migration, /on conflict\(organization_id,recipient_user_id,occurrence_key\) do nothing/);
  });

  it("enforces cutoff visibility and no-push behavior at the database boundary", () => {
    assert.match(migration, /create function private\.organization_manager_notification_branch_date_closed\(/);
    assert.match(migration, /daily_business_report_branch_close_at\(p_business_date,branch_timezone\)/);
    assert.match(migration, /organization_manager_category_no_push_guard/);
    assert.match(migration, /category notifications are in-app only/);
    assert.match(migration, /event_type in\('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks'\)/);
    assert.match(migration, /notification\.event_type not in\('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks'\)/);
  });

  it("preserves legacy maintenance creation and excludes scheduler/producer activation", () => {
    assert.doesNotMatch(migration, /create_organization_manager_notification\s*\(/);
    assert.doesNotMatch(migration, /cron\.schedule|pg_cron|scheduler|worker|produce_/i);
    assert.match(migration, /maintenance_issue_created/);
    assert.match(migration, /guard_organization_manager_notification_history/);
    assert.match(migration, /category_context is distinct from old\.category_context/);
  });

  it("keeps direct table access revoked and does not add a standalone hygiene event", () => {
    assert.match(migration, /revoke all on table public\.organization_manager_notifications\s+from public, anon, authenticated, service_role/);
    assert.match(migration, /revoke all on table public\.organization_manager_push_deliveries\s+from public, anon, authenticated, service_role/);
    assert.doesNotMatch(migration, /grant\s+(select|insert|update|delete)\s+on\s+table\s+public\.organization_manager_notifications/i);
    assert.doesNotMatch(migration, /organization_manager_notification_jobs/);
    assert.doesNotMatch(migration, /produce_staff_hygiene_missing_notifications/);
  });
});
