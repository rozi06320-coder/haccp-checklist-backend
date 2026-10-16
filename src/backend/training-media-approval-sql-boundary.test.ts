import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe,it } from "node:test";

const migration=readFileSync(new URL("../../supabase/migrations/20261016234500_training_media_approval_workflow.sql",import.meta.url),"utf8");
const service=readFileSync(new URL("./training-media.ts",import.meta.url),"utf8");
const app=readFileSync(new URL("./app.ts",import.meta.url),"utf8");

describe("Training media approval SQL boundary",()=>{
 it("adds auditable review state and a positive concurrency revision",()=>{
  for(const column of ["reviewed_at","reviewed_by","rejection_reason","revision"])assert.match(migration,new RegExp(`add column ${column}`));
  assert.match(migration,/training_media_assets_review_state_check/);
  assert.match(migration,/revision integer not null default 1/);
 });
 it("authorizes an exact draft slot and rejects stale or repeated review",()=>{
  const review=migration.slice(migration.indexOf("create function public.review_internal_admin_training_media"));
  assert.match(review,/assert_internal_admin_training_draft/);
  assert.match(review,/assert_training_image_slot/);
  assert.match(review,/selected\.revision<>expected_revision/);
  assert.match(review,/errcode='40001'/);
  assert.match(review,/selected\.approval_status<>'submitted'/);
 });
 it("keeps review RPCs service-role-only and table access revoked",()=>{
  for(const name of ["get_internal_admin_training_media_review_candidate","review_internal_admin_training_media"]){
   assert.match(migration,new RegExp(`revoke all on function public\\.${name}`));
   assert.match(migration,new RegExp(`grant execute on function public\\.${name}.*to service_role`));
  }
  assert.doesNotMatch(migration,/grant (?:select|insert|update|delete).*training_media_assets/i);
 });
 it("resets review audit fields when bytes or metadata are replaced",()=>{
  assert.match(migration,/approval_status='submitted',reviewed_at=null,reviewed_by=null,rejection_reason=null,[\s\S]*revision=asset\.revision\+1/);
 });
 it("requires an audited approval for publication",()=>{
  assert.match(migration,/asset\.approval_status<>'approved'/);
  assert.match(migration,/asset\.reviewed_at is null/);
  assert.match(migration,/asset\.reviewed_by is null/);
 });
 it("verifies private object bytes before approval and exposes only a safe endpoint",()=>{
  assert.match(service,/storage\.download\(candidate\.storage_object_path\)/);
  assert.match(service,/hash\(bytes\)!==candidate\.sha256/);
  assert.match(service,/metadata\.format!=="webp"/);
  assert.match(app,/media\/:assetId\/review/);
  assert.match(app,/requireInternalAdmin/);
  assert.match(app,/Cache-Control","private, no-store/);
 });
});
