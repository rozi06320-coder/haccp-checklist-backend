import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";

const migrationsDirectory = resolve(process.cwd(), "supabase/migrations");
const migrationName = "20261020140000_organization_manager_secure_password_reset.sql";
const migration = readFileSync(resolve(migrationsDirectory, migrationName), "utf8");
const service = readFileSync(
  resolve(process.cwd(), "src/backend/organization-manager-password-reset.ts"),
  "utf8",
);

describe("Organization Manager password-reset SQL boundaries", () => {
  it("requires password verification and never uses session age as step-up proof", () => {
    assert.match(service, /signInWithPassword/);
    assert.match(service, /data\.user\?\.id !== input\.actorUserId/);
    assert.match(service, /const passwordClient = createPasswordClient\(\)/);
    assert.doesNotMatch(migration, /session\.created_at|recent authentication/i);
  });

  it("stores only hashes and binds the one-time grant to actor, session, tenant and target", () => {
    assert.match(migration, /actor_user_id=p_actor_user_id and grant_row\.actor_session_id=p_actor_session_id/);
    assert.match(migration, /grant_row\.organization_id=p_organization_id and grant_row\.target_user_id=p_target_user_id/);
    assert.match(migration, /grant_row\.consumed_at is null and statement_timestamp\(\)<grant_row\.expires_at/);
    assert.doesNotMatch(migration, /temporary_password\s+(?:text|varchar)|current_password\s+(?:text|varchar)/i);
  });

  it("keeps reset tables private and does not install a global account-audit trigger", () => {
    assert.match(migration, /revoke all on table public\.organization_manager_password_reset_operations[\s\S]*service_role/);
    assert.match(migration, /before update or delete on public\.organization_manager_password_reset_events/);
    assert.doesNotMatch(migration, /before update or delete on public\.account_management_audit_logs/i);
  });

  it("uses durable database limits and keyed IP hashing", () => {
    assert.match(migration, /organization_manager_password_reset_rate_limits/);
    assert.match(service, /createHmac\("sha256", rateLimitHmacKey\)/);
    assert.doesNotMatch(service, /sha256\(input\.clientIp\)/);
  });

  it("serializes reset and stale-recovery writers on the target profile", () => {
    assert.match(migration, /select profile\.must_change_password[\s\S]*for update;[\s\S]*where operation\.target_user_id=p_target_user_id[\s\S]*for update;/);
    assert.match(migration, /create unique index organization_manager_password_reset_one_unresolved_target_idx[\s\S]*where status in\('pending_auth','auth_outcome_unknown'\)/);
    assert.match(migration, /recovery_generation>=3/);
  });

  it("uses empty search paths and service-role-only execution", () => {
    const definers = migration.match(/security definer set search_path=''/g) ?? [];
    assert.ok(definers.length >= 9);
    assert.match(migration, /revoke all on function public\.begin_organization_manager_password_reset[\s\S]*authenticated,service_role/);
    assert.match(migration, /grant execute on function public\.begin_organization_manager_password_reset[\s\S]*to service_role/);
  });
});
