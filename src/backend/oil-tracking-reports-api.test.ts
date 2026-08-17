import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { ChecklistAccessError } from "./checklist-persistence";

const supervisor="14000000-0000-4000-8000-000000000001",manager="14000000-0000-4000-8000-000000000002";
const branch="24000000-0000-4000-8000-000000000001",org="34000000-0000-4000-8000-000000000001";
const kitchenReportId="54000000-0000-4000-8000-000000000001";
const oilOpeningOnlyId="64000000-0000-4000-8000-000000000001";
const oilCompleteId="64000000-0000-4000-8000-000000000002";
const calls:Array<{name:string;input:unknown}>=[];
const kitchenReport={id:kitchenReportId,branch_id:branch,checklist_type:"kitchen_opening",business_date:"2026-08-01",submitted_at:"2026-08-01T07:30:00Z",submitted_by:"Supervisor",completion:100,issue_count:0,status:"compliant"};
const baseList={reports:[kitchenReport],page:1,page_size:20,total:1};
const emptyBaseList={reports:[],page:1,page_size:20,total:0};
const oilReportsFixture=[
  {id:oilCompleteId,branch_id:branch,checklist_type:"oil_tracking",business_date:"2026-08-02",submitted_at:"2026-08-02T20:00:00Z",submitted_by:"Supervisor",completion:100,issue_count:1,status:"issues_found"},
  {id:oilOpeningOnlyId,branch_id:branch,checklist_type:"oil_tracking",business_date:"2026-08-01",submitted_at:"2026-08-01T08:00:00Z",submitted_by:"Supervisor",completion:50,issue_count:0,status:"in_progress"},
];
let baseReports=baseList.reports;
let oilReports=oilReportsFixture;
let oilListMode:"ok"|"failure"="ok";
const oilDetail={id:oilCompleteId,branch_id:branch,branch_name:"A",business_date:"2026-08-02",checklist_type:"oil_tracking",definition_id:"oil_tracking_v1",submitted_at:"2026-08-02T20:00:00Z",submitted_by:"Supervisor",completion:100,issue_count:1,status:"issues_found",opening_submitted_at:"2026-08-02T08:00:00Z",closing_submitted_at:"2026-08-02T20:00:00Z",rows:[
  {fryer_id:"fryer-1",fryer_label:"Fryer 1",fryer_short_label:"F1",in_use_today:true,oil_status:"new_oil",opening_temperature_c:175,opening_status:"pass",opening_note:"",closing_tpm_percent:21,closing_note:"Filter before rush",tpm_classification:"nearing_end"},
  {fryer_id:"fryer-2",fryer_label:"Fryer 2",fryer_short_label:"F2",in_use_today:false,oil_status:"pending",opening_temperature_c:null,opening_status:"pending",opening_note:"",closing_tpm_percent:25,closing_note:"Inactive fryer",tpm_classification:"change_discard"},
],issues:[{id:"74000000-0000-4000-8000-000000000001",section:"closing",fryer_id:"fryer-1",fryer_label:"Fryer 1",title:"Closing TPM nearing oil end of life",remark:"Filter before rush",tpm_status:"nearing_end"}]};
const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){throw new Error("unused");},async getCurrentState(){throw new Error("unused");},
 async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async getOilTrackingCurrentState(){throw new Error("unused");},async saveOilTrackingDraft(){throw new Error("unused");},async submitOilTrackingOpening(){throw new Error("unused");},async submitOilTrackingClosing(){throw new Error("unused");},
 async listSupervisor(input:{type?:string;pageSize:number}){calls.push({name:"history",input});if(oilListMode==="failure")return{reports:baseReports,page:1,page_size:input.pageSize,total:baseReports.length};const all=[...oilReports,...baseReports];const reports=input.type?all.filter((row)=>row.checklist_type===input.type):all;return{reports,page:1,page_size:input.pageSize,total:reports.length};},
 async listOilTrackingSupervisor(input:{page:number;pageSize:number}){calls.push({name:"oil-history",input});if(oilListMode==="failure")throw new Error("Checklist persistence unavailable.");return{reports:oilReports,page:input.page,page_size:input.pageSize,total:oilReports.length};},
 async getReport(_actor:string,id:string){calls.push({name:"detail",input:id});if(id!==kitchenReportId)throw new ChecklistAccessError();return{id,branch_id:branch,branch_name:"A",business_date:"2026-08-01",checklist_type:"kitchen_opening",definition_id:"kitchen_opening_v1",submitted_at:"2026-08-01T07:30:00Z",submitted_by:"Supervisor",completion:100,issue_count:0,status:"compliant",items:[],staff:[]};},
 async getOilTrackingReport(_actor:string,id:string){calls.push({name:"oil-detail",input:id});if(id!==oilCompleteId)throw new ChecklistAccessError();return oilDetail;},
 async listManagedReports(){throw new Error("unused");},async listManagedIssues(){throw new Error("unused");},async getManagedIssue(){throw new Error("unused");},
};
function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:supervisor}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="supervisor"?{userId:supervisor,email:"s@example.invalid"}:token==="manager"?{userId:manager,email:"m@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="supervisor"?{id:supervisor,full_name:"S",must_change_password:false,disabled:false,branches:[{id:branch,name:"A",organization_id:org,role:"branch_manager"}],managed_organizations:[]}:{id:manager,full_name:"M",must_change_password:false,disabled:false,branches:[],managed_organizations:[{id:org,name:"O",role:"organization_manager"}]},hasOrganizationManagerAccess:async()=>token==="manager",validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token="supervisor"){return fetch(origin+path,{headers:{Authorization:`Bearer ${token}`}});}

describe("Oil Tracking supervisor reports API",()=>{
 before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
  after(()=>new Promise<void>((resolve)=>server.close(()=>resolve())));

 beforeEach(()=>{calls.length=0;baseReports=baseList.reports;oilReports=oilReportsFixture;oilListMode="ok";});

 it("returns an available empty Submission History when no submitted rows exist",async()=>{
  baseReports=emptyBaseList.reports;oilReports=[];
  const response=await request(`/api/v1/supervisor/branches/${branch}/submissions?page=1&page_size=20`);
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{reports:[],page:1,page_size:20,total:0});
 });

 it("keeps all-checklist history available when the optional Oil merge is temporarily unavailable",async()=>{
  oilListMode="failure";
  const response=await request(`/api/v1/supervisor/branches/${branch}/submissions?page=1&page_size=20`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.deepEqual(body.reports.map((row:{checklist_type:string})=>row.checklist_type),["kitchen_opening"]);
  assert.equal(body.total,1);
 });

 it("merges Oil Tracking into Submission History without breaking existing reports",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/submissions?page=1&page_size=20`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.total,3);
  assert.deepEqual(body.reports.map((row:{checklist_type:string})=>row.checklist_type),["oil_tracking","oil_tracking","kitchen_opening"]);
  assert.equal(body.reports[1].status,"in_progress");
  assert.equal(body.reports[1].completion,50);
  assert.equal(body.reports[0].status,"issues_found");
  assert.equal(body.reports[0].issue_count,1);
 });

 it("supports Oil-only history filtering",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=oil_tracking`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.total,2);
  assert.ok(body.reports.every((row:{checklist_type:string})=>row.checklist_type==="oil_tracking"));
  assert.equal(calls.at(-1)?.name,"history");
 });

 it("keeps existing report type filters working",async()=>{
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=kitchen_opening`)).status,200);
  assert.equal(calls.at(-1)?.name,"history");
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/submissions?checklist_type=foh_opening`)).status,200);
  assert.equal(calls.at(-1)?.name,"history");
 });

 it("returns Oil detail rows, TPM classifications, synthesized visible items, and issues",async()=>{
  const response=await request(`/api/v1/supervisor/submissions/${oilCompleteId}`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.checklist_type,"oil_tracking");
  assert.equal(body.rows[0].tpm_classification,"nearing_end");
  assert.equal(body.rows[1].in_use_today,false);
  assert.equal(body.issues[0].tpm_status,"nearing_end");
  assert.match(body.items[0].item_text,/Fryer 1.*Closing TPM 21% Nearing End/);
  assert.match(body.items[0].remark,/Closing note: Filter before rush/);
 });

 it("keeps existing Kitchen detail working",async()=>{
  const response=await request(`/api/v1/supervisor/submissions/${kitchenReportId}`);
  assert.equal(response.status,200);
  assert.equal((await response.json()).checklist_type,"kitchen_opening");
 });
});
