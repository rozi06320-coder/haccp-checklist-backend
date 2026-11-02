import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261102140000_access_management_phase1.sql");
const appPath = path.resolve("src/backend/app.ts");
const adminPath = path.resolve("src/backend/admin.ts");

describe("Access Management Phase 1 Migration and SQL Boundary", () => {
  it("adds training_role and credential_version to training_memberships", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /add column if not exists training_role text not null default 'training_supervisor'/);
    assert.match(sql, /add column if not exists credential_version uuid not null default gen_random_uuid\(\)/);
    assert.match(sql, /training_memberships_training_role_check\s+check\s*\(training_role in \('training_supervisor'\)\)/);
  });

  it("updates audit log check constraint for training supervisor actions", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /'training_supervisor_granted'/);
    assert.match(sql, /'training_supervisor_suspended'/);
    assert.match(sql, /'training_supervisor_reactivated'/);
    assert.match(sql, /'training_supervisor_revoked'/);
    assert.match(sql, /'training_supervisor_reassigned'/);
  });

  it("enforces mutual exclusivity between Supervisor and Training Supervisor roles across branch moves and role changes", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /create or replace function private\.enforce_access_assignment_mutual_exclusivity\(\)/);
    assert.match(sql, /account cannot simultaneously hold active supervisor and training supervisor roles/);
    assert.match(sql, /create trigger branch_memberships_access_assignment_exclusivity[\s\S]+after insert or update of role, active, branch_id on public\.branch_memberships/);
    assert.match(sql, /create trigger training_memberships_access_assignment_exclusivity[\s\S]+after insert or update of active, organization_id, training_role on public\.training_memberships/);
  });

  it("secures all new functions with SECURITY DEFINER, search_path='', and service_role execute", async () => {
    const sql = await readFile(migrationPath, "utf8");
    const rpcs = [
      "list_internal_admin_access_assignments",
      "grant_internal_admin_training_supervisor",
      "suspend_internal_admin_training_supervisor",
      "reactivate_internal_admin_training_supervisor",
      "revoke_internal_admin_training_supervisor",
      "reassign_internal_admin_training_supervisor",
      "establish_training_supervisor_session",
      "get_training_supervisor_context",
    ];

    for (const rpc of rpcs) {
      assert.match(sql, new RegExp(`create or replace function public\\.${rpc}`));
      assert.match(sql, new RegExp(`revoke all on function public\\.${rpc}[^;]+from public, anon, authenticated`));
      assert.match(sql, new RegExp(`grant execute on function public\\.${rpc}[^;]+to service_role`));
      assert.doesNotMatch(sql, new RegExp(`grant execute on function public\\.${rpc}[^;]+to authenticated`));
    }

    assert.match(sql, /revoke all on function public\.get_training_account_context\(uuid\) from public, anon, authenticated, service_role/);
  });

  it("rotates credential_version on lifecycle mutations and validates session in context RPC", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /credential_version = gen_random_uuid\(\)/);
    assert.match(sql, /training supervisor session has been revoked/);
    assert.match(sql, /credential version is required/);
  });

  it("exposes internal admin access assignment endpoints and admin service methods", async () => {
    const [app, admin] = await Promise.all([readFile(appPath, "utf8"), readFile(adminPath, "utf8")]);

    assert.match(app, /\/api\/v1\/internal-admin\/organizations\/:organizationId\/access-assignments/);
    assert.match(app, /\/api\/v1\/internal-admin\/organizations\/:organizationId\/access-assignments\/training-supervisors/);
    assert.match(app, /training-supervisors\/:userId\/suspend/);
    assert.match(app, /training-supervisors\/:userId\/reactivate/);
    assert.match(app, /training-supervisors\/:userId\/reassign/);
    assert.match(app, /\/api\/v1\/training-supervisor\/session/);
    assert.match(app, /\/api\/v1\/training-supervisor\/context/);

    assert.match(admin, /listAccessAssignmentsForInternalAdmin/);
    assert.match(admin, /grantTrainingSupervisorForInternalAdmin/);
    assert.match(admin, /suspendTrainingSupervisorForInternalAdmin/);
    assert.match(admin, /reactivateTrainingSupervisorForInternalAdmin/);
    assert.match(admin, /revokeTrainingSupervisorForInternalAdmin/);
    assert.match(admin, /reassignTrainingSupervisorForInternalAdmin/);
    assert.match(admin, /establishTrainingSupervisorSession/);
    assert.match(admin, /getTrainingSupervisorContext/);
  });
});
