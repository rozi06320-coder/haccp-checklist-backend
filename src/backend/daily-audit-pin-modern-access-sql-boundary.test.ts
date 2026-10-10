import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL(
  "../../supabase/migrations/20261010210000_daily_audit_pin_modern_branch_access.sql",
  import.meta.url,
);

const signatures = [
  "public.get_daily_audit_access_user_credentials(uuid, uuid)",
  "public.get_organization_manager_daily_audit_credentials(uuid, uuid)",
  "public.record_organization_manager_daily_audit_access_grant(uuid, uuid, uuid, uuid)",
  "public.validate_organization_manager_daily_audit_grant(uuid, uuid, uuid, uuid)",
] as const;

describe("Daily Audit PIN modern branch access SQL boundary", () => {
  it("replaces exactly the four PIN credential and grant functions", async () => {
    const migration = await readFile(migrationPath, "utf8");
    const replaced = [...migration.matchAll(/create or replace function\s+([^\n(]+)\s*\(/gi)]
      .map((match) => match[1]?.trim());

    assert.deepEqual(replaced, [
      "public.get_daily_audit_access_user_credentials",
      "public.get_organization_manager_daily_audit_credentials",
      "public.record_organization_manager_daily_audit_access_grant",
      "public.validate_organization_manager_daily_audit_grant",
    ]);
    assert.doesNotMatch(
      migration,
      /create or replace function\s+(?:private\.actor_owns_operational_team|public\.(?:get_supervisor_daily_audit_current_state|save_supervisor_daily_audit_draft|submit_supervisor_daily_audit))/i,
    );
  });

  it("uses canonical branch access without retaining the legacy team dependency", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.equal(
      (migration.match(/private\.actor_can_read_operational_branch\(actor_user_id, target_branch_id\)/g) ?? []).length,
      4,
    );
    assert.doesNotMatch(migration, /private\.actor_owns_operational_team/i);
    assert.doesNotMatch(migration, /branch_supervisor_teams/i);
    assert.match(migration, /branch\.active/);
    assert.match(migration, /organization\.active/);
  });

  it("preserves credential-version validation, safe grant auditing, and hardened definitions", async () => {
    const migration = await readFile(migrationPath, "utf8");

    assert.match(migration, /credential\.credential_version = target_credential_version/);
    assert.match(migration, /'daily_audit_access_granted'/);
    assert.match(migration, /jsonb_build_object\('credential_version', target_credential_version\)/);
    assert.equal((migration.match(/security definer/g) ?? []).length, 4);
    assert.equal((migration.match(/set search_path = ''/g) ?? []).length, 4);
    assert.doesNotMatch(migration, /pin_hash[^\n]*account_management_audit_logs|details[^\n]*pin|raw.*error/i);
  });

  it("keeps all four RPCs service-role-only", async () => {
    const migration = await readFile(migrationPath, "utf8");

    for (const signature of signatures) {
      const escaped = escapeRegExp(signature);
      assert.match(
        migration,
        new RegExp(`revoke all on function ${escaped} from public, anon, authenticated;`),
      );
      assert.match(
        migration,
        new RegExp(`grant execute on function ${escaped} to service_role;`),
      );
    }
    assert.doesNotMatch(migration, /grant execute on function [^;]+ to (?:public|anon|authenticated);/i);
  });
});

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/ /g, "\\s+");
}
