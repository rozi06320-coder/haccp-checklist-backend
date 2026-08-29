import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const manager="17000000-0000-4000-8000-000000000001",supervisor="17000000-0000-4000-8000-000000000002";
const org="37000000-0000-4000-8000-000000000001",branch="27000000-0000-4000-8000-000000000001";
const phaseIssueId="e402ca8c-54e0-b9fa-1da2-10e739dd1997",oilIssueId="11f5d425-5c86-f0c0-0488-b7dbdf51bd94",coldIssueId="47000000-0000-4000-8000-000000000003",coldMissedIssueId="35cfe577-b2a5-c1c7-37c9-790fbd1b9e9c",salesIssueId="24f24b15-ac97-8063-f651-db5322239db3";
const zero={expected_checks:0,answered_checks:0,compliant_checks:0,issue_checks:0,pending_checks:0,completion_percentage:null,compliance_percentage:null};
const oilCounts={expected_checks:2,answered_checks:2,compliant_checks:0,issue_checks:2,pending_checks:0,completion_percentage:100,compliance_percentage:0};
const coldCounts={expected_checks:1,answered_checks:1,compliant_checks:0,issue_checks:1,pending_checks:0,completion_percentage:100,compliance_percentage:0};
const totals={expected_checks:17,answered_checks:3,compliant_checks:0,issue_checks:3,pending_checks:14,completion_percentage:18,compliance_percentage:0};
const overview={organization:{id:org,name:"Org"},generated_at:"2026-08-06T12:00:00Z",date_context:"current_branch_local_business_day",summary:{active_branch_count:1,active_team_count:1,active_supervisor_account_count:1,active_operational_staff_count:0},totals,local_dates:[{business_date:"2026-08-06",branch_count:1}],branches:[{branch_id:branch,branch_name:"Branch",branch_code:"BR",timezone:"Asia/Riyadh",business_date:"2026-08-06",status:"ready",active_team_count:1,totals,checklists:[
  {checklist_type:"kitchen_opening",team_states:{not_started:0,draft:0,submitted:0},...zero},
  {checklist_type:"foh_opening",team_states:{not_started:0,draft:0,submitted:0},...zero},
  {checklist_type:"staff_hygiene",team_states:{not_started:0,draft:0,submitted:0},...zero},
  {checklist_type:"oil_tracking",team_states:{not_started:0,draft:0,submitted:1},...oilCounts},
  {checklist_type:"cold_storage",team_states:{not_started:0,draft:0,submitted:1},...coldCounts},
  {checklist_type:"sales_tracking",team_states:{not_started:1,draft:0,submitted:0},expected_checks:1,answered_checks:0,compliant_checks:0,issue_checks:0,pending_checks:1,completion_percentage:0,compliance_percentage:null},
  {checklist_type:"daily_audit",team_states:{not_started:1,draft:0,submitted:0},expected_checks:13,answered_checks:0,compliant_checks:0,issue_checks:0,pending_checks:13,completion_percentage:0,compliance_percentage:null},
]}]};
const phaseIssue={id:phaseIssueId,report_id:"dfd01581-712c-d617-b19f-eabc3ef42d00",branch_id:branch,branch_name:"Branch",business_date:"2026-08-06",submitted_by:"Supervisor",checklist_type:"kitchen_opening",title:"Kitchen issue",description:"Missing item",status:"new",created_at:"2026-08-06T10:00:00Z",item_id:"k1",item_text:"Kitchen item"};
const oilIssue={id:oilIssueId,report_id:"73d92fb3-b31e-a87f-f795-17ff8c6c44af",branch_id:branch,branch_name:"Branch",business_date:"2026-08-06",submitted_by:"Supervisor",checklist_type:"oil_tracking",title:"Closing TPM filtering required - Fryer 1",description:"Closing TPM status: filtering required. Filter oil",status:"new",created_at:"2026-08-06T12:00:00Z",item_id:"fryer-1",item_text:"Fryer 1"};
const coldIssue={id:coldIssueId,report_id:"57000000-0000-4000-8000-000000000003",branch_id:branch,branch_name:"Branch",business_date:"2026-08-06",submitted_by:"Supervisor",checklist_type:"cold_storage",title:"Cold storage temperature issue - Line Refrigerator",description:"12:00 reading: 5C. Adjusted thermostat",status:"new",created_at:"2026-08-06T11:00:00Z",item_id:"ref-1",item_text:"Line Refrigerator"};
const coldMissedIssue={id:coldMissedIssueId,report_id:"57000000-0000-4000-8000-000000000003",branch_id:branch,branch_name:"Branch",business_date:"2026-08-06",submitted_by:"Supervisor",checklist_type:"cold_storage",title:"Chiller & Freezer missed scheduled check - 20:00",description:"20:00 scheduled Chiller & Freezer check was not submitted.",status:"new",created_at:"2026-08-06T11:30:00Z",item_id:"missed:20:00",item_text:"Missed 20:00 scheduled check",record_kind:"derived_missing",source_submission_id:null};
const salesIssue={id:salesIssueId,report_id:"0997a165-1b96-227f-a9bb-beac8d961f60",branch_id:branch,branch_name:"Branch",business_date:"2026-08-06",submitted_by:"Supervisor",checklist_type:"sales_tracking",title:"Sales Tracking variance issue",description:"Actual total 250, POS total 200, variance 50.",status:"new",created_at:"2026-08-06T11:45:00Z",item_id:"variance",item_text:"Variance mismatch"};
const calls:Array<{name:string;input:unknown}>=[];
let oilIssuesMode:"ok"|"failure"="ok";
let salesIssuesMode:"ok"|"failure"|"malformed"="ok";
let emptyIssuesMode=false;
const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){calls.push({name:"overview",input:null});return overview;},async getCurrentState(){throw new Error("unused");},async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async getOilTrackingCurrentState(){throw new Error("unused");},async saveOilTrackingDraft(){throw new Error("unused");},async submitOilTrackingOpening(){throw new Error("unused");},async submitOilTrackingClosing(){throw new Error("unused");},async getColdStorageCurrentState(){throw new Error("unused");},async saveColdStorageDraft(){throw new Error("unused");},async submitColdStorageSlot(){throw new Error("unused");},
 async listSupervisor(){throw new Error("unused");},async listOilTrackingSupervisor(){throw new Error("unused");},async listColdStorageSupervisor(){throw new Error("unused");},
 async getReport(){throw new Error("unused");},async getOilTrackingReport(){throw new Error("unused");},async getColdStorageReport(){throw new Error("unused");},
 async listManagedReports(){throw new Error("unused");},async listManagedOilTrackingReports(){throw new Error("unused");},async listManagedColdStorageReports(){throw new Error("unused");},async getManagedOilTrackingReport(){throw new Error("unused");},async getManagedColdStorageReport(){throw new Error("unused");},
 async listManagedIssues(input:Record<string,unknown>){calls.push({name:"phase-issues",input});return{issues:emptyIssuesMode?[]:[phaseIssue],page:input.requested_page,page_size:input.requested_page_size,total:emptyIssuesMode?0:1};},
 async listManagedOilTrackingIssues(input:Record<string,unknown>){calls.push({name:"oil-issues",input});if(oilIssuesMode==="failure")throw new Error("Checklist persistence unavailable.");return{issues:emptyIssuesMode?[]:[oilIssue],page:input.requested_page,page_size:input.requested_page_size,total:emptyIssuesMode?0:1};},
 async listManagedColdStorageIssues(input:Record<string,unknown>){calls.push({name:"cold-issues",input});return{issues:emptyIssuesMode?[]:[coldMissedIssue,coldIssue],page:input.requested_page,page_size:input.requested_page_size,total:emptyIssuesMode?0:2};},
 async listManagedSalesTrackingIssues(input:Record<string,unknown>){calls.push({name:"sales-issues",input});if(salesIssuesMode==="failure")throw new Error("Checklist persistence unavailable.");if(salesIssuesMode==="malformed")return{issues:[{...salesIssue,checklist_type:"unknown"}],page:input.requested_page,page_size:input.requested_page_size,total:1};return{issues:emptyIssuesMode?[]:[salesIssue],page:input.requested_page,page_size:input.requested_page_size,total:emptyIssuesMode?0:1};},
 async getManagedIssue(_actor:string,_organization:string,id:string){calls.push({name:"phase-detail",input:id});if(id!==phaseIssueId)throw new ChecklistAccessError();return{...phaseIssue,remark:"Missing item"};},
 async getManagedOilTrackingIssue(_actor:string,_organization:string,id:string){calls.push({name:"oil-detail",input:id});if(id!==oilIssueId)throw new ChecklistAccessError();return{...oilIssue,remark:"Section: closing\nTPM status: filtering required\nFilter oil"};},
 async getManagedColdStorageIssue(_actor:string,_organization:string,id:string){calls.push({name:"cold-detail",input:id});if(id===coldMissedIssueId)return{...coldMissedIssue,submitted_by:null,remark:"Missed scheduled check\nSlot: 20:00"};if(id!==coldIssueId)throw new ChecklistAccessError();return{...coldIssue,remark:"Slot: 12:00\nTemperature: 5C\nAdjusted thermostat"};},
 async getManagedSalesTrackingIssue(_actor:string,_organization:string,id:string){calls.push({name:"sales-detail",input:id});if(id!==salesIssueId)throw new ChecklistAccessError();return{...salesIssue,remark:"Variance issue\nActual total: 250\nPOS total: 200\nVariance: 50\nActual and POS totals do not match."};},
};
function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:manager}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="manager"?{userId:manager,email:"m@example.invalid"}:token==="supervisor"?{userId:supervisor,email:"s@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="manager"?{id:manager,full_name:"M",must_change_password:false,disabled:false,branches:[],managed_organizations:[{id:org,name:"O",role:"organization_manager"}]}:{id:supervisor,full_name:"S",must_change_password:false,disabled:false,branches:[{id:branch,name:"A",organization_id:org,role:"branch_manager"}],managed_organizations:[]},hasOrganizationManagerAccess:async()=>token==="manager",validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token="manager"){return fetch(origin+path,{headers:{Authorization:`Bearer ${token}`}});}

describe("Management Oil and Cold Storage overview and issues API",()=>{
 before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
 after(()=>new Promise<void>((resolve)=>server.close(()=>resolve())));
 beforeEach(()=>{calls.length=0;oilIssuesMode="ok";salesIssuesMode="ok";emptyIssuesMode=false;});

 it("returns Oil and Cold in management overview branch breakdown and totals",async()=>{
  const response=await request(`/api/v1/management/organizations/${org}/overview`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.deepEqual(body.branches[0].checklists.map((row:{checklist_type:string})=>row.checklist_type),["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage","sales_tracking","daily_audit"]);
  assert.equal(body.totals.expected_checks,17);
  assert.equal(body.totals.issue_checks,3);
 });

 it("merges Oil and Cold issues into all management issues",async()=>{
  const response=await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.deepEqual(body.issues.map((row:{checklist_type:string})=>row.checklist_type),["oil_tracking","sales_tracking","cold_storage","cold_storage","kitchen_opening"]);
  assert.match(body.issues[1].title,/Sales Tracking variance/);
  assert.equal(body.total,5);
 });

 it("returns a normal empty issues response instead of unavailable when no issue rows exist",async()=>{
  emptyIssuesMode=true;
  const response=await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{issues:[],page:1,page_size:20,total:0});
 });

 it("keeps all issues available if optional Oil issue merge is unavailable",async()=>{
  oilIssuesMode="failure";
  const response=await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
  assert.equal(response.status,200);
  assert.deepEqual((await response.json()).issues.map((row:{checklist_type:string})=>row.checklist_type),["sales_tracking","cold_storage","cold_storage","kitchen_opening"]);
 });

 it("keeps all issues available if optional Sales Tracking issue merge is malformed or unavailable",async()=>{
  salesIssuesMode="malformed";
  const malformed=await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
  assert.equal(malformed.status,200);
  assert.deepEqual((await malformed.json()).issues.map((row:{checklist_type:string})=>row.checklist_type),["oil_tracking","cold_storage","cold_storage","kitchen_opening"]);

  salesIssuesMode="failure";
  const unavailable=await request(`/api/v1/management/organizations/${org}/issues?page=1&page_size=20`);
  assert.equal(unavailable.status,200);
  assert.deepEqual((await unavailable.json()).issues.map((row:{checklist_type:string})=>row.checklist_type),["oil_tracking","cold_storage","cold_storage","kitchen_opening"]);

  const direct=await request(`/api/v1/management/organizations/${org}/issues?checklist_type=sales_tracking`);
  assert.equal(direct.status,503);
 });

 it("supports direct Oil and Cold management issue filters",async()=>{
  assert.equal((await request(`/api/v1/management/organizations/${org}/issues?checklist_type=oil_tracking`)).status,200);
  assert.equal(calls.at(-1)?.name,"oil-issues");
  assert.equal((await request(`/api/v1/management/organizations/${org}/issues?checklist_type=cold_storage`)).status,200);
  assert.equal(calls.at(-1)?.name,"cold-issues");
  assert.equal((await request(`/api/v1/management/organizations/${org}/issues?checklist_type=sales_tracking`)).status,200);
  assert.equal(calls.at(-1)?.name,"sales-issues");
  assert.equal((await request(`/api/v1/management/organizations/${org}/issues?checklist_type=kitchen_opening`)).status,200);
  assert.equal(calls.at(-1)?.name,"phase-issues");
});

 it("opens Oil, Cold, and Sales Tracking issue details through manager access",async()=>{
  const oil=await request(`/api/v1/management/organizations/${org}/issues/${oilIssueId}`);
  assert.equal(oil.status,200);
  assert.equal((await oil.json()).checklist_type,"oil_tracking");
  const cold=await request(`/api/v1/management/organizations/${org}/issues/${coldIssueId}`);
  assert.equal(cold.status,200);
  assert.equal((await cold.json()).checklist_type,"cold_storage");
  const missed=await request(`/api/v1/management/organizations/${org}/issues/${coldMissedIssueId}`);
  assert.equal(missed.status,200);
  const missedBody=await missed.json();
  assert.equal(missedBody.submitted_by,null);
  assert.equal(missedBody.record_kind,"derived_missing");
  assert.equal(missedBody.source_submission_id,null);
  assert.match(missedBody.remark,/Missed scheduled check/);
  const submittedCold=await request(`/api/v1/management/organizations/${org}/issues/${coldIssueId}`);
  const submittedColdBody=await submittedCold.json();
  assert.equal(submittedColdBody.record_kind,"submission");
  assert.equal(submittedColdBody.source_submission_id,coldIssue.report_id);
  const sales=await request(`/api/v1/management/organizations/${org}/issues/${salesIssueId}`);
  assert.equal(sales.status,200);
  const salesBody=await sales.json();
  assert.equal(salesBody.checklist_type,"sales_tracking");
  assert.match(salesBody.remark,/Actual and POS totals do not match/);
 });

 it("denies supervisor access to management overview and issues",async()=>{
  assert.equal((await request(`/api/v1/management/organizations/${org}/overview`,"supervisor")).status,403);
  assert.equal((await request(`/api/v1/management/organizations/${org}/issues`,"supervisor")).status,403);
 });
});
