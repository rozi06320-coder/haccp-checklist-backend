import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { ChecklistAccessError, ChecklistConflictError, ChecklistInputError } from "./checklist-persistence";
import { OperationalAccessError, OperationalConflictError } from "./operational";

const supervisor="15000000-0000-4000-8000-000000000001",manager="15000000-0000-4000-8000-000000000002",internalAdmin="15000000-0000-4000-8000-000000000003",maintenance="15000000-0000-4000-8000-000000000004";
const branch="25000000-0000-4000-8000-000000000001",otherBranch="25000000-0000-4000-8000-000000000002",org="35000000-0000-4000-8000-000000000001";
const masterEquipmentId="45000000-0000-4000-8000-000000000001",secondMasterEquipmentId="45000000-0000-4000-8000-000000000002";
const calls:Array<{name:string;input:unknown}>=[];
let currentEquipment:unknown[]=[];
let currentReadings:unknown[]=[];
type MasterEquipment={id:string;branch_id:string;name:string;equipment_type:"refrigerator"|"freezer";active:boolean;updated_at:string};
let masterEquipment:MasterEquipment[]=[];
const replay=new Map<string,string>();
const current=()=>({business_date:"2026-08-01",state:"draft",equipment:currentEquipment,readings:currentReadings});
const digest=(value:unknown)=>createHash("sha256").update(JSON.stringify(value)).digest("hex");
const hasMissingCorrection=(input:{equipment:unknown[];readings:unknown[];slot:string})=>{
  const active=new Set(input.equipment.filter((row)=>Boolean((row as {active?:boolean}).active)).map((row)=>(row as {equipment_id:string}).equipment_id));
  return input.readings.some((row)=>active.has((row as {equipment_id:string}).equipment_id)
    && (row as {slot:string}).slot===input.slot
    && Number((row as {temperature_c:unknown}).temperature_c)>=5
    && !(row as {corrective_action:string}).corrective_action.trim());
};
const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){throw new Error("unused");},
 async getCurrentState(){throw new Error("unused");},async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},
 async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async getOilTrackingCurrentState(){throw new Error("unused");},async saveOilTrackingDraft(){throw new Error("unused");},async submitOilTrackingOpening(){throw new Error("unused");},async submitOilTrackingClosing(){throw new Error("unused");},
 async listSupervisor(){throw new Error("unused");},async getReport(){throw new Error("unused");},async listManagedReports(){throw new Error("unused");},async listManagedIssues(){throw new Error("unused");},async getManagedIssue(){throw new Error("unused");},
 async getColdStorageCurrentState(actorUserId:string,branchId:string){calls.push({name:"cold-current",input:{actorUserId,branchId}});if(branchId!==branch)throw new ChecklistAccessError();return current();},
 async saveColdStorageDraft(input:{actorUserId:string;branchId:string;equipment:unknown[];readings:unknown[]}){calls.push({name:"cold-draft",input});if(input.branchId!==branch)throw new ChecklistAccessError();currentEquipment=input.equipment;currentReadings=input.readings;return current();},
 async submitColdStorageSlot(input:{actorUserId:string;branchId:string;slot:string;idempotencyKey:string;equipment:unknown[];readings:unknown[]}){calls.push({name:"cold-submit",input});if(input.branchId!==branch)throw new ChecklistAccessError();if(hasMissingCorrection(input))throw new ChecklistInputError();const key=`${input.slot}:${input.idempotencyKey}`,hash=digest({slot:input.slot,equipment:input.equipment,readings:input.readings});const existing=replay.get(key);if(existing&&existing!==hash)throw new ChecklistConflictError();replay.set(key,hash);currentEquipment=input.equipment;currentReadings=input.readings.map((row)=>({...(row as Record<string,unknown>),...((row as {slot:string}).slot===input.slot?{submitted_at:"2026-08-01T12:15:00.000Z"}:{})}));return{...current(),issue_count:currentReadings.filter((row)=>Number((row as {temperature_c:unknown}).temperature_c)>=5).length};},
};
const operationalAdmin={
 async listSupervisorColdStorageEquipment(actorUserId:string,branchId:string){calls.push({name:"master-list",input:{actorUserId,branchId}});if(actorUserId!==supervisor||branchId!==branch)throw new OperationalAccessError();return{equipment:masterEquipment};},
 async createSupervisorColdStorageEquipment(input:{actorUserId:string;branchId:string;name:string;equipmentType:"refrigerator"|"freezer"}){calls.push({name:"master-create",input});if(input.actorUserId!==supervisor||input.branchId!==branch)throw new OperationalAccessError();if(input.name==="Unavailable Unit")throw new Error("database unavailable");if(masterEquipment.some(row=>row.active&&row.name.toLowerCase()===input.name.toLowerCase()))throw new OperationalConflictError();const row:MasterEquipment={id:secondMasterEquipmentId,branch_id:branch,name:input.name,equipment_type:input.equipmentType,active:true,updated_at:"2026-08-11T12:30:00.000Z"};masterEquipment.push(row);return{equipment:row};},
 async renameSupervisorColdStorageEquipment(input:{actorUserId:string;branchId:string;equipmentId:string;name:string}){calls.push({name:"master-rename",input});if(input.actorUserId!==supervisor||input.branchId!==branch)throw new OperationalAccessError();const row=masterEquipment.find(item=>item.id===input.equipmentId);if(!row)throw new OperationalAccessError();if(masterEquipment.some(item=>item.id!==row.id&&item.active&&item.name.toLowerCase()===input.name.toLowerCase()))throw new OperationalConflictError();row.name=input.name;row.updated_at="2026-08-11T13:00:00.000Z";return{equipment:row};},
} as BackendDependencies["operationalAdmin"];
function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,operationalAdmin,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:supervisor}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="supervisor"?{userId:supervisor,email:"s@example.invalid"}:token==="manager"?{userId:manager,email:"m@example.invalid"}:token==="internal"?{userId:internalAdmin,email:"i@example.invalid"}:token==="maintenance"?{userId:maintenance,email:"x@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="supervisor"?{id:supervisor,full_name:"S",must_change_password:false,disabled:false,branches:[{id:branch,name:"A",organization_id:org,role:"branch_manager"}],managed_organizations:[]}:token==="manager"?{id:manager,full_name:"M",must_change_password:false,disabled:false,branches:[],managed_organizations:[{id:org,name:"O",role:"organization_manager"}]}:{id:token==="internal"?internalAdmin:maintenance,full_name:"Other",must_change_password:false,disabled:false,branches:[],managed_organizations:[]},isInternalAdmin:async()=>token==="internal",hasOrganizationManagerAccess:async()=>token==="manager",validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token?:string,init:RequestInit={}){return fetch(origin+path,{...init,headers:{...(token?{Authorization:`Bearer ${token}`}:{"x-no-auth":"1"}),...(init.headers??{})}});}
const equipment=[{equipmentId:"ref-1",equipmentName:"Line Refrigerator",equipmentType:"refrigerator",active:true},{equipmentId:"freezer-1",equipmentName:"Walk-in Freezer",equipmentType:"freezer",active:false}];
const reading={equipmentId:"ref-1",slot:"12",temperatureC:"4.9",status:"pass",correctiveAction:""};

describe("Cold Storage API integration",()=>{
 before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address()as AddressInfo).port}`;});
 after(()=>new Promise<void>(resolve=>server.close(()=>resolve())));
 beforeEach(()=>{calls.length=0;currentEquipment=[];currentReadings=[];replay.clear();masterEquipment=[{id:masterEquipmentId,branch_id:branch,name:"Walk-in Freezer",equipment_type:"freezer",active:true,updated_at:"2026-08-11T12:00:00.000Z"}];});

 it("registers Supervisor equipment master routes and denies other roles",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/cold-storage/equipment`;
  assert.equal((await request(path)).status,401);
  for(const token of ["manager","internal","maintenance"]){
   assert.equal((await request(path,token)).status,403);
   assert.equal((await request(path,token,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"Unit",equipment_type:"freezer"})})).status,403);
  }
 });
 it("lists safe active master equipment for the assigned Supervisor",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/cold-storage/equipment`,"supervisor");
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{equipment:masterEquipment});
  assert.deepEqual(calls.at(-1),{name:"master-list",input:{actorUserId:supervisor,branchId:branch}});
  assert.doesNotMatch(JSON.stringify(masterEquipment),/organization_id|created_by|updated_by/);
 });
 it("creates normalized equipment without accepting organization or creator authority",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/cold-storage/equipment`;
  const response=await request(path,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"  Reach-in   Refrigerator  ",equipment_type:"refrigerator"})});
  assert.equal(response.status,201);
  assert.deepEqual(calls.at(-1),{name:"master-create",input:{actorUserId:supervisor,branchId:branch,name:"Reach-in Refrigerator",equipmentType:"refrigerator"}});
  assert.doesNotMatch(JSON.stringify(await response.json()),/organization_id|created_by|updated_by/);
  for(const body of [
   {name:"",equipment_type:"freezer"},
   {name:"Unit",equipment_type:"warmer"},
   {name:"Unit",equipment_type:"freezer",organization_id:org},
   {name:"Unit",equipment_type:"freezer",created_by:manager},
  ])assert.equal((await request(path,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})).status,400);
 });
 it("maps duplicate names to 409 and unexpected failures to safe 503",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/cold-storage/equipment`;
  const duplicate=await request(path,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"walk-in freezer",equipment_type:"freezer"})});
  assert.equal(duplicate.status,409);
  const unavailable=await request(path,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"Unavailable Unit",equipment_type:"freezer"})});
  assert.equal(unavailable.status,503);
  assert.doesNotMatch(JSON.stringify(await unavailable.json()),/database unavailable|Supabase/i);
 });
 it("renames equipment safely and rejects invalid or conflicting requests",async()=>{
  masterEquipment.push({id:secondMasterEquipmentId,branch_id:branch,name:"Reach-in Refrigerator",equipment_type:"refrigerator",active:true,updated_at:"2026-08-11T12:30:00.000Z"});
  const path=`/api/v1/supervisor/branches/${branch}/cold-storage/equipment/${masterEquipmentId}`;
  const renamed=await request(path,"supervisor",{method:"PATCH",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"  Main   Walk-in Freezer  "})});
  assert.equal(renamed.status,200);
  assert.deepEqual(calls.at(-1),{name:"master-rename",input:{actorUserId:supervisor,branchId:branch,equipmentId:masterEquipmentId,name:"Main Walk-in Freezer"}});
  assert.doesNotMatch(JSON.stringify(await renamed.json()),/organization_id|created_by|updated_by/);
  assert.equal((await request(path,"supervisor",{method:"PATCH",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"Reach-in Refrigerator"})})).status,409);
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/cold-storage/equipment/not-a-uuid`,"supervisor",{method:"PATCH",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"Unit"})})).status,400);
  assert.equal((await request(path,"supervisor",{method:"PATCH",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"Unit",updated_by:supervisor})})).status,400);
  assert.equal((await request(`/api/v1/supervisor/branches/${otherBranch}/cold-storage/equipment`,"supervisor")).status,403);
 });

 it("requires authentication and forbids Manager authority",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/current-state`;
  assert.equal((await request(path)).status,401);
  assert.equal((await request(path,"manager")).status,403);
 });
 it("returns empty current state for a Supervisor",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/current-state`,"supervisor");
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{current:{business_date:"2026-08-01",revision:0,state:"draft",equipment:[],readings:[]}});
 });
 it("saves and restores a normalized draft",async()=>{
  const save=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({equipment,readings:[reading]})});
  assert.equal(save.status,200);
  const input=calls.at(-1)?.input as {equipment:Array<Record<string,unknown>>;readings:Array<Record<string,unknown>>};
  assert.equal(input.equipment[0].equipment_id,"ref-1");
  assert.equal(input.equipment[0].equipment_type,"refrigerator");
  assert.equal(input.readings[0].slot,"12:00");
  assert.equal(input.readings[0].temperature_c,"4.9");
  const restored=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/current-state`,"supervisor");
  assert.equal((await restored.json()).current.equipment[0].equipment_id,"ref-1");
 });
 it("requires idempotency key for submit",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/slots/12/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({equipment,readings:[reading]})});
  assert.equal(response.status,400);
 });
 it("rejects invalid slots and invalid payloads",async()=>{
  const headers={"Content-Type":"application/json","Idempotency-Key":"65000000-0000-4000-8000-000000000001"};
  for(const removed of ["3","8"]){
   const removedReading={...reading,slot:removed};
   assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/slots/${removed}/submit`,"supervisor",{method:"POST",headers,body:JSON.stringify({equipment,readings:[removedReading]})})).status,400);
  }
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({equipment:[{...equipment[0],equipmentType:"warmer"}],readings:[reading]})})).status,400);
 });
 it("accepts the 20:00 and 02:00 canonical slots",async()=>{
  for(const [routeSlot,payloadSlot,key] of [["20","20","65000000-0000-4000-8000-000000000020"],["02","02","65000000-0000-4000-8000-000000000002"]] as const){
   const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/slots/${routeSlot}/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":key},body:JSON.stringify({equipment,readings:[{...reading,slot:payloadSlot}]})});
   assert.equal(response.status,201);
   assert.equal((await response.json()).current.readings[0].slot,`${payloadSlot}:00`);
  }
 });
 it("maps 5C without corrective action to a safe validation error",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/slots/12/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"65000000-0000-4000-8000-000000000002"},body:JSON.stringify({equipment,readings:[{...reading,temperatureC:5,status:"fail",correctiveAction:""}]})});
  assert.equal(response.status,422);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|cold-submit/i);
 });
 it("accepts 4.9C without issue",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/slots/12/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"65000000-0000-4000-8000-000000000003"},body:JSON.stringify({equipment,readings:[reading]})});
  assert.equal(response.status,201);
  const body=await response.json();
  assert.equal(body.current.issue_count,0);
  assert.equal(body.current.readings[0].slot,"12:00");
  assert.equal(body.current.readings[0].submitted_at,"2026-08-01T12:15:00.000Z");
  const restored=await request(`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/current-state`,"supervisor");
  const current=await restored.json();
  assert.equal(current.current.readings[0].submitted_at,"2026-08-01T12:15:00.000Z");
 });
 it("accepts same-key same-body replay and rejects changed-body replay",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/cold_storage/slots/12/submit`;
  const headers={"Content-Type":"application/json","Idempotency-Key":"65000000-0000-4000-8000-000000000004"};
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({equipment,readings:[reading]})})).status,201);
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({equipment,readings:[reading]})})).status,201);
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({equipment,readings:[{...reading,temperatureC:4.8}]})})).status,409);
 });
 it("maps forbidden other branch or team access to safe 403",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${otherBranch}/checklists/cold_storage/current-state`,"supervisor");
  assert.equal(response.status,403);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|cold-current/i);
 });
});
