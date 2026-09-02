import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const migrationPath = "supabase/migrations/20260902130000_maintenance_helper_nullif_runtime_repair.sql";
const source = () => readFile(path.resolve(migrationPath), "utf8");

describe("Maintenance helper NULLIF runtime repair", () => {
  it("replaces only the two affected helper signatures without a catalog workaround", async () => {
    const sql = await source();
    assert.deepEqual(
      [...sql.matchAll(/create or replace function\s+([^\s(]+)\(([^)]*)\)/gi)]
        .map((match) => `${match[1]}(${match[2]})`),
      [
        "private.clean_maintenance_payment_method(candidate text)",
        "private.clean_maintenance_responsible_person(candidate text)",
      ],
    );
    assert.doesNotMatch(sql, /pg_catalog\.nullif\s*\(/i);
    assert.doesNotMatch(sql, /create(?:\s+or\s+replace)?\s+function\s+pg_catalog\.nullif/i);
    assert.equal((sql.match(/returns text/g) ?? []).length, 2);
    assert.equal((sql.match(/set search_path = ''/g) ?? []).length, 2);
    assert.equal((sql.match(/language plpgsql/g) ?? []).length, 2);
    assert.equal((sql.match(/\bimmutable\b/g) ?? []).length, 2);
    assert.equal((sql.match(/security invoker/g) ?? []).length, 2);
    assert.doesNotMatch(sql, /\b(?:grant|revoke)\b/i);
  });

  it("preserves payment method trimming, nullability, and allowed values", async () => {
    const sql = await source();
    const payment = sql.slice(
      sql.indexOf("create or replace function private.clean_maintenance_payment_method"),
      sql.indexOf("create or replace function private.clean_maintenance_responsible_person"),
    );
    assert.match(payment, /cleaned text := pg_catalog\.btrim\(coalesce\(candidate, ''\)\)/);
    assert.match(payment, /if cleaned = '' then\s+return null/);
    assert.match(payment, /cleaned not in \('cash', 'credit_card', 'pay_later'\)/);
    assert.match(payment, /invalid maintenance payment method'[\s\S]*errcode = '22023'/);
  });

  it("preserves responsible-person trimming, nullability, and length validation", async () => {
    const sql = await source();
    const responsible = sql.slice(
      sql.indexOf("create or replace function private.clean_maintenance_responsible_person"),
    );
    assert.match(responsible, /cleaned text := pg_catalog\.btrim\(coalesce\(candidate, ''\)\)/);
    assert.match(responsible, /if cleaned = '' then\s+return null/);
    assert.match(responsible, /pg_catalog\.char_length\(cleaned\) > 100/);
    assert.match(responsible, /invalid maintenance responsible person'[\s\S]*errcode = '22023'/);
  });
});
