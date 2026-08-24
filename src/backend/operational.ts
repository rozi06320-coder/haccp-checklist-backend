import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AdminOperationError } from "./admin";
import { managementOperationsSummarySchema } from "../lib/contracts/management-operations-summary";
import { annualEvaluationDetailSchema, annualEvaluationWorkspaceSchema, type AnnualEvaluationScore } from "../lib/contracts/annual-evaluation";
import { employeeCountryCodes } from "../lib/employee-countries";

const uuid = z.string().uuid();
const role = z.enum(["kitchen", "dispatcher", "production", "front_of_house", "cleaner", "cashier"]);
const roles = z.array(role).min(1).max(2);
const duty = z.enum(["on_duty", "day_off", "on_vacation"]);
const employment = z.enum(["active", "inactive"]);
const staffCode = z.string().nullable();
const countryCode = z.enum(employeeCountryCodes).nullable();
const optionalStaffText = z.string().nullable();
const optionalStaffDate = z.iso.date().nullable();
const healthCardStatus = z.enum(["not_done", "pending", "passed", "done_waiting_id", "failed"]);
const monthlyEvaluationStatus = z.enum(["draft", "completed"]);
const dailyAuditItem = z.object({item_id:z.string(),item_number:z.number().int().min(1).max(13).optional(),answer:z.enum(["not_checked","compliant","non_compliant"]),remark:z.string()}).strict();
const dailyAuditCurrent = z.object({submission_id:uuid.nullable().optional(),branch_id:uuid,business_date:z.iso.date(),state:z.enum(["empty","draft","submitted"]).nullable(),revision:z.number().int().nonnegative().default(0),auditor_display_name:z.string().nullable().optional(),auditor_kind:z.enum(["manual_access_user","organization_manager_pin"]).nullable().optional(),submitted_at:z.string().nullable().optional(),updated_at:z.string().nullable().optional(),items:z.array(dailyAuditItem).length(13)}).strict();
const purchaseLogCategory = z.enum(["stationery", "kitchen", "equipment", "food_item"]);
const purchaseLogPaymentStatus = z.enum(["unpaid", "reimbursed"]);
const supplierReceivingCategory = z.enum(["raw", "frozen", "juice"]);
const maintenanceIssueCategory = z.enum(["equipment", "plumbing", "electrical", "refrigeration", "building", "other"]);
const maintenanceIssuePriority = z.enum(["low", "normal", "high", "urgent"]);
const maintenanceIssueStatus = z.enum(["new", "in_progress", "waiting_parts", "resolved", "closed"]);
const maintenancePurchaseUnit = z.enum(["pcs", "meter", "kg", "box", "bag", "roll", "set", "liter", "other"]);
const monthlyEvaluationScore = z.object({
  section: z.string(),
  factor_key: z.string(),
  factor_label: z.string(),
  rating: z.number().int().min(1).max(5).nullable(),
  comment: optionalStaffText,
}).strict();

const teamRow = z.object({
  team_id: uuid,
  team_name: z.string(),
  team_active: z.boolean(),
  can_write: z.boolean(),
  assignment_role: z.enum(["primary", "backup"]).nullable(),
  company_name: z.string().nullable(),
  staff_id: uuid.nullable(),
  display_name: z.string().nullable(),
  staff_company_name: z.string().nullable(),
  staff_code: staffCode,
  country_code: countryCode,
  iqama_number: optionalStaffText,
  iqama_expiry_date: optionalStaffDate,
  phone_number: optionalStaffText,
  email: optionalStaffText,
  employment_status: employment.nullable(),
  assignment_id: uuid.nullable(),
  operational_roles: roles.nullable(),
  duty_status: duty.nullable(),
}).strict();
const supervisorOwnedTeamRow = z.object({
  team_id: uuid,
  organization_id: uuid,
  branch_id: uuid,
  team_name: z.string(),
  active: z.boolean(),
  legacy_supervisor_team_id: uuid,
  supervisor_user_id: uuid,
  assignment_role: z.literal("primary"),
  can_write: z.boolean(),
}).strict();
const staffTransferDestinationRow = z.object({
  branch_id: uuid,
  branch_name: z.string(),
  branch_code: z.string(),
  operational_team_id: uuid,
  team_name: z.string(),
}).strict();
const branchTransferRow = z.object({
  staff_id: uuid,
  assignment_id: uuid,
  branch_id: uuid,
  operational_team_id: uuid,
}).strict();

const mutationRow = z.object({
  staff_id: uuid,
  assignment_id: uuid,
  duplicate_name_warning: z.boolean(),
  country_code: countryCode.optional(),
  iqama_number: optionalStaffText.optional(),
  iqama_expiry_date: optionalStaffDate.optional(),
  phone_number: optionalStaffText.optional(),
  email: optionalStaffText.optional(),
}).strict();
const staffImportPreviewRpcRow = z.object({
  preview_token: uuid,
  row_number: z.number().int().nullable(),
  error_code: z.string().nullable(),
}).strict();

const healthCardRow = z.object({
  id: uuid.nullable(),
  operational_staff_id: uuid,
  certificate_number: optionalStaffText,
  status: healthCardStatus,
  place_of_issue: optionalStaffText,
  expiry_date: optionalStaffDate,
  date_issue: optionalStaffDate,
  occupation: optionalStaffText,
  company: optionalStaffText,
  branch_name_snapshot: optionalStaffText,
  notes: optionalStaffText,
  updated_at: z.string().nullable(),
}).strict();
const monthlyEvaluationRow = z.object({
  id: uuid.nullable(),
  operational_staff_id: uuid,
  evaluation_month: optionalStaffDate,
  evaluator_name: optionalStaffText,
  status: monthlyEvaluationStatus,
  average_score: z.union([z.number(), z.string()]).nullable(),
  scores: z.array(monthlyEvaluationScore).max(100),
  updated_at: z.string().nullable(),
}).strict();
const purchaseLogRow = z.object({
  id: uuid,
  organization_id: uuid.optional(),
  branch_id: uuid,
  supervisor_team_id: uuid.optional(),
  branch_name: z.string().optional(),
  category: purchaseLogCategory,
  item_name: z.string(),
  quantity: z.union([z.number(), z.string()]),
  amount: z.union([z.number(), z.string()]),
  vendor_name: z.string(),
  purchase_date: z.iso.date(),
  notes: optionalStaffText,
  payment_status: purchaseLogPaymentStatus,
  reimbursement_note: optionalStaffText,
  reimbursed_at: z.string().nullable(),
  reimbursed_by: uuid.nullable(),
  invoice_storage_path: optionalStaffText,
  invoice_original_name: optionalStaffText,
  invoice_url: z.string().nullable().optional(),
  created_by: uuid,
  created_by_name: optionalStaffText.optional(),
  created_at: z.string(),
  updated_at: z.string(),
}).strict();
const supplierReceivingRow = z.object({
  id: uuid,
  organization_id: uuid.optional(),
  branch_id: uuid,
  supervisor_team_id: uuid.optional(),
  branch_name: z.string().optional(),
  supplier_id: uuid.nullable(),
  category: supplierReceivingCategory,
  supplier_name_en: z.string(),
  supplier_name_ar: optionalStaffText,
  quantity: z.union([z.number(), z.string()]),
  unit: z.string(),
  notes: optionalStaffText,
  photo_storage_path: optionalStaffText,
  photo_original_name: optionalStaffText,
  photo_url: z.string().nullable().optional(),
  created_by: uuid,
  created_by_name: optionalStaffText.optional(),
  created_at: z.string(),
  updated_at: z.string(),
}).strict();
const branchSupplierRow = z.object({
  id: uuid,
  organization_id: uuid.optional(),
  branch_id: uuid,
  supervisor_team_id: uuid.optional(),
  supplier_name_en: z.string(),
  supplier_name_ar: optionalStaffText,
  created_by: uuid.optional(),
  created_at: z.string(),
  updated_at: z.string(),
}).strict();
const coldStorageEquipmentMasterRow = z.object({
  id: uuid,
  branch_id: uuid,
  name: z.string().min(1).max(120),
  equipment_type: z.enum(["refrigerator", "freezer"]),
  active: z.boolean(),
  updated_at: z.string(),
  organization_id: uuid.optional(),
  created_by: uuid.optional(),
  updated_by: uuid.nullable().optional(),
  created_at: z.string().optional(),
}).strict();
const maintenanceIssueUpdateRow = z.object({
  id: uuid,
  status: maintenanceIssueStatus,
  note: optionalStaffText,
  updated_by: uuid.nullable(),
  updated_by_access_user_id: uuid.nullable().optional(),
  updated_by_name: optionalStaffText,
  created_at: z.string(),
}).strict();
const maintenanceIssueRow = z.object({
  id: uuid,
  organization_id: uuid.optional(),
  branch_id: uuid,
  branch_name: z.string(),
  title: z.string(),
  category: maintenanceIssueCategory,
  priority: maintenanceIssuePriority,
  status: maintenanceIssueStatus,
  description: optionalStaffText,
  location: optionalStaffText,
  reported_by: uuid,
  reporter_name: optionalStaffText,
  assigned_to: uuid.nullable(),
  created_at: z.string(),
  updated_at: z.string(),
  updates: z.array(maintenanceIssueUpdateRow).optional(),
}).strict();

const PURCHASE_INVOICE_BUCKET = "branch-purchase-invoices";
const PURCHASE_INVOICE_SIGNED_URL_SECONDS = 5 * 60;
export const MAX_PURCHASE_INVOICE_BYTES = 5 * 1024 * 1024;
export const MAX_MAINTENANCE_PURCHASE_PHOTOS = 3;
export const purchaseInvoiceMime = z.enum(["image/jpeg", "image/png", "image/webp", "application/pdf"]);
export const maintenancePurchaseReceiptMime = purchaseInvoiceMime;
const SUPPLIER_RECEIVING_PHOTO_BUCKET = "branch-supplier-receiving-photos";
const SUPPLIER_RECEIVING_PHOTO_SIGNED_URL_SECONDS = 5 * 60;
export const MAX_SUPPLIER_RECEIVING_PHOTO_BYTES = 5 * 1024 * 1024;
export const supplierReceivingPhotoMime = z.enum(["image/jpeg", "image/png", "image/webp"]);

export type OperationalRole = z.infer<typeof role>;
export class OperationalConflictError extends Error {}
export class OperationalDuplicateStaffCodeError extends Error {}
export class OperationalAccessError extends Error {}
export class OperationalInputError extends Error {}
export class OperationalHygieneSubmittedError extends Error {}
export type OperationalAdmin = {
  resolveDailyAuditGrantBranchScope?(actorUserId:string,branchId:string):Promise<{branch_id:string;organization_id:string;active:boolean;organization_active:boolean}|null>;
  resolveDailyAuditManualAccessUser?(actorUserId:string,branchId:string,accessUserId:string):Promise<{id:string;organization_id:string;display_name:string;active:boolean;credential_version:string}|null>;
  getSupervisorDailyAuditCurrentState?(input:{actorUserId:string;branchId:string;businessDate:string}):Promise<unknown>;
  saveSupervisorDailyAuditDraft?(input:{actorUserId:string;branchId:string;businessDate:string;expectedRevision:number;auditorKind:string;auditorId:string;auditorDisplayName:string;accessCredentialVersion:string;items:unknown}):Promise<unknown>;
  submitSupervisorDailyAudit?(input:{actorUserId:string;branchId:string;businessDate:string;expectedRevision:number;auditorKind:string;auditorId:string;auditorDisplayName:string;accessCredentialVersion:string;items:unknown;idempotencyKey?:string|null}):Promise<unknown>;
  listSupervisorColdStorageEquipment?(actorUserId: string, branchId: string): Promise<unknown>;
  createSupervisorColdStorageEquipment?(input: {
    actorUserId: string;
    branchId: string;
    name: string;
    equipmentType: "refrigerator" | "freezer";
  }): Promise<unknown>;
  updateSupervisorColdStorageEquipment?(input: {
    actorUserId: string;
    branchId: string;
    equipmentId: string;
    name: string;
    equipmentType: "refrigerator" | "freezer";
  }): Promise<unknown>;
  archiveSupervisorColdStorageEquipment?(input: {
    actorUserId: string;
    branchId: string;
    equipmentId: string;
  }): Promise<unknown>;
  renameSupervisorColdStorageEquipment?(input: {
    actorUserId: string;
    branchId: string;
    equipmentId: string;
    name: string;
  }): Promise<unknown>;
  getBranchTimezone(actorUserId: string, branchId: string): Promise<string>;
  getSupervisorTeam(actorUserId: string, branchId: string, date: string): Promise<unknown>;
  createSupervisorOwnedOperationalTeam?(input: { actorUserId: string; branchId: string; name: string }): Promise<unknown>;
  createStaff(input: { actorUserId: string; branchId: string; operationalTeamId: string; displayName: string; companyName: string; staffCode?: string | null; countryCode?: string | null; iqamaNumber?: string | null; iqamaExpiryDate?: string | null; phoneNumber?: string | null; email?: string | null; roles: OperationalRole[] }): Promise<unknown>;
  createStaffImportPreview?(input: { actorUserId: string; branchId: string; operationalTeamId: string; rows: Array<{ row_number: number; staff_code: string | null; display_name: string; primary_role: OperationalRole; secondary_role: OperationalRole | null; country_code: string | null; company_name: string | null; iqama_number: string | null; iqama_expiry_date: string | null; phone_number: string | null; email: string | null }> }): Promise<{ preview_token: string; duplicate_rows: Array<{ row_number: number; error_code: string }> }>;
  confirmStaffImport?(input: { actorUserId: string; branchId: string; operationalTeamId: string; previewToken: string }): Promise<{ imported_count: number }>;
  updateStaff(input: { actorUserId: string; branchId: string; staffId: string; displayName: string; companyName: string; staffCode?: string | null; countryCode?: string | null; iqamaNumber?: string | null; iqamaExpiryDate?: string | null; phoneNumber?: string | null; email?: string | null; employmentStatus: "active"; roles: OperationalRole[] }): Promise<unknown>;
  setDuty(input: { actorUserId: string; branchId: string; staffId: string; date: string; status: "on_duty" | "day_off" | "on_vacation" }): Promise<unknown>;
  moveStaff?(input: { actorUserId: string; branchId: string; staffId: string; expectedAssignmentId: string; operationalTeamId: string }): Promise<unknown>;
  listStaffTransferDestinations?(input: { actorUserId: string; sourceBranchId: string; staffId: string; expectedAssignmentId: string }): Promise<{ destinations: Array<z.infer<typeof staffTransferDestinationRow>> }>;
  transferStaffBranch?(input: { actorUserId: string; organizationId: string; sourceBranchId: string; staffId: string; expectedAssignmentId: string; destinationBranchId: string; destinationTeamId: string }): Promise<unknown>;
  leaveStaff?(input: { actorUserId: string; branchId: string; staffId: string; expectedAssignmentId: string }): Promise<unknown>;
  listHealthCards(actorUserId: string, branchId: string): Promise<unknown>;
  upsertHealthCard(input: {
    actorUserId: string; branchId: string; staffId: string; certificateNumber?: string | null;
    status: z.infer<typeof healthCardStatus>; placeOfIssue?: string | null; expiryDate?: string | null;
    dateIssue?: string | null; occupation?: string | null; company?: string | null; notes?: string | null;
  }): Promise<unknown>;
  listMonthlyEvaluations(actorUserId: string, branchId: string, evaluationMonth: string): Promise<unknown>;
  saveMonthlyEvaluation(input: {
    actorUserId: string; branchId: string; staffId: string; evaluationMonth: string; evaluatorName?: string | null;
    status: z.infer<typeof monthlyEvaluationStatus>;
    scores: Array<{ section: string; factor_key: string; factor_label: string; rating: number | null; comment?: string | null }>;
  }): Promise<unknown>;
  listPurchaseLogs(actorUserId: string, branchId: string): Promise<unknown>;
  createPurchaseLog(input: {
    actorUserId: string;
    branchId: string;
    payload: {
      category: z.infer<typeof purchaseLogCategory>;
      item_name: string;
      quantity: string | number;
      amount: string | number;
      vendor_name?: string | null;
      purchase_date: string;
      notes?: string | null;
      payment_status?: z.infer<typeof purchaseLogPaymentStatus>;
      reimbursement_note?: string | null;
    };
    invoice?: { bytes: Buffer; mimeType: z.infer<typeof purchaseInvoiceMime>; originalName: string } | null;
  }): Promise<unknown>;
  updatePurchaseLogPaymentStatus(input: {
    actorUserId: string;
    branchId: string;
    purchaseLogId: string;
    paymentStatus: z.infer<typeof purchaseLogPaymentStatus>;
    reimbursementNote?: string | null;
  }): Promise<unknown>;
  listSupplierReceivings(actorUserId: string, branchId: string): Promise<unknown>;
  listBranchSuppliers(actorUserId: string, branchId: string): Promise<unknown>;
  createBranchSupplier(input: {
    actorUserId: string;
    branchId: string;
    supplierNameEn: string;
    supplierNameAr?: string | null;
  }): Promise<unknown>;
  createSupplierReceiving(input: {
    actorUserId: string;
    branchId: string;
    payload: {
      category: z.infer<typeof supplierReceivingCategory>;
      supplier_name_en?: string | null;
      supplier_name_ar?: string | null;
      supplier_id?: string | null;
      quantity: string | number;
      unit: string;
      notes?: string | null;
    };
    photo?: { bytes: Buffer; mimeType: z.infer<typeof supplierReceivingPhotoMime>; originalName: string } | null;
  }): Promise<unknown>;
  listSupervisorMaintenanceIssues(actorUserId: string, branchId: string): Promise<unknown>;
  createSupervisorMaintenanceIssue(input: {
    actorUserId: string;
    branchId: string;
    payload: {
      title: string;
      category: z.infer<typeof maintenanceIssueCategory>;
      priority: z.infer<typeof maintenanceIssuePriority>;
      description?: string | null;
      location?: string | null;
    };
  }): Promise<unknown>;
  listMaintenanceIssues(input: { actorUserId?: string | null; accessUserId?: string | null; organizationId?: string | null }): Promise<unknown>;
  updateMaintenanceIssue(input: {
    actorUserId?: string | null;
    accessUserId?: string | null;
    issueId: string;
    status: z.infer<typeof maintenanceIssueStatus>;
    note?: string | null;
  }): Promise<unknown>;
  listMaintenancePurchases(actorUserId: string, issueId: string): Promise<unknown>;
  createMaintenancePurchase(input: { actorUserId:string; issueId:string; payload:{item_name:string;quantity:string|number;unit:"pcs"|"meter"|"kg"|"box"|"bag"|"roll"|"set"|"liter"|"other";amount:string|number;vendor_name?:string|null;purchase_date:string;notes?:string|null}; receipts?:Array<{bytes:Buffer;mimeType:z.infer<typeof maintenancePurchaseReceiptMime>;originalName:string}>|null }): Promise<unknown>;
  reimburseMaintenancePurchase(input:{actorUserId:string;purchaseId:string;reimbursementNote?:string|null}):Promise<unknown>;
  listMaintenancePurchaseHistory?(input:{actorUserId:string}):Promise<unknown>;
  listManagedMaintenancePurchases?(input:{actorUserId:string;organizationId:string;branchId?:string;issueStatus?:z.infer<typeof maintenanceIssueStatus>;paymentStatus?:z.infer<typeof purchaseLogPaymentStatus>;vendor?:string;dateFrom?:string;dateTo?:string}):Promise<unknown>;
  getManagedOperationsSummary?(input:{actorUserId:string;organizationId:string;branchId?:string;month:string}):Promise<unknown>;
  listManagedStaff(input: {
    actorUserId: string; organizationId: string; page: number; pageSize: number;
    search?: string; branchId?: string; supervisorUserId?: string;
    role?: OperationalRole; employmentStatus?: "active" | "inactive"; date?: string;
  }): Promise<unknown>;
  listManagedEmployeeTeam?(input: { actorUserId: string; organizationId: string; branchId?: string; month: string }): Promise<unknown>;
  startManagedOperationalStaffSupervisorTraining?(input:{actorUserId:string;organizationId:string;staffId:string}):Promise<unknown>;
  cancelManagedOperationalStaffSupervisorTraining?(input:{actorUserId:string;organizationId:string;staffId:string}):Promise<unknown>;
  getManagedOperationalStaffSupervisorTrainingPromotionState?(input:{actorUserId:string;organizationId:string;staffId:string}):Promise<unknown>;
  promoteManagedOperationalStaffSupervisorTraining?(input:{actorUserId:string;organizationId:string;staffId:string;newSupervisorUserId:string;fullName:string;fullNameAr?:string|null}):Promise<unknown>;
  getManagedAnnualEvaluationWorkspace?(input:{actorUserId:string;organizationId:string;evaluationYear:number;branchId?:string;subjectType?:"supervisor"|"training_supervisor"|"employee";subjectId?:string;state?:"draft"|"submitted"}):Promise<unknown>;
  getManagedAnnualEvaluationDetail?(input:{actorUserId:string;organizationId:string;evaluationId:string}):Promise<unknown>;
  saveManagedAnnualEvaluationDraft?(input:{actorUserId:string;organizationId:string;branchId:string;evaluationYear:number;subjectType:"supervisor"|"training_supervisor"|"employee";subjectId:string;expectedRevision:number;scores:AnnualEvaluationScore[]}):Promise<unknown>;
  submitManagedAnnualEvaluation?(input:{actorUserId:string;organizationId:string;evaluationId:string;expectedRevision:number}):Promise<unknown>;
  listManagedPurchaseLogs?(input: { actorUserId: string; organizationId: string; branchId?: string; category?: z.infer<typeof purchaseLogCategory>; paymentStatus?: z.infer<typeof purchaseLogPaymentStatus>; dateFrom?: string; dateTo?: string }): Promise<unknown>;
  listManagedSupplierReceivings?(input: { actorUserId: string; organizationId: string; branchId?: string; category?: z.infer<typeof supplierReceivingCategory>; supplierId?: string; dateFrom?: string; dateTo?: string }): Promise<unknown>;
  listManagedMaintenanceIssues?(input: { actorUserId: string; organizationId: string; branchId?: string; status?: z.infer<typeof maintenanceIssueStatus>; priority?: z.infer<typeof maintenanceIssuePriority>; category?: z.infer<typeof maintenanceIssueCategory>; dateFrom?: string; dateTo?: string }): Promise<unknown>;
  listManagedTeams(actorUserId: string, organizationId: string): Promise<unknown>;
  listEligibleSupervisors(actorUserId: string, organizationId: string, branchId: string): Promise<unknown>;
};

const nonPersistentAuth = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
} as const;

export function createOperationalAdmin(url: string, secretKey: string): OperationalAdmin {
  const client = createClient(url, secretKey, { auth: nonPersistentAuth });
  const purchaseInvoiceStorage = client.storage.from(PURCHASE_INVOICE_BUCKET);
  const supplierReceivingPhotoStorage = client.storage.from(SUPPLIER_RECEIVING_PHOTO_BUCKET);
  const maintenanceReceiptStorage = client.storage.from("maintenance-purchase-receipts");
  async function rpc(name: string, input: Record<string, unknown>) {
    const result = await client.rpc(name, input);
    if (result.error) {
      if (result.error.code === "23505" && /employee code/i.test(result.error.message)) {
        throw new OperationalDuplicateStaffCodeError();
      }
      if (result.error.code === "23514" && /annual evaluation incomplete/i.test(result.error.message)) throw new OperationalInputError();
      if (result.error.code === "23514" && /destination team hygiene already submitted/i.test(result.error.message)) throw new OperationalHygieneSubmittedError();
      if (["23505", "23514", "40001", "55000"].includes(result.error.code)) {
        throw new OperationalConflictError();
      }
      if (result.error.code === "22023") throw new OperationalInputError();
      if (result.error.code === "42501") throw new OperationalAccessError();
      throw new AdminOperationError();
    }
    if (!Array.isArray(result.data)) throw new AdminOperationError();
    return result.data;
  }
  async function rpcObject(name: string, input: Record<string, unknown>) {
    const result = await client.rpc(name, input);
    if (result.error) {
      if (result.error.code === "23505" && /employee code/i.test(result.error.message)) throw new OperationalDuplicateStaffCodeError();
      if (result.error.code === "23514" && /annual evaluation incomplete/i.test(result.error.message)) throw new OperationalInputError();
      if (result.error.code === "23514" && /destination team hygiene already submitted/i.test(result.error.message)) throw new OperationalHygieneSubmittedError();
      if (["23505", "23514", "40001", "55000"].includes(result.error.code)) throw new OperationalConflictError();
      if (result.error.code === "22023") throw new OperationalInputError();
      if (result.error.code === "42501") throw new OperationalAccessError();
      throw new AdminOperationError();
    }
    if (typeof result.data !== "object" || result.data === null || Array.isArray(result.data)) throw new AdminOperationError();
    return result.data;
  }
  async function resolveDailyAuditGrantBranchScope(actorUserId:string,branchId:string){
    const activeScope=z.array(z.object({timezone:z.string().min(1).max(100)}).strict()).length(1).parse(await rpc("get_supervisor_branch_timezone",{
      actor_user_id:actorUserId,target_branch_id:branchId,
    }));
    const branches=z.array(z.object({id:uuid,organization_id:uuid}).passthrough()).max(200).parse(await rpc("list_supervised_branches",{
      actor_user_id:actorUserId,
    }));
    const branch=branches.find((row)=>row.id===branchId);
    if(!branch||activeScope.length!==1)return null;
    return {branch_id:branch.id,organization_id:branch.organization_id,active:true,organization_active:true};
  }
  async function resolveDailyAuditManualAccessUser(actorUserId:string,branchId:string,accessUserId:string){
    const credentials=z.array(z.object({
      organization_id:uuid,access_user_id:uuid,display_name:z.string().min(1).max(120),credential_version:uuid,
    }).passthrough()).max(100).parse(await rpc("get_daily_audit_access_user_credentials",{
      actor_user_id:actorUserId,target_branch_id:branchId,
    }));
    const credential=credentials.find((row)=>row.access_user_id===accessUserId);
    if(!credential)return null;
    return {id:credential.access_user_id,organization_id:credential.organization_id,display_name:credential.display_name,active:true,credential_version:credential.credential_version};
  }
  function inspectPurchaseInvoice(bytes: Buffer, declaredMime: string) {
    if (bytes.length === 0 || bytes.length > MAX_PURCHASE_INVOICE_BYTES) throw new AdminOperationError();
    const mime = purchaseInvoiceMime.safeParse(declaredMime.toLowerCase());
    if (!mime.success) throw new AdminOperationError();
    const jpeg = bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff && bytes.at(-2) === 0xff && bytes.at(-1) === 0xd9;
    const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const png = bytes.length >= 33 && bytes.subarray(0, 8).equals(pngSignature) && bytes.subarray(12, 16).toString("ascii") === "IHDR" && bytes.subarray(bytes.length - 8, bytes.length - 4).toString("ascii") === "IEND";
    const webp = bytes.length >= 20 && bytes.subarray(0, 4).toString("ascii") === "RIFF" && bytes.subarray(8, 12).toString("ascii") === "WEBP" && bytes.readUInt32LE(4) === bytes.length - 8;
    const pdf = bytes.length >= 5 && bytes.subarray(0, 5).toString("ascii") === "%PDF-";
    const detected = jpeg ? { mime: "image/jpeg" as const, extension: "jpg" as const } : png ? { mime: "image/png" as const, extension: "png" as const } : webp ? { mime: "image/webp" as const, extension: "webp" as const } : pdf ? { mime: "application/pdf" as const, extension: "pdf" as const } : null;
    if (!detected || detected.mime !== mime.data) throw new AdminOperationError();
    return detected;
  }
  function inspectSupplierReceivingPhoto(bytes: Buffer, declaredMime: string) {
    if (bytes.length === 0 || bytes.length > MAX_SUPPLIER_RECEIVING_PHOTO_BYTES) throw new AdminOperationError();
    const mime = supplierReceivingPhotoMime.safeParse(declaredMime.toLowerCase());
    if (!mime.success) throw new AdminOperationError();
    const jpeg = bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff && bytes.at(-2) === 0xff && bytes.at(-1) === 0xd9;
    const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const png = bytes.length >= 33 && bytes.subarray(0, 8).equals(pngSignature) && bytes.subarray(12, 16).toString("ascii") === "IHDR" && bytes.subarray(bytes.length - 8, bytes.length - 4).toString("ascii") === "IEND";
    const webp = bytes.length >= 20 && bytes.subarray(0, 4).toString("ascii") === "RIFF" && bytes.subarray(8, 12).toString("ascii") === "WEBP" && bytes.readUInt32LE(4) === bytes.length - 8;
    const detected = jpeg ? { mime: "image/jpeg" as const, extension: "jpg" as const } : png ? { mime: "image/png" as const, extension: "png" as const } : webp ? { mime: "image/webp" as const, extension: "webp" as const } : null;
    if (!detected || detected.mime !== mime.data) throw new AdminOperationError();
    return detected;
  }
  function safeFileName(value: string, extension: string, fallback = "invoice") {
    const base = value.trim().split(/[\\/]/u).pop()?.replace(/\.[^.]+$/u, "") ?? fallback;
    const cleaned = base.toLowerCase().replace(/[^a-z0-9._-]+/gu, "-").replace(/^-+|-+$/gu, "").slice(0, 80) || fallback;
    return `${cleaned}.${extension}`;
  }
  function safeOriginalFileName(value: string, fallback = "receipt") {
    return value.trim().split(/[\\/]/u).pop()?.replace(/[\u0000-\u001f\u007f]/gu, "").trim().slice(0, 180) || fallback;
  }
  async function signPurchaseInvoice(path: string | null) {
    if (!path) return null;
    try {
      const result = await purchaseInvoiceStorage.createSignedUrl(path, PURCHASE_INVOICE_SIGNED_URL_SECONDS);
      return result.error || !result.data?.signedUrl ? null : result.data.signedUrl;
    } catch {
      return null;
    }
  }
  async function signSupplierReceivingPhoto(path: string | null) {
    if (!path) return null;
    try {
      const result = await supplierReceivingPhotoStorage.createSignedUrl(path, SUPPLIER_RECEIVING_PHOTO_SIGNED_URL_SECONDS);
      return result.error || !result.data?.signedUrl ? null : result.data.signedUrl;
    } catch {
      return null;
    }
  }
  async function signMaintenanceReceipt(path:string|null){if(!path)return null;try{const result=await maintenanceReceiptStorage.createSignedUrl(path,PURCHASE_INVOICE_SIGNED_URL_SECONDS);return result.error||!result.data?.signedUrl?null:result.data.signedUrl;}catch{return null;}}
  const maintenancePurchaseAttachmentRpcRow=z.object({id:uuid,storage_path:z.string(),original_filename:optionalStaffText,mime_type:optionalStaffText,size_bytes:z.union([z.number(),z.string()]).nullable(),position:z.number().int().min(1).max(MAX_MAINTENANCE_PURCHASE_PHOTOS)}).strict();
  const maintenancePurchaseListRpcRow=z.object({id:uuid,branch_id:uuid,item_name:z.string(),quantity:z.union([z.number(),z.string()]),unit:maintenancePurchaseUnit,amount:z.union([z.number(),z.string()]),vendor_name:z.string(),purchase_date:z.string(),notes:optionalStaffText,payment_status:purchaseLogPaymentStatus,reimbursement_note:optionalStaffText,reimbursed_at:z.string().nullable(),receipt_storage_path:optionalStaffText,receipt_original_name:optionalStaffText,attachments:z.array(maintenancePurchaseAttachmentRpcRow).max(MAX_MAINTENANCE_PURCHASE_PHOTOS).default([]),created_at:z.string(),updated_at:z.string()}).strict();
  const maintenancePurchaseMutationRpcRow=maintenancePurchaseListRpcRow.extend({organization_id:uuid,maintenance_issue_id:uuid,maintenance_user_id:uuid}).strict();
  async function normalizeMaintenancePurchaseRows(rows:z.infer<typeof maintenancePurchaseListRpcRow>[]){return Promise.all(rows.map(async row=>{const attachments=await Promise.all(row.attachments.map(async attachment=>({id:attachment.id,original_filename:attachment.original_filename,mime_type:attachment.mime_type,size_bytes:attachment.size_bytes===null?null:Number(attachment.size_bytes),position:attachment.position,url:await signMaintenanceReceipt(attachment.storage_path)})));const first=attachments[0];const{receipt_storage_path,...safe}=row;return{...safe,attachments,quantity:Number(row.quantity),amount:Number(row.amount),receipt_url:first?.url??await signMaintenanceReceipt(receipt_storage_path),receipt_original_name:first?.original_filename??row.receipt_original_name};}));}
  async function normalizeMaintenancePurchases(rows:unknown[]){return normalizeMaintenancePurchaseRows(z.array(maintenancePurchaseListRpcRow).max(500).parse(rows));}
  async function normalizeMaintenancePurchaseMutations(rows:unknown[]){const parsed=z.array(maintenancePurchaseMutationRpcRow).length(1).parse(rows);return normalizeMaintenancePurchaseRows(parsed.map(({organization_id,maintenance_issue_id,maintenance_user_id,...row})=>{void organization_id;void maintenance_issue_id;void maintenance_user_id;return row;}));}
  async function normalizeManagedMaintenancePurchases(rows:unknown[]){return Promise.all(z.array(z.object({id:uuid,organization_id:uuid,branch_id:uuid,branch_name:z.string(),maintenance_issue_id:uuid,issue_title:z.string(),issue_category:maintenanceIssueCategory,issue_status:maintenanceIssueStatus,maintenance_user_id:uuid,maintenance_user_name:optionalStaffText,item_name:z.string(),quantity:z.union([z.number(),z.string()]),unit:maintenancePurchaseUnit,amount:z.union([z.number(),z.string()]),vendor_name:z.string(),purchase_date:z.string(),notes:optionalStaffText,payment_status:purchaseLogPaymentStatus,reimbursement_note:optionalStaffText,reimbursed_at:z.string().nullable(),receipt_storage_path:optionalStaffText,receipt_original_name:optionalStaffText,attachments:z.array(maintenancePurchaseAttachmentRpcRow).max(MAX_MAINTENANCE_PURCHASE_PHOTOS).default([]),created_at:z.string(),updated_at:z.string()}).strict()).max(1000).parse(rows).map(async row=>{const attachments=await Promise.all(row.attachments.map(async attachment=>({id:attachment.id,original_filename:attachment.original_filename,mime_type:attachment.mime_type,size_bytes:attachment.size_bytes===null?null:Number(attachment.size_bytes),position:attachment.position,url:await signMaintenanceReceipt(attachment.storage_path)})));const{organization_id,receipt_storage_path,...safe}=row;void organization_id;return{...safe,attachments,quantity:Number(row.quantity),amount:Number(row.amount),receipt_url:attachments[0]?.url??await signMaintenanceReceipt(receipt_storage_path),receipt_original_name:attachments[0]?.original_filename??row.receipt_original_name};}));}
  async function normalizePurchaseRows(rows: unknown[]) {
    return Promise.all(z.array(purchaseLogRow.omit({ invoice_url: true })).max(500).parse(rows).map(async (row) => {
      const { organization_id, supervisor_team_id, invoice_storage_path, ...safeRow } = row;
      void organization_id;
      void supervisor_team_id;
      return {
        ...safeRow,
        quantity: Number(row.quantity),
        amount: Number(row.amount),
        invoice_url: await signPurchaseInvoice(invoice_storage_path),
      };
    }));
  }
  async function normalizeManagedPurchaseRows(rows: unknown[]) {
    return Promise.all(z.array(purchaseLogRow.omit({ invoice_url: true })).max(500).parse(rows).map(async (row) => {
      const { organization_id, supervisor_team_id, invoice_storage_path, ...safeRow } = row;
      void organization_id;
      void supervisor_team_id;
      return {
        ...safeRow,
        quantity: Number(row.quantity),
        amount: Number(row.amount),
        invoice_url: await signPurchaseInvoice(invoice_storage_path),
      };
    }));
  }
  async function normalizeSupplierReceivingRows(rows: unknown[]) {
    return Promise.all(z.array(supplierReceivingRow.omit({ photo_url: true })).max(500).parse(rows).map(async (row) => {
      const { organization_id, supervisor_team_id, photo_storage_path, ...safeRow } = row;
      void organization_id;
      void supervisor_team_id;
      return {
        ...safeRow,
        quantity: Number(row.quantity),
        photo_url: await signSupplierReceivingPhoto(photo_storage_path),
      };
    }));
  }
  async function normalizeManagedSupplierReceivingRows(rows: unknown[]) {
    return Promise.all(z.array(supplierReceivingRow.omit({ photo_url: true })).max(500).parse(rows).map(async (row) => {
      const { organization_id, supervisor_team_id, photo_storage_path, ...safeRow } = row;
      void organization_id;
      void supervisor_team_id;
      return {
        ...safeRow,
        quantity: Number(row.quantity),
        photo_url: await signSupplierReceivingPhoto(photo_storage_path),
      };
    }));
  }
  function normalizeBranchSupplierRows(rows: unknown[]) {
    return z.array(branchSupplierRow).max(500).parse(rows).map((row) => {
      const { organization_id, supervisor_team_id, created_by, ...safeRow } = row;
      void organization_id;
      void supervisor_team_id;
      void created_by;
      return safeRow;
    });
  }
  function normalizeColdStorageEquipmentMasterRows(rows: unknown[]) {
    return z.array(coldStorageEquipmentMasterRow).max(100).parse(rows).map((row) => {
      const { organization_id, created_by, updated_by, created_at, ...safeRow } = row;
      void organization_id;
      void created_by;
      void updated_by;
      void created_at;
      return safeRow;
    });
  }
  function normalizeMaintenanceIssueRows(rows: unknown[]) {
    return z.array(maintenanceIssueRow).max(1000).parse(rows).map((row) => {
      const { organization_id, ...safeRow } = row;
      void organization_id;
      return {
        ...safeRow,
        updates: row.updates ?? [],
      };
    });
  }
  function normalizeManagedMaintenanceIssueRows(rows: unknown[]) {
    return z.array(maintenanceIssueRow.omit({ assigned_to: true }).strict()).max(1000).parse(rows).map((row) => {
      const { organization_id, ...safeRow } = row;
      void organization_id;
      return safeRow;
    });
  }
  return {
    resolveDailyAuditGrantBranchScope,
    resolveDailyAuditManualAccessUser,
    async listSupervisorColdStorageEquipment(actorUserId, branchId) {
      return {
        equipment: normalizeColdStorageEquipmentMasterRows(await rpc(
          "list_supervisor_cold_storage_equipment",
          { actor_user_id: actorUserId, target_branch_id: branchId },
        )),
      };
    },
    async createSupervisorColdStorageEquipment(input) {
      const rows = normalizeColdStorageEquipmentMasterRows(await rpc(
        "create_supervisor_cold_storage_equipment",
        {
          actor_user_id: input.actorUserId,
          target_branch_id: input.branchId,
          equipment_name: input.name,
          equipment_type: input.equipmentType,
        },
      ));
      if (rows.length !== 1) throw new AdminOperationError();
      return { equipment: rows[0] };
    },
    async renameSupervisorColdStorageEquipment(input) {
      const rows = normalizeColdStorageEquipmentMasterRows(await rpc(
        "rename_supervisor_cold_storage_equipment",
        {
          actor_user_id: input.actorUserId,
          target_branch_id: input.branchId,
          target_equipment_id: input.equipmentId,
          equipment_name: input.name,
        },
      ));
      if (rows.length !== 1) throw new AdminOperationError();
      return { equipment: rows[0] };
    },
    async updateSupervisorColdStorageEquipment(input) {
      const rows = normalizeColdStorageEquipmentMasterRows(await rpc(
        "update_supervisor_cold_storage_equipment",
        {
          actor_user_id: input.actorUserId,
          target_branch_id: input.branchId,
          target_equipment_id: input.equipmentId,
          equipment_name: input.name,
          equipment_type: input.equipmentType,
        },
      ));
      if (rows.length !== 1) throw new AdminOperationError();
      return { equipment: rows[0] };
    },
    async archiveSupervisorColdStorageEquipment(input) {
      const rows = normalizeColdStorageEquipmentMasterRows(await rpc(
        "archive_supervisor_cold_storage_equipment",
        {
          actor_user_id: input.actorUserId,
          target_branch_id: input.branchId,
          target_equipment_id: input.equipmentId,
        },
      ));
      if (rows.length !== 1) throw new AdminOperationError();
      return { equipment: rows[0] };
    },
    async getBranchTimezone(actorUserId, branchId) {
      const rows = z.array(z.object({ timezone: z.string().min(1).max(100) }).strict()).length(1)
        .parse(await rpc("get_supervisor_branch_timezone", {
          actor_user_id: actorUserId, target_branch_id: branchId,
        }));
      return rows[0].timezone;
    },
    async getSupervisorTeam(actorUserId, branchId, date) {
      const rows = z.array(teamRow).max(501).parse(await rpc("get_supervisor_operational_team", {
        actor_user_id: actorUserId, target_branch_id: branchId, requested_date: date,
      }));
      // A supervisor who has no assigned operational team is a valid access
      // state, not an adapter/RPC failure. The route maps this to its explicit
      // setup-required 403 response.
      if (rows.length === 0) throw new OperationalAccessError();
      const teams = new Map<string, {
        id: string;
        name: string;
        active: boolean;
        can_write: boolean;
        assignment_role: "primary" | "backup" | null;
        company_name: string | null;
        staff: Array<unknown>;
      }>();
      for (const row of rows) {
        const team = teams.get(row.team_id) ?? {
          id: row.team_id,
          name: row.team_name,
          active: row.team_active,
          can_write: row.can_write,
          assignment_role: row.assignment_role,
          company_name: row.company_name,
          staff: [],
        };
        if (row.staff_id !== null) {
          team.staff.push({
            id: row.staff_id, display_name: row.display_name, company_name: row.staff_company_name, staff_code: row.staff_code,
            country_code: row.country_code,
            iqama_number: row.iqama_number, iqama_expiry_date: row.iqama_expiry_date, phone_number: row.phone_number, email: row.email,
            employment_status: row.employment_status,
            assignment: { id: row.assignment_id, operational_team_id: row.team_id, operational_roles: row.operational_roles },
            duty_date: date, duty_status: row.duty_status,
          });
        }
        teams.set(row.team_id, team);
      }
      return { teams: [...teams.values()] };
    },
    async createSupervisorOwnedOperationalTeam(input) {
      const rows = z.array(supervisorOwnedTeamRow).length(1).parse(await rpc("create_supervisor_owned_operational_team", {
        p_actor_user_id: input.actorUserId,
        p_branch_id: input.branchId,
        p_team_name: input.name,
      }));
      const row = rows[0];
      return {
        team: {
          id: row.team_id,
          organization_id: row.organization_id,
          branch_id: row.branch_id,
          name: row.team_name,
          active: row.active,
          legacy_supervisor_team_id: row.legacy_supervisor_team_id,
          supervisor_user_id: row.supervisor_user_id,
          assignment_role: row.assignment_role,
          can_write: row.can_write,
        },
      };
    },
    async createStaff(input) {
      const rows = z.array(mutationRow).length(1).parse(await rpc("create_operational_team_staff", {
        actor_user_id: input.actorUserId, target_branch_id: input.branchId,
        target_operational_team_id: input.operationalTeamId,
	        new_display_name: input.displayName, new_staff_code: input.staffCode ?? null,
	        new_company_name: input.companyName,
	        new_country_code: input.countryCode ?? null,
	        new_iqama_number: input.iqamaNumber ?? null,
        new_iqama_expiry_date: input.iqamaExpiryDate ?? null,
        new_phone_number: input.phoneNumber ?? null,
        new_email: input.email ?? null,
        new_operational_roles: input.roles,
      }));
      return rows[0];
    },
    async createStaffImportPreview(input) {
      const rows = z.array(staffImportPreviewRpcRow).min(1).parse(await rpc("create_operational_team_staff_import_preview", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        target_operational_team_id: input.operationalTeamId,
        import_rows: input.rows,
      }));
      const previewToken = rows[0]?.preview_token;
      if (!previewToken) throw new OperationalInputError();
      return {
        preview_token: previewToken,
        duplicate_rows: rows.flatMap((row) => row.row_number === null || row.error_code === null ? [] : [{ row_number: row.row_number, error_code: row.error_code }]),
      };
    },
    async confirmStaffImport(input) {
      const rows = z.array(z.object({ imported_count: z.number().int().nonnegative() }).strict()).length(1).parse(await rpc("confirm_operational_team_staff_import", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        target_operational_team_id: input.operationalTeamId,
        import_preview_token: input.previewToken,
      }));
      return rows[0];
    },
    async updateStaff(input) {
      const rows = z.array(mutationRow).length(1).parse(await rpc("update_operational_team_staff", {
        actor_user_id: input.actorUserId, target_branch_id: input.branchId,
        target_staff_id: input.staffId, new_display_name: input.displayName,
	        new_staff_code: input.staffCode ?? null,
	        new_company_name: input.companyName,
	        new_country_code: input.countryCode ?? null,
	        new_iqama_number: input.iqamaNumber ?? null,
        new_iqama_expiry_date: input.iqamaExpiryDate ?? null,
        new_phone_number: input.phoneNumber ?? null,
        new_email: input.email ?? null,
        new_employment_status: input.employmentStatus, new_operational_roles: input.roles,
      }));
      return rows[0];
    },
    async setDuty(input) {
      const rows = z.array(z.object({
        staff_id: uuid, assignment_id: uuid, duty_date: z.string(),
        duty_status: duty, eligible: z.boolean(),
      }).strict()).length(1).parse(await rpc("set_operational_team_staff_duty", {
        actor_user_id: input.actorUserId, target_branch_id: input.branchId,
        target_staff_id: input.staffId, requested_date: input.date,
        new_duty_status: input.status,
      }));
      return rows[0];
    },
    async moveStaff(input) {
      const rows = z.array(z.object({
        staff_id: uuid, assignment_id: uuid, operational_team_id: uuid,
      }).strict()).length(1).parse(await rpc("move_operational_staff_team", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        target_staff_id: input.staffId,
        expected_assignment_id: input.expectedAssignmentId,
        target_operational_team_id: input.operationalTeamId,
      }));
      return rows[0];
    },
    async listStaffTransferDestinations(input) {
      return {
        destinations: z.array(staffTransferDestinationRow).max(500).parse(await rpc("list_operational_staff_transfer_destinations", {
          actor_user_id: input.actorUserId,
          p_source_branch_id: input.sourceBranchId,
          p_operational_staff_id: input.staffId,
          p_expected_assignment_id: input.expectedAssignmentId,
        })),
      };
    },
    async transferStaffBranch(input) {
      const rows = z.array(branchTransferRow).length(1).parse(await rpc("transfer_operational_staff_branch", {
        actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_source_branch_id: input.sourceBranchId,
        p_operational_staff_id: input.staffId,
        p_expected_assignment_id: input.expectedAssignmentId,
        p_destination_branch_id: input.destinationBranchId,
        p_destination_team_id: input.destinationTeamId,
      }));
      return rows[0];
    },
    async leaveStaff(input) {
      const rows = z.array(z.object({
        staff_id: uuid, assignment_id: uuid, employment_status: z.literal("inactive"),
      }).strict()).length(1).parse(await rpc("leave_operational_staff_company", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        target_staff_id: input.staffId,
        expected_assignment_id: input.expectedAssignmentId,
      }));
      return rows[0];
    },
    async listHealthCards(actorUserId, branchId) {
      return {
        health_cards: z.array(healthCardRow).max(500).parse(await rpc("list_operational_staff_health_cards", {
          actor_user_id: actorUserId,
          target_branch_id: branchId,
        })),
      };
    },
    async upsertHealthCard(input) {
      const rows = z.array(healthCardRow).length(1).parse(await rpc("upsert_operational_staff_health_card", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        payload: {
          operational_staff_id: input.staffId,
          certificate_number: input.certificateNumber ?? null,
          status: input.status,
          place_of_issue: input.placeOfIssue ?? null,
          expiry_date: input.expiryDate ?? null,
          date_issue: input.dateIssue ?? null,
          occupation: input.occupation ?? null,
          company: input.company ?? null,
          notes: input.notes ?? null,
        },
      }));
      return { health_card: rows[0] };
    },
    async listMonthlyEvaluations(actorUserId, branchId, evaluationMonth) {
      return {
        evaluations: z.array(monthlyEvaluationRow).max(500).parse(await rpc("list_operational_staff_monthly_evaluations", {
        actor_user_id: actorUserId,
        target_branch_id: branchId,
        requested_month: evaluationMonth,
        })),
      };
    },
    async saveMonthlyEvaluation(input) {
      const rows = z.array(monthlyEvaluationRow).length(1).parse(await rpc("save_operational_staff_monthly_evaluation", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        target_staff_id: input.staffId,
        requested_month: input.evaluationMonth,
        new_evaluator_name: input.evaluatorName ?? null,
        score_payload: input.scores,
        new_status: input.status,
      }));
      return { evaluation: rows[0] };
    },
    async listPurchaseLogs(actorUserId, branchId) {
      return { purchase_logs: await normalizePurchaseRows(await rpc("list_branch_purchase_logs", {
        actor_user_id: actorUserId,
        target_branch_id: branchId,
      })) };
    },
    async createPurchaseLog(input) {
      let invoicePath: string | null = null;
      let invoiceOriginalName: string | null = null;
      let invoiceMime: z.infer<typeof purchaseInvoiceMime> | null = null;
      if (input.invoice) {
        const inspected = inspectPurchaseInvoice(input.invoice.bytes, input.invoice.mimeType);
        invoiceMime = inspected.mime;
        invoiceOriginalName = input.invoice.originalName.trim().slice(0, 180) || `invoice.${inspected.extension}`;
        invoicePath = `branches/${input.branchId}/purchase-logs/${randomUUID()}/${safeFileName(invoiceOriginalName, inspected.extension)}`;
        const upload = await purchaseInvoiceStorage.upload(invoicePath, input.invoice.bytes, {
          contentType: inspected.mime,
          cacheControl: "300",
          upsert: false,
          metadata: { byteSize: String(input.invoice.bytes.length), mimeType: inspected.mime, originalName: invoiceOriginalName },
        });
        if (upload.error) throw new AdminOperationError();
      }
      try {
        const rows = await normalizePurchaseRows(await rpc("create_branch_purchase_log", {
          actor_user_id: input.actorUserId,
          target_branch_id: input.branchId,
          payload: { ...input.payload, invoice_storage_path: invoicePath, invoice_original_name: invoiceOriginalName },
        }));
        return { purchase_log: rows[0] };
      } catch (error) {
        if (invoicePath) {
          await purchaseInvoiceStorage.remove([invoicePath]);
        }
        void invoiceMime;
        throw error;
      }
    },
    async updatePurchaseLogPaymentStatus(input) {
      const rows = await normalizePurchaseRows(await rpc("update_branch_purchase_log_payment_status", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        target_purchase_log_id: input.purchaseLogId,
        new_payment_status: input.paymentStatus,
        new_reimbursement_note: input.reimbursementNote ?? null,
      }));
      return { purchase_log: rows[0] };
    },
    async listSupplierReceivings(actorUserId, branchId) {
      return { supplier_receivings: await normalizeSupplierReceivingRows(await rpc("list_branch_supplier_receivings", {
        actor_user_id: actorUserId,
        target_branch_id: branchId,
      })) };
    },
    async listBranchSuppliers(actorUserId, branchId) {
      return { suppliers: normalizeBranchSupplierRows(await rpc("list_branch_suppliers", {
        actor_user_id: actorUserId,
        target_branch_id: branchId,
      })) };
    },
    async createBranchSupplier(input) {
      const rows = normalizeBranchSupplierRows(await rpc("create_branch_supplier", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        payload: {
          supplier_name_en: input.supplierNameEn,
          supplier_name_ar: input.supplierNameAr ?? null,
        },
      }));
      if (rows.length !== 1) throw new AdminOperationError();
      return { supplier: rows[0] };
    },
    async createSupplierReceiving(input) {
      let photoPath: string | null = null;
      let photoOriginalName: string | null = null;
      if (input.photo) {
        const inspected = inspectSupplierReceivingPhoto(input.photo.bytes, input.photo.mimeType);
        photoOriginalName = input.photo.originalName.trim().slice(0, 180) || `photo.${inspected.extension}`;
        photoPath = `branches/${input.branchId}/supplier-receivings/${randomUUID()}/${safeFileName(photoOriginalName, inspected.extension, "photo")}`;
        const upload = await supplierReceivingPhotoStorage.upload(photoPath, input.photo.bytes, {
          contentType: inspected.mime,
          cacheControl: "300",
          upsert: false,
          metadata: { byteSize: String(input.photo.bytes.length), mimeType: inspected.mime, originalName: photoOriginalName },
        });
        if (upload.error) throw new AdminOperationError();
      }
      try {
        const rows = await normalizeSupplierReceivingRows(await rpc("create_branch_supplier_receiving", {
          actor_user_id: input.actorUserId,
          target_branch_id: input.branchId,
          payload: { ...input.payload, photo_storage_path: photoPath, photo_original_name: photoOriginalName },
        }));
        return { supplier_receiving: rows[0] };
      } catch (error) {
        if (photoPath) {
          await supplierReceivingPhotoStorage.remove([photoPath]);
        }
        throw error;
      }
    },
    async listSupervisorMaintenanceIssues(actorUserId, branchId) {
      return { maintenance_issues: normalizeMaintenanceIssueRows(await rpc("list_supervisor_maintenance_issues", {
        actor_user_id: actorUserId,
        target_branch_id: branchId,
      })) };
    },
    async createSupervisorMaintenanceIssue(input) {
      const rows = normalizeMaintenanceIssueRows(await rpc("create_supervisor_maintenance_issue", {
        actor_user_id: input.actorUserId,
        target_branch_id: input.branchId,
        payload: input.payload,
      }));
      if (rows.length !== 1) throw new AdminOperationError();
      return { maintenance_issue: rows[0] };
    },
    async listMaintenanceIssues(input) {
      return { maintenance_issues: normalizeMaintenanceIssueRows(await rpc("list_maintenance_issues", {
        actor_user_id: input.actorUserId ?? null,
        access_user_id: input.accessUserId ?? null,
        target_organization_id: input.organizationId,
      })) };
    },
    async updateMaintenanceIssue(input) {
      const rows = normalizeMaintenanceIssueRows(await rpc("update_maintenance_issue", {
        actor_user_id: input.actorUserId ?? null,
        access_user_id: input.accessUserId ?? null,
        target_issue_id: input.issueId,
        new_status: input.status,
        new_note: input.note ?? null,
      }));
      if (rows.length !== 1) throw new AdminOperationError();
      return { maintenance_issue: rows[0] };
    },
    async listMaintenancePurchases(actorUserId,issueId){return{maintenance_purchases:await normalizeMaintenancePurchases(await rpc("list_maintenance_purchase_logs",{actor_user_id:actorUserId,target_issue_id:issueId}))};},
    async createMaintenancePurchase(input){
      const receipts=input.receipts?.filter((receipt)=>receipt.bytes.length>0)??[];
      if(receipts.length>MAX_MAINTENANCE_PURCHASE_PHOTOS)throw new AdminOperationError();
      const purchaseId=randomUUID();
      const uploaded:Array<{id:string;storage_path:string;original_filename:string;mime_type:z.infer<typeof maintenancePurchaseReceiptMime>;size_bytes:number;position:number}>=[];
      try{
        for(const [index,receipt]of receipts.entries()){
          const inspected=inspectPurchaseInvoice(receipt.bytes,receipt.mimeType);
          const originalName=safeOriginalFileName(receipt.originalName,`receipt-${index+1}.${inspected.extension}`);
          const storageName=`${randomUUID()}-${safeFileName(receipt.originalName,inspected.extension,`receipt-${index+1}`)}`;
          const path=`maintenance/${input.issueId}/purchases/${purchaseId}/${storageName}`;
          const upload=await maintenanceReceiptStorage.upload(path,receipt.bytes,{contentType:inspected.mime,upsert:false,metadata:{byteSize:String(receipt.bytes.length),mimeType:inspected.mime,originalName}});
          if(upload.error)throw new AdminOperationError();
          uploaded.push({id:randomUUID(),storage_path:path,original_filename:originalName,mime_type:inspected.mime,size_bytes:receipt.bytes.length,position:index+1});
        }
        const first=uploaded[0];
        const rows=await normalizeMaintenancePurchaseMutations(await rpc("create_maintenance_purchase_log",{actor_user_id:input.actorUserId,target_issue_id:input.issueId,payload:{...input.payload,purchase_id:purchaseId,receipt_storage_path:first?.storage_path??null,receipt_original_name:first?.original_filename??null,attachments:uploaded}}));
        return{maintenance_purchase:rows[0]};
      }catch(error){
        if(uploaded.length>0)await maintenanceReceiptStorage.remove(uploaded.map((item)=>item.storage_path));
        throw error;
      }
    },
    async reimburseMaintenancePurchase(input){const rows=await normalizeMaintenancePurchaseMutations(await rpc("reimburse_maintenance_purchase_log",{actor_user_id:input.actorUserId,target_purchase_id:input.purchaseId,new_note:input.reimbursementNote??null}));return{maintenance_purchase:rows[0]};},
    async listMaintenancePurchaseHistory(input){return{maintenance_purchases:await normalizeManagedMaintenancePurchases(await rpc("list_maintenance_purchase_history",{actor_user_id:input.actorUserId}))};},
    async getSupervisorDailyAuditCurrentState(input){return dailyAuditCurrent.parse(await rpcObject("get_supervisor_daily_audit_current_state",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_business_date:input.businessDate}));},
    async saveSupervisorDailyAuditDraft(input){return dailyAuditCurrent.parse(await rpcObject("save_supervisor_daily_audit_draft",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_business_date:input.businessDate,expected_revision:input.expectedRevision,auditor_kind:input.auditorKind,auditor_id:input.auditorId,auditor_name_snapshot:input.auditorDisplayName,access_credential_version:input.accessCredentialVersion,items:input.items}));},
    async submitSupervisorDailyAudit(input){return dailyAuditCurrent.parse(await rpcObject("submit_supervisor_daily_audit",{actor_user_id:input.actorUserId,target_branch_id:input.branchId,target_business_date:input.businessDate,expected_revision:input.expectedRevision,auditor_kind:input.auditorKind,auditor_id:input.auditorId,auditor_name_snapshot:input.auditorDisplayName,access_credential_version:input.accessCredentialVersion,items:input.items,idempotency_key:input.idempotencyKey??null}));},
    async listManagedMaintenancePurchases(input){return{maintenance_purchases:await normalizeManagedMaintenancePurchases(await rpc("list_managed_maintenance_purchases",{actor_user_id:input.actorUserId,target_organization_id:input.organizationId,branch_filter:input.branchId??null,issue_status_filter:input.issueStatus??null,payment_status_filter:input.paymentStatus??null,vendor_filter:input.vendor??null,date_from_filter:input.dateFrom??null,date_to_filter:input.dateTo??null}))};},
    async getManagedOperationsSummary(input) {
      return managementOperationsSummarySchema.parse(await rpcObject("get_managed_operations_summary", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        branch_filter: input.branchId ?? null,
        requested_month: `${input.month}-01`,
      }));
    },
    async listManagedStaff(input) {
      const rows = z.array(z.object({
        staff_id: uuid, display_name: z.string(), employment_status: employment,
        staff_code: staffCode, country_code: countryCode,
        branch_id: uuid, branch_name: z.string(), supervisor_user_id: uuid.nullable(),
        supervisor_name: z.string().nullable(), team_id: uuid.nullable(), assignment_id: uuid.nullable(),
        operational_roles: roles.nullable(), duty_status: duty.nullable(),
        total_count: z.number().int().nonnegative(),
      }).strict()).max(50).parse(await rpc("list_managed_operational_staff", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        requested_page: input.page, requested_page_size: input.pageSize,
        search_term: input.search ?? null, branch_filter: input.branchId ?? null,
        supervisor_filter: input.supervisorUserId ?? null,
        role_filter: input.role ?? null, employment_filter: input.employmentStatus ?? null,
        requested_date: input.date ?? null,
      }));
      return {
        staff: rows.map(({ total_count, ...row }) => {
          void total_count;
          return row;
        }),
        total: rows[0]?.total_count ?? 0,
      };
    },
    async listManagedEmployeeTeam(input) {
      return z.object({
        employees: z.array(z.object({
          staff_id: uuid, display_name: z.string(), staff_code: staffCode, employment_status: employment,
          country_code: countryCode, company_name: optionalStaffText, iqama_number: optionalStaffText, phone_number: optionalStaffText, email: optionalStaffText,
          branch_id: uuid, branch_name: z.string(), branch_name_ar: optionalStaffText, supervisor_name: optionalStaffText, supervisor_name_ar: optionalStaffText,
          assignment_id: uuid.nullable(), operational_team_id: uuid.nullable(), operational_team_name: optionalStaffText,
          operational_roles: roles.nullable(), duty_status: duty.nullable(),
          supervisor_training_status: z.enum(["training"]).nullable(),
        }).strict()).max(500),
        operational_teams: z.array(z.object({
          id: uuid, branch_id: uuid, branch_name: z.string(), branch_name_ar: optionalStaffText,
          name: z.string(), active: z.boolean(),
        }).strict()).max(500),
        health_cards: z.array(healthCardRow.extend({ display_name: z.string(), branch_id: uuid, branch_name: z.string(), branch_name_ar: optionalStaffText }).strict()).max(500),
        monthly_evaluations: z.array(monthlyEvaluationRow.extend({ display_name: z.string(), branch_id: uuid, branch_name: z.string(), branch_name_ar: optionalStaffText }).strict()).max(500),
      }).strict().parse(await rpcObject("list_managed_employee_team", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        branch_filter: input.branchId ?? null, requested_month: `${input.month}-01`,
      }));
    },
    async startManagedOperationalStaffSupervisorTraining(input) {
      return rpcObject("start_managed_operational_staff_supervisor_training",{
        actor_user_id:input.actorUserId,target_organization_id:input.organizationId,target_staff_id:input.staffId,
      });
    },
    async cancelManagedOperationalStaffSupervisorTraining(input) {
      return rpcObject("cancel_managed_operational_staff_supervisor_training",{
        actor_user_id:input.actorUserId,target_organization_id:input.organizationId,target_staff_id:input.staffId,
      });
    },
    async getManagedOperationalStaffSupervisorTrainingPromotionState(input) {
      return rpcObject("get_managed_supervisor_training_promotion_state",{
        actor_user_id:input.actorUserId,target_organization_id:input.organizationId,target_staff_id:input.staffId,
      });
    },
    async promoteManagedOperationalStaffSupervisorTraining(input) {
      return rpcObject("promote_managed_operational_staff_supervisor_training",{
        actor_user_id:input.actorUserId,target_organization_id:input.organizationId,target_staff_id:input.staffId,
        new_supervisor_user_id:input.newSupervisorUserId,new_supervisor_full_name:input.fullName,
        new_supervisor_full_name_ar:input.fullNameAr??null,
      });
    },
    async getManagedAnnualEvaluationWorkspace(input) {
      return annualEvaluationWorkspaceSchema.parse(await rpcObject("get_managed_annual_evaluation_workspace",{
        p_actor_user_id:input.actorUserId,p_organization_id:input.organizationId,p_evaluation_year:input.evaluationYear,
        p_branch_id:input.branchId??null,p_subject_type:input.subjectType??null,p_subject_id:input.subjectId??null,p_state:input.state??null,
      }));
    },
    async getManagedAnnualEvaluationDetail(input) {
      return annualEvaluationDetailSchema.parse(await rpcObject("get_managed_annual_evaluation_detail",{
        p_actor_user_id:input.actorUserId,p_organization_id:input.organizationId,p_evaluation_id:input.evaluationId,
      }));
    },
    async saveManagedAnnualEvaluationDraft(input) {
      return annualEvaluationDetailSchema.parse(await rpcObject("save_managed_annual_evaluation_draft",{
        p_actor_user_id:input.actorUserId,p_organization_id:input.organizationId,p_branch_id:input.branchId,
        p_evaluation_year:input.evaluationYear,p_subject_type:input.subjectType,
        p_supervisor_user_id:input.subjectType==="supervisor"?input.subjectId:null,
        p_operational_staff_id:input.subjectType==="training_supervisor"||input.subjectType==="employee"?input.subjectId:null,
        p_expected_revision:input.expectedRevision,p_scores:input.scores,
      }));
    },
    async submitManagedAnnualEvaluation(input) {
      return annualEvaluationDetailSchema.parse(await rpcObject("submit_managed_annual_evaluation",{
        p_actor_user_id:input.actorUserId,p_organization_id:input.organizationId,p_evaluation_id:input.evaluationId,
        p_expected_revision:input.expectedRevision,
      }));
    },
    async listManagedPurchaseLogs(input) {
      return { purchase_logs: await normalizeManagedPurchaseRows(await rpc("list_managed_purchase_logs", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        branch_filter: input.branchId ?? null, category_filter: input.category ?? null,
        payment_status_filter: input.paymentStatus ?? null, date_from_filter: input.dateFrom ?? null,
        date_to_filter: input.dateTo ?? null,
      })) };
    },
    async listManagedSupplierReceivings(input) {
      return { supplier_receivings: await normalizeManagedSupplierReceivingRows(await rpc("list_managed_supplier_receivings", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        branch_filter: input.branchId ?? null, category_filter: input.category ?? null,
        supplier_filter: input.supplierId ?? null, date_from_filter: input.dateFrom ?? null,
        date_to_filter: input.dateTo ?? null,
      })) };
    },
    async listManagedMaintenanceIssues(input) {
      return { maintenance_issues: normalizeManagedMaintenanceIssueRows(await rpc("list_managed_maintenance_issues", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId, branch_filter: input.branchId ?? null,
        status_filter: input.status ?? null, priority_filter: input.priority ?? null, category_filter: input.category ?? null,
        date_from_filter: input.dateFrom ?? null, date_to_filter: input.dateTo ?? null,
      })) };
    },
    async listManagedTeams(actorUserId, organizationId) {
      return {
        teams: z.array(z.object({
          team_id: uuid, branch_id: uuid, branch_name: z.string(),
          supervisor_user_id: uuid, supervisor_name: z.string().nullable(),
          active: z.boolean(), operational_staff_count: z.number().int().nonnegative(),
        }).strict()).max(500).parse(await rpc("list_managed_supervisor_teams", {
          actor_user_id: actorUserId, target_organization_id: organizationId,
        })),
      };
    },
    async listEligibleSupervisors(actorUserId, organizationId, branchId) {
      return {
        supervisors: z.array(z.object({
          user_id: uuid, full_name: z.string().nullable(),
          assignments: z.array(z.object({
            team_id: uuid, active: z.boolean(),
          }).strict()).max(200),
        }).strict()).max(200).parse(await rpc("list_eligible_branch_supervisors", {
          actor_user_id: actorUserId, target_organization_id: organizationId, target_branch_id: branchId,
        })),
      };
    },
  };
}

export function branchLocalDate(timezone: string, now: Date): string {
  if (!Number.isFinite(now.getTime())) throw new Error("Invalid clock value.");
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  if (!values.year || !values.month || !values.day) throw new Error("Invalid timezone.");
  return `${values.year}-${values.month}-${values.day}`;
}
