import { createHash } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { managementSalesTrackingMonthlySummarySchema } from "../lib/contracts/management-sales-tracking-monthly";

export class ChecklistConflictError extends Error {}
export class ChecklistInputError extends Error {}
export class ChecklistAccessError extends Error {}
export class ManagementOverviewUnavailableError extends Error {}

export type ChecklistPersistence = {
  getOverview(actorUserId:string,branchId:string):Promise<unknown>;
  getManagementOverview?(actorUserId:string,organizationId:string):Promise<unknown>;
  getCurrentState(actorUserId:string,branchId:string,type:string):Promise<unknown>;
  getHygieneCurrentState?(actorUserId:string,branchId:string,operationalTeamId:string):Promise<unknown>;
  saveDraft(input:{actorUserId:string;branchId:string;type:string;expectedRevision:number;answers:unknown[]}):Promise<unknown>;
  saveHygieneDraft(input:{actorUserId:string;branchId:string;operationalTeamId:string;expectedRevision:number;staff:unknown[]}):Promise<unknown>;
  submitOpening(input:{actorUserId:string;branchId:string;type:string;expectedRevision:number;idempotencyKey:string;answers:unknown[]}):Promise<unknown>;
  submitHygiene(input:{actorUserId:string;branchId:string;operationalTeamId:string;idempotencyKey:string;staff:unknown[]}):Promise<unknown>;
  getOilTrackingCurrentState?(actorUserId:string,branchId:string):Promise<unknown>;
  saveOilTrackingDraft?(input:{actorUserId:string;branchId:string;expectedRevision:number;rows:unknown[]}):Promise<unknown>;
  submitOilTrackingOpening?(input:{actorUserId:string;branchId:string;expectedRevision:number;idempotencyKey:string;rows:unknown[]}):Promise<unknown>;
  submitOilTrackingClosing?(input:{actorUserId:string;branchId:string;expectedRevision:number;idempotencyKey:string;rows:unknown[]}):Promise<unknown>;
  getColdStorageCurrentState?(actorUserId:string,branchId:string):Promise<unknown>;
  saveColdStorageDraft?(input:{actorUserId:string;branchId:string;expectedRevision:number;equipment:unknown[];readings:unknown[]}):Promise<unknown>;
  submitColdStorageSlot?(input:{actorUserId:string;branchId:string;expectedRevision:number;slot:string;idempotencyKey:string;equipment:unknown[];readings:unknown[]}):Promise<unknown>;
  getSalesTrackingCurrentState?(actorUserId:string,branchId:string):Promise<unknown>;
  listSalesTrackingOnlineOrderProviders?(actorUserId:string,branchId:string):Promise<unknown>;
  createSalesTrackingOnlineOrderProvider?(input:{actorUserId:string;branchId:string;name:string}):Promise<unknown>;
  saveSalesTrackingDraft?(input:{actorUserId:string;branchId:string;expectedRevision:number;entryPeriod:"middle_shift"|"closing_shift";payload:SalesTrackingDraftPayload}):Promise<unknown>;
  submitSalesTracking?(input:{actorUserId:string;branchId:string;expectedRevision:number;idempotencyKey:string}):Promise<unknown>;
  getFinancialClosingCurrentState?(actorUserId:string,branchId:string):Promise<unknown>;
  saveFinancialClosingDraft?(input:{actorUserId:string;branchId:string;expectedRevision:number;items:unknown[]}):Promise<unknown>;
  submitFinancialClosing?(input:{actorUserId:string;branchId:string;expectedRevision:number;items:unknown[]}):Promise<unknown>;
  listSupervisorNotifications?(actorUserId:string):Promise<unknown>;
  markSupervisorNotificationRead?(actorUserId:string,notificationId:string):Promise<unknown>;
  getInventoryItemsCurrentState?(actorUserId:string,branchId:string,inventoryMonth?:string|null):Promise<unknown>;
  saveInventoryItemsDraft?(input:{actorUserId:string;branchId:string;payload:InventoryItemsDraftPayload}):Promise<unknown>;
  submitInventoryItems?(input:{actorUserId:string;branchId:string;idempotencyKey:string;payload:InventoryItemsDraftPayload}):Promise<unknown>;
  listManagedSalesTrackingReports?(input:{actorUserId:string;organizationId:string;dateFrom?:string|null;dateTo?:string|null;branchId?:string|null}):Promise<unknown>;
  getManagedSalesTrackingMonthlySummary?(input:{actorUserId:string;organizationId:string;month:string;branchId?:string|null}):Promise<unknown>;
  listManagedInventoryItemsReports?(input:{actorUserId:string;organizationId:string;inventoryMonth:string;branchId?:string|null}):Promise<unknown>;
  listSupervisor(input:{actorUserId:string;branchId:string;page:number;pageSize:number;type?:string}):Promise<unknown>;
  listOilTrackingSupervisor?(input:{actorUserId:string;branchId:string;page:number;pageSize:number}):Promise<unknown>;
  listColdStorageSupervisor?(input:{actorUserId:string;branchId:string;page:number;pageSize:number}):Promise<unknown>;
  getReport(actorUserId:string,reportId:string,managerMode:boolean):Promise<unknown>;
  getOilTrackingReport?(actorUserId:string,reportId:string):Promise<unknown>;
  getColdStorageReport?(actorUserId:string,reportId:string):Promise<unknown>;
  listManagedReports(input:Record<string,unknown>):Promise<unknown>;
  listManagedOilTrackingReports?(input:Record<string,unknown>):Promise<unknown>;
  listManagedColdStorageReports?(input:Record<string,unknown>):Promise<unknown>;
  listManagedDailyAuditReports?(input:Record<string,unknown>):Promise<unknown>;
  listManagedFinancialClosingReports?(input:Record<string,unknown>):Promise<unknown>;
  getManagedOilTrackingReport?(actorUserId:string,organizationId:string,reportId:string):Promise<unknown>;
  getManagedColdStorageReport?(actorUserId:string,organizationId:string,reportId:string):Promise<unknown>;
  getManagedDailyAuditReport?(actorUserId:string,organizationId:string,reportId:string):Promise<unknown>;
  getManagedFinancialClosingReport?(actorUserId:string,organizationId:string,reportId:string):Promise<unknown>;
  listManagedIssues(input:Record<string,unknown>):Promise<unknown>;
  listManagedOilTrackingIssues?(input:Record<string,unknown>):Promise<unknown>;
  listManagedColdStorageIssues?(input:Record<string,unknown>):Promise<unknown>;
  listManagedSalesTrackingIssues?(input:Record<string,unknown>):Promise<unknown>;
  getManagedIssue(actorUserId:string,organizationId:string,issueId:string):Promise<unknown>;
  getManagedOilTrackingIssue?(actorUserId:string,organizationId:string,issueId:string):Promise<unknown>;
  getManagedColdStorageIssue?(actorUserId:string,organizationId:string,issueId:string):Promise<unknown>;
  getManagedSalesTrackingIssue?(actorUserId:string,organizationId:string,issueId:string):Promise<unknown>;
};

export type SalesTrackingDraftPayload = {
  sales_rows:Array<{
    entry_date:string;
    actual_cash:string|number;
    actual_credit:string|number;
    pos_cash:string|number;
    pos_credit:string|number;
    online_delivery:string|number;
    online_amounts?:Array<{provider_id:string;amount:string|number}>;
    remarks:string;
  }>;
  cash_rows:Array<{
    entry_date:string;
    denominations:{
      "1":number;
      "2":number;
      "5":number;
      "10":number;
      "20":number;
      "50":number;
      "100":number;
      "200":number;
      "500":number;
    };
    remaining_cash:string|number;
    remarks:string;
  }>;
};

export type InventoryItemsDraftPayload = {
  beef_rows:Array<{
    production_date:string;
    russian_kg:string|number;
    australian_kg:string|number;
    fat_kg:string|number;
    ready_patty:string|number;
    hunch_sauce_kg:string|number;
    wastage_grams:string|number;
  }>;
  item_usage:{
    usage_month:string;
    items:Array<{
      item_id?:string;
      group_name:string;
      item_name:string;
      usage:Record<string,string|number>;
    }>;
  };
};

const nonPersistentAuth={autoRefreshToken:false,detectSessionInUrl:false,persistSession:false} as const;
const mutation=z.array(z.object({id:z.uuid(),business_date:z.string(),checklist_type:z.string(),state:z.string(),created_at:z.string().optional(),updated_at:z.string().optional(),submitted_at:z.string().optional(),issue_count:z.number().int().nonnegative().optional()}).passthrough()).length(1);
const dateOnly=z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const numericJson=z.union([z.number(),z.string()]);
const salesTrackingPeriod=z.enum(["middle_shift","closing_shift"]);
const salesTrackingTotals=z.object({
  actual_cash:numericJson,
  actual_credit:numericJson,
  pos_cash:numericJson,
  pos_credit:numericJson,
  online_delivery:numericJson,
  actual_total:numericJson,
  pos_total:numericJson,
  variance:numericJson,
  cash_total:numericJson,
  remaining_cash:numericJson,
}).strict();
const salesTrackingCurrent=z.object({
  report_id:z.uuid().nullable(),
  business_date:dateOnly,
  state:z.enum(["draft","submitted"]),
  revision:z.number().int().nonnegative().default(0),
  submitted_at:z.string().nullable(),
  submitted_by_user_id:z.uuid().nullable(),
  submitted_by_name_snapshot:z.string().nullable(),
  periods:z.array(z.object({id:z.uuid(),entry_period:salesTrackingPeriod,entered_by_user_id:z.uuid(),entered_by_name:z.string(),entered_at:z.string()}).strict()).max(2),
  sales_rows:z.array(z.object({
    id:z.uuid().optional(),
    entry_date:dateOnly,
    entry_period:salesTrackingPeriod.nullable(),
    entered_by_user_id:z.uuid().nullable(),
    entered_by_name:z.string().nullable(),
    entered_at:z.string().nullable(),
    actual_cash:numericJson,
    actual_credit:numericJson,
    pos_cash:numericJson,
    pos_credit:numericJson,
    online_delivery:numericJson,
    online_amounts:z.array(z.object({id:z.uuid().optional(),provider_id:z.uuid(),provider_name:z.string(),amount:numericJson}).strict()).optional().default([]),
    remarks:z.string().max(2000).nullable().optional(),
    actual_total:numericJson.optional(),
    pos_total:numericJson.optional(),
    variance:numericJson.optional(),
  }).strict()).max(31),
  cash_rows:z.array(z.object({
    id:z.uuid().optional(),
    entry_date:dateOnly,
    entry_period:salesTrackingPeriod.nullable(),
    entered_by_user_id:z.uuid().nullable(),
    entered_by_name:z.string().nullable(),
    entered_at:z.string().nullable(),
    denom_1:z.number().int().nonnegative(),
    denom_2:z.number().int().nonnegative(),
    denom_5:z.number().int().nonnegative(),
    denom_10:z.number().int().nonnegative(),
    denom_20:z.number().int().nonnegative(),
    denom_50:z.number().int().nonnegative(),
    denom_100:z.number().int().nonnegative(),
    denom_200:z.number().int().nonnegative(),
    denom_500:z.number().int().nonnegative(),
    remaining_cash:numericJson,
    remarks:z.string().max(2000).nullable().optional(),
    cash_total:numericJson.optional(),
  }).strict()).max(31),
  totals:salesTrackingTotals,
}).strict();
const salesTrackingOnlineOrderProvider=z.object({
  id:z.uuid(),
  organization_id:z.uuid(),
  branch_id:z.uuid(),
  name:z.string().min(1).max(120),
  normalized_name:z.string().min(1).max(120),
  default_provider_key:z.string().nullable(),
  is_default:z.boolean(),
  active:z.boolean(),
  created_by:z.uuid().nullable(),
  created_at:z.string(),
  updated_at:z.string(),
}).strict();
const salesTrackingOnlineOrderProviders=z.object({
  providers:z.array(salesTrackingOnlineOrderProvider).max(200),
}).strict();
const salesTrackingOnlineOrderProviderMutation=z.object({
  provider:salesTrackingOnlineOrderProvider,
}).strict();
const managedSalesTrackingOnlineProviderAmount=z.object({
  provider_id:z.uuid().nullable().optional(),
  provider_key:z.string().nullable().optional(),
  provider_name:z.string().min(1).max(120),
  amount:numericJson,
}).strict();
const inventoryItemsCurrent=z.object({
  report_id:z.uuid().nullable().optional(),
  business_date:dateOnly,
  inventory_month:dateOnly.optional(),
  state:z.enum(["draft","submitted"]),
  updated_at:z.string().nullable().optional(),
  submitted_at:z.string().nullable().optional(),
  beef_rows:z.array(z.object({
    id:z.uuid().optional(),
    production_date:dateOnly,
    russian_kg:numericJson,
    australian_kg:numericJson,
    fat_kg:numericJson,
    total_kg:numericJson.optional(),
    ready_patty:numericJson,
    hunch_sauce_kg:numericJson,
    wastage_grams:numericJson,
  }).strict()).max(62),
  item_usage:z.object({
    usage_month:dateOnly,
    items:z.array(z.object({
      id:z.uuid().optional(),
      group_name:z.string().min(1).max(120),
      item_name:z.string().min(1).max(160),
      usage:z.record(z.string(),numericJson),
    }).strict()).max(200),
  }).strict(),
}).strict();
const managedSalesTrackingReports=z.object({
  sales_rows:z.array(z.object({
    report_id:z.uuid(),
    row_id:z.uuid(),
    business_date:dateOnly,
    entry_date:dateOnly,
    entry_period:salesTrackingPeriod.nullable(),
    entered_by:z.string().nullable(),
    entered_at:z.string().nullable(),
    branch_id:z.uuid(),
    branch_name:z.string(),
    supervisor_user_id:z.uuid(),
    submitted_by:z.string().nullable(),
    supervisor_team_id:z.uuid(),
    supervisor_team_name:z.string(),
    submitted_at:z.string(),
    actual_cash:numericJson,
    actual_credit:numericJson,
    pos_cash:numericJson,
    pos_credit:numericJson,
    online_delivery:numericJson,
    online_provider_breakdown:z.array(managedSalesTrackingOnlineProviderAmount).optional().default([]),
    actual_total:numericJson,
    pos_total:numericJson,
    variance:numericJson,
    remarks:z.string().max(2000).nullable().optional(),
  }).strict()).max(1000),
  cash_rows:z.array(z.object({
    report_id:z.uuid(),
    row_id:z.uuid(),
    business_date:dateOnly,
    entry_date:dateOnly,
    entry_period:salesTrackingPeriod.nullable(),
    entered_by:z.string().nullable(),
    entered_at:z.string().nullable(),
    branch_id:z.uuid(),
    branch_name:z.string(),
    supervisor_user_id:z.uuid(),
    submitted_by:z.string().nullable(),
    supervisor_team_id:z.uuid(),
    supervisor_team_name:z.string(),
    submitted_at:z.string(),
    denom_1:z.number().int().nonnegative(),
    denom_2:z.number().int().nonnegative(),
    denom_5:z.number().int().nonnegative(),
    denom_10:z.number().int().nonnegative(),
    denom_20:z.number().int().nonnegative(),
    denom_50:z.number().int().nonnegative(),
    denom_100:z.number().int().nonnegative(),
    denom_200:z.number().int().nonnegative(),
    denom_500:z.number().int().nonnegative(),
    cash_total:numericJson,
    remaining_cash:numericJson,
    remarks:z.string().max(2000).nullable().optional(),
  }).strict()).max(1000),
}).strict();
const managedInventoryItemsReports=z.object({
  inventory_month:dateOnly,
  reports:z.array(z.object({
    branch_id:z.uuid(),
    branch_name:z.string(),
    branch_code:z.string(),
    inventory_month:dateOnly,
    status:z.enum(["submitted","draft","not_submitted"]),
    report_id:z.uuid().nullable(),
    business_date:dateOnly.nullable(),
    supervisor_user_id:z.uuid().nullable(),
    submitted_by:z.string().nullable(),
    supervisor_team_id:z.uuid().nullable(),
    supervisor_team_name:z.string().nullable(),
    updated_at:z.string().nullable(),
    submitted_at:z.string().nullable(),
    summary:z.object({
      russian_kg_total:numericJson,
      australian_kg_total:numericJson,
      total_kg:numericJson,
      ready_patty_total:numericJson,
      hunch_sauce_total:numericJson,
      wastage_total:numericJson,
      item_usage_total:numericJson,
    }).strict(),
    beef_rows:z.array(z.object({
      row_id:z.uuid(),
      production_date:dateOnly,
      russian_kg:numericJson,
      australian_kg:numericJson,
      fat_kg:numericJson,
      total_kg:numericJson,
      ready_patty:numericJson,
      hunch_sauce_kg:numericJson,
      wastage_grams:numericJson,
    }).strict()).max(62),
    item_usage_rows:z.array(z.object({
      item_id:z.uuid(),
      group_name:z.string().min(1).max(120),
      item_name:z.string().min(1).max(160),
      usage:z.record(z.string(),numericJson),
      total_usage:numericJson,
    }).strict()).max(200),
  }).strict()).max(250),
}).strict();
function canonical(value:unknown):string {
  if(Array.isArray(value))return `[${value.map(canonical).join(",")}]`;
  if(value&&typeof value==="object")return `{${Object.entries(value).sort(([a],[b])=>a.localeCompare(b)).map(([k,v])=>`${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  return JSON.stringify(value);
}
export function checklistRequestHash(value:unknown){return createHash("sha256").update(canonical(value)).digest("hex");}

export function inventoryItemsDraftRpcArgs(actorUserId:string,branchId:string,payload:InventoryItemsDraftPayload){
 return {p_actor_user_id:actorUserId,p_target_branch_id:branchId,beef_rows:payload.beef_rows,item_usage:payload.item_usage};
}

export function inventoryItemsSubmitRpcArgs(actorUserId:string,branchId:string,idempotencyKey:string,payload:InventoryItemsDraftPayload){
 return {p_actor_user_id:actorUserId,p_target_branch_id:branchId,p_idempotency_key:idempotencyKey,p_request_hash:checklistRequestHash({type:"inventory_items",branch_id:branchId,inventory_month:payload.item_usage.usage_month,beef_rows:payload.beef_rows,item_usage:payload.item_usage}),beef_rows:payload.beef_rows,item_usage:payload.item_usage};
}

function salesTrackingRpcPayload(payload:SalesTrackingDraftPayload){
  return {
    sales_rows:payload.sales_rows.map((row)=>({
      entry_date:row.entry_date,
      actual_cash:row.actual_cash,
      actual_credit:row.actual_credit,
      pos_cash:row.pos_cash,
      pos_credit:row.pos_credit,
      online_delivery:row.online_delivery,
      ...(row.online_amounts?{online_amounts:row.online_amounts}:{}),
      remarks:row.remarks,
    })),
    cash_rows:payload.cash_rows.map((row)=>({
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
    })),
  };
}

export function salesTrackingDraftRpcArgs(actorUserId:string,branchId:string,expectedRevision:number,entryPeriod:"middle_shift"|"closing_shift",payload:SalesTrackingDraftPayload){
 const rows=salesTrackingRpcPayload(payload);
 return{actor_user_id:actorUserId,target_branch_id:branchId,expected_revision:expectedRevision,entry_period:entryPeriod,sales_rows:rows.sales_rows,cash_rows:rows.cash_rows};
}

export function salesTrackingSubmitRpcArgs(actorUserId:string,branchId:string,expectedRevision:number,idempotencyKey:string){
 return{actor_user_id:actorUserId,target_branch_id:branchId,expected_revision:expectedRevision,idempotency_key:idempotencyKey,request_hash:checklistRequestHash({type:"sales_tracking",branch_id:branchId,expected_revision:expectedRevision})};
}

export function createChecklistPersistence(url:string,secretKey:string):ChecklistPersistence{
 const client=createClient(url,secretKey,{auth:nonPersistentAuth});
 async function rpc(name:string,args:Record<string,unknown>){
  const result=await client.rpc(name,args);
  if(result.error){
   if(result.error.code==="23505"||result.error.code==="23514"||result.error.code==="40001"||result.error.code==="55000")throw new ChecklistConflictError();
   if(result.error.code==="22023")throw new ChecklistInputError();
   if(result.error.code==="42501")throw new ChecklistAccessError();
   throw new Error("Checklist persistence unavailable.");
  }
  return result.data;
 }
 return {
  getOverview:(actorUserId,branchId)=>rpc("get_phase4a_supervisor_overview",{actor_user_id:actorUserId,target_branch_id:branchId}),
  async getManagementOverview(actorUserId,organizationId){
   const result=await client.rpc("get_management_overview_with_daily_audit",{actor_user_id:actorUserId,target_organization_id:organizationId});
   if(result.error){
    if(result.error.code==="42501")throw new ChecklistAccessError();
    throw new ManagementOverviewUnavailableError();
   }
   return result.data;
  },
  getCurrentState:(actorUserId,branchId,type)=>rpc("get_phase4a_current_state",{actor_user_id:actorUserId,target_branch_id:branchId,target_checklist_type:type}),
  getHygieneCurrentState:(actorUserId,branchId,operationalTeamId)=>rpc("get_operational_team_hygiene_current_state",{actor_user_id:actorUserId,target_branch_id:branchId,target_operational_team_id:operationalTeamId}),
  async saveDraft(input){return mutation.parse(await rpc("save_phase4a_draft",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_checklist_type:input.type,expected_revision:input.expectedRevision,answers:input.answers}))[0];},
  async saveHygieneDraft(input){return mutation.parse(await rpc("save_operational_team_hygiene_draft",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_operational_team_id:input.operationalTeamId,expected_revision:input.expectedRevision,staff_answers:input.staff}))[0];},
  async submitOpening(input){return mutation.parse(await rpc("submit_phase4a_opening",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_checklist_type:input.type,expected_revision:input.expectedRevision,idempotency_key:input.idempotencyKey,request_hash:checklistRequestHash({type:input.type,answers:input.answers}),answers:input.answers}))[0];},
  async submitHygiene(input){return mutation.parse(await rpc("submit_operational_team_hygiene",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_operational_team_id:input.operationalTeamId,idempotency_key:input.idempotencyKey,request_hash:checklistRequestHash({type:"staff_hygiene",operational_team_id:input.operationalTeamId,staff:input.staff}),staff_answers:input.staff}))[0];},
  getOilTrackingCurrentState:(actorUserId,branchId)=>rpc("get_oil_tracking_current_state",{actor_user_id:actorUserId,target_branch_id:branchId}),
  saveOilTrackingDraft:(input)=>rpc("save_oil_tracking_draft",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,expected_revision:input.expectedRevision,rows:input.rows}),
  submitOilTrackingOpening:(input)=>rpc("submit_oil_tracking_opening",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,expected_revision:input.expectedRevision,idempotency_key:input.idempotencyKey,request_hash:checklistRequestHash({type:"oil_tracking",section:"opening",rows:input.rows}),rows:input.rows}),
  submitOilTrackingClosing:(input)=>rpc("submit_oil_tracking_closing",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,expected_revision:input.expectedRevision,idempotency_key:input.idempotencyKey,request_hash:checklistRequestHash({type:"oil_tracking",section:"closing",rows:input.rows}),rows:input.rows}),
  getColdStorageCurrentState:(actorUserId,branchId)=>rpc("get_cold_storage_current_state",{actor_user_id:actorUserId,target_branch_id:branchId}),
  saveColdStorageDraft:(input)=>rpc("save_cold_storage_draft",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,expected_revision:input.expectedRevision,equipment:input.equipment,readings:input.readings}),
  submitColdStorageSlot:(input)=>rpc("submit_cold_storage_slot",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,expected_revision:input.expectedRevision,slot:input.slot,idempotency_key:input.idempotencyKey,request_hash:checklistRequestHash({type:"cold_storage",slot:input.slot,equipment:input.equipment,readings:input.readings}),equipment:input.equipment,readings:input.readings}),
  async getSalesTrackingCurrentState(actorUserId,branchId){return salesTrackingCurrent.parse(await rpc("get_sales_tracking_current_state",{actor_user_id:actorUserId,target_branch_id:branchId}));},
  async listSalesTrackingOnlineOrderProviders(actorUserId,branchId){
   return salesTrackingOnlineOrderProviders.parse(await rpc("list_sales_tracking_online_order_providers",{actor_user_id:actorUserId,target_branch_id:branchId}));
  },
  async createSalesTrackingOnlineOrderProvider(input){
   return salesTrackingOnlineOrderProviderMutation.parse(await rpc("create_sales_tracking_online_order_provider",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,provider_name:input.name}));
  },
  async saveSalesTrackingDraft(input){
   return salesTrackingCurrent.parse(await rpc("save_sales_tracking_draft",salesTrackingDraftRpcArgs(input.actorUserId,input.branchId,input.expectedRevision,input.entryPeriod,input.payload)));
  },
	  async submitSalesTracking(input){
	   return salesTrackingCurrent.parse(await rpc("submit_sales_tracking",salesTrackingSubmitRpcArgs(input.actorUserId,input.branchId,input.expectedRevision,input.idempotencyKey)));
	  },
	  getFinancialClosingCurrentState:(actorUserId,branchId)=>rpc("get_financial_closing_current_state",{actor_user_id:actorUserId,target_branch_id:branchId}),
	  saveFinancialClosingDraft:(input)=>rpc("save_financial_closing_draft",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,expected_revision:input.expectedRevision,report_items:input.items}),
	  submitFinancialClosing:(input)=>rpc("submit_financial_closing",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,expected_revision:input.expectedRevision,report_items:input.items}),
	  listSupervisorNotifications:(actorUserId)=>rpc("evaluate_supervisor_notifications",{actor_user_id:actorUserId}),
	  markSupervisorNotificationRead:(actorUserId,notificationId)=>rpc("mark_supervisor_notification_read",{actor_user_id:actorUserId,target_notification_id:notificationId}),
  async getInventoryItemsCurrentState(actorUserId,branchId,inventoryMonth){
   const args=inventoryMonth?{actor_user_id:actorUserId,target_branch_id:branchId,target_inventory_month:inventoryMonth}:{actor_user_id:actorUserId,target_branch_id:branchId};
   return inventoryItemsCurrent.parse(await rpc("get_inventory_items_current_state",args));
  },
  async saveInventoryItemsDraft(input){
   return inventoryItemsCurrent.parse(await rpc("save_inventory_items_draft",inventoryItemsDraftRpcArgs(input.actorUserId,input.branchId,input.payload)));
  },
  async submitInventoryItems(input){
   return inventoryItemsCurrent.parse(await rpc("submit_inventory_items",inventoryItemsSubmitRpcArgs(input.actorUserId,input.branchId,input.idempotencyKey,input.payload)));
  },
  async listManagedSalesTrackingReports(input){
   const reports=managedSalesTrackingReports.parse(await rpc("list_managed_sales_tracking_reports",{actor_user_id:input.actorUserId,target_organization_id:input.organizationId,from_date:input.dateFrom??null,to_date:input.dateTo??null}));
   if(!input.branchId)return reports;
   return {
    sales_rows:reports.sales_rows.filter((row)=>row.branch_id===input.branchId),
    cash_rows:reports.cash_rows.filter((row)=>row.branch_id===input.branchId),
   };
  },
  async getManagedSalesTrackingMonthlySummary(input){
   return managementSalesTrackingMonthlySummarySchema.parse(await rpc("get_managed_sales_tracking_monthly_summary",{
    actor_user_id:input.actorUserId,
    target_organization_id:input.organizationId,
    target_month:`${input.month}-01`,
    branch_filter:input.branchId??null,
   }));
  },
  async listManagedInventoryItemsReports(input){
   return managedInventoryItemsReports.parse(await rpc("list_managed_inventory_items_reports",{actor_user_id:input.actorUserId,target_organization_id:input.organizationId,target_inventory_month:input.inventoryMonth,optional_branch_id:input.branchId??null}));
  },
  listSupervisor:(input)=>rpc("list_phase2_branch_reports",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,requested_page:input.page,requested_page_size:input.pageSize,target_checklist_type:input.type??null}),
  listOilTrackingSupervisor:(input)=>rpc("list_phase2_branch_reports",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,requested_page:input.page,requested_page_size:input.pageSize,target_checklist_type:"oil_tracking"}),
  listColdStorageSupervisor:(input)=>rpc("list_phase2_branch_reports",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,requested_page:input.page,requested_page_size:input.pageSize,target_checklist_type:"cold_storage"}),
  getReport:(actorUserId,reportId,managerMode)=>managerMode?rpc("get_phase4a_report_detail",{actor_user_id:actorUserId,target_report_id:reportId,manager_mode:true}):rpc("get_phase2_branch_report_detail",{actor_user_id:actorUserId,target_report_id:reportId}),
  getOilTrackingReport:(actorUserId,reportId)=>rpc("get_oil_tracking_report_detail",{actor_user_id:actorUserId,target_report_id:reportId}),
  getColdStorageReport:(actorUserId,reportId)=>rpc("get_cold_storage_report_detail",{actor_user_id:actorUserId,target_report_id:reportId}),
  listManagedReports:(input)=>rpc("list_phase4a_managed_reports",input),
  listManagedOilTrackingReports:(input)=>rpc("list_oil_tracking_managed_reports",input),
	  listManagedColdStorageReports:(input)=>rpc("list_cold_storage_managed_reports",input),
	  listManagedDailyAuditReports:(input)=>rpc("list_managed_daily_audit_reports",input),
	  listManagedFinancialClosingReports:(input)=>rpc("list_managed_financial_closing_reports",input),
	  getManagedOilTrackingReport:(actorUserId,organizationId,reportId)=>rpc("get_oil_tracking_managed_report_detail",{actor_user_id:actorUserId,target_organization_id:organizationId,target_report_id:reportId}),
	  getManagedColdStorageReport:(actorUserId,organizationId,reportId)=>rpc("get_cold_storage_managed_report_detail",{actor_user_id:actorUserId,target_organization_id:organizationId,target_report_id:reportId}),
	  getManagedDailyAuditReport:(actorUserId,organizationId,reportId)=>rpc("get_managed_daily_audit_report_detail",{actor_user_id:actorUserId,target_organization_id:organizationId,target_submission_id:reportId}),
	  getManagedFinancialClosingReport:(actorUserId,organizationId,reportId)=>rpc("get_managed_financial_closing_report_detail",{actor_user_id:actorUserId,target_organization_id:organizationId,target_report_id:reportId}),
  listManagedIssues:(input)=>rpc("list_phase4a_managed_issues",input),
  listManagedOilTrackingIssues:(input)=>rpc("list_oil_tracking_managed_issues",input),
  listManagedColdStorageIssues:(input)=>rpc("list_cold_storage_managed_issues",input),
  listManagedSalesTrackingIssues:(input)=>rpc("list_sales_tracking_managed_issues",input),
  getManagedIssue:(actorUserId,organizationId,issueId)=>rpc("get_phase4a_managed_issue",{actor_user_id:actorUserId,target_organization_id:organizationId,target_issue_id:issueId}),
  getManagedOilTrackingIssue:(actorUserId,organizationId,issueId)=>rpc("get_oil_tracking_managed_issue",{actor_user_id:actorUserId,target_organization_id:organizationId,target_issue_id:issueId}),
  getManagedColdStorageIssue:(actorUserId,organizationId,issueId)=>rpc("get_cold_storage_managed_issue",{actor_user_id:actorUserId,target_organization_id:organizationId,target_issue_id:issueId}),
  getManagedSalesTrackingIssue:(actorUserId,organizationId,issueId)=>rpc("get_sales_tracking_managed_issue",{actor_user_id:actorUserId,target_organization_id:organizationId,target_issue_id:issueId}),
 };
}
