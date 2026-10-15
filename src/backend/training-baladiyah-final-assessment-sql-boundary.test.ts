import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const sql = readFileSync(
  new URL("../../supabase/migrations/20261015220000_baladiyah_final_assessment.sql", import.meta.url),
  "utf8",
);

describe("Baladiyah final assessment SQL boundary", () => {
  it("requires the exact normalized revision-one source and fails closed", () => {
    assert.match(sql, /version\.status = 'draft'/u);
    assert.match(sql, /version\.revision = 1/u);
    assert.match(sql, /5d77e1c5d9c127a7a07fb0caf0703b52a0df2b16e0510632ff57bf4c09cf1515/u);
    assert.match(sql, /<> 9[\s\S]*<> 27[\s\S]*lesson_type = 'reading'[\s\S]*<> 9[\s\S]*lesson_type = 'key_points'[\s\S]*<> 9[\s\S]*lesson_type = 'quiz'[\s\S]*<> 9/u);
    assert.match(sql, /quiz payload precondition drifted/u);
    assert.match(sql, /question precondition drifted/u);
    assert.match(sql, /image-slot precondition drifted/u);
  });

  it("changes only draft curriculum rows and never publishes or writes learner/media state", () => {
    assert.match(sql, /delete from public\.training_lessons/u);
    assert.match(sql, /insert into public\.training_modules/u);
    assert.match(sql, /insert into public\.training_lessons/u);
    assert.match(sql, /set revision = 2,[\s\S]*content_hash = expected_target_hash/u);
    assert.doesNotMatch(sql, /update public\.training_media_assets|insert into public\.training_media_assets|delete from public\.training_media_assets/iu);
    assert.doesNotMatch(sql, /training_(?:assignments|enrollments|lesson_progress|quiz_attempts|course_completions)/iu);
    assert.doesNotMatch(sql, /status\s*=\s*'published'|published_at\s*=|published_by\s*=/iu);
  });

  it("snapshots and compares slots and media around the mutation", () => {
    assert.match(sql, /slots_before jsonb;[\s\S]*slots_after jsonb;/u);
    assert.match(sql, /media_before jsonb;[\s\S]*media_after jsonb;/u);
    assert.match(sql, /slots_after is distinct from slots_before or slots_after is distinct from expected_slots/u);
    assert.match(sql, /media_after is distinct from media_before/u);
  });

  it("is owner-only, hardened, and exactly idempotent", () => {
    assert.match(sql, /security definer\s+set search_path = ''/u);
    assert.match(sql, /current_revision = 2 and current_content_hash = expected_target_hash/u);
    assert.match(sql, /Baladiyah final assessment target has drifted/u);
    assert.match(sql, /revoke all on function private\.restructure_baladiyah_final_assessment\(\)\s+from public, anon, authenticated, service_role;/u);
    assert.doesNotMatch(sql, /grant execute on function private\.restructure_baladiyah_final_assessment/u);
  });
});
