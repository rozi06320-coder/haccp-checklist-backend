import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = path.resolve("supabase/migrations/20260829103000_supplier_receiving_piv_pos.sql");

describe("Supplier Receiving PIV POS contract", () => {
  it("adds nullable PIV POS storage with trim and length constraints", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /alter table public\.branch_supplier_receivings\s+add column if not exists piv_pos text null;/);
    assert.match(migration, /piv_pos = pg_catalog\.btrim\(piv_pos\)/);
    assert.match(migration, /char_length\(piv_pos\) <= 100/);
  });

  it("stores PIV POS through the existing Supplier Receiving payload without changing RPC signatures", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function public\.create_branch_supplier_receiving\(actor_user_id uuid,target_branch_id uuid,payload jsonb\)/);
    assert.match(migration, /piv_pos_value text:=nullif\(pg_catalog\.btrim\(coalesce\(payload->>'piv_pos',''\)\),''\)/);
    assert.match(migration, /char_length\(coalesce\(piv_pos_value,''\)\)>100/);
    assert.match(migration, /supplier_name_ar,piv_pos,quantity,unit,notes/);
    assert.match(migration, /coalesce\(supplier_ar,s\.supplier_name_ar\),piv_pos_value,q,unit_value/);
    assert.doesNotMatch(migration, /upper\(.*piv_pos|lower\(.*piv_pos|regexp_replace\(.*piv_pos/s);
  });

  it("returns PIV POS from Supervisor and Manager Supplier Receiving list RPCs", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /returns table\(id uuid,branch_id uuid,branch_name text,supplier_id uuid,category text,supplier_name_en text,supplier_name_ar text,piv_pos text,quantity numeric/);
    assert.match(migration, /r\.supplier_name_ar,r\.piv_pos,r\.quantity/);
    assert.match(migration, /supplier_name_ar text, piv_pos text,\s+quantity numeric/);
    assert.match(migration, /receiving\.supplier_name_ar, receiving\.piv_pos, receiving\.quantity/);
  });

  it("keeps backend route and service schemas aware of nullable PIV POS", async () => {
    const [app, operational] = await Promise.all([
      readFile(path.resolve("src/backend/app.ts"), "utf8"),
      readFile(path.resolve("src/backend/operational.ts"), "utf8"),
    ]);
    assert.match(app, /piv_pos: optionalStaffTextSchema\(100\)/);
    assert.match(app, /piv_pos: z\.string\(\)\.nullable\(\)\.optional\(\)\.transform\(\(value\) => value \?\? null\)/);
    assert.match(operational, /piv_pos: optionalStaffText\.optional\(\)\.transform\(\(value\) => value \?\? null\)/);
    assert.match(operational, /piv_pos\?: string \| null/);
  });
});
