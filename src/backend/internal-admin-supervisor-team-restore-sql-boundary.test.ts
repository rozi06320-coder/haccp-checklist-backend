import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve(
  "supabase/migrations/20261002140000_internal_admin_supervisor_team_restore.sql",
);

describe("Internal Admin Supervisor team restore migration", () => {
  it("keeps the legacy overload and adds an explicit-branch restore overload", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /reactivate_internal_admin_supervisor\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*target_user_id uuid,\s*target_branch_id uuid\s*\)/s);
    assert.match(sql, /reactivate_internal_admin_supervisor\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*target_user_id uuid\s*\)/s);
    assert.match(sql, /explicit supervisor restore branch required/);
    assert.match(sql, /grant execute on function public\.reactivate_internal_admin_supervisor\(uuid, uuid, uuid, uuid\)\s+to service_role;/s);
    assert.doesNotMatch(sql, /grant execute on function public\.reactivate_internal_admin_supervisor[^;]+to authenticated;/s);
  });

  it("locks scope, preserves history, and inserts one new canonical assignment", async () => {
    const sql = await readFile(migrationPath, "utf8");

    assert.match(sql, /from public\.branch_memberships membership[\s\S]+for update;/);
    assert.match(sql, /from public\.branch_operational_teams team[\s\S]+for update;/);
    assert.match(sql, /target_organization_id::text \|\| ':' \|\| target_user_id::text \|\| ':supervisor-access-restore'/);
    assert.doesNotMatch(sql, /target_user_id::text \|\| ':' \|\| target_branch_id::text \|\| ':supervisor-access-restore'/);
    assert.match(sql, /operational team already has active primary supervisor/);
    assert.match(sql, /insert into public\.branch_operational_team_supervisors/);
    assert.match(sql, /historical_assignment\.assignment_role/);
    assert.match(sql, /valid_from,[\s\S]+restore_business_date/);
    assert.doesNotMatch(sql, /set\s+active\s*=\s*true,\s*valid_to\s*=\s*null[\s\S]+historical_assignment/i);
  });

  it("restores only audit-scoped backups and records every restored assignment", async () => {
    const sql = await readFile(migrationPath, "utf8");
    const restoreBody = sql.split("create or replace function public.reactivate_internal_admin_supervisor(")[1] ?? "";

    assert.match(sql, /'closed_team_assignments', closed_assignments/);
    assert.match(restoreBody, /latest_branch_revocation_details->'closed_team_assignments'/);
    assert.match(restoreBody, /revoked\.assignment_role = 'backup'/);
    assert.match(restoreBody, /assignment\.id = revoked\.assignment_id/);
    assert.match(restoreBody, /assignment\.supervisor_user_id = target_user_id/);
    assert.match(restoreBody, /'restored_team_assignments', restored_team_assignments/);
    assert.match(restoreBody, /'restored_operational_team_id', restored_assignment\.operational_team_id/);
    assert.match(restoreBody, /'historical_assignment_id', historical_assignment\.id/);
    assert.doesNotMatch(restoreBody, /update public\.branch_supervisor_teams[\s\S]+set active = true/);
  });
});
