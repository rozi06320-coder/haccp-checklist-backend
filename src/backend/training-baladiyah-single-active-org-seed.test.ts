import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261015003000_seed_baladiyah_single_active_org.sql", import.meta.url),
  "utf8",
);

describe("Baladiyah single-active-organization successor seed", () => {
  it("fails closed unless exactly one active organization exists", () => {
    assert.match(migration, /select count\(\*\)::integer, \(array_agg\(organization\.id\)\)\[1\]/u);
    assert.match(migration, /where organization\.active/u);
    assert.match(migration, /if active_organization_count <> 1 then/u);
    assert.match(migration, /requires exactly one active organization; found %/u);
    assert.doesNotMatch(migration, /organization\.(?:slug|name)\s*=/u);
    assert.doesNotMatch(migration, /where organization\.active\s+limit 1/iu);
  });

  it("uses an owner-only hardened helper", () => {
    assert.match(migration, /private\.seed_baladiyah_single_active_organization\(\)/u);
    assert.match(migration, /security definer\s+set search_path = ''/u);
    assert.match(
      migration,
      /revoke all on function private\.seed_baladiyah_single_active_organization\(\)\s+from public, anon, authenticated, service_role;/u,
    );
    assert.doesNotMatch(migration, /grant execute on function private\.seed_baladiyah_single_active_organization/iu);
  });

  it("compares the stored draft payload and fails rather than overwriting conflicts", () => {
    assert.match(migration, /version\.content_hash = manifest_hash/u);
    assert.match(migration, /module\.metadata is distinct from expected\.module_value -> 'metadata'/u);
    assert.match(migration, /lesson\.content_i18n is distinct from expected_lesson\.lesson_value -> 'content_i18n'/u);
    assert.match(migration, /Existing Baladiyah course\/version conflicts with the approved draft manifest/u);
    assert.doesNotMatch(migration, /update public\.training_(?:courses|course_versions|modules|lessons)/iu);
  });

  it("remains a draft-only curriculum seed with no media or learner state writes", () => {
    assert.match(migration, /"course_key": "baladiyah-food-safety-hygiene"/u);
    assert.match(migration, /insert into public\.training_courses/u);
    assert.match(migration, /insert into public\.training_course_versions/u);
    assert.doesNotMatch(migration, /insert into public\.training_media_assets/iu);
    assert.doesNotMatch(
      migration,
      /insert into public\.training_(?:assignments|enrollments|lesson_progress|quiz_attempts|course_completions)/iu,
    );
    assert.doesNotMatch(migration, /set\s+status\s*=\s*'published'|published_at\s*=/iu);
  });
});
