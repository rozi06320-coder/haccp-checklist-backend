import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const coreMigration = readFileSync(
  new URL("../../supabase/migrations/20260901190000_operational_staff_scheduled_team_moves.sql", import.meta.url),
  "utf8",
);
const cronMigration = readFileSync(
  new URL("../../supabase/migrations/20260901200000_operational_staff_scheduled_team_move_cron.sql", import.meta.url),
  "utf8",
);

describe("scheduled team move cron SQL boundary", () => {
  it("keeps scheduling in a separate forward migration", () => {
    assert.doesNotMatch(coreMigration, /create extension if not exists pg_cron|cron\.schedule/i);
    assert.match(cronMigration, /create extension if not exists pg_cron/);
    assert.match(cronMigration, /public\.apply_due_operational_staff_team_moves\(uuid,uuid\)/);
  });

  it("installs one deterministic named job at a one-minute cadence", () => {
    assert.match(cronMigration, /cron\.schedule\(\s*'operational-staff-scheduled-team-moves'/);
    assert.match(cronMigration, /'\* \* \* \* \*'/);
    assert.match(cronMigration, /'select public\.apply_due_operational_staff_team_moves\(null::uuid, null::uuid\);'/);
    assert.doesNotMatch(cronMigration, /insert\s+into\s+cron\.job/i);
  });

  it("uses the named-job upsert contract and restores an inactive job", () => {
    assert.match(cronMigration, /cron\.schedule\(text,text,text\)/);
    assert.match(cronMigration, /cron\.alter_job\(bigint,text,text,text,text,boolean\)/);
    assert.match(cronMigration, /perform cron\.alter_job\(scheduled_job_id, active := true\)/);
    assert.doesNotMatch(cronMigration, /cron\.unschedule/);
  });

  it("keeps activation internal and avoids HTTP scheduling", () => {
    assert.doesNotMatch(cronMigration, /grant[\s\S]*\b(?:anon|authenticated)\b/i);
    assert.doesNotMatch(cronMigration, /pg_net|net\.http|http_request|webhook/i);
    assert.match(coreMigration, /revoke all on function[\s\S]*public\.apply_due_operational_staff_team_moves\(uuid,uuid\)[\s\S]*from public,anon,authenticated/);
    assert.match(coreMigration, /grant execute on function[\s\S]*public\.apply_due_operational_staff_team_moves\(uuid,uuid\)[\s\S]*to service_role/);
  });

  it("retains per-move blocking and skip-locked processing in the activation function", () => {
    assert.match(coreMigration, /for update of move skip locked/);
    assert.match(coreMigration, /set status='blocked'/);
    assert.match(coreMigration, /where move\.id=scheduled\.id and move\.status='pending'/);
  });
});
