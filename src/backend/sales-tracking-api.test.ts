import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { ChecklistAccessError, ChecklistConflictError, ChecklistInputError } from "./checklist-persistence";
import { managementSalesTrackingMonthlySummarySchema } from "../lib/contracts/management-sales-tracking-monthly";

const supervisor="16000000-0000-4000-8000-000000000001",manager="16000000-0000-4000-8000-000000000002",otherManager="16000000-0000-4000-8000-000000000003";
const branch="26000000-0000-4000-8000-000000000001",otherBranch="26000000-0000-4000-8000-000000000002",org="36000000-0000-4000-8000-000000000001";
const calls:Array<{name:string;input:unknown}>=[];
let currentSalesRows:Array<Record<string,unknown>>=[];
let currentCashRows:Array<Record<string,unknown>>=[];
let currentPeriods:Array<{id:string;entry_period:"middle_shift"|"closing_shift";entered_by_user_id:string;entered_by_name:string;entered_at:string}>=[];
let currentRevision=0;
let currentState:"draft"|"submitted"="draft";
let submittedAt:string|null=null;
let submittedByUserId:string|null=null;
let submittedByNameSnapshot:string|null=null;
let malformedManagedSalesTracking=false;
let malformedMonthlySummary=false;
const replay=new Map<string,string>();
let providers:Array<Record<string,unknown>>=[];

function numeric(value:unknown){
  const number=typeof value==="number"?value:Number(value);
  return Number.isFinite(number)?number:0;
}

function providerFor(id:unknown){
  return providers.find((provider)=>provider.id===id);
}

function managerProviderBreakdown(row:Record<string,unknown>){
  return (Array.isArray(row.online_amounts)?row.online_amounts:[]).filter((amount)=>numeric((amount as Record<string,unknown>).amount)!==0).map((amount)=>{
    const provider=providerFor((amount as Record<string,unknown>).provider_id);
    return {
      provider_id:(amount as Record<string,unknown>).provider_id,
      provider_key:provider?.default_provider_key??null,
      provider_name:provider?.name??"Unknown",
      amount:(amount as Record<string,unknown>).amount,
    };
  });
}

function current(){
  const sumSales=(field:string)=>currentSalesRows.reduce((total,row)=>total+numeric(row[field]),0);
  const cashTotal=currentCashRows.reduce((total,row)=>total+Number(row.denom_1)+Number(row.denom_2)*2+Number(row.denom_5)*5+Number(row.denom_10)*10+Number(row.denom_20)*20+Number(row.denom_50)*50+Number(row.denom_100)*100+Number(row.denom_200)*200+Number(row.denom_500)*500,0);
  return {
    report_id:currentRevision===0?null:"56000000-0000-4000-8000-000000000001",
    business_date:"2026-08-08",
    state:currentState,
    revision:currentRevision,
    submitted_at:submittedAt,
    submitted_by_user_id:submittedByUserId,
    submitted_by_name_snapshot:submittedByNameSnapshot,
    periods:currentPeriods,
    sales_rows:currentSalesRows.map((row)=>({
      ...row,
      online_amounts:(Array.isArray(row.online_amounts)?row.online_amounts:[]).map((amount)=>({
        ...(amount as Record<string,unknown>),
        provider_name:providerFor((amount as Record<string,unknown>).provider_id)?.name??"Unknown",
      })),
      actual_total:numeric(row.actual_cash)+numeric(row.actual_credit)+numeric(row.online_delivery),
      pos_total:numeric(row.pos_cash)+numeric(row.pos_credit)+numeric(row.online_delivery),
      variance:numeric(row.actual_cash)+numeric(row.actual_credit)-numeric(row.pos_cash)-numeric(row.pos_credit),
    })),
    cash_rows:currentCashRows.map((row)=>({
      ...row,
      cash_total:Number(row.denom_1)+Number(row.denom_2)*2+Number(row.denom_5)*5+Number(row.denom_10)*10+Number(row.denom_20)*20+Number(row.denom_50)*50+Number(row.denom_100)*100+Number(row.denom_200)*200+Number(row.denom_500)*500,
    })),
    totals:{actual_cash:sumSales("actual_cash"),actual_credit:sumSales("actual_credit"),pos_cash:sumSales("pos_cash"),pos_credit:sumSales("pos_credit"),online_delivery:sumSales("online_delivery"),actual_total:sumSales("actual_cash")+sumSales("actual_credit")+sumSales("online_delivery"),pos_total:sumSales("pos_cash")+sumSales("pos_credit")+sumSales("online_delivery"),variance:sumSales("actual_cash")+sumSales("actual_credit")-sumSales("pos_cash")-sumSales("pos_credit"),cash_total:cashTotal,remaining_cash:currentCashRows.reduce((total,row)=>total+numeric(row.remaining_cash),0)},
  };
}

const persistence={
 async getOverview(){throw new Error("unused");},async getManagementOverview(){throw new Error("unused");},
 async getCurrentState(){throw new Error("unused");},async saveDraft(){throw new Error("unused");},async saveHygieneDraft(){throw new Error("unused");},
 async submitOpening(){throw new Error("unused");},async submitHygiene(){throw new Error("unused");},
 async getOilTrackingCurrentState(){throw new Error("unused");},async saveOilTrackingDraft(){throw new Error("unused");},async submitOilTrackingOpening(){throw new Error("unused");},async submitOilTrackingClosing(){throw new Error("unused");},
 async getColdStorageCurrentState(){throw new Error("unused");},async saveColdStorageDraft(){throw new Error("unused");},async submitColdStorageSlot(){throw new Error("unused");},
 async listSupervisor(){throw new Error("unused");},async getReport(){throw new Error("unused");},async listManagedReports(){throw new Error("unused");},async listManagedIssues(){throw new Error("unused");},async getManagedIssue(){throw new Error("unused");},
 async getSalesTrackingCurrentState(actorUserId:string,branchId:string){calls.push({name:"sales-current",input:{actorUserId,branchId}});if(branchId!==branch)throw new ChecklistAccessError();return current();},
 async listSalesTrackingOnlineOrderProviders(actorUserId:string,branchId:string){
  calls.push({name:"sales-online-providers",input:{actorUserId,branchId}});
  if(branchId!==branch)throw new ChecklistAccessError();
  return{providers};
 },
 async createSalesTrackingOnlineOrderProvider(input:{actorUserId:string;branchId:string;name:string}){
  calls.push({name:"sales-online-provider-create",input});
  if(input.branchId!==branch)throw new ChecklistAccessError();
  const name=input.name.trim().replace(/\s+/gu," ");
  const normalized=name.toLowerCase();
  if(providers.some((provider)=>provider.normalized_name===normalized))throw new ChecklistConflictError();
  const provider={id:"57000000-0000-4000-8000-000000000099",organization_id:org,branch_id:branch,name,normalized_name:normalized,default_provider_key:null,is_default:false,active:true,created_by:input.actorUserId,created_at:"2026-08-08T10:00:00.000Z",updated_at:"2026-08-08T10:00:00.000Z"};
  providers.push(provider);
  return{provider};
 },
 async saveSalesTrackingDraft(input:{actorUserId:string;branchId:string;expectedRevision:number;entryPeriod:"middle_shift"|"closing_shift";payload:{sales_rows:Array<Record<string,unknown>>;cash_rows:Array<{entry_date:string;denominations:Record<string,number>;remaining_cash:unknown;remarks:string}>}}){
  calls.push({name:"sales-draft",input});
  if(input.branchId!==branch)throw new ChecklistAccessError();
  if(currentState==="submitted"||input.expectedRevision!==currentRevision||currentPeriods.some((period)=>period.entry_period===input.entryPeriod))throw new ChecklistConflictError();
  if(input.entryPeriod==="middle_shift"&&currentPeriods.some((period)=>period.entry_period==="closing_shift"))throw new ChecklistConflictError();
  const attribution={entry_period:input.entryPeriod,entered_by_user_id:supervisor,entered_by_name:"S",entered_at:"2026-08-08T10:00:00.000Z"};
  currentPeriods.push({id:`56000000-0000-4000-8000-00000000030${currentPeriods.length}`,...attribution});
  currentRevision+=1;
  currentSalesRows.push(...input.payload.sales_rows.map((row)=>({...row,...attribution})));
  currentCashRows.push(...input.payload.cash_rows.map((row)=>({
    entry_date:row.entry_date,
    denom_1:row.denominations["1"],
    denom_2:row.denominations["2"],
    denom_5:row.denominations["5"],
    denom_10:row.denominations["10"],
    denom_20:row.denominations["20"],
    denom_50:row.denominations["50"],
    denom_100:row.denominations["100"],
    denom_200:row.denominations["200"],
    denom_500:row.denominations["500"],
    remaining_cash:row.remaining_cash,
    remarks:row.remarks,
    ...attribution,
  })));
  return current();
 },
 async submitSalesTracking(input:{actorUserId:string;branchId:string;expectedRevision:number;idempotencyKey:string}){
  calls.push({name:"sales-submit",input});
  if(input.branchId!==branch)throw new ChecklistAccessError();
  const hash=String(input.expectedRevision);
  const existing=replay.get(input.idempotencyKey);
  if(existing&&existing!==hash)throw new ChecklistConflictError();
  if(existing)return current();
  if(currentState==="submitted"||input.expectedRevision!==currentRevision)throw new ChecklistConflictError();
  if(!currentPeriods.some((period)=>period.entry_period==="closing_shift")||currentPeriods.length>2)throw new ChecklistInputError();
  replay.set(input.idempotencyKey,hash);
  currentState="submitted";
  currentRevision+=1;
  submittedAt="2026-08-08T12:00:00.000Z";
  submittedByUserId=supervisor;
  submittedByNameSnapshot="S";
  return current();
 },
 async listManagedSalesTrackingReports(input:{actorUserId:string;organizationId:string;dateFrom?:string|null;dateTo?:string|null;branchId?:string|null}){
  calls.push({name:"managed-sales-tracking",input});
  if(input.actorUserId!==manager||input.organizationId!==org)throw new ChecklistAccessError();
  if(malformedManagedSalesTracking)return{sales_rows:[{bad:"shape"}],cash_rows:[]};
  const base={report_id:"56000000-0000-4000-8000-000000000001",business_date:"2026-08-08",branch_id:branch,branch_name:"A",supervisor_user_id:supervisor,submitted_by:"S",supervisor_team_id:"46000000-0000-4000-8000-000000000001",supervisor_team_name:"S Team",submitted_at:"2026-08-08T12:00:00.000Z"};
  if((input.dateFrom&&input.dateFrom>base.business_date)||(input.dateTo&&input.dateTo<base.business_date)||input.branchId&&input.branchId!==branch)return{sales_rows:[],cash_rows:[]};
  return {
    sales_rows:currentState==="submitted"?currentSalesRows.map((row,index)=>({
      ...base,row_id:`56000000-0000-4000-8000-00000000010${index}`,entry_date:row.entry_date,entry_period:row.entry_period,entered_by:row.entered_by_name,entered_at:row.entered_at,actual_cash:row.actual_cash,actual_credit:row.actual_credit,pos_cash:row.pos_cash,pos_credit:row.pos_credit,online_delivery:row.online_delivery,online_provider_breakdown:managerProviderBreakdown(row),
      actual_total:numeric(row.actual_cash)+numeric(row.actual_credit)+numeric(row.online_delivery),
      pos_total:numeric(row.pos_cash)+numeric(row.pos_credit)+numeric(row.online_delivery),
      variance:numeric(row.actual_cash)+numeric(row.actual_credit)-numeric(row.pos_cash)-numeric(row.pos_credit),
      remarks:row.remarks,
    })):[],
    cash_rows:currentState==="submitted"?currentCashRows.map((row,index)=>({
      ...base,row_id:`56000000-0000-4000-8000-00000000020${index}`,entry_date:row.entry_date,entry_period:row.entry_period,entered_by:row.entered_by_name,entered_at:row.entered_at,denom_1:row.denom_1,denom_2:row.denom_2,denom_5:row.denom_5,denom_10:row.denom_10,denom_20:row.denom_20,denom_50:row.denom_50,denom_100:row.denom_100,denom_200:row.denom_200,denom_500:row.denom_500,remaining_cash:row.remaining_cash,remarks:row.remarks,
      cash_total:Number(row.denom_1)+Number(row.denom_2)*2+Number(row.denom_5)*5+Number(row.denom_10)*10+Number(row.denom_20)*20+Number(row.denom_50)*50+Number(row.denom_100)*100+Number(row.denom_200)*200+Number(row.denom_500)*500,
    })):[],
  };
 },
 async getManagedSalesTrackingMonthlySummary(input:{actorUserId:string;organizationId:string;month:string;branchId?:string|null}){
  calls.push({name:"managed-sales-tracking-monthly",input});
  if(input.actorUserId!==manager||input.organizationId!==org||input.branchId===otherBranch)throw new ChecklistAccessError();
  if(malformedMonthlySummary)return{bad:"shape"};
  const empty=input.month==="2026-09";
  const metrics={
    submitted_report_count:empty?0:2,submitted_day_count:empty?0:1,sales_entry_count:empty?0:2,cash_entry_count:empty?0:1,
    total_sales:empty?"0":"10498.00",total_cash_collected:empty?"0":"1000.00",total_variance:"0.00",
    balanced_sales_report_count:empty?0:2,variance_sales_report_count:0,
    payment_breakdown:{actual_cash:empty?"0":"324.00",actual_credit:empty?"0":"7190.00",online_delivery:empty?"0":"2984.00",pos_cash:empty?"0":"324.00",pos_credit:empty?"0":"7190.00"},
    online_provider_breakdown:empty?[]:[{provider_id:"57000000-0000-4000-8000-000000000001",provider_key:"jahez",provider_name:"Jahez",amount:"1800.00"},{provider_id:"57000000-0000-4000-8000-000000000003",provider_key:"hungerstation",provider_name:"HungerStation",amount:"1184.00"}],
    legacy_online_delivery:empty?"0":"0",
  };
  const {submitted_day_count,...totalMetrics}=metrics;
  return {
    generated_at:"2026-08-11T12:00:00.000Z",
    scope:{organization_id:org,branch_id:input.branchId??null,month:input.month,date_from:`${input.month}-01`,date_to:input.month==="2026-09"?"2026-09-30":"2026-08-31"},
    totals:{...totalMetrics,submitted_branch_day_count:submitted_day_count,reporting_branch_count:empty?0:1},
    branches:empty?[]:[{...metrics,branch_id:branch,branch_name:"A",branch_name_ar:"الفرع أ",branch_code:"A"}],
  };
 },
};

function deps():BackendDependencies{return{checkReadiness:async()=>true,checklistPersistence:persistence,passwordChange:{verifyCurrent:async()=>true,updatePassword:async()=>{},finalize:async()=>{}},provisioningAdmin:{createUser:async()=>({id:supervisor}),deleteUser:async()=>{},finalize:async()=>{}},managementAdmin:{listUsers:async()=>({users:[],total:0})},branchManagementAdmin:{listBranches:async()=>[],listStaff:async()=>[],getPinMetadata:async()=>({configured:false,updated_at:null,updated_by_name:null}),storePin:async()=>({configured:false,updated_at:null,updated_by_name:null}),getPinCredential:async()=>null},pinCrypto:{hash:async()=>({pin_hash:"x",salt:"x",kdf_version:1,cost:1,block_size:1,parallelization:1}),verify:async()=>false,issueGrant:()=>"",verifyGrant:()=>false},authVerifier:{verify:async token=>token==="supervisor"?{userId:supervisor,email:"s@example.invalid"}:token==="manager"?{userId:manager,email:"m@example.invalid"}:token==="other-manager"?{userId:otherManager,email:"om@example.invalid"}:null},createUserContext:token=>({getUserContext:async()=>token==="supervisor"?{id:supervisor,full_name:"S",must_change_password:false,disabled:false,branches:[{id:branch,name:"A",organization_id:org,role:"branch_manager"}],managed_organizations:[]}:{id:token==="manager"?manager:otherManager,full_name:"M",must_change_password:false,disabled:false,branches:[],managed_organizations:token==="manager"?[{id:org,name:"O",role:"organization_manager"}]:[{id:"36000000-0000-4000-8000-000000000099",name:"Other",role:"organization_manager"}]},hasOrganizationManagerAccess:async(_userId:string,organizationId:string)=>token==="manager"&&organizationId===org,validateActiveBranches:async(organizationId:string,branchIds:string[])=>token==="manager"&&organizationId===org&&branchIds.every((id)=>id===branch),listActiveBranches:async()=>[]})};}
const config:BackendConfig={nodeEnv:"test",host:"127.0.0.1",port:1,trustProxy:false,supabase:{url:"http://127.0.0.1",publishableKey:"test",secretKey:"test"},dailyAuditGrantSecret:"test-placeholder-long-enough-for-tests"};
let server:Server,origin:string;
async function request(path:string,token?:string,init:RequestInit={}){return fetch(origin+path,{...init,headers:{...(token?{Authorization:`Bearer ${token}`}:{"x-no-auth":"1"}),...(init.headers??{})}});}

const draftPayload={
  expected_revision:0,
  entry_period:"middle_shift" as const,
  sales_rows:[{
    entry_date:"2026-08-08",
    actual_cash:"162.00",
    actual_credit:"3595.00",
    pos_cash:"162.00",
    pos_credit:"3595.00",
    online_delivery:"1492.00",
    remarks:"",
  }],
  cash_rows:[{
    entry_date:"2026-08-08",
    denominations:{"1":8,"2":1,"5":24,"10":3,"20":2,"50":2,"100":0,"200":1,"500":1},
    remaining_cash:"100.00",
    remarks:"",
  }],
};
const closingPayload={...draftPayload,expected_revision:1,entry_period:"closing_shift" as const,sales_rows:[{...draftPayload.sales_rows[0],actual_cash:"30.00",actual_credit:"20.00",pos_cash:"30.00",pos_credit:"20.00",online_delivery:"5.00"}],cash_rows:[{...draftPayload.cash_rows[0],remaining_cash:"50.00"}]};

async function saveBothPeriods(){
  const path=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`;
  assert.equal((await request(path,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(draftPayload)})).status,200);
  assert.equal((await request(path,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(closingPayload)})).status,200);
}

async function submitSavedDay(idempotencyKey:string,expectedRevision=2){
  await saveBothPeriods();
  return request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":idempotencyKey},body:JSON.stringify({expected_revision:expectedRevision})});
}

describe("Sales Tracking API integration",()=>{
 before(async()=>{server=createServer(createApp(config,deps()));await new Promise<void>((resolve,reject)=>server.listen(0,"127.0.0.1",resolve).once("error",reject));origin=`http://127.0.0.1:${(server.address()as AddressInfo).port}`;});
 after(()=>new Promise<void>(resolve=>server.close(()=>resolve())));
 beforeEach(()=>{calls.length=0;currentSalesRows=[];currentCashRows=[];currentPeriods=[];currentRevision=0;currentState="draft";submittedAt=null;submittedByUserId=null;submittedByNameSnapshot=null;malformedManagedSalesTracking=false;malformedMonthlySummary=false;replay.clear();providers=[
  {id:"57000000-0000-4000-8000-000000000001",organization_id:org,branch_id:branch,name:"Jahez",normalized_name:"jahez",default_provider_key:"jahez",is_default:true,active:true,created_by:null,created_at:"2026-08-08T10:00:00.000Z",updated_at:"2026-08-08T10:00:00.000Z"},
  {id:"57000000-0000-4000-8000-000000000003",organization_id:org,branch_id:branch,name:"HungerStation",normalized_name:"hungerstation",default_provider_key:"hungerstation",is_default:true,active:true,created_by:null,created_at:"2026-08-08T10:00:00.000Z",updated_at:"2026-08-08T10:00:00.000Z"},
  {id:"57000000-0000-4000-8000-000000000002",organization_id:org,branch_id:branch,name:"Ninja",normalized_name:"ninja",default_provider_key:"ninja",is_default:true,active:true,created_by:null,created_at:"2026-08-08T10:00:00.000Z",updated_at:"2026-08-08T10:00:00.000Z"},
  {id:"57000000-0000-4000-8000-000000000004",organization_id:org,branch_id:branch,name:"The Chef",normalized_name:"the chef",default_provider_key:"the_chef",is_default:true,active:true,created_by:null,created_at:"2026-08-08T10:00:00.000Z",updated_at:"2026-08-08T10:00:00.000Z"},
  {id:"57000000-0000-4000-8000-000000000005",organization_id:org,branch_id:branch,name:"Try Order",normalized_name:"try order",default_provider_key:"try_order",is_default:true,active:true,created_by:null,created_at:"2026-08-08T10:00:00.000Z",updated_at:"2026-08-08T10:00:00.000Z"},
 ];});

 it("requires authentication and forbids Manager authority",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/current-state`;
  assert.equal((await request(path)).status,401);
  assert.equal((await request(path,"manager")).status,403);
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"manager",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"66000000-0000-4000-8000-000000000000"},body:JSON.stringify({expected_revision:0})})).status,403);
 });
 it("returns empty current state for a Supervisor",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/current-state`,"supervisor");
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{current:{report_id:null,business_date:"2026-08-08",state:"draft",revision:0,submitted_at:null,submitted_by_user_id:null,submitted_by_name_snapshot:null,periods:[],sales_rows:[],cash_rows:[],totals:{actual_cash:0,actual_credit:0,pos_cash:0,pos_credit:0,online_delivery:0,actual_total:0,pos_total:0,variance:0,cash_total:0,remaining_cash:0}}});
 });
 it("lists default Online Order providers for a Supervisor branch",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/online-order-providers`,"supervisor");
  assert.equal(response.status,200);
  const body=await response.json();
  assert.deepEqual(body.providers.map((provider:Record<string,unknown>)=>provider.name),["Jahez","HungerStation","Ninja","The Chef","Try Order"]);
  assert.deepEqual(calls.at(-1),{name:"sales-online-providers",input:{actorUserId:supervisor,branchId:branch}});
 });
 it("creates custom Online Order providers with normalized duplicate protection",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/online-order-providers`;
  const created=await request(path,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:"  Quick   Eats  "})});
  assert.equal(created.status,201);
  assert.equal((await created.json()).provider.name,"Quick Eats");
  assert.deepEqual(calls.at(-1),{name:"sales-online-provider-create",input:{actorUserId:supervisor,branchId:branch,name:"Quick Eats"}});
  const duplicate=await request(path,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:" JAHEZ "})});
  assert.equal(duplicate.status,409);
  assert.doesNotMatch(JSON.stringify(await duplicate.json()),/Supabase|database|sales-online-provider-create/i);
 });
 it("protects Online Order provider routes from managers and other branches",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/online-order-providers`;
  assert.equal((await request(path)).status,401);
  assert.equal((await request(path,"manager")).status,403);
  assert.equal((await request(`/api/v1/supervisor/branches/${otherBranch}/checklists/sales_tracking/online-order-providers`,"supervisor")).status,403);
  assert.equal((await request(path,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({name:""})})).status,400);
 });
 it("saves a normalized draft and returns computed totals",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(draftPayload)});
  assert.equal(response.status,200);
  const input=calls.at(-1)?.input as {payload:{sales_rows:Array<Record<string,unknown>>;cash_rows:Array<{denominations:Record<string,number>}>}};
  assert.equal(input.payload.sales_rows[0].actual_cash,"162.00");
  assert.equal(input.payload.sales_rows[0].actual_credit,"3595.00");
  assert.equal(input.payload.sales_rows[0].pos_cash,"162.00");
  assert.equal(input.payload.sales_rows[0].pos_credit,"3595.00");
  assert.equal(input.payload.sales_rows[0].online_delivery,"1492.00");
  assert.equal(input.payload.cash_rows[0].denominations["500"],1);
  const body=await response.json();
  assert.equal(body.current.report_id,"56000000-0000-4000-8000-000000000001");
  assert.equal(body.current.sales_rows[0].actual_total,5249);
  assert.equal(body.current.sales_rows[0].pos_total,5249);
  assert.equal(body.current.sales_rows[0].variance,0);
  assert.equal(body.current.cash_rows[0].cash_total,1000);
  assert.equal(body.current.totals.actual_total,5249);
  assert.equal(body.current.totals.cash_total,1000);
  assert.deepEqual(body.current.cash_rows[0].denominations,{"1":8,"2":1,"5":24,"10":3,"20":2,"50":2,"100":0,"200":1,"500":1});
 });
 it("saves provider amounts as the Online Delivery aggregate and restores breakdown",async()=>{
  const payload={...draftPayload,sales_rows:[{...draftPayload.sales_rows[0],online_delivery:"999.00",online_amounts:[{provider_id:"57000000-0000-4000-8000-000000000001",amount:"100.00"},{provider_id:"57000000-0000-4000-8000-000000000002",amount:"50.00"}]}]};
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)});
  assert.equal(response.status,200);
  const input=calls.at(-1)?.input as {payload:{sales_rows:Array<Record<string,unknown>>}};
  assert.deepEqual(input.payload.sales_rows[0].online_amounts,[{provider_id:"57000000-0000-4000-8000-000000000001",amount:"100.00"},{provider_id:"57000000-0000-4000-8000-000000000002",amount:"50.00"}]);
  const body=await response.json();
  assert.equal(body.current.sales_rows[0].online_delivery,"150");
  assert.deepEqual(body.current.sales_rows[0].online_amounts.map((amount:Record<string,unknown>)=>[amount.provider_name,amount.amount]),[["Jahez","100.00"],["Ninja","50.00"]]);
 });
 it("restores saved sales and cash rows from current state",async()=>{
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(draftPayload)})).status,200);
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/current-state`,"supervisor");
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.current.sales_rows[0].entry_date,"2026-08-08");
  assert.equal(body.current.cash_rows[0].remaining_cash,"100.00");
 });
 it("rejects invalid payloads and unknown fields",async()=>{
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({sales_rows:[{...draftPayload.sales_rows[0],extra:"nope"}],cash_rows:[]})})).status,400);
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({sales_rows:"bad",cash_rows:[]})})).status,400);
 });
 it("rejects negative numeric values",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({...draftPayload,sales_rows:[{...draftPayload.sales_rows[0],actual_cash:"-1"}],cash_rows:[]})});
  assert.equal(response.status,400);
 });
 it("rejects non-integer denomination counts",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({...draftPayload,sales_rows:[],cash_rows:[{...draftPayload.cash_rows[0],denominations:{...draftPayload.cash_rows[0].denominations,"5":1.5}}]})});
  assert.equal(response.status,400);
 });
 it("requires a valid idempotency key for submit",async()=>{
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({expected_revision:0})})).status,400);
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"not-a-uuid"},body:JSON.stringify({expected_revision:0})})).status,400);
 });
 it("rejects daily submit when no period is saved",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"66000000-0000-4000-8000-000000000096"},body:JSON.stringify({expected_revision:0})});
  assert.equal(response.status,422);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|periods incomplete/i);
 });
 it("rejects Middle-only daily submit",async()=>{
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(draftPayload)})).status,200);
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"66000000-0000-4000-8000-000000000099"},body:JSON.stringify({expected_revision:1})});
  assert.equal(response.status,422);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|periods incomplete/i);
 });
 it("submits a Closing-only day and keeps it immutable",async()=>{
  const draftPath=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`;
  assert.equal((await request(draftPath,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({...closingPayload,expected_revision:0})})).status,200);
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"66000000-0000-4000-8000-000000000097"},body:JSON.stringify({expected_revision:1})});
  assert.equal(response.status,201);
  const body=await response.json();
  assert.deepEqual(body.current.periods.map((period:Record<string,unknown>)=>period.entry_period),["closing_shift"]);
  assert.equal((await request(draftPath,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({...draftPayload,expected_revision:2})})).status,409);
 });
 it("rejects a new Middle period after Closing is saved before final submit",async()=>{
  const draftPath=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`;
  assert.equal((await request(draftPath,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({...closingPayload,expected_revision:0})})).status,200);
  const response=await request(draftPath,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({...draftPayload,expected_revision:1})});
  assert.equal(response.status,409);
  assert.deepEqual(currentPeriods.map((period)=>period.entry_period),["closing_shift"]);
 });
 it("serializes concurrent duplicate Middle and duplicate Closing periods",async()=>{
  const draftPath=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`;
  const middleResponses=await Promise.all([draftPayload,draftPayload].map((payload)=>request(draftPath,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})));
  assert.deepEqual(middleResponses.map((response)=>response.status).sort(),[200,409]);
  const closingResponses=await Promise.all([closingPayload,closingPayload].map((payload)=>request(draftPath,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})));
  assert.deepEqual(closingResponses.map((response)=>response.status).sort(),[200,409]);
  assert.deepEqual(currentPeriods.map((period)=>period.entry_period),["middle_shift","closing_shift"]);
 });
 it("submits once and returns submitted current state",async()=>{
  const response=await submitSavedDay("66000000-0000-4000-8000-000000000001");
  assert.equal(response.status,201);
  const body=await response.json();
  assert.equal(body.current.state,"submitted");
  assert.equal(body.current.submitted_at,"2026-08-08T12:00:00.000Z");
  assert.equal(body.current.submitted_by_user_id,supervisor);
  assert.equal(body.current.submitted_by_name_snapshot,"S");
  assert.equal(body.current.report_id,"56000000-0000-4000-8000-000000000001");
  assert.equal(body.current.sales_rows[0].actual_total,5249);
  assert.equal(body.current.cash_rows[0].cash_total,1000);
  assert.equal(calls.at(-1)?.name,"sales-submit");
 });
 it("replays the same daily submit and rejects changed revision",async()=>{
  const path=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`;
  const headers={"Content-Type":"application/json","Idempotency-Key":"66000000-0000-4000-8000-000000000002"};
  await saveBothPeriods();
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({expected_revision:2})})).status,201);
  assert.equal((await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({expected_revision:2})})).status,201);
  const response=await request(path,"supervisor",{method:"POST",headers,body:JSON.stringify({expected_revision:3})});
  assert.equal(response.status,409);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|sales-submit/i);
 });
 it("rejects a subsequent different submit for the same day",async()=>{
  assert.equal((await submitSavedDay("66000000-0000-4000-8000-000000000003")).status,201);
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"66000000-0000-4000-8000-000000000004"},body:JSON.stringify({expected_revision:3})})).status,409);
 });
 it("current state after submit returns submitted rows",async()=>{
  assert.equal((await submitSavedDay("66000000-0000-4000-8000-000000000005")).status,201);
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/current-state`,"supervisor");
  const body=await response.json();
  assert.equal(body.current.state,"submitted");
  assert.equal(body.current.sales_rows[0].entry_date,"2026-08-08");
  assert.equal(body.current.cash_rows[0].remaining_cash,"100.00");
 });
 it("draft save after submit does not overwrite submitted state",async()=>{
  assert.equal((await submitSavedDay("66000000-0000-4000-8000-000000000006")).status,201);
  const changed={...draftPayload,expected_revision:3,sales_rows:[{...draftPayload.sales_rows[0],actual_cash:"999.00"}]};
  const response=await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(changed)});
  assert.equal(response.status,409);
  assert.equal(currentSalesRows[0].actual_cash,"162.00");
 });
 it("maps forbidden other branch or team access to safe 403",async()=>{
  const response=await request(`/api/v1/supervisor/branches/${otherBranch}/checklists/sales_tracking/current-state`,"supervisor");
  assert.equal(response.status,403);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|sales-current/i);
 });
 it("returns submitted Sales Tracking rows to an Organization Manager",async()=>{
  assert.equal((await submitSavedDay("66000000-0000-4000-8000-000000000007")).status,201);
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking`,"manager");
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.sales_rows[0].branch_name,"A");
  assert.equal(body.sales_rows[0].actual_total,5249);
  assert.equal(body.sales_rows[0].pos_total,5249);
  assert.equal(body.sales_rows[0].variance,0);
 assert.deepEqual(body.cash_rows[0].denominations,{"1":8,"2":1,"5":24,"10":3,"20":2,"50":2,"100":0,"200":1,"500":1});
  assert.equal(body.cash_rows[0].cash_total,1000);
  assert.equal(calls.at(-1)?.name,"managed-sales-tracking");
 });
 it("returns read-only Manager online provider breakdown without changing aggregate totals",async()=>{
  providers.push({id:"57000000-0000-4000-8000-000000000099",organization_id:org,branch_id:branch,name:"Keeta",normalized_name:"keeta",default_provider_key:null,is_default:false,active:true,created_by:supervisor,created_at:"2026-08-08T10:00:00.000Z",updated_at:"2026-08-08T10:00:00.000Z"});
  const middle={...draftPayload,sales_rows:[{...draftPayload.sales_rows[0],online_delivery:"999.00",online_amounts:[{provider_id:"57000000-0000-4000-8000-000000000001",amount:"100.00"},{provider_id:"57000000-0000-4000-8000-000000000003",amount:"25.00"}]}]};
  const closing={...closingPayload,sales_rows:[{...closingPayload.sales_rows[0],online_delivery:"999.00",online_amounts:[{provider_id:"57000000-0000-4000-8000-000000000001",amount:"250.00"},{provider_id:"57000000-0000-4000-8000-000000000099",amount:"40.00"}]}]};
  const path=`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/draft`;
  assert.equal((await request(path,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(middle)})).status,200);
  assert.equal((await request(path,"supervisor",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(closing)})).status,200);
  assert.equal((await request(`/api/v1/supervisor/branches/${branch}/checklists/sales_tracking/submit`,"supervisor",{method:"POST",headers:{"Content-Type":"application/json","Idempotency-Key":"66000000-0000-4000-8000-000000000018"},body:JSON.stringify({expected_revision:2})})).status,201);
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking`,"manager");
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.sales_rows.length,2);
  assert.deepEqual(body.sales_rows[0].online_provider_breakdown.map((amount:Record<string,unknown>)=>[amount.provider_name,amount.amount]),[["Jahez","100.00"],["HungerStation","25.00"]]);
  assert.deepEqual(body.sales_rows[1].online_provider_breakdown.map((amount:Record<string,unknown>)=>[amount.provider_name,amount.amount]),[["Jahez","250.00"],["Keeta","40.00"]]);
  assert.equal(body.sales_rows.reduce((sum:number,row:Record<string,unknown>)=>sum+numeric(row.online_delivery),0),415);
  assert.equal(body.sales_rows[0].actual_total,3882);
  assert.equal(body.sales_rows[0].pos_total,3882);
  assert.equal(body.sales_rows[0].variance,0);
 });
 it("filters Manager Sales Tracking by server-side date range and branch",async()=>{
  assert.equal((await submitSavedDay("66000000-0000-4000-8000-000000000017")).status,201);
  const bounded=await request(`/api/v1/management/organizations/${org}/sales-tracking?date_from=2026-08-08&date_to=2026-08-08&branch_id=${branch}`,"manager");
  assert.equal(bounded.status,200);
  assert.equal((await bounded.json()).sales_rows.length,2);
  assert.deepEqual(calls.at(-1),{name:"managed-sales-tracking",input:{actorUserId:manager,organizationId:org,dateFrom:"2026-08-08",dateTo:"2026-08-08",branchId:branch}});
  const outside=await request(`/api/v1/management/organizations/${org}/sales-tracking?date_from=2026-08-09&date_to=2026-08-09&branch_id=${branch}`,"manager");
  assert.equal(outside.status,200);
  assert.deepEqual(await outside.json(),{sales_rows:[],cash_rows:[]});
 });
 it("rejects a cross-organization branch filter for Manager Sales Tracking",async()=>{
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking?branch_id=${otherBranch}`,"manager");
  assert.equal(response.status,403);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Supabase|database|sales-tracking/i);
 });
 it("returns empty Manager Sales Tracking rows when no reports are submitted",async()=>{
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking`,"manager");
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{sales_rows:[],cash_rows:[]});
 });
 it("denies non-manager access to Manager Sales Tracking reports",async()=>{
  assert.equal((await request(`/api/v1/management/organizations/${org}/sales-tracking`)).status,401);
  assert.equal((await request(`/api/v1/management/organizations/${org}/sales-tracking`,"supervisor")).status,403);
  assert.equal((await request(`/api/v1/management/organizations/${org}/sales-tracking`,"other-manager")).status,403);
 });
 it("fails safe for malformed Manager Sales Tracking responses and invalid filters",async()=>{
  assert.equal((await request(`/api/v1/management/organizations/${org}/sales-tracking?date_from=bad`,"manager")).status,400);
  malformedManagedSalesTracking=true;
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking`,"manager");
  assert.equal(response.status,503);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Zod|Supabase|managed-sales-tracking/i);
 });
 it("returns a safe Manager monthly Sales Tracking aggregate",async()=>{
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking/monthly-summary?month=2026-08&branch_id=${branch}`,"manager");
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(managementSalesTrackingMonthlySummarySchema.safeParse(body).success,true);
  assert.equal(body.totals.total_sales,"10498.00");
  assert.equal(body.totals.total_cash_collected,"1000.00");
  assert.equal(body.totals.submitted_report_count,2);
  assert.equal(body.totals.submitted_branch_day_count,1);
  assert.deepEqual(body.totals.online_provider_breakdown.map((amount:Record<string,unknown>)=>[amount.provider_name,amount.amount]),[["Jahez","1800.00"],["HungerStation","1184.00"]]);
  assert.equal(body.totals.legacy_online_delivery,"0");
  assert.equal(body.totals.payment_breakdown.online_delivery,"2984.00");
  assert.deepEqual(body.branches[0].online_provider_breakdown.map((amount:Record<string,unknown>)=>[amount.provider_name,amount.amount]),[["Jahez","1800.00"],["HungerStation","1184.00"]]);
  assert.deepEqual(calls.at(-1),{name:"managed-sales-tracking-monthly",input:{actorUserId:manager,organizationId:org,month:"2026-08",branchId:branch}});
  assert.doesNotMatch(JSON.stringify(body),/supervisor_user_id|remarks|notes|storage|filename/i);
 });
 it("returns zero monthly totals and branches for an empty month",async()=>{
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking/monthly-summary?month=2026-09`,"manager");
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.totals.submitted_report_count,0);
  assert.equal(body.totals.total_sales,"0");
  assert.deepEqual(body.branches,[]);
 });
 it("protects and validates the Manager monthly Sales Tracking route",async()=>{
  const path=`/api/v1/management/organizations/${org}/sales-tracking/monthly-summary?month=2026-08`;
  assert.equal((await request(path)).status,401);
  assert.equal((await request(path,"supervisor")).status,403);
  assert.equal((await request(path,"other-manager")).status,403);
  assert.equal((await request(`/api/v1/management/organizations/${org}/sales-tracking/monthly-summary?month=bad`,"manager")).status,400);
  assert.equal((await request(`/api/v1/management/organizations/${org}/sales-tracking/monthly-summary?month=2026-08&branch_id=${otherBranch}`,"manager")).status,403);
 });
 it("fails safe when the Manager monthly aggregate is malformed",async()=>{
  malformedMonthlySummary=true;
  const response=await request(`/api/v1/management/organizations/${org}/sales-tracking/monthly-summary?month=2026-08`,"manager");
  assert.equal(response.status,503);
  assert.doesNotMatch(JSON.stringify(await response.json()),/Zod|Supabase|managed-sales-tracking-monthly/i);
 });
});
