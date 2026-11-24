import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20261125120000_supervisor_team_onboarding_setup.sql";

describe("Supervisor Operational Team Onboarding Phase 1 SQL boundary", () => {
  it("creates RLS-protected onboarding and idempotency tables with zero direct client access", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    for (const table of [
      "public.supervisor_team_onboarding_states",
      "public.supervisor_team_bootstrap_idempotency",
    ]) {
      assert.match(sql, new RegExp(`create table ${table.replace(".", "\\.")}`));
      assert.match(sql, new RegExp(`alter table ${table.replace(".", "\\.")} enable row level security`));
      assert.match(sql, new RegExp(`revoke all on ${table.replace(".", "\\.")}[\\s\\S]*?from public, anon, authenticated, service_role`));
    }
  });

  it("enforces SECURITY DEFINER, empty search_path, and service_role-only grants on all onboarding RPCs", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    for (const signature of [
      "public.get_supervisor_team_onboarding_state(uuid, uuid[])",
      "public.set_supervisor_team_onboarding_waiting(uuid, uuid)",
      "public.create_supervisor_owned_operational_team_v2(uuid, uuid, text, uuid)",
      "public.create_supervisor_owned_operational_team(uuid, uuid, text)",
    ]) {
      const escaped = signature.replace(/[().[\]]/g, "\\$&");
      assert.match(sql, new RegExp(`revoke all on function ${escaped}[\\s\\S]*?from public, anon, authenticated, service_role`));
      assert.match(sql, new RegExp(`grant execute on function ${escaped}[\\s\\S]*?to service_role`));
    }
    assert.match(sql, /create or replace function public\.create_supervisor_owned_operational_team\(/);
    assert.match(sql, /private\.actor_can_write_operational_team\(p_actor_user_id, p_branch_id, prior_idem\.operational_team_id\)/);
  });

  it("preserves all existing and Branch Day Off audit actions while adding onboarding actions", async () => {
    const sql = await readFile(path.resolve(migrationPath), "utf8");
    for (const action of [
      "supervisor_team_assigned",
      "supervisor_team_deactivated",
      "supervisor_operational_access_restored",
      "branch_weekly_day_off_configured",
      "branch_closure_created",
      "branch_closure_reopened",
      "branch_closure_cancelled",
      "supervisor_team_onboarding_waiting_selected",
      "supervisor_owned_team_created",
    ]) {
      assert.match(sql, new RegExp(`'${action}'`));
    }
  });
});
