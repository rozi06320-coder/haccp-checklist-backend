import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.join(process.cwd(), "supabase/migrations/20260921130000_purchase_requests_phase1b.sql");
const detailsMigrationPath = path.join(process.cwd(), "supabase/migrations/20260923100000_purchasing_purchase_request_details.sql");
const financialDocumentsMigrationPath = path.join(process.cwd(), "supabase/migrations/20260923120000_purchasing_purchase_request_financial_documents.sql");
const linkMigrationPath = path.join(process.cwd(), "supabase/migrations/20260924120000_central_purchasing_purchase_log_link.sql");

describe("Purchase Request migration contract", () => {
  it("creates a separate request and item domain with no Purchase Log or expense coupling", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /create table public\.purchase_requests/i);
    assert.match(sql, /create table public\.purchase_request_items/i);
    assert.match(sql, /category text not null check \(category in \('stationary','kitchen','other'\)\)/i);
    assert.match(sql, /status text not null default 'submitted'/i);
    assert.match(sql, /quantity numeric not null check \(quantity > 0\)/i);
    assert.doesNotMatch(sql, /branch_purchase_logs|expense|reimbursement|invoice/i);
  });

  it("keeps mutations behind service-role RPCs with explicit supervisor and purchasing gates", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /public\.create_supervisor_purchase_request/);
    assert.match(sql, /private\.purchase_request_actor_branch_scope/);
    assert.match(sql, /membership\.role = 'branch_manager'/);
    assert.match(sql, /private\.has_active_purchasing_membership\(actor_user_id, target_organization_id\)/);
    assert.match(sql, /grant execute on function public\.create_supervisor_purchase_request\(uuid, uuid, text, text, jsonb\) to service_role/i);
    assert.match(sql, /grant execute on function public\.list_purchasing_purchase_requests\(uuid, uuid, text\) to service_role/i);
    assert.doesNotMatch(sql, /grant execute .* to authenticated/i);
  });

  it("allows only Phase 1B purchasing status transitions", async () => {
    const sql = await readFile(migrationPath, "utf8");
    assert.match(sql, /v_request\.status = 'submitted' and next_status = 'processing'/);
    assert.match(sql, /v_request\.status = 'processing' and next_status = 'purchased'/);
    assert.doesNotMatch(sql, /next_status = 'received'/);
  });

  it("adds item-level purchasing details without coupling requests to Purchase Logs", async () => {
    const sql = await readFile(detailsMigrationPath, "utf8");
    assert.match(sql, /alter table public\.purchase_request_items/i);
    for (const column of ["vendor_name", "purchased_quantity", "actual_unit_cost", "actual_total_cost", "purchasing_notes"]) {
      assert.match(sql, new RegExp(`add column if not exists ${column}`, "i"));
    }
    assert.match(sql, /if next_status = 'purchased'/i);
    assert.match(sql, /purchase details incomplete/i);
    assert.match(sql, /purchase_request_items_actual_cost_breakdown_check/i);
    assert.match(sql, /actual_total_cost = pg_catalog\.round\(purchased_quantity \* actual_unit_cost, 2\)/i);
    assert.match(sql, /private\.has_active_purchasing_membership\(actor_user_id, target_organization_id\)/i);
    assert.doesNotMatch(sql, /insert into public\.branch_purchase_logs|expense/i);
  });

  it("adds a dedicated read-only Purchasing Purchase Log list RPC", async () => {
    const sql = await readFile(detailsMigrationPath, "utf8");
    assert.match(sql, /create function public\.list_purchasing_purchase_logs/i);
    assert.match(sql, /private\.has_active_purchasing_membership\(actor_user_id, target_organization_id\)/i);
    assert.match(sql, /log\.organization_id = target_organization_id/i);
    assert.match(sql, /log\.deleted_at is null/i);
    assert.match(sql, /grant execute on function public\.list_purchasing_purchase_logs\(uuid, uuid, uuid, text, date, date, text\) to service_role/i);
    assert.doesNotMatch(sql, /update public\.branch_purchase_logs|delete from public\.branch_purchase_logs/i);
  });

  it("adds Purchase Request financial breakdown, documents, and save-only details without Purchase Log coupling", async () => {
    const sql = await readFile(financialDocumentsMigrationPath, "utf8");
    for (const column of ["invoice_number", "before_tax_amount", "tax_amount", "total_amount"]) {
      assert.match(sql, new RegExp(`add column if not exists ${column}`, "i"));
    }
    assert.match(sql, /insert into storage\.buckets\(id, name, public, file_size_limit, allowed_mime_types\)/i);
    assert.match(sql, /'purchase-request-attachments'/i);
    assert.match(sql, /create table if not exists public\.purchase_request_item_attachments/i);
    assert.match(sql, /before_tax_amount \+ tax_amount/i);
    assert.match(sql, /actual_total_cost = v_actual_total_cost/i);
    assert.match(sql, /public\.save_purchasing_purchase_request_details/i);
    assert.match(sql, /v_request\.status <> 'processing'/i);
    assert.match(sql, /private\.has_active_purchasing_membership\(actor_user_id, target_organization_id\)/i);
    assert.match(sql, /grant execute on function public\.save_purchasing_purchase_request_details\(uuid, uuid, uuid, jsonb\) to service_role/i);
    assert.doesNotMatch(sql, /insert into public\.branch_purchase_logs|insert into public\.maintenance_purchase_logs|reimbursement|expense/i);
  });

  it("links purchased request items to Branch Purchase Logs without settlement/payment-source state", async () => {
    const sql = await readFile(linkMigrationPath, "utf8");
    assert.doesNotMatch(sql, /payment_source|company_paid|reimburse_purchasing_purchase_request_item/i);
    assert.doesNotMatch(sql, /purchase_request_items[\s\S]*settlement_status/i);
    assert.match(sql, /add column if not exists source_type text/i);
    assert.match(sql, /source_purchase_request_id uuid/i);
    assert.match(sql, /source_purchase_request_item_id uuid/i);
    assert.match(sql, /create unique index branch_purchase_logs_central_purchasing_item_key/i);
    assert.match(sql, /where source_type = 'central_purchasing'[\s\S]*source_purchase_request_item_id is not null/i);
    assert.match(sql, /insert into public\.branch_purchase_logs/i);
    assert.match(sql, /'unpaid'/i);
    assert.match(sql, /source_type='central_purchasing'/i);
    assert.match(sql, /existing\.source_type='central_purchasing'[\s\S]*central purchasing purchase logs are source managed/i);
  });
});
