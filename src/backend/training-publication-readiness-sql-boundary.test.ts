import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {describe,it} from "node:test";

const migration=readFileSync(new URL("../../supabase/migrations/20261017120000_training_publication_readiness.sql",import.meta.url),"utf8");
const service=readFileSync(new URL("./training-media.ts",import.meta.url),"utf8");
const app=readFileSync(new URL("./app.ts",import.meta.url),"utf8");
describe("Training publication readiness boundary",()=>{
 it("is a read-only, service-role-only Internal Admin RPC",()=>{assert.match(migration,/stable\s+security definer\s+set search_path = ''/);assert.match(migration,/assert_internal_admin_training_draft/);assert.match(migration,/revoke all on function public\.get_internal_admin_training_publication_readiness[\s\S]*public, anon, authenticated, service_role/);assert.match(migration,/grant execute[\s\S]*to service_role/);assert.doesNotMatch(migration,/\b(insert|update|delete|truncate)\b/i);});
 it("reuses the strict curriculum and publication media validators",()=>{assert.match(migration,/get_internal_admin_training_draft_preview/);assert.match(migration,/training_image_slot_requirements/);assert.match(migration,/validate_internal_admin_training_media_for_publish/);});
 it("verifies approved private objects without returning private coordinates",()=>{assert.match(service,/getPublicationReadiness/);assert.match(service,/storage\.download/);assert.match(service,/hash\(bytes\)!==candidate\.sha256/);assert.match(service,/Math\.min\(4,approvedSlots\.length\)/);assert.match(service,/withTimeout/);assert.match(app,/versions\/:versionId\/publication-readiness/);});
});

