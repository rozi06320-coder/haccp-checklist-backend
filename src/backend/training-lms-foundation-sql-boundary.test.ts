import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261013220000_training_lms_foundation.sql", import.meta.url),
  "utf8",
);

describe("Training LMS Phase 2A SQL boundary", () => {
  it("creates only the approved identity, session, and course foundation tables", () => {
    for (const table of [
      "operational_staff_training_credentials",
      "training_learner_sessions",
      "training_courses",
      "training_course_versions",
      "training_modules",
      "training_lessons",
    ]) {
      assert.match(migration, new RegExp(`create table public\\.${table} \\(`));
    }

    assert.doesNotMatch(migration, /create table public\.training_(?:assignments|enrollments|lesson_progress|quiz_attempts|course_completions)/);
  });

  it("uses the existing scrypt parameter convention without a plaintext PIN column", () => {
    assert.match(migration, /kdf_version = 1/);
    assert.match(migration, /cost = 16384/);
    assert.match(migration, /block_size = 8/);
    assert.match(migration, /parallelization = 1/);
    assert.doesNotMatch(migration, /\b(?:plain_?text_?)?pin\s+text\b/i);
  });

  it("keeps learner identity server-resolved through a persistent session ID", () => {
    assert.match(migration, /create table public\.training_learner_sessions/);
    assert.match(migration, /foreign key \(employee_id, organization_id\)/);
    assert.match(migration, /foreign key \(branch_id_at_auth, organization_id\)/);
    assert.doesNotMatch(migration, /create or replace function public\.(?:create|validate)_training_learner_session/);
  });

  it("protects published and retired course content at the database boundary", () => {
    assert.match(migration, /create or replace function private\.enforce_training_draft_content\(\)/);
    assert.match(migration, /create or replace function private\.enforce_training_course_version_immutability\(\)/);
    assert.match(migration, /before insert or update or delete on public\.training_modules/);
    assert.match(migration, /before insert or update or delete on public\.training_lessons/);
    assert.match(migration, /Published or retired Training content is immutable/);
  });

  it("hardens all Phase 2A tables and credential RPCs", () => {
    for (const table of [
      "operational_staff_training_credentials",
      "training_learner_sessions",
      "training_courses",
      "training_course_versions",
      "training_modules",
      "training_lessons",
    ]) {
      assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`));
      assert.match(
        migration,
        new RegExp(`revoke all on table public\\.${table} from public, anon, authenticated, service_role`),
      );
    }

    for (const name of [
      "store_internal_admin_operational_staff_training_credential",
      "revoke_internal_admin_operational_staff_training_credential",
      "get_internal_admin_operational_staff_training_credential_status",
    ]) {
      assert.match(migration, new RegExp(`create or replace function public\\.${name}`));
      assert.match(migration, new RegExp(`grant execute on function public\\.${name}`));
    }
    assert.match(migration, /if not private\.is_internal_admin\(actor_user_id\) then/g);
  });

  it("does not alter the existing Training Portal access functions", () => {
    assert.doesNotMatch(migration, /create or replace function public\.list_training_branch_employees/);
    assert.doesNotMatch(migration, /create or replace function public\.validate_training_branch_employee/);
    assert.doesNotMatch(migration, /create or replace function public\.validate_training_branch_session/);
  });
});
