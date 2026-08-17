import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { ChecklistAccessError } from "./checklist-persistence";

const supervisor="15000000-0000-4000-8000-000000000001",manager="15000000-0000-4000-8000-000000000002";
const branch="25000000-0000-4000-8000-000000000001",org="35000000-0000-4000-8000-000000000001";
const kitchenReportId="55000000-0000-4000-8000-000000000001";
const oilReportId="65000000-0000-4000-8000-000000000001";
const coldReportId="75000000-0000-4000-8000-000000000001";
const calls:Array<{name:string;input:unknown}>=[];
const kitchenReport={id:kitchenReportId,branch_id:branch,checklist_type:"kitchen_opening",business_date:"2026-08-01",submitted_at:"2026-08-01T07:30:00Z",submitted_by:"Supervisor",completion:100,issue_count:0,status:"compliant"};
const oilReport={id:oilReportId,branch_id:branch,checklist_type:"oil_tracking",business_date:"2026-08-02",submitted_at:"2026-08-02T20:00:00Z",submitted_by:"Supervisor",completion:100,issue_count:0,status:"compliant"};
const coldReport={id:coldReportId,branch_id:branch,checklist_type:"cold_storage",business_date:"2026-08-03",submitted_at:"2026-08-03T12:15:00Z",submitted_by:"Supervisor",completion:33,issue_count:1,status:"issues_found",submitted_slots:["12:00"],missed_check_count:1,missed_slots:["20:00"]};
let baseReports=[kitchenReport];
let oilReports=[oilReport];
let coldReports=[coldReport];
let coldListMode:"ok"|"failure"="ok";
const coldDetail={id:coldReportId,branch_id:branch,branch_name:"A",business_date:"2026-08-03",checklist_type:"cold_storage",definition_id:"cold_storage_v1",submitted_at:"2026-08-03T12:15:00Z",submitted_by:"Supervisor",completion:33,issue_count:1,status:"issues_found",submitted_slots:["12:00"],missed_check_count:1,missed_slots:["20:00"],rows:[
  {equipment_id:"ref-1",equipment_name:"Line Refrigerator",equipment_type:"refrigerator",active:true,slot:"12:00",temperature_c:5,status:"fail",corrective_action:"Adjusted thermostat",submitted_at:"2026-08-03T12:15:00Z"},
  {equipment_id:"freezer-1",equipment_name:"Walk-in Freezer",equipment_type:"freezer",active:true,slot:"12:00",temperature_c:4.9,status:"pass",corrective_action:"",submitted_at:"2026-08-03T12:15:00Z"},
],issues:[{id:"85000000-0000-4000-8000-000000000001",equipment_id:"ref-1",equipment_name:"Line Refrigerator",slot:"12:00",temperature_c:5,title:"Cold Storage temperature issue",remark:"Adjusted thermostat"}]};
const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){throw new Error("unused");},async getCurrentState(){throw new Error("unused");},
 async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async getOilTrackingCurrentState(){throw new Error("unused");},async saveOilTrackingDraft(){throw new Error("unused");},async submitOilTrackingOpening(){throw new Error("unused");},async submitOilTrackingClosing(){throw new Error("unused");},
 async getColdStorageCurrentState(){throw new Error("unused");},async saveColdStorageDraft(){throw new Error("unused");},async submitColdStorageSlot(){throw new Error("unused");},
 async listSupervisor(input:{type?:string;pageSize:number}){calls.push({name:"history",input});const all=coldListMode==="failure"?[...oilReports,...baseReports]:[...coldReports,...oilReports,...baseReports];const reports=input.type?all.filter((row)=>row.checklist_type===input.type):all;return{reports,page:1,page_size:input.pageSize,total:reports.length};},
 async listOilTrackingSupervisor(input:{page:number;pageSize:number}){calls.push({name:"oil-history",input});return{reports:oilReports,page:input.page,page_size:input.pageSize,total:oilReports.length};},
 async listColdStorageSupervisor(input:{page:number;pageSize:number}){calls.push({name:"cold-history",input});if(coldListMode==="failure")throw new Error("Checklist persistence unavailable.");return{reports:coldReports,page:input.page,page_size:input.pageSize,total:coldReports.length};},
 async getReport(_actor:string,id:string){calls.push({name:"detail",input:id});if(id!==kitchenReportId)throw new ChecklistAccessError();return{id,branch_id:branch,branch_name:"A",business_date:"2026-08-01",checklist_type:"kitchen_opening",definition_id:"kitchen_opening_v1",submitted_at:"2026-08-01T07:30:00Z",submitted_by:"Supervisor",completion:100,issue_count:0,status:"compliant",items:[],staff:[]};},
 async getOilTrackingReport(_actor:string,id:string){calls.push({name:"oil-detail",input:id});if(id!==oilReportId)throw new ChecklistAccessError();return{id,branch_id:branch,branch_name:"A",business_date:"2026-08-02",checklist_type:"oil_tracking",definition_id:"oil_tracking_v1",submitted_at:"2026-08-02T20:00:00Z",submitted_by:"Supervisor",completion:100,issue_count:0,status:"compliant",opening_submitted_at:"2026-08-02T08:00:00Z",closing_submitted_at:"2026-08-02T20:00:00Z",rows:[],issues:[]};},
 async getColdStorageReport(_actor:string,id:string){calls.push({name:"cold-detail",input:id});if(id!==coldReportId)throw new ChecklistAccessError();return coldDetail;},
 async listManagedReports(){throw new Error("unused");},async listManagedIssues(){throw new Error("unused");},async getManagedIssue(){throw new Error("unused");},
};
function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:supervisor}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="supervisor"?{userId:supervisor,email:"s@example.invalid"}:token==="manager"?{userId:manager,email:"m@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="supervisor"?{id:supervisor,full_name:"S",must_change_password:false,disabled:false,branches:[{id:branch,name:"A",organization_id:org,role:"branch_manager"}],managed_organizations:[]}:{id:manager,full_name:"M",must_change_password:false,disabled:false,branches:[],managed_organizations:[{id:org,name:"O",role:"organization_manager"}]},hasOrganizationManagerAccess:async()=>token==="manager",validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token="supervisor"){return fetch(origin+path,{headers:{Authorization:`Bearer ${token}`}});}

describe("Cold Storage supervisor reports API",()=>{
 before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
 after(()=>new Promise<void>((resolve)=>server.close(()=>resolve())));
 beforeEach(()=>{calls.length=0;baseReports=[kitchenReport];oilReports=[oilReport];coldReports=[coldReport];coldListMode="ok";});

 it("keeps all-checklist history available when Cold Storage merge is temporarily unavailable",async()=>{
  coldListMode="failure";
  const response=await request(`/api/v1/supervisor/branches/${branch}/submissions?page=1&page_size=20`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.deepEqual(body.reports.map((row:{checklist_type:string})=>row.checklist_type),["oil_tracking","kitchen_opening"]);
  assert.equal(body.total,2);
 });

 it("merges Cold Storage into Submission History without breaking existing reports",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/submissions?page=1&page_size=20`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.total,3);
  assert.deepEqual(body.reports.map((row:{checklist_type:string})=>row.checklist_type),["cold_storage","oil_tracking","kitchen_opening"]);
  assert.equal(body.reports[0].status,"issues_found");
  assert.equal(body.reports[0].completion,33);
  assert.equal(body.reports[0].missed_check_count,1);
  assert.deepEqual(body.reports[0].missed_slots,["20:00"]);
  assert.deepEqual(body.reports[0].submitted_slots,["12:00"]);
 });

 it("supports Cold Storage history filtering",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=cold_storage`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.total,1);
  assert.ok(body.reports.every((row:{checklist_type:string})=>row.checklist_type==="cold_storage"));
  assert.equal(calls.at(-1)?.name,"history");
 });

 it("keeps the existing four report type filters working",async()=>{
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=kitchen_opening`)).status,200);
  assert.equal(calls.at(-1)?.name,"history");
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=foh_opening`)).status,200);
  assert.equal(calls.at(-1)?.name,"history");
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=staff_hygiene`)).status,200);
  assert.equal(calls.at(-1)?.name,"history");
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=oil_tracking`)).status,200);
  assert.equal(calls.at(-1)?.name,"history");
 });

 it("returns Cold Storage detail rows and synthesized visible items",async()=>{
  const response=await request(`/api/v1/supervisor/submissions/${coldReportId}`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.checklist_type,"cold_storage");
  assert.equal(body.rows[0].equipment_name,"Line Refrigerator");
  assert.equal(body.rows[0].temperature_c,5);
  assert.equal(body.issues[0].equipment_id,"ref-1");
  assert.equal(body.missed_check_count,1);
  assert.deepEqual(body.missed_slots,["20:00"]);
  assert.match(body.items[0].item_text,/Line Refrigerator.*12:00.*5C/);
  assert.equal(body.items[0].remark,"Adjusted thermostat");
 });
});
