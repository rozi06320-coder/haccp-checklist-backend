import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationUrl=new URL("../../supabase/migrations/20260930140000_supervisor_overview_completion_basis.sql",import.meta.url);
const appUrl=new URL("./app.ts",import.meta.url);

describe("Supervisor Overview completion basis migration",()=>{
 it("replaces only the exact Supervisor Overview RPC and preserves access and business-date behavior",async()=>{
  const sql=await readFile(migrationUrl,"utf8");
  assert.match(sql,/create or replace function public\.get_phase4a_supervisor_overview\(actor_user_id uuid,target_branch_id uuid\)/);
  assert.equal((sql.match(/create or replace function/g)??[]).length,1);
  assert.match(sql,/private\.actor_can_read_operational_branch\(actor_user_id,target_branch_id\)/);
  assert.match(sql,/private\.phase4a_business_date\(b\.timezone\)/);
  assert.match(sql,/security definer set search_path=''/);
  assert.match(sql,/revoke all on function public\.get_phase4a_supervisor_overview\(uuid,uuid\) from public,anon,authenticated/);
  assert.match(sql,/grant execute on function public\.get_phase4a_supervisor_overview\(uuid,uuid\) to service_role/);
 });

 it("keeps raw metrics while adding applicable missing Oil and a finalized completion basis",async()=>{
  const sql=await readFile(migrationUrl,"utf8");
  assert.match(sql,/select 'oil_tracking','not_started',2::bigint,0::bigint,0::bigint,0::bigint/);
  assert.match(sql,/count\(r\.id\)filter\(where r\.in_use_today\)\*2/);
  assert.match(sql,/case when checklist_type not in\('oil_tracking','cold_storage'\)or state='submitted'or expected_checks=0 then answered_checks/);
  assert.match(sql,/least\(answered_checks,greatest\(expected_checks-1,0\)\)/);
  assert.match(sql,/least\(99,round\(completion_answered_checks\*100\.0\/expected_checks\)::int\)/);
  assert.match(sql,/'answered_checks',m\.answered_checks/);
  assert.doesNotMatch(sql,/'completion_answered_checks',m\.completion_answered_checks/);
  for(const type of ["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage"])assert.match(sql,new RegExp(type));
  assert.doesNotMatch(sql,/sales_tracking|daily_inventory|daily_waste|daily_usage/);
 });

 it("keeps the API count contract strict while validating completion against checklist state",async()=>{
  const source=await readFile(appUrl,"utf8");
  assert.match(source,/overviewCompletionPercentage=.*Math\.min\(99,Math\.round/);
  assert.match(source,/\["oil_tracking","cold_storage"\]\.includes\(value\.checklist_type\)/);
  assert.match(source,/Invalid completion percentage total\./);
  assert.match(source,/value\.totals\[key\]!==value\.checklists\.reduce/);
 });
});
