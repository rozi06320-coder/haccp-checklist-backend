import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe,it } from "node:test";

const sql=readFileSync(new URL("../../supabase/migrations/20261016120000_internal_admin_training_draft_preview.sql",import.meta.url),"utf8");
const app=readFileSync(new URL("./app.ts",import.meta.url),"utf8");

describe("Internal Admin Training draft preview boundary",()=>{
  it("pins the exact draft revision and structural contract",()=>{
    assert.match(sql,/course\.course_key = 'baladiyah-food-safety-hygiene'/);
    assert.match(sql,/version\.version_number = 1/);
    assert.match(sql,/version\.status = 'draft'/);
    assert.match(sql,/version\.revision = 2/);
    assert.match(sql,/9bfb8467b8a43dc61db87833d0532403d14ecc6d3f63cb57e37582ea32d634d3/);
    assert.match(sql,/<> 10[\s\S]*<> 19[\s\S]*<> 40/);
    assert.match(sql,/array\['en','ar','id','hi','fil'\]/);
  });

  it("uses the hardened Internal Admin scope and service-role-only execution",()=>{
    assert.match(sql,/perform private\.assert_internal_admin_training_draft/);
    assert.match(sql,/security definer[\s\S]*set search_path = ''/);
    assert.match(sql,/revoke all on function public\.get_internal_admin_training_draft_preview\(uuid,uuid,uuid,uuid\) from public,anon,authenticated/);
    assert.match(sql,/grant execute on function public\.get_internal_admin_training_draft_preview\(uuid,uuid,uuid,uuid\) to service_role/);
  });

  it("never returns quiz content, metadata, answers, explanations, or Storage coordinates",()=>{
    const projection=sql.slice(sql.indexOf("return query"));
    assert.match(projection,/case when lesson\.lesson_type = 'quiz' then null else lesson\.content_i18n end/);
    assert.doesNotMatch(projection,/lesson\.metadata|storage_object_path|storage_bucket|sha256/);
    assert.doesNotMatch(sql,/insert into|update public|delete from|training_learner_sessions|training_enrollments|training_lesson_progress|training_quiz_attempts/i);
  });

  it("exposes only an authenticated no-store Internal Admin endpoint",()=>{
    assert.match(app,/training\/courses\/:courseId\/versions\/:versionId\/preview/);
    assert.match(app,/protectedRateLimit,authenticate/);
    assert.match(app,/await requireInternalAdmin\(request\)/);
    assert.match(app,/trainingMediaService\.getDraftPreview/);
    assert.match(app,/Cache-Control","private, no-store/);
  });
});
