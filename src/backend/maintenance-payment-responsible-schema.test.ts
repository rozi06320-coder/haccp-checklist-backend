import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20260829153000_maintenance_payment_responsible_schema.sql";
const source = () => readFile(path.resolve(migrationPath), "utf8");

describe("Maintenance payment and responsible person schema foundation", () => {
  it("adds only nullable compatibility columns without changing RPC/API contracts", async () => {
    const migration = await source();

    assert.match(migration, /alter table public\.maintenance_purchase_logs\s+add column if not exists payment_method text null;/);
    assert.match(migration, /alter table public\.maintenance_issues\s+add column if not exists responsible_person_name text null;/);

    assert.doesNotMatch(migration, /create or replace function/i);
    assert.doesNotMatch(migration, /drop function/i);
    assert.doesNotMatch(migration, /alter type/i);
    assert.doesNotMatch(migration, /returns table/i);
    assert.doesNotMatch(migration, /grant execute/i);
    assert.doesNotMatch(migration, /payment_status\s*=/i);
  });

  it("constrains payment method to the new nullable canonical values", async () => {
    const migration = await source();

    assert.match(migration, /constraint maintenance_purchase_logs_payment_method_check check/);
    assert.match(migration, /payment_method is null/);
    assert.match(migration, /payment_method in \('cash', 'credit_card', 'pay_later'\)/);
    assert.doesNotMatch(migration, /payment_method text not null/i);
    assert.doesNotMatch(migration, /default\s+'cash'|default\s+'credit_card'|default\s+'pay_later'/i);
  });

  it("keeps payment method separate from reimbursement payment_status semantics", async () => {
    const migration = await source();

    assert.doesNotMatch(migration, /alter table public\.maintenance_purchase_logs[\s\S]*payment_status/i);
    assert.doesNotMatch(migration, /case[\s\S]*payment_method[\s\S]*payment_status/i);
    assert.doesNotMatch(migration, /payment_status[\s\S]*payment_method/i);
  });

  it("allows nullable trimmed responsible person names up to 100 characters", async () => {
    const migration = await source();

    assert.match(migration, /constraint maintenance_issues_responsible_person_name_check check/);
    assert.match(migration, /responsible_person_name is null/);
    assert.match(migration, /responsible_person_name = pg_catalog\.btrim\(responsible_person_name\)/);
    assert.match(migration, /pg_catalog\.char_length\(responsible_person_name\) between 1 and 100/);
    assert.doesNotMatch(migration, /responsible_person_name uuid/i);
    assert.doesNotMatch(migration, /references public\.profiles/i);
    assert.doesNotMatch(migration, /drop column .*assigned_to/i);
  });
});
