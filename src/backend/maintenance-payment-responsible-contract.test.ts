import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20260829160000_maintenance_payment_responsible_contract.sql";
const source = () => readFile(path.resolve(migrationPath), "utf8");

describe("Maintenance payment and responsible person RPC contract", () => {
  it("does not recreate Phase 1 columns or alter payment status semantics", async () => {
    const migration = await source();

    assert.doesNotMatch(migration, /add column .*payment_method/i);
    assert.doesNotMatch(migration, /add column .*responsible_person_name/i);
    assert.doesNotMatch(migration, /payment_status\s*=\s*case[\s\S]*payment_method/i);
  });

  it("preserves legacy issue update signatures and adds responsible person overloads", async () => {
    const migration = await source();

    assert.match(migration, /create or replace function public\.update_maintenance_issue\(\s*actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text\s*\)/);
    assert.match(migration, /create or replace function public\.update_maintenance_issue\(\s*actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text, new_responsible_person_name text\s*\)/);
    assert.match(migration, /select \* from public\.update_maintenance_issue\(actor_user_id, access_user_id, target_issue_id, new_status, new_note, existing_responsible\)/);
    assert.match(migration, /create or replace function public\.update_maintenance_issue_with_repair_photo\(\s*actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text, repair_photo jsonb\s*\)/);
    assert.match(migration, /create or replace function public\.update_maintenance_issue_with_repair_photo\(\s*actor_user_id uuid, access_user_id uuid, target_issue_id uuid, new_status text, new_note text, repair_photo jsonb, new_responsible_person_name text\s*\)/);
  });

  it("threads responsible person through issue create/read RPCs", async () => {
    const migration = await source();

    assert.match(migration, /private\.clean_maintenance_responsible_person\(payload->>'responsible_person_name'\)/);
    assert.match(migration, /insert into public\.maintenance_issues as issue\([\s\S]*responsible_person_name, idempotency_key/);
    assert.match(migration, /issue\.responsible_person_name/);
    assert.match(migration, /responsible_person_name text/);
  });

  it("threads payment method through purchase create/read RPCs without changing payment status", async () => {
    const migration = await source();

    assert.match(migration, /private\.clean_maintenance_payment_method\(payload->>'payment_method'\)/);
    assert.match(migration, /insert into public\.maintenance_purchase_logs\([\s\S]*payment_method/);
    assert.match(migration, /p\.payment_status,p\.payment_method/);
    assert.match(migration, /left join public\.maintenance_issues issue on issue\.id=p\.maintenance_issue_id/);
    assert.match(migration, /issue\.responsible_person_name/);
  });

  it("keeps backend-only mutation grants hardened for new and legacy overloads", async () => {
    const migration = await source();

    for (const signature of [
      "public.create_supervisor_maintenance_issue(uuid,uuid,jsonb)",
      "public.create_supervisor_maintenance_issue_with_photo(uuid,uuid,jsonb)",
      "public.create_manager_office_maintenance_issue(uuid,uuid,jsonb)",
      "public.create_manager_office_maintenance_issue_with_photo(uuid,uuid,jsonb)",
      "public.update_maintenance_issue(uuid,uuid,uuid,text,text)",
      "public.update_maintenance_issue(uuid,uuid,uuid,text,text,text)",
      "public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb)",
      "public.update_maintenance_issue_with_repair_photo(uuid,uuid,uuid,text,text,jsonb,text)",
      "public.create_maintenance_purchase_log(uuid,uuid,jsonb)",
      "public.reimburse_maintenance_purchase_log(uuid,uuid,text)",
    ]) {
      assert.match(migration, new RegExp(`revoke all on function ${signature.replace(/[().]/gu, "\\$&")} from public, anon, authenticated`, "i"));
      assert.match(migration, new RegExp(`grant execute on function ${signature.replace(/[().]/gu, "\\$&")} to service_role`, "i"));
    }
  });
});
