import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(new URL("../../supabase/migrations/20261104110000_authoritative_supervisor_classification_read_contract.sql", import.meta.url), "utf8");
const operational = readFileSync(new URL("./operational.ts", import.meta.url), "utf8");
const admin = readFileSync(new URL("./admin.ts", import.meta.url), "utf8");

describe("authoritative Supervisor classification read contracts", () => {
  it("adds versioned RPCs without replacing deployed RPC signatures", () => {
    assert.match(migration, /create function public\.list_managed_people_directory_v2\(/);
    assert.match(migration, /create function public\.list_internal_admin_supervisors_v2\(/);
    assert.doesNotMatch(migration, /drop function public\.(?:list_managed_people_directory|list_internal_admin_supervisors)\(/);
  });

  it("uses branch_manager authorization and classification metadata, defaulting only active operational users", () => {
    assert.match(migration, /membership\.role = 'branch_manager'/);
    assert.match(migration, /membership\.active/);
    assert.match(migration, /supervisor_access_classifications/);
    assert.match(migration, /coalesce\(\(\s*select classification\.classification/s);
    assert.match(migration, /'supervisor'\)/);
    assert.match(migration, /private\.actor_manages_active_organization/);
    assert.match(migration, /private\.is_internal_admin/);
    assert.match(migration, /'person_type', 'training_supervisor'/);
    assert.match(migration, /person\.value->>'supervisor_role' = 'training_supervisor'/);
  });

  it("keeps both readers SECURITY DEFINER, search-path isolated, and service-role-only", () => {
    assert.equal(migration.match(/security definer/gi)?.length, 2);
    assert.equal(migration.match(/set search_path = ''/g)?.length, 2);
    assert.equal(migration.match(/grant execute on function public\.(?:list_managed_people_directory_v2|list_internal_admin_supervisors_v2)/g)?.length, 2);
    assert.doesNotMatch(migration, /grant execute on function public\.(?:list_managed_people_directory_v2|list_internal_admin_supervisors_v2).*\b(?:public|anon|authenticated)\b/i);
  });

  it("routes backend readers to v2 while preserving the HTTP response wrappers", () => {
    assert.match(operational, /rpcObject\("list_managed_people_directory_v2"/);
    assert.match(admin, /admin\.rpc\("list_internal_admin_supervisors_v2"/);
    assert.match(admin, /classification: z\.enum\(\["supervisor", "training_supervisor"\]\)/);
  });
});
