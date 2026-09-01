import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(
  new URL("../../supabase/migrations/20260901190000_operational_staff_scheduled_team_moves.sql", import.meta.url),
  "utf8",
);
const foundation = readFileSync(new URL("../../supabase/migrations/20260731000000_operational_staff_foundation.sql", import.meta.url), "utf8");
const rosterBaseline = readFileSync(new URL("../../supabase/migrations/20260813113000_employee_foundation_phase_a.sql", import.meta.url), "utf8");
const hygieneBaseline = readFileSync(new URL("../../supabase/migrations/20260812030000_shared_operational_teams_phase1.sql", import.meta.url), "utf8");
const auditBaseline = readFileSync(new URL("../../supabase/migrations/20260824100000_source_owned_cross_branch_staff_transfer.sql", import.meta.url), "utf8");
const operational = readFileSync(new URL("./operational.ts", import.meta.url), "utf8");
const admin = readFileSync(new URL("./admin.ts", import.meta.url), "utf8");

function definition(source: string, marker: string) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, marker);
  const end = source.indexOf("$$;", start);
  assert.notEqual(end, -1, marker);
  return source.slice(start, end + "$$;".length);
}

function normalized(source: string) {
  return source.replace(/\s+/gu, " ").trim();
}

describe("scheduled same-branch team move SQL boundary", () => {
  it("stores one explicit pending move without creating a future assignment", () => {
    assert.match(migration, /create table public\.operational_staff_scheduled_team_moves/);
    assert.match(migration, /where status='pending'/);
    assert.match(migration, /effective_business_date=requested_business_date\+1/);
    assert.match(migration, /source_assignment_id uuid not null/);
    assert.match(migration, /foreign key\(operational_staff_id,branch_id,organization_id\)/);
    assert.doesNotMatch(migration, /insert into public\.operational_staff_assignments[\s\S]{0,500}status='pending'/);
  });

  it("serializes source and destination Hygiene before choosing immediate or scheduled", () => {
    assert.match(migration, /old_assignment\.operational_team_id::text<target_team\.id::text/);
    assert.match(migration, /lock_operational_team_hygiene\(target_branch_id,old_assignment\.operational_team_id,current_business_date\)/);
    assert.match(migration, /lock_operational_team_hygiene\(target_branch_id,target_team\.id,current_business_date\)/);
    assert.match(migration, /submission\.state='submitted'/);
    assert.match(migration, /snapshot\.operational_staff_id=target_staff_id/);
    assert.match(migration, /submission\.operational_team_id=old_assignment\.operational_team_id/);
    assert.match(migration, /submission\.operational_team_id=target_team\.id/);
    assert.match(migration, /invalid destination team' using errcode='22023'/);
    assert.match(migration, /staff assignment changed' using errcode='40001'/);
    assert.match(migration, /staff move denied' using errcode='42501'/);
  });

  it("keeps immediate duty carry-forward and omits it from scheduled activation", () => {
    const requestFunction = migration.slice(
      migration.indexOf("create function private.request_operational_staff_team_move"),
      migration.indexOf("create or replace function public.move_operational_staff_team"),
    );
    const activationFunction = migration.slice(
      migration.indexOf("create function private.apply_due_operational_staff_team_moves"),
      migration.indexOf("create function public.apply_due_operational_staff_team_moves"),
    );
    assert.match(requestFunction, /prior_duty/);
    assert.match(requestFunction, /insert into public\.operational_staff_duty_statuses/);
    assert.doesNotMatch(activationFunction, /insert into public\.operational_staff_duty_statuses/);
  });

  it("applies due moves idempotently with exact assignment dates and safe blocking", () => {
    assert.match(migration, /for update of move skip locked/);
    assert.match(migration, /valid_to=scheduled\.effective_business_date-1/);
    assert.match(migration, /scheduled\.effective_business_date,scheduled\.requested_by_user_id/);
    assert.match(migration, /where move\.id=scheduled\.id and move\.status='pending'/);
    assert.match(migration, /'destination_inactive'/);
    assert.match(migration, /'source_assignment_changed'/);
    assert.match(migration, /'hygiene_already_submitted'/);
  });

  it("provides lazy activation at roster, Hygiene context, and Move Team boundaries", () => {
    assert.match(migration, /create or replace function public\.get_supervisor_operational_team/);
    assert.match(migration, /create or replace function private\.operational_team_hygiene_context/);
    assert.match(migration, /perform private\.apply_due_operational_staff_team_moves\(target_branch_id\)/);
    assert.match(migration, /perform private\.apply_due_operational_staff_team_moves\(target_branch\)/);
    assert.match(migration, /create function public\.get_operational_staff_team_move_context/);
    for (const method of ["getManagedOperationsSummary", "listManagedStaff", "listManagedEmployeeTeam", "listManagedTeams"]) {
      const start = operational.indexOf(`async ${method}`);
      assert.notEqual(start, -1, method);
      assert.match(operational.slice(start, start + 250), /applyDueScheduledTeamMoves/);
    }
    assert.match(admin, /async listBranchTeamsForInternalAdmin[\s\S]{0,150}applyDueScheduledTeamMoves/);
  });

  it("cancels pending moves when explicitly requested or the employee becomes inactive", () => {
    assert.match(migration, /create function public\.cancel_operational_staff_scheduled_team_move/);
    assert.match(migration, /private\.actor_can_write_operational_team\(actor_user_id,target_branch_id,scheduled\.source_operational_team_id\)/);
    assert.match(migration, /after update of employment_status on public\.operational_staff/);
    assert.match(migration, /set status='cancelled'/);
    assert.match(foundation, /employment_status = 'inactive' and deactivated_at is not null and deactivated_by is not null/);
    assert.match(migration, /cancelled_by_user_id=new\.deactivated_by/);
  });

  it("fails legacy callers closed rather than hiding a scheduled result", () => {
    const legacy = definition(migration, "create or replace function public.move_operational_staff_team");
    const canonical = definition(migration, "create function public.request_operational_staff_team_move");
    assert.match(legacy, /target_operational_team_id,false/);
    assert.match(canonical, /target_operational_team_id,true/);
    assert.match(migration, /if not allow_scheduled then[\s\S]{0,120}errcode='40001'/);
    assert.match(operational, /if \(input\.scheduledMoveContract === "phase1"\)[\s\S]{0,350}RpcSignatureMissingError\) throw new AdminOperationError\(\)/);
  });

  it("keeps blocked outcomes visible while allowing a later retry", () => {
    assert.match(migration, /move\.status in\('pending','blocked'\)/);
    assert.match(migration, /blocked_reason text/);
    assert.match(migration, /distinct on\(move\.operational_staff_id\)/);
  });

  it("keeps whole-function replacements equal to the latest canonical definitions plus activation", () => {
    const currentRoster = definition(migration, "create or replace function public.get_supervisor_operational_team")
      .replace("create or replace function", "create function")
      .replace("  perform private.apply_due_operational_staff_team_moves(target_branch_id);\n", "");
    assert.equal(normalized(currentRoster), normalized(definition(rosterBaseline, "create function public.get_supervisor_operational_team")));

    const currentHygiene = definition(migration, "create or replace function private.operational_team_hygiene_context")
      .replace("create or replace function", "create function")
      .replace("language plpgsql volatile", "language plpgsql stable")
      .replace("  perform private.apply_due_operational_staff_team_moves(target_branch);\n", "");
    assert.equal(normalized(currentHygiene), normalized(definition(hygieneBaseline, "create function private.operational_team_hygiene_context")));

    const currentAudit = definition(migration, "create or replace function private.operational_audit_details_are_allowlisted")
      .replace("'closure_reason','scheduled_move_id',\n      'move_status','effective_business_date','blocked_reason'", "'closure_reason'");
    assert.equal(normalized(currentAudit), normalized(definition(auditBaseline, "create or replace function private.operational_audit_details_are_allowlisted")));
  });

  it("keeps cross-branch transfer outside this migration and hardens mutation grants", () => {
    assert.doesNotMatch(migration, /create or replace function public\.transfer_operational_staff_branch/);
    assert.doesNotMatch(migration, /update public\.operational_staff set branch_id/);
    assert.match(migration, /from public,anon,authenticated/);
    assert.match(migration, /to service_role/);
  });

  it("preserves the 03:00 helper and contains no speculative scheduler configuration", () => {
    assert.match(migration, /private\.phase4a_business_date\(branch\.timezone\)/);
    assert.doesNotMatch(migration, /cron\.schedule|pg_cron/i);
  });
});
