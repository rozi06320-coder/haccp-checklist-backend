import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { inspectMaintenancePurchaseReceipt, maintenancePurchaseRequestHash, MAX_PURCHASE_INVOICE_BYTES } from "./operational";

const source = (file:string) => readFile(path.resolve(file), "utf8");
const issueMigration = "supabase/migrations/20260902100000_maintenance_issue_integrity_scheduling.sql";
const purchaseMigration = "supabase/migrations/20260902110000_maintenance_purchase_integrity.sql";

describe("Maintenance Phase 1 issue integrity contract", () => {
  it("scopes create idempotency by branch or office and removes team ownership", async () => {
    const sql = await source(issueMigration);
    assert.match(sql, /maintenance_issues_branch_idempotency_key_idx[\s\S]*organization_id, branch_id, idempotency_key/);
    assert.match(sql, /maintenance_issues_office_idempotency_key_idx[\s\S]*organization_id, idempotency_key/);
    assert.match(sql, /where issue\.location_scope = 'branch'[\s\S]*issue\.branch_id = target_branch_id[\s\S]*issue\.idempotency_key = request_idempotency_key/);
    assert.match(sql, /where issue\.location_scope = 'office'[\s\S]*issue\.organization_id = target_organization_id[\s\S]*issue\.idempotency_key = request_idempotency_key/);
    assert.match(sql, /requested_id, target_organization_id, target_branch_id, null, 'branch'/);
    assert.doesNotMatch(sql, /require_supervisor_maintenance_team/);
  });

  it("authorizes branch supervisors without operational-team ownership", async () => {
    const sql = await source(issueMigration);
    const authorization = sql.slice(sql.indexOf("create or replace function private.actor_can_view_maintenance_issue"), sql.indexOf("create or replace function private.maintenance_issue_transition_allowed"));
    assert.match(authorization, /branch_memberships/);
    assert.match(authorization, /membership\.role = 'branch_manager'/);
    assert.match(authorization, /profile\.disabled_at is null/);
    assert.match(authorization, /not profile\.must_change_password/);
    assert.doesNotMatch(authorization, /branch_supervisor_teams/);
    assert.match(sql, /list_supervisor_maintenance_issues_v2/);
    assert.match(sql, /private\.require_supervisor_maintenance_branch/);
  });

  it("uses one locked revision for status, responsibility, and repair scheduling", async () => {
    const sql = await source(issueMigration);
    assert.match(sql, /add column if not exists revision bigint not null default 0/);
    assert.match(sql, /where issue_row\.id = target_issue_id[\s\S]*for update/);
    assert.match(sql, /expected_revision <> issue\.revision[\s\S]*errcode = '40001'/);
    assert.match(sql, /responsible_person_name = clean_responsible/);
    assert.match(sql, /planned_repair_date = new_planned_repair_date/);
    assert.match(sql, /revision = issue_row\.revision \+ 1/);
    assert.match(sql, /update_maintenance_issue\([\s\S]*expected_revision bigint[\s\S]*new_planned_repair_date date/);
  });

  it("records structured planned-date history and keeps dates separate from status", async () => {
    const sql = await source(issueMigration);
    assert.match(sql, /update_kind in \('status_update', 'repair_schedule_change'\)/);
    assert.match(sql, /old_planned_repair_date date/);
    assert.match(sql, /new_planned_repair_date date/);
    assert.match(sql, /planned repair date change reason required/);
    assert.match(sql, /statement_timestamp\(\) at time zone branch\.timezone/);
    assert.match(sql, /schedule_changed := issue\.planned_repair_date is distinct from new_planned_repair_date;[\s\S]*if schedule_changed and new_planned_repair_date is not null and new_planned_repair_date < local_today/);
    assert.match(sql, /'repair_schedule_change', old_planned_date/);
    assert.doesNotMatch(sql, /planned_repair_date[\s\S]{0,100}(cron|auto.*resolve)/i);
  });

  it("requires proof for resolution and rejects reopening", async () => {
    const sql = await source(issueMigration);
    assert.match(sql, /if repair_photos is null then[\s\S]*if new_status = 'resolved'/);
    assert.match(sql, /repair proof required to resolve maintenance issue/);
    assert.match(sql, /if new_status <> 'resolved' or issue\.status in \('resolved', 'closed'\)/);
    assert.match(sql, /old_status = 'resolved' and new_status = 'closed'/);
    assert.doesNotMatch(sql, /old_status = 'resolved' and new_status in \('closed',\s*'in_progress'\)/);
    assert.doesNotMatch(sql, /delete from public\.maintenance_issue_attachments/);
  });
});

describe("Maintenance Phase 1 purchase integrity contract", () => {
  it("uses source-specific tenant-scoped purchase idempotency with payload hashes", async () => {
    const sql = await source(purchaseMigration);
    assert.match(sql, /maintenance_purchase_issue_idempotency_key_idx[\s\S]*organization_id, maintenance_issue_id, idempotency_key/);
    assert.match(sql, /maintenance_purchase_general_idempotency_key_idx[\s\S]*organization_id, idempotency_key/);
    assert.match(sql, /purchase_type = 'issue'/);
    assert.match(sql, /purchase_type = 'general'/);
    assert.match(sql, /saved\.request_hash is distinct from request_fingerprint[\s\S]*errcode = '40001'/);
  });

  it("accepts bounded image and PDF evidence under organization-scoped paths", async () => {
    const [sql, operational] = await Promise.all([source(purchaseMigration), source("src/backend/operational.ts")]);
    assert.match(sql, /image\/jpeg', 'image\/png', 'image\/webp', 'application\/pdf/);
    assert.match(sql, /attachment_size > 5242880/);
    assert.match(sql, /attachment_count > 3/);
    assert.match(sql, /maintenance\/' \|\| target_organization::text \|\| '\/purchases\/' \|\| purchase_id::text/);
    assert.match(operational, /`maintenance\/\$\{purchaseScope\?\.organization_id\}\/purchases\/\$\{purchaseId\}/);
    assert.doesNotMatch(operational, /issueId\?\?"standalone"/);
  });

  it("validates receipt bytes rather than trusting declared image or PDF MIME", () => {
    const jpeg=Buffer.from([0xff,0xd8,0xff,0x00,0xff,0xd9]);
    const png=Buffer.alloc(33);Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]).copy(png);png.write("IHDR",12,"ascii");png.write("IEND",25,"ascii");
    const webp=Buffer.alloc(20);webp.write("RIFF",0,"ascii");webp.writeUInt32LE(12,4);webp.write("WEBP",8,"ascii");
    const pdf=Buffer.from("%PDF-1.7\n");
    assert.equal(inspectMaintenancePurchaseReceipt(jpeg,"image/jpeg").extension,"jpg");
    assert.equal(inspectMaintenancePurchaseReceipt(png,"image/png").extension,"png");
    assert.equal(inspectMaintenancePurchaseReceipt(webp,"image/webp").extension,"webp");
    assert.equal(inspectMaintenancePurchaseReceipt(pdf,"application/pdf").extension,"pdf");
    assert.throws(()=>inspectMaintenancePurchaseReceipt(pdf,"image/jpeg"));
    assert.throws(()=>inspectMaintenancePurchaseReceipt(Buffer.from("not-an-image"),"image/png"));
    assert.throws(()=>inspectMaintenancePurchaseReceipt(Buffer.alloc(MAX_PURCHASE_INVOICE_BYTES+1),"application/pdf"));
  });

  it("attributes reimbursement once and freezes reimbursed financial evidence", async () => {
    const sql = await source(purchaseMigration);
    assert.match(sql, /add column if not exists reimbursed_by uuid references public\.profiles/);
    assert.match(sql, /create table if not exists public\.maintenance_purchase_events/);
    assert.match(sql, /maintenance_purchase_events_one_reimbursement_key unique/);
    assert.match(sql, /where purchase_row\.id = target_purchase_id[\s\S]*for update/);
    assert.match(sql, /maintenance purchase already reimbursed[\s\S]*errcode = '40001'/);
    assert.match(sql, /reimbursed_at = statement_timestamp\(\)/);
    assert.match(sql, /reimbursed_by = actor_user_id/);
    assert.match(sql, /reimbursed maintenance purchase is immutable/);
    assert.match(sql, /reimbursed maintenance purchase evidence is immutable/);
  });

  it("provides complete explicit pagination and scoped Manager receipt metadata", async () => {
    const [sql, operational] = await Promise.all([source(purchaseMigration), source("src/backend/operational.ts")]);
    assert.match(sql, /get_maintenance_purchase_history_page/);
    assert.match(sql, /purchase_type_filter not in \('issue', 'general', 'all'\)/);
    assert.match(sql, /requested_page_size > 200/);
    assert.match(sql, /'total_count', total_rows/);
    assert.match(sql, /get_managed_maintenance_purchase_receipt_metadata/);
    assert.match(sql, /actor_manages_active_organization/);
    assert.match(sql, /revoke all on function public\.get_managed_maintenance_purchase_receipt_metadata\(uuid, uuid, uuid, uuid\) from public, anon, authenticated;/);
    assert.match(sql, /grant execute on function public\.get_managed_maintenance_purchase_receipt_metadata\(uuid, uuid, uuid, uuid\) to service_role;/);
    assert.doesNotMatch(sql, /grant execute on function public\.get_managed_maintenance_purchase_receipt_metadata\(uuid, uuid, uuid, uuid\) to (?:anon|authenticated);/);
    assert.match(operational, /rpc\("get_managed_maintenance_purchase_receipt_metadata"/);
    const managerMethod = operational.slice(operational.indexOf("async createManagedMaintenancePurchaseReceiptReadUrl"), operational.indexOf("async getManagedOperationsSummary"));
    assert.doesNotMatch(managerMethod, /client\.from/);
  });

  it("hashes replay semantics deterministically and detects payload or evidence changes", () => {
    const base={issueId:"10000000-0000-4000-8000-000000000001",payload:{item_name:"Pump",amount:10},receipts:[{bytes:Buffer.from("receipt"),mimeType:"application/pdf"}]};
    assert.equal(maintenancePurchaseRequestHash(base),maintenancePurchaseRequestHash(base));
    assert.notEqual(maintenancePurchaseRequestHash(base),maintenancePurchaseRequestHash({...base,payload:{...base.payload,amount:11}}));
    assert.notEqual(maintenancePurchaseRequestHash(base),maintenancePurchaseRequestHash({...base,receipts:[{bytes:Buffer.from("other"),mimeType:"application/pdf"}]}));
  });
});

describe("Maintenance Phase 1 standalone backend contract", () => {
  it("uses canonical v2 RPCs and maps validation/conflict/access safely", async () => {
    const [app, operational] = await Promise.all([source("src/backend/app.ts"), source("src/backend/operational.ts")]);
    assert.match(app, /expected_revision: z\.number\(\)\.int\(\)\.nonnegative\(\)/);
    assert.match(app, /planned_repair_date: dateOnlySchema\.nullable/);
    assert.match(app, /OperationalConflictError[\s\S]*HttpError\(409/);
    assert.match(operational, /list_supervisor_maintenance_issues_v2/);
    assert.match(operational, /create_supervisor_maintenance_issue_with_photo_v2/);
    assert.match(operational, /expected_revision:input\.expectedRevision/);
    assert.match(operational, /create_maintenance_purchase_log_v2/);
    assert.match(operational, /reimburse_maintenance_purchase_log_v2/);
    assert.match(app, /Idempotency-Key/);
    assert.match(app, /maintenancePurchaseHistoryPageSchema/);
  });
});
