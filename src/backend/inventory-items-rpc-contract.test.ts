import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import {
  checklistRequestHash,
  inventoryItemsDraftRpcArgs,
  inventoryItemsSubmitRpcArgs,
  type InventoryItemsDraftPayload,
} from "./checklist-persistence";

const actor="17000000-0000-4000-8000-000000000001";
const branch="27000000-0000-4000-8000-000000000001";
const idempotencyKey="47000000-0000-4000-8000-000000000001";
const payload:InventoryItemsDraftPayload={
 beef_rows:[{production_date:"2026-08-12",russian_kg:"10",australian_kg:"0",fat_kg:"0",ready_patty:"0",hunch_sauce_kg:"0",wastage_grams:"0"}],
 item_usage:{usage_month:"2026-08-01",items:[]},
};

describe("Inventory Items PostgREST RPC argument contract",()=>{
 it("uses the current p-prefixed draft argument names",()=>{
  assert.deepEqual(inventoryItemsDraftRpcArgs(actor,branch,payload),{
   p_actor_user_id:actor,
   p_target_branch_id:branch,
   beef_rows:payload.beef_rows,
   item_usage:payload.item_usage,
  });
 });

 it("uses the current p-prefixed submit argument names",()=>{
  assert.deepEqual(inventoryItemsSubmitRpcArgs(actor,branch,idempotencyKey,payload),{
   p_actor_user_id:actor,
   p_target_branch_id:branch,
   p_idempotency_key:idempotencyKey,
   p_request_hash:checklistRequestHash({type:"inventory_items",branch_id:branch,inventory_month:"2026-08-01",beef_rows:payload.beef_rows,item_usage:payload.item_usage}),
   beef_rows:payload.beef_rows,
   item_usage:payload.item_usage,
  });
 });

 it("keeps the Beef Production label migration scoped to field labels only",async()=>{
  const migration=await readFile(path.resolve("supabase/migrations/20260927140000_inventory_beef_production_label.sql"),"utf8");
  assert.match(migration,/beef_russian_label/);
  assert.match(migration,/beef_australian_label/);
  assert.match(migration,/beef_hunch_sauce_label/);
  assert.match(migration,/update_inventory_beef_production_field_labels/);
  assert.doesNotMatch(migration,/\bbeef_production_label\b/);
  assert.doesNotMatch(migration,/\bupdate_inventory_beef_production_label\b/);
 });
});
