import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisorA="13000000-0000-4000-8000-000000000001";
const supervisorB="13000000-0000-4000-8000-000000000002";
const branch="23000000-0000-4000-8000-000000000001";
const organization="33000000-0000-4000-8000-000000000001";
const counts={expected_checks:0,answered_checks:0,compliant_checks:0,issue_checks:0,pending_checks:0,completion_percentage:null,compliance_percentage:null};
const overview={
 business_date:"2026-08-12",
 totals:{expected_checks:50,answered_checks:40,compliant_checks:39,issue_checks:1,pending_checks:10,completion_percentage:80,compliance_percentage:98},
 checklists:[
  {checklist_type:"kitchen_opening",state:"submitted",expected_checks:17,answered_checks:17,compliant_checks:16,issue_checks:1,pending_checks:0,completion_percentage:100,compliance_percentage:94},
  {checklist_type:"foh_opening",state:"submitted",expected_checks:18,answered_checks:18,compliant_checks:18,issue_checks:0,pending_checks:0,completion_percentage:100,compliance_percentage:100},
  {checklist_type:"staff_hygiene",state:"not_started",expected_checks:4,answered_checks:0,compliant_checks:0,issue_checks:0,pending_checks:4,completion_percentage:0,compliance_percentage:null},
  {checklist_type:"oil_tracking",state:"draft",expected_checks:8,answered_checks:2,compliant_checks:2,issue_checks:0,pending_checks:6,completion_percentage:25,compliance_percentage:100},
  {checklist_type:"cold_storage",state:"draft",expected_checks:3,answered_checks:3,compliant_checks:3,issue_checks:0,pending_checks:0,completion_percentage:100,compliance_percentage:100},
 ],
};
let overviewPayload:unknown=overview;
const overviewCalls:Array<{actor:string;branch:string}>=[];

const checklistPersistence={
 async getOverview(actor:string,targetBranch:string){overviewCalls.push({actor,branch:targetBranch});return overviewPayload;},
 async getManagementOverview(){throw new Error("unused");},async getCurrentState(){throw new Error("unused");},
 async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async getOilTrackingCurrentState(){throw new Error("obsolete Overview dependency called");},
 async getColdStorageCurrentState(){throw new Error("obsolete Overview dependency called");},
 async listSupervisor(){throw new Error("unused");},async getReport(){throw new Error("unused");},async listManagedReports(){throw new Error("unused");},async listManagedIssues(){throw new Error("unused");},async getManagedIssue(){throw new Error("unused");},
};

function dependencies():BackendDependencies{return{
 checkReadiness:async()=>true,
 checklistPersistence,
 passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},
 provisioningAdmin:{createUser:async()=>({id:supervisorA}),deleteUser:async()=>{},finalize:async()=>{}},
 managementAdmin:{listUsers:async()=>({users:[],total:0})},
 branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},
 pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},
 authVerifier:{verify:async token=>token==="supervisor-a"?{userId:supervisorA,email:"a@example.invalid"}:token==="supervisor-b"?{userId:supervisorB,email:"b@example.invalid"}:null},
 createUserContext:()=>({getUserContext:async()=>({id:supervisorA,full_name:"Supervisor",must_change_password:false,disabled:false,branches:[{id:branch,name:"Branch",organization_id:organization,role:"branch_manager"}],managed_organizations:[]}),hasOrganizationManagerAccess:async()=>false,validateActiveBranches:async()=>true,listActiveBranches:async()=>[]}),
};}

const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};

describe("Branch-shared supervisor Overview API",()=>{
 let server:Server;
 let origin="";
 before(async()=>{server=createServer(createApp(config,dependencies()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
 after(()=>new Promise<void>(resolve=>server.close(()=>resolve())));

 async function request(token:string){return fetch(`${origin}/api/v1/supervisor/branches/${branch}/overview`,{headers:{Authorization:`Bearer ${token}`}});}

 it("returns the atomic five-card RPC payload unchanged for both branch supervisors",async()=>{
  overviewPayload=overview;
  const a=await request("supervisor-a"),b=await request("supervisor-b");
  assert.equal(a.status,200);assert.equal(b.status,200);
  assert.deepEqual(await a.json(),overview);assert.deepEqual(await b.json(),overview);
  assert.deepEqual(overviewCalls.slice(-2),[{actor:supervisorA,branch},{actor:supervisorB,branch}]);
 });

 it("fails closed when the atomic RPC response is incomplete",async()=>{
  overviewPayload={...overview,checklists:overview.checklists.slice(0,3),totals:{...counts,expected_checks:35,pending_checks:35,completion_percentage:0}};
  const response=await request("supervisor-a");
  assert.equal(response.status,503);
  assert.doesNotMatch(JSON.stringify(await response.json()),/database|postgres|zod|checklists/i);
 });
});
