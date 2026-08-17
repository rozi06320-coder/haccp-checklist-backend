import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const manager="b1000000-0000-4000-8000-000000000001",supervisor="b1000000-0000-4000-8000-000000000002";
const organization="b2000000-0000-4000-8000-000000000001",branch="b3000000-0000-4000-8000-000000000001",submission="b4000000-0000-4000-8000-000000000001",openingSubmission="b4000000-0000-4000-8000-000000000002";
const items=Array.from({length:13},(_,index)=>({item_id:`daily-audit-${index+1}`,item_text:`Daily item ${index+1}`,answer:index===3?"non_compliant":"compliant",remark:index===3?"Corrective action required":""}));
const report={id:submission,branch_id:branch,branch_name:"Branch A",checklist_type:"daily_audit",business_date:"2026-08-11",submitted_at:"2026-08-11T09:00:00Z",submitted_by:"Safe Auditor",auditor_kind:"manual_access_user",completion:100,issue_count:1,status:"issues_found",record_kind:"submission"};
const genericDailyAuditReport={...report,submitted_by:"Manager Runtime",auditor_kind:null,issue_count:0,status:"compliant"};
const genericDailyAuditDetail={...genericDailyAuditReport,definition_id:"daily_audit_v1",items};
const detail={...report,definition_id:"daily_audit_v1",items};
const openingDetail={id:openingSubmission,branch_id:branch,branch_name:"Branch A",checklist_type:"kitchen_opening",business_date:"2026-08-11",submitted_at:"2026-08-11T08:00:00Z",submitted_by:"Manager Runtime",definition_id:"kitchen_opening_v1",completion:100,issue_count:0,status:"compliant",items:[{item_id:"kitchen-opening-1",item_text:"Opening item",answer:"completed",remark:""}]};

const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){throw new Error("unused");},async getCurrentState(){throw new Error("unused");},async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async listSupervisor(){throw new Error("unused");},
 async getReport(_actor:string,id:string){if(id===submission)return genericDailyAuditDetail;if(id===openingSubmission)return openingDetail;throw new ChecklistAccessError();},
 async listManagedReports(input:Record<string,unknown>){return{reports:[genericDailyAuditReport],page:input.requested_page,page_size:input.requested_page_size,total:1};},
 async listManagedDailyAuditReports(input:Record<string,unknown>){if(input.actor_user_id!==manager||input.target_organization_id!==organization)throw new ChecklistAccessError();return{reports:[report],page:input.requested_page,page_size:input.requested_page_size,total:1};},
 async getManagedOilTrackingReport(){throw new ChecklistAccessError();},
 async getManagedColdStorageReport(){throw new ChecklistAccessError();},
 async getManagedDailyAuditReport(_actor:string,org:string,id:string){if(org!==organization||id!==submission)throw new ChecklistAccessError();return detail;},
 async listManagedIssues(){return{issues:[],page:1,page_size:20,total:0};},async getManagedIssue(){throw new Error("unused");},
};

function dependencies():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:manager}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="manager"?{userId:manager,email:"manager@example.invalid"}:token==="supervisor"?{userId:supervisor,email:"supervisor@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="manager"?{id:manager,full_name:"Manager",must_change_password:false,disabled:false,branches:[],managed_organizations:[{id:organization,name:"Org",role:"organization_manager"}]}:{id:supervisor,full_name:"Supervisor",must_change_password:false,disabled:false,branches:[{id:branch,name:"Branch A",organization_id:organization,role:"branch_manager"}],managed_organizations:[]},hasOrganizationManagerAccess:async()=>token==="manager",validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token="manager",method="GET"){return fetch(origin+path,{method,headers:{Authorization:`Bearer ${token}`}});}

describe("Manager Daily Audit read-only API",()=>{
 before(async()=>{server=createServer(createApp(config,dependencies()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
 after(()=>new Promise<void>(resolve=>server.close(()=>resolve())));

 it("lists submitted Daily Audits with safe auditor fields",async()=>{
  const response=await request(`/api/v1/management/organizations/${organization}/reports?checklist_type=daily_audit`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.reports[0].checklist_type,"daily_audit");
  assert.equal(body.reports[0].auditor_kind,"manual_access_user");
  assert.equal(body.reports[0].submitted_by,"Safe Auditor");
  assert.equal(body.reports[0].issue_count,1);
  assert.doesNotMatch(JSON.stringify(body),/credential|pin|hash|salt|cookie|grant|token/i);
 });

 it("includes Daily Audit in the combined report history",async()=>{
  const response=await request(`/api/v1/management/organizations/${organization}/reports`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.deepEqual(body.reports.map((row:{checklist_type:string})=>row.checklist_type),["daily_audit"]);
  assert.equal(body.reports[0].submitted_by,"Safe Auditor");
  assert.equal(body.reports[0].issue_count,1);
  assert.equal(body.total,1);
 });

 it("returns the read-only 13-item detail",async()=>{
  const response=await request(`/api/v1/management/organizations/${organization}/reports/${submission}`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(genericDailyAuditDetail.submitted_by,"Manager Runtime");
  assert.equal(detail.submitted_by,"Safe Auditor");
  assert.equal(body.items.length,13);
  assert.equal(body.items[3].answer,"non_compliant");
  assert.equal(body.items[3].remark,"Corrective action required");
  assert.equal(body.submitted_by,"Safe Auditor");
  assert.doesNotMatch(JSON.stringify(body),/credential|pin|hash|salt|cookie|grant|token/i);
 });

 it("keeps non-Daily-Audit detail on the generic report path",async()=>{
  const response=await request(`/api/v1/management/organizations/${organization}/reports/${openingSubmission}`);
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.checklist_type,"kitchen_opening");
  assert.equal(body.submitted_by,"Manager Runtime");
  assert.equal(body.items.length,1);
 });

 it("denies Supervisor access and exposes no Manager mutation route",async()=>{
  assert.equal((await request(`/api/v1/management/organizations/${organization}/reports?checklist_type=daily_audit`,"supervisor")).status,403);
  assert.equal((await request(`/api/v1/management/organizations/${organization}/reports/${submission}`,"manager","PUT")).status,404);
 });
});
