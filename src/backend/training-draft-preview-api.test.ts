import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach,describe,it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const actor="7f100000-0000-4000-8000-000000000001",organization="7f100000-0000-4000-8000-000000000002",course="7f100000-0000-4000-8000-000000000003",version="7f100000-0000-4000-8000-000000000004";
const config=loadBackendConfig({NODE_ENV:"test",SUPABASE_URL:"http://127.0.0.1:54321",SUPABASE_PUBLISHABLE_KEY:"publishable-test-placeholder",DAILY_AUDIT_GRANT_SECRET:"test-training-preview-secret-placeholder"});
const servers:ReturnType<typeof createServer>[]=[];
const preview={course:{status:"draft",revision:2},instructional_modules:[],final_assessment:{question_count:27,pass_threshold_bps:8000,minimum_correct_count:22,locked:true,submission_available:false}};

function dependencies(internalAdmin=true,calls:Array<Record<string,string>>=[]):BackendDependencies{return{
  authVerifier:{async verify(token){return token==="valid"?{userId:actor,email:"admin@example.invalid"}:null;}},
  async checkReadiness(){return true;},
  createUserContext(){return{async getUserContext(){return null;},async isInternalAdmin(){return internalAdmin;},async hasOrganizationManagerAccess(){return false;},async validateActiveBranches(){return false;},async listActiveBranches(){return[];}};},
  passwordChange:{async verifyCurrent(){return false;},async updatePassword(){},async finalize(){}},
  provisioningAdmin:{async createUser(){return{id:actor};},async deleteUser(){},async finalize(){}},
  managementAdmin:{async listUsers(){return{users:[],total:0};}},
  branchManagementAdmin:{async listBranches(){return[];},async listStaff(){return[];},async getPinMetadata(){throw new Error("unused");},async storePin(){throw new Error("unused");},async getPinCredential(){return null;}},
  pinCrypto:{async hash(){throw new Error("unused");},async verify(){return false;}},
  trainingMediaService:{async getDraftPreview(scope){calls.push(scope);return preview;}} as unknown as NonNullable<BackendDependencies["trainingMediaService"]>,
};}
async function start(deps:BackendDependencies){const server=createServer(createApp(config,deps));servers.push(server);await new Promise<void>(resolve=>server.listen(0,"127.0.0.1",resolve));return`http://127.0.0.1:${(server.address() as AddressInfo).port}`;}
afterEach(async()=>Promise.all(servers.splice(0).map(server=>new Promise<void>(resolve=>server.close(()=>resolve())))));
const path=`/api/v1/internal-admin/organizations/${organization}/training/courses/${course}/versions/${version}/preview`;

describe("Internal Admin Training draft preview API",()=>{
  it("returns a no-store preview using the authenticated actor and exact scope",async()=>{const calls:Array<Record<string,string>>=[],origin=await start(dependencies(true,calls));const response=await fetch(`${origin}${path}`,{headers:{Authorization:"Bearer valid"}});assert.equal(response.status,200);assert.equal(response.headers.get("cache-control"),"private, no-store");assert.deepEqual(calls,[{actorUserId:actor,organizationId:organization,courseId:course,courseVersionId:version}]);const body=await response.text();assert.match(body,/"question_count":27/);assert.doesNotMatch(body,/answer_key|correct_option|explanation|storage_object_path|sha256/i);});
  it("rejects anonymous and non-Internal-Admin access",async()=>{const origin=await start(dependencies(false));assert.equal((await fetch(`${origin}${path}`)).status,401);assert.equal((await fetch(`${origin}${path}`,{headers:{Authorization:"Bearer valid"}})).status,403);});
  it("rejects malformed scope and query input",async()=>{const origin=await start(dependencies());assert.equal((await fetch(`${origin}${path}?extra=true`,{headers:{Authorization:"Bearer valid"}})).status,400);assert.equal((await fetch(`${origin}${path.replace(version,"not-a-uuid")}`,{headers:{Authorization:"Bearer valid"}})).status,400);});
});
