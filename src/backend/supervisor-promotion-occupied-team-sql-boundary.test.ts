import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationUrl = new URL(
  "../../supabase/migrations/20260929120000_supervisor_promotion_allows_occupied_team.sql",
  import.meta.url,
);

describe("Supervisor promotion from an occupied operational team", () => {
  it("replaces only the authoritative seven-argument promotion RPC", async () => {
    const sql = await readFile(migrationUrl, "utf8");

    assert.match(sql, /create or replace function public\.promote_managed_operational_staff_supervisor_training\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*target_staff_id uuid,\s*new_supervisor_user_id uuid,\s*new_supervisor_full_name text,\s*new_supervisor_full_name_ar text,\s*target_branch_id uuid default null\s*\) returns jsonb/);
    assert.match(sql, /language plpgsql\s+security definer\s+set search_path = ''/);
    assert.match(sql, /revoke all on function public\.promote_managed_operational_staff_supervisor_training\(uuid, uuid, uuid, uuid, text, text, uuid\)/);
    assert.match(sql, /grant execute on function public\.promote_managed_operational_staff_supervisor_training\(uuid, uuid, uuid, uuid, text, text, uuid\)\s+to service_role/);
  });

  it("inherits only when no other active primary exists", async () => {
    const sql = await readFile(migrationUrl, "utf8");

    assert.match(sql, /inherited_operational_team_id uuid := null;/);
    assert.match(sql, /from public\.branch_operational_teams team[\s\S]*where team\.id = assignment_row\.operational_team_id[\s\S]*for update;[\s\S]*if not exists \([\s\S]*assignment_role = 'primary'[\s\S]*supervisor_assignment\.active[\s\S]*supervisor_assignment\.supervisor_user_id <> new_supervisor_user_id[\s\S]*\) then/);
    assert.match(sql, /if existing_team_supervisor_row\.id is null then[\s\S]*insert into public\.branch_operational_team_supervisors[\s\S]*inherited_operational_team_id := assignment_row\.operational_team_id;\s*end if;/);
    assert.doesNotMatch(sql, /raise exception 'operational team already has active primary supervisor'/);
    assert.doesNotMatch(sql, /drop\s+(index|constraint)[\s\S]*branch_operational_team_supervisors_active_primary_key/i);
  });

  it("preserves common staff, training, membership, and audit finalization", async () => {
    const sql = await readFile(migrationUrl, "utf8");

    assert.match(sql, /select \* into target_membership_row[\s\S]*from public\.branch_memberships[\s\S]*for update;/);
    assert.match(sql, /if active_branch_count <> 1 or current_branch_id <> resolved_target_branch_id then[\s\S]*raise exception 'supervisor active branch state conflict'/);
    assert.match(sql, /update public\.operational_staff_assignments\s+set active = false,[\s\S]*closure_reason = 'promoted_to_supervisor'/);
    assert.match(sql, /update public\.operational_staff\s+set employment_status = 'inactive'/);
    assert.match(sql, /update public\.operational_staff_supervisor_training\s+set status = 'promoted',[\s\S]*promoted_supervisor_user_id = new_supervisor_user_id/);
    assert.match(sql, /'inherited_operational_team_id', inherited_operational_team_id/);
    assert.match(sql, /return private\.operational_staff_supervisor_training_json\(training_row\.id\);/);
  });
});
