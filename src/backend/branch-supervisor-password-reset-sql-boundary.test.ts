import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../../supabase/migrations/20261119120000_branch_supervisor_secure_password_reset.sql", import.meta.url), "utf8");
const service = readFileSync(new URL("./branch-supervisor-password-reset.ts", import.meta.url), "utf8");

test("Branch Supervisor reset is independently scoped and fail-closed", () => {
  assert.match(migration, /membership\.role='branch_manager'/);
  assert.match(migration, /private\.is_internal_admin/);
  assert.match(migration, /organization_id=p_organization_id/);
  assert.match(migration, /delete from auth\.sessions/);
  assert.match(migration, /grant execute on function public\.begin_branch_supervisor_password_reset/);
  assert.match(migration, /revoke all on function public\.begin_branch_supervisor_password_reset/);
  assert.match(migration, /set search_path=''?/);
  assert.doesNotMatch(service, /temporary_password\s*:/);
  assert.match(service, /randomBytes\(24\)/);
});
