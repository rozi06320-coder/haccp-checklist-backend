import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261103100000_atomic_access_role_transition.sql");
const appPath = path.resolve("src/backend/app.ts");
const adminPath = path.resolve("src/backend/admin.ts");

describe("Atomic Role Transition SQL Boundary and Architecture", () => {
  it("uses authoritative public.training_memberships and public.training_membership_branches", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.doesNotMatch(sql, /create table.*training_supervisor_assignments/i);
    assert.match(sql, /insert into public\.training_memberships\(/);
    assert.match(sql, /insert into public\.training_membership_branches\(/);
    assert.match(sql, /delete from public\.training_membership_branches/);
  });

  it("preserves all 51 audit actions and adds user_role_transitioned without dropping valid actions", async () => {
    const sql = await readFile(migrationPath, "utf8");
    const requiredActions = [
      "user_created", "user_disabled", "user_enabled", "temporary_password_reset",
      "password_changed", "branch_created", "branch_assignment_added", "branch_assignment_removed",
      "branch_role_changed", "daily_audit_pin_configured", "daily_audit_pin_replaced",
      "daily_audit_access_granted", "daily_audit_user_access_granted", "daily_audit_user_access_revoked",
      "daily_audit_access_user_created", "daily_audit_access_user_revoked",
      "maintenance_access_user_created", "maintenance_access_user_deactivated",
      "maintenance_user_created", "maintenance_user_deactivated",
      "training_account_created", "training_account_updated", "training_account_deactivated",
      "training_account_reactivated", "training_account_password_reset",
      "training_supervisor_granted", "training_supervisor_suspended", "training_supervisor_reactivated",
      "training_supervisor_revoked", "training_supervisor_reassigned",
      "branch_shift_created", "branch_shift_updated",
      "supervisor_team_assigned", "supervisor_team_deactivated", "supervisor_profile_updated",
      "operational_staff_created", "operational_staff_updated", "operational_staff_deactivated",
      "operational_staff_assignment_created", "operational_staff_assignment_updated",
      "operational_staff_assignment_deactivated", "operational_staff_duty_changed",
      "organization_logo_updated", "branch_logo_updated",
      "operational_staff_supervisor_training_started", "operational_staff_supervisor_training_cancelled",
      "operational_staff_supervisor_training_promoted",
      "purchasing_user_created", "purchasing_membership_enabled", "purchasing_membership_disabled",
      "supervisor_demoted_to_staff",
      "user_role_transitioned"
    ];

    for (const action of requiredActions) {
      assert.match(sql, new RegExp(`'${action}'`), `Missing audit action: ${action}`);
    }
  });

  it("implements transition_internal_admin_access_role with SECURITY DEFINER and search_path=''", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /create or replace function public\.transition_internal_admin_access_role\(/);
    assert.match(sql, /security definer/);
    assert.match(sql, /set search_path = ''/);
    assert.match(sql, /revoke all on function public\.transition_internal_admin_access_role[^;]+from public, anon, authenticated, service_role/);
    assert.match(sql, /grant execute on function public\.transition_internal_admin_access_role[^;]+to service_role/);
    assert.doesNotMatch(sql, /grant execute on function public\.transition_internal_admin_access_role[^;]+to authenticated/);
  });

  it("enforces serializing concurrency locks and profile row locking", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /perform pg_advisory_xact_lock\(hashtext\('user_role_transition_' \|\| target_user_id::text\)\)/);
    assert.match(sql, /for update/);
  });

  it("orders deactivation before activation to satisfy mutual exclusivity trigger", async () => {
    const sql = await readFile(migrationPath, "utf8");
    const supervisorToTrainingMatch = sql.indexOf("source_role = 'supervisor' and target_role = 'training_supervisor'");
    const deactSupervisor = sql.indexOf("set active = false, updated_at = now()", supervisorToTrainingMatch);
    const actTraining = sql.indexOf("insert into public.training_memberships", supervisorToTrainingMatch);
    assert.ok(deactSupervisor < actTraining, "Supervisor membership must be deactivated before activating training membership");

    const trainingToSupervisorMatch = sql.indexOf("source_role = 'training_supervisor' and target_role = 'supervisor'");
    const deactTraining = sql.indexOf("update public.training_memberships\n    set active = false", trainingToSupervisorMatch);
    const actSupervisor = sql.indexOf("insert into public.branch_memberships", trainingToSupervisorMatch);
    assert.ok(deactTraining < actSupervisor, "Training membership must be deactivated before activating supervisor branch membership");
  });

  it("preserves operational team history using valid_to = greatest(valid_from, current_date)", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /valid_to = greatest\(assignment\.valid_from, current_date\)/);
  });

  it("never includes credential_version or secrets in audit logs", async () => {
    const sql = await readFile(migrationPath, "utf8");
    const auditBlocks = sql.match(/insert into public\.account_management_audit_logs[\s\S]+?\);/g) ?? [];
    assert.ok(auditBlocks.length >= 2, "Expected audit log statements in migration");
    for (const block of auditBlocks) {
      assert.doesNotMatch(block, /credential_version/i, "Audit log must not contain credential_version");
      assert.doesNotMatch(block, /token/i, "Audit log must not contain token");
      assert.doesNotMatch(block, /password/i, "Audit log must not contain password");
    }
  });

  it("exposes the atomic transition route in app.ts and admin service in admin.ts", async () => {
    const [app, admin] = await Promise.all([readFile(appPath, "utf8"), readFile(adminPath, "utf8")]);
    assert.match(app, /\/api\/v1\/internal-admin\/organizations\/:organizationId\/access-assignments\/transition/);
    assert.match(app, /transitionAccessRoleBodySchema/);
    assert.match(admin, /transitionAccessRoleForInternalAdmin/);
    assert.match(admin, /admin\.rpc\("transition_internal_admin_access_role"/);
  });
});
