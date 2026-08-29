import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const manager="16000000-0000-4000-8000-000000000001",supervisor="16000000-0000-4000-8000-000000000002";
const org="36000000-0000-4000-8000-000000000001",branch="26000000-0000-4000-8000-000000000001";
const kitchenId="56000000-0000-4000-8000-000000000001",oilId="66000000-0000-4000-8000-000000000001",coldId="76000000-0000-4000-8000-000000000001",coldMissingId="76000000-0000-4000-8000-000000000002";
const calls:Array<{name:string;input:unknown}>=[];
const baseReport={id:kitchenId,branch_id:branch,branch_name:"A",checklist_type:"kitchen_opening",business_date:"2026-08-01",submitted_at:"2026-08-01T07:00:00Z",submitted_by:"Supervisor",issue_count:0,status:"compliant"};
const oilReport={id:oilId,branch_id:branch,branch_name:"A",checklist_type:"oil_tracking",business_date:"2026-08-02",submitted_at:"2026-08-02T20:00:00Z",submitted_by:"Supervisor",completion:100,issue_count:1,status:"issues_found"};
const coldReport={id:coldId,record_kind:"submission",source_submission_id:coldId,branch_id:branch,branch_name:"A",checklist_type:"cold_storage",business_date:"2026-08-03",submitted_at:"2026-08-03T12:00:00Z",submitted_by:"Supervisor",completion:33,issue_count:1,status:"issues_found",submitted_slots:["12:00"],missed_check_count:1,missed_slots:["20:00"]};
const coldMissingReport={id:coldMissingId,record_kind:"derived_missing",source_submission_id:coldId,branch_id:branch,branch_name:"A",checklist_type:"cold_storage",business_date:"2026-08-03",submitted_at:null,submitted_by:null,completion:0,issue_count:1,status:"not_checked",submitted_slots:["12:00"],missed_check_count:1,missed_slots:["20:00"]};
const oilDetail={id:oilId,branch_id:branch,branch_name:"A",business_date:"2026-08-02",checklist_type:"oil_tracking",definition_id:"oil_tracking_v1",submitted_at:"2026-08-02T20:00:00Z",submitted_by:"Supervisor",completion:100,issue_count:1,status:"issues_found",opening_submitted_at:"2026-08-02T08:00:00Z",closing_submitted_at:"2026-08-02T20:00:00Z",rows:[{fryer_id:"fryer-1",fryer_label:"Fryer 1",fryer_short_label:"F1",in_use_today:true,oil_status:"new_oil",opening_temperature_c:175,opening_status:"pass",opening_note:"",closing_tpm_percent:22,closing_note:"Filter oil",tpm_classification:"filtering_required"}],issues:[]};
const coldDetail={id:coldId,record_kind:"submission",source_submission_id:coldId,branch_id:branch,branch_name:"A",business_date:"2026-08-03",checklist_type:"cold_storage",definition_id:"cold_storage_v1",submitted_at:"2026-08-03T12:00:00Z",submitted_by:"Supervisor",completion:33,issue_count:1,status:"issues_found",submitted_slots:["12:00"],missed_check_count:1,missed_slots:["20:00"],rows:[{equipment_id:"ref-1",equipment_name:"Line Refrigerator",equipment_type:"refrigerator",active:true,slot:"12:00",temperature_c:5,status:"fail",corrective_action:"Adjusted thermostat",submitted_at:"2026-08-03T12:00:00Z"}],issues:[]};
const coldMissingDetail={id:coldMissingId,record_kind:"derived_missing",source_submission_id:coldId,branch_id:branch,branch_name:"A",business_date:"2026-08-03",checklist_type:"cold_storage",definition_id:"cold_storage_v1",submitted_at:null,submitted_by:null,completion:0,issue_count:1,status:"not_checked",submitted_slots:["12:00"],missed_check_count:1,missed_slots:["20:00"],items:[{item_id:"missed:20:00",item_text:"20:00 scheduled Chiller & Freezer check",answer:"not_checked",remark:"Scheduled temperature check was not submitted.",evidence:null}],rows:[],issues:[]};
let oilMode:"ok"|"failure"="ok";
const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){throw new Error("unused");},async getCurrentState(){throw new Error("unused");},async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async getOilTrackingCurrentState(){throw new Error("unused");},async saveOilTrackingDraft(){throw new Error("unused");},async submitOilTrackingOpening(){throw new Error("unused");},async submitOilTrackingClosing(){throw new Error("unused");},async getColdStorageCurrentState(){throw new Error("unused");},async saveColdStorageDraft(){throw new Error("unused");},async submitColdStorageSlot(){throw new Error("unused");},
 async listSupervisor(){throw new Error("unused");},async listOilTrackingSupervisor(){throw new Error("unused");},async listColdStorageSupervisor(){throw new Error("unused");},
 async getReport(_actor:string,id:string,managerMode:boolean){calls.push({name:"detail",input:{id,managerMode}});if(id!==kitchenId)throw new ChecklistAccessError();return{id:kitchenId,branch_id:branch,branch_name:"A",business_date:"2026-08-01",checklist_type:"kitchen_opening",definition_id:"kitchen_opening_v1",submitted_at:"2026-08-01T07:00:00Z",submitted_by:"Supervisor",completion:100,issue_count:0,status:"compliant",items:[],staff:[]};},
 async getOilTrackingReport(){throw new Error("unused");},async getColdStorageReport(){throw new Error("unused");},
 async listManagedReports(input:Record<string,unknown>){calls.push({name:"reports",input});if(input.actor_user_id!==manager)throw new ChecklistAccessError();const reports=!input.status_filter||input.status_filter===baseReport.status?[baseReport]:[];return{reports,page:input.requested_page,page_size:input.requested_page_size,total:reports.length};},
 async listManagedOilTrackingReports(input:Record<string,unknown>){calls.push({name:"oil-reports",input});if(input.actor_user_id!==manager)throw new ChecklistAccessError();if(oilMode==="failure")throw new Error("Checklist persistence unavailable.");const reports=!input.status_filter||input.status_filter===oilReport.status?[oilReport]:[];return{reports,page:input.requested_page,page_size:input.requested_page_size,total:reports.length};},
 async listManagedColdStorageReports(input:Record<string,unknown>){calls.push({name:"cold-reports",input});if(input.actor_user_id!==manager)throw new ChecklistAccessError();const reports=[coldReport,coldMissingReport].filter(row=>!input.status_filter||input.status_filter===row.status);return{reports,page:input.requested_page,page_size:input.requested_page_size,total:reports.length};},
 async getManagedOilTrackingReport(_actor:string,_organization:string,id:string){calls.push({name:"oil-detail",input:id});if(id!==oilId)throw new ChecklistAccessError();return oilDetail;},
 async getManagedColdStorageReport(_actor:string,_organization:string,id:string){calls.push({name:"cold-detail",input:id});if(id===coldMissingId)return coldMissingDetail;if(id!==coldId)throw new ChecklistAccessError();return coldDetail;},
 async listManagedIssues(){return{issues:[],page:1,page_size:20,total:0};},async getManagedIssue(){throw new Error("unused");},
};
function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:manager}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="manager"?{userId:manager,email:"m@example.invalid"}:token==="supervisor"?{userId:supervisor,email:"s@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="manager"?{id:manager,full_name:"M",must_change_password:false,disabled:false,branches:[],managed_organizations:[{id:org,name:"O",role:"organization_manager"}]}:{id:supervisor,full_name:"S",must_change_password:false,disabled:false,branches:[{id:branch,name:"A",organization_id:org,role:"branch_manager"}],managed_organizations:[]},hasOrganizationManagerAccess:async()=>token==="manager",validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token="manager"){return fetch(origin+path,{headers:{Authorization:`Bearer ${token}`}});}

describe("Management Oil and Cold Storage reports API",()=>{
 before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
 after(()=>new Promise<void>((resolve)=>server.close(()=>resolve())));
 beforeEach(()=>{calls.length=0;oilMode="ok";});

 it("merges Oil and Cold into all management reports",async()=>{
  const response=await request(`/api/v1/management/organizations/${org}/reports?page=1&page_size=20`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.deepEqual(body.reports.map((row:{checklist_type:string;status:string})=>`${row.checklist_type}:${row.status}`),["cold_storage:issues_found","cold_storage:not_checked","oil_tracking:issues_found","kitchen_opening:compliant"]);
  assert.equal(body.reports[0].missed_check_count,1);
  assert.deepEqual(body.reports[0].missed_slots,["20:00"]);
  assert.equal(body.reports[1].submitted_at,null);
  assert.equal(body.reports[1].submitted_by,null);
  assert.equal(body.reports[1].record_kind,"derived_missing");
  assert.equal(body.total,4);
 });

 it("keeps all reports available if optional Oil merge is unavailable",async()=>{
  oilMode="failure";
  const response=await request(`/api/v1/management/organizations/${org}/reports?page=1&page_size=20`);
  assert.equal(response.status,200);
  assert.deepEqual((await response.json()).reports.map((row:{checklist_type:string})=>row.checklist_type),["cold_storage","cold_storage","kitchen_opening"]);
 });

 it("supports direct Oil and Cold management filters",async()=>{
  assert.equal((await request(`/api/v1/management/organizations/${org}/reports?checklist_type=oil_tracking`)).status,200);
  assert.equal(calls.at(-1)?.name,"oil-reports");
  assert.equal((await request(`/api/v1/management/organizations/${org}/reports?checklist_type=cold_storage`)).status,200);
  assert.equal(calls.at(-1)?.name,"cold-reports");
  const notChecked=await request(`/api/v1/management/organizations/${org}/reports?checklist_type=cold_storage&status=not_checked`);
  assert.equal(notChecked.status,200);
  assert.equal((await notChecked.json()).reports[0].record_kind,"derived_missing");
  assert.equal((await request(`/api/v1/management/organizations/${org}/reports?checklist_type=kitchen_opening`)).status,200);
  assert.equal(calls.at(-1)?.name,"reports");
 });

 it("opens Oil and Cold report details through manager access",async()=>{
  const oil=await request(`/api/v1/management/organizations/${org}/reports/${oilId}`);
  assert.equal(oil.status,200);
  const oilBody=await oil.json();
  assert.equal(oilBody.checklist_type,"oil_tracking");
  assert.match(oilBody.items[0].item_text,/Fryer 1.*Filtering Required/);
  const cold=await request(`/api/v1/management/organizations/${org}/reports/${coldId}`);
  assert.equal(cold.status,200);
  const coldBody=await cold.json();
  assert.equal(coldBody.checklist_type,"cold_storage");
  assert.equal(coldBody.missed_check_count,1);
  assert.deepEqual(coldBody.missed_slots,["20:00"]);
  assert.match(coldBody.items[0].item_text,/Line Refrigerator.*12:00.*5C/);
  const missing=await request(`/api/v1/management/organizations/${org}/reports/${coldMissingId}`);
  assert.equal(missing.status,200);
  const missingBody=await missing.json();
  assert.equal(missingBody.status,"not_checked");
  assert.equal(missingBody.record_kind,"derived_missing");
  assert.equal(missingBody.submitted_at,null);
  assert.equal(missingBody.submitted_by,null);
  assert.match(missingBody.items[0].remark,/not submitted/);
 });

 it("denies supervisor access to management reports",async()=>{
  assert.equal((await request(`/api/v1/management/organizations/${org}/reports`,"supervisor")).status,403);
 });
});
