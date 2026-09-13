import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migrationPath = new URL(
  "../../supabase/migrations/20260913150000_supervisor_promotion_cross_branch.sql",
  import.meta.url,
);
const source = readFileSync(migrationPath, "utf8");

describe("Supervisor promotion cross-branch migration boundary", () => {
  it("drops old 6-parameter function and creates authoritative 7-parameter function with default null", () => {
    assert.match(
      source,
      /drop function if exists public\.promote_managed_operational_staff_supervisor_training\(\s*uuid,\s*uuid,\s*uuid,\s*uuid,\s*text,\s*text\s*\);/,
    );
    assert.match(
      source,
      /create function public\.promote_managed_operational_staff_supervisor_training\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*target_staff_id uuid,\s*new_supervisor_user_id uuid,\s*new_supervisor_full_name text,\s*new_supervisor_full_name_ar text,\s*target_branch_id uuid default null\s*\) returns jsonb/,
    );
  });

  it("resolves target branch falling back to staff origin branch when null", () => {
    assert.match(
      source,
      /resolved_target_branch_id := coalesce\(target_branch_id, staff_row\.branch_id\);/,
    );
  });

  it("strictly validates that target branch exists, is active, and belongs to target organization", () => {
    assert.match(
      source,
      /select branch\.\* into strict target_branch_row\s+from public\.branches branch\s+where branch\.id = resolved_target_branch_id\s+and branch\.organization_id = target_organization_id\s+and branch\.active;/,
    );
  });

  it("assigns supervisor branch_memberships using resolved target branch", () => {
    assert.match(
      source,
      /insert into public\.branch_memberships\(branch_id, user_id, role, active\)\s+values\(resolved_target_branch_id, new_supervisor_user_id, 'branch_manager', true\)/,
    );
  });

  it("closes origin staff assignment using staff_row.branch_id without mutating target branch assignments", () => {
    assert.match(
      source,
      /and assignment\.branch_id = staff_row\.branch_id\s+and assignment\.active\s+for update;/,
    );
    assert.match(
      source,
      /update public\.operational_staff_assignments\s+set active = false,\s+valid_to = greatest\(valid_from, current_date\),\s+closed_at = now\(\),\s+closed_by_user_id = actor_user_id,\s+closure_reason = 'promoted_to_supervisor'\s+where id = assignment_row\.id;/,
    );
  });

  it("preserves operational staff deactivation and training promotion lifecycle", () => {
    assert.match(
      source,
      /update public\.operational_staff\s+set employment_status = 'inactive',\s+deactivated_at = now\(\),\s+deactivated_by = actor_user_id\s+where id = staff_row\.id;/,
    );
    assert.match(
      source,
      /update public\.operational_staff_supervisor_training\s+set status = 'promoted',\s+promoted_at = now\(\),\s+promoted_by_user_id = actor_user_id,\s+promoted_supervisor_user_id = new_supervisor_user_id\s+where id = training_row\.id/,
    );
  });

  it("records both origin_branch_id and target_branch_id in audit logs", () => {
    assert.match(
      source,
      /values\(\s*target_organization_id,\s*actor_user_id,\s*new_supervisor_user_id,\s*resolved_target_branch_id,\s*'operational_staff_supervisor_training_promoted'/,
    );
    assert.match(source, /'origin_branch_id', staff_row\.branch_id/);
    assert.match(source, /'target_branch_id', resolved_target_branch_id/);
  });

  it("preserves empty search path and service_role execute grant", () => {
    assert.match(source, /security definer\s+set search_path = ''/);
    assert.match(
      source,
      /revoke all on function public\.promote_managed_operational_staff_supervisor_training\(uuid, uuid, uuid, uuid, text, text, uuid\)\s+from public, anon, authenticated;/,
    );
    assert.match(
      source,
      /grant execute on function public\.promote_managed_operational_staff_supervisor_training\(uuid, uuid, uuid, uuid, text, text, uuid\)\s+to service_role;/,
    );
  });

  it("notifies postgrest to reload schema cache", () => {
    assert.match(source, /notify\s+pgrst,\s*'reload schema';/);
  });

  it("does not update historical business tables and introduces no hard deletes", () => {
    assert.doesNotMatch(source, /delete\s+from/i);
    assert.doesNotMatch(source, /truncate/i);
    assert.doesNotMatch(source, /drop\s+table/i);
    assert.doesNotMatch(source, /update\s+public\.daily_audit/i);
    assert.doesNotMatch(source, /update\s+public\.checklist/i);
    assert.doesNotMatch(source, /update\s+public\.sales/i);
    assert.doesNotMatch(source, /update\s+public\.inventory/i);
  });
});
