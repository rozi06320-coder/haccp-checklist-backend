import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261004130000_operational_staff_scheduled_branch_transfers.sql", import.meta.url),
  "utf8",
);

describe("scheduled cross-branch transfer SQL boundary", () => {
  it("stores source and destination scope without binding staff to its mutable branch", () => {
    assert.match(migration, /create table public\.operational_staff_scheduled_branch_transfers/);
    assert.match(migration, /foreign key\(operational_staff_id,organization_id\)/);
    assert.doesNotMatch(migration, /foreign key\(operational_staff_id,source_branch_id,organization_id\)/);
    assert.match(migration, /effective_source_business_date=requested_source_business_date\+1/);
    assert.match(migration, /where status='pending'/);
  });

  it("uses one lifecycle lock and checks both pending movement tables", () => {
    assert.match(migration, /operational-staff-movement/);
    assert.match(migration, /operational_staff_scheduled_team_moves/);
    assert.match(migration, /operational_staff_scheduled_branch_transfers/);
    assert.match(migration, /staff pending movement already exists/);
    assert.match(migration, /existing_transfer\.source_assignment_id=p_expected_assignment_id/);
  });

  it("schedules only submitted Hygiene and uses source-local 04:00", () => {
    assert.match(migration, /hygiene_staff_snapshots/);
    assert.match(migration, /submission\.state='submitted'/);
    assert.match(migration, /source_recorded or destination_submitted/);
    assert.match(migration, /effective_source_date::timestamp\+time '04:00'/);
    assert.match(migration, /at time zone source_branch\.timezone/);
    assert.match(migration, /phase4a_business_date_at\(destination_branch\.timezone,scheduled\.effective_at\)/);
  });

  it("applies atomically without copying historical duty or Hygiene", () => {
    assert.match(migration, /valid_to=scheduled\.effective_source_business_date-1/);
    assert.match(migration, /update public\.operational_staff staff set branch_id=scheduled\.destination_branch_id/);
    assert.match(migration, /destination_team\.legacy_supervisor_team_id/);
    const activation = migration.slice(
      migration.indexOf("create function private.apply_due_operational_staff_branch_transfers"),
      migration.indexOf("create function public.apply_due_operational_staff_branch_transfers"),
    );
    assert.doesNotMatch(activation, /insert into public\.operational_staff_duty_statuses/);
    assert.doesNotMatch(activation, /update public\.(?:checklist_submissions|hygiene_staff_snapshots)/);
  });

  it("keeps legacy callers immediate and restricts new functions to service role", () => {
    assert.match(migration, /request_operational_staff_branch_transfer[\s\S]*,false\) transfer/);
    assert.match(migration, /if destination_submitted then[\s\S]*destination team hygiene already submitted/);
    assert.match(migration, /from public,anon,authenticated/);
    assert.match(migration, /to service_role/);
    assert.match(migration, /set search_path = ''/);
  });

  it("installs isolated cron and supports explicit cancellation", () => {
    assert.match(migration, /operational-staff-scheduled-branch-transfers/);
    assert.match(migration, /'\* \* \* \* \*'/);
    assert.match(migration, /cancel_operational_staff_scheduled_branch_transfer/);
    assert.match(migration, /cancelled_by_user_id=actor_user_id/);
  });
});
