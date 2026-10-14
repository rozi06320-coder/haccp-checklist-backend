import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261014120000_baladiyah_photo_first_draft_curriculum.sql", import.meta.url),
  "utf8",
);

describe("Baladiyah draft curriculum SQL boundary", () => {
  it("seeds through an owner-only organization-scoped helper", () => {
    assert.match(migration, /create or replace function private\.seed_baladiyah_food_safety_hygiene_draft\(\s*target_organization_id uuid\s*\)/u);
    assert.match(migration, /set search_path = ''/u);
    assert.match(migration, /organization\.id = target_organization_id/u);
    assert.match(migration, /organization\.slug = 'burger-hunch'/u);
    assert.match(migration, /revoke all on function private\.seed_baladiyah_food_safety_hygiene_draft\(uuid\)\s+from public, anon, authenticated, service_role;/u);
    assert.doesNotMatch(migration, /grant execute on function private\.seed_baladiyah/iu);
  });

  it("can only create an active course with an editable draft version", () => {
    assert.match(migration, /"course_key": "baladiyah-food-safety-hygiene"/u);
    assert.match(migration, /insert into public\.training_courses/u);
    assert.match(migration, /insert into public\.training_course_versions/u);
    assert.match(migration, /'draft'/u);
    assert.doesNotMatch(migration, /set\s+status\s*=\s*'published'|values\([^;]*'published'/isu);
    assert.doesNotMatch(migration, /published_at\s*=|published_by\s*=/iu);
  });

  it("does not add out-of-scope persistence or alter Training access", () => {
    assert.doesNotMatch(migration, /create table/iu);
    assert.doesNotMatch(migration, /training_(?:assignments|enrollments|lesson_progress|quiz_attempts|course_completions)/iu);
    assert.doesNotMatch(migration, /create or replace function public\.(?:list|store|validate|get)_.*training/iu);
    assert.doesNotMatch(migration, /alter table .*branch_training_access|drop /iu);
  });
});
