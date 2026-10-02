import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20261002150000_internal_admin_supervisor_demote_to_staff.sql");
const appPath = path.resolve("src/backend/app.ts");
const adminPath = path.resolve("src/backend/admin.ts");

describe("Internal Admin Supervisor demotion migration", () => {
  it("adds an unambiguous account identity without name-based matching", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /account_user_id uuid references auth\.users\(id\) on delete restrict/);
    assert.match(sql, /unique index if not exists operational_staff_organization_account_user_key/);
    assert.match(sql, /count\(distinct other\.operational_staff_id\)[\s\S]+count\(distinct other\.promoted_supervisor_user_id\)/);
    assert.doesNotMatch(sql, /staff\.display_name\s*=\s*profile\.full_name/i);
    assert.doesNotMatch(sql, /staff\.email\s*=\s*auth_user\.email/i);
  });

  it("uses a locked, service-role-only atomic lifecycle mutation", async () => {
    const sql = await readFile(migrationPath, "utf8");
    const body = sql.split("create or replace function public.demote_internal_admin_supervisor_to_staff(")[1] ?? "";
    assert.match(body, /pg_advisory_xact_lock/);
    assert.match(body, /for update of assignment, team/);
    assert.match(body, /expected_active_branch_ids/);
    assert.match(body, /expected_active_supervisor_assignment_ids/);
    assert.match(body, /replacement primary supervisor required/);
    assert.match(body, /update public\.branch_operational_team_supervisors[\s\S]+set active = false/);
    assert.match(body, /insert into public\.operational_staff_assignments/);
    assert.match(body, /supervisor_demoted_to_staff/);
    assert.match(sql, /revoke all on function public\.demote_internal_admin_supervisor_to_staff[\s\S]+grant execute[\s\S]+to service_role/);
    assert.doesNotMatch(sql, /grant execute on function public\.demote_internal_admin_supervisor_to_staff[^;]+authenticated/);
  });

  it("preserves history and prevents simultaneous active Staff and Supervisor roles", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /account cannot be active as supervisor and operational staff/);
    assert.doesNotMatch(sql, /delete from public\.branch_operational_team_supervisors/i);
    assert.doesNotMatch(sql, /delete from public\.operational_staff_assignments/i);
    assert.doesNotMatch(sql, /insert into public\.branch_memberships[\s\S]+['"]staff['"]/i);
  });

  it("exposes strict preflight and mutation API contracts", async () => {
    const [app, admin] = await Promise.all([readFile(appPath, "utf8"), readFile(adminPath, "utf8")]);
    assert.match(app, /supervisors\/:userId\/demotion-eligibility/);
    assert.match(app, /supervisors\/:userId\/demote-to-staff/);
    assert.match(app, /operational_roles: z\.array\(operationalRoleSchema\)\.min\(1\)\.max\(2\)/);
    assert.match(app, /AdminConflictError[\s\S]+HttpError\(409/);
    assert.match(admin, /rpc\("get_internal_admin_supervisor_demotion_eligibility"/);
    assert.match(admin, /rpc\("demote_internal_admin_supervisor_to_staff"/);
  });
});
