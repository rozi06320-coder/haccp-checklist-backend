import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const manager="11000000-0000-4000-8000-000000000002";
const organization="31000000-0000-4000-8000-000000000001";
const branch="21000000-0000-4000-8000-000000000001";
const zero={expected_checks:0,answered_checks:0,compliant_checks:0,issue_checks:0,pending_checks:0,completion_percentage:null,compliance_percentage:null};
const dailyPending={expected_checks:13,answered_checks:0,compliant_checks:0,issue_checks:0,pending_checks:13,completion_percentage:0,compliance_percentage:null};
const overview={organization:{id:organization,name:"Organization"},generated_at:"2026-08-05T00:00:00Z",date_context:"current_branch_local_business_day" as const,summary:{active_branch_count:1,active_team_count:0,active_supervisor_account_count:0,active_operational_staff_count:0},totals:dailyPending,local_dates:[{business_date:"2026-08-05",branch_count:1}],branches:[{branch_id:branch,branch_name:"Branch",branch_code:"BR",timezone:"Asia/Riyadh",business_date:"2026-08-05",status:"no_active_team" as const,active_team_count:0,totals:dailyPending,checklists:[...["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage","sales_tracking"].map(checklist_type=>({checklist_type,team_states:{not_started:0,draft:0,submitted:0},...zero})),{checklist_type:"daily_audit",team_states:{not_started:1,draft:0,submitted:0},...dailyPending}]}]};

let allowed=true;
const persistence={
  async getOverview(){return null;},
  async getManagementOverview(){return overview;},
  async getCurrentState(){return null;},
  async saveDraft(){return null;},
  async saveHygieneDraft(){return null;},
  async submitOpening(){return null;},
  async submitHygiene(){return null;},
  async listSupervisor(){return null;},
  async getReport(){return null;},
  async listManagedReports(){return null;},
  async listManagedIssues(){return null;},
  async getManagedIssue(){return null;},
};
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:manager}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="manager"?{userId:manager,email:"manager@example.invalid"}:null},createUserContext:()=>({getUserContext:async()=>({id:manager,full_name:"Manager",must_change_password:false,disabled:false,branches:[],managed_organizations:[]}),hasOrganizationManagerAccess:async()=>allowed,validateActiveBranches:async()=>true,listActiveBranches:async()=>[]})};}

let server:Server,origin:string;
async function request(path:string,token?:string){return fetch(origin+path,{headers:token?{Authorization:`Bearer ${token}`}:{}});}

describe("Management Overview access regression",()=>{
  before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
  after(()=>new Promise<void>(resolve=>server.close(()=>resolve())));

  it("loads valid Overview data through explicit organization access when joined context is empty",async()=>{
    allowed=true;
    const response=await request(`/api/v1/management/organizations/${organization}/overview`,"manager");
    assert.equal(response.status,200);
    const body=await response.json();
    assert.equal(body.organization.id,organization);
    assert.equal(body.branches.length,1);
  });

  it("keeps the unavailable fallback path for real access failures",async()=>{
    allowed=false;
    const response=await request(`/api/v1/management/organizations/${organization}/overview`,"manager");
    assert.equal(response.status,403);
    assert.equal((await response.json()).error.code,"forbidden");
  });
});
