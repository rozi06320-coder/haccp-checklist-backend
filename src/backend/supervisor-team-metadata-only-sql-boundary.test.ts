import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20260920100000_supervisor_team_metadata_only_destinations.sql", import.meta.url),
  "utf8",
);
const databaseTest = readFileSync(
  new URL("../../supabase/tests/database/supervisor_team_metadata_only_destinations.test.sql", import.meta.url),
  "utf8",
);

describe("Supervisor team metadata-only destination SQL boundary", () => {
  it("replaces only the existing supervisor team RPC signature", () => {
    assert.match(migration, /create or replace function public\.get_supervisor_operational_team\(actor_user_id uuid,target_branch_id uuid,requested_date date\)/);
    assert.match(migration, /returns table\(team_id uuid,team_name text,team_active boolean,can_write boolean,assignment_role text,/);
    assert.doesNotMatch(migration, /drop function|create table|alter table|transfer_operational_staff_branch/i);
  });

  it("keeps branch authorization and scheduled move activation", () => {
    assert.match(migration, /perform private\.apply_due_operational_staff_team_moves\(target_branch_id\)/);
    assert.match(migration, /not private\.actor_can_read_operational_branch\(actor_user_id,target_branch_id\)/);
    assert.match(migration, /raise exception 'team access denied' using errcode='42501'/);
  });

  it("returns active same-branch team metadata while forcing metadata-only rows read-only", () => {
    assert.match(migration, /from public\.branch_operational_teams team/);
    assert.match(migration, /left join public\.branch_operational_team_supervisors actor_assignment/);
    assert.match(migration, /where team\.branch_id=target_branch_id and team\.active/);
    assert.match(migration, /case when actor_assignment\.id is null then false else private\.actor_can_write_operational_team/);
    assert.match(migration, /actor_assignment\.assignment_role/);
  });

  it("gates staff assignment and duty data on a valid supervisor assignment", () => {
    assert.match(migration, /left join public\.operational_staff_assignments assignment\s+on actor_assignment\.id is not null and assignment\.operational_team_id=team\.id and assignment\.active/);
    assert.match(migration, /left join public\.operational_staff staff on staff\.id=assignment\.operational_staff_id/);
    assert.match(migration, /case when assignment\.id is null then null else coalesce\(duty\.duty_status,'on_duty'\) end/);
    assert.doesNotMatch(migration, /join public\.operational_staff_assignments assignment\s+on assignment\.operational_team_id=team\.id and assignment\.active/);
  });

  it("documents the runtime regression cases in pgTAP", () => {
    for (const expected of [
      "assigned Team A and active unassigned Team B are both returned",
      "metadata-only Team B exposes no staff PII assignment or duty fields",
      "Team B staff details never leak to Team A supervisor",
      "inactive teams are excluded",
      "unauthorized branch access is denied",
      "branch supervisor with no valid team assignment gains no staff or write access through metadata rows",
      "same-branch move to metadata-only destination works through source-team permission",
    ]) {
      assert.match(databaseTest, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    }
  });
});
