import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const crossBranchMigrationPath = new URL(
  "../../supabase/migrations/20260913150000_supervisor_promotion_cross_branch.sql",
  import.meta.url,
);
const transferMigrationPath = new URL(
  "../../supabase/migrations/20260914100000_supervisor_promotion_target_branch_transfer.sql",
  import.meta.url,
);

const crossBranchSource = readFileSync(crossBranchMigrationPath, "utf8");
const transferSource = readFileSync(transferMigrationPath, "utf8");

describe("Supervisor promotion cross-branch migration boundary (20260913150000)", () => {
  it("drops old 6-parameter function and creates authoritative 7-parameter function with default null", () => {
    assert.match(
      crossBranchSource,
      /drop function if exists public\.promote_managed_operational_staff_supervisor_training\(\s*uuid,\s*uuid,\s*uuid,\s*uuid,\s*text,\s*text\s*\);/,
    );
    assert.match(
      crossBranchSource,
      /create function public\.promote_managed_operational_staff_supervisor_training\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*target_staff_id uuid,\s*new_supervisor_user_id uuid,\s*new_supervisor_full_name text,\s*new_supervisor_full_name_ar text,\s*target_branch_id uuid default null\s*\) returns jsonb/,
    );
  });

  it("notifies postgrest to reload schema cache", () => {
    assert.match(crossBranchSource, /notify\s+pgrst,\s*'reload schema';/);
  });
});

describe("Supervisor promotion target branch transfer migration boundary (20260914100000)", () => {
  it("1. employee Branch A -> Supervisor Branch B succeeds by resolving explicit target branch and validating it", () => {
    assert.match(
      transferSource,
      /resolved_target_branch_id := coalesce\(target_branch_id, staff_row\.branch_id\);/,
    );
    assert.match(
      transferSource,
      /select branch\.\* into strict target_branch_row\s+from public\.branches branch\s+where branch\.id = resolved_target_branch_id\s+and branch\.organization_id = target_organization_id\s+and branch\.active;/,
    );
  });

  it("2. origin operational assignment closes using staff_row.branch_id and records closure reason", () => {
    assert.match(
      transferSource,
      /and assignment\.branch_id = staff_row\.branch_id\s+and assignment\.active\s+for update;/,
    );
    assert.match(
      transferSource,
      /update public\.operational_staff_assignments\s+set active = false,\s+valid_to = greatest\(valid_from, current_date\),\s+closed_at = now\(\),\s+closed_by_user_id = actor_user_id,\s+closure_reason = 'promoted_to_supervisor'\s+where id = assignment_row\.id;/,
    );
  });

  it("3. target branch_manager membership active created when membership missing", () => {
    assert.match(
      transferSource,
      /if target_membership_row\.branch_id is null then\s+insert into public\.branch_memberships\(branch_id, user_id, role, active, updated_at\)\s+values\(resolved_target_branch_id, new_supervisor_user_id, 'branch_manager', true, now\(\)\);/,
    );
  });

  it("4. existing inactive target membership reactivates as branch_manager", () => {
    assert.match(
      transferSource,
      /elsif not target_membership_row\.active then\s+update public\.branch_memberships\s+set role = 'branch_manager',\s+active = true,\s+updated_at = now\(\)\s+where branch_id = resolved_target_branch_id\s+and user_id = new_supervisor_user_id;/,
    );
  });

  it("5. compatible active target membership is idempotent", () => {
    assert.match(
      transferSource,
      /elsif target_membership_row\.role = 'branch_manager' then\s+update public\.branch_memberships\s+set updated_at = now\(\)\s+where branch_id = resolved_target_branch_id\s+and user_id = new_supervisor_user_id;/,
    );
  });

  it("6. old active membership that represents transferable current origin branch state is deactivated", () => {
    assert.match(
      transferSource,
      /if other_active_branch_id = staff_row\.branch_id then\s+update public\.branch_memberships membership\s+set active = false,\s+updated_at = now\(\)\s+where membership\.branch_id = staff_row\.branch_id\s+and membership\.user_id = new_supervisor_user_id\s+and membership\.active;/,
    );
  });

  it("7. ambiguous multiple active memberships fail closed", () => {
    assert.match(
      transferSource,
      /if other_active_count > 1 then\s+raise exception 'supervisor multiple active branch memberships conflict' using errcode = '23514';/,
    );
    assert.match(
      transferSource,
      /else\s+raise exception 'supervisor active branch state conflict' using errcode = '23514';\s+end if;/,
    );
  });

  it("8. cross-org membership is not modified (scoped strictly to target_organization_id)", () => {
    assert.match(
      transferSource,
      /where branch\.organization_id = target_organization_id\s+and membership\.user_id = new_supervisor_user_id/,
    );
  });

  it("9. historical rows not deleted; business tables and staff origin history preserved", () => {
    assert.doesNotMatch(transferSource, /delete\s+from/i);
    assert.doesNotMatch(transferSource, /truncate/i);
    assert.doesNotMatch(transferSource, /drop\s+table/i);
    assert.doesNotMatch(transferSource, /update\s+public\.daily_audit/i);
    assert.doesNotMatch(transferSource, /update\s+public\.checklist/i);
    assert.doesNotMatch(transferSource, /update\s+public\.sales/i);
    assert.doesNotMatch(transferSource, /update\s+public\.inventory/i);
    assert.doesNotMatch(transferSource, /update\s+public\.maintenance/i);
    assert.doesNotMatch(transferSource, /update\s+public\.operational_staff\s+set[^;]*branch_id\s*=/i);
    assert.match(transferSource, /'origin_branch_id',\s*staff_row\.branch_id/);
    assert.match(transferSource, /'target_branch_id',\s*resolved_target_branch_id/);
  });

  it("10. already-promoted retry with same target is idempotent", () => {
    assert.match(
      transferSource,
      /if training_row\.promoted_supervisor_user_id <> new_supervisor_user_id then\s+raise exception 'supervisor promotion already completed' using errcode = '23505';\s+end if;/,
    );
    assert.match(
      transferSource,
      /return private\.operational_staff_supervisor_training_json\(training_row\.id\);/,
    );
  });

  it("11. already-promoted retry with different target does NOT silently succeed", () => {
    assert.match(
      transferSource,
      /if established_target_branch_id is null then\s+raise exception 'supervisor promotion established branch indeterminate' using errcode = '23514';\s+end if;/,
    );
    assert.match(
      transferSource,
      /if target_branch_id is not null and target_branch_id <> established_target_branch_id then\s+raise exception 'supervisor promotion target branch conflict' using errcode = '40001';\s+end if;/,
    );
  });

  it("12. transaction remains atomic with concurrency locks, post-check guarantee, and stacked diagnostics", () => {
    assert.match(transferSource, /for update of membership/);
    assert.match(transferSource, /if active_branch_count <> 1 or current_branch_id <> resolved_target_branch_id then\s+raise exception 'supervisor active branch state conflict' using errcode = '23514';/);
    assert.match(transferSource, /get stacked diagnostics\s+v_constraint_name = constraint_name,\s+v_message_text = message_text;/);
    assert.match(transferSource, /using errcode = '23505', constraint = v_constraint_name;/);
    assert.match(transferSource, /notify\s+pgrst,\s*'reload schema';/);
  });
});
