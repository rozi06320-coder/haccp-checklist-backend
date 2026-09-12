import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationPath = new URL("../../supabase/migrations/20260912100000_daily_inventory_persistence.sql", import.meta.url);

describe("Daily Inventory Phase 1 canonical DB migration SQL boundary", () => {
  // 1. tables/constraints/indexes exist
  it("1. tables, constraints, and indexes exist", async () => {
    const migration = await readFile(migrationPath, "utf8");

    // Tables exist
    assert.match(migration, /create table if not exists public\.branch_daily_inventory_reports/);
    assert.match(migration, /create table if not exists public\.branch_daily_inventory_entries/);

    // Report constraints
    assert.match(migration, /constraint branch_daily_inventory_reports_revision_check check \(revision >= 1\)/);
    assert.match(migration, /constraint branch_daily_inventory_reports_branch_org_fk foreign key \(branch_id, organization_id\) references public\.branches\(id, organization_id\)/);
    assert.match(migration, /constraint branch_daily_inventory_reports_branch_date_key unique \(branch_id, business_date\)/);
    assert.match(migration, /constraint branch_daily_inventory_reports_scope_key unique \(id, organization_id, branch_id, business_date\)/);

    // Entry constraints
    assert.match(migration, /constraint branch_daily_inventory_entries_manual_opening_check check/);
    assert.match(migration, /constraint branch_daily_inventory_entries_receiving_check check \(receiving_quantity >= 0\)/);
    assert.match(migration, /constraint branch_daily_inventory_entries_transfer_in_check check \(transfer_in_quantity >= 0\)/);
    assert.match(migration, /constraint branch_daily_inventory_entries_transfer_out_check check \(transfer_out_quantity >= 0\)/);
    assert.match(migration, /constraint branch_daily_inventory_entries_actual_closing_check check \(actual_closing_quantity is null or actual_closing_quantity >= 0\)/);
    assert.match(migration, /constraint branch_daily_inventory_entries_unit_snapshot_check check \(\s*inventory_item_unit_snapshot in \('pcs', 'kg', 'g', 'L', 'ml'\)\s*\)/);
    assert.match(migration, /constraint branch_daily_inventory_entries_pcs_integer_check check/);
    assert.match(migration, /constraint branch_daily_inventory_entries_report_scope_fk foreign key \(report_id, organization_id, branch_id, business_date\) references public\.branch_daily_inventory_reports/);
    assert.match(migration, /constraint branch_daily_inventory_entries_report_item_key unique \(report_id, inventory_item_id\)/);
    assert.match(migration, /constraint branch_daily_inventory_entries_branch_date_item_key unique \(branch_id, business_date, inventory_item_id\)/);

    // Indexes
    assert.match(migration, /create index if not exists branch_daily_inventory_reports_branch_date_idx/);
    assert.match(migration, /create index if not exists branch_daily_inventory_entries_report_idx/);
    assert.match(migration, /create index if not exists branch_daily_inventory_entries_branch_date_item_idx/);
  });

  // 2. RLS enabled
  it("2. RLS enabled on both daily inventory tables", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /alter table public\.branch_daily_inventory_reports enable row level security/);
    assert.match(migration, /alter table public\.branch_daily_inventory_entries enable row level security/);
    assert.match(migration, /create policy branch_daily_inventory_reports_select_authorized[\s\S]*private\.has_branch_access\(branch_id\)/);
    assert.match(migration, /create policy branch_daily_inventory_entries_select_authorized[\s\S]*private\.has_branch_access\(branch_id\)/);
  });

  // 3. authenticated direct mutations blocked
  it("3. authenticated direct mutations blocked and restricted to service-role RPCs", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /revoke all on table public\.branch_daily_inventory_reports, public\.branch_daily_inventory_entries from public, anon, authenticated, service_role/);
    assert.match(migration, /grant select on table public\.branch_daily_inventory_reports, public\.branch_daily_inventory_entries to authenticated, service_role/);
    assert.match(migration, /revoke all on function public\.get_branch_daily_inventory\(uuid, uuid, date\), public\.get_branch_daily_inventory\(uuid, uuid, date, date\), public\.save_branch_daily_inventory\(uuid, uuid, date, bigint, jsonb\) from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.get_branch_daily_inventory\(uuid, uuid, date\), public\.get_branch_daily_inventory\(uuid, uuid, date, date\), public\.save_branch_daily_inventory\(uuid, uuid, date, bigint, jsonb\) to service_role/);
  });

  // 4. cross-branch item rejected
  it("4. cross-branch item rejected via composite foreign key and catalog lookup validation", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /constraint branch_daily_inventory_entries_inventory_item_fk foreign key \(branch_id, inventory_item_id\) references public\.branch_inventory_catalog_items\(branch_id, id\)/);
    assert.match(migration, /i\.organization_id = ctx\.organization_id[\s\S]*and i\.branch_id = ctx\.branch_id/);
    assert.match(migration, /if cat_item\.id is null then[\s\S]*raise exception 'inventory item unavailable' using errcode = '42501'/);
  });

  // 5. Day 1 manual opening accepted
  it("5. Day 1 manual opening accepted in check constraint and save logic", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /extract\(day from business_date\) = 1 and \(manual_opening_quantity is null or manual_opening_quantity >= 0\)/);
    assert.match(migration, /is_day_one := \(extract\(day from target_business_date\) = 1\)/);
    assert.match(migration, /when extract\(day from target_business_date\) = 1 then entry\.manual_opening_quantity/);
  });

  // 6. Day 2 manual opening rejected
  it("6. Day 2 manual opening rejected by check constraint and save validation", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /extract\(day from business_date\) <> 1 and manual_opening_quantity is null/);
    assert.match(migration, /if not is_day_one then[\s\S]*raise exception 'manual opening quantity allowed only on day 1' using errcode = '22023'/);
  });

  // 7. Day 2 opening derived from previous day's actual closing
  it("7. Day 2 opening derived from previous day's actual closing", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /select prev_entry\.actual_closing_quantity[\s\S]*from public\.branch_daily_inventory_entries prev_entry[\s\S]*where prev_entry\.organization_id = ctx\.organization_id[\s\S]*and prev_entry\.branch_id = ctx\.branch_id[\s\S]*and prev_entry\.business_date = \(target_business_date - 1\)[\s\S]*and prev_entry\.inventory_item_id = entry\.inventory_item_id/);
    assert.match(migration, /'is_opening_manual', \(extract\(day from target_business_date\) = 1\)/);
  });

  // 8. missing previous closing returns opening null, not zero
  it("8. missing previous closing returns opening null, not zero", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Subquery returns NULL when no matching previous entry exists, never coalescing to 0
    assert.doesNotMatch(migration, /coalesce\(\s*\(\s*select prev_entry\.actual_closing_quantity[^)]+\),\s*0\)/);
  });

  // 9. previous day closing 0 returns opening 0
  it("9. previous day closing 0 returns opening 0", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Direct subquery select prev_entry.actual_closing_quantity preserves 0 without converting to null
    assert.doesNotMatch(migration, /nullif\(\s*\(\s*select prev_entry\.actual_closing_quantity/);
  });

  // 10. pcs decimal validation follows existing canonical unit rule
  it("10. pcs decimal validation follows existing canonical unit rule", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /constraint branch_daily_inventory_entries_pcs_integer_check check/);
    assert.match(migration, /if effective_unit = 'pcs' then/);
    assert.match(migration, /pg_catalog\.floor\(stage_record\.receiving_quantity\) <> stage_record\.receiving_quantity/);
    assert.match(migration, /raise exception 'pcs quantity must be an integer' using errcode = '22023'/);
  });

  // 11. non-pcs decimal quantities allowed within existing rules
  it("11. non-pcs decimal quantities allowed within existing rules", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // pcs check explicitly guards on unit = 'pcs', leaving kg/g/L/ml unconstrained by floor()
    assert.match(migration, /inventory_item_unit_snapshot <> 'pcs' or/);
    assert.match(migration, /if effective_unit = 'pcs' then/);
  });

  // 12. actual closing null vs explicit 0 distinct
  it("12. actual closing null vs explicit 0 distinct", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /actual_closing_quantity numeric null/);
    assert.match(migration, /jsonb_typeof\(entry_row->'actual_closing_quantity'\) = 'number'/);
    assert.match(migration, /parsed_actual_closing := \(entry_row->>'actual_closing_quantity'\)::numeric/);
    // Preserves null when field is null vs 0 when field is 0
    assert.doesNotMatch(migration, /parsed_actual_closing := coalesce\(\(entry_row->>'actual_closing_quantity'\)::numeric, 0\)/);
  });

  // 13. expected_revision=0 create behavior
  it("13. expected_revision=0 create behavior", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /if report\.id is null and expected_revision <> 0 then[\s\S]*raise exception 'daily inventory changed' using errcode = '40001'/);
    assert.match(migration, /insert into public\.branch_daily_inventory_reports[\s\S]*values\s*\([\s\S]*1,\s*actor_user_id,\s*actor_user_id\s*\)/);
  });

  // 14. stale revision rejected
  it("14. stale revision rejected with 40001", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /if report\.id is not null and expected_revision <> report\.revision then[\s\S]*raise exception 'daily inventory changed' using errcode = '40001'/);
  });

  // 15. successful PATCH increments revision once
  it("15. successful PATCH increments revision once per RPC call", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /set revision = existing\.revision \+ 1/);
    // Confirm revision is incremented on report update, not per-entry loop
    assert.doesNotMatch(migration, /update public\.branch_daily_inventory_reports[\s\S]*for each/);
  });

  // 16. partial PATCH preserves omitted items
  it("16. partial PATCH preserves omitted items", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Update applies only matching stage items
    assert.match(migration, /update public\.branch_daily_inventory_entries entry[\s\S]*from branch_daily_inventory_stage stage, branch_daily_inventory_existing existing[\s\S]*where entry\.report_id = report\.id[\s\S]*and entry\.inventory_item_id = stage\.inventory_item_id/);
    // Never deletes unmentioned items
    assert.doesNotMatch(migration, /delete from public\.branch_daily_inventory_entries entry[\s\S]*not in \(\s*select inventory_item_id from branch_daily_inventory_stage\)/);
  });

  // 17. explicit empty entry deletes existing entry
  it("17. explicit empty entry deletes existing entry", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /delete from public\.branch_daily_inventory_entries entry[\s\S]*using branch_daily_inventory_stage stage[\s\S]*where entry\.report_id = report\.id[\s\S]*and entry\.inventory_item_id = stage\.inventory_item_id[\s\S]*and stage\.manual_opening_quantity is null[\s\S]*and stage\.receiving_quantity = 0[\s\S]*and stage\.transfer_in_quantity = 0[\s\S]*and stage\.transfer_out_quantity = 0[\s\S]*and stage\.actual_closing_quantity is null/);
  });

  // 18. new empty entry creates nothing
  it("18. new empty entry creates nothing", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Insert filters out empty entries
    assert.match(migration, /insert into public\.branch_daily_inventory_entries[\s\S]*where not \([\s\S]*stage\.manual_opening_quantity is null[\s\S]*and stage\.receiving_quantity = 0[\s\S]*and stage\.transfer_in_quantity = 0[\s\S]*and stage\.transfer_out_quantity = 0[\s\S]*and stage\.actual_closing_quantity is null[\s\S]*\)/);
  });

  // 19. inactive existing historical item correction allowed
  it("19. inactive existing historical item correction allowed", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Only enforces is_active for new rows (when item does not exist in branch_daily_inventory_existing)
    assert.match(migration, /if not exists \(select 1 from branch_daily_inventory_existing e where e\.inventory_item_id = stage_record\.inventory_item_id\) then/);
    assert.match(migration, /if not cat_item\.is_active then[\s\S]*raise exception 'cannot record inventory for inactive item' using errcode = '22023'/);
  });

  // 20. new inactive item rejected
  it("20. new inactive item rejected", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /if not exists \(select 1 from branch_daily_inventory_existing e where e\.inventory_item_id = stage_record\.inventory_item_id\) then[\s\S]*if not cat_item\.is_active then/);
  });

  // 21. future date rejected
  it("21. future date rejected", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /if target_business_date > ctx\.business_date then[\s\S]*raise exception 'daily inventory future business date denied' using errcode = '22023'/);
    assert.match(migration, /if start_date > ctx\.business_date or end_date > ctx\.business_date then[\s\S]*raise exception 'daily inventory future business date denied' using errcode = '22023'/);
  });

  // 22. same-name different-UUID items remain separate
  it("22. same-name different-UUID items remain separate", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /constraint branch_daily_inventory_entries_branch_date_item_key unique \(branch_id, business_date, inventory_item_id\)/);
    assert.match(migration, /constraint branch_daily_inventory_entries_report_item_key unique \(report_id, inventory_item_id\)/);
    assert.match(migration, /and prev_entry\.inventory_item_id = entry\.inventory_item_id/);
  });

  // 23. range GET returns requested canonical dates
  it("23. range GET returns requested canonical dates", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /create or replace function public\.get_branch_daily_inventory\(\s*actor_user_id uuid,\s*target_branch_id uuid,\s*start_date date,\s*end_date date\s*\)/);
    assert.match(migration, /'start_date', start_date/);
    assert.match(migration, /'end_date', end_date/);
    assert.match(migration, /'reports', coalesce\(/);
  });

  // 24. range GET opening derivation works across dates
  it("24. range GET opening derivation works across dates", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /when extract\(day from cal\.day_date\) = 1 then entry\.manual_opening_quantity/);
    assert.match(migration, /and prev_entry\.business_date = \(cal\.day_date - 1\)/);
    assert.match(migration, /and prev_entry\.inventory_item_id = entry\.inventory_item_id/);
  });

  // 25. month boundary: Sep 30 actual closing does NOT automatically become Oct 1 manual opening; Oct 1 opening is its own persisted manual value
  it("25. month boundary: Sep 30 actual closing does NOT automatically become Oct 1 manual opening", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Day 1 branch returns entry.manual_opening_quantity directly without inspecting previous calendar day
    assert.match(migration, /when extract\(day from target_business_date\) = 1 then entry\.manual_opening_quantity/);
    assert.match(migration, /when extract\(day from cal\.day_date\) = 1 then entry\.manual_opening_quantity/);
  });

  // 26. no Waste/Sales/Expected/Variance columns exist
  it("26. no Waste, Sales Usage, Expected Closing, or Variance columns exist in tables", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.doesNotMatch(migration, /sales_usage numeric/i);
    assert.doesNotMatch(migration, /waste numeric/i);
    assert.doesNotMatch(migration, /expected_closing numeric/i);
    assert.doesNotMatch(migration, /variance numeric/i);
  });

  // 27. nonexistent report GET returns revision 0 and empty entries array
  it("27. nonexistent report GET returns revision 0, report_id null, and empty entries array", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /if report\.id is null then[\s\S]*'report_id',\s*null[\s\S]*'revision',\s*0[\s\S]*'created_at',\s*null[\s\S]*'updated_at',\s*null[\s\S]*'entries',\s*'\[\]'::jsonb/);
  });

  // 28. existing report GET returns revision >= 1
  it("28. existing report GET returns revision >= 1 from stored report", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /constraint branch_daily_inventory_reports_revision_check check \(revision >= 1\)/);
    assert.match(migration, /'revision',\s*report\.revision/);
  });

  // 29. range GET returns every requested date, including unpersisted/empty dates
  it("29. range GET returns every requested date via calendar series, including unpersisted/empty dates", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /from\s*\(\s*select\s*\(start_date \+ s\)::date as day_date\s*from pg_catalog\.generate_series\(0,\s*end_date - start_date\)\s*as s\s*\)\s*cal/);
    assert.match(migration, /left join public\.branch_daily_inventory_reports report[\s\S]*on report\.organization_id = ctx\.organization_id[\s\S]*and report\.branch_id = ctx\.branch_id[\s\S]*and report\.business_date = cal\.day_date/);
    assert.match(migration, /'revision', coalesce\(report\.revision, 0\)/);
    assert.match(migration, /order by cal\.day_date asc/);
  });

  // 30. duplicate inventory_item_id input rejected
  it("30. duplicate inventory_item_id input in single payload rejected with 23505", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /inventory_item_id uuid primary key/);
    assert.match(migration, /exception when unique_violation then[\s\S]*raise exception 'duplicate daily inventory item' using errcode = '23505'/);
  });

  // 31. invalid JSON numeric types rejected
  it("31. invalid JSON numeric types (strings, booleans, objects, arrays, NaN) rejected", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Typechecks before parsing:
    assert.match(migration, /jsonb_typeof\(entry_row->'manual_opening_quantity'\) not in \('number', 'null'\)/);
    assert.match(migration, /jsonb_typeof\(entry_row->'receiving_quantity'\) <> 'number'/);
    assert.match(migration, /jsonb_typeof\(entry_row->'transfer_in_quantity'\) <> 'number'/);
    assert.match(migration, /jsonb_typeof\(entry_row->'transfer_out_quantity'\) <> 'number'/);
    assert.match(migration, /jsonb_typeof\(entry_row->'actual_closing_quantity'\) not in \('number', 'null'\)/);
    // Explicit NaN defense:
    assert.match(migration, /\(parsed_manual_opening\)::text = 'NaN'/);
    assert.match(migration, /\(parsed_receiving\)::text = 'NaN'/);
    assert.match(migration, /\(parsed_transfer_in\)::text = 'NaN'/);
    assert.match(migration, /\(parsed_transfer_out\)::text = 'NaN'/);
    assert.match(migration, /\(parsed_actual_closing\)::text = 'NaN'/);
  });

  // 32. no-op mutation does not increment revision
  it("32. no-op mutation preserves revision without bumping", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.match(migration, /if not changed then[\s\S]*return private\.branch_daily_inventory_payload\(actor_user_id, target_branch_id, target_business_date\);/);
  });

  // 33. deleting the final entry leaves header intentionally
  it("33. deleting final entry leaves header with incremented revision", async () => {
    const migration = await readFile(migrationPath, "utf8");
    // Report revision is updated unconditionally when changed is true
    assert.match(migration, /update public\.branch_daily_inventory_reports existing[\s\S]*set revision = existing\.revision \+ 1/);
    // Report header is NEVER deleted when all entries are removed
    assert.doesNotMatch(migration, /delete from public\.branch_daily_inventory_reports/);
  });

  // 34. regression guard: rejects invalid schema-qualified extract syntax
  it("34. regression guard: migration SQL does not contain invalid pg_catalog.extract syntax", async () => {
    const migration = await readFile(migrationPath, "utf8");
    assert.doesNotMatch(migration, /pg_catalog\.extract\s*\(/);
  });
});
