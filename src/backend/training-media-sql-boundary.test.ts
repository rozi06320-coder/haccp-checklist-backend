import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe,it } from "node:test";
const sql=readFileSync(new URL("../../supabase/migrations/20261014230000_training_media_assets.sql",import.meta.url),"utf8");
const service=readFileSync(new URL("./training-media.ts",import.meta.url),"utf8");
describe("Training media SQL boundary",()=>{
 it("creates a private WebP-only bucket and constrained version-owned table",()=>{assert.match(sql,/values \('training-media'.*false, 5242880, array\['image\/webp'\]\)/);assert.match(sql,/create table public\.training_media_assets/);assert.match(sql,/foreign key\(course_version_id, organization_id\)/);assert.match(sql,/unique\(course_version_id, asset_key\)/);assert.match(sql,/unique\(storage_bucket, storage_object_path\)/);});
 it("enables RLS and revokes direct access including service role",()=>{assert.match(sql,/alter table public\.training_media_assets enable row level security/);assert.match(sql,/revoke all on table public\.training_media_assets from public, anon, authenticated, service_role/);assert.doesNotMatch(sql,/create policy[\s\S]*training-media/i);});
 it("uses hardened service-only RPCs",()=>{for(const name of ["register_internal_admin_training_media","replace_internal_admin_training_media","update_internal_admin_training_media_metadata","retire_internal_admin_training_media","list_internal_admin_training_media","authorize_internal_admin_training_media_read","authorize_training_learner_media_read"]) {assert.match(sql,new RegExp(`security definer[\\s\\S]*set search_path = ''`));assert.match(sql,new RegExp(`grant execute on function public\\.${name}`));assert.match(sql,new RegExp(`revoke all on function public\\.${name}`));}});
 it("guards immutable versions and referenced removal",()=>{assert.match(sql,/Published or retired Training media is immutable/);assert.match(sql,/Training media is referenced by lesson content/);assert.match(sql,/before insert or update or delete on public\.training_media_assets/);});
  it("validates publication references, approval, locales, and hashes",()=>{assert.match(sql,/validate_internal_admin_training_media_for_publish/);assert.match(sql,/approval_status='approved'/);assert.match(sql,/training_media_locales_complete/);assert.match(sql,/extensions\.digest/);});
  it("rejects animated image metadata before normalization",()=>{assert.match(service,/\(metadata\.pages\?\?1\)>1/);});
});
