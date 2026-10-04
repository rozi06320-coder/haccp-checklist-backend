import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe,it } from "node:test";

describe("Sales Tracking three-photo direct-upload contract",()=>{
 it("enforces three active ordered photos under the report photo lock",async()=>{
  const migration=await readFile(path.resolve("supabase/migrations/20261006120000_sales_tracking_three_evidence_photos.sql"),"utf8");
  assert.match(migration,/drop index if exists public\.sales_tracking_attachments_active_report_uidx/);
  assert.match(migration,/display_order between 1 and 3/);
  assert.match(migration,/unique index sales_tracking_attachments_active_position_uidx/);
  assert.match(migration,/pg_advisory_xact_lock[\s\S]*:sales_tracking_photo/);
  assert.match(migration,/if active_count>=3 then raise exception'maximum sales tracking photos reached'/);
  assert.match(migration,/replacement_attachment_id is not null/);
  assert.match(migration,/update public\.sales_tracking_attachments set deleted_at=now\(\)[\s\S]*insert into public\.sales_tracking_attachments/);
  assert.match(migration,/create or replace function public\.finalize_sales_tracking_attachment[\s\S]*order by a\.display_order,a\.created_at,a\.id limit 1 for update[\s\S]*uploaded_by_user_id,display_order/);
 });
 it("keeps upload paths server-derived and finalization service-role only",async()=>{
  const [migration,persistence,app]=await Promise.all([
   readFile(path.resolve("supabase/migrations/20261006120000_sales_tracking_three_evidence_photos.sql"),"utf8"),
   readFile(path.resolve("src/backend/checklist-persistence.ts"),"utf8"),
   readFile(path.resolve("src/backend/app.ts"),"utf8"),
  ]);
  assert.match(persistence,/createSignedUploadUrl\(path,\{upsert:false\}\)/);
  assert.match(persistence,/salesTrackingPhotoStorage\.download\(path\)/);
  assert.match(persistence,/salesTrackingPhotoMime\(bytes,input\.mimeType\)/);
  assert.match(persistence,/catch\(error\)\{try\{await salesTrackingPhotoStorage\.remove\(\[path\]\);\}catch\{\}throw error;\}/);
  assert.match(persistence,/if\(mutation\.old_storage_path\)try\{await salesTrackingPhotoStorage\.remove\(\[mutation\.old_storage_path\]\);\}catch\{\}/);
  assert.match(migration,/revoke all on function public\.prepare_sales_tracking_attachment_upload/);
  assert.match(migration,/to service_role/);
  assert.match(app,/photos\/upload-intent/);
  assert.doesNotMatch(app,/storage_path.*response/);
 });
 it("keeps Manager lists count-only and signs photos only through the detail path",async()=>{
  const [migration,persistence,app]=await Promise.all([
   readFile(path.resolve("supabase/migrations/20261006120000_sales_tracking_three_evidence_photos.sql"),"utf8"),
   readFile(path.resolve("src/backend/checklist-persistence.ts"),"utf8"),
   readFile(path.resolve("src/backend/app.ts"),"utf8"),
  ]);
  assert.match(migration,/'evidence_count'/);
  assert.match(migration,/'evidence_filenames'/);
  assert.match(migration,/get_managed_sales_tracking_attachments/);
  assert.match(persistence,/getManagedSalesTrackingAttachments[\s\S]*safeSalesTrackingAttachments/);
  assert.match(persistence,/try\{const signed=await salesTrackingPhotoStorage\.createSignedUrl[\s\S]*catch\{signedUrl=null;\}/);
  assert.match(app,/sales-tracking\/:reportId\/attachments/);
  const listRoute=app.slice(app.indexOf('app.get("/api/v1/management/organizations/:organizationId/sales-tracking"'),app.indexOf('app.get("/api/v1/management/organizations/:organizationId/sales-tracking/:reportId/attachments"'));
  assert.doesNotMatch(listRoute,/getManagedSalesTrackingAttachments|signed_url|createSignedUrl/);
 });
});
