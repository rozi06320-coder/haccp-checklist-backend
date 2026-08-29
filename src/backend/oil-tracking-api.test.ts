import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { ChecklistAccessError, ChecklistConflictError } from "./checklist-persistence";

const supervisor="12000000-0000-4000-8000-000000000001",manager="12000000-0000-4000-8000-000000000002";
const branch="22000000-0000-4000-8000-000000000001",otherBranch="22000000-0000-4000-8000-000000000002",org="32000000-0000-4000-8000-000000000001";
const calls:Array<{name:string;input:unknown}>=[];
let currentRows:unknown[]=[];
const replay=new Map<string,string>();
const current=()=>({business_date:"2026-08-01",opening_submitted:false,closing_submitted:false,opening_submitted_at:null,closing_submitted_at:null,rows:currentRows});
const digest=(value:unknown)=>createHash("sha256").update(JSON.stringify(value)).digest("hex");
const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){throw new Error("unused");},
 async getCurrentState(){throw new Error("unused");},async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},
 async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async listSupervisor(){throw new Error("unused");},async getReport(){throw new Error("unused");},async listManagedReports(){throw new Error("unused");},async listManagedIssues(){throw new Error("unused");},async getManagedIssue(){throw new Error("unused");},
 async getOilTrackingCurrentState(actorUserId:string,branchId:string){calls.push({name:"oil-current",input:{actorUserId,branchId}});if(branchId!==branch)throw new ChecklistAccessError();return current();},
 async saveOilTrackingDraft(input:{actorUserId:string;branchId:string;expectedRevision:number;rows:unknown[]}){calls.push({name:"oil-draft",input});if(input.branchId!==branch)throw new ChecklistAccessError();if(input.expectedRevision===99)throw new ChecklistConflictError("40001");currentRows=input.rows;return current();},
 async submitOilTrackingOpening(input:{actorUserId:string;branchId:string;idempotencyKey:string;rows:unknown[]}){calls.push({name:"oil-opening",input});if(input.branchId!==branch)throw new ChecklistAccessError();const key=`opening:${input.idempotencyKey}`,hash=digest(input.rows);const existing=replay.get(key);if(existing&&existing!==hash)throw new ChecklistConflictError();replay.set(key,hash);currentRows=input.rows;return{...current(),opening_submitted:true,issue_count:0};},
 async submitOilTrackingClosing(input:{actorUserId:string;branchId:string;idempotencyKey:string;rows:unknown[]}){calls.push({name:"oil-closing",input});if(input.branchId!==branch)throw new ChecklistAccessError();const key=`closing:${input.idempotencyKey}`,hash=digest(input.rows);const existing=replay.get(key);if(existing&&existing!==hash)throw new ChecklistConflictError();replay.set(key,hash);currentRows=input.rows;return{...current(),closing_submitted:true,issue_count:0};},
};
function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:supervisor}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="supervisor"?{userId:supervisor,email:"s@example.invalid"}:token==="manager"?{userId:manager,email:"m@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="supervisor"?{id:supervisor,full_name:"S",must_change_password:false,disabled:false,branches:[{id:branch,name:"A",organization_id:org,role:"branch_manager"}],managed_organizations:[]}:{id:manager,full_name:"M",must_change_password:false,disabled:false,branches:[],managed_organizations:[{id:org,name:"O",role:"organization_manager"}]},hasOrganizationManagerAccess:async()=>token==="manager",validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token?:string,init:RequestInit={}){return fetch(origin+path,{...init,headers:{...(token?{Authorization:`Bearer ${token}`}:{"x-no-auth":"1"}),...(init.headers??{})}});}
const row={id:"fryer-1",label:"Fryer 1",shortLabel:"F1",inUseToday:true,oilStatus:"new-oil",temperature:"175.5",openingStatus:"pass",openingNote:"",closingTpm:"20.9",closingNote:""};

describe("Oil Tracking API integration",()=>{
 before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address()as AddressInfo).port}`;});
 after(()=>new Promise<void>(resolve=>server.close(()=>resolve())));
 beforeEach(()=>{calls.length=0;currentRows=[];replay.clear();});

 it("requires authentication and forbids Manager authority",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/current-state`;
  assert.equal((await request(path)).status,401);
  assert.equal((await request(path,"manager")).status,403);
 });
 it("returns empty current state for a Supervisor",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/current-state`,"supervisor");
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{current:{business_date:"2026-08-01",revision:0,opening_submitted:false,closing_submitted:false,opening_submitted_at:null,closing_submitted_at:null,rows:[]}});
 });
 it("saves and restores a normalized draft",async()=>{
  const save=await request(`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({rows:[row]})});
  assert.equal(save.status,200);
  const input=calls.at(-1)?.input as {rows:Array<Record<string,unknown>>};
  assert.equal(input.rows[0].fryer_id,"fryer-1");
  assert.equal(input.rows[0].oil_status,"new_oil");
  assert.equal(input.rows[0].opening_temperature_c,"175.5");
  assert.equal(input.rows[0].closing_tpm_percent,"20.9");
  const restored=await request(`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/current-state`,"supervisor");
  assert.equal((await restored.json()).current.rows[0].fryer_id,"fryer-1");
 });
 it("logs safe Oil Tracking draft correlation diagnostics on conflict",async()=>{
  const correlationId="62000000-0000-4000-8000-000000000099";
  const records:unknown[][]=[];
  const originalInfo=console.info;
  console.info=(...args:unknown[])=>{records.push(args);};
  try{
   const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json","X-Oil-Tracking-Correlation-Id":correlationId,"User-Agent":"oil-test-agent","Origin":"https://app.example.test","Referer":"https://app.example.test/branch-manager"},body:JSON.stringify({expected_revision:99,rows:[{...row,openingNote:"secret note",closingNote:"secret closing note"}]})});
   assert.equal(response.status,409);
   const body=await response.json();
   const backendRequestId=body.error.requestId;
   assert.equal(response.headers.get("x-request-id"),backendRequestId);
  }finally{console.info=originalInfo;}
  assert.equal(calls.filter(call=>call.name==="oil-draft").length,1);
  const serialized=JSON.stringify(records);
  assert.match(serialized,/OIL_TRACKING_CORRELATION/);
  assert.match(serialized,/request_received/);
  assert.match(serialized,/auth_ok/);
  assert.match(serialized,/rpc_invocation/);
  assert.match(serialized,/route_error/);
  assert.match(serialized,new RegExp(correlationId));
  assert.match(serialized,/"expectedRevision":99/);
  assert.match(serialized,/"sqlstate":"40001"/);
  assert.match(serialized,/oil-test-agent/);
  assert.doesNotMatch(serialized,/secret note|secret closing note|175\.5|20\.9|Bearer|supervisor/);
 });
 it("requires idempotency keys for submit routes",async()=>{
  for(const section of ["opening","closing"])assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/${section}/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({rows:[row]})})).status,400);
 });
 it("rejects invalid payloads",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({rows:[{...row,oilStatus:"bad"}]})});
  assert.equal(response.status,400);
 });
 it("accepts same-key same-body replay and rejects changed-body replay",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/opening/submit`;
  const headers={"Content-Type":"application/json","Idempotency-Key":"62000000-0000-4000-8000-000000000001"};
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({rows:[row]})})).status,201);
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({rows:[row]})})).status,201);
  const changed={...row,openingTemperatureC:"180"};
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({rows:[changed]})})).status,409);
 });
 it("requires idempotency for closing and submits with normalized rows",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/oil_tracking/closing/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"62000000-0000-4000-8000-000000000002"},body:JSON.stringify({rows:[row]})});
  assert.equal(response.status,201);
  assert.equal(calls.at(-1)?.name,"oil-closing");
 });
 it("maps forbidden other branch or team access to safe 403",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${otherBranch}/checklists/oil_tracking/current-state`,"supervisor");
  assert.equal(response.status,403);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|oil-current/i);
 });
});
