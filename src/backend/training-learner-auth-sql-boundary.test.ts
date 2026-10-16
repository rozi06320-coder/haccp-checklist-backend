import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261015233000_training_learner_auth_sessions.sql", import.meta.url),
  "utf8",
);

describe("Training learner authentication SQL boundary", () => {
  it("reuses the Phase 2A tables and stores only a token digest", () => {
    assert.doesNotMatch(migration, /create table public\.(?:operational_staff_training_credentials|training_learner_sessions)/i);
    assert.match(migration, /add column token_digest text/);
    assert.match(migration, /token_digest ~ '\^\[0-9a-f\]\{64\}\$'/);
    assert.doesNotMatch(migration, /\b(?:raw_)?token\s+text\b/i);
    assert.match(migration, /create unique index training_learner_sessions_token_digest_idx/);
  });

  it("uses modern operational assignments and branch-local validity", () => {
    assert.match(migration, /public\.operational_staff_assignments/);
    assert.match(migration, /public\.branch_operational_teams/);
    assert.match(migration, /operational_team\.active/);
    assert.match(migration, /private\.phase4a_business_date\(branch\.timezone\)/);
    assert.doesNotMatch(migration, /branch_supervisor_teams/);
  });

  it("serializes failure accounting and applies five-attempt lockout", () => {
    assert.match(migration, /for update/);
    assert.match(migration, /next_failure_count >= 5/);
    assert.match(migration, /interval '15 minutes'/);
    assert.match(migration, /failed_window_started_at/);
    assert.match(migration, /set revoked_at = coalesce/);
  });

  it("creates 12-hour absolute and one-hour sliding idle expiry", () => {
    assert.match(migration, /now_at \+ interval '12 hours'/);
    assert.match(migration, /now_at \+ interval '1 hour'/);
    assert.match(migration, /least\(stored\.expires_at, now_at \+ interval '1 hour'\)/);
    assert.match(migration, /learner_session\.idle_expires_at <= now_at/);
  });

  it("revalidates credential version, employee eligibility, and branch scope", () => {
    assert.match(migration, /credential\.credential_version = learner_session\.credential_version/);
    assert.match(migration, /credential\.status = 'active'/);
    assert.match(migration, /private\.training_learner_employee_is_eligible/);
    assert.match(migration, /staff\.branch_id = target_branch_id/);
  });

  it("hardens every RPC", () => {
    for (const signature of [
      "get_training_learner_login_credential\\(uuid, uuid, text\\)",
      "complete_training_learner_login\\(uuid, uuid, uuid, uuid, boolean, text\\)",
      "validate_training_learner_session\\(text\\)",
      "revoke_training_learner_session\\(text\\)",
    ]) {
      assert.match(migration, new RegExp(`revoke all on function public\\.${signature}`));
      assert.match(migration, new RegExp(`grant execute on function public\\.${signature}`));
    }
    assert.equal((migration.match(/security definer/g) ?? []).length >= 6, true);
    assert.equal((migration.match(/set search_path = ''/g) ?? []).length >= 6, true);
  });
});
