import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migrationPath = new URL(
  "../../supabase/migrations/20260903110000_manager_unified_people_directory.sql",
  import.meta.url,
);
const source = readFileSync(migrationPath, "utf8");
const dryRunPath = new URL("file:///tmp/manager-unified-people-directory-production-dry-run.sql");
const dryRunSource = existsSync(dryRunPath) ? readFileSync(dryRunPath, "utf8") : null;

describe("Manager unified people directory migration boundary", () => {
  it("adds only the versioned additive people reader contract", () => {
    assert.match(source, /create function public\.list_managed_people_directory\(\s*actor_user_id uuid,\s*target_organization_id uuid,\s*branch_filter uuid default null,\s*requested_month date default null,\s*search_term text default null,\s*code_filter text default null\s*\) returns jsonb/s);
    assert.doesNotMatch(source, /create\s+or\s+replace\s+function\s+public\.list_managed_employee_team/i);
    assert.doesNotMatch(source, /drop\s+function/i);
  });

  it("uses strict Manager scope and active Supervisor membership sources", () => {
    assert.match(source, /private\.actor_manages_active_organization\(actor_user_id, target_organization_id\)/);
    assert.match(source, /from public\.branch_memberships membership/);
    assert.match(source, /membership\.role = 'branch_manager'/);
    assert.match(source, /membership\.active/);
    assert.match(source, /branch\.active/);
    assert.match(source, /organization\.active/);
    assert.match(source, /from public\.operational_staff staff/);
  });

  it("keeps a discriminated union and calendar-month New semantics", () => {
    assert.match(source, /'person_type', 'staff'/);
    assert.match(source, /'person_type', 'supervisor'/);
    assert.match(source, /staff\.created_at \+ interval '1 month'/);
    assert.match(source, /pg_catalog\.min\(membership\.created_at\) as joined_at/);
    assert.match(source, /organization_join\.joined_at \+ interval '1 month'/);
    assert.doesNotMatch(source, /profile\.created_at as joined_at/);
    const organizationJoinCte = source.slice(source.indexOf("supervisor_organization_joins"), source.indexOf("supervisor_people as materialized"));
    assert.doesNotMatch(organizationJoinCte, /membership\.active/);
    assert.doesNotMatch(organizationJoinCte, /membership\.role/);
    assert.match(source, /joined_at <= pg_catalog\.now\(\) and pg_catalog\.now\(\) < supervisor\.new_until/);
    assert.equal(source.match(/pg_catalog\.now\(\)/g)?.length, 4);
    assert.doesNotMatch(source.replaceAll("pg_catalog.now()", ""), /\bnow\(\)/);
    const supervisorObject = source.slice(source.indexOf("'person_type', 'supervisor'"), source.indexOf("from supervisor_people supervisor"));
    for (const staffOnlyField of ["staff_id", "assignment_id", "operational_team_id", "operational_roles", "supervisor_training_status"]) {
      assert.doesNotMatch(supervisorObject, new RegExp(`'${staffOnlyField}'`));
    }
  });

  it("uses parsed empty-search-path assertions in the local SQL Editor dry run", { skip: dryRunSource === null }, () => {
    assert.equal(dryRunSource?.match(/pg_catalog\.pg_options_to_table\(function\.proconfig\)/g)?.length, 3);
    assert.equal(dryRunSource?.match(/option\.option_name = 'search_path'/g)?.length, 3);
    assert.equal(dryRunSource?.match(/option\.option_value in \('', '""'\)/g)?.length, 3);
    assert.doesNotMatch(dryRunSource ?? "", /option\.option_value = ''/);
    assert.doesNotMatch(dryRunSource ?? "", /\boption\.(?:name|setting)\b/);
    assert.doesNotMatch(dryRunSource ?? "", /array_to_string\(function\.proconfig|proconfig\s*@>|'search_path=|search_path=\\"\\"/);
  });

  it("uses literal bounded search and canonical code filters", () => {
    assert.match(source, /normalized_code_filter text := nullif\(pg_catalog\.btrim\(code_filter\), ''\)/);
    assert.match(source, /pg_catalog\.length\(coalesce\(code_filter, ''\)\) > 64/);
    assert.match(source, /pg_catalog\.strpos\(pg_catalog\.lower\(coalesce\(staff\.staff_code, ''\)\), pg_catalog\.lower\(normalized_code_filter\)\) > 0/);
    assert.match(source, /pg_catalog\.strpos\(pg_catalog\.lower\(coalesce\(profile\.person_code, ''\)\), pg_catalog\.lower\(normalized_code_filter\)\) > 0/);
    assert.doesNotMatch(source, /ilike/);
  });

  it("deduplicates promotions only through the explicit promotion relation", () => {
    assert.match(source, /promotion\.promoted_supervisor_user_id/);
    assert.match(source, /promotion\.status = 'promoted'/);
    assert.doesNotMatch(source, /staff\.display_name\s*=\s*supervisor/i);
    assert.doesNotMatch(source, /staff\.email\s*=\s*supervisor/i);
    assert.doesNotMatch(source, /staff\.phone_number\s*=\s*supervisor/i);
  });

  it("publishes bounded results and service-role-only execution", () => {
    assert.match(source, /people_limit constant integer := 1000/);
    assert.match(source, /'people_total'/);
    assert.match(source, /'people_truncated'/);
    assert.match(source, /security definer/);
    assert.match(source, /set search_path = ''/);
    assert.match(source, /revoke all on function public\.list_managed_people_directory\(uuid, uuid, uuid, date, text, text\)\s+from public, anon, authenticated/);
    assert.match(source, /grant execute on function public\.list_managed_people_directory\(uuid, uuid, uuid, date, text, text\)\s+to service_role/);
  });
});
