import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const source = (file: string) => readFile(path.resolve(file), "utf8");

describe("Maintenance issue before/after photos", () => {
  it("adds a private before/after attachment model and extends it to three photos per type without touching purchases", async () => {
    const [baseMigration, multiMigration] = await Promise.all([
      source("supabase/migrations/20260826113000_maintenance_issue_before_after_photos.sql"),
      source("supabase/migrations/20260826170000_maintenance_issue_multi_photos.sql"),
    ]);
    const migration = `${baseMigration}\n${multiMigration}`;
    assert.match(migration, /maintenance-issue-photos','maintenance-issue-photos',false,5242880/);
    assert.match(migration, /create table if not exists public\.maintenance_issue_attachments/);
    assert.match(migration, /attachment_type text not null/);
    assert.match(migration, /attachment_type in \('issue','repair'\)/);
    assert.match(migration, /unique\(maintenance_issue_id, attachment_type\)/);
    assert.match(multiMigration, /drop constraint if exists maintenance_issue_attachments_one_per_type_key/);
    assert.match(multiMigration, /add column if not exists attachment_position integer/);
    assert.match(multiMigration, /column_name = 'position'/);
    assert.match(multiMigration, /drop column if exists "position"/);
    assert.match(multiMigration, /maintenance_issue_attachments_position_check/);
    assert.match(multiMigration, /unique\(maintenance_issue_id, attachment_type, attachment_position\)/);
    assert.match(multiMigration, /enforce_maintenance_issue_attachment_limit/);
    assert.match(multiMigration, /too many maintenance issue attachments/);
    assert.match(migration, /alter table public\.maintenance_issue_attachments enable row level security/);
    assert.match(migration, /revoke all on table public\.maintenance_issue_attachments from public, anon, authenticated/);
    assert.match(migration, /grant select, insert, update, delete on table public\.maintenance_issue_attachments to service_role/);
    assert.match(migration, /public\.create_supervisor_maintenance_issue_with_photo/);
    assert.match(migration, /public\.update_maintenance_issue_with_repair_photo/);
    assert.match(migration, /public\.list_maintenance_issue_attachments/);
    assert.match(migration, /repair photo required to resolve maintenance issue/);
    assert.doesNotMatch(migration, /maintenance_purchase_logs|maintenance-purchase-receipts/);
  });

  it("validates, uploads, signs, and cleans issue photos through backend service helpers", async () => {
    const operational = await source("src/backend/operational.ts");
    assert.match(operational, /MAINTENANCE_ISSUE_PHOTO_BUCKET = "maintenance-issue-photos"/);
    assert.match(operational, /MAX_MAINTENANCE_ISSUE_PHOTO_BYTES = 5 \* 1024 \* 1024/);
    assert.match(operational, /MAX_MAINTENANCE_ISSUE_PHOTOS = 3/);
    assert.match(operational, /maintenanceIssuePhotoMime = z\.enum\(\["image\/jpeg", "image\/png", "image\/webp"\]\)/);
    assert.match(operational, /inspectMaintenanceIssuePhoto/);
    assert.match(operational, /bytes\.subarray\(0, 8\)\.equals\(pngSignature\)/);
    assert.match(operational, /maintenanceIssuePhotoStorage\.createSignedUrl\(path,MAINTENANCE_ISSUE_PHOTO_SIGNED_URL_SECONDS\)/);
    assert.match(operational, /maintenanceIssuePhotoStorage\.upload/);
    assert.match(operational, /uploadMaintenanceIssuePhotos/);
    assert.match(operational, /attachment_position/);
    assert.match(operational, /maintenanceIssuePhotoStorage\.remove\(uploaded\.map\(\(photo\)=>photo\.storage_path\)\)/);
    assert.match(operational, /create_supervisor_maintenance_issue_with_photo/);
    assert.match(operational, /update_maintenance_issue_with_repair_photo/);
    assert.match(operational, /list_maintenance_issue_attachments/);
    assert.match(operational, /before_photos/);
    assert.match(operational, /after_photos/);
    assert.doesNotMatch(operational, /pin_hash|service_key|SUPABASE_SECRET_KEY/);
  });

  it("keeps API responses signed and requires after-repair photos only for resolved transitions", async () => {
    const app = await source("src/backend/app.ts");
    assert.match(app, /maintenanceIssuePhotoResponseSchema/);
    assert.match(app, /before_photo: maintenanceIssuePhotoResponseSchema\.optional\(\)/);
    assert.match(app, /after_photo: maintenanceIssuePhotoResponseSchema\.optional\(\)/);
    assert.match(app, /before_photos: z\.array/);
    assert.match(app, /after_photos: z\.array/);
    assert.match(app, /maintenanceIssueCreateEnvelopeSchema/);
    assert.match(app, /maintenanceIssueUpdateEnvelopeSchema/);
    assert.match(app, /application\/vnd\.maintenance-issue\+json/);
    assert.match(app, /body\.data\.status === "resolved" && repairPhotos\.length === 0/);
    assert.match(app, /Photo required to resolve this issue\./);
    assert.doesNotMatch(app, /pin_hash|storage_path.*json|SUPABASE_SECRET_KEY/);
  });
});
