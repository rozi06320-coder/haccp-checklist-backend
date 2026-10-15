import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const sql=readFileSync(new URL("../../supabase/migrations/20261015120000_training_required_image_slots.sql",import.meta.url),"utf8");
const app=readFileSync(new URL("./app.ts",import.meta.url),"utf8");

describe("Training required image slots SQL boundary",()=>{
  it("normalizes only the expected draft and keeps the forty-slot contract",()=>{
    assert.match(sql,/course\.course_key = 'baladiyah-food-safety-hygiene'/);
    assert.match(sql,/version\.version_number = 1/);
    assert.match(sql,/current_status <> 'draft'/);
    assert.match(sql,/<> 9[\s\S]*<> 27[\s\S]*<> 40/);
    assert.match(sql,/original_manifest_hash constant text := '4e63cd0f/);
    assert.doesNotMatch(sql,/status\s*=\s*'published'/);
    const normalization=sql.slice(0,sql.indexOf("create or replace function public.list_internal_admin_training_image_slots"));
    assert.doesNotMatch(normalization,/insert into public\.training_media_assets/i);
  });

  it("creates locale-aligned explicit image_slots and removes legacy inline image objects",()=>{
    assert.match(sql,/array\['en','ar','id','hi','fil'\]/);
    assert.match(sql,/item\.value - 'image'/);
    assert.match(sql,/jsonb_set\(locale_content, '\{image_slots\}'/);
    assert.match(sql,/bound_reference_count = resolved_slot_count \* locale_count/);
  });

  it("exposes an ordered safe slot RPC without storage data",()=>{
    assert.match(sql,/public\.list_internal_admin_training_image_slots/);
    assert.match(sql,/order by slot\.module_position, slot\.lesson_position, slot\.slot_position/);
    assert.match(sql,/asset\.id is not null/);
    const rpc=sql.slice(sql.indexOf("create or replace function public.list_internal_admin_training_image_slots"),sql.indexOf("create or replace function public.register_internal_admin_training_media"));
    assert.doesNotMatch(rpc,/storage_bucket|storage_object_path|sha256/);
    assert.match(sql,/grant execute on function public\.list_internal_admin_training_image_slots\(uuid,uuid,uuid,uuid\) to service_role/);
  });

  it("hardens registration and later mutations to the same real slot",()=>{
    assert.match(sql,/perform private\.assert_training_image_slot\(target_organization_id,target_course_version_id,target_asset_key\)/);
    assert.equal((sql.match(/perform private\.assert_training_image_slot\(target_organization_id,target_course_version_id,selected\.asset_key\)/g)??[]).length,2);
    assert.match(sql,/Unknown Training image slot[\s\S]*errcode = '22023'/);
    assert.match(sql,/Training image slot contract changed[\s\S]*errcode = '55000'/);
  });

  it("protects required slots from removal and validates all requirements for publication",()=>{
    assert.match(sql,/Required Training image slots must be replaced, not removed/);
    assert.match(sql,/private\.training_image_slot_bindings_valid/);
    assert.match(sql,/asset\.approval_status <> 'approved'/);
    assert.match(sql,/not private\.training_media_locales_complete\(asset\.alt_i18n\)/);
    assert.match(sql,/return query select pg_catalog\.encode\(extensions\.digest/);
  });

  it("exposes the authenticated no-store image-slot endpoint",()=>{
    assert.match(app,/\/api\/v1\/internal-admin\/organizations\/:organizationId\/training\/image-slots/);
    assert.match(app,/trainingMediaService\.listSlots/);
    assert.match(app,/response\.setHeader\("Cache-Control","private, no-store"\);response\.status\(200\)\.json\(\{slots\}\)/);
  });
});
