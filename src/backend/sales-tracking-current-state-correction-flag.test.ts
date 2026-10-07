import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { describe, it } from "node:test";
import { createChecklistPersistence } from "./checklist-persistence";

const actorId="8dfa0345-da1a-4ac6-adac-1e909a59d6fa";
const branchId="dea33e25-4732-4dcf-96db-010ad917c16c";
const reportId="cc10010a-55ad-42e0-a77e-929bcbec6a79";
const caseId="b823e43a-46f2-4d5f-a75a-62b1387a3408";
const attachmentId="ca58f8b0-f3ec-456e-ade0-500704920c81";
const attachmentPath=`${branchId}/${reportId}/${attachmentId}.jpeg`;

function rawCurrent(overrides:Record<string,unknown>={}){
 return {
  report_id:reportId,business_date:"2026-10-07",currency_code:"SAR",state:"draft",revision:0,
  submitted_at:null,submitted_by_user_id:null,submitted_by_name_snapshot:null,
  review_status:"none",review_revision:0,reviewed_at:null,reviewed_by:null,reviewed_by_user_id:null,
  case_id:caseId,version_number:1,supersedes_report_id:null,is_correction_draft:false,
  attachment:null,attachments:[],source_attachments:[],periods:[],sales_rows:[],cash_rows:[],
  totals:{actual_cash:0,actual_credit:0,pos_cash:0,pos_credit:0,online_delivery:0,actual_total:0,gross_sales:0,refund_total:0,net_sales:0,pos_total:0,variance:0,cash_total:0,remaining_cash:0},
  ...overrides,
 };
}

const rawAttachment={
 id:attachmentId,storage_path:attachmentPath,original_filename:"Sales report.jpeg",mime_type:"image/jpeg",
 size_bytes:253393,display_order:1,created_at:"2026-10-07T21:24:47.613432+00:00",
};

async function withSupabase(payload:unknown,signingStatus:number,run:(origin:string,requests:string[])=>Promise<void>){
 const requests:string[]=[];
 const server=createServer((request,response)=>{
  requests.push(request.url??"");
  if(request.url==="/rest/v1/rpc/get_sales_tracking_current_state"){
   response.writeHead(200,{"Content-Type":"application/json"});
   response.end(JSON.stringify(payload));
   return;
  }
  if(request.url?.startsWith("/storage/v1/object/sign/sales-tracking-evidence/")){
   response.writeHead(signingStatus,{"Content-Type":"application/json"});
   response.end(signingStatus===200?JSON.stringify({signedURL:"/object/sign/sales-tracking-evidence/signed-token"}):JSON.stringify({message:"signing unavailable"}));
   return;
  }
  response.writeHead(404,{"Content-Type":"application/json"});
  response.end(JSON.stringify({message:"not found"}));
 });
 await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));
 const origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;
 try{await run(origin,requests);}finally{await new Promise<void>((resolve)=>server.close(()=>resolve()));}
}

describe("Sales Tracking correction flag contract",()=>{
 it("normalizes the only SQL emitter to false while preserving its security boundary",async()=>{
  const [migration,twoArgumentOverload]=await Promise.all([
   readFile(path.resolve("supabase/migrations/20261007160000_sales_tracking_correction_flag_boolean.sql"),"utf8"),
   readFile(path.resolve("supabase/migrations/20261005120000_sales_tracking_refund_optional_photo.sql"),"utf8"),
  ]);
  assert.match(migration,/create or replace function public\.get_sales_tracking_current_state\(actor_user_id uuid,target_branch_id uuid,target_business_date date\)/);
  assert.match(migration,/'is_correction_draft',coalesce\(case_row\.open_correction_report_id=r\.id,false\)/);
  assert.match(migration,/returns jsonb language plpgsql security definer set search_path=''/);
  assert.match(migration,/revoke all on function public\.get_sales_tracking_current_state\(uuid,uuid,date\)from public,anon,authenticated/);
  assert.match(migration,/grant execute on function public\.get_sales_tracking_current_state\(uuid,uuid,date\)to service_role/);
  assert.equal((migration.match(/'is_correction_draft'/g)??[]).length,1);
  assert.match(twoArgumentOverload,/create or replace function public\.get_sales_tracking_current_state\(actor_user_id uuid,target_branch_id uuid\)[\s\S]*?return public\.get_sales_tracking_current_state\(actor_user_id,target_branch_id,c\.business_date\)/);
 });

 it("accepts ordinary, correction, and automatically reviewed current-state variants",async()=>{
  const variants=[
   rawCurrent(),
   rawCurrent({is_correction_draft:true,version_number:2,supersedes_report_id:"eaccbc3c-e226-4171-b2d3-062be1dd6db6"}),
   rawCurrent({state:"submitted",is_correction_draft:false,review_status:"reviewed",review_revision:2,reviewed_at:"2026-10-08T00:00:00+00:00",reviewed_by_user_id:null,reviewed_by:null,submitted_at:"2026-10-08T00:00:00+00:00",submitted_by_user_id:actorId,submitted_by_name_snapshot:"Supervisor"}),
  ];
  for(const variant of variants){
   await withSupabase(variant,200,async(origin)=>{
    const current=await createChecklistPersistence(origin,"test-secret").getSalesTrackingCurrentState?.(actorId,branchId,"2026-10-07") as Record<string,unknown>;
    assert.equal(current.is_correction_draft,variant.is_correction_draft);
    assert.equal(current.reviewed_by_user_id,variant.reviewed_by_user_id);
   });
  }
 });

 it("keeps storage paths internal and does not fail current-state when signing fails",async()=>{
  const payload=rawCurrent({attachment:rawAttachment,attachments:[rawAttachment]});
  for(const signingStatus of [200,500]){
   await withSupabase(payload,signingStatus,async(origin,requests)=>{
    const current=await createChecklistPersistence(origin,"test-secret").getSalesTrackingCurrentState?.(actorId,branchId,"2026-10-07") as {attachment:Record<string,unknown>;attachments:Array<Record<string,unknown>>};
    assert.equal("storage_path" in current.attachment,false);
    assert.equal("storage_path" in current.attachments[0],false);
    assert.equal(current.attachment.signed_url,signingStatus===200?`${origin}/storage/v1/object/sign/sales-tracking-evidence/signed-token`:null);
    assert.ok(requests.some((url)=>url.startsWith(`/storage/v1/object/sign/sales-tracking-evidence/${attachmentPath}`)));
   });
  }
 });

 it("continues rejecting malformed required identifiers",async()=>{
  await withSupabase(rawCurrent({report_id:"not-a-uuid"}),200,async(origin)=>{
   await assert.rejects(()=>createChecklistPersistence(origin,"test-secret").getSalesTrackingCurrentState!(actorId,branchId,"2026-10-07"));
  });
 });
});
