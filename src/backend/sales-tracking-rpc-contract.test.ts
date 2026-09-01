import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe,it } from "node:test";
import { checklistRequestHash,salesTrackingDraftRpcArgs,salesTrackingSubmitRpcArgs,type SalesTrackingDraftPayload } from "./checklist-persistence";

const actor="17000000-0000-4000-8000-000000000011",branch="27000000-0000-4000-8000-000000000011",key="47000000-0000-4000-8000-000000000011";
const payload:SalesTrackingDraftPayload={sales_rows:[{entry_date:"2026-08-12",actual_cash:"10",actual_credit:"5",pos_cash:"10",pos_credit:"5",online_delivery:"2",remarks:""}],cash_rows:[{entry_date:"2026-08-12",denominations:{"1":0,"2":0,"5":0,"10":0,"20":0,"50":0,"100":0,"200":0,"500":0},remaining_cash:"0",remarks:""}]};

describe("Sales Tracking PostgREST RPC argument contract",()=>{
 it("uses the exact period-save signature and canonical period value",()=>{
 assert.deepEqual(salesTrackingDraftRpcArgs(actor,branch,3,"middle_shift",payload),{
   actor_user_id:actor,target_branch_id:branch,expected_revision:3,entry_period:"middle_shift",sales_rows:payload.sales_rows,cash_rows:[{entry_date:"2026-08-12",denom_1:0,denom_2:0,denom_5:0,denom_10:0,denom_20:0,denom_50:0,denom_100:0,denom_200:0,denom_500:0,remaining_cash:"0",remarks:""}],
  });
 });
 it("passes provider amount rows without adding provider columns",()=>{
  const providerPayload:SalesTrackingDraftPayload={...payload,sales_rows:[{...payload.sales_rows[0],online_delivery:"150",online_amounts:[{provider_id:"57000000-0000-4000-8000-000000000001",amount:"100"},{provider_id:"57000000-0000-4000-8000-000000000002",amount:"50"}]}]};
  assert.deepEqual(salesTrackingDraftRpcArgs(actor,branch,3,"middle_shift",providerPayload).sales_rows,[{
   entry_date:"2026-08-12",actual_cash:"10",actual_credit:"5",pos_cash:"10",pos_credit:"5",online_delivery:"150",online_amounts:[{provider_id:"57000000-0000-4000-8000-000000000001",amount:"100"},{provider_id:"57000000-0000-4000-8000-000000000002",amount:"50"}],remarks:"",
  }]);
 });
 it("uses the exact daily-submit signature",()=>{
  assert.deepEqual(salesTrackingSubmitRpcArgs(actor,branch,4,key),{
   actor_user_id:actor,target_branch_id:branch,expected_revision:4,idempotency_key:key,
   request_hash:checklistRequestHash({type:"sales_tracking",branch_id:branch,expected_revision:4}),
  });
 });
 it("allows one or two saved periods while preserving submit concurrency and grants",async()=>{
  const migration=await readFile(path.resolve("supabase/migrations/20260901090000_sales_tracking_flexible_daily_submit.sql"),"utf8");
  assert.match(migration,/create or replace function public\.submit_sales_tracking\(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text\)/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/coalesce\(expected_revision,-1\)<>s\.branch_revision/);
  assert.match(migration,/period_count<1 or period_count>2/);
  assert.doesNotMatch(migration,/period_count<>2|count\(\*\)[^;]*<>2/);
  assert.match(migration,/sales_tracking_submission_idempotency/);
  assert.match(migration,/revoke execute on function public\.submit_sales_tracking\(uuid,uuid,bigint,uuid,text\) from public,anon,authenticated/);
  assert.match(migration,/grant execute on function public\.submit_sales_tracking\(uuid,uuid,bigint,uuid,text\) to service_role/);
 });
});
