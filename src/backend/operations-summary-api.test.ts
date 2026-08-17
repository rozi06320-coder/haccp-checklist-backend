import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { managementOperationsSummarySchema } from "../lib/contracts/management-operations-summary";

const manager="11000000-0000-4000-8000-000000000002";
const organization="31000000-0000-4000-8000-000000000001";
const branch="21000000-0000-4000-8000-000000000001";
let allowed=true;
let validBranch=true;
const summary={
  generated_at:"2026-08-11T10:00:00.000Z",
  scope:{organization_id:organization,branch_id:null,month:"2026-08"},
  purchase_logs:{unpaid_count:1,unpaid_amount:"12.50",total_amount:"20.00"},
  supplier_receivings:{entry_count:2,branch_count:1},
  maintenance_issues:{open_count:3,urgent_high_count:1},
  maintenance_purchases:{purchase_count:1,total_amount:"5.00",unpaid_count:1,unpaid_amount:"5.00"},
  inventory:{active_branch_count:1,reported_branch_count:0,submitted_branch_count:0,beef_row_count:0,item_usage_row_count:0},
  staff:{active_count:4,inactive_count:1},
  availability:{purchase_logs:"ready" as const,supplier_receivings:"ready" as const,maintenance_issues:"ready" as const,maintenance_purchases:"ready" as const,inventory:"ready" as const,staff:"ready" as const},
};
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
function dependencies():BackendDependencies{return{
  checkReadiness:async()=>true,
  passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},
  provisioningAdmin:{createUser:async()=>({id:manager}),deleteUser:async()=>{},finalize:async()=>{}},
  managementAdmin:{listUsers:async()=>({users:[],total:0})},
  branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},
  pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},
  authVerifier:{verify:async token=>token==="manager"?{userId:manager,email:"manager@example.invalid"}:null},
  createUserContext:()=>({getUserContext:async()=>({id:manager,full_name:"Manager",must_change_password:false,disabled:false,branches:[],managed_organizations:[]}),hasOrganizationManagerAccess:async()=>allowed,validateActiveBranches:async()=>validBranch,listActiveBranches:async()=>[]}),
  operationalAdmin:{getManagedOperationsSummary:async input=>({...summary,scope:{...summary.scope,branch_id:input.branchId??null,month:input.month}})} as BackendDependencies["operationalAdmin"],
};}

let server:Server,origin:string;
async function request(path:string,token?:string){return fetch(origin+path,{headers:token?{Authorization:`Bearer ${token}`}:{}});}

describe("Manager operations summary API",()=>{
  before(async()=>{server=createServer(createApp(config,dependencies()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;});
  after(()=>new Promise<void>(resolve=>server.close(()=>resolve())));

  it("returns the strict aggregate DTO with decimal strings",async()=>{
    allowed=true;validBranch=true;
    const response=await request(`/api/v1/management/organizations/${organization}/operations-summary?month=2026-08`,"manager");
    assert.equal(response.status,200);
    const body=await response.json();
    assert.equal(managementOperationsSummarySchema.safeParse(body).success,true);
    assert.equal(body.purchase_logs.unpaid_amount,"12.50");
    assert.equal("invoice_storage_path" in body,false);
    assert.equal("notes" in body,false);
  });

  it("rejects unauthenticated, unauthorized, invalid query, and invalid branch requests",async()=>{
    assert.equal((await request(`/api/v1/management/organizations/${organization}/operations-summary`)).status,401);
    allowed=false;
    assert.equal((await request(`/api/v1/management/organizations/${organization}/operations-summary`,"manager")).status,403);
    allowed=true;
    assert.equal((await request(`/api/v1/management/organizations/${organization}/operations-summary?month=bad`,"manager")).status,400);
    validBranch=false;
    assert.equal((await request(`/api/v1/management/organizations/${organization}/operations-summary?branch_id=${branch}`,"manager")).status,403);
  });
});
