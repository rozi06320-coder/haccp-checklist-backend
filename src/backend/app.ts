import { randomUUID, timingSafeEqual } from "node:crypto";
import { performance } from "node:perf_hooks";
import express, { type Express, type NextFunction, type Request, type Response } from "express";
import rateLimit, { ipKeyGenerator } from "express-rate-limit";
import helmet from "helmet";
import { z } from "zod";
import { managementOverviewSchema } from "./management-overview-contract";
import { managementOperationsSummarySchema } from "../lib/contracts/management-operations-summary";
import { managementSalesTrackingMonthlySummarySchema } from "../lib/contracts/management-sales-tracking-monthly";
import { annualEvaluationDetailSchema, annualEvaluationScoreSchema, annualEvaluationSubjectTypeSchema, annualEvaluationWorkspaceSchema } from "../lib/contracts/annual-evaluation";
import { requireAuthentication } from "./auth";
import { AdminAccessError, AdminConflictError, AdminDuplicatePersonCodeError, AdminDuplicateStaffCodeError, AdminInputError, AdminNotFoundError, ProvisioningStageError, type DailyAuditAccessUserCredential, type ManagerPinCredential } from "./admin";
import type { BackendConfig } from "./config";
import {
  createDefaultDependencies,
  type BackendDependencies,
} from "./dependencies";
import { errorHandler, HttpError, notFoundHandler } from "./errors";
import { branchLocalDate, MAX_MAINTENANCE_ISSUE_PHOTO_BYTES, MAX_MAINTENANCE_PURCHASE_PHOTOS, MAX_PURCHASE_INVOICE_BYTES, MAX_SUPPLIER_RECEIVING_PHOTO_BYTES, OperationalAccessError, OperationalConflictError, OperationalDuplicateColdStorageEquipmentCodeError, OperationalDuplicateStaffCodeError, OperationalHygieneSubmittedError, OperationalInputError, purchaseInvoiceMime, supplierReceivingPhotoMime, maintenanceIssuePhotoMime, maintenancePurchaseReceiptMime } from "./operational";
import { ChecklistAccessError, ChecklistConflictError, ChecklistInputError, ManagementOverviewUnavailableError } from "./checklist-persistence";
import { evidenceMimeSchema, EvidenceAccessError, EvidenceConflictError, EvidenceInputError, EvidenceUnavailableError, MAX_EVIDENCE_BYTES } from "./evidence";
import { BrandingAccessError, BrandingInputError, BrandingUnavailableError, MAX_BRANDING_BYTES } from "./branding";
import { MaintenancePushAccessError, MaintenancePushConflictError, MaintenancePushInputError, MaintenancePushUnavailableError } from "./maintenance-push";
import type { UserContext } from "./user-context";
import { validateDailyAuditGrant } from "./daily-audit-grant";
import { decodeUploadFilename } from "../lib/internal-api/upload-filename";
import { employeeCountryCodes } from "../lib/employee-countries";

const organizationIdSchema = z.uuid();
const branchIdSchema = z.uuid();
const staffIdSchema = z.uuid();
const operationalRoleSchema = z.enum(["kitchen", "dispatcher", "production", "front_of_house", "cleaner", "cashier"]);
const dateOnlySchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((value) => {
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
});
const normalizedNameSchema = z.string().max(120)
  .transform((value) => value.trim().replace(/\s+/gu, " "))
  .pipe(z.string().min(1).max(120));
const branchCodeSchema = z.string().max(120)
  .transform((value) => value.trim().toUpperCase())
  .pipe(z.string().min(1).max(120).regex(/^[A-Z0-9-]+$/));
const coldStorageEquipmentCodeSchema = z.string()
  .transform((value) => value.trim().toUpperCase())
  .pipe(z.string().min(1).max(24).regex(/^[A-Z0-9-]+$/));
const branchCitySchema = z.string().max(120)
  .transform((value) => value.trim().replace(/\s+/gu, " "))
  .pipe(z.string().min(1).max(120));
const companyNameSchema = z.string().max(160)
  .transform((value) => value.trim().replace(/\s+/gu, " "))
  .pipe(z.string().min(1).max(160));
const staffCodeSchema = z.string().max(80).optional().nullable().transform((value) => {
  const trimmed = (value ?? "").trim();
  return trimmed.length ? trimmed : null;
});
const countryCodeSchema = z.preprocess((value) => {
  if (typeof value !== "string") return value ?? null;
  const trimmed = value.trim();
  return trimmed ? trimmed.toUpperCase() : null;
}, z.enum(employeeCountryCodes).nullable()).optional().transform((value) => value ?? null);
const optionalStaffTextSchema = (max: number) => z.string().max(max).optional().nullable().transform((value) => {
  const trimmed = (value ?? "").trim();
  return trimmed.length ? trimmed : null;
});
const optionalDisplayNameSchema = z.string().max(120).optional().nullable().transform((value) => {
  const trimmed = (value ?? "").trim().replace(/\s+/gu, " ");
  return trimmed.length ? trimmed : null;
});
const optionalDateOnlySchema = dateOnlySchema.optional().nullable().transform((value) => value ?? null);
const optionalStaffEmailSchema = z.string().max(254).optional().nullable().transform((value) => {
  const trimmed = (value ?? "").trim();
  return trimmed.length ? trimmed : null;
}).pipe(z.email().nullable());
const optionalStaffDateSchema = z.union([z.iso.date(), z.literal(""), z.null()]).optional().transform((value) => value || null);
const createOperationalStaffBodySchema = z.object({
  operational_team_id: z.uuid(),
  display_name: normalizedNameSchema,
  company_name: companyNameSchema,
  staff_code: staffCodeSchema,
  country_code: countryCodeSchema,
  iqama_number: optionalStaffTextSchema(80),
  iqama_expiry_date: optionalStaffDateSchema,
  phone_number: optionalStaffTextSchema(40),
  email: optionalStaffEmailSchema,
  primary_role: operationalRoleSchema,
  secondary_role: operationalRoleSchema.optional(),
}).strict().superRefine((value, context) => {
  if (value.secondary_role === value.primary_role) {
    context.addIssue({ code: "custom", path: ["secondary_role"], message: "Roles must be unique." });
  }
});
const createSupervisorOwnedTeamBodySchema = z.object({
  name: z.string().max(80).transform((value) => value.trim().replace(/\s+/gu, " ")).pipe(z.string().min(1).max(80)),
}).strict();
const supervisorOwnedTeamResponseSchema = z.object({
  team: z.object({
    id: z.uuid(),
    organization_id: z.uuid(),
    branch_id: z.uuid(),
    name: z.string(),
    active: z.boolean(),
    legacy_supervisor_team_id: z.uuid(),
    supervisor_user_id: z.uuid(),
    assignment_role: z.literal("primary"),
    can_write: z.literal(true),
  }).strict(),
}).strict();
const operationalStaffImportRowSchema = z.object({
  row_number: z.number().int().min(2).max(10000),
  staff_code: staffCodeSchema,
  display_name: normalizedNameSchema,
  primary_role: operationalRoleSchema,
  secondary_role: operationalRoleSchema.nullable().optional().transform((value) => value ?? null),
  country_code: countryCodeSchema,
  company_name: optionalStaffTextSchema(160),
  iqama_number: optionalStaffTextSchema(80),
  iqama_expiry_date: optionalStaffDateSchema,
  phone_number: optionalStaffTextSchema(40),
  email: optionalStaffEmailSchema,
}).strict().superRefine((value, context) => {
  if (value.secondary_role && value.secondary_role === value.primary_role) {
    context.addIssue({ code: "custom", path: ["secondary_role"], message: "Roles must be unique." });
  }
});
const createOperationalStaffImportPreviewBodySchema = z.object({
  operational_team_id: z.uuid(),
  rows: z.array(operationalStaffImportRowSchema).max(250),
}).strict();
const confirmOperationalStaffImportBodySchema = z.object({
  operational_team_id: z.uuid(),
  preview_token: z.uuid(),
}).strict();
const updateOperationalStaffBodySchema = z.object({
  display_name: normalizedNameSchema,
  company_name: companyNameSchema,
  staff_code: staffCodeSchema,
  country_code: countryCodeSchema,
  iqama_number: optionalStaffTextSchema(80),
  iqama_expiry_date: optionalStaffDateSchema,
  phone_number: optionalStaffTextSchema(40),
  email: optionalStaffEmailSchema,
  employment_status: z.literal("active"),
  primary_role: operationalRoleSchema,
  secondary_role: operationalRoleSchema.optional(),
}).strict().superRefine((value, context) => {
  if (value.secondary_role === value.primary_role) {
    context.addIssue({ code: "custom", path: ["secondary_role"], message: "Roles must be unique." });
  }
});
const dutyStatusBodySchema = z.object({
  duty_status: z.enum(["on_duty", "day_off", "on_vacation"]),
}).strict();
const moveOperationalStaffBodySchema = z.object({
  expected_assignment_id: z.uuid(),
  operational_team_id: z.uuid(),
}).strict();
const transferDestinationsQuerySchema = z.object({
  expected_assignment_id: z.uuid(),
}).strict();
const branchTransferBodySchema = z.object({
  expected_assignment_id: z.uuid(),
  destination_branch_id: z.uuid(),
  destination_team_id: z.uuid(),
}).strict();
const leaveOperationalStaffBodySchema = z.object({ expected_assignment_id: z.uuid() }).strict();
const promoteSupervisorTrainingBodySchema = z.object({
  full_name: normalizedNameSchema,
  full_name_ar: optionalDisplayNameSchema,
  email: z.string().trim().toLowerCase().max(254).pipe(z.email()),
  temporary_password: z.string().min(6).max(128),
}).strict();
const healthCardStatusBodySchema = z.object({
  certificate_number: optionalStaffTextSchema(120),
  status: z.enum(["not_done", "pending", "passed", "done_waiting_id", "failed"]),
  place_of_issue: optionalStaffTextSchema(120),
  expiry_date: optionalStaffDateSchema,
  date_issue: optionalStaffDateSchema,
  occupation: optionalStaffTextSchema(120),
  company: optionalStaffTextSchema(160),
  notes: optionalStaffTextSchema(2000),
}).strict();
const monthOnlySchema = z.string().regex(/^\d{4}-\d{2}$/).refine((value) => {
  const [year, month] = value.split("-").map(Number);
  return year >= 2000 && year <= 2100 && month >= 1 && month <= 12;
});
const monthlyEvaluationQuerySchema = z.object({
  month: monthOnlySchema,
}).strict();
const monthlyEvaluationScoreBodySchema = z.object({
  section: z.string().max(80).transform((value) => value.trim().replace(/\s+/gu, " ")).pipe(z.string().min(1).max(80)),
  factor_key: z.string().max(120).transform((value) => value.trim()).pipe(z.string().min(1).max(120)),
  factor_label: z.string().max(160).transform((value) => value.trim().replace(/\s+/gu, " ")).pipe(z.string().min(1).max(160)),
  rating: z.number().int().min(1).max(5).nullable(),
  comment: optionalStaffTextSchema(2000),
}).strict();
const monthlyEvaluationBodySchema = z.object({
  evaluation_month: monthOnlySchema,
  evaluator_name: optionalStaffTextSchema(120),
  status: z.enum(["draft", "completed"]),
  scores: z.array(monthlyEvaluationScoreBodySchema).min(1).max(100),
}).strict();
const purchaseLogCategorySchema = z.enum(["stationery", "kitchen", "equipment", "food_item"]);
const purchaseLogPaymentStatusSchema = z.enum(["unpaid", "reimbursed"]);
const purchaseLogBodySchema = z.object({
  category: purchaseLogCategorySchema,
  item_name: normalizedNameSchema,
  quantity: z.union([z.number(), z.string()]).transform(Number).pipe(z.number().positive()),
  amount: z.union([z.number(), z.string()]).transform(Number).pipe(z.number().nonnegative()),
  vendor_name: z.string().max(120).optional().nullable().transform((value) => {
    const trimmed = (value ?? "").trim().replace(/\s+/gu, " ");
    return trimmed.length ? trimmed : "N/A";
  }),
  purchase_date: dateOnlySchema,
  notes: optionalStaffTextSchema(2000),
  payment_status: purchaseLogPaymentStatusSchema.default("unpaid"),
  reimbursement_note: optionalStaffTextSchema(500),
}).strict();
const purchaseLogPaymentStatusBodySchema = z.object({
  payment_status: purchaseLogPaymentStatusSchema,
  reimbursement_note: optionalStaffTextSchema(500),
}).strict();
const purchaseLogResponseRowSchema = z.object({
  id: z.uuid(),
  branch_id: z.uuid(),
  branch_name: z.string().optional(),
  category: purchaseLogCategorySchema,
  item_name: z.string(),
  quantity: z.union([z.number(), z.string()]),
  amount: z.union([z.number(), z.string()]),
  vendor_name: z.string(),
  purchase_date: dateOnlySchema,
  notes: z.string().nullable(),
  payment_status: purchaseLogPaymentStatusSchema,
  reimbursement_note: z.string().nullable(),
  reimbursed_at: z.string().nullable(),
  reimbursed_by: z.uuid().nullable(),
  invoice_original_name: z.string().nullable(),
  invoice_url: z.string().nullable().optional(),
  created_by: z.uuid(),
  created_at: z.string(),
  updated_at: z.string(),
});
const purchaseLogListResponseSchema = z.object({ purchase_logs: z.array(purchaseLogResponseRowSchema).max(500) }).strict();
const purchaseLogMutationResponseSchema = z.object({ purchase_log: purchaseLogResponseRowSchema }).strict();
const managedPurchaseLogRowSchema = purchaseLogResponseRowSchema.extend({ created_by_name: z.string().nullable().optional() }).strict();
const managedPurchaseLogListResponseSchema = z.object({ purchase_logs: z.array(managedPurchaseLogRowSchema).max(500) }).strict();
const supplierReceivingCategorySchema = z.enum(["raw", "frozen", "juice"]);
const supplierReceivingUnits = ["pcs", "bag", "kg", "box"] as const;
const supplierReceivingUnitSchema = z.preprocess(
  (value) => typeof value === "string" ? value.trim() : value,
  z.enum(supplierReceivingUnits),
);
const supplierBodySchema = z.object({
  supplier_name_en: normalizedNameSchema,
  supplier_name_ar: optionalStaffTextSchema(120),
}).strict();
const supplierReceivingBodySchema = z.object({
  category: supplierReceivingCategorySchema,
  supplier_id: z.uuid().optional().nullable(),
  supplier_name_en: normalizedNameSchema.optional(),
  supplier_name_ar: optionalStaffTextSchema(120),
  quantity: z.union([z.number(), z.string()]).transform(Number).pipe(z.number().positive()),
  unit: supplierReceivingUnitSchema,
  notes: optionalStaffTextSchema(2000),
}).strict().superRefine((value, context) => {
  if (!value.supplier_id && !value.supplier_name_en) {
    context.addIssue({ code: "custom", path: ["supplier_name_en"], message: "Supplier name is required." });
  }
});
const branchSupplierResponseRowSchema = z.object({
  id: z.uuid(),
  branch_id: z.uuid(),
  supplier_name_en: z.string(),
  supplier_name_ar: z.string().nullable(),
  created_at: z.string(),
  updated_at: z.string(),
});
const branchSupplierListResponseSchema = z.object({ suppliers: z.array(branchSupplierResponseRowSchema).max(500) }).strict();
const branchSupplierMutationResponseSchema = z.object({ supplier: branchSupplierResponseRowSchema }).strict();
const supplierReceivingResponseRowSchema = z.object({
  id: z.uuid(),
  branch_id: z.uuid(),
  branch_name: z.string().optional(),
  supplier_id: z.uuid().nullable(),
  category: supplierReceivingCategorySchema,
  supplier_name_en: z.string(),
  supplier_name_ar: z.string().nullable(),
  quantity: z.union([z.number(), z.string()]),
  unit: z.string(),
  notes: z.string().nullable(),
  photo_original_name: z.string().nullable(),
  photo_url: z.string().nullable().optional(),
  created_by: z.uuid(),
  created_at: z.string(),
  updated_at: z.string(),
});
const supplierReceivingListResponseSchema = z.object({ supplier_receivings: z.array(supplierReceivingResponseRowSchema).max(500) }).strict();
const supplierReceivingMutationResponseSchema = z.object({ supplier_receiving: supplierReceivingResponseRowSchema }).strict();
const managedSupplierReceivingRowSchema = supplierReceivingResponseRowSchema.extend({ created_by_name: z.string().nullable().optional() }).strict();
const managedSupplierReceivingListResponseSchema = z.object({ supplier_receivings: z.array(managedSupplierReceivingRowSchema).max(500) }).strict();
const maintenanceIssueCategorySchema = z.enum(["equipment", "plumbing", "electrical", "refrigeration", "building", "other"]);
const maintenanceIssuePrioritySchema = z.enum(["low", "normal", "high", "urgent"]);
const maintenanceIssueStatusSchema = z.enum(["new", "in_progress", "waiting_parts", "resolved", "closed"]);
const maintenancePurchaseUnitSchema = z.enum(["pcs", "meter", "kg", "box", "bag", "roll", "set", "liter", "other"]);
const maintenancePurchaseTypeSchema = z.enum(["issue", "general"]);
const maintenancePurchaseScopeSchema = z.enum(["branch", "office", "other"]);
const maintenancePurchaseCategorySchema = z.enum(["spare_parts", "tools_equipment", "electrical", "plumbing", "hvac_refrigeration", "kitchen_equipment", "fuel_petrol", "transportation", "technician_contractor", "building_facility", "safety_equipment", "it_network", "general_supplies", "other"]);
const maintenanceIssueBodySchema = z.object({
  title: normalizedNameSchema,
  category: maintenanceIssueCategorySchema,
  priority: maintenanceIssuePrioritySchema,
  description: optionalStaffTextSchema(2000),
  location: optionalStaffTextSchema(160),
}).strict();
const maintenanceIssueUpdateBodySchema = z.object({
  status: maintenanceIssueStatusSchema,
  note: optionalStaffTextSchema(2000),
}).strict();
const maintenanceIssuePhotoResponseSchema = z.object({
  url: z.string().nullable(),
  mime_type: z.string().nullable(),
  size_bytes: z.number().nullable(),
  original_filename: z.string().nullable(),
}).strict().nullable();
const maintenanceIssuePhotoUploadSchema = z.object({
  original_name: z.string().max(180).optional().nullable(),
  mime_type: maintenanceIssuePhotoMime,
  content_base64: z.string().min(1),
}).strict();
const maintenanceIssueCreateEnvelopeSchema = z.object({
  issue: maintenanceIssueBodySchema,
  before_photo: maintenanceIssuePhotoUploadSchema.nullable().optional(),
}).strict();
const maintenanceIssueUpdateEnvelopeSchema = z.object({
  issue: maintenanceIssueUpdateBodySchema,
  repair_photo: maintenanceIssuePhotoUploadSchema.nullable().optional(),
}).strict();
const maintenanceIssueUpdateResponseRowSchema = z.object({
  id: z.uuid(),
  status: maintenanceIssueStatusSchema,
  note: z.string().nullable(),
  updated_by: z.uuid().nullable(),
  updated_by_access_user_id: z.uuid().nullable().optional(),
  updated_by_name: z.string().nullable(),
  created_at: z.string(),
}).strict();
const maintenanceIssueResponseRowSchema = z.object({
  id: z.uuid(),
  branch_id: z.uuid().nullable(),
  branch_name: z.string(),
  title: z.string(),
  category: maintenanceIssueCategorySchema,
  priority: maintenanceIssuePrioritySchema,
  status: maintenanceIssueStatusSchema,
  description: z.string().nullable(),
  location: z.string().nullable(),
  reported_by: z.uuid(),
  reporter_name: z.string().nullable(),
  assigned_to: z.uuid().nullable(),
  created_at: z.string(),
  updated_at: z.string(),
  updates: z.array(maintenanceIssueUpdateResponseRowSchema).optional(),
  before_photo: maintenanceIssuePhotoResponseSchema.optional(),
  after_photo: maintenanceIssuePhotoResponseSchema.optional(),
}).strict();
const maintenanceIssueListResponseSchema = z.object({ maintenance_issues: z.array(maintenanceIssueResponseRowSchema).max(1000) }).strict();
const maintenanceIssueMutationResponseSchema = z.object({ maintenance_issue: maintenanceIssueResponseRowSchema }).strict();
const managedMaintenanceIssueRowSchema=maintenanceIssueResponseRowSchema.omit({assigned_to:true}).strict();
const managedMaintenanceIssueListResponseSchema=z.object({maintenance_issues:z.array(managedMaintenanceIssueRowSchema).max(1000)}).strict();
const pushSubscriptionBodySchema = z.object({
  endpoint: z.url().max(4096),
  keys: z.object({
    p256dh: z.string().trim().min(16).max(512).regex(/^[A-Za-z0-9_-]+$/),
    auth: z.string().trim().min(8).max(256).regex(/^[A-Za-z0-9_-]+$/),
  }).strict(),
}).strict();
const pushSubscriptionDeleteBodySchema = z.object({
  endpoint: z.url().max(4096),
}).strict();
const pushSubscriptionResponseSchema = z.object({
  subscription: z.object({
    id: z.uuid(),
    user_id: z.uuid(),
    endpoint: z.string(),
    disabled_at: z.string().nullable(),
  }).nullable(),
}).strict();
const supervisorPushRunResponseSchema = z.object({
  evaluated_at: z.string(),
  deliveries_attempted: z.number().int().nonnegative(),
  deliveries_sent: z.number().int().nonnegative(),
}).strict();
const maintenancePurchaseAttachmentSchema=z.object({id:z.uuid(),original_filename:z.string().nullable(),mime_type:z.string().nullable(),size_bytes:z.number().nullable(),position:z.number().int().min(1).max(MAX_MAINTENANCE_PURCHASE_PHOTOS),url:z.string().nullable()}).strict();
const maintenancePurchaseRowSchema=z.object({id:z.uuid(),branch_id:z.uuid().nullable(),purchase_type:maintenancePurchaseTypeSchema,purchase_scope:maintenancePurchaseScopeSchema,destination:z.string().nullable(),category:maintenancePurchaseCategorySchema,item_name:z.string(),quantity:z.union([z.number(),z.string()]),unit:maintenancePurchaseUnitSchema,amount:z.union([z.number(),z.string()]),vendor_name:z.string(),purchase_date:z.string(),notes:z.string().nullable(),payment_status:z.enum(["unpaid","reimbursed"]),reimbursement_note:z.string().nullable(),reimbursed_at:z.string().nullable(),receipt_original_name:z.string().nullable(),receipt_url:z.string().nullable(),attachments:z.array(maintenancePurchaseAttachmentSchema).max(MAX_MAINTENANCE_PURCHASE_PHOTOS).default([]),created_at:z.string(),updated_at:z.string()}).strict();
const maintenancePurchaseListSchema=z.object({maintenance_purchases:z.array(maintenancePurchaseRowSchema).max(500)}).strict();
const maintenancePurchaseMutationSchema=z.object({maintenance_purchase:maintenancePurchaseRowSchema}).strict();
const managedMaintenancePurchaseRowSchema=z.object({id:z.uuid(),branch_id:z.uuid().nullable(),branch_name:z.string(),maintenance_issue_id:z.uuid().nullable(),purchase_type:maintenancePurchaseTypeSchema,issue_title:z.string().nullable(),issue_category:maintenanceIssueCategorySchema.nullable(),issue_status:maintenanceIssueStatusSchema.nullable(),purchase_scope:maintenancePurchaseScopeSchema,destination:z.string().nullable(),category:maintenancePurchaseCategorySchema,maintenance_user_id:z.uuid(),maintenance_user_name:z.string().nullable(),item_name:z.string(),quantity:z.union([z.number(),z.string()]),unit:maintenancePurchaseUnitSchema,amount:z.union([z.number(),z.string()]),vendor_name:z.string(),purchase_date:z.string(),notes:z.string().nullable(),payment_status:z.enum(["unpaid","reimbursed"]),reimbursement_note:z.string().nullable(),reimbursed_at:z.string().nullable(),receipt_original_name:z.string().nullable(),receipt_url:z.string().nullable(),attachments:z.array(maintenancePurchaseAttachmentSchema).max(MAX_MAINTENANCE_PURCHASE_PHOTOS).default([]),created_at:z.string(),updated_at:z.string()}).strict();
const managedMaintenancePurchaseListSchema=z.object({maintenance_purchases:z.array(managedMaintenancePurchaseRowSchema).max(1000)}).strict();
const maintenancePurchaseHistoryListSchema=z.object({maintenance_purchases:z.array(managedMaintenancePurchaseRowSchema.omit({maintenance_user_id:true})).max(1000)}).strict();
const maintenancePurchaseBodySchema=z.object({purchase_type:maintenancePurchaseTypeSchema.optional(),purchase_scope:maintenancePurchaseScopeSchema.optional(),branch_id:z.uuid().nullable().optional(),destination:optionalStaffTextSchema(120),category:maintenancePurchaseCategorySchema,item_name:normalizedNameSchema,quantity:z.union([z.number(),z.string()]).transform(Number).pipe(z.number().positive()),unit:maintenancePurchaseUnitSchema,amount:z.union([z.number(),z.string()]).transform(Number).pipe(z.number().nonnegative()),vendor_name:optionalStaffTextSchema(120),purchase_date:dateOnlySchema,notes:optionalStaffTextSchema(2000)}).strict();
const maintenancePurchaseBranchListSchema=z.object({branches:z.array(z.object({id:z.uuid(),name:z.string(),name_ar:z.string().nullable()}).strict()).max(500)}).strict();
const maintenancePurchaseAttachmentUploadSchema=z.object({original_name:z.string().max(180).optional().nullable(),mime_type:maintenancePurchaseReceiptMime,content_base64:z.string().min(1)}).strict();
const maintenancePurchaseUploadEnvelopeSchema=z.object({purchase:maintenancePurchaseBodySchema,attachments:z.array(maintenancePurchaseAttachmentUploadSchema).max(MAX_MAINTENANCE_PURCHASE_PHOTOS).default([])}).strict();
const maintenancePurchasePaymentBodySchema=z.object({reimbursement_note:optionalStaffTextSchema(500)}).strict();
const dailyAuditItemApiSchema=z.object({item_id:z.string().min(1).max(80),answer:z.enum(["not_checked","compliant","non_compliant"]),remark:z.string().max(4000)}).strict();
const dailyAuditBodySchema=z.object({business_date:dateOnlySchema,expected_revision:z.number().int().nonnegative().default(0),items:z.array(dailyAuditItemApiSchema).max(13)}).strict();
const dailyAuditResponseSchema=z.object({submission_id:z.uuid().nullable().optional(),branch_id:z.uuid(),business_date:dateOnlySchema,state:z.enum(["empty","draft","submitted"]).nullable(),revision:z.number().int().nonnegative().default(0),auditor_display_name:z.string().nullable().optional(),auditor_kind:z.enum(["manual_access_user","organization_manager_pin"]).nullable().optional(),submitted_at:z.string().nullable().optional(),updated_at:z.string().nullable().optional(),items:z.array(z.object({item_id:z.string(),item_number:z.number().int().optional(),answer:z.enum(["not_checked","compliant","non_compliant"]),remark:z.string()}).strict()).length(13)}).strict();
const emptyQuerySchema = z.object({}).strict();
const internalAdminOperationalTeamNameSchema = z.string().max(80).transform((value) => value.trim().replace(/\s+/gu, " ")).pipe(z.string().min(1).max(80));
const createInternalAdminBranchTeamStaffBodySchema = z.object({
  display_name: normalizedNameSchema,
  company_name: companyNameSchema,
  staff_code: staffCodeSchema,
  country_code: countryCodeSchema,
  primary_role: operationalRoleSchema,
  secondary_role: operationalRoleSchema.optional(),
}).strict().superRefine((value, context) => {
  if (value.secondary_role === value.primary_role) {
    context.addIssue({ code: "custom", path: ["secondary_role"], message: "Roles must be unique." });
  }
});
const createInternalAdminBranchTeamBodySchema = z.object({
  team_name: internalAdminOperationalTeamNameSchema.optional(),
  company_name: companyNameSchema,
  branch_id: z.uuid(),
  supervisor_user_id: z.uuid().optional(),
  primary_supervisor_user_id: z.uuid().optional(),
  backup_supervisor_user_id: z.uuid().nullable().optional(),
  initial_staff: z.array(createInternalAdminBranchTeamStaffBodySchema).max(50).optional(),
}).strict().superRefine((value, context) => {
  const primarySupervisorUserId = value.primary_supervisor_user_id ?? value.supervisor_user_id;
  if (!primarySupervisorUserId) {
    context.addIssue({ code: "custom", path: ["primary_supervisor_user_id"], message: "Choose a primary supervisor." });
  }
  if (value.backup_supervisor_user_id && value.backup_supervisor_user_id === primarySupervisorUserId) {
    context.addIssue({ code: "custom", path: ["backup_supervisor_user_id"], message: "Choose a different backup supervisor." });
  }
});
const managedBranchTimezoneSchema = z.enum(["Asia/Riyadh", "UTC"]);
const createBranchBodySchema = z.object({
  name: normalizedNameSchema,
  name_ar: optionalStaffTextSchema(120),
  code: branchCodeSchema,
  city: branchCitySchema,
  area: optionalDisplayNameSchema,
  address: optionalStaffTextSchema(240),
  timezone: managedBranchTimezoneSchema.default("Asia/Riyadh"),
  active: z.boolean().default(true),
}).strict();
const updateBranchBodySchema = z.object({
  name: normalizedNameSchema,
  name_ar: optionalStaffTextSchema(120),
  code: branchCodeSchema,
  city: branchCitySchema,
  area: optionalDisplayNameSchema,
  address: optionalStaffTextSchema(240),
  timezone: managedBranchTimezoneSchema,
}).strict();
const createOrganizationBodySchema = z.object({
  name: normalizedNameSchema,
  name_ar: optionalStaffTextSchema(120),
}).strict();
const updateOrganizationBodySchema = createOrganizationBodySchema;
const internalAdminLifecycleBodySchema = z.object({}).strict();
const operationalStaffListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).max(1000000).default(1),
  page_size: z.coerce.number().int().min(1).max(50).default(20),
  search: z.string().trim().max(120).optional(),
  branch_id: z.uuid().optional(),
  supervisor_user_id: z.uuid().optional(),
  operational_role: operationalRoleSchema.optional(),
  employment_status: z.enum(["active", "inactive"]).optional(),
  date: dateOnlySchema.optional(),
}).strict();
const managedEmployeeTeamQuerySchema=z.object({branch_id:z.uuid().optional(),month:z.string().regex(/^\d{4}-(?:0[1-9]|1[0-2])$/)}).strict();
const managedAnnualEvaluationQuerySchema=z.object({evaluation_year:z.coerce.number().int().min(2000).max(2200),branch_id:z.uuid().optional(),subject_type:annualEvaluationSubjectTypeSchema.optional(),subject_id:z.uuid().optional(),state:z.enum(["draft","submitted"]).optional()}).strict().refine(value=>(value.subject_type===undefined)===(value.subject_id===undefined));
const managedAnnualEvaluationDraftSchema=z.object({branch_id:z.uuid(),evaluation_year:z.number().int().min(2000).max(2200),subject_type:annualEvaluationSubjectTypeSchema,subject_id:z.uuid(),expected_revision:z.number().int().nonnegative(),scores:z.array(annualEvaluationScoreSchema).max(20)}).strict();
const managedAnnualEvaluationSubmitSchema=z.object({expected_revision:z.number().int().nonnegative()}).strict();
const managedPurchaseLogQuerySchema=z.object({branch_id:z.uuid().optional(),category:z.enum(["stationery","kitchen","equipment","food_item"]).optional(),payment_status:z.enum(["unpaid","reimbursed"]).optional(),date_from:dateOnlySchema.optional(),date_to:dateOnlySchema.optional()}).strict().refine((value)=>!value.date_from||!value.date_to||value.date_from<=value.date_to);
const managedSupplierReceivingQuerySchema=z.object({branch_id:z.uuid().optional(),category:supplierReceivingCategorySchema.optional(),supplier_id:z.uuid().optional(),date_from:dateOnlySchema.optional(),date_to:dateOnlySchema.optional()}).strict().refine((value)=>!value.date_from||!value.date_to||value.date_from<=value.date_to);
const managedMaintenanceIssueQuerySchema=z.object({branch_id:z.uuid().optional(),status:maintenanceIssueStatusSchema.optional(),priority:maintenanceIssuePrioritySchema.optional(),category:maintenanceIssueCategorySchema.optional(),date_from:dateOnlySchema.optional(),date_to:dateOnlySchema.optional()}).strict().refine((value)=>!value.date_from||!value.date_to||value.date_from<=value.date_to);
const managedMaintenancePurchaseQuerySchema=z.object({branch_id:z.uuid().optional(),issue_status:maintenanceIssueStatusSchema.optional(),payment_status:z.enum(["unpaid","reimbursed"]).optional(),vendor:z.string().trim().min(1).max(120).optional(),date_from:dateOnlySchema.optional(),date_to:dateOnlySchema.optional(),purchase_type:maintenancePurchaseTypeSchema.optional()}).strict().refine((value)=>!value.date_from||!value.date_to||value.date_from<=value.date_to);
const pinBodySchema = z.object({
  pin: z.string().regex(/^[0-9]{6}$/),
  pin_confirmation: z.string().regex(/^[0-9]{6}$/),
}).strict().refine((value) => value.pin === value.pin_confirmation);
const pinVerifySchema = z.object({
  branch_id: z.uuid(),
  pin: z.string().regex(/^[0-9]{4,8}$/),
}).strict();
const dailyAuditAccessCreateBodySchema = z.object({
  display_name: normalizedNameSchema,
  pin: z.string().regex(/^[0-9]{4,8}$/),
  pin_confirmation: z.string().regex(/^[0-9]{4,8}$/),
}).strict().refine((value) => value.pin === value.pin_confirmation);
const maintenanceAccessCreateBodySchema = z.object({
  display_name: normalizedNameSchema,
  pin: z.string().regex(/^[0-9]{4,8}$/),
  pin_confirmation: z.string().regex(/^[0-9]{4,8}$/),
}).strict().refine((value) => value.pin === value.pin_confirmation);
const maintenanceAccessVerifyBodySchema = z.object({
  organization: z.string().max(120).transform((value) => value.trim().replace(/\s+/gu, " ")).pipe(z.string().min(1).max(120)),
  display_name: normalizedNameSchema,
  pin: z.string().regex(/^[0-9]{4,8}$/),
}).strict();
const trainingOrganizationSlugSchema = z.string()
  .max(120)
  .transform((value) => value.trim().toLowerCase())
  .pipe(z.string().min(1).max(120).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/));
const trainingPinSchema = z.string().regex(/^[0-9]{4,12}$/);
const trainingBranchAccessUpdateBodySchema = z.object({
  enabled: z.boolean(),
  pin: trainingPinSchema.optional(),
}).strict();
const trainingBranchAccessVerifyBodySchema = z.object({
  branch_id: z.uuid(),
  pin: trainingPinSchema,
}).strict();
const trainingBranchAccessLegacyVerifyBodySchema = trainingBranchAccessVerifyBodySchema.extend({
  organization_slug: trainingOrganizationSlugSchema,
}).strict();
const trainingEmployeeCodeSchema = z.string()
  .max(80)
  .transform((value) => value.trim())
  .pipe(z.string().min(1).max(80));
const trainingEmployeeSelectBodySchema = z.object({
  employee_code: trainingEmployeeCodeSchema,
}).strict();
const DAILY_AUDIT_COOKIE_PATH = "/api/daily-audit";
const MAINTENANCE_ACCESS_COOKIE_PATH = "/maintenance";
const TRAINING_ACCESS_COOKIE_PATH = "/";
const LEGACY_TRAINING_ACCESS_COOKIE_PATH = "/training";
export function serializeDailyAuditGrantCookie(
  value: string,
  nodeEnv: BackendConfig["nodeEnv"],
  maxAge: number,
) {
  return `audit_access=${value}; Max-Age=${maxAge}; Path=${DAILY_AUDIT_COOKIE_PATH}; HttpOnly; SameSite=Strict${nodeEnv === "production" ? "; Secure" : ""}`;
}
export function serializeMaintenanceAccessCookie(
  value: string,
  nodeEnv: BackendConfig["nodeEnv"],
  maxAge: number,
) {
  return `maintenance_access=${value}; Max-Age=${maxAge}; Path=${MAINTENANCE_ACCESS_COOKIE_PATH}; HttpOnly; SameSite=Strict${nodeEnv === "production" ? "; Secure" : ""}`;
}
function serializeTrainingAccessCookieForPath(
  value: string,
  nodeEnv: BackendConfig["nodeEnv"],
  maxAge: number,
  path: string,
) {
  return `training_access=${value}; Max-Age=${maxAge}; Path=${path}; HttpOnly; SameSite=Strict${nodeEnv === "production" ? "; Secure" : ""}`;
}
export function serializeTrainingAccessCookie(
  value: string,
  nodeEnv: BackendConfig["nodeEnv"],
  maxAge: number,
) {
  return serializeTrainingAccessCookieForPath(value, nodeEnv, maxAge, TRAINING_ACCESS_COOKIE_PATH);
}
function serializeTrainingAccessCookieHeaders(
  value: string,
  nodeEnv: BackendConfig["nodeEnv"],
  maxAge: number,
) {
  return [
    serializeTrainingAccessCookie(value, nodeEnv, maxAge),
    serializeTrainingAccessCookieForPath("", nodeEnv, 0, LEGACY_TRAINING_ACCESS_COOKIE_PATH),
  ];
}
function setTrainingAccessCookie(response: Response, value: string, nodeEnv: BackendConfig["nodeEnv"], maxAge: number) {
  response.setHeader("Set-Cookie", serializeTrainingAccessCookieHeaders(value, nodeEnv, maxAge));
}
function readCookie(header: string | undefined, name: string) {
  if (!header) return null;
  for (const part of header.split(";")) {
    const [rawKey, ...rawValue] = part.trim().split("=");
    if (rawKey === name) return rawValue.join("=") || "";
  }
  return null;
}
const userListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).max(1000000).default(1),
  page_size: z.coerce.number().int().min(1).max(50).default(20),
  search: z.string().trim().max(120).optional(),
  role: z.enum(["staff", "branch_manager"]).optional(),
  branch_id: z.uuid().optional(),
  lifecycle: z.enum(["active", "password_change_required", "disabled"]).optional(),
}).strict();
const passwordChangeBodySchema = z
  .object({
    current_password: z.string().min(1).max(128),
    new_password: z.string().min(6).max(128),
  })
  .strict()
  .refine((value) => value.current_password !== value.new_password);
const supervisorTeamAssignmentBodySchema = z.object({
  operational_team_id: z.uuid(),
  assignment_role: z.enum(["primary", "backup"]),
}).strict();
function rejectDuplicateSupervisorTeamAssignments(
  value: { supervisor_team_assignments: Array<{ operational_team_id: string }> },
  context: z.RefinementCtx,
) {
  const ids = value.supervisor_team_assignments.map((assignment) => assignment.operational_team_id);
  if (new Set(ids).size !== ids.length) {
    context.addIssue({
      code: "custom",
      path: ["supervisor_team_assignments"],
      message: "Duplicate operational team assignments are not allowed.",
    });
  }
}
function rejectDuplicateBranchIds(value: { branch_ids: string[] }, context: z.RefinementCtx) {
  if (new Set(value.branch_ids).size !== value.branch_ids.length) {
    context.addIssue({
      code: "custom",
      path: ["branch_ids"],
      message: "Duplicate branch IDs are not allowed.",
    });
  }
}
const baseProvisioningFields = {
  full_name: z
    .string()
    .max(120)
    .transform((value) => value.trim().replace(/\s+/g, " "))
    .pipe(z.string().min(1).max(120)),
  full_name_ar: optionalDisplayNameSchema,
  email: z
    .string()
    .trim()
    .toLowerCase()
    .max(254)
    .pipe(z.email()),
  temporary_password: z.string().min(6).max(128),
  branch_ids: z.array(z.uuid()).min(1).max(50),
} as const;
const baseProvisioningBodySchema = z.object(baseProvisioningFields).strict().superRefine(rejectDuplicateBranchIds);
const provisioningBodySchema = z.object({
  ...baseProvisioningFields,
  person_code: optionalStaffTextSchema(80),
  phone_number: optionalStaffTextSchema(40),
  country_code: countryCodeSchema,
  iqama_number: optionalStaffTextSchema(80),
  iqama_expiry_date: optionalDateOnlySchema,
  supervisor_team_assignments: z.array(supervisorTeamAssignmentBodySchema).max(50).default([]),
}).strict().superRefine((value, context) => {
  rejectDuplicateBranchIds(value, context);
  rejectDuplicateSupervisorTeamAssignments(value, context);
});
const supervisorProfileBodySchema = z.object({
  full_name: normalizedNameSchema,
  full_name_ar: optionalDisplayNameSchema,
  person_code: optionalStaffTextSchema(80),
  phone_number: optionalStaffTextSchema(40),
  country_code: countryCodeSchema,
  iqama_number: optionalStaffTextSchema(80),
  iqama_expiry_date: optionalDateOnlySchema,
}).strict();
const maintenanceUserBodySchema = z
  .object({
    full_name: normalizedNameSchema,
    full_name_ar: optionalDisplayNameSchema,
    email: z
      .string()
      .trim()
      .toLowerCase()
      .max(254)
      .pipe(z.email()),
    temporary_password: z.string().min(6).max(128),
  })
  .strict();
const trainingAccountBodySchema = z.object({
  account_name: normalizedNameSchema,
  email: z.string().trim().toLowerCase().max(254).pipe(z.email()),
  temporary_password: z.string().min(6).max(128),
  branch_ids: z.array(z.uuid()).min(1).max(50),
  active: z.boolean().default(true),
}).strict().superRefine(rejectDuplicateBranchIds);
const trainingAccountUpdateBodySchema = z.object({
  account_name: normalizedNameSchema,
  branch_ids: z.array(z.uuid()).min(1).max(50),
  active: z.boolean(),
}).strict().superRefine(rejectDuplicateBranchIds);
const trainingAccountPasswordResetBodySchema = z.object({
  temporary_password: z.string().min(6).max(128),
}).strict();
const organizationManagerBodySchema = maintenanceUserBodySchema.extend({
  full_name_ar: optionalDisplayNameSchema,
}).strict();
const existingUserGrantBodySchema = z.object({
  email: z.string().trim().toLowerCase().max(254).pipe(z.email()),
}).strict();
const existingSupervisorGrantBodySchema = existingUserGrantBodySchema.extend({
  branch_ids: z.array(z.uuid()).min(1).max(50),
  supervisor_team_assignments: z.array(supervisorTeamAssignmentBodySchema).max(50).default([]),
}).strict().superRefine((value, context) => {
  if (new Set(value.branch_ids).size !== value.branch_ids.length) {
    context.addIssue({
      code: "custom",
      path: ["branch_ids"],
      message: "Duplicate branch IDs are not allowed.",
    });
  }
  rejectDuplicateSupervisorTeamAssignments(value, context);
});
const reactivateAccessBodySchema = z.object({ active: z.literal(true) }).strict();

const checklistTypeSchema=z.enum(["kitchen_opening","foh_opening","staff_hygiene"]);
const supervisorChecklistTypeSchema=z.enum(["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage","sales_tracking","daily_audit","purchase_log","supplier_receiving","financial_closing"]);
const managementIssueChecklistTypeSchema=z.enum(["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage","sales_tracking"]);
const managementReportChecklistTypeSchema=z.enum(["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage","sales_tracking","daily_audit","financial_closing"]);
const openingTypeSchema=z.enum(["kitchen_opening","foh_opening"]);
const openingAnswerSchema=z.object({item_id:z.string().min(1).max(80),answer:z.enum(["not_checked","completed","issue_found"]),remark:z.string().max(2000),evidence_id:z.uuid().nullable()}).strict().superRefine((value,context)=>{
  if(value.answer==="issue_found"&&(!value.evidence_id||!value.remark.trim()))context.addIssue({code:"custom",message:"Issue evidence is required."});
  if(value.answer!=="issue_found"&&value.evidence_id)context.addIssue({code:"custom",message:"Evidence is not allowed."});
});
const openingBodySchema=z.object({checklist_type:openingTypeSchema,expected_revision:z.number().int().nonnegative().default(0),answers:z.array(openingAnswerSchema).min(1).max(18)}).strict();
const hygieneRowSchema=z.object({staff_id:z.uuid(),uniform:z.enum(["pass","issue"]),fingernails:z.enum(["pass","issue"]),hair:z.enum(["pass","issue"]),facial_hair:z.enum(["pass","issue"]),remark:z.string().max(2000)}).strict();
const hygieneBodySchema=z.object({checklist_type:z.literal("staff_hygiene"),operational_team_id:z.uuid(),staff:z.array(hygieneRowSchema).max(500)}).strict();
const hygieneDraftRowSchema=hygieneRowSchema.extend({uniform:z.enum(["pending","pass","issue"]),fingernails:z.enum(["pending","pass","issue"]),hair:z.enum(["pending","pass","issue"]),facial_hair:z.enum(["pending","pass","issue"])}).strict();
const hygieneDraftBodySchema=z.object({checklist_type:z.literal("staff_hygiene"),operational_team_id:z.uuid(),expected_revision:z.number().int().nonnegative(),staff:z.array(hygieneDraftRowSchema).max(500)}).strict();
const oilStatusInputSchema=z.enum(["pending","new_oil","filtered_oil","new-oil","filtered-oil"]).transform(value=>value.replace(/-/g,"_") as "pending"|"new_oil"|"filtered_oil");
const oilCheckInputSchema=z.enum(["pending","pass","fail"]);
const oilNumberInputSchema=z.union([z.number(),z.string().trim().max(40),z.null()]).optional();
const oilTextInputSchema=z.string().max(2000).optional().nullable().transform(value=>value??"");
const oilRowInputSchema=z.object({
  id:z.string().min(1).max(80).optional(),
  fryerId:z.string().min(1).max(80).optional(),
  fryer_id:z.string().min(1).max(80).optional(),
  label:z.string().min(1).max(120).optional(),
  fryerLabelSnapshot:z.string().min(1).max(120).optional(),
  fryer_label_snapshot:z.string().min(1).max(120).optional(),
  shortLabel:z.string().min(1).max(40).optional(),
  fryerShortLabelSnapshot:z.string().min(1).max(40).optional(),
  fryer_short_label_snapshot:z.string().min(1).max(40).optional(),
  inUseToday:z.boolean().optional(),
  in_use_today:z.boolean().optional(),
  oilStatus:oilStatusInputSchema.optional(),
  oil_status:oilStatusInputSchema.optional(),
  openingTemperatureC:oilNumberInputSchema,
  opening_temperature_c:oilNumberInputSchema,
  temperature:oilNumberInputSchema,
  openingStatus:oilCheckInputSchema.optional(),
  opening_status:oilCheckInputSchema.optional(),
  openingNote:oilTextInputSchema,
  opening_note:oilTextInputSchema,
  closingTpmPercent:oilNumberInputSchema,
  closing_tpm_percent:oilNumberInputSchema,
  closingTpm:oilNumberInputSchema,
  closingNote:oilTextInputSchema,
  closing_note:oilTextInputSchema,
}).strict().transform((value,context)=>{
  const fryerId=value.fryer_id??value.fryerId??value.id;
  const label=value.fryer_label_snapshot??value.fryerLabelSnapshot??value.label;
  const shortLabel=value.fryer_short_label_snapshot??value.fryerShortLabelSnapshot??value.shortLabel;
  if(!fryerId)context.addIssue({code:"custom",path:["fryerId"],message:"Fryer ID is required."});
  if(!label)context.addIssue({code:"custom",path:["label"],message:"Fryer label is required."});
  if(!shortLabel)context.addIssue({code:"custom",path:["shortLabel"],message:"Fryer short label is required."});
  return {
    fryer_id:fryerId??"",
    fryer_label_snapshot:label??"",
    fryer_short_label_snapshot:shortLabel??"",
    in_use_today:value.in_use_today??value.inUseToday??false,
    oil_status:value.oil_status??value.oilStatus??"pending",
    opening_temperature_c:value.opening_temperature_c??value.openingTemperatureC??value.temperature??null,
    opening_status:value.opening_status??value.openingStatus??"pending",
    opening_note:value.opening_note??value.openingNote??"",
    closing_tpm_percent:value.closing_tpm_percent??value.closingTpmPercent??value.closingTpm??null,
    closing_note:value.closing_note??value.closingNote??"",
  };
});
const oilTrackingBodySchema=z.object({expected_revision:z.number().int().nonnegative().default(0),rows:z.array(oilRowInputSchema).max(50)}).strict();
const coldSlotSchema=z.enum(["12","20","02","12:00","20:00","02:00"]).transform(value=>value.includes(":")?value:`${value}:00` as "12:00"|"20:00"|"02:00");
const coldPersistedSlotSchema=z.enum(["12:00","20:00","02:00","3:00","8:00"]);
const coldNumberInputSchema=z.union([z.number(),z.string().trim().max(40),z.null()]).optional();
const coldTextInputSchema=z.string().max(2000).optional().nullable().transform(value=>value??"");
const coldEquipmentInputSchema=z.object({
  id:z.string().min(1).max(80).optional(),
  equipmentId:z.string().min(1).max(80).optional(),
  equipment_id:z.string().min(1).max(80).optional(),
  equipmentCode:z.union([coldStorageEquipmentCodeSchema,z.null()]).optional(),
  equipment_code:z.union([coldStorageEquipmentCodeSchema,z.null()]).optional(),
  name:z.string().min(1).max(120).optional(),
  equipmentName:z.string().min(1).max(120).optional(),
  equipment_name:z.string().min(1).max(120).optional(),
  type:z.enum(["refrigerator","freezer"]).optional(),
  equipmentType:z.enum(["refrigerator","freezer"]).optional(),
  equipment_type:z.enum(["refrigerator","freezer"]).optional(),
  active:z.boolean().optional(),
}).strict().transform((value,context)=>{
  const equipmentId=value.equipment_id??value.equipmentId??value.id;
  const equipmentCode=value.equipment_code??value.equipmentCode??null;
  const equipmentName=value.equipment_name??value.equipmentName??value.name;
  const equipmentType=value.equipment_type??value.equipmentType??value.type;
  if(!equipmentId)context.addIssue({code:"custom",path:["equipmentId"],message:"Equipment ID is required."});
  if(!equipmentName)context.addIssue({code:"custom",path:["equipmentName"],message:"Equipment name is required."});
  if(!equipmentType)context.addIssue({code:"custom",path:["equipmentType"],message:"Equipment type is required."});
  return {equipment_id:equipmentId??"",equipment_code:equipmentCode,equipment_name:equipmentName??"",equipment_type:equipmentType??"refrigerator",active:value.active??true};
});
const coldReadingInputSchema=z.object({
  equipmentId:z.string().min(1).max(80).optional(),
  equipment_id:z.string().min(1).max(80).optional(),
  slot:coldSlotSchema.optional(),
  temperatureC:coldNumberInputSchema,
  temperature_c:coldNumberInputSchema,
  status:z.enum(["pending","pass","fail"]).optional(),
  correctiveAction:coldTextInputSchema,
  corrective_action:coldTextInputSchema,
}).strict().transform((value,context)=>{
  const equipmentId=value.equipment_id??value.equipmentId;
  if(!equipmentId)context.addIssue({code:"custom",path:["equipmentId"],message:"Equipment ID is required."});
  if(!value.slot)context.addIssue({code:"custom",path:["slot"],message:"Slot is required."});
  return {
    equipment_id:equipmentId??"",
    slot:value.slot??"12:00",
    temperature_c:value.temperature_c??value.temperatureC??null,
    status:value.status??"pending",
    corrective_action:value.corrective_action??value.correctiveAction??"",
  };
});
const coldStorageBodySchema=z.object({expected_revision:z.number().int().nonnegative().default(0),equipment:z.array(coldEquipmentInputSchema).max(100),readings:z.array(coldReadingInputSchema).max(300)}).strict();
const financialClosingItemKeySchema=z.enum(["sales_closing","collections","exceptions","purchases","transfers","production","waste","petty_cash","pending_documents","exception_escalation"]);
const financialClosingStatusSchema=z.enum(["completed","not_completed","not_applicable"]);
const financialClosingItemInputSchema=z.object({
  item_key:financialClosingItemKeySchema,
  status:financialClosingStatusSchema.nullable().optional(),
  reason:z.string().max(2000).optional().nullable().transform(value=>value??""),
  follow_up:z.string().max(2000).optional().nullable().transform(value=>value??""),
}).strict();
const financialClosingBodySchema=z.object({expected_revision:z.number().int().nonnegative().default(0),items:z.array(financialClosingItemInputSchema).max(10)}).strict();
const coldStorageEquipmentMasterTypeSchema=z.enum(["refrigerator","freezer"]);
const coldStorageEquipmentMasterBodySchema=z.object({
  equipment_code:coldStorageEquipmentCodeSchema,
  name:normalizedNameSchema,
  equipment_type:coldStorageEquipmentMasterTypeSchema,
}).strict();
const coldStorageEquipmentMasterUpdateBodySchema=z.object({equipment_code:coldStorageEquipmentCodeSchema,name:normalizedNameSchema,equipment_type:coldStorageEquipmentMasterTypeSchema}).strict();
const coldStorageEquipmentMasterSchema=z.object({
  id:z.uuid(),
  branch_id:z.uuid(),
  equipment_code:z.string().min(1).max(24).nullable(),
  name:z.string().min(1).max(120),
  equipment_type:coldStorageEquipmentMasterTypeSchema,
  active:z.boolean(),
  updated_at:z.string(),
}).strict();
const coldStorageEquipmentMasterListSchema=z.object({
  equipment:z.array(coldStorageEquipmentMasterSchema).max(100),
}).strict();
const coldStorageEquipmentMasterMutationSchema=z.object({
  equipment:coldStorageEquipmentMasterSchema,
}).strict();
const salesTrackingDecimalInputSchema=z.union([
  z.number().finite().nonnegative(),
  z.string().trim().max(40).regex(/^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/),
]).transform(value=>typeof value==="number"?String(value):value);
const salesTrackingTextSchema=z.string().max(2000).optional().nullable().transform(value=>value??"");
const salesTrackingSalesRowInputSchema=z.object({
  entry_date:dateOnlySchema,
  actual_cash:salesTrackingDecimalInputSchema,
  actual_credit:salesTrackingDecimalInputSchema,
  pos_cash:salesTrackingDecimalInputSchema,
  pos_credit:salesTrackingDecimalInputSchema,
  online_delivery:salesTrackingDecimalInputSchema,
  online_amounts:z.array(z.object({
    provider_id:z.uuid(),
    amount:salesTrackingDecimalInputSchema,
  }).strict()).max(200).optional().default([]),
  remarks:salesTrackingTextSchema,
}).strict().superRefine((value,context)=>{
  const providerIds=value.online_amounts.map((amount)=>amount.provider_id);
  if(new Set(providerIds).size!==providerIds.length)context.addIssue({code:"custom",path:["online_amounts"],message:"Duplicate provider IDs are not allowed."});
}).transform((value)=>value.online_amounts.length?{
  ...value,
  online_delivery:String(Math.round(value.online_amounts.reduce((total,amount)=>total+Number(amount.amount),0)*100)/100),
}:value);
const salesTrackingDenominationsSchema=z.object({
  "1":z.number().int().nonnegative(),
  "2":z.number().int().nonnegative(),
  "5":z.number().int().nonnegative(),
  "10":z.number().int().nonnegative(),
  "20":z.number().int().nonnegative(),
  "50":z.number().int().nonnegative(),
  "100":z.number().int().nonnegative(),
  "200":z.number().int().nonnegative(),
  "500":z.number().int().nonnegative(),
}).strict();
const salesTrackingCashRowInputSchema=z.object({
  entry_date:dateOnlySchema,
  denominations:salesTrackingDenominationsSchema,
  remaining_cash:salesTrackingDecimalInputSchema,
  remarks:salesTrackingTextSchema,
}).strict();
const salesTrackingPeriodSchema=z.enum(["middle_shift","closing_shift"]);
const salesTrackingTotalsSchema=z.object({actual_cash:z.union([z.number(),z.string()]),actual_credit:z.union([z.number(),z.string()]),pos_cash:z.union([z.number(),z.string()]),pos_credit:z.union([z.number(),z.string()]),online_delivery:z.union([z.number(),z.string()]),actual_total:z.union([z.number(),z.string()]),pos_total:z.union([z.number(),z.string()]),variance:z.union([z.number(),z.string()]),cash_total:z.union([z.number(),z.string()]),remaining_cash:z.union([z.number(),z.string()])}).strict();
const salesTrackingBodySchema=z.object({
  expected_revision:z.number().int().nonnegative().default(0),
  entry_period:salesTrackingPeriodSchema,
  sales_rows:z.array(salesTrackingSalesRowInputSchema).length(1),
  cash_rows:z.array(salesTrackingCashRowInputSchema).length(1),
}).strict();
const salesTrackingSubmitBodySchema=z.object({expected_revision:z.number().int().nonnegative()}).strict();
const salesTrackingOnlineProviderBodySchema=z.object({name:normalizedNameSchema}).strict();
const salesTrackingOnlineProviderSchema=z.object({
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
const salesTrackingOnlineProviderListSchema=z.object({
  providers:z.array(salesTrackingOnlineProviderSchema).max(200),
}).strict();
const salesTrackingOnlineProviderMutationSchema=z.object({
  provider:salesTrackingOnlineProviderSchema,
}).strict();
const salesTrackingOnlineAmountSchema=z.object({id:z.uuid().optional(),provider_id:z.uuid(),provider_name:z.string(),amount:z.union([z.number(),z.string()])}).strict();
const inventoryDecimalInputSchema=z.union([
  z.number().finite().nonnegative(),
  z.string().trim().max(40).regex(/^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/),
]).transform(value=>typeof value==="number"?String(value):value);
const inventoryBeefRowInputSchema=z.object({
  production_date:dateOnlySchema,
  russian_kg:inventoryDecimalInputSchema,
  australian_kg:inventoryDecimalInputSchema,
  fat_kg:inventoryDecimalInputSchema,
  ready_patty:inventoryDecimalInputSchema,
  hunch_sauce_kg:inventoryDecimalInputSchema,
  wastage_grams:inventoryDecimalInputSchema,
}).strict();
const inventoryUsageValueSchema=z.record(z.string().regex(/^(?:[1-9]|[12][0-9]|3[01])$/),inventoryDecimalInputSchema);
const inventoryItemUsageInputSchema=z.object({
  usage_month:dateOnlySchema.refine(value=>value.endsWith("-01"),"Month must be first day of the month."),
  items:z.array(z.object({
    item_id:z.uuid().optional(),
    group_name:z.string().trim().max(120).optional().nullable().transform(value=>value?.trim()||"Liwa"),
    item_name:z.string().trim().min(1).max(160),
    usage:inventoryUsageValueSchema,
  }).strict()).max(200),
}).strict().superRefine((value,context)=>{
  const days=gregorianMonthDayCount(value.usage_month);
  if(!days){context.addIssue({code:"custom",path:["usage_month"],message:"Invalid usage month."});return;}
  value.items.forEach((item,itemIndex)=>Object.keys(item.usage).forEach((day)=>{
    if(Number(day)>days)context.addIssue({code:"custom",path:["items",itemIndex,"usage",day],message:"Day is outside the selected Gregorian month."});
  }));
});
const inventoryItemsBodySchema=z.object({
  beef_rows:z.array(inventoryBeefRowInputSchema).max(62),
  item_usage:inventoryItemUsageInputSchema,
}).strict();
const inventoryItemsQuerySchema=z.object({
  inventory_month:dateOnlySchema.refine(value=>value.endsWith("-01"),"Month must be first day of the month.").optional(),
}).strict();
const idempotencySchema=z.uuid();
const uuidLikeSchema=z.string().regex(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/);
const pageQuerySchema=z.object({page:z.coerce.number().int().min(1).max(1000000).default(1),page_size:z.coerce.number().int().min(1).max(50).default(20),checklist_type:supervisorChecklistTypeSchema.optional()}).strict();
const managerReportQuerySchema=z.object({page:z.coerce.number().int().min(1).default(1),page_size:z.coerce.number().int().min(1).max(50).default(20),date_from:dateOnlySchema.optional(),date_to:dateOnlySchema.optional(),branch_id:z.uuid().optional(),supervisor_user_id:z.uuid().optional(),checklist_type:managementReportChecklistTypeSchema.optional(),status:z.enum(["compliant","issues_found","in_progress","not_checked"]).optional(),search:z.string().trim().max(120).optional()}).strict();
const managerSalesTrackingQuerySchema=z.object({date_from:dateOnlySchema.optional(),date_to:dateOnlySchema.optional(),branch_id:z.uuid().optional()}).strict();
const managerSalesTrackingMonthlyQuerySchema=z.object({month:monthOnlySchema,branch_id:z.uuid().optional()}).strict();
const managerInventoryMonthSchema=z.string().regex(/^\d{4}-(?:0[1-9]|1[0-2])$/).transform(value=>`${value}-01`);
const managerInventoryItemsQuerySchema=z.object({month:managerInventoryMonthSchema.optional(),branch_id:z.uuid().optional()}).strict();
const operationsSummaryQuerySchema=z.object({month:monthOnlySchema.optional(),branch_id:z.uuid().optional()}).strict();
const managerIssueQuerySchema=z.object({page:z.coerce.number().int().min(1).default(1),page_size:z.coerce.number().int().min(1).max(50).default(20),date_from:dateOnlySchema.optional(),date_to:dateOnlySchema.optional(),branch_id:z.uuid().optional(),supervisor_user_id:z.uuid().optional(),staff_id:z.uuid().optional(),checklist_type:managementIssueChecklistTypeSchema.optional(),status:z.literal("new").optional(),search:z.string().trim().max(120).optional()}).strict();
const phase4aEvidenceMetadataSchema=z.object({id:z.uuid(),status:z.enum(["pending","draft","finalized"]),mime_type:evidenceMimeSchema,byte_size:z.number().int().positive().max(MAX_EVIDENCE_BYTES),available:z.boolean()});
const phase4aAnswerSchema=z.object({item_id:z.string().max(120),item_text:z.string().optional(),answer:z.string().max(40),remark:z.string().max(2000),follow_up:z.string().max(2000).optional(),evidence:phase4aEvidenceMetadataSchema.nullable().optional()});
const phase4aStaffSnapshotSchema=z.object({staff_id:z.uuid(),display_name:z.string().max(120),operational_roles:z.array(z.string().max(40)).max(2),uniform:z.string().max(20),fingernails:z.string().max(20),hair:z.string().max(20),facial_hair:z.string().max(20),remark:z.string().max(2000)});
const phase4aCurrentSchema=z.object({state:z.enum(["none","draft","submitted"]),business_date:z.string(),checklist_type:checklistTypeSchema,id:z.uuid().nullable().optional(),created_at:z.string().nullable().optional(),updated_at:z.string().nullable().optional(),submitted_at:z.string().nullable().optional(),operational_team_id:z.uuid().optional(),team_name:z.string().optional(),can_write:z.boolean().optional(),revision:z.number().int().nonnegative().optional(),answers:z.array(phase4aAnswerSchema).max(50).optional(),staff:z.array(phase4aStaffSnapshotSchema).max(500).optional()});
const overviewCountsSchema=z.object({expected_checks:z.number().int().nonnegative(),answered_checks:z.number().int().nonnegative(),compliant_checks:z.number().int().nonnegative(),issue_checks:z.number().int().nonnegative(),pending_checks:z.number().int().nonnegative(),completion_percentage:z.number().int().min(0).max(100).nullable(),compliance_percentage:z.number().int().min(0).max(100).nullable()}).strict().superRefine((value,context)=>{if(value.answered_checks!==value.compliant_checks+value.issue_checks)context.addIssue({code:"custom",message:"Invalid answered count."});if(value.pending_checks!==value.expected_checks-value.answered_checks)context.addIssue({code:"custom",message:"Invalid pending count."});if(value.completion_percentage!==(value.expected_checks===0?null:Math.round(value.answered_checks*100/value.expected_checks)))context.addIssue({code:"custom",message:"Invalid completion percentage."});if(value.compliance_percentage!==(value.answered_checks===0?null:Math.round(value.compliant_checks*100/value.answered_checks)))context.addIssue({code:"custom",message:"Invalid compliance percentage."});});
const supervisorProductionOverviewChecklistTypeSchema=z.enum(["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage"]);
const phase4aOverviewSchema=z.object({business_date:dateOnlySchema,totals:overviewCountsSchema,checklists:z.array(overviewCountsSchema.extend({checklist_type:supervisorProductionOverviewChecklistTypeSchema,state:z.enum(["not_started","draft","submitted"])}).strict()).length(5)}).strict().superRefine((value,context)=>{const types=value.checklists.map(x=>x.checklist_type);if(new Set(types).size!==5||!["kitchen_opening","foh_opening","staff_hygiene","oil_tracking","cold_storage"].every(type=>types.includes(type as never)))context.addIssue({code:"custom",message:"Invalid checklist set."});for(const key of ["expected_checks","answered_checks","compliant_checks","issue_checks","pending_checks"] as const)if(value.totals[key]!==value.checklists.reduce((sum,row)=>sum+row[key],0))context.addIssue({code:"custom",message:`Invalid ${key} total.`});});
const phase4aMutationSchema=z.object({id:z.uuid(),business_date:z.string(),checklist_type:checklistTypeSchema,state:z.enum(["draft","submitted"]),created_at:z.string().optional(),updated_at:z.string().optional(),submitted_at:z.string().optional(),issue_count:z.number().int().nonnegative().optional(),revision:z.number().int().nonnegative().optional()});
const coldStorageMissedMetadataSchema={missed_check_count:z.number().int().nonnegative().optional(),missed_slots:z.array(coldPersistedSlotSchema).max(3).optional()};
const recordKindSchema=z.enum(["submission","derived_missing"]);
const phase4aListSchema=z.object({reports:z.array(z.object({id:z.uuid(),branch_id:z.uuid(),branch_name:z.string().optional(),branch_code:z.string().optional(),checklist_type:supervisorChecklistTypeSchema,business_date:z.string(),submitted_at:z.string().nullable(),submitted_by:z.string().nullable(),auditor_kind:z.enum(["manual_access_user","organization_manager_pin"]).nullable().optional(),completion:z.number().optional(),issue_count:z.number().int().nonnegative(),status:z.string(),record_kind:recordKindSchema.optional(),source_submission_id:z.uuid().nullable().optional(),submitted_slots:z.array(coldPersistedSlotSchema).max(3).optional(),...coldStorageMissedMetadataSchema})).max(50),page:z.number().int().positive(),page_size:z.number().int().positive().max(50),total:z.number().int().nonnegative()});
const oilReportRowSchema=z.object({fryer_id:z.string(),fryer_label:z.string(),fryer_short_label:z.string(),in_use_today:z.boolean(),oil_status:z.enum(["pending","new_oil","filtered_oil"]),opening_temperature_c:z.union([z.number(),z.string()]).nullable().optional(),opening_status:z.enum(["pending","pass","fail"]),opening_note:z.string(),closing_tpm_percent:z.union([z.number(),z.string()]).nullable().optional(),closing_note:z.string(),tpm_classification:z.enum(["good","nearing_end","filtering_required","change_discard"]).nullable().optional()}).strict();
const oilReportIssueSchema=z.object({id:z.uuid(),section:z.enum(["opening","closing"]),fryer_id:z.string(),fryer_label:z.string(),title:z.string(),remark:z.string(),tpm_status:z.enum(["good","nearing_end","filtering_required","change_discard"]).nullable().optional()}).strict();
const coldStorageReportRowSchema=z.object({equipment_id:z.string(),equipment_code:z.string().min(1).max(24).nullable().optional(),equipment_name:z.string(),equipment_type:z.enum(["refrigerator","freezer"]),active:z.boolean(),slot:coldPersistedSlotSchema,temperature_c:z.union([z.number(),z.string()]).nullable().optional(),status:z.enum(["pending","pass","fail"]),corrective_action:z.string(),submitted_at:z.string().nullable().optional()}).strict();
const coldStorageReportIssueSchema=z.object({id:z.uuid(),equipment_id:z.string(),equipment_code:z.string().min(1).max(24).nullable().optional(),equipment_name:z.string(),slot:coldPersistedSlotSchema,temperature_c:z.union([z.number(),z.string()]),title:z.string(),remark:z.string()}).strict();
const phase4aDetailSchema=z.object({id:z.uuid(),branch_id:z.uuid(),branch_name:z.string(),branch_code:z.string().optional(),business_date:z.string(),checklist_type:supervisorChecklistTypeSchema,definition_id:z.string(),submitted_at:z.string().nullable(),submitted_by:z.string().nullable(),auditor_kind:z.enum(["manual_access_user","organization_manager_pin"]).nullable().optional(),completion:z.number(),issue_count:z.number().int().nonnegative(),status:z.string(),record_kind:recordKindSchema.optional(),source_submission_id:z.uuid().nullable().optional(),items:z.array(z.object({item_id:z.string(),item_text:z.string(),answer:z.string(),remark:z.string(),follow_up:z.string().optional(),entry_period:salesTrackingPeriodSchema.nullable().optional(),entered_by:z.string().nullable().optional(),entered_at:z.string().nullable().optional(),evidence:phase4aEvidenceMetadataSchema.nullable().optional()})).max(300).optional(),staff:z.array(phase4aStaffSnapshotSchema).max(500).optional(),opening_submitted_at:z.string().nullable().optional(),closing_submitted_at:z.string().nullable().optional(),submitted_slots:z.array(coldPersistedSlotSchema).max(3).optional(),...coldStorageMissedMetadataSchema,rows:z.array(z.union([oilReportRowSchema,coldStorageReportRowSchema])).max(300).optional(),issues:z.array(z.union([oilReportIssueSchema,coldStorageReportIssueSchema])).max(300).optional()});
const phase4aIssueListSchema=z.object({issues:z.array(z.object({id:uuidLikeSchema,report_id:uuidLikeSchema.nullable(),branch_id:z.uuid(),branch_name:z.string(),business_date:z.string(),submitted_by:z.string().nullable(),checklist_type:managementIssueChecklistTypeSchema,title:z.string(),description:z.string(),status:z.string(),created_at:z.string(),item_id:z.string().nullable().optional(),item_text:z.string().nullable().optional(),affected_staff_id:z.uuid().nullable().optional(),affected_staff_name:z.string().nullable().optional(),record_kind:recordKindSchema.optional(),source_submission_id:uuidLikeSchema.nullable().optional()})).max(50),page:z.number().int().positive(),page_size:z.number().int().positive().max(50),total:z.number().int().nonnegative()});
const managedSalesTrackingOnlineProviderAmountSchema=z.object({provider_id:z.uuid().nullable().optional(),provider_key:z.string().nullable().optional(),provider_name:z.string().min(1).max(120),amount:z.union([z.number(),z.string()])}).strict();
const managedSalesTrackingSchema=z.object({
  sales_rows:z.array(z.object({
    report_id:z.uuid(),row_id:z.uuid(),business_date:dateOnlySchema,entry_date:dateOnlySchema,entry_period:salesTrackingPeriodSchema.nullable(),entered_by:z.string().nullable(),entered_at:z.string().nullable(),branch_id:z.uuid(),branch_name:z.string(),supervisor_user_id:z.uuid(),submitted_by:z.string().nullable(),supervisor_team_id:z.uuid(),supervisor_team_name:z.string(),submitted_at:z.string(),
    actual_cash:z.union([z.number(),z.string()]),actual_credit:z.union([z.number(),z.string()]),pos_cash:z.union([z.number(),z.string()]),pos_credit:z.union([z.number(),z.string()]),online_delivery:z.union([z.number(),z.string()]),online_provider_breakdown:z.array(managedSalesTrackingOnlineProviderAmountSchema).optional().default([]),actual_total:z.union([z.number(),z.string()]),pos_total:z.union([z.number(),z.string()]),variance:z.union([z.number(),z.string()]),remarks:z.string().nullable().optional(),
  }).strict()).max(1000),
  cash_rows:z.array(z.object({
    report_id:z.uuid(),row_id:z.uuid(),business_date:dateOnlySchema,entry_date:dateOnlySchema,entry_period:salesTrackingPeriodSchema.nullable(),entered_by:z.string().nullable(),entered_at:z.string().nullable(),branch_id:z.uuid(),branch_name:z.string(),supervisor_user_id:z.uuid(),submitted_by:z.string().nullable(),supervisor_team_id:z.uuid(),supervisor_team_name:z.string(),submitted_at:z.string(),
    denom_1:z.number().int().nonnegative(),denom_2:z.number().int().nonnegative(),denom_5:z.number().int().nonnegative(),denom_10:z.number().int().nonnegative(),denom_20:z.number().int().nonnegative(),denom_50:z.number().int().nonnegative(),denom_100:z.number().int().nonnegative(),denom_200:z.number().int().nonnegative(),denom_500:z.number().int().nonnegative(),cash_total:z.union([z.number(),z.string()]),remaining_cash:z.union([z.number(),z.string()]),remarks:z.string().nullable().optional(),
  }).strict()).max(1000),
}).strict().transform((result)=>({
  sales_rows:result.sales_rows,
  cash_rows:result.cash_rows.map((row)=>({
    report_id:row.report_id,row_id:row.row_id,business_date:row.business_date,entry_date:row.entry_date,entry_period:row.entry_period,entered_by:row.entered_by,entered_at:row.entered_at,branch_id:row.branch_id,branch_name:row.branch_name,supervisor_user_id:row.supervisor_user_id,submitted_by:row.submitted_by,supervisor_team_id:row.supervisor_team_id,supervisor_team_name:row.supervisor_team_name,submitted_at:row.submitted_at,
    denominations:{"1":row.denom_1,"2":row.denom_2,"5":row.denom_5,"10":row.denom_10,"20":row.denom_20,"50":row.denom_50,"100":row.denom_100,"200":row.denom_200,"500":row.denom_500},
    cash_total:row.cash_total,remaining_cash:row.remaining_cash,remarks:row.remarks,
  })),
}));
const managedInventoryItemsSchema=z.object({
  inventory_month:dateOnlySchema,
  reports:z.array(z.object({
    branch_id:z.uuid(),branch_name:z.string(),branch_code:z.string(),inventory_month:dateOnlySchema,status:z.enum(["submitted","draft","not_submitted"]),
    report_id:z.uuid().nullable(),business_date:dateOnlySchema.nullable(),supervisor_user_id:z.uuid().nullable(),submitted_by:z.string().nullable(),supervisor_team_id:z.uuid().nullable(),supervisor_team_name:z.string().nullable(),updated_at:z.string().nullable(),submitted_at:z.string().nullable(),
    summary:z.object({russian_kg_total:z.union([z.number(),z.string()]),australian_kg_total:z.union([z.number(),z.string()]),total_kg:z.union([z.number(),z.string()]),ready_patty_total:z.union([z.number(),z.string()]),hunch_sauce_total:z.union([z.number(),z.string()]),wastage_total:z.union([z.number(),z.string()]),item_usage_total:z.union([z.number(),z.string()])}).strict(),
    beef_rows:z.array(z.object({row_id:z.uuid(),production_date:dateOnlySchema,russian_kg:z.union([z.number(),z.string()]),australian_kg:z.union([z.number(),z.string()]),fat_kg:z.union([z.number(),z.string()]),total_kg:z.union([z.number(),z.string()]),ready_patty:z.union([z.number(),z.string()]),hunch_sauce_kg:z.union([z.number(),z.string()]),wastage_grams:z.union([z.number(),z.string()])}).strict()).max(62),
    item_usage_rows:z.array(z.object({item_id:z.uuid(),group_name:z.string().min(1).max(120),item_name:z.string().min(1).max(160),usage:z.record(z.string(),z.union([z.number(),z.string()])),total_usage:z.union([z.number(),z.string()])}).strict()).max(200),
  }).strict()).max(250),
}).strict();
const phase4aIssueDetailSchema=z.object({id:uuidLikeSchema,report_id:uuidLikeSchema.nullable(),branch_id:z.uuid(),branch_name:z.string(),business_date:z.string(),submitted_by:z.string().nullable(),checklist_type:managementIssueChecklistTypeSchema,item_id:z.string().nullable().optional(),item_text:z.string().nullable().optional(),affected_staff_id:z.uuid().nullable().optional(),affected_staff_name:z.string().nullable().optional(),remark:z.string(),status:z.string(),created_at:z.string(),record_kind:recordKindSchema.optional(),source_submission_id:uuidLikeSchema.nullable().optional(),evidence:phase4aEvidenceMetadataSchema.nullable().optional()});
function gregorianMonthDayCount(monthStart:string){
  const match=/^(\d{4})-(\d{2})-01$/.exec(monthStart);
  if(!match)return null;
  const year=Number(match[1]),monthIndex=Number(match[2])-1;
  if(monthIndex<0||monthIndex>11)return null;
  return new Date(Date.UTC(year,monthIndex+1,0)).getUTCDate();
}
function managerInventoryCurrentMonth(){
  const parts=new Intl.DateTimeFormat("en-US-u-ca-gregory",{calendar:"gregory",timeZone:"Asia/Riyadh",year:"numeric",month:"2-digit"}).formatToParts(new Date());
  const value=(type:string)=>parts.find((part)=>part.type===type)?.value;
  return `${value("year")}-${value("month")}-01`;
}
const oilCurrentSchema=z.object({
  submission_id:z.uuid().nullable().optional(),
  business_date:dateOnlySchema,
  revision:z.number().int().nonnegative().default(0),
  opening_submitted_at:z.string().nullable().optional(),
  closing_submitted_at:z.string().nullable().optional(),
  opening_submitted:z.boolean(),
  closing_submitted:z.boolean(),
  issue_count:z.number().int().nonnegative().optional(),
  rows:z.array(z.object({
    id:z.uuid().optional(),
    fryer_id:z.string().max(80),
    fryer_label_snapshot:z.string().max(120),
    fryer_short_label_snapshot:z.string().max(40),
    in_use_today:z.boolean(),
    oil_status:z.enum(["pending","new_oil","filtered_oil"]),
    opening_temperature_c:z.union([z.number(),z.string()]).nullable().optional(),
    opening_status:z.enum(["pending","pass","fail"]),
    opening_note:z.string().max(2000),
    closing_tpm_percent:z.union([z.number(),z.string()]).nullable().optional(),
    closing_note:z.string().max(2000),
  }).strict()).max(50),
}).strict();
const coldStorageCurrentSchema=z.object({
  submission_id:z.uuid().nullable().optional(),
  business_date:dateOnlySchema,
  revision:z.number().int().nonnegative().default(0),
  state:z.enum(["none","draft","submitted"]),
  issue_count:z.number().int().nonnegative().optional(),
  equipment:z.array(z.object({
    id:z.uuid().optional(),
    equipment_id:z.string().max(80),
    equipment_code:z.string().min(1).max(24).nullable().optional(),
    equipment_name:z.string().max(120),
    equipment_type:z.enum(["refrigerator","freezer"]),
    active:z.boolean(),
  }).strict()).max(100),
  readings:z.array(z.object({
    id:z.uuid().optional(),
    equipment_id:z.string().max(80),
    slot:coldPersistedSlotSchema,
    temperature_c:z.union([z.number(),z.string()]).nullable().optional(),
    status:z.enum(["pending","pass","fail"]),
    corrective_action:z.string().max(2000),
    submitted_at:z.string().nullable().optional(),
  }).strict()).max(300),
}).strict();
const salesTrackingCurrentSchema=z.object({
  report_id:z.uuid().nullable(),
  business_date:dateOnlySchema,
  state:z.enum(["draft","submitted"]),
  revision:z.number().int().nonnegative().default(0),
  submitted_at:z.string().nullable(),
  submitted_by_user_id:z.uuid().nullable(),
  submitted_by_name_snapshot:z.string().nullable(),
  periods:z.array(z.object({id:z.uuid(),entry_period:salesTrackingPeriodSchema,entered_by_user_id:z.uuid(),entered_by_name:z.string(),entered_at:z.string()}).strict()).max(2),
  sales_rows:z.array(z.object({
    id:z.uuid().optional(),
    entry_date:dateOnlySchema,
    entry_period:salesTrackingPeriodSchema.nullable(),entered_by_user_id:z.uuid().nullable(),entered_by_name:z.string().nullable(),entered_at:z.string().nullable(),
    actual_cash:z.union([z.number(),z.string()]),
    actual_credit:z.union([z.number(),z.string()]),
    pos_cash:z.union([z.number(),z.string()]),
    pos_credit:z.union([z.number(),z.string()]),
    online_delivery:z.union([z.number(),z.string()]),
    online_amounts:z.array(salesTrackingOnlineAmountSchema).optional().default([]),
    remarks:z.string().max(2000).nullable().optional(),
    actual_total:z.union([z.number(),z.string()]).optional(),
    pos_total:z.union([z.number(),z.string()]).optional(),
    variance:z.union([z.number(),z.string()]).optional(),
  }).strict()).max(31),
  cash_rows:z.array(z.object({
    id:z.uuid().optional(),
    entry_date:dateOnlySchema,
    entry_period:salesTrackingPeriodSchema.nullable(),entered_by_user_id:z.uuid().nullable(),entered_by_name:z.string().nullable(),entered_at:z.string().nullable(),
    denom_1:z.number().int().nonnegative(),
    denom_2:z.number().int().nonnegative(),
    denom_5:z.number().int().nonnegative(),
    denom_10:z.number().int().nonnegative(),
    denom_20:z.number().int().nonnegative(),
    denom_50:z.number().int().nonnegative(),
    denom_100:z.number().int().nonnegative(),
    denom_200:z.number().int().nonnegative(),
    denom_500:z.number().int().nonnegative(),
    remaining_cash:z.union([z.number(),z.string()]),
    remarks:z.string().max(2000).nullable().optional(),
    cash_total:z.union([z.number(),z.string()]).optional(),
  }).strict()).max(31),
  totals:salesTrackingTotalsSchema,
}).strict().transform((current)=>({
  ...current,
  cash_rows:current.cash_rows.map((row)=>({
    id:row.id,
    entry_date:row.entry_date,
    entry_period:row.entry_period,
    entered_by_user_id:row.entered_by_user_id,
    entered_by_name:row.entered_by_name,
    entered_at:row.entered_at,
    denominations:{
      "1":row.denom_1,
      "2":row.denom_2,
      "5":row.denom_5,
      "10":row.denom_10,
      "20":row.denom_20,
      "50":row.denom_50,
      "100":row.denom_100,
      "200":row.denom_200,
      "500":row.denom_500,
    },
    remaining_cash:row.remaining_cash,
    remarks:row.remarks,
    cash_total:row.cash_total,
  })),
	}));
const financialClosingCurrentSchema=z.object({
  report_id:z.uuid().nullable(),
  branch_id:z.uuid(),
  business_date:dateOnlySchema,
  state:z.enum(["empty","draft","submitted"]),
  revision:z.number().int().nonnegative().default(0),
  branch_name:z.string(),
  branch_code:z.string(),
  branch_city:z.string().nullable(),
  submitted_at:z.string().nullable(),
  submitted_by_user_id:z.uuid().nullable(),
  submitted_by_name_snapshot:z.string().nullable(),
  updated_at:z.string().nullable(),
  completion:z.union([z.number(),z.string()]).transform(Number),
  not_completed_count:z.union([z.number(),z.string()]).transform(Number),
  items:z.array(z.object({
    item_key:financialClosingItemKeySchema,
    status:financialClosingStatusSchema.nullable(),
    reason:z.string(),
    follow_up:z.string(),
  }).strict()).length(10),
}).strict();
const supervisorNotificationSchema=z.object({
  id:z.uuid(),
  organization_id:z.uuid(),
  branch_id:z.uuid(),
  business_date:dateOnlySchema,
  notification_type:z.enum(["oil_tracking_reminder","cold_storage_reminder","financial_closing_reminder","financial_closing_overdue"]),
  checklist_type:z.enum(["oil_tracking","cold_storage","financial_closing"]),
  rule_key:z.enum(["oil_tracking_1800","cold_storage_2000","financial_closing_2200","financial_closing_2300","financial_closing_0200_overdue"]),
  severity:z.enum(["warning","urgent"]),
  read_at:z.string().nullable(),
  resolved_at:z.string().nullable(),
  created_at:z.string(),
  payload:z.record(z.string(),z.unknown()),
}).strict();
const supervisorNotificationListSchema=z.array(supervisorNotificationSchema).max(50);
const supervisorNotificationResponseSchema=z.object({notifications:supervisorNotificationListSchema,unread_count:z.number().int().nonnegative()}).strict();
const inventoryItemsCurrentSchema=z.object({
  report_id:z.uuid().nullable().optional(),
  business_date:dateOnlySchema,
  inventory_month:dateOnlySchema.optional(),
  state:z.enum(["draft","submitted"]),
  updated_at:z.string().nullable().optional(),
  submitted_at:z.string().nullable().optional(),
  beef_rows:z.array(z.object({
    id:z.uuid().optional(),
    production_date:dateOnlySchema,
    russian_kg:z.union([z.number(),z.string()]),
    australian_kg:z.union([z.number(),z.string()]),
    fat_kg:z.union([z.number(),z.string()]),
    total_kg:z.union([z.number(),z.string()]).optional(),
    ready_patty:z.union([z.number(),z.string()]),
    hunch_sauce_kg:z.union([z.number(),z.string()]),
    wastage_grams:z.union([z.number(),z.string()]),
  }).strict()).max(62),
  item_usage:z.object({
    usage_month:dateOnlySchema,
    items:z.array(z.object({
      id:z.uuid().optional(),
      group_name:z.string().min(1).max(120),
      item_name:z.string().min(1).max(160),
      usage:z.record(z.string(),z.union([z.number(),z.string()])),
    }).strict()).max(200),
  }).strict(),
}).strict();
type SupervisorReportList=z.infer<typeof phase4aListSchema>;
type ManagementIssueList=z.infer<typeof phase4aIssueListSchema>;

function sortSupervisorReports(reports:SupervisorReportList["reports"]){
  return [...reports].sort((a,b)=>{
    const date=b.business_date.localeCompare(a.business_date);
    return date!==0?date:(b.submitted_at??"").localeCompare(a.submitted_at??"");
  });
}

function supervisorReportIdentity(report:SupervisorReportList["reports"][number]){
  return `${report.record_kind??"submission"}:${report.checklist_type}:${report.id}:${report.business_date}`;
}

function mergeSupervisorReportLists(page:number,pageSize:number,...lists:SupervisorReportList[]):SupervisorReportList{
  const merged=lists.flatMap((list)=>list.reports);
  const uniqueByIdentity=new Map<string,SupervisorReportList["reports"][number]>();
  for(const report of merged)uniqueByIdentity.set(supervisorReportIdentity(report),report);
  const reports=sortSupervisorReports([...uniqueByIdentity.values()]).slice((page-1)*pageSize,page*pageSize);
  const duplicateCount=merged.length-uniqueByIdentity.size;
  return {reports,page,page_size:pageSize,total:Math.max(0,lists.reduce((sum,list)=>sum+list.total,0)-duplicateCount)};
}

function emptySupervisorReportList(page:number,pageSize:number):SupervisorReportList{
  return {reports:[],page,page_size:pageSize,total:0};
}

function sortManagementIssues(issues:ManagementIssueList["issues"]){
  return [...issues].sort((a,b)=>{
    const created=b.created_at.localeCompare(a.created_at);
    return created!==0?created:b.id.localeCompare(a.id);
  });
}

function mergeManagementIssueLists(page:number,pageSize:number,...lists:ManagementIssueList[]):ManagementIssueList{
  const issues=sortManagementIssues(lists.flatMap((list)=>list.issues)).slice((page-1)*pageSize,page*pageSize);
  return {issues,page,page_size:pageSize,total:lists.reduce((sum,list)=>sum+list.total,0)};
}

function emptyManagementIssueList(page:number,pageSize:number):ManagementIssueList{
  return {issues:[],page,page_size:pageSize,total:0};
}

function issueDetailWithSourceMetadata(detail:unknown){
  if(typeof detail!=="object"||detail===null)return detail;
  const record=detail as Record<string,unknown>;
  const itemId=typeof record.item_id==="string"?record.item_id:"";
  const derived=itemId==="not_checked"||itemId.startsWith("missed:");
  return {
    ...record,
    record_kind:typeof record.record_kind==="string"?record.record_kind:derived?"derived_missing":"submission",
    source_submission_id:typeof record.source_submission_id==="string"?record.source_submission_id:derived?null:record.report_id,
  };
}

function oilReportLabel(value:string|null|undefined){
  return value?value.replaceAll("_"," ").replace(/\b\w/g,(letter)=>letter.toUpperCase()):"Not recorded";
}

function coldStorageEquipmentLabel(row:{equipment_code?:string|null;equipment_name:string}){
  return row.equipment_code?`${row.equipment_code} - ${row.equipment_name}`:row.equipment_name;
}

function oilReportDetailWithItems(detail:z.infer<typeof phase4aDetailSchema>){
  if(detail.checklist_type!=="oil_tracking"||!detail.rows)return detail;
  const rows=detail.rows as z.infer<typeof oilReportRowSchema>[];
  return {
    ...detail,
    items:rows.map((row)=>({
      item_id:row.fryer_id,
      item_text:[
        row.fryer_label,
        row.in_use_today?"In use":"Inactive",
        `Oil ${oilReportLabel(row.oil_status)}`,
        `Opening ${row.opening_temperature_c==null?"not recorded":`${row.opening_temperature_c}C`} ${oilReportLabel(row.opening_status)}`,
        `Closing TPM ${row.closing_tpm_percent==null?"not recorded":`${row.closing_tpm_percent}%`} ${oilReportLabel(row.tpm_classification)}`,
      ].join(" · "),
      answer:!row.in_use_today?"inactive":row.opening_status==="fail"||(["nearing_end","filtering_required","change_discard"] as Array<string|null|undefined>).includes(row.tpm_classification)?"issue_found":"completed",
      remark:[row.opening_note&&`Opening note: ${row.opening_note}`,row.closing_note&&`Closing note: ${row.closing_note}`].filter(Boolean).join("\n"),
    })),
  };
}

function coldStorageReportDetailWithItems(detail:z.infer<typeof phase4aDetailSchema>){
  if(detail.record_kind==="derived_missing")return detail;
  if(detail.checklist_type!=="cold_storage"||!detail.rows)return detail;
  const rows=detail.rows as z.infer<typeof coldStorageReportRowSchema>[];
  return {
    ...detail,
    items:rows.map((row)=>({
      item_id:`${row.equipment_id}-${row.slot}`,
      item_text:[
        coldStorageEquipmentLabel(row),
        oilReportLabel(row.equipment_type),
        row.active?"Active":"Inactive",
        row.slot,
        row.temperature_c==null?"Temperature not recorded":`${row.temperature_c}C`,
      ].join(" · "),
      answer:!row.active?"inactive":row.status==="fail"?"issue_found":"completed",
      remark:row.corrective_action,
    })),
  };
}

function checklistError(error:unknown){
 if(error instanceof ChecklistConflictError)return new HttpError(409,"conflict","A final report already exists or the replay key conflicts.");
 if(error instanceof ChecklistInputError)return new HttpError(422,"unprocessable_entity","Checklist answers are incomplete or no longer eligible.");
 if(error instanceof ChecklistAccessError)return new HttpError(403,"forbidden","Access is denied.");
 return new HttpError(503,"service_unavailable","The service is unavailable.");
}

function dailyAuditPersistenceError(error:unknown){
 if(error instanceof OperationalConflictError)return new HttpError(409,"conflict","This Daily Audit changed or has already been submitted. Refresh and try again.");
 if(error instanceof OperationalInputError)return new HttpError(422,"unprocessable_entity","The Daily Audit is invalid or incomplete.");
 if(error instanceof OperationalAccessError)return new HttpError(403,"forbidden","Access is denied.");
 return new HttpError(503,"service_unavailable","The service is unavailable.");
}

function evidenceError(error:unknown){
 if(error instanceof EvidenceConflictError)return new HttpError(409,"conflict","Evidence cannot be changed after submission.");
 if(error instanceof EvidenceInputError)return new HttpError(422,"unprocessable_entity","The evidence photo is invalid or unavailable.");
 if(error instanceof EvidenceAccessError)return new HttpError(403,"forbidden","Access is denied.");
 if(error instanceof EvidenceUnavailableError)return new HttpError(503,"service_unavailable","Evidence storage is temporarily unavailable.");
 return new HttpError(503,"service_unavailable","Evidence storage is temporarily unavailable.");
}

function brandingError(error: unknown) {
  if (error instanceof BrandingInputError) return new HttpError(422, "unprocessable_entity", "The branding image is invalid or unavailable.");
  if (error instanceof BrandingAccessError) return new HttpError(403, "forbidden", "Access is denied.");
  if (error instanceof BrandingUnavailableError) return new HttpError(503, "service_unavailable", "Branding storage is temporarily unavailable.");
  return new HttpError(503, "service_unavailable", "Branding storage is temporarily unavailable.");
}

function operationalPurchaseError(error: unknown) {
  if (error instanceof OperationalInputError) return new HttpError(422, "unprocessable_entity", "The purchase log is invalid.");
  if (error instanceof OperationalConflictError) return new HttpError(409, "conflict", "The purchase log conflicts with current team data.");
  if (error instanceof OperationalAccessError) return new HttpError(403, "forbidden", "Access is denied.");
  return new HttpError(503, "service_unavailable", "Purchase Log is temporarily unavailable.");
}

function operationalSupplierReceivingError(error: unknown) {
  if (error instanceof OperationalInputError) return new HttpError(422, "unprocessable_entity", "The supplier receiving entry is invalid.");
  if (error instanceof OperationalConflictError) return new HttpError(409, "conflict", "The supplier receiving entry conflicts with current team data.");
  if (error instanceof OperationalAccessError) return new HttpError(403, "forbidden", "Access is denied.");
  return new HttpError(503, "service_unavailable", "Supplier Receiving is temporarily unavailable.");
}

function operationalColdStorageEquipmentError(error: unknown) {
  if (error instanceof OperationalInputError) return new HttpError(400, "bad_request", "The Cold Storage equipment is invalid.");
  if (error instanceof OperationalDuplicateColdStorageEquipmentCodeError) return new HttpError(409, "duplicate_equipment_code", "Equipment code already exists.");
  if (error instanceof OperationalConflictError) return new HttpError(409, "conflict", "An active equipment name already exists for this branch.");
  if (error instanceof OperationalAccessError) return new HttpError(403, "forbidden", "Access is denied.");
  return new HttpError(503, "service_unavailable", "Cold Storage equipment is temporarily unavailable.");
}

function operationalMaintenanceIssueError(error: unknown) {
  if (error instanceof OperationalInputError) return new HttpError(422, "unprocessable_entity", "The maintenance issue is invalid.");
  if (error instanceof OperationalConflictError) return new HttpError(409, "conflict", "The maintenance issue conflicts with current workflow state.");
  if (error instanceof OperationalAccessError) return new HttpError(403, "forbidden", "Access is denied.");
  return new HttpError(503, "service_unavailable", "Maintenance issues are temporarily unavailable.");
}

function maintenancePushError(error: unknown) {
  if (error instanceof MaintenancePushInputError) return new HttpError(422, "unprocessable_entity", "The push subscription is invalid.");
  if (error instanceof MaintenancePushConflictError) return new HttpError(409, "conflict", "This browser subscription belongs to another account.");
  if (error instanceof MaintenancePushAccessError) return new HttpError(403, "forbidden", "Access is denied.");
  if (error instanceof MaintenancePushUnavailableError) return new HttpError(503, "service_unavailable", "Maintenance notifications are temporarily unavailable.");
  return new HttpError(503, "service_unavailable", "Maintenance notifications are temporarily unavailable.");
}

function browserPushError(error: unknown) {
  if (error instanceof MaintenancePushInputError) return new HttpError(422, "unprocessable_entity", "The push subscription is invalid.");
  if (error instanceof MaintenancePushConflictError) return new HttpError(409, "conflict", "This browser subscription belongs to another account.");
  if (error instanceof MaintenancePushAccessError) return new HttpError(403, "forbidden", "Access is denied.");
  if (error instanceof MaintenancePushUnavailableError) return new HttpError(503, "service_unavailable", "Notifications are temporarily unavailable.");
  return new HttpError(503, "service_unavailable", "Notifications are temporarily unavailable.");
}

function schedulerSecretIsValid(request: Request, configuredSecret: string | undefined) {
  if (!configuredSecret) return false;
  const supplied = request.header("X-Scheduler-Secret") ?? "";
  const expected = Buffer.from(configuredSecret, "utf8");
  const actual = Buffer.from(supplied, "utf8");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function logSupervisorProvisioningFailure(
  request: Request,
  error: unknown,
  fallbackStage: "auth_create" | "database_finalize",
) {
  request.safeFailureLogged = true;
  if (request.app.get("env") === "test") return;

  const details: {
    requestId: string;
    stage: "auth_create" | "database_finalize";
    reason: string;
    upstreamStatus?: number;
    databaseCode?: string;
  } = {
    requestId: request.id,
    stage: fallbackStage,
    reason: "unexpected_error",
  };

  if (error instanceof ProvisioningStageError) {
    details.stage = error.stage === "auth_create" ? "auth_create" : "database_finalize";
    details.reason = error.category;
    if (typeof error.status === "number") details.upstreamStatus = error.status;
    if (error.stage === "database_finalize" && error.databaseCode) details.databaseCode = error.databaseCode;
  }

  console.error("[supervisor-provisioning] failed", details);
}

function evidenceLengthGuard(request:Request,_response:Response,next:NextFunction){
 const raw=request.headers["content-length"];
 if(typeof raw!=="string"||!/^\d+$/.test(raw)||request.headers["transfer-encoding"]){next(new HttpError(411,"bad_request","A valid content length is required."));return;}
 const length=Number(raw);
 if(!Number.isSafeInteger(length)||length<=0){next(new HttpError(400,"bad_request","The evidence photo is invalid."));return;}
 if(length>MAX_EVIDENCE_BYTES){next(new HttpError(413,"payload_too_large","The evidence photo is too large."));return;}
 if(Object.keys(request.headers).some(key=>key.startsWith("x-evidence-"))){next(new HttpError(400,"bad_request","The request is invalid."));return;}
 next();
}

function brandingLengthGuard(request: Request, _response: Response, next: NextFunction) {
  const raw = request.headers["content-length"];
  if (typeof raw !== "string" || !/^\d+$/.test(raw) || request.headers["transfer-encoding"]) {
    next(new HttpError(411, "bad_request", "A valid content length is required."));
    return;
  }
  const length = Number(raw);
  if (!Number.isSafeInteger(length) || length <= 0) {
    next(new HttpError(400, "bad_request", "The branding image is invalid."));
    return;
  }
  if (length > MAX_BRANDING_BYTES) {
    next(new HttpError(413, "payload_too_large", "The branding image is too large."));
    return;
  }
  next();
}

function requireAuthContext(request: Request) {
  if (!request.auth) {
    throw new HttpError(401, "unauthorized", "Authentication is required.");
  }
  return request.auth;
}

function normalizedRequestRoute(request: Request): string {
  const routePath = request.route?.path;
  if (typeof routePath === "string") return routePath;

  const path = request.path;
  if (path.startsWith("/api/")) return "/api/*";
  if (path.startsWith("/health/")) return "/health/*";
  if (/\/[^/]+\.[A-Za-z0-9]{1,8}$/u.test(path)) return "/static/*";
  return "/non-api/*";
}

function requestRateDiagnostic(request: Request, response: Response, next: NextFunction) {
  if (request.app.get("env") === "test") {
    next();
    return;
  }

  const startedAt = performance.now();
  response.once("finish", () => {
    console.info("[request-rate]", {
      timestamp: new Date().toISOString(),
      requestId: request.id,
      method: request.method,
      route: normalizedRequestRoute(request),
      status: response.statusCode,
      durationMs: Math.round((performance.now() - startedAt) * 100) / 100,
    });
  });
  next();
}

async function loadActiveUser(request: Request): Promise<UserContext> {
  const auth = requireAuthContext(request);

  try {
    const context = await auth.userContext.getUserContext(auth.userId);
    if (!context || context.disabled) {
      throw new HttpError(403, "forbidden", "Access is denied.");
    }
    return context;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(
      503,
      "service_unavailable",
      "The service is unavailable.",
    );
  }
}

function hasSupervisorBrowserPushAccess(context: UserContext) {
  return !context.must_change_password
    && context.managed_organizations.length === 0
    && context.branches.some((branch) => branch.role === "branch_manager");
}

async function requireInternalAdmin(request: Request): Promise<void> {
  const auth = requireAuthContext(request);
  try {
    if (!(await auth.userContext.isInternalAdmin?.(auth.userId))) {
      throw new HttpError(403, "forbidden", "Access is denied.");
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(503, "service_unavailable", "The service is unavailable.");
  }
}

export function createApp(
  config: BackendConfig,
  dependencies: BackendDependencies = createDefaultDependencies(config),
): Express {
  const app = express();

  app.set("env", config.nodeEnv);
  app.disable("x-powered-by");
  app.set("trust proxy", config.trustProxy);

  app.use((request, response, next) => {
    request.id = randomUUID();
    response.setHeader("X-Request-Id", request.id);
    next();
  });
  app.use(requestRateDiagnostic);
  app.use(helmet());

  // Liveness deliberately precedes body parsing and all dependency/rate limits.
  app.get("/health/live", (_request, response) => {
    response.setHeader("Cache-Control", "no-store");
    response.status(200).json({ status: "live" });
  });

  app.get("/health/ready", async (_request, response) => {
    let ready = false;
    try {
      ready = await dependencies.checkReadiness();
    } catch {
      ready = false;
    }

    response.setHeader("Cache-Control", "no-store");
    response
      .status(ready ? 200 : 503)
      .json({ status: ready ? "ready" : "unavailable" });
  });

  app.use(express.json({ limit: "100kb", strict: true }));

  const protectedRateLimit = rateLimit({
    windowMs: 60_000,
    limit: 100,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    validate: {
      // Express trust is constrained by validated config. Avoid the library's
      // generic boolean-trust warning because boolean true is never accepted.
      trustProxy: false,
      xForwardedForHeader: false,
    },
    handler(_request, _response, next) {
      next(
        new HttpError(
          429,
          "rate_limited",
          "Too many requests. Try again later.",
        ),
      );
    },
  });
  // The Branch Supervisor shell needs this one read-only request before it can
  // render anything. Internal Next-to-API traffic otherwise shares one IP
  // bucket across users and dashboard requests, which can rate-limit a valid
  // supervisor bootstrap. Authenticate first, then rate-limit per user.
  const supervisorTeamBootstrapRateLimit = rateLimit({
    windowMs: 60_000,
    limit: 60,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    validate: { trustProxy: false, xForwardedForHeader: false },
    keyGenerator(request) {
      return request.auth?.userId ?? ipKeyGenerator(request.ip ?? "unknown");
    },
    handler(_request, _response, next) {
      next(
        new HttpError(
          429,
          "rate_limited",
          "Too many requests. Try again later.",
        ),
      );
    },
  });
  const passwordChangeRateLimit = rateLimit({
    windowMs: 15 * 60_000,
    limit: 5,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    validate: { trustProxy: false, xForwardedForHeader: false },
    handler(_request, _response, next) {
      next(
        new HttpError(
          429,
          "rate_limited",
          "Too many requests. Try again later.",
        ),
      );
    },
  });
  const pinVerificationRateLimit = rateLimit({
    windowMs: 15 * 60_000,
    limit: 5,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    validate: { trustProxy: false, xForwardedForHeader: false },
    keyGenerator(request) {
      const branchId = branchIdSchema.safeParse(request.body?.branch_id);
      return request.auth && branchId.success
        ? `${request.auth.userId}:${branchId.data}`
        : `${request.auth?.userId ?? "unauthenticated"}:invalid`;
    },
    handler(_request, response, next) {
      response.setHeader(
        "Set-Cookie",
        serializeDailyAuditGrantCookie("", config.nodeEnv, 0),
      );
      next(new HttpError(429, "rate_limited", "Unable to verify Daily Audit access."));
    },
  });
  const trainingBranchDiscoveryRateLimit = rateLimit({
    windowMs: 60_000,
    limit: 60,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    validate: { trustProxy: false, xForwardedForHeader: false },
    handler(_request, _response, next) {
      next(new HttpError(429, "rate_limited", "Unable to load Training access."));
    },
  });
  const trainingPinVerificationRateLimit = rateLimit({
    windowMs: 15 * 60_000,
    limit: 10,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    validate: { trustProxy: false, xForwardedForHeader: false },
    keyGenerator(request) {
      const branchId = branchIdSchema.safeParse(request.body?.branch_id);
      return `${ipKeyGenerator(request.ip ?? "unknown")}:${config.trainingOrganizationSlug ?? "unconfigured"}:${branchId.success ? branchId.data : "invalid"}`;
    },
    handler(_request, response, next) {
      setTrainingAccessCookie(response, "", config.nodeEnv, 0);
      next(new HttpError(429, "rate_limited", "Unable to verify Training access."));
    },
  });
  const evidenceUploadRateLimit = rateLimit({
    windowMs:60_000,limit:12,standardHeaders:"draft-8",legacyHeaders:false,
    validate:{trustProxy:false,xForwardedForHeader:false},
    keyGenerator(request){return`${request.auth?.userId??"unauthenticated"}:${request.params.branchId??"invalid"}`;},
    handler(_request,_response,next){next(new HttpError(429,"rate_limited","Too many evidence uploads. Try again later."));},
  });
  const activeEvidenceUploads=new Map<string,number>();
  const evidenceConcurrency=(request:Request,response:Response,next:NextFunction)=>{
    const key=request.auth?.userId??"unauthenticated";const current=activeEvidenceUploads.get(key)??0;
    if(current>=2){next(new HttpError(429,"rate_limited","Too many evidence uploads are active."));return;}
    activeEvidenceUploads.set(key,current+1);let released=false;const release=()=>{if(released)return;released=true;const remaining=(activeEvidenceUploads.get(key)??1)-1;if(remaining<=0)activeEvidenceUploads.delete(key);else activeEvidenceUploads.set(key,remaining);};
    response.once("finish",release);response.once("close",release);next();
  };
  const evidenceRawBody=express.raw({type:()=>true,limit:MAX_EVIDENCE_BYTES});
  const brandingRawBody=express.raw({type:()=>true,limit:MAX_BRANDING_BYTES});
  const purchaseInvoiceRawBody=express.raw({type:()=>true,limit:MAX_PURCHASE_INVOICE_BYTES});
  const maintenanceReceiptRawBody=express.raw({type:()=>true,limit:MAX_PURCHASE_INVOICE_BYTES*MAX_MAINTENANCE_PURCHASE_PHOTOS*2});
  const maintenanceIssuePhotoRawBody=express.raw({type:()=>true,limit:MAX_MAINTENANCE_ISSUE_PHOTO_BYTES*2});
  const supplierReceivingPhotoRawBody=express.raw({type:()=>true,limit:MAX_SUPPLIER_RECEIVING_PHOTO_BYTES});
  const authenticate = requireAuthentication(
    dependencies.authVerifier,
    dependencies.createUserContext,
  );
  async function loadMaintenanceIssueActor(request: Request) {
    const authHeader = request.header("authorization") ?? "";
    const bearer = /^Bearer\s+(.+)$/i.exec(authHeader)?.[1]?.trim();
    if (bearer) {
      const verified = await dependencies.authVerifier.verify(bearer);
      if (!verified) throw new HttpError(401, "unauthorized", "Authentication is required.");
      const context = await dependencies.createUserContext(bearer).getUserContext(verified.userId);
      if (!context || context.disabled || context.must_change_password) {
        throw new HttpError(403, "forbidden", "Access is denied.");
      }
      if (context.managed_organizations.length > 0 || context.branches.some((branch) => branch.role === "branch_manager")) {
        throw new HttpError(403, "forbidden", "Access is denied.");
      }
      return { actorUserId: verified.userId, accessUserId: null as string | null, organizationId: null as string | null };
    }
    const grant = readCookie(request.headers.cookie, "maintenance_access");
    const parsed = grant && dependencies.pinCrypto.verifyMaintenanceGrant?.(grant);
    const maintenanceAdmin = dependencies.maintenanceAccessAdmin;
    if (!parsed || !maintenanceAdmin) throw new HttpError(401, "unauthorized", "Maintenance access is required.");
    const session = await maintenanceAdmin.validateAccessGrant(parsed);
    if (!session) throw new HttpError(401, "unauthorized", "Maintenance access is required.");
    return { actorUserId: null as string | null, accessUserId: session.access_user_id, organizationId: session.organization_id };
  }

  async function loadAuthenticatedMaintenanceUser(request: Request) {
    const auth = requireAuthContext(request);
    const context = await loadActiveUser(request);
    if (
      context.must_change_password ||
      context.managed_organizations.length > 0 ||
      context.branches.length > 0
    ) {
      throw new HttpError(403, "forbidden", "Access is denied.");
    }
    return auth.userId;
  }

  async function loadTrainingBranchSession(request: Request) {
    const grant = readCookie(request.headers.cookie, "training_access");
    const parsed = grant && dependencies.pinCrypto.verifyTrainingGrant?.(grant);
    const trainingAdmin = dependencies.trainingBranchAccessAdmin;
    if (!parsed || !trainingAdmin) {
      throw new HttpError(401, "unauthorized", "Training access is required.");
    }
    const session = await trainingAdmin.validateSession({
      organizationId: parsed.organizationId,
      branchId: parsed.branchId,
      credentialVersion: parsed.credentialVersion,
    });
    if (!session) throw new HttpError(401, "unauthorized", "Training access is required.");
    const employee = parsed.employeeId
      ? await trainingAdmin.validateEmployee({
        organizationId: parsed.organizationId,
        branchId: parsed.branchId,
        employeeId: parsed.employeeId,
      })
      : null;
    return {
      ...session,
      credential_version: parsed.credentialVersion,
      employee,
      employee_invalidated: Boolean(parsed.employeeId && !employee),
      issued_at: new Date(parsed.issuedAt).toISOString(),
      expires_at: new Date(parsed.expiresAt).toISOString(),
      expires_at_ms: parsed.expiresAt,
    };
  }

  app.get(
    "/api/v1/branch-manager/branches",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) throw new HttpError(403, "forbidden", "Access is denied.");
        const branches = await dependencies.branchManagementAdmin.listBranches(auth.userId);
        if (branches.length === 0) throw new HttpError(403, "forbidden", "Access is denied.");
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ branches });
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(503, "service_unavailable", "The service is unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/supervisor/branches/:branchId/branding",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!branchId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        if (!dependencies.brandingService) throw new HttpError(503, "service_unavailable", "Branding storage is temporarily unavailable.");
        const branding = await dependencies.brandingService.getSupervisorBranchBranding(auth.userId, branchId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.setHeader("X-Content-Type-Options", "nosniff");
        response.status(200).json({ branding });
      } catch (error) {
        next(error instanceof HttpError ? error : brandingError(error));
      }
    },
  );
  app.get(
    "/api/v1/branch-manager/branches/:branchId/staff",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!branchId.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) throw new HttpError(403, "forbidden", "Access is denied.");
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ staff: await dependencies.branchManagementAdmin.listStaff(auth.userId, branchId.data) });
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    },
  );
  app.get(
    "/api/v1/management/organizations/:organizationId/daily-audit-pins",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit settings are unavailable."));
      }
    },
  );
  app.put(
    "/api/v1/management/organizations/:organizationId/daily-audit-pins/:managerId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const managerId = z.uuid().safeParse(request.params.managerId);
        const body = pinBodySchema.safeParse(request.body);
        if (!organizationId.success || !managerId.success || !body.success) {
          throw new HttpError(400, "bad_request", "Unable to configure Daily Audit PIN.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "This Daily Audit PIN cannot be used."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit settings are unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/management/organizations/:organizationId/daily-audit-access",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit settings are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/management/organizations/:organizationId/daily-audit-access",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = dailyAuditAccessCreateBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "This Daily Audit access user already exists."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit settings are unavailable."));
      }
    },
  );
  app.delete(
    "/api/v1/management/organizations/:organizationId/daily-audit-access/:accessUserId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const accessUserId = z.uuid().safeParse(request.params.accessUserId);
        if (!organizationId.success || !accessUserId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit settings are unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/management/organizations/:organizationId/maintenance-access-users",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password ||
          !(await auth.userContext.hasOrganizationManagerAccess(auth.userId, organizationId.data))) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        const maintenanceAdmin = dependencies.maintenanceAccessAdmin;
        if (!maintenanceAdmin) throw new HttpError(503, "service_unavailable", "Maintenance access is unavailable.");
        const users = await maintenanceAdmin.listAccessUsers(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ users });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance access is unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/management/organizations/:organizationId/maintenance-access-users",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = maintenanceAccessCreateBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password ||
          !(await auth.userContext.hasOrganizationManagerAccess(auth.userId, organizationId.data))) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        const maintenanceAdmin = dependencies.maintenanceAccessAdmin;
        if (!maintenanceAdmin) throw new HttpError(503, "service_unavailable", "Maintenance access is unavailable.");
        const credential = await dependencies.pinCrypto.hash(body.data.pin);
        await maintenanceAdmin.createAccessUser({
          actorUserId: auth.userId, organizationId: organizationId.data,
          displayName: body.data.display_name, credential,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "This Maintenance access user already exists."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance access is unavailable."));
      }
    },
  );
  app.delete(
    "/api/v1/management/organizations/:organizationId/maintenance-access-users/:accessUserId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const accessUserId = z.uuid().safeParse(request.params.accessUserId);
        if (!organizationId.success || !accessUserId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password ||
          !(await auth.userContext.hasOrganizationManagerAccess(auth.userId, organizationId.data))) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        const maintenanceAdmin = dependencies.maintenanceAccessAdmin;
        if (!maintenanceAdmin) throw new HttpError(503, "service_unavailable", "Maintenance access is unavailable.");
        await maintenanceAdmin.deactivateAccessUser({ actorUserId: auth.userId, organizationId: organizationId.data, accessUserId: accessUserId.data });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance access is unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/management/organizations/:organizationId/maintenance-users",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/management/organizations/:organizationId/maintenance-users",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = maintenanceUserBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  app.delete(
    "/api/v1/management/organizations/:organizationId/maintenance-users/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        if (!organizationId.success || !userId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listOrganizationsForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Organizations are unavailable.");
        }
        const rows = await dependencies.managementAdmin.listOrganizationsForInternalAdmin(auth.userId);
        const organizations = await Promise.all(rows.map(async (organization) => ({
          id: organization.id,
          name: organization.name,
          name_ar: organization.name_ar ?? null,
          active: organization.active,
          logo_url: dependencies.brandingService
            ? await dependencies.brandingService.signLogoPath(organization.logo_path ?? null).catch(() => null)
            : null,
        })));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ organizations });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Organizations are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const body = createOrganizationBodySchema.safeParse(request.body);
        if (!body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.createOrganizationForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Organizations are unavailable.");
        }
        const organization = await dependencies.managementAdmin.createOrganizationForInternalAdmin({
          actorUserId: auth.userId,
          name: body.data.name,
          nameAr: body.data.name_ar,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({ organization: { ...organization, name_ar: organization.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "Organization already exists."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Organizations are unavailable."));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = updateOrganizationBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.updateOrganizationForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Unable to update organization right now.");
        }
        const organization = await dependencies.managementAdmin.updateOrganizationForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          name: body.data.name,
          nameAr: body.data.name_ar,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ organization: { ...organization, name_ar: organization.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "Organization already exists."));
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Organization is unavailable."));
        else if (error instanceof AdminInputError) next(new HttpError(422, "unprocessable_entity", "The organization is invalid."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Unable to update organization right now."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/deactivate",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = internalAdminLifecycleBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.deactivateOrganizationForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Unable to update organization right now.");
        }
        const organization = await dependencies.managementAdmin.deactivateOrganizationForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ organization: { ...organization, name_ar: organization.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Organization is unavailable."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Unable to update organization right now."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/reactivate",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = internalAdminLifecycleBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.reactivateOrganizationForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Unable to update organization right now.");
        }
        const organization = await dependencies.managementAdmin.reactivateOrganizationForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ organization: { ...organization, name_ar: organization.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Organization is unavailable."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Unable to update organization right now."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/logo",
    protectedRateLimit, authenticate, brandingLengthGuard, brandingRawBody, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.brandingService) {
          throw new HttpError(503, "service_unavailable", "Branding storage is temporarily unavailable.");
        }
        const declaredMime = String(request.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
        if (!Buffer.isBuffer(request.body) || request.body.length !== Number(request.header("content-length"))) {
          throw new HttpError(400, "bad_request", "The branding image is invalid.");
        }
        const branding = await dependencies.brandingService.uploadOrganizationLogo({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          bytes: request.body,
          declaredMime,
          requestId: request.id,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.setHeader("X-Content-Type-Options", "nosniff");
        response.status(200).json({ branding });
      } catch (error) {
        next(error instanceof HttpError ? error : brandingError(error));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/maintenance-users",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listMaintenanceUsers) {
          throw new HttpError(503, "service_unavailable", "Maintenance users are unavailable.");
        }
        const users = await dependencies.managementAdmin.listMaintenanceUsers(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ users });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  async function respondWithTrainingBranches(organizationSlug: string | null, response: Response, next: NextFunction) {
    try {
      if (!organizationSlug) throw new HttpError(503, "service_unavailable", "Training access is not configured.");
      const trainingAdmin = dependencies.trainingBranchAccessAdmin;
      if (!trainingAdmin) throw new HttpError(503, "service_unavailable", "Training access is temporarily unavailable.");
      const result = await trainingAdmin.listPublicBranches(organizationSlug);
      if (!result) throw new HttpError(404, "not_found", "Training access is unavailable.");
      response.setHeader("Cache-Control", "private, no-store");
      response.status(200).json(result);
    } catch (error) {
      if (error instanceof HttpError) next(error);
      else next(new HttpError(503, "service_unavailable", "Training access is temporarily unavailable."));
    }
  }

  app.get(
    "/api/v1/training/branches",
    trainingBranchDiscoveryRateLimit,
    async (request, response, next) => {
      if (!emptyQuerySchema.safeParse(request.query).success) {
        next(new HttpError(400, "bad_request", "The request is invalid."));
        return;
      }
      await respondWithTrainingBranches(config.trainingOrganizationSlug ?? null, response, next);
    },
  );
  app.get(
    "/api/v1/training/organizations/:organizationSlug/branches",
    trainingBranchDiscoveryRateLimit,
    async (request, response, next) => {
      const organizationSlug = trainingOrganizationSlugSchema.safeParse(request.params.organizationSlug);
      if (!organizationSlug.success || !emptyQuerySchema.safeParse(request.query).success) {
        next(new HttpError(400, "bad_request", "The request is invalid."));
        return;
      }
      await respondWithTrainingBranches(organizationSlug.data, response, next);
    },
  );
  app.post(
    "/api/v1/training/access/verify",
    trainingPinVerificationRateLimit,
    async (request, response, next) => {
      try {
        const body = trainingBranchAccessVerifyBodySchema.safeParse(request.body);
        const legacyBody = trainingBranchAccessLegacyVerifyBodySchema.safeParse(request.body);
        const parsedBody = body.success ? body.data : legacyBody.success ? legacyBody.data : null;
        const organizationSlug = body.success ? config.trainingOrganizationSlug : legacyBody.success ? legacyBody.data.organization_slug : null;
        if (!parsedBody || !organizationSlug || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "Unable to verify Training access.");
        }
        const trainingAdmin = dependencies.trainingBranchAccessAdmin;
        const issueGrant = dependencies.pinCrypto.issueTrainingGrant;
        if (!trainingAdmin || !issueGrant) {
          throw new HttpError(503, "service_unavailable", "Unable to verify Training access.");
        }
        const credential = await trainingAdmin.getCredential({
          organizationSlug,
          branchId: parsedBody.branch_id,
        });
        if (!credential || !(await dependencies.pinCrypto.verify(parsedBody.pin, credential))) {
          throw new HttpError(403, "forbidden", "Unable to verify Training access.");
        }
        const issuedAt = Date.now();
        const grant = issueGrant(credential.organization_id, credential.branch_id, credential.credential_version, issuedAt);
        response.setHeader("Cache-Control", "private, no-store");
        setTrainingAccessCookie(response, grant, config.nodeEnv, 12 * 60 * 60);
        response.status(200).json({
          verified: true,
          expires_at: new Date(issuedAt + 12 * 60 * 60_000).toISOString(),
          organization: {
            id: credential.organization_id,
            name: credential.organization_name,
            name_ar: credential.organization_name_ar ?? null,
          },
          branch: {
            id: credential.branch_id,
            name: credential.branch_name,
            name_ar: credential.branch_name_ar ?? null,
          },
        });
      } catch (error) {
        setTrainingAccessCookie(response, "", config.nodeEnv, 0);
        next(error instanceof HttpError ? error : new HttpError(503, "service_unavailable", "Unable to verify Training access."));
      }
    },
  );
  app.get(
    "/api/v1/training/session",
    trainingBranchDiscoveryRateLimit,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const session = await loadTrainingBranchSession(request);
        response.setHeader("Cache-Control", "private, no-store");
        if (session.employee_invalidated && dependencies.pinCrypto.issueTrainingGrant) {
          const now = Date.now();
          setTrainingAccessCookie(
            response,
            dependencies.pinCrypto.issueTrainingGrant(session.organization_id, session.branch_id, session.credential_version, now, null, session.expires_at_ms),
            config.nodeEnv,
            Math.max(0, Math.ceil((session.expires_at_ms - now) / 1000)),
          );
        }
        response.status(200).json({
          verified: true,
          expires_at: session.expires_at,
          organization: {
            id: session.organization_id,
            name: session.organization_name,
            name_ar: session.organization_name_ar ?? null,
          },
          branch: {
            id: session.branch_id,
            name: session.branch_name,
            name_ar: session.branch_name_ar ?? null,
          },
          employee: session.employee,
        });
      } catch (error) {
        setTrainingAccessCookie(response, "", config.nodeEnv, 0);
        if (error instanceof HttpError) next(error);
        else next(new HttpError(401, "unauthorized", "Training access is required."));
      }
    },
  );
  app.get(
    "/api/v1/training/employees",
    trainingBranchDiscoveryRateLimit,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const session = await loadTrainingBranchSession(request);
        const trainingAdmin = dependencies.trainingBranchAccessAdmin;
        if (!trainingAdmin) throw new HttpError(503, "service_unavailable", "Training employees are unavailable.");
        const employees = await trainingAdmin.listEmployees({
          organizationId: session.organization_id,
          branchId: session.branch_id,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ employees });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "Training employees are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/training/employee/select",
    trainingBranchDiscoveryRateLimit,
    async (request, response, next) => {
      try {
        const body = trainingEmployeeSelectBodySchema.safeParse(request.body);
        if (!body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const session = await loadTrainingBranchSession(request);
        const trainingAdmin = dependencies.trainingBranchAccessAdmin;
        const issueGrant = dependencies.pinCrypto.issueTrainingGrant;
        if (!trainingAdmin?.selectEmployeeByCode || !issueGrant) throw new HttpError(503, "service_unavailable", "Training employee selection is unavailable.");
        const employee = await trainingAdmin.selectEmployeeByCode({
          organizationId: session.organization_id,
          branchId: session.branch_id,
          employeeCode: body.data.employee_code,
        });
        if (!employee) throw new HttpError(404, "not_found", "Employee code not found.");
        const now = Date.now();
        response.setHeader("Cache-Control", "private, no-store");
        setTrainingAccessCookie(
          response,
          issueGrant(session.organization_id, session.branch_id, session.credential_version, now, employee.employee_id, session.expires_at_ms),
          config.nodeEnv,
          Math.max(0, Math.ceil((session.expires_at_ms - now) / 1000)),
        );
        response.status(200).json({
          selected: true,
          expires_at: session.expires_at,
          employee,
        });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "Employee code is ambiguous."));
        else next(new HttpError(503, "service_unavailable", "Training employee selection is unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/training/employee/clear",
    trainingBranchDiscoveryRateLimit,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success || !emptyQuerySchema.safeParse(request.body ?? {}).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const session = await loadTrainingBranchSession(request);
        const issueGrant = dependencies.pinCrypto.issueTrainingGrant;
        if (!issueGrant) throw new HttpError(503, "service_unavailable", "Training employee selection is unavailable.");
        const now = Date.now();
        response.setHeader("Cache-Control", "private, no-store");
        setTrainingAccessCookie(
          response,
          issueGrant(session.organization_id, session.branch_id, session.credential_version, now, null, session.expires_at_ms),
          config.nodeEnv,
          Math.max(0, Math.ceil((session.expires_at_ms - now) / 1000)),
        );
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "Training employee selection is unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/training/access/logout",
    trainingBranchDiscoveryRateLimit,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success || !emptyQuerySchema.safeParse(request.body ?? {}).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        response.setHeader("Cache-Control", "private, no-store");
        setTrainingAccessCookie(response, "", config.nodeEnv, 0);
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "Unable to clear Training access."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/training-branch-access",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        const trainingAdmin = dependencies.trainingBranchAccessAdmin;
        if (!trainingAdmin) throw new HttpError(503, "service_unavailable", "Branch Training Access is unavailable.");
        const branchAccess = await trainingAdmin.listForInternalAdmin(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ branch_access: branchAccess });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Branch Training Access is unavailable."));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId/training-branch-access/:branchId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = trainingBranchAccessUpdateBodySchema.safeParse(request.body);
        if (!organizationId.success || !branchId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        const trainingAdmin = dependencies.trainingBranchAccessAdmin;
        if (!trainingAdmin) throw new HttpError(503, "service_unavailable", "Branch Training Access is unavailable.");
        const credential = body.data.pin ? await dependencies.pinCrypto.hash(body.data.pin) : null;
        const result = await trainingAdmin.storeForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          branchId: branchId.data,
          enabled: body.data.enabled,
          credential,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Branch is unavailable."));
        else if (error instanceof AdminInputError) next(new HttpError(422, "unprocessable_entity", "Enter valid Branch Training Access details."));
        else next(new HttpError(503, "service_unavailable", "Branch Training Access is unavailable."));
      }
    },
  );
  app.use(
    [
      "/api/v1/training/account",
      "/api/v1/internal-admin/organizations/:organizationId/training-accounts",
    ],
    protectedRateLimit,
    (_request, _response, next) => {
      next(new HttpError(410, "gone", "Training Account email/password access has been retired."));
    },
  );
  app.get(
    "/api/v1/training/account",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        if (!dependencies.managementAdmin.getTrainingAccountContext) {
          throw new HttpError(503, "service_unavailable", "Training access is temporarily unavailable.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        const account = await dependencies.managementAdmin.getTrainingAccountContext(auth.userId);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ account });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Training access is temporarily unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/training-accounts",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listTrainingAccountsForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Training accounts are unavailable.");
        }
        const accounts = await dependencies.managementAdmin.listTrainingAccountsForInternalAdmin(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ accounts });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Training accounts are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/training-accounts",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = trainingAccountBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.provisioningAdmin.finalizeTrainingAccount) {
          throw new HttpError(503, "service_unavailable", "Training accounts are unavailable.");
        }
        let newUserId: string;
        try {
          newUserId = (await dependencies.provisioningAdmin.createUser({
            email: body.data.email,
            password: body.data.temporary_password,
          })).id;
        } catch (error) {
          if (error instanceof AdminConflictError) {
            throw new HttpError(409, "conflict", "An account with that email already exists.");
          }
          throw new HttpError(503, "service_unavailable", "Training accounts are unavailable.");
        }
        try {
          await dependencies.provisioningAdmin.finalizeTrainingAccount({
            actorUserId: auth.userId,
            organizationId: organizationId.data,
            newUserId,
            accountName: body.data.account_name,
            branchIds: body.data.branch_ids,
            active: body.data.active,
          });
        } catch (error) {
          try {
            await dependencies.provisioningAdmin.deleteUser(newUserId);
          } catch {
            if (config.nodeEnv !== "test") {
              console.error("Training account provisioning compensation failed", { requestId: request.id });
            }
          }
          if (error instanceof AdminAccessError) throw new HttpError(403, "forbidden", "Access is denied.");
          if (error instanceof AdminConflictError || error instanceof AdminInputError) {
            throw new HttpError(422, "unprocessable_entity", "The Training account is invalid.");
          }
          throw new HttpError(503, "service_unavailable", "Training accounts are unavailable.");
        }
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({
          id: newUserId,
          account_name: body.data.account_name,
          email: body.data.email,
          organization_id: organizationId.data,
          active: body.data.active,
          branch_ids: body.data.branch_ids,
          must_change_password: true,
        });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "Training accounts are unavailable."));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId/training-accounts/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        const body = trainingAccountUpdateBodySchema.safeParse(request.body);
        if (!organizationId.success || !userId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.updateTrainingAccountForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Training accounts are unavailable.");
        }
        await dependencies.managementAdmin.updateTrainingAccountForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
          accountName: body.data.account_name,
          active: body.data.active,
          branchIds: body.data.branch_ids,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "The Training account was not found."));
        else if (error instanceof AdminConflictError || error instanceof AdminInputError) next(new HttpError(422, "unprocessable_entity", "The Training account is invalid."));
        else next(new HttpError(503, "service_unavailable", "Training accounts are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/training-accounts/:userId/reset-password",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        const body = trainingAccountPasswordResetBodySchema.safeParse(request.body);
        if (!organizationId.success || !userId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.authorizeTrainingAccountPasswordReset || !dependencies.managementAdmin.finalizeTrainingAccountPasswordReset) {
          throw new HttpError(503, "service_unavailable", "Training accounts are unavailable.");
        }
        await dependencies.managementAdmin.authorizeTrainingAccountPasswordReset({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        await dependencies.passwordChange.updatePassword(userId.data, body.data.temporary_password);
        await dependencies.managementAdmin.finalizeTrainingAccountPasswordReset({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Training accounts are unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/managers",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listOrganizationManagersForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Organization Managers are unavailable.");
        }
        const managers = await dependencies.managementAdmin.listOrganizationManagersForInternalAdmin(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ managers });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Organization Managers are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/managers",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = organizationManagerBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.provisioningAdmin.finalizeOrganizationManager) {
          throw new HttpError(503, "service_unavailable", "Organization Managers are unavailable.");
        }
        let newUserId: string;
        try {
          newUserId = (await dependencies.provisioningAdmin.createUser({
            email: body.data.email,
            password: body.data.temporary_password,
          })).id;
        } catch (error) {
          if (error instanceof AdminConflictError) {
            throw new HttpError(409, "conflict", "An account with that email already exists.");
          }
          throw new HttpError(503, "service_unavailable", "Organization Managers are unavailable.");
        }
        try {
          await dependencies.provisioningAdmin.finalizeOrganizationManager({
            actorUserId: auth.userId,
            organizationId: organizationId.data,
            newUserId,
            fullName: body.data.full_name,
            fullNameAr: body.data.full_name_ar,
          });
        } catch {
          try {
            await dependencies.provisioningAdmin.deleteUser(newUserId);
          } catch {
            if (config.nodeEnv !== "test") {
              console.error("Organization Manager provisioning compensation failed", { requestId: request.id });
            }
          }
          throw new HttpError(503, "service_unavailable", "Organization Managers are unavailable.");
        }
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({
          id: newUserId,
          full_name: body.data.full_name,
          full_name_ar: body.data.full_name_ar ?? null,
          email: body.data.email,
          role: "organization_manager",
          organization_id: organizationId.data,
          must_change_password: true,
        });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "Organization Managers are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/managers/existing",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = existingUserGrantBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.grantExistingOrganizationManagerForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Organization Managers are unavailable.");
        }
        await dependencies.managementAdmin.grantExistingOrganizationManagerForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          email: body.data.email,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "No existing account was found for that email."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Organization Managers are unavailable."));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId/managers/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        const body = reactivateAccessBodySchema.safeParse(request.body);
        if (!organizationId.success || !userId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.reactivateOrganizationManagerForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Organization Managers are unavailable.");
        }
        await dependencies.managementAdmin.reactivateOrganizationManagerForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Organization Managers are unavailable."));
      }
    },
  );
  app.get("/api/v1/maintenance/issues/:issueId/purchases",protectedRateLimit,authenticate,async(request,response,next)=>{try{const issue=z.uuid().safeParse(request.params.issueId);if(!issue.success||!emptyQuerySchema.safeParse(request.query).success||!dependencies.operationalAdmin)throw new HttpError(issue.success?503:400,issue.success?"service_unavailable":"bad_request",issue.success?"Maintenance purchases are temporarily unavailable.":"The request is invalid.");const actorUserId=await loadAuthenticatedMaintenanceUser(request);const result=maintenancePurchaseListSchema.parse(await dependencies.operationalAdmin.listMaintenancePurchases(actorUserId,issue.data));response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);}catch(error){next(error instanceof HttpError?error:operationalMaintenanceIssueError(error));}});
  app.post("/api/v1/maintenance/issues/:issueId/purchases",protectedRateLimit,authenticate,maintenanceReceiptRawBody,async(request,response,next)=>{try{const issue=z.uuid().safeParse(request.params.issueId);let raw:unknown=request.body;let receipts:Array<{bytes:Buffer;mimeType:z.infer<typeof maintenancePurchaseReceiptMime>;originalName:string}>=[];if(Buffer.isBuffer(request.body)){const contentType=request.header("Content-Type")?.split(";")[0]?.trim().toLowerCase();if(contentType==="application/vnd.maintenance-purchase+json"){let decoded:unknown;try{decoded=JSON.parse(request.body.toString("utf8"));}catch{throw new HttpError(400,"bad_request","The request is invalid.");}const envelope=maintenancePurchaseUploadEnvelopeSchema.safeParse(decoded);if(!envelope.success)throw new HttpError(400,"bad_request","The request is invalid.");raw=envelope.data.purchase;receipts=envelope.data.attachments.map((attachment)=>({bytes:Buffer.from(attachment.content_base64,"base64"),mimeType:attachment.mime_type,originalName:attachment.original_name?.trim()||"receipt"}));}else{const encoded=request.header("X-Maintenance-Purchase-Payload"),name=decodeUploadFilename(request.header("X-Maintenance-Purchase-Filename-B64"))??"receipt";if(!encoded)throw new HttpError(400,"bad_request","The request is invalid.");try{raw=JSON.parse(Buffer.from(encoded,"base64url").toString("utf8"));}catch{throw new HttpError(400,"bad_request","The request is invalid.");}const mime=maintenancePurchaseReceiptMime.safeParse(contentType);if(!mime.success)throw new HttpError(400,"bad_request","The request is invalid.");receipts=[{bytes:request.body,mimeType:mime.data,originalName:name}];}}const body=maintenancePurchaseBodySchema.safeParse(raw);if(!issue.success||!body.success||!emptyQuerySchema.safeParse(request.query).success||!dependencies.operationalAdmin)throw new HttpError(400,"bad_request","The request is invalid.");const actorUserId=await loadAuthenticatedMaintenanceUser(request);const result=maintenancePurchaseMutationSchema.parse(await dependencies.operationalAdmin.createMaintenancePurchase({actorUserId,issueId:issue.data,payload:body.data,receipts}));response.setHeader("Cache-Control","private, no-store");response.status(201).json(result);}catch(error){next(error instanceof HttpError?error:operationalMaintenanceIssueError(error));}});
  app.get("/api/v1/maintenance/purchase-branches",protectedRateLimit,authenticate,async(request,response,next)=>{try{if(!emptyQuerySchema.safeParse(request.query).success||!dependencies.operationalAdmin?.listMaintenancePurchaseBranches)throw new HttpError(503,"service_unavailable","Maintenance purchase branches are temporarily unavailable.");const actorUserId=await loadAuthenticatedMaintenanceUser(request);const result=maintenancePurchaseBranchListSchema.parse(await dependencies.operationalAdmin.listMaintenancePurchaseBranches({actorUserId}));response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);}catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Maintenance purchase branches are temporarily unavailable."));}});
  app.post("/api/v1/maintenance/purchases/general",protectedRateLimit,authenticate,maintenanceReceiptRawBody,async(request,response,next)=>{try{let raw:unknown=request.body;let receipts:Array<{bytes:Buffer;mimeType:z.infer<typeof maintenancePurchaseReceiptMime>;originalName:string}>=[];if(Buffer.isBuffer(request.body)){const contentType=request.header("Content-Type")?.split(";")[0]?.trim().toLowerCase();if(contentType==="application/vnd.maintenance-purchase+json"){let decoded:unknown;try{decoded=JSON.parse(request.body.toString("utf8"));}catch{throw new HttpError(400,"bad_request","The request is invalid.");}const envelope=maintenancePurchaseUploadEnvelopeSchema.safeParse(decoded);if(!envelope.success)throw new HttpError(400,"bad_request","The request is invalid.");raw=envelope.data.purchase;receipts=envelope.data.attachments.map((attachment)=>({bytes:Buffer.from(attachment.content_base64,"base64"),mimeType:attachment.mime_type,originalName:attachment.original_name?.trim()||"receipt"}));}else{const encoded=request.header("X-Maintenance-Purchase-Payload"),name=decodeUploadFilename(request.header("X-Maintenance-Purchase-Filename-B64"))??"receipt";if(!encoded)throw new HttpError(400,"bad_request","The request is invalid.");try{raw=JSON.parse(Buffer.from(encoded,"base64url").toString("utf8"));}catch{throw new HttpError(400,"bad_request","The request is invalid.");}const mime=maintenancePurchaseReceiptMime.safeParse(contentType);if(!mime.success)throw new HttpError(400,"bad_request","The request is invalid.");receipts=[{bytes:request.body,mimeType:mime.data,originalName:name}];}}const body=maintenancePurchaseBodySchema.safeParse(raw);if(!body.success||!emptyQuerySchema.safeParse(request.query).success||!dependencies.operationalAdmin)throw new HttpError(400,"bad_request","The request is invalid.");if(body.data.purchase_type==="issue"||body.data.branch_id||!body.data.destination)throw new HttpError(422,"unprocessable_entity","The maintenance purchase details are invalid.");const actorUserId=await loadAuthenticatedMaintenanceUser(request);const result=maintenancePurchaseMutationSchema.parse(await dependencies.operationalAdmin.createMaintenancePurchase({actorUserId,issueId:null,payload:{...body.data,purchase_type:"general",purchase_scope:"other",branch_id:null},receipts}));response.setHeader("Cache-Control","private, no-store");response.status(201).json(result);}catch(error){next(error instanceof HttpError?error:operationalMaintenanceIssueError(error));}});
  app.get("/api/v1/maintenance/purchases/issue",protectedRateLimit,authenticate,async(request,response,next)=>{try{if(!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");if(!dependencies.operationalAdmin?.listMaintenancePurchaseHistory)throw new HttpError(503,"service_unavailable","Maintenance purchase history is temporarily unavailable.");const actorUserId=await loadAuthenticatedMaintenanceUser(request);const result=managedMaintenancePurchaseListSchema.parse(await dependencies.operationalAdmin.listMaintenancePurchaseHistory({actorUserId,purchaseType:"issue"}));const safeResult=maintenancePurchaseHistoryListSchema.parse({maintenance_purchases:result.maintenance_purchases.map(({maintenance_user_id,...purchase})=>{void maintenance_user_id;return purchase;})});response.setHeader("Cache-Control","private, no-store");response.status(200).json(safeResult);}catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Maintenance purchase history is temporarily unavailable."));}});
  app.get("/api/v1/maintenance/purchases/general",protectedRateLimit,authenticate,async(request,response,next)=>{try{if(!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");if(!dependencies.operationalAdmin?.listMaintenancePurchaseHistory)throw new HttpError(503,"service_unavailable","Maintenance purchase history is temporarily unavailable.");const actorUserId=await loadAuthenticatedMaintenanceUser(request);const result=managedMaintenancePurchaseListSchema.parse(await dependencies.operationalAdmin.listMaintenancePurchaseHistory({actorUserId,purchaseType:"general"}));const safeResult=maintenancePurchaseHistoryListSchema.parse({maintenance_purchases:result.maintenance_purchases.map(({maintenance_user_id,...purchase})=>{void maintenance_user_id;return purchase;})});response.setHeader("Cache-Control","private, no-store");response.status(200).json(safeResult);}catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Maintenance purchase history is temporarily unavailable."));}});
  app.patch("/api/v1/maintenance/purchases/:purchaseId/payment-status",protectedRateLimit,authenticate,async(request,response,next)=>{try{const purchase=z.uuid().safeParse(request.params.purchaseId),body=maintenancePurchasePaymentBodySchema.safeParse(request.body);if(!purchase.success||!body.success||!emptyQuerySchema.safeParse(request.query).success||!dependencies.operationalAdmin)throw new HttpError(400,"bad_request","The request is invalid.");const actorUserId=await loadAuthenticatedMaintenanceUser(request);const result=maintenancePurchaseMutationSchema.parse(await dependencies.operationalAdmin.reimburseMaintenancePurchase({actorUserId,purchaseId:purchase.data,reimbursementNote:body.data.reimbursement_note}));response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);}catch(error){next(error instanceof HttpError?error:operationalMaintenanceIssueError(error));}});
  app.delete(
    "/api/v1/internal-admin/organizations/:organizationId/managers/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        if (!organizationId.success || !userId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.deactivateOrganizationManagerForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Organization Managers are unavailable.");
        }
        await dependencies.managementAdmin.deactivateOrganizationManagerForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Organization Managers are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/maintenance-users",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = maintenanceUserBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.provisioningAdmin.finalizeMaintenance) {
          throw new HttpError(503, "service_unavailable", "Maintenance users are unavailable.");
        }
        let newUserId: string;
        try {
          newUserId = (await dependencies.provisioningAdmin.createUser({
            email: body.data.email,
            password: body.data.temporary_password,
          })).id;
        } catch (error) {
          if (error instanceof AdminConflictError) {
            throw new HttpError(409, "conflict", "An account with that email already exists.");
          }
          throw new HttpError(503, "service_unavailable", "Maintenance users are unavailable.");
        }
        try {
          await dependencies.provisioningAdmin.finalizeMaintenance({
            actorUserId: auth.userId,
            organizationId: organizationId.data,
            newUserId,
            fullName: body.data.full_name,
            fullNameAr: body.data.full_name_ar,
          });
        } catch {
          try {
            await dependencies.provisioningAdmin.deleteUser(newUserId);
          } catch {
            if (config.nodeEnv !== "test") {
              console.error("Maintenance user provisioning compensation failed", { requestId: request.id });
            }
          }
          throw new HttpError(503, "service_unavailable", "Maintenance users are unavailable.");
        }
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({
          id: newUserId,
          full_name: body.data.full_name,
          full_name_ar: body.data.full_name_ar ?? null,
          email: body.data.email,
          role: "maintenance_user",
          organization_id: organizationId.data,
          must_change_password: true,
        });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/maintenance-users/existing",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = existingUserGrantBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.grantExistingMaintenanceUser) {
          throw new HttpError(503, "service_unavailable", "Maintenance users are unavailable.");
        }
        await dependencies.managementAdmin.grantExistingMaintenanceUser({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          email: body.data.email,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "No existing account was found for that email."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId/maintenance-users/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        const body = reactivateAccessBodySchema.safeParse(request.body);
        if (!organizationId.success || !userId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.reactivateMaintenanceUser) {
          throw new HttpError(503, "service_unavailable", "Maintenance users are unavailable.");
        }
        await dependencies.managementAdmin.reactivateMaintenanceUser({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  app.delete(
    "/api/v1/internal-admin/organizations/:organizationId/maintenance-users/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        if (!organizationId.success || !userId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.deactivateMaintenanceUser) {
          throw new HttpError(503, "service_unavailable", "Maintenance users are unavailable.");
        }
        await dependencies.managementAdmin.deactivateMaintenanceUser({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Maintenance users are unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/branches",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listBranchesForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Branches are unavailable.");
        }
        const rows = await dependencies.managementAdmin.listBranchesForInternalAdmin(auth.userId, organizationId.data);
        const branches = await Promise.all(rows.map(async (branch) => ({
          id: branch.id,
          name: branch.name,
          name_ar: branch.name_ar ?? null,
          code: branch.code,
          city: branch.city ?? null,
          area: branch.area ?? null,
          address: branch.address ?? null,
          timezone: branch.timezone,
          active: branch.active,
          logo_configured: Boolean(branch.logo_path),
          logo_url: dependencies.brandingService
            ? await dependencies.brandingService.signLogoPath(branch.logo_path ?? null).catch(() => null)
            : null,
        })));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ branches });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Branches are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/branches/:branchId/logo",
    protectedRateLimit, authenticate, brandingLengthGuard, brandingRawBody, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!organizationId.success || !branchId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.brandingService) {
          throw new HttpError(503, "service_unavailable", "Branding storage is temporarily unavailable.");
        }
        const declaredMime = String(request.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
        if (!Buffer.isBuffer(request.body) || request.body.length !== Number(request.header("content-length"))) {
          throw new HttpError(400, "bad_request", "The branding image is invalid.");
        }
        const branding = await dependencies.brandingService.uploadBranchLogo({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          branchId: branchId.data,
          bytes: request.body,
          declaredMime,
          requestId: request.id,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.setHeader("X-Content-Type-Options", "nosniff");
        response.status(200).json({ branding });
      } catch (error) {
        next(error instanceof HttpError ? error : brandingError(error));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId/branches/:branchId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = updateBranchBodySchema.safeParse(request.body);
        if (!organizationId.success || !branchId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.updateBranchForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Unable to update branch right now.");
        }
        const branch = await dependencies.managementAdmin.updateBranchForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          branchId: branchId.data,
          name: body.data.name,
          nameAr: body.data.name_ar,
          code: body.data.code,
          city: body.data.city,
          area: body.data.area,
          address: body.data.address,
          timezone: body.data.timezone,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ branch: { ...branch, name_ar: branch.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "Branch already exists."));
        else if (error instanceof AdminInputError) next(new HttpError(422, "unprocessable_entity", "Enter valid branch details."));
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Organization is unavailable."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Unable to update branch right now."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/branches/:branchId/deactivate",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = internalAdminLifecycleBodySchema.safeParse(request.body);
        if (!organizationId.success || !branchId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.deactivateBranchForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Unable to update branch right now.");
        }
        const branch = await dependencies.managementAdmin.deactivateBranchForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          branchId: branchId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ branch: { ...branch, name_ar: branch.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Organization is unavailable."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Unable to update branch right now."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/branches/:branchId/reactivate",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = internalAdminLifecycleBodySchema.safeParse(request.body);
        if (!organizationId.success || !branchId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.reactivateBranchForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Unable to update branch right now.");
        }
        const branch = await dependencies.managementAdmin.reactivateBranchForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          branchId: branchId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ branch: { ...branch, name_ar: branch.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Organization is unavailable."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Unable to update branch right now."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/branches",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = createBranchBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.createBranchForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Branches are unavailable.");
        }
        const branch = await dependencies.managementAdmin.createBranchForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          name: body.data.name,
          nameAr: body.data.name_ar,
          code: body.data.code,
          city: body.data.city,
          area: body.data.area,
          address: body.data.address,
          timezone: body.data.timezone,
          active: body.data.active,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({ branch: { ...branch, name_ar: branch.name_ar ?? null } });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "Branch already exists."));
        else if (error instanceof AdminInputError) next(new HttpError(422, "unprocessable_entity", "Enter valid branch details."));
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "Organization is unavailable."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Unable to create branch right now."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/branch-teams",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listBranchTeamsForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Branch Teams are unavailable.");
        }
        const teams = await dependencies.managementAdmin.listBranchTeamsForInternalAdmin(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ teams });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Branch Teams are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/branch-teams",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = createInternalAdminBranchTeamBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.createBranchTeamForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Branch Teams are unavailable.");
        }
        const primarySupervisorUserId = body.data.primary_supervisor_user_id ?? body.data.supervisor_user_id;
        if (!primarySupervisorUserId) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const team = await dependencies.managementAdmin.createBranchTeamForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          teamName: body.data.team_name ?? body.data.company_name,
          companyName: body.data.company_name,
          branchId: body.data.branch_id,
          primarySupervisorUserId,
          backupSupervisorUserId: body.data.backup_supervisor_user_id ?? null,
          initialStaff: (body.data.initial_staff ?? []).map((staff) => ({
            displayName: staff.display_name,
            companyName: staff.company_name,
            staffCode: staff.staff_code,
            countryCode: staff.country_code,
            roles: [staff.primary_role, ...(staff.secondary_role ? [staff.secondary_role] : [])],
          })),
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({ team });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminDuplicateStaffCodeError) next(new HttpError(409, "duplicate_employee_code", "Employee code already exists for this organization."));
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "This Branch Team already exists."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(400, "bad_request", "Unable to create Branch Team."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/branch-teams/:teamId/staff",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const teamId = organizationIdSchema.safeParse(request.params.teamId);
        const body = createInternalAdminBranchTeamStaffBodySchema.safeParse(request.body);
        if (!organizationId.success || !teamId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.createBranchTeamStaffForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Branch Team staff is unavailable.");
        }
        const roles = [body.data.primary_role, ...(body.data.secondary_role ? [body.data.secondary_role] : [])];
        const staff = await dependencies.managementAdmin.createBranchTeamStaffForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          teamId: teamId.data,
          displayName: body.data.display_name,
          companyName: body.data.company_name,
          staffCode: body.data.staff_code,
          countryCode: body.data.country_code,
          roles,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({ staff });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminDuplicateStaffCodeError) next(new HttpError(409, "duplicate_employee_code", "Employee code already exists for this organization."));
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "Unable to create Branch Team staff."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(400, "bad_request", "Unable to create Branch Team staff."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/daily-audit-access",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        const pinAdmin = dependencies.dailyAuditPinAdmin;
        if (!pinAdmin?.listManagersForInternalAdmin || !pinAdmin.listAccessUsersForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Daily Audit access is unavailable.");
        }
        const [managers, users] = await Promise.all([
          pinAdmin.listManagersForInternalAdmin(auth.userId, organizationId.data),
          pinAdmin.listAccessUsersForInternalAdmin(auth.userId, organizationId.data),
        ]);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ managers, users });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit access is unavailable."));
      }
    },
  );
  app.put(
    "/api/v1/internal-admin/organizations/:organizationId/daily-audit-pins/:managerId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const managerId = z.uuid().safeParse(request.params.managerId);
        const body = pinBodySchema.safeParse(request.body);
        if (!organizationId.success || !managerId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "Unable to configure Daily Audit PIN.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        const pinAdmin = dependencies.dailyAuditPinAdmin;
        if (!pinAdmin?.storeManagerPinForInternalAdmin || !dependencies.pinCrypto.fingerprint) {
          throw new HttpError(503, "service_unavailable", "Daily Audit access is unavailable.");
        }
        const credential = await dependencies.pinCrypto.hash(body.data.pin);
        const metadata = await pinAdmin.storeManagerPinForInternalAdmin({
          actorUserId: auth.userId, organizationId: organizationId.data,
          managerUserId: managerId.data, credential,
          fingerprint: dependencies.pinCrypto.fingerprint(body.data.pin),
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(metadata);
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "This Daily Audit PIN cannot be used."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit access is unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/daily-audit-access",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = dailyAuditAccessCreateBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        const pinAdmin = dependencies.dailyAuditPinAdmin;
        if (!pinAdmin?.createAccessUserForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Daily Audit access is unavailable.");
        }
        const credential = await dependencies.pinCrypto.hash(body.data.pin);
        await pinAdmin.createAccessUserForInternalAdmin({
          actorUserId: auth.userId, organizationId: organizationId.data,
          displayName: body.data.display_name, credential,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "This Daily Audit access user already exists."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit access is unavailable."));
      }
    },
  );
  app.delete(
    "/api/v1/internal-admin/organizations/:organizationId/daily-audit-access/:accessUserId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const accessUserId = z.uuid().safeParse(request.params.accessUserId);
        if (!organizationId.success || !accessUserId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        const pinAdmin = dependencies.dailyAuditPinAdmin;
        if (!pinAdmin?.revokeAccessUserForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Daily Audit access is unavailable.");
        }
        await pinAdmin.revokeAccessUserForInternalAdmin({
          actorUserId: auth.userId, organizationId: organizationId.data, accessUserId: accessUserId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Daily Audit access is unavailable."));
      }
    },
  );
  app.get(
    "/api/v1/internal-admin/organizations/:organizationId/supervisors",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listSupervisorsForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Supervisors are unavailable.");
        }
        const supervisors = await dependencies.managementAdmin.listSupervisorsForInternalAdmin(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ supervisors });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Supervisors are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/supervisors",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = provisioningBodySchema.safeParse(request.body);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        if (!body.success) {
          if (body.error.issues.some((issue) => issue.path[0] === "country_code")) {
            throw new HttpError(422, "invalid_country", "Select a valid country.");
          }
          if (body.error.issues.some((issue) => issue.path[0] === "iqama_expiry_date")) {
            throw new HttpError(422, "invalid_iqama_expiry", "Enter a valid Gregorian Iqama expiry date.");
          }
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listBranchesForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "The service is unavailable.");
        }
        const branches = await dependencies.managementAdmin.listBranchesForInternalAdmin(auth.userId, organizationId.data);
        const activeBranchIds = new Set(branches.filter((branch) => branch.active).map((branch) => branch.id));
        if (!body.data.branch_ids.every((branchId) => activeBranchIds.has(branchId))) {
          throw new HttpError(404, "not_found", "The requested resource was not found.");
        }

        let newUserId: string;
        try {
          newUserId = (await dependencies.provisioningAdmin.createUser({
            email: body.data.email,
            password: body.data.temporary_password,
          })).id;
        } catch (error) {
          if (error instanceof AdminConflictError) {
            throw new HttpError(409, "conflict", "An account with that email already exists.");
          }
          logSupervisorProvisioningFailure(request, error, "auth_create");
          throw new HttpError(503, "service_unavailable", "The service is unavailable.");
        }

        try {
          await dependencies.provisioningAdmin.finalize({
            actorUserId: auth.userId,
            organizationId: organizationId.data,
            newUserId,
            fullName: body.data.full_name,
            fullNameAr: body.data.full_name_ar,
            personCode: body.data.person_code,
            phoneNumber: body.data.phone_number,
            countryCode: body.data.country_code,
            iqamaNumber: body.data.iqama_number,
            iqamaExpiryDate: body.data.iqama_expiry_date,
            role: "branch_manager",
            branchIds: body.data.branch_ids,
            supervisorTeamAssignments: body.data.supervisor_team_assignments.map((assignment) => ({
              operationalTeamId: assignment.operational_team_id,
              assignmentRole: assignment.assignment_role,
            })),
          });
        } catch (error) {
          try {
            await dependencies.provisioningAdmin.deleteUser(newUserId);
          } catch {
            if (config.nodeEnv !== "test") {
              console.error("Supervisor provisioning compensation failed", { requestId: request.id });
            }
          }
          if (error instanceof AdminConflictError) {
            throw new HttpError(409, "conflict", "Supervisor team assignment conflicts with current team data.");
          }
          if (error instanceof AdminAccessError) {
            throw new HttpError(403, "forbidden", "Access is denied.");
          }
          if (error instanceof AdminDuplicatePersonCodeError) {
            throw new HttpError(409, "duplicate_person_code", "Supervisor code already exists.");
          }
          logSupervisorProvisioningFailure(request, error, "database_finalize");
          throw new HttpError(503, "service_unavailable", "The service is unavailable.");
        }

        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({
          id: newUserId,
          full_name: body.data.full_name,
          full_name_ar: body.data.full_name_ar ?? null,
          person_code: body.data.person_code,
          phone_number: body.data.phone_number,
          country_code: body.data.country_code,
          iqama_number: body.data.iqama_number,
          iqama_expiry_date: body.data.iqama_expiry_date,
          role: "branch_manager",
          branch_ids: body.data.branch_ids,
          must_change_password: true,
        });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "The service is unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/internal-admin/organizations/:organizationId/supervisors/existing",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = existingSupervisorGrantBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.listBranchesForInternalAdmin || !dependencies.managementAdmin.grantExistingSupervisorForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Supervisors are unavailable.");
        }
        const branches = await dependencies.managementAdmin.listBranchesForInternalAdmin(auth.userId, organizationId.data);
        const activeBranchIds = new Set(branches.filter((branch) => branch.active).map((branch) => branch.id));
        if (!body.data.branch_ids.every((branchId) => activeBranchIds.has(branchId))) {
          throw new HttpError(404, "not_found", "The requested resource was not found.");
        }
        await dependencies.managementAdmin.grantExistingSupervisorForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          email: body.data.email,
          branchIds: body.data.branch_ids,
          supervisorTeamAssignments: body.data.supervisor_team_assignments.map((assignment) => ({
            operationalTeamId: assignment.operational_team_id,
            assignmentRole: assignment.assignment_role,
          })),
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "Supervisor team assignment conflicts with current team data."));
        else if (error instanceof AdminNotFoundError) next(new HttpError(404, "not_found", "No existing account was found for that email."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Supervisors are unavailable."));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId/supervisors/:userId/profile",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        const body = supervisorProfileBodySchema.safeParse(request.body);
        if (!organizationId.success || !userId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        if (!body.success) {
          if (body.error.issues.some((issue) => issue.path[0] === "country_code")) {
            throw new HttpError(422, "invalid_country", "Select a valid country.");
          }
          if (body.error.issues.some((issue) => issue.path[0] === "iqama_expiry_date")) {
            throw new HttpError(422, "invalid_iqama_expiry", "Enter a valid Gregorian Iqama expiry date.");
          }
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.updateSupervisorProfileForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Supervisors are unavailable.");
        }
        const supervisor = await dependencies.managementAdmin.updateSupervisorProfileForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
          fullName: body.data.full_name,
          fullNameAr: body.data.full_name_ar,
          personCode: body.data.person_code,
          phoneNumber: body.data.phone_number,
          countryCode: body.data.country_code,
          iqamaNumber: body.data.iqama_number,
          iqamaExpiryDate: body.data.iqama_expiry_date,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ supervisor });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminDuplicatePersonCodeError) next(new HttpError(409, "duplicate_person_code", "Supervisor code already exists."));
        else if (error instanceof AdminConflictError) next(new HttpError(422, "invalid_profile", "The Supervisor profile is invalid."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Supervisors are unavailable."));
      }
    },
  );
  app.patch(
    "/api/v1/internal-admin/organizations/:organizationId/supervisors/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        const body = reactivateAccessBodySchema.safeParse(request.body);
        if (!organizationId.success || !userId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.reactivateSupervisorForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Supervisors are unavailable.");
        }
        await dependencies.managementAdmin.reactivateSupervisorForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Supervisors are unavailable."));
      }
    },
  );
  app.delete(
    "/api/v1/internal-admin/organizations/:organizationId/supervisors/:userId",
    protectedRateLimit, authenticate, async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const userId = z.uuid().safeParse(request.params.userId);
        if (!organizationId.success || !userId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        await requireInternalAdmin(request);
        if (!dependencies.managementAdmin.deactivateSupervisorForInternalAdmin) {
          throw new HttpError(503, "service_unavailable", "Supervisors are unavailable.");
        }
        await dependencies.managementAdmin.deactivateSupervisorForInternalAdmin({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          userId: userId.data,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(204).end();
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Supervisors are unavailable."));
      }
    },
  );
  app.post(
    "/api/v1/maintenance/access/verify",
    protectedRateLimit, pinVerificationRateLimit, async (request, response, next) => {
      try {
        const body = maintenanceAccessVerifyBodySchema.safeParse(request.body);
        if (!body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "Unable to verify Maintenance access.");
        }
        const maintenanceAdmin = dependencies.maintenanceAccessAdmin;
        const issueGrant = dependencies.pinCrypto.issueMaintenanceGrant;
        if (!maintenanceAdmin || !issueGrant) {
          throw new HttpError(503, "service_unavailable", "Unable to verify Maintenance access.");
        }
        const credential = await maintenanceAdmin.getAccessCredential({
          organizationIdentifier: body.data.organization,
          displayName: body.data.display_name,
        });
        if (!credential || !(await dependencies.pinCrypto.verify(body.data.pin, credential))) {
          throw new HttpError(403, "forbidden", "Unable to verify Maintenance access.");
        }
        const grant = issueGrant(credential.organization_id, credential.access_user_id, credential.credential_version);
        response.setHeader("Cache-Control", "private, no-store");
        response.setHeader("Set-Cookie", serializeMaintenanceAccessCookie(grant, config.nodeEnv, 8 * 60 * 60));
        response.status(200).json({
          verified: true,
          expires_in: 8 * 60 * 60,
          organization: { id: credential.organization_id, name: credential.organization_name },
          access_user: { id: credential.access_user_id, display_name: credential.display_name },
        });
      } catch (error) {
        response.setHeader("Set-Cookie", serializeMaintenanceAccessCookie("", config.nodeEnv, 0));
        next(error instanceof HttpError ? error : new HttpError(503, "service_unavailable", "Unable to verify Maintenance access."));
      }
    },
  );
  app.get(
    "/api/v1/maintenance/access/session",
    protectedRateLimit, async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const grant = readCookie(request.headers.cookie, "maintenance_access");
        const parsed = grant && dependencies.pinCrypto.verifyMaintenanceGrant?.(grant);
        const maintenanceAdmin = dependencies.maintenanceAccessAdmin;
        if (!parsed || !maintenanceAdmin) {
          throw new HttpError(401, "unauthorized", "Maintenance access is required.");
        }
        const session = await maintenanceAdmin.validateAccessGrant(parsed);
        if (!session) throw new HttpError(401, "unauthorized", "Maintenance access is required.");
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({
          verified: true,
          organization: {
            id: session.organization_id,
            name: session.organization_name,
            logo_url: dependencies.brandingService
              ? await dependencies.brandingService.getMaintenanceAccessOrganizationBranding(session.organization_id)
                .then((branding) => branding.organization_logo_url)
                .catch(() => null)
              : null,
          },
          access_user: { id: session.access_user_id, display_name: session.display_name },
        });
      } catch (error) {
        response.setHeader("Set-Cookie", serializeMaintenanceAccessCookie("", config.nodeEnv, 0));
        if (error instanceof HttpError) next(error);
        else next(new HttpError(401, "unauthorized", "Maintenance access is required."));
      }
    },
  );
  app.get(
    "/api/v1/maintenance/organizations/:organizationId/branding",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        if (!dependencies.brandingService) throw new HttpError(503, "service_unavailable", "Branding storage is temporarily unavailable.");
        const branding = await dependencies.brandingService.getMaintenanceOrganizationBranding(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.setHeader("X-Content-Type-Options", "nosniff");
        response.status(200).json({ branding });
      } catch (error) {
        next(error instanceof HttpError ? error : brandingError(error));
      }
    },
  );
  app.post(
    "/api/v1/maintenance/access/logout",
    protectedRateLimit, async (_request, response) => {
      response.setHeader("Cache-Control", "private, no-store");
      response.setHeader("Set-Cookie", serializeMaintenanceAccessCookie("", config.nodeEnv, 0));
      response.status(200).json({ logged_out: true });
    },
  );
  app.get(
    "/api/v1/maintenance/push/public-key",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        await loadAuthenticatedMaintenanceUser(request);
        const publicKey = dependencies.maintenancePush?.getPublicKey() ?? null;
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ enabled: publicKey !== null, public_key: publicKey });
      } catch (error) {
        next(error instanceof HttpError ? error : maintenancePushError(error));
      }
    },
  );
  app.post(
    "/api/v1/maintenance/push/subscriptions",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const body = pushSubscriptionBodySchema.safeParse(request.body);
        if (!body.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        if (!dependencies.maintenancePush) throw new HttpError(503, "service_unavailable", "Maintenance notifications are temporarily unavailable.");
        const actorUserId = await loadAuthenticatedMaintenanceUser(request);
        const result = pushSubscriptionResponseSchema.parse(await dependencies.maintenancePush.registerSubscription({
          actorUserId,
          endpoint: body.data.endpoint,
          p256dh: body.data.keys.p256dh,
          auth: body.data.keys.auth,
          userAgent: request.header("User-Agent") ?? null,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : maintenancePushError(error));
      }
    },
  );
  app.delete(
    "/api/v1/maintenance/push/subscriptions",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const body = pushSubscriptionDeleteBodySchema.safeParse(request.body);
        if (!body.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        if (!dependencies.maintenancePush) throw new HttpError(503, "service_unavailable", "Maintenance notifications are temporarily unavailable.");
        const actorUserId = await loadAuthenticatedMaintenanceUser(request);
        const result = pushSubscriptionResponseSchema.parse(await dependencies.maintenancePush.disableSubscription({
          actorUserId,
          endpoint: body.data.endpoint,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : maintenancePushError(error));
      }
    },
  );
  app.get(
    "/api/v1/supervisor/push/public-key",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const context = await loadActiveUser(request);
        if (!hasSupervisorBrowserPushAccess(context)) throw new HttpError(403, "forbidden", "Access is denied.");
        const publicKey = dependencies.maintenancePush?.getPublicKey() ?? null;
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ enabled: publicKey !== null, public_key: publicKey });
      } catch (error) {
        next(error instanceof HttpError ? error : browserPushError(error));
      }
    },
  );
  app.post(
    "/api/v1/supervisor/push/subscriptions",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const body = pushSubscriptionBodySchema.safeParse(request.body);
        if (!body.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        if (!dependencies.maintenancePush) throw new HttpError(503, "service_unavailable", "Notifications are temporarily unavailable.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (!hasSupervisorBrowserPushAccess(context)) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = pushSubscriptionResponseSchema.parse(await dependencies.maintenancePush.registerSupervisorSubscription({
          actorUserId: auth.userId,
          endpoint: body.data.endpoint,
          p256dh: body.data.keys.p256dh,
          auth: body.data.keys.auth,
          userAgent: request.header("User-Agent") ?? null,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : browserPushError(error));
      }
    },
  );
  app.delete(
    "/api/v1/supervisor/push/subscriptions",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const body = pushSubscriptionDeleteBodySchema.safeParse(request.body);
        if (!body.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        if (!dependencies.maintenancePush) throw new HttpError(503, "service_unavailable", "Notifications are temporarily unavailable.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (!hasSupervisorBrowserPushAccess(context)) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = pushSubscriptionResponseSchema.parse(await dependencies.maintenancePush.disableSubscription({
          actorUserId: auth.userId,
          endpoint: body.data.endpoint,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : browserPushError(error));
      }
    },
  );
  app.post(
    "/api/v1/internal/supervisor-notifications/push/run",
    protectedRateLimit,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success || !emptyQuerySchema.safeParse(request.body ?? {}).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        if (!config.supervisorNotificationSchedulerSecret) throw new HttpError(503, "service_unavailable", "Notification scheduler is not configured.");
        if (!schedulerSecretIsValid(request, config.supervisorNotificationSchedulerSecret)) throw new HttpError(401, "unauthorized", "Access is denied.");
        if (!dependencies.maintenancePush) throw new HttpError(503, "service_unavailable", "Notifications are temporarily unavailable.");
        const result = supervisorPushRunResponseSchema.parse(await dependencies.maintenancePush.notifyDueSupervisorChecklistReminders({
          asOf: dependencies.now?.() ?? new Date(),
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : browserPushError(error));
      }
    },
  );
  app.get(
    "/api/v1/maintenance/issues",
    protectedRateLimit,
    async (request, response, next) => {
      try {
        if (!emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        if (!dependencies.operationalAdmin) throw new HttpError(503, "service_unavailable", "Maintenance issues are temporarily unavailable.");
        const actor = await loadMaintenanceIssueActor(request);
        const result = maintenanceIssueListResponseSchema.parse(await dependencies.operationalAdmin.listMaintenanceIssues(actor));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalMaintenanceIssueError(error));
      }
    },
  );
  app.patch(
    "/api/v1/maintenance/issues/:issueId",
    protectedRateLimit,
    maintenanceIssuePhotoRawBody,
    async (request, response, next) => {
      try {
        const issueId = z.uuid().safeParse(request.params.issueId);
        let rawPayload: unknown = request.body;
        let repairPhoto: { bytes: Buffer; mimeType: z.infer<typeof maintenanceIssuePhotoMime>; originalName: string } | null = null;
        if (Buffer.isBuffer(request.body)) {
          if (request.header("Content-Type")?.split(";")[0]?.trim().toLowerCase() !== "application/vnd.maintenance-issue+json") {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          let decoded: unknown;
          try {
            decoded = JSON.parse(request.body.toString("utf8"));
          } catch {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          const envelope = maintenanceIssueUpdateEnvelopeSchema.safeParse(decoded);
          if (!envelope.success) throw new HttpError(400, "bad_request", "The request is invalid.");
          rawPayload = envelope.data.issue;
          if (envelope.data.repair_photo) {
            repairPhoto = {
              bytes: Buffer.from(envelope.data.repair_photo.content_base64, "base64"),
              mimeType: envelope.data.repair_photo.mime_type,
              originalName: envelope.data.repair_photo.original_name?.trim() || "after-repair-photo",
            };
          }
        }
        const body = maintenanceIssueUpdateBodySchema.safeParse(rawPayload);
        if (!issueId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        if (body.data.status === "resolved" && !repairPhoto) {
          throw new HttpError(422, "unprocessable_entity", "Photo required to resolve this issue.");
        }
        if (!dependencies.operationalAdmin) throw new HttpError(503, "service_unavailable", "Maintenance issues are temporarily unavailable.");
        const actor = await loadMaintenanceIssueActor(request);
        const result = maintenanceIssueMutationResponseSchema.parse(await dependencies.operationalAdmin.updateMaintenanceIssue({
          actorUserId: actor.actorUserId,
          accessUserId: actor.accessUserId,
          issueId: issueId.data,
          status: body.data.status,
          note: body.data.note,
          repairPhoto,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalMaintenanceIssueError(error));
      }
    },
  );
  app.post(
    "/api/v1/checklists/daily-audit/verify",
    protectedRateLimit, authenticate, pinVerificationRateLimit, async (request, response, next) => {
      try {
        const body = pinVerifySchema.safeParse(request.body);
        if (!body.success) throw new HttpError(400, "bad_request", "Unable to verify Daily Audit access.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) throw new HttpError(403, "forbidden", "Unable to verify Daily Audit access.");
        const pinAdmin = dependencies.dailyAuditPinAdmin;
        const issueGrant = dependencies.pinCrypto.issueGrant;
        const issueManagerGrant = dependencies.pinCrypto.issueManagerGrant;
        if (!pinAdmin || !issueGrant || !issueManagerGrant) throw new HttpError(503, "service_unavailable", "Unable to verify Daily Audit access.");
        if (pinAdmin.listAccessUserCredentials) {
          let manualCredentials: DailyAuditAccessUserCredential[] = [];
          try {
            manualCredentials = await pinAdmin.listAccessUserCredentials(auth.userId, body.data.branch_id);
          } catch {
            throw new HttpError(403, "forbidden", "Unable to verify Daily Audit access.");
          }
          for (const credential of manualCredentials) {
            if (await dependencies.pinCrypto.verify(body.data.pin, credential)) {
              const grant = dependencies.pinCrypto.issueManualDailyAuditGrant
                ? dependencies.pinCrypto.issueManualDailyAuditGrant({actorUserId:auth.userId,organizationId:credential.organization_id,originalBranchId:body.data.branch_id,auditorId:credential.access_user_id,auditorDisplayName:credential.display_name,credentialVersion:credential.credential_version})
                : issueGrant(auth.userId, body.data.branch_id, credential.credential_version);
              response.setHeader("Cache-Control", "private, no-store");
              response.setHeader("Set-Cookie", serializeDailyAuditGrantCookie(grant, config.nodeEnv, 300));
              response.status(200).json({ verified: true, expires_in: 300 });
              return;
            }
          }
        }
        let credentials: ManagerPinCredential[] = [];
        try {
          credentials = await pinAdmin.listCredentials(auth.userId, body.data.branch_id);
        } catch {
          throw new HttpError(403, "forbidden", "Unable to verify Daily Audit access.");
        }
        let matched = null;
        for (const credential of credentials) {
          if (await dependencies.pinCrypto.verify(body.data.pin, credential)) {
            matched = credential;
            break;
          }
        }
        if (!matched) {
          throw new HttpError(403, "forbidden", "Unable to verify Daily Audit access.");
        }
        await pinAdmin.recordGrant({ actorUserId: auth.userId, branchId: body.data.branch_id,
          managerUserId: matched.manager_user_id, credentialVersion: matched.credential_version });
        const grant = dependencies.pinCrypto.issueOrganizationManagerDailyAuditGrant
          ? dependencies.pinCrypto.issueOrganizationManagerDailyAuditGrant({
              actorUserId: auth.userId,
              organizationId: matched.organization_id,
              originalBranchId: body.data.branch_id,
              auditorId: matched.manager_user_id,
              auditorDisplayName: matched.display_name,
              credentialVersion: matched.credential_version,
            })
          : issueManagerGrant(auth.userId, body.data.branch_id, matched.organization_id,
              matched.manager_user_id, matched.credential_version);
        response.setHeader("Cache-Control", "private, no-store");
        response.setHeader("Set-Cookie", serializeDailyAuditGrantCookie(grant, config.nodeEnv, 300));
        response.status(200).json({ verified: true, expires_in: 300 });
      } catch (error) {
        response.setHeader("Set-Cookie", serializeDailyAuditGrantCookie("", config.nodeEnv, 0));
        next(error instanceof HttpError ? error : new HttpError(503, "service_unavailable", "Unable to verify Daily Audit access."));
      }
    },
  );

  app.get(
    "/api/v1/me",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        response.status(200).json(await loadActiveUser(request));
      } catch (error) {
        next(error);
      }
    },
  );

  app.post(
    "/api/v1/account/change-password",
    passwordChangeRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const body = passwordChangeBodySchema.safeParse(request.body);
        if (!body.success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }

        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (!context.must_change_password) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }

        let verified = false;
        try {
          verified = await dependencies.passwordChange.verifyCurrent(
            auth.email,
            body.data.current_password,
          );
        } catch {
          throw new HttpError(
            503,
            "service_unavailable",
            "The service is unavailable.",
          );
        }
        if (!verified) {
          throw new HttpError(
            400,
            "bad_request",
            "Unable to change the password. Check the current password and try again.",
          );
        }

        try {
          await dependencies.passwordChange.updatePassword(
            auth.userId,
            body.data.new_password,
          );
        } catch {
          throw new HttpError(
            503,
            "service_unavailable",
            "The service is unavailable.",
          );
        }

        try {
          await dependencies.passwordChange.finalize(auth.userId);
        } catch {
          if (config.nodeEnv !== "test") {
            console.error("Password change finalization failed", {
              requestId: request.id,
              userId: auth.userId,
              stage: "database_finalization",
            });
            request.safeFailureLogged = true;
          }
          throw new HttpError(
            503,
            "service_unavailable",
            "The password change could not be completed. Retry using your latest password.",
          );
        }

        response.status(200).json({ success: true });
      } catch (error) {
        next(error);
      }
    },
  );

  app.get(
    "/api/v1/management/organizations/:organizationId/branding",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        if (!dependencies.brandingService) throw new HttpError(503, "service_unavailable", "Branding storage is temporarily unavailable.");
        const branding = await dependencies.brandingService.getManagementOrganizationBranding(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.setHeader("X-Content-Type-Options", "nosniff");
        response.status(200).json({ branding });
      } catch (error) {
        next(error instanceof HttpError ? error : brandingError(error));
      }
    },
  );

  app.get(
    "/api/v1/management/organizations/:organizationId/branches",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) throw new HttpError(403, "forbidden", "Access is denied.");
        const allowed = await auth.userContext.hasOrganizationManagerAccess(auth.userId, organizationId.data);
        if (!allowed) throw new HttpError(403, "forbidden", "Access is denied.");
        const branches = await auth.userContext.listActiveBranches(organizationId.data);
        if (config.nodeEnv !== "test") console.info("Managed active branches returned", {
          requestId: request.id, stage: "express_response", category: "success", status: 200,
          organizationId: organizationId.data, branchCount: branches.length,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ branches });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "The service is unavailable."));
      }
    },
  );

  app.post(
    "/api/v1/management/organizations/:organizationId/branches",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const body = createBranchBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.managementAdmin.createBranch) throw new HttpError(403, "forbidden", "Access is denied.");
        const allowed = await auth.userContext.hasOrganizationManagerAccess(auth.userId, organizationId.data);
        if (!allowed) throw new HttpError(403, "forbidden", "Access is denied.");
        const branch = await dependencies.managementAdmin.createBranch({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          name: body.data.name,
          nameAr: body.data.name_ar,
          code: body.data.code,
          city: body.data.city,
          area: body.data.area,
          address: body.data.address,
          timezone: body.data.timezone,
          active: body.data.active,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json({ branch });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof AdminConflictError) next(new HttpError(409, "conflict", "A branch with this name already exists."));
        else if (error instanceof AdminInputError) next(new HttpError(422, "unprocessable_entity", "Enter valid branch details."));
        else if (error instanceof AdminAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "The service is unavailable."));
      }
    },
  );

  app.get(
    "/api/v1/management/organizations/:organizationId/users",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const query = userListQuerySchema.safeParse(request.query);
        if (!organizationId.success || !query.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) throw new HttpError(403, "forbidden", "Access is denied.");
        const allowed = await auth.userContext.hasOrganizationManagerAccess(auth.userId, organizationId.data);
        if (!allowed) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.managementAdmin.listUsers({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          page: query.data.page,
          pageSize: query.data.page_size,
          search: query.data.search || undefined,
          role: query.data.role,
          branchId: query.data.branch_id,
          lifecycle: query.data.lifecycle,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({
          users: result.users,
          pagination: { page: query.data.page, page_size: query.data.page_size, total: result.total },
        });
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else next(new HttpError(503, "service_unavailable", "The service is unavailable."));
      }
    },
  );

  app.post(
    "/api/v1/management/organizations/:organizationId/users",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(
          request.params.organizationId,
        );
        const body = baseProvisioningBodySchema.safeParse(request.body);
        if (!organizationId.success || !body.success) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        await loadActiveUser(request);
        throw new HttpError(403, "forbidden", "Access is denied.");
      } catch (error) {
        next(error);
      }
    },
  );

  app.get(
    "/api/v1/management/organizations/:organizationId/access",
    protectedRateLimit,
    authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(
          request.params.organizationId,
        );
        if (!organizationId.success) {
          throw new HttpError(
            400,
            "bad_request",
            "The request is invalid.",
          );
        }

        const auth = requireAuthContext(request);
        await loadActiveUser(request);

        let allowed = false;
        try {
          allowed = await auth.userContext.hasOrganizationManagerAccess(
            auth.userId,
            organizationId.data,
          );
        } catch {
          throw new HttpError(
            503,
            "service_unavailable",
            "The service is unavailable.",
          );
        }

        if (!allowed) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }

        response.status(200).json({
          organization_id: organizationId.data,
          role: "organization_manager",
          allowed: true,
        });
      } catch (error) {
        next(error);
      }
    },
  );

  app.get("/api/v1/supervisor/branches/:branchId/team", authenticate, supervisorTeamBootstrapRateLimit,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const query = emptyQuerySchema.safeParse(request.query);
        if (!branchId.success || !query.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password) throw new HttpError(403, "forbidden", "Access is denied.");
        if (!dependencies.operationalAdmin) throw new HttpError(503, "service_unavailable", "Branch Team is unavailable.");
        void query;
        const timezone = await dependencies.operationalAdmin.getBranchTimezone(auth.userId, branchId.data);
        const date = branchLocalDate(timezone, dependencies.now?.() ?? new Date());
        const result = await dependencies.operationalAdmin.getSupervisorTeam(auth.userId, branchId.data, date);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        if (error instanceof HttpError) next(error);
        else if (error instanceof OperationalAccessError) next(new HttpError(403, "forbidden", "Access is denied."));
        else next(new HttpError(503, "service_unavailable", "Branch Team is unavailable."));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/operational-teams", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = createSupervisorOwnedTeamBodySchema.safeParse(request.body);
        if (!branchId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin?.createSupervisorOwnedOperationalTeam) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        const result = supervisorOwnedTeamResponseSchema.parse(await dependencies.operationalAdmin.createSupervisorOwnedOperationalTeam({
          actorUserId: auth.userId,
          branchId: branchId.data,
          name: body.data.name,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "Employee Team already exists.")
          : error instanceof OperationalInputError
          ? new HttpError(422, "bad_request", "Enter a valid Employee Team name.")
          : error instanceof OperationalAccessError
          ? new HttpError(403, "forbidden", "Access is denied.")
          : new HttpError(503, "service_unavailable", "Unable to create Employee Team right now."));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/operational-staff", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = createOperationalStaffBodySchema.safeParse(request.body);
        if (!branchId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.operationalAdmin.createStaff({
          actorUserId: auth.userId, branchId: branchId.data, operationalTeamId: body.data.operational_team_id,
          displayName: body.data.display_name,
          companyName: body.data.company_name,
          staffCode: body.data.staff_code,
          countryCode: body.data.country_code,
          iqamaNumber: body.data.iqama_number,
          iqamaExpiryDate: body.data.iqama_expiry_date,
          phoneNumber: body.data.phone_number,
          email: body.data.email,
          roles: [body.data.primary_role, ...(body.data.secondary_role ? [body.data.secondary_role] : [])],
        });
        response.status(201).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalDuplicateStaffCodeError
          ? new HttpError(409, "duplicate_employee_code", "Employee code already exists for this organization.")
          : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "The requested change conflicts with current team data.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/operational-staff/import-preview", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = createOperationalStaffImportPreviewBodySchema.safeParse(request.body);
        if (!branchId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin?.createStaffImportPreview) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.operationalAdmin.createStaffImportPreview({
          actorUserId: auth.userId,
          branchId: branchId.data,
          operationalTeamId: body.data.operational_team_id,
          rows: body.data.rows,
        });
        response.status(201).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalDuplicateStaffCodeError
          ? new HttpError(409, "duplicate_employee_code", "Employee code already exists for this organization.")
          : error instanceof OperationalInputError
          ? new HttpError(400, "bad_request", "The request is invalid.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/operational-staff/import-confirm", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = confirmOperationalStaffImportBodySchema.safeParse(request.body);
        if (!branchId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin?.confirmStaffImport) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.confirmStaffImport({
          actorUserId: auth.userId,
          branchId: branchId.data,
          operationalTeamId: body.data.operational_team_id,
          previewToken: body.data.preview_token,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalDuplicateStaffCodeError
          ? new HttpError(409, "duplicate_employee_code", "Employee code already exists for this organization.")
          : error instanceof OperationalInputError
          ? new HttpError(400, "bad_request", "The request is invalid.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.patch("/api/v1/supervisor/branches/:branchId/operational-staff/:staffId", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = updateOperationalStaffBodySchema.safeParse(request.body);
        if (!branchId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.operationalAdmin.updateStaff({
          actorUserId: auth.userId, branchId: branchId.data, staffId: staffId.data,
          displayName: body.data.display_name, companyName: body.data.company_name, staffCode: body.data.staff_code,
          countryCode: body.data.country_code,
          iqamaNumber: body.data.iqama_number,
          iqamaExpiryDate: body.data.iqama_expiry_date,
          phoneNumber: body.data.phone_number,
          email: body.data.email,
          employmentStatus: body.data.employment_status,
          roles: [body.data.primary_role, ...(body.data.secondary_role ? [body.data.secondary_role] : [])],
        });
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalDuplicateStaffCodeError
          ? new HttpError(409, "duplicate_employee_code", "Employee code already exists for this organization.")
          : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "The requested change conflicts with current team data.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.put("/api/v1/supervisor/branches/:branchId/operational-staff/:staffId/duty-status", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = dutyStatusBodySchema.safeParse(request.body);
        if (!branchId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const timezone = await dependencies.operationalAdmin.getBranchTimezone(auth.userId, branchId.data);
        const date = branchLocalDate(timezone, dependencies.now?.() ?? new Date());
        response.status(200).json(await dependencies.operationalAdmin.setDuty({
          actorUserId: auth.userId, branchId: branchId.data, staffId: staffId.data,
          date, status: body.data.duty_status,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.put("/api/v1/supervisor/branches/:branchId/operational-staff/:staffId/team", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = moveOperationalStaffBodySchema.safeParse(request.body);
        if (!branchId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin?.moveStaff) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.moveStaff({
          actorUserId: auth.userId,
          branchId: branchId.data,
          staffId: staffId.data,
          expectedAssignmentId: body.data.expected_assignment_id,
          operationalTeamId: body.data.operational_team_id,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "The requested change conflicts with current team data.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.get("/api/v1/supervisor/branches/:branchId/operational-staff/:staffId/transfer-destinations", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const query = transferDestinationsQuerySchema.safeParse(request.query);
        if (!branchId.success || !staffId.success || !query.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        const sourceBranch = context.branches.find((branch) => branch.id === branchId.data);
        if (context.must_change_password || !sourceBranch || !dependencies.operationalAdmin?.listStaffTransferDestinations) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.listStaffTransferDestinations({
          actorUserId: auth.userId,
          sourceBranchId: branchId.data,
          staffId: staffId.data,
          expectedAssignmentId: query.data.expected_assignment_id,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalInputError
          ? new HttpError(400, "bad_request", "The request is invalid.")
          : error instanceof OperationalAccessError
            ? new HttpError(403, "forbidden", "Access is denied.")
            : new HttpError(503, "service_unavailable", "Transfer destinations are temporarily unavailable."));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/operational-staff/:staffId/branch-transfer", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = branchTransferBodySchema.safeParse(request.body);
        if (!branchId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        const sourceBranch = context.branches.find((branch) => branch.id === branchId.data);
        if (context.must_change_password || !sourceBranch || !dependencies.operationalAdmin?.transferStaffBranch) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.transferStaffBranch({
          actorUserId: auth.userId,
          organizationId: sourceBranch.organization_id,
          sourceBranchId: branchId.data,
          staffId: staffId.data,
          expectedAssignmentId: body.data.expected_assignment_id,
          destinationBranchId: body.data.destination_branch_id,
          destinationTeamId: body.data.destination_team_id,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalHygieneSubmittedError
          ? new HttpError(409, "destination_hygiene_submitted", "Destination team hygiene is already submitted for today.")
          : error instanceof OperationalConflictError
            ? new HttpError(409, "conflict", "Employee assignment changed; refresh and try again.")
            : error instanceof OperationalAccessError
              ? new HttpError(403, "forbidden", "Access is denied.")
              : error instanceof OperationalInputError
                ? new HttpError(400, "bad_request", "The request is invalid.")
                : new HttpError(503, "service_unavailable", "Unable to transfer this employee."));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/operational-staff/:staffId/leave-company", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = leaveOperationalStaffBodySchema.safeParse(request.body);
        if (!branchId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin?.leaveStaff) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.leaveStaff({
          actorUserId: auth.userId, branchId: branchId.data, staffId: staffId.data,
          expectedAssignmentId: body.data.expected_assignment_id,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "The requested change conflicts with current team data.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.get("/api/v1/supervisor/branches/:branchId/team/health-cards", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const query = emptyQuerySchema.safeParse(request.query);
        if (!branchId.success || !query.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.operationalAdmin.listHealthCards(auth.userId, branchId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.put("/api/v1/supervisor/branches/:branchId/team/health-cards/:staffId", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = healthCardStatusBodySchema.safeParse(request.body);
        if (!branchId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.upsertHealthCard({
          actorUserId: auth.userId,
          branchId: branchId.data,
          staffId: staffId.data,
          certificateNumber: body.data.certificate_number,
          status: body.data.status,
          placeOfIssue: body.data.place_of_issue,
          expiryDate: body.data.expiry_date,
          dateIssue: body.data.date_issue,
          occupation: body.data.occupation,
          company: body.data.company,
          notes: body.data.notes,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.get("/api/v1/supervisor/branches/:branchId/team/monthly-evaluations", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const query = monthlyEvaluationQuerySchema.safeParse(request.query);
        if (!branchId.success || !query.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.operationalAdmin.listMonthlyEvaluations(auth.userId, branchId.data, `${query.data.month}-01`);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.put("/api/v1/supervisor/branches/:branchId/team/monthly-evaluations/:staffId", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = monthlyEvaluationBodySchema.safeParse(request.body);
        if (!branchId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        if (body.data.status === "completed" && body.data.scores.some((score) => score.rating === null)) {
          throw new HttpError(400, "bad_request", "The request is invalid.");
        }
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.saveMonthlyEvaluation({
          actorUserId: auth.userId,
          branchId: branchId.data,
          staffId: staffId.data,
          evaluationMonth: `${body.data.evaluation_month}-01`,
          evaluatorName: body.data.evaluator_name,
          status: body.data.status,
          scores: body.data.scores,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.get("/api/v1/supervisor/branches/:branchId/supplier-receivings", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!branchId.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = supplierReceivingListResponseSchema.parse(await dependencies.operationalAdmin.listSupplierReceivings(auth.userId, branchId.data));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalSupplierReceivingError(error));
      }
    });

  app.get("/api/v1/supervisor/branches/:branchId/suppliers", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!branchId.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = branchSupplierListResponseSchema.parse(await dependencies.operationalAdmin.listBranchSuppliers(auth.userId, branchId.data));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalSupplierReceivingError(error));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/suppliers", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const body = supplierBodySchema.safeParse(request.body);
        if (!branchId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = branchSupplierMutationResponseSchema.parse(await dependencies.operationalAdmin.createBranchSupplier({
          actorUserId: auth.userId,
          branchId: branchId.data,
          supplierNameEn: body.data.supplier_name_en,
          supplierNameAr: body.data.supplier_name_ar,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalSupplierReceivingError(error));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/supplier-receivings", protectedRateLimit, authenticate, supplierReceivingPhotoRawBody,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        let rawPayload: unknown = request.body;
        let photo: { bytes: Buffer; mimeType: z.infer<typeof supplierReceivingPhotoMime>; originalName: string } | null = null;
        if (Buffer.isBuffer(request.body)) {
          const metadataHeader = request.header("X-Supplier-Receiving-Payload");
          const fileName = decodeUploadFilename(request.header("X-Supplier-Receiving-Filename-B64"));
          if (!metadataHeader || !fileName) throw new HttpError(400, "bad_request", "The request is invalid.");
          try {
            rawPayload = JSON.parse(Buffer.from(metadataHeader, "base64url").toString("utf8"));
          } catch {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          const mime = supplierReceivingPhotoMime.safeParse(request.header("Content-Type")?.split(";")[0]?.trim().toLowerCase());
          if (!mime.success) throw new HttpError(400, "bad_request", "The request is invalid.");
          photo = { bytes: request.body, mimeType: mime.data, originalName: fileName };
        }
        const body = supplierReceivingBodySchema.safeParse(rawPayload);
        if (!branchId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = supplierReceivingMutationResponseSchema.parse(await dependencies.operationalAdmin.createSupplierReceiving({
          actorUserId: auth.userId,
          branchId: branchId.data,
          payload: body.data,
          photo,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalSupplierReceivingError(error));
      }
    });

  app.get("/api/v1/supervisor/branches/:branchId/maintenance-issues", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!branchId.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = maintenanceIssueListResponseSchema.parse(await dependencies.operationalAdmin.listSupervisorMaintenanceIssues(auth.userId, branchId.data));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalMaintenanceIssueError(error));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/maintenance-issues", protectedRateLimit, authenticate, maintenanceIssuePhotoRawBody,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        let rawPayload: unknown = request.body;
        let photo: { bytes: Buffer; mimeType: z.infer<typeof maintenanceIssuePhotoMime>; originalName: string } | null = null;
        if (Buffer.isBuffer(request.body)) {
          if (request.header("Content-Type")?.split(";")[0]?.trim().toLowerCase() !== "application/vnd.maintenance-issue+json") {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          let decoded: unknown;
          try {
            decoded = JSON.parse(request.body.toString("utf8"));
          } catch {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          const envelope = maintenanceIssueCreateEnvelopeSchema.safeParse(decoded);
          if (!envelope.success) throw new HttpError(400, "bad_request", "The request is invalid.");
          rawPayload = envelope.data.issue;
          if (envelope.data.before_photo) {
            photo = {
              bytes: Buffer.from(envelope.data.before_photo.content_base64, "base64"),
              mimeType: envelope.data.before_photo.mime_type,
              originalName: envelope.data.before_photo.original_name?.trim() || "reported-photo",
            };
          }
        }
        const body = maintenanceIssueBodySchema.safeParse(rawPayload);
        if (!branchId.success || !body.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = maintenanceIssueMutationResponseSchema.parse(await dependencies.operationalAdmin.createSupervisorMaintenanceIssue({
          actorUserId: auth.userId,
          branchId: branchId.data,
          payload: body.data,
          photo,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json(result);
        void dependencies.maintenancePush?.notifyMaintenanceIssueCreated({
          issueId: result.maintenance_issue.id,
          branchId: result.maintenance_issue.branch_id,
          branchName: result.maintenance_issue.branch_name,
          priority: result.maintenance_issue.priority,
          title: result.maintenance_issue.title,
        }).catch(() => undefined);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalMaintenanceIssueError(error));
      }
    });

  app.get("/api/v1/supervisor/branches/:branchId/purchase-logs", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!branchId.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = purchaseLogListResponseSchema.parse(await dependencies.operationalAdmin.listPurchaseLogs(auth.userId, branchId.data));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalPurchaseError(error));
      }
    });

  app.post("/api/v1/supervisor/branches/:branchId/purchase-logs", protectedRateLimit, authenticate, purchaseInvoiceRawBody,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        let rawPayload: unknown = request.body;
        let invoice: { bytes: Buffer; mimeType: z.infer<typeof purchaseInvoiceMime>; originalName: string } | null = null;
        if (Buffer.isBuffer(request.body)) {
          const metadataHeader = request.header("X-Purchase-Log-Payload");
          const fileName = decodeUploadFilename(request.header("X-Purchase-Log-Filename-B64"));
          if (!metadataHeader || !fileName) throw new HttpError(400, "bad_request", "The request is invalid.");
          try {
            rawPayload = JSON.parse(Buffer.from(metadataHeader, "base64url").toString("utf8"));
          } catch {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          const mime = purchaseInvoiceMime.safeParse(request.header("Content-Type")?.split(";")[0]?.trim().toLowerCase());
          if (!mime.success) throw new HttpError(400, "bad_request", "The request is invalid.");
          invoice = { bytes: request.body, mimeType: mime.data, originalName: fileName };
        }
        const body = purchaseLogBodySchema.safeParse(rawPayload);
        if (!branchId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = purchaseLogMutationResponseSchema.parse(await dependencies.operationalAdmin.createPurchaseLog({
          actorUserId: auth.userId,
          branchId: branchId.data,
          payload: body.data,
          invoice,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalPurchaseError(error));
      }
    });

  app.patch("/api/v1/supervisor/branches/:branchId/purchase-logs/:purchaseLogId/payment-status", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        const purchaseLogId = z.uuid().safeParse(request.params.purchaseLogId);
        const body = purchaseLogPaymentStatusBodySchema.safeParse(request.body);
        if (!branchId.success || !purchaseLogId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || context.managed_organizations.length > 0 || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = purchaseLogMutationResponseSchema.parse(await dependencies.operationalAdmin.updatePurchaseLogPaymentStatus({
          actorUserId: auth.userId,
          branchId: branchId.data,
          purchaseLogId: purchaseLogId.data,
          paymentStatus: body.data.payment_status,
          reimbursementNote: body.data.reimbursement_note,
        }));
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : operationalPurchaseError(error));
      }
    });

  app.get("/api/v1/management/organizations/:organizationId/operational-staff", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const query = operationalStaffListQuerySchema.safeParse(request.query);
        if (!organizationId.success || !query.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.operationalAdmin.listManagedStaff({
          actorUserId: auth.userId, organizationId: organizationId.data, page: query.data.page,
          pageSize: query.data.page_size, search: query.data.search, branchId: query.data.branch_id,
          supervisorUserId: query.data.supervisor_user_id,
          role: query.data.operational_role, employmentStatus: query.data.employment_status, date: query.data.date,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.get("/api/v1/management/organizations/:organizationId/employees", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId=organizationIdSchema.safeParse(request.params.organizationId);
        const query=managedEmployeeTeamQuerySchema.safeParse(request.query);
        if(!organizationId.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
        const auth=requireAuthContext(request);const context=await loadActiveUser(request);
        if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.listManagedEmployeeTeam)throw new HttpError(403,"forbidden","Access is denied.");
        const result=await dependencies.operationalAdmin.listManagedEmployeeTeam({actorUserId:auth.userId,organizationId:organizationId.data,branchId:query.data.branch_id,month:query.data.month});
        response.setHeader("Cache-Control","private, no-store");response.json(result);
      } catch(error) {
        if(error instanceof HttpError)next(error);
        else if(error instanceof OperationalAccessError)next(new HttpError(403,"forbidden","Access is denied."));
        else next(new HttpError(503,"service_unavailable","Employee team data is temporarily unavailable."));
      }
    });

  app.post("/api/v1/management/organizations/:organizationId/operational-staff/:staffId/supervisor-training", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        if (!organizationId.success || !staffId.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !context.managed_organizations.some((item) => item.id === organizationId.data)
          || !dependencies.operationalAdmin?.startManagedOperationalStaffSupervisorTraining) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.startManagedOperationalStaffSupervisorTraining({
          actorUserId: auth.userId, organizationId: organizationId.data, staffId: staffId.data,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "The employee is already in Supervisor Training.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.post("/api/v1/management/organizations/:organizationId/operational-staff/:staffId/supervisor-training/cancel", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        if (!organizationId.success || !staffId.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !context.managed_organizations.some((item) => item.id === organizationId.data)
          || !dependencies.operationalAdmin?.cancelManagedOperationalStaffSupervisorTraining) throw new HttpError(403, "forbidden", "Access is denied.");
        response.status(200).json(await dependencies.operationalAdmin.cancelManagedOperationalStaffSupervisorTraining({
          actorUserId: auth.userId, organizationId: organizationId.data, staffId: staffId.data,
        }));
      } catch (error) {
        next(error instanceof HttpError ? error : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "The requested change conflicts with current employee data.")
          : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.post("/api/v1/management/organizations/:organizationId/operational-staff/:staffId/supervisor-training/promote", protectedRateLimit, authenticate,
    async (request, response, next) => {
      let newUserId: string | null = null;
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const staffId = staffIdSchema.safeParse(request.params.staffId);
        const body = promoteSupervisorTrainingBodySchema.safeParse(request.body);
        if (!organizationId.success || !staffId.success || !body.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !context.managed_organizations.some((item) => item.id === organizationId.data)
          || !dependencies.operationalAdmin?.getManagedOperationalStaffSupervisorTrainingPromotionState
          || !dependencies.operationalAdmin.promoteManagedOperationalStaffSupervisorTraining) {
          throw new HttpError(403, "forbidden", "Access is denied.");
        }
        const state = await dependencies.operationalAdmin.getManagedOperationalStaffSupervisorTrainingPromotionState({
          actorUserId: auth.userId, organizationId: organizationId.data, staffId: staffId.data,
        });
        if (typeof state === "object" && state !== null && "status" in state && state.status === "promoted") {
          response.setHeader("Cache-Control", "private, no-store");
          response.status(200).json(state);
          return;
        }
        try {
          newUserId = (await dependencies.provisioningAdmin.createUser({
            email: body.data.email,
            password: body.data.temporary_password,
          })).id;
        } catch (error) {
          if (error instanceof AdminConflictError) throw new HttpError(409, "conflict", "An account with that email already exists.");
          throw new HttpError(503, "service_unavailable", "Supervisor promotion is temporarily unavailable.");
        }
        const result = await dependencies.operationalAdmin.promoteManagedOperationalStaffSupervisorTraining({
          actorUserId: auth.userId,
          organizationId: organizationId.data,
          staffId: staffId.data,
          newSupervisorUserId: newUserId,
          fullName: body.data.full_name,
          fullNameAr: body.data.full_name_ar,
        });
        response.setHeader("Cache-Control", "private, no-store");
        response.status(201).json(result);
      } catch (error) {
        if (newUserId) {
          try {
            await dependencies.provisioningAdmin.deleteUser(newUserId);
          } catch {
            if (config.nodeEnv !== "test") {
              console.error("Supervisor promotion compensation failed", { requestId: request.id });
            }
          }
        }
        next(error instanceof HttpError ? error : error instanceof OperationalConflictError
          ? new HttpError(409, "conflict", "Supervisor promotion conflicts with current employee or team data.")
          : error instanceof OperationalAccessError
            ? new HttpError(403, "forbidden", "Access is denied.")
            : error instanceof OperationalInputError
              ? new HttpError(400, "bad_request", "The request is invalid.")
              : new HttpError(503, "service_unavailable", "Supervisor promotion is temporarily unavailable."));
      }
    });

  app.get("/api/v1/management/organizations/:organizationId/annual-evaluations",protectedRateLimit,authenticate,
    async(request,response,next)=>{try{
      const organizationId=organizationIdSchema.safeParse(request.params.organizationId),query=managedAnnualEvaluationQuerySchema.safeParse(request.query);
      if(!organizationId.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
      const auth=requireAuthContext(request),context=await loadActiveUser(request);
      if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.getManagedAnnualEvaluationWorkspace)throw new HttpError(403,"forbidden","Access is denied.");
      const result=annualEvaluationWorkspaceSchema.parse(await dependencies.operationalAdmin.getManagedAnnualEvaluationWorkspace({actorUserId:auth.userId,organizationId:organizationId.data,evaluationYear:query.data.evaluation_year,branchId:query.data.branch_id,subjectType:query.data.subject_type,subjectId:query.data.subject_id,state:query.data.state}));
      response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
    }catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Annual Evaluations are temporarily unavailable."));}});

  app.get("/api/v1/management/organizations/:organizationId/annual-evaluations/:evaluationId",protectedRateLimit,authenticate,
    async(request,response,next)=>{try{
      const organizationId=organizationIdSchema.safeParse(request.params.organizationId),evaluationId=z.uuid().safeParse(request.params.evaluationId);
      if(!organizationId.success||!evaluationId.success)throw new HttpError(400,"bad_request","The request is invalid.");
      const auth=requireAuthContext(request),context=await loadActiveUser(request);
      if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.getManagedAnnualEvaluationDetail)throw new HttpError(403,"forbidden","Access is denied.");
      const result=annualEvaluationDetailSchema.parse(await dependencies.operationalAdmin.getManagedAnnualEvaluationDetail({actorUserId:auth.userId,organizationId:organizationId.data,evaluationId:evaluationId.data}));
      response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
    }catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Annual Evaluation detail is temporarily unavailable."));}});

  app.put("/api/v1/management/organizations/:organizationId/annual-evaluations/draft",protectedRateLimit,authenticate,
    async(request,response,next)=>{try{
      const organizationId=organizationIdSchema.safeParse(request.params.organizationId),body=managedAnnualEvaluationDraftSchema.safeParse(request.body);
      if(!organizationId.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
      const auth=requireAuthContext(request),context=await loadActiveUser(request);
      if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.saveManagedAnnualEvaluationDraft)throw new HttpError(403,"forbidden","Access is denied.");
      const result=annualEvaluationDetailSchema.parse(await dependencies.operationalAdmin.saveManagedAnnualEvaluationDraft({actorUserId:auth.userId,organizationId:organizationId.data,branchId:body.data.branch_id,evaluationYear:body.data.evaluation_year,subjectType:body.data.subject_type,subjectId:body.data.subject_id,expectedRevision:body.data.expected_revision,scores:body.data.scores}));
      response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
    }catch(error){next(error instanceof HttpError?error:error instanceof OperationalConflictError?new HttpError(409,"conflict","This evaluation changed. Refresh and try again."):error instanceof OperationalInputError?new HttpError(422,"bad_request","Check the evaluation scores."):error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Unable to save this Annual Evaluation."));}});

  app.post("/api/v1/management/organizations/:organizationId/annual-evaluations/:evaluationId/submit",protectedRateLimit,authenticate,
    async(request,response,next)=>{try{
      const organizationId=organizationIdSchema.safeParse(request.params.organizationId),evaluationId=z.uuid().safeParse(request.params.evaluationId),body=managedAnnualEvaluationSubmitSchema.safeParse(request.body);
      if(!organizationId.success||!evaluationId.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
      const auth=requireAuthContext(request),context=await loadActiveUser(request);
      if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.submitManagedAnnualEvaluation)throw new HttpError(403,"forbidden","Access is denied.");
      const result=annualEvaluationDetailSchema.parse(await dependencies.operationalAdmin.submitManagedAnnualEvaluation({actorUserId:auth.userId,organizationId:organizationId.data,evaluationId:evaluationId.data,expectedRevision:body.data.expected_revision}));
      response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
    }catch(error){next(error instanceof HttpError?error:error instanceof OperationalConflictError?new HttpError(409,"conflict","This evaluation changed or is incomplete."):error instanceof OperationalInputError?new HttpError(422,"bad_request","Rate all 20 criteria before submitting."):error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Unable to submit this Annual Evaluation."));}});

  app.get("/api/v1/management/organizations/:organizationId/purchase-logs", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId=organizationIdSchema.safeParse(request.params.organizationId),query=managedPurchaseLogQuerySchema.safeParse(request.query);
        if(!organizationId.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
        const auth=requireAuthContext(request),context=await loadActiveUser(request);
        if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.listManagedPurchaseLogs)throw new HttpError(403,"forbidden","Access is denied.");
        const result=managedPurchaseLogListResponseSchema.parse(await dependencies.operationalAdmin.listManagedPurchaseLogs({actorUserId:auth.userId,organizationId:organizationId.data,branchId:query.data.branch_id,category:query.data.category,paymentStatus:query.data.payment_status,dateFrom:query.data.date_from,dateTo:query.data.date_to}));
        response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
      } catch(error) { next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Purchase Logs are temporarily unavailable.")); }
    });

  app.get("/api/v1/management/organizations/:organizationId/supplier-receivings", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId=organizationIdSchema.safeParse(request.params.organizationId),query=managedSupplierReceivingQuerySchema.safeParse(request.query);
        if(!organizationId.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
        const auth=requireAuthContext(request),context=await loadActiveUser(request);
        if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.listManagedSupplierReceivings)throw new HttpError(403,"forbidden","Access is denied.");
        const result=managedSupplierReceivingListResponseSchema.parse(await dependencies.operationalAdmin.listManagedSupplierReceivings({actorUserId:auth.userId,organizationId:organizationId.data,branchId:query.data.branch_id,category:query.data.category,supplierId:query.data.supplier_id,dateFrom:query.data.date_from,dateTo:query.data.date_to}));
        response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
      } catch(error) { next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Supplier Receiving is temporarily unavailable.")); }
    });

  app.get("/api/v1/management/organizations/:organizationId/maintenance-issues", protectedRateLimit, authenticate,
    async(request,response,next)=>{
      try{
        const organizationId=organizationIdSchema.safeParse(request.params.organizationId),query=managedMaintenanceIssueQuerySchema.safeParse(request.query);
        if(!organizationId.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
        const auth=requireAuthContext(request),context=await loadActiveUser(request);
        if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.listManagedMaintenanceIssues)throw new HttpError(403,"forbidden","Access is denied.");
        const result=managedMaintenanceIssueListResponseSchema.parse(await dependencies.operationalAdmin.listManagedMaintenanceIssues({actorUserId:auth.userId,organizationId:organizationId.data,branchId:query.data.branch_id,status:query.data.status,priority:query.data.priority,category:query.data.category,dateFrom:query.data.date_from,dateTo:query.data.date_to}));
        response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
      }catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Maintenance Issues are temporarily unavailable."));}
    });

  app.post("/api/v1/management/organizations/:organizationId/maintenance-issues", protectedRateLimit, authenticate, maintenanceIssuePhotoRawBody,
    async(request,response,next)=>{
      try{
        const organizationId=organizationIdSchema.safeParse(request.params.organizationId);
        let rawPayload: unknown = request.body;
        let photo: { bytes: Buffer; mimeType: z.infer<typeof maintenanceIssuePhotoMime>; originalName: string } | null = null;
        if (Buffer.isBuffer(request.body)) {
          if (request.header("Content-Type")?.split(";")[0]?.trim().toLowerCase() !== "application/vnd.maintenance-issue+json") {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          let decoded: unknown;
          try {
            decoded = JSON.parse(request.body.toString("utf8"));
          } catch {
            throw new HttpError(400, "bad_request", "The request is invalid.");
          }
          const envelope = maintenanceIssueCreateEnvelopeSchema.safeParse(decoded);
          if (!envelope.success) throw new HttpError(400, "bad_request", "The request is invalid.");
          rawPayload = envelope.data.issue;
          if (envelope.data.before_photo) {
            photo = {
              bytes: Buffer.from(envelope.data.before_photo.content_base64, "base64"),
              mimeType: envelope.data.before_photo.mime_type,
              originalName: envelope.data.before_photo.original_name?.trim() || "reported-photo",
            };
          }
        }
        const body=maintenanceIssueBodySchema.safeParse(rawPayload);
        if(!organizationId.success||!body.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
        const auth=requireAuthContext(request),context=await loadActiveUser(request);
        if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data)||!dependencies.operationalAdmin?.createManagerOfficeMaintenanceIssue)throw new HttpError(403,"forbidden","Access is denied.");
        const result=maintenanceIssueMutationResponseSchema.parse(await dependencies.operationalAdmin.createManagerOfficeMaintenanceIssue({actorUserId:auth.userId,organizationId:organizationId.data,payload:body.data,photo}));
        response.setHeader("Cache-Control","private, no-store");response.status(201).json(result);
        void dependencies.maintenancePush?.notifyMaintenanceIssueCreated({
          issueId: result.maintenance_issue.id,
          branchId: result.maintenance_issue.branch_id,
          branchName: result.maintenance_issue.branch_name,
          priority: result.maintenance_issue.priority,
          title: result.maintenance_issue.title,
        }).catch(()=>undefined);
      }catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Maintenance Issues are temporarily unavailable."));}
    });

  app.get("/api/v1/management/organizations/:organizationId/maintenance-purchases", protectedRateLimit, authenticate,
    async(request,response,next)=>{try{const organizationId=organizationIdSchema.safeParse(request.params.organizationId),query=managedMaintenancePurchaseQuerySchema.safeParse(request.query);if(!organizationId.success||!query.success||!dependencies.operationalAdmin?.listManagedMaintenancePurchases)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!context.managed_organizations.some(item=>item.id===organizationId.data))throw new HttpError(403,"forbidden","Access is denied.");const result=managedMaintenancePurchaseListSchema.parse(await dependencies.operationalAdmin.listManagedMaintenancePurchases({actorUserId:auth.userId,organizationId:organizationId.data,branchId:query.data.branch_id,issueStatus:query.data.issue_status,paymentStatus:query.data.payment_status,vendor:query.data.vendor,dateFrom:query.data.date_from,dateTo:query.data.date_to,purchaseType:query.data.purchase_type}));response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);}catch(error){next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):new HttpError(503,"service_unavailable","Maintenance Purchases are temporarily unavailable."));}});

  app.get("/api/v1/management/organizations/:organizationId/supervisor-teams", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        if (!organizationId.success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request);
        const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        const result = await dependencies.operationalAdmin.listManagedTeams(auth.userId, organizationId.data);
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(result);
      } catch (error) {
        next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied."));
      }
    });

  app.get("/api/v1/management/organizations/:organizationId/branches/:branchId/eligible-supervisors", protectedRateLimit, authenticate,
    async (request, response, next) => {
      try {
        const organizationId = organizationIdSchema.safeParse(request.params.organizationId);
        const branchId = branchIdSchema.safeParse(request.params.branchId);
        if (!organizationId.success || !branchId.success || !emptyQuerySchema.safeParse(request.query).success) throw new HttpError(400, "bad_request", "The request is invalid.");
        const auth = requireAuthContext(request); const context = await loadActiveUser(request);
        if (context.must_change_password || !dependencies.operationalAdmin) throw new HttpError(403, "forbidden", "Access is denied.");
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json(await dependencies.operationalAdmin.listEligibleSupervisors(auth.userId, organizationId.data, branchId.data));
      } catch (error) { next(error instanceof HttpError ? error : new HttpError(403, "forbidden", "Access is denied.")); }
    });

  app.post("/api/v1/supervisor/branches/:branchId/checklists/:checklistType/items/:itemId/evidence",
    authenticate,evidenceUploadRateLimit,evidenceConcurrency,evidenceLengthGuard,evidenceRawBody,async(request,response,next)=>{try{
      const branch=branchIdSchema.safeParse(request.params.branchId),type=openingTypeSchema.safeParse(request.params.checklistType),item=z.string().min(1).max(80).safeParse(request.params.itemId);
      const mime=request.header("content-type");
      if(!branch.success||!type.success||!item.success||!mime||!Buffer.isBuffer(request.body)||request.body.length!==Number(request.header("content-length")))throw new HttpError(400,"bad_request","The evidence photo is invalid.");
      const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.evidenceService)throw new HttpError(403,"forbidden","Access is denied.");
      const evidence=await dependencies.evidenceService.upload({actorUserId:auth.userId,branchId:branch.data,checklistType:type.data,itemId:item.data,bytes:request.body,declaredMime:mime,requestId:request.id});
      response.setHeader("Cache-Control","private, no-store");response.setHeader("X-Content-Type-Options","nosniff");response.status(201).json({evidence});
    }catch(error){next(error instanceof HttpError?error:evidenceError(error));}});

  app.delete("/api/v1/evidence/:evidenceId",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const id=z.uuid().safeParse(request.params.evidenceId);if(!id.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.evidenceService)throw new HttpError(403,"forbidden","Access is denied.");
    await dependencies.evidenceService.retire(auth.userId,id.data,request.id);response.setHeader("Cache-Control","private, no-store");response.status(204).end();
  }catch(error){next(error instanceof HttpError?error:evidenceError(error));}});

  app.get("/api/v1/evidence/:evidenceId/read-url",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const id=z.uuid().safeParse(request.params.evidenceId);if(!id.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.evidenceService)throw new HttpError(403,"forbidden","Access is denied.");
    const result=await dependencies.evidenceService.createReadUrl(auth.userId,id.data);response.setHeader("Cache-Control","private, no-store");response.setHeader("X-Content-Type-Options","nosniff");response.status(200).json(result);
  }catch(error){next(error instanceof HttpError?error:evidenceError(error));}});

	  app.get("/api/v1/supervisor/notifications",protectedRateLimit,authenticate,async(request,response,next)=>{try{
	    if(!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
	    const auth=requireAuthContext(request),context=await loadActiveUser(request);
	    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.listSupervisorNotifications)throw new HttpError(403,"forbidden","Access is denied.");
	    const notifications=supervisorNotificationListSchema.parse(await dependencies.checklistPersistence.listSupervisorNotifications(auth.userId));
	    const unreadCount=notifications.filter((item)=>item.read_at===null&&item.resolved_at===null).length;
	    const result=supervisorNotificationResponseSchema.parse({notifications,unread_count:unreadCount});
	    response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
	  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

	  app.patch("/api/v1/supervisor/notifications/:notificationId/read",protectedRateLimit,authenticate,async(request,response,next)=>{try{
	    const id=z.uuid().safeParse(request.params.notificationId);
	    if(!id.success||!emptyQuerySchema.safeParse(request.query).success||!emptyQuerySchema.safeParse(request.body??{}).success)throw new HttpError(400,"bad_request","The request is invalid.");
	    const auth=requireAuthContext(request),context=await loadActiveUser(request);
	    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.markSupervisorNotificationRead)throw new HttpError(403,"forbidden","Access is denied.");
	    const rows=supervisorNotificationListSchema.max(1).parse(await dependencies.checklistPersistence.markSupervisorNotificationRead(auth.userId,id.data));
	    const notification=rows[0];
	    if(!notification)throw new HttpError(404,"not_found","Notification not found.");
	    response.setHeader("Cache-Control","private, no-store");response.status(200).json({notification});
	  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

	  app.get("/api/v1/supervisor/branches/:branchId/daily-audit/current-state",protectedRateLimit,authenticate,async(request,response,next)=>{try{const branch=branchIdSchema.safeParse(request.params.branchId),query=z.object({business_date:dateOnlySchema}).strict().safeParse(request.query);if(!branch.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request),op=dependencies.operationalAdmin;if(context.must_change_password||context.managed_organizations.length>0||!op?.getSupervisorDailyAuditCurrentState||!op.resolveDailyAuditGrantBranchScope||!op.resolveDailyAuditManualAccessUser)throw new HttpError(403,"forbidden","Access is denied.");const identity=await validateDailyAuditGrant({cookies:request.headers.cookie,actorUserId:auth.userId,targetBranchId:branch.data,pinCrypto:dependencies.pinCrypto,getBranchScope:(targetBranchId)=>op.resolveDailyAuditGrantBranchScope!(auth.userId,targetBranchId),getCredentialScope:async(organizationId,accessUserId)=>{const row=await op.resolveDailyAuditManualAccessUser!(auth.userId,branch.data,accessUserId);return row&&row.organization_id===organizationId?{active:row.active,credential_version:row.credential_version,display_name:row.display_name}:null;},getOrganizationManagerCredentialScope:async(_organizationId,managerUserId,credentialVersion,targetBranchId)=>{const active=await dependencies.dailyAuditPinAdmin?.validateGrant({actorUserId:auth.userId,branchId:targetBranchId,managerUserId,credentialVersion});return active?{active:true,credential_version:credentialVersion,display_name:"Organization Manager"}:null;}});if(!identity)throw new HttpError(403,"forbidden","Daily Audit access is required.");response.setHeader("Cache-Control","private, no-store");response.status(200).json(dailyAuditResponseSchema.parse(await op.getSupervisorDailyAuditCurrentState({actorUserId:auth.userId,branchId:branch.data,businessDate:query.data.business_date})));}catch(error){next(error instanceof HttpError?error:operationalMaintenanceIssueError(error));}});
  app.put("/api/v1/supervisor/branches/:branchId/daily-audit/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{const branch=branchIdSchema.safeParse(request.params.branchId),body=dailyAuditBodySchema.safeParse(request.body);if(!branch.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request),op=dependencies.operationalAdmin;if(context.must_change_password||context.managed_organizations.length>0||!op?.saveSupervisorDailyAuditDraft||!op.resolveDailyAuditGrantBranchScope||!op.resolveDailyAuditManualAccessUser)throw new HttpError(403,"forbidden","Access is denied.");const identity=await validateDailyAuditGrant({cookies:request.headers.cookie,actorUserId:auth.userId,targetBranchId:branch.data,pinCrypto:dependencies.pinCrypto,getBranchScope:(targetBranchId)=>op.resolveDailyAuditGrantBranchScope!(auth.userId,targetBranchId),getCredentialScope:async(organizationId,accessUserId)=>{const row=await op.resolveDailyAuditManualAccessUser!(auth.userId,branch.data,accessUserId);return row&&row.organization_id===organizationId?{active:row.active,credential_version:row.credential_version,display_name:row.display_name}:null;},getOrganizationManagerCredentialScope:async(_organizationId,managerUserId,credentialVersion,targetBranchId)=>{const active=await dependencies.dailyAuditPinAdmin?.validateGrant({actorUserId:auth.userId,branchId:targetBranchId,managerUserId,credentialVersion});return active?{active:true,credential_version:credentialVersion,display_name:"Organization Manager"}:null;}});if(!identity)throw new HttpError(403,"forbidden","Daily Audit access is required.");const result=await op.saveSupervisorDailyAuditDraft({actorUserId:auth.userId,branchId:branch.data,businessDate:body.data.business_date,expectedRevision:body.data.expected_revision,auditorKind:identity.auditor_kind,auditorId:identity.auditor_id,auditorDisplayName:identity.auditor_display_name,accessCredentialVersion:identity.access_credential_version,items:body.data.items});response.status(200).json(dailyAuditResponseSchema.parse(result));}catch(error){next(error instanceof HttpError?error:dailyAuditPersistenceError(error));}});
  app.post("/api/v1/supervisor/branches/:branchId/daily-audit/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{const branch=branchIdSchema.safeParse(request.params.branchId),body=dailyAuditBodySchema.safeParse(request.body);if(!branch.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request),op=dependencies.operationalAdmin;if(context.must_change_password||context.managed_organizations.length>0||!op?.submitSupervisorDailyAudit||!op.resolveDailyAuditGrantBranchScope||!op.resolveDailyAuditManualAccessUser)throw new HttpError(403,"forbidden","Access is denied.");const identity=await validateDailyAuditGrant({cookies:request.headers.cookie,actorUserId:auth.userId,targetBranchId:branch.data,pinCrypto:dependencies.pinCrypto,getBranchScope:(targetBranchId)=>op.resolveDailyAuditGrantBranchScope!(auth.userId,targetBranchId),getCredentialScope:async(organizationId,accessUserId)=>{const row=await op.resolveDailyAuditManualAccessUser!(auth.userId,branch.data,accessUserId);return row&&row.organization_id===organizationId?{active:row.active,credential_version:row.credential_version,display_name:row.display_name}:null;},getOrganizationManagerCredentialScope:async(_organizationId,managerUserId,credentialVersion,targetBranchId)=>{const active=await dependencies.dailyAuditPinAdmin?.validateGrant({actorUserId:auth.userId,branchId:targetBranchId,managerUserId,credentialVersion});return active?{active:true,credential_version:credentialVersion,display_name:"Organization Manager"}:null;}});if(!identity)throw new HttpError(403,"forbidden","Daily Audit access is required.");const result=await op.submitSupervisorDailyAudit({actorUserId:auth.userId,branchId:branch.data,businessDate:body.data.business_date,expectedRevision:body.data.expected_revision,auditorKind:identity.auditor_kind,auditorId:identity.auditor_id,auditorDisplayName:identity.auditor_display_name,accessCredentialVersion:identity.access_credential_version,items:body.data.items,idempotencyKey:request.header("Idempotency-Key")});response.status(201).json(dailyAuditResponseSchema.parse(result));}catch(error){next(error instanceof HttpError?error:dailyAuditPersistenceError(error));}});
  app.get("/api/v1/supervisor/branches/:branchId/checklists/oil_tracking/current-state",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId);
    if(!branch.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.getOilTrackingCurrentState)throw new HttpError(403,"forbidden","Access is denied.");
    const current=oilCurrentSchema.parse(await dependencies.checklistPersistence.getOilTrackingCurrentState(auth.userId,branch.data));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.put("/api/v1/supervisor/branches/:branchId/checklists/oil_tracking/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),body=oilTrackingBodySchema.safeParse(request.body);
    if(!branch.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.saveOilTrackingDraft)throw new HttpError(403,"forbidden","Access is denied.");
    const current=oilCurrentSchema.parse(await dependencies.checklistPersistence.saveOilTrackingDraft({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,rows:body.data.rows}));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.post("/api/v1/supervisor/branches/:branchId/checklists/oil_tracking/opening/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),key=idempotencySchema.safeParse(request.header("Idempotency-Key")),body=oilTrackingBodySchema.safeParse(request.body);
    if(!branch.success||!key.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.submitOilTrackingOpening)throw new HttpError(403,"forbidden","Access is denied.");
    const current=oilCurrentSchema.parse(await dependencies.checklistPersistence.submitOilTrackingOpening({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,idempotencyKey:key.data,rows:body.data.rows}));
    response.setHeader("Cache-Control","private, no-store");response.status(201).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.post("/api/v1/supervisor/branches/:branchId/checklists/oil_tracking/closing/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),key=idempotencySchema.safeParse(request.header("Idempotency-Key")),body=oilTrackingBodySchema.safeParse(request.body);
    if(!branch.success||!key.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.submitOilTrackingClosing)throw new HttpError(403,"forbidden","Access is denied.");
    const current=oilCurrentSchema.parse(await dependencies.checklistPersistence.submitOilTrackingClosing({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,idempotencyKey:key.data,rows:body.data.rows}));
    response.setHeader("Cache-Control","private, no-store");response.status(201).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/cold-storage/equipment",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId);
    if(!branch.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request),operational=dependencies.operationalAdmin;
    if(context.must_change_password||context.managed_organizations.length>0||!context.branches.some(item=>item.id===branch.data&&item.role==="branch_manager"))throw new HttpError(403,"forbidden","Access is denied.");
    if(!operational?.listSupervisorColdStorageEquipment)throw new HttpError(503,"service_unavailable","Cold Storage equipment is temporarily unavailable.");
    const result=coldStorageEquipmentMasterListSchema.parse(await operational.listSupervisorColdStorageEquipment(auth.userId,branch.data));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
  }catch(error){next(error instanceof HttpError?error:operationalColdStorageEquipmentError(error));}});

  app.post("/api/v1/supervisor/branches/:branchId/cold-storage/equipment",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),body=coldStorageEquipmentMasterBodySchema.safeParse(request.body);
    if(!branch.success||!body.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request),operational=dependencies.operationalAdmin;
    if(context.must_change_password||context.managed_organizations.length>0||!context.branches.some(item=>item.id===branch.data&&item.role==="branch_manager"))throw new HttpError(403,"forbidden","Access is denied.");
    if(!operational?.createSupervisorColdStorageEquipment)throw new HttpError(503,"service_unavailable","Cold Storage equipment is temporarily unavailable.");
    const result=coldStorageEquipmentMasterMutationSchema.parse(await operational.createSupervisorColdStorageEquipment({actorUserId:auth.userId,branchId:branch.data,equipmentCode:body.data.equipment_code,name:body.data.name,equipmentType:body.data.equipment_type}));
    response.setHeader("Cache-Control","private, no-store");response.status(201).json(result);
  }catch(error){next(error instanceof HttpError?error:operationalColdStorageEquipmentError(error));}});

  app.patch("/api/v1/supervisor/branches/:branchId/cold-storage/equipment/:equipmentId",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),equipment=z.uuid().safeParse(request.params.equipmentId),body=coldStorageEquipmentMasterUpdateBodySchema.safeParse(request.body);
    if(!branch.success||!equipment.success||!body.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request),operational=dependencies.operationalAdmin;
    if(context.must_change_password||context.managed_organizations.length>0||!context.branches.some(item=>item.id===branch.data&&item.role==="branch_manager"))throw new HttpError(403,"forbidden","Access is denied.");
    if(!operational?.updateSupervisorColdStorageEquipment)throw new HttpError(503,"service_unavailable","Cold Storage equipment is temporarily unavailable.");
    const result=coldStorageEquipmentMasterMutationSchema.parse(await operational.updateSupervisorColdStorageEquipment({actorUserId:auth.userId,branchId:branch.data,equipmentId:equipment.data,equipmentCode:body.data.equipment_code,name:body.data.name,equipmentType:body.data.equipment_type}));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
  }catch(error){next(error instanceof HttpError?error:operationalColdStorageEquipmentError(error));}});

  app.delete("/api/v1/supervisor/branches/:branchId/cold-storage/equipment/:equipmentId",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),equipment=z.uuid().safeParse(request.params.equipmentId);
    if(!branch.success||!equipment.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request),operational=dependencies.operationalAdmin;
    if(context.must_change_password||context.managed_organizations.length>0||!context.branches.some(item=>item.id===branch.data&&item.role==="branch_manager"))throw new HttpError(403,"forbidden","Access is denied.");
    if(!operational?.archiveSupervisorColdStorageEquipment)throw new HttpError(503,"service_unavailable","Cold Storage equipment is temporarily unavailable.");
    const result=coldStorageEquipmentMasterMutationSchema.parse(await operational.archiveSupervisorColdStorageEquipment({actorUserId:auth.userId,branchId:branch.data,equipmentId:equipment.data}));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json(result);
  }catch(error){next(error instanceof HttpError?error:operationalColdStorageEquipmentError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/checklists/cold_storage/current-state",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId);
    if(!branch.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.getColdStorageCurrentState)throw new HttpError(403,"forbidden","Access is denied.");
    const current=coldStorageCurrentSchema.parse(await dependencies.checklistPersistence.getColdStorageCurrentState(auth.userId,branch.data));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.put("/api/v1/supervisor/branches/:branchId/checklists/cold_storage/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),body=coldStorageBodySchema.safeParse(request.body);
    if(!branch.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.saveColdStorageDraft)throw new HttpError(403,"forbidden","Access is denied.");
    const current=coldStorageCurrentSchema.parse(await dependencies.checklistPersistence.saveColdStorageDraft({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,equipment:body.data.equipment,readings:body.data.readings}));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/checklists/sales_tracking/current-state",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId);
    if(!branch.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.getSalesTrackingCurrentState)throw new HttpError(403,"forbidden","Access is denied.");
    const current=salesTrackingCurrentSchema.parse(await dependencies.checklistPersistence.getSalesTrackingCurrentState(auth.userId,branch.data));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/checklists/sales_tracking/online-order-providers",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId);
    if(!branch.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.listSalesTrackingOnlineOrderProviders)throw new HttpError(403,"forbidden","Access is denied.");
    const providers=salesTrackingOnlineProviderListSchema.parse(await dependencies.checklistPersistence.listSalesTrackingOnlineOrderProviders(auth.userId,branch.data));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json(providers);
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.post("/api/v1/supervisor/branches/:branchId/checklists/sales_tracking/online-order-providers",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),body=salesTrackingOnlineProviderBodySchema.safeParse(request.body);
    if(!branch.success||!body.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.createSalesTrackingOnlineOrderProvider)throw new HttpError(403,"forbidden","Access is denied.");
    const provider=salesTrackingOnlineProviderMutationSchema.parse(await dependencies.checklistPersistence.createSalesTrackingOnlineOrderProvider({actorUserId:auth.userId,branchId:branch.data,name:body.data.name}));
    response.setHeader("Cache-Control","private, no-store");response.status(201).json(provider);
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.put("/api/v1/supervisor/branches/:branchId/checklists/sales_tracking/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),body=salesTrackingBodySchema.safeParse(request.body);
    if(!branch.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.saveSalesTrackingDraft)throw new HttpError(403,"forbidden","Access is denied.");
    const current=salesTrackingCurrentSchema.parse(await dependencies.checklistPersistence.saveSalesTrackingDraft({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,entryPeriod:body.data.entry_period,payload:body.data}));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/inventory-items/current-state",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),query=inventoryItemsQuerySchema.safeParse(request.query);
    if(!branch.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.getInventoryItemsCurrentState)throw new HttpError(403,"forbidden","Access is denied.");
    const current=inventoryItemsCurrentSchema.parse(await dependencies.checklistPersistence.getInventoryItemsCurrentState(auth.userId,branch.data,query.data.inventory_month??null));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.put("/api/v1/supervisor/branches/:branchId/inventory-items/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),body=inventoryItemsBodySchema.safeParse(request.body);
    if(!branch.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.saveInventoryItemsDraft)throw new HttpError(403,"forbidden","Access is denied.");
    const current=inventoryItemsCurrentSchema.parse(await dependencies.checklistPersistence.saveInventoryItemsDraft({actorUserId:auth.userId,branchId:branch.data,payload:body.data}));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.post("/api/v1/supervisor/branches/:branchId/inventory-items/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),key=idempotencySchema.safeParse(request.header("Idempotency-Key")),body=inventoryItemsBodySchema.safeParse(request.body);
    if(!branch.success||!key.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.submitInventoryItems)throw new HttpError(403,"forbidden","Access is denied.");
    const current=inventoryItemsCurrentSchema.parse(await dependencies.checklistPersistence.submitInventoryItems({actorUserId:auth.userId,branchId:branch.data,idempotencyKey:key.data,payload:body.data}));
    response.setHeader("Cache-Control","private, no-store");response.status(201).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

	  app.post("/api/v1/supervisor/branches/:branchId/checklists/sales_tracking/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{
	    const branch=branchIdSchema.safeParse(request.params.branchId),key=idempotencySchema.safeParse(request.header("Idempotency-Key")),body=salesTrackingSubmitBodySchema.safeParse(request.body);
	    if(!branch.success||!key.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
	    const auth=requireAuthContext(request),context=await loadActiveUser(request);
	    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.submitSalesTracking)throw new HttpError(403,"forbidden","Access is denied.");
	    const current=salesTrackingCurrentSchema.parse(await dependencies.checklistPersistence.submitSalesTracking({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,idempotencyKey:key.data}));
	    response.setHeader("Cache-Control","private, no-store");response.status(201).json({current});
	  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

	  app.get("/api/v1/supervisor/branches/:branchId/checklists/financial_closing/current-state",protectedRateLimit,authenticate,async(request,response,next)=>{try{
	    const branch=branchIdSchema.safeParse(request.params.branchId);
	    if(!branch.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
	    const auth=requireAuthContext(request),context=await loadActiveUser(request);
	    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.getFinancialClosingCurrentState)throw new HttpError(403,"forbidden","Access is denied.");
	    const current=financialClosingCurrentSchema.parse(await dependencies.checklistPersistence.getFinancialClosingCurrentState(auth.userId,branch.data));
	    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
	  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

	  app.put("/api/v1/supervisor/branches/:branchId/checklists/financial_closing/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{
	    const branch=branchIdSchema.safeParse(request.params.branchId),body=financialClosingBodySchema.safeParse(request.body);
	    if(!branch.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
	    const auth=requireAuthContext(request),context=await loadActiveUser(request);
	    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.saveFinancialClosingDraft)throw new HttpError(403,"forbidden","Access is denied.");
	    const current=financialClosingCurrentSchema.parse(await dependencies.checklistPersistence.saveFinancialClosingDraft({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,items:body.data.items}));
	    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
	  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

	  app.post("/api/v1/supervisor/branches/:branchId/checklists/financial_closing/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{
	    const branch=branchIdSchema.safeParse(request.params.branchId),key=idempotencySchema.safeParse(request.header("Idempotency-Key")),body=financialClosingBodySchema.safeParse(request.body);
	    if(!branch.success||!key.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
	    const auth=requireAuthContext(request),context=await loadActiveUser(request);
	    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.submitFinancialClosing)throw new HttpError(403,"forbidden","Access is denied.");
	    const current=financialClosingCurrentSchema.parse(await dependencies.checklistPersistence.submitFinancialClosing({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,items:body.data.items}));
	    response.setHeader("Cache-Control","private, no-store");response.status(201).json({current});
	  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

	  app.post("/api/v1/supervisor/branches/:branchId/checklists/cold_storage/slots/:slot/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),slot=coldSlotSchema.safeParse(request.params.slot),key=idempotencySchema.safeParse(request.header("Idempotency-Key")),body=coldStorageBodySchema.safeParse(request.body);
    if(!branch.success||!slot.success||!key.success||!body.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence?.submitColdStorageSlot)throw new HttpError(403,"forbidden","Access is denied.");
    const current=coldStorageCurrentSchema.parse(await dependencies.checklistPersistence.submitColdStorageSlot({actorUserId:auth.userId,branchId:branch.data,expectedRevision:body.data.expected_revision,slot:slot.data,idempotencyKey:key.data,equipment:body.data.equipment,readings:body.data.readings}));
    response.setHeader("Cache-Control","private, no-store");response.status(201).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/checklists/staff_hygiene/teams/:teamId/current-state",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),team=z.uuid().safeParse(request.params.teamId);
    if(!branch.success||!team.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||!dependencies.checklistPersistence?.getHygieneCurrentState)throw new HttpError(403,"forbidden","Access is denied.");
    const current=phase4aCurrentSchema.parse(await dependencies.checklistPersistence.getHygieneCurrentState(auth.userId,branch.data,team.data));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/checklists/:checklistType/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),type=checklistTypeSchema.safeParse(request.params.checklistType);
    if(!branch.success||!type.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    const current=phase4aCurrentSchema.parse(await dependencies.checklistPersistence.getCurrentState(auth.userId,branch.data,type.data));response.setHeader("Cache-Control","private, no-store");response.status(200).json({current});
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/overview",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId);if(!branch.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||context.managed_organizations.length>0||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    const overview=phase4aOverviewSchema.parse(await dependencies.checklistPersistence.getOverview(auth.userId,branch.data));
    response.setHeader("Cache-Control","private, no-store");response.status(200).json(overview);
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.put("/api/v1/supervisor/branches/:branchId/checklists/draft",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),opening=openingBodySchema.safeParse(request.body),hygiene=hygieneDraftBodySchema.safeParse(request.body);
    if(!branch.success||(!opening.success&&!hygiene.success))throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    if(opening.success){if(!dependencies.evidenceService)throw new HttpError(503,"service_unavailable","Evidence storage is temporarily unavailable.");await dependencies.evidenceService.verifySet(auth.userId,branch.data,opening.data.checklist_type,opening.data.answers.flatMap(answer=>answer.evidence_id?[answer.evidence_id]:[]));}
    const result=opening.success?await dependencies.checklistPersistence.saveDraft({actorUserId:auth.userId,branchId:branch.data,type:opening.data.checklist_type,expectedRevision:opening.data.expected_revision,answers:opening.data.answers}):await dependencies.checklistPersistence.saveHygieneDraft({actorUserId:auth.userId,branchId:branch.data,operationalTeamId:hygiene.success?hygiene.data.operational_team_id:"",expectedRevision:hygiene.success?hygiene.data.expected_revision:0,staff:hygiene.success?hygiene.data.staff:[]});
    response.status(200).json(phase4aMutationSchema.parse(result));
  }catch(error){next(error instanceof HttpError?error:error instanceof EvidenceAccessError||error instanceof EvidenceInputError||error instanceof EvidenceUnavailableError?evidenceError(error):checklistError(error));}});

  app.post("/api/v1/supervisor/branches/:branchId/checklists/submit",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),key=idempotencySchema.safeParse(request.header("Idempotency-Key"));
    const opening=openingBodySchema.safeParse(request.body),hygiene=hygieneBodySchema.safeParse(request.body);
    if(!branch.success||!key.success||(!opening.success&&!hygiene.success))throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    if(opening.success){if(!dependencies.evidenceService)throw new HttpError(503,"service_unavailable","Evidence storage is temporarily unavailable.");await dependencies.evidenceService.verifySet(auth.userId,branch.data,opening.data.checklist_type,opening.data.answers.flatMap(answer=>answer.evidence_id?[answer.evidence_id]:[]));}
    const result=opening.success
      ? await dependencies.checklistPersistence.submitOpening({actorUserId:auth.userId,branchId:branch.data,type:opening.data.checklist_type,expectedRevision:opening.data.expected_revision,idempotencyKey:key.data,answers:opening.data.answers})
      : await dependencies.checklistPersistence.submitHygiene({actorUserId:auth.userId,branchId:branch.data,operationalTeamId:hygiene.success?hygiene.data.operational_team_id:"",idempotencyKey:key.data,staff:hygiene.success?hygiene.data.staff:[]});
    response.status(201).json(phase4aMutationSchema.parse(result));
  }catch(error){next(error instanceof HttpError?error:error instanceof EvidenceAccessError||error instanceof EvidenceInputError||error instanceof EvidenceUnavailableError?evidenceError(error):checklistError(error));}});

  app.get("/api/v1/supervisor/branches/:branchId/submissions",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const branch=branchIdSchema.safeParse(request.params.branchId),query=pageQuerySchema.safeParse(request.query);if(!branch.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    const list=phase4aListSchema.parse(await dependencies.checklistPersistence.listSupervisor({actorUserId:auth.userId,branchId:branch.data,page:query.data.page,pageSize:query.data.page_size,type:query.data.checklist_type}));
    response.setHeader("Cache-Control","private, no-store");response.json(phase4aListSchema.parse(list));
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});
  app.get("/api/v1/supervisor/submissions/:submissionId",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const id=z.uuid().safeParse(request.params.submissionId);if(!id.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request);if(context.must_change_password||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    let detail:unknown;
    try{detail=await dependencies.checklistPersistence.getReport(auth.userId,id.data,false);}
    catch(error){
      if(!(error instanceof ChecklistAccessError))throw error;
      try{
        if(!dependencies.checklistPersistence.getOilTrackingReport)throw error;
        detail=oilReportDetailWithItems(phase4aDetailSchema.parse(await dependencies.checklistPersistence.getOilTrackingReport(auth.userId,id.data)));
      }catch(oilError){
        if(!(oilError instanceof ChecklistAccessError)||!dependencies.checklistPersistence.getColdStorageReport)throw oilError;
        detail=coldStorageReportDetailWithItems(phase4aDetailSchema.parse(await dependencies.checklistPersistence.getColdStorageReport(auth.userId,id.data)));
      }
    }
    response.setHeader("Cache-Control","private, no-store");response.json(phase4aDetailSchema.parse(detail));
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/management/organizations/:organizationId/overview",protectedRateLimit,authenticate,async(request,response,next)=>{
    try {
      const organization=organizationIdSchema.safeParse(request.params.organizationId);
      if(!organization.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
      const auth=requireAuthContext(request),context=await loadActiveUser(request);
      const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,organization.data);
      if(context.must_change_password||!allowed||!dependencies.checklistPersistence?.getManagementOverview)throw new HttpError(403,"forbidden","Access is denied.");
      const overview=managementOverviewSchema.parse(await dependencies.checklistPersistence.getManagementOverview(auth.userId,organization.data));
      response.setHeader("Cache-Control","private, no-store");
      response.status(200).json(overview);
    } catch(error) {
      const failure=error instanceof HttpError
        ? error
        : error instanceof ChecklistAccessError
          ? new HttpError(403,"forbidden","Access is denied.")
          : new HttpError(503,"service_unavailable","The service is unavailable.");
      if(config.nodeEnv!=="test")console.info("Management overview request completed",{
        requestId:request.id,stage:"management_overview",
        category:failure.status===400?"invalid_request":failure.status===403?"access_denied":error instanceof ManagementOverviewUnavailableError?"dependency_unavailable":"invalid_response",
        status:failure.status,
      });
      next(failure);
    }
  });

  app.get("/api/v1/management/organizations/:organizationId/operations-summary",protectedRateLimit,authenticate,async(request,response,next)=>{
    try {
      const organization=organizationIdSchema.safeParse(request.params.organizationId);
      const query=operationsSummaryQuerySchema.safeParse(request.query);
      if(!organization.success||!query.success)throw new HttpError(400,"bad_request","The request is invalid.");
      const auth=requireAuthContext(request),context=await loadActiveUser(request);
      const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,organization.data);
      if(context.must_change_password||!allowed)throw new HttpError(403,"forbidden","Access is denied.");
      if(query.data.branch_id&&!(await auth.userContext.validateActiveBranches(organization.data,[query.data.branch_id])))throw new HttpError(403,"forbidden","Access is denied.");
      if(!dependencies.operationalAdmin?.getManagedOperationsSummary)throw new HttpError(503,"service_unavailable","The service is unavailable.");
      const month=query.data.month??managerInventoryCurrentMonth().slice(0,7);
      const summary=managementOperationsSummarySchema.parse(await dependencies.operationalAdmin.getManagedOperationsSummary({actorUserId:auth.userId,organizationId:organization.data,branchId:query.data.branch_id,month}));
      if(summary.scope.organization_id!==organization.data||summary.scope.branch_id!==(query.data.branch_id??null)||summary.scope.month!==month)throw new Error("operations summary scope mismatch");
      response.setHeader("Cache-Control","private, no-store");
      response.status(200).json(summary);
    }catch(error){
      next(error instanceof HttpError?error:error instanceof OperationalAccessError?new HttpError(403,"forbidden","Access is denied."):error instanceof OperationalInputError?new HttpError(400,"bad_request","The request is invalid."):new HttpError(503,"service_unavailable","The service is unavailable."));
    }
  });

  app.get("/api/v1/management/organizations/:organizationId/sales-tracking",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const org=organizationIdSchema.safeParse(request.params.organizationId),q=managerSalesTrackingQuerySchema.safeParse(request.query);
    if(!org.success||!q.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,org.data);
    if(context.must_change_password||!allowed)throw new HttpError(403,"forbidden","Access is denied.");
    if(q.data.branch_id&&!(await auth.userContext.validateActiveBranches(org.data,[q.data.branch_id])))throw new HttpError(403,"forbidden","Access is denied.");
    if(!dependencies.checklistPersistence?.listManagedSalesTrackingReports)throw new HttpError(503,"service_unavailable","The service is unavailable.");
    const reports=managedSalesTrackingSchema.parse(await dependencies.checklistPersistence.listManagedSalesTrackingReports({actorUserId:auth.userId,organizationId:org.data,dateFrom:q.data.date_from??null,dateTo:q.data.date_to??null,branchId:q.data.branch_id??null}));
    response.setHeader("Cache-Control","private, no-store");
    response.status(200).json(reports);
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/management/organizations/:organizationId/sales-tracking/monthly-summary",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const org=organizationIdSchema.safeParse(request.params.organizationId),q=managerSalesTrackingMonthlyQuerySchema.safeParse(request.query);
    if(!org.success||!q.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,org.data);
    if(context.must_change_password||!allowed)throw new HttpError(403,"forbidden","Access is denied.");
    if(!dependencies.checklistPersistence?.getManagedSalesTrackingMonthlySummary)throw new HttpError(503,"service_unavailable","The service is unavailable.");
    const summary=managementSalesTrackingMonthlySummarySchema.parse(await dependencies.checklistPersistence.getManagedSalesTrackingMonthlySummary({actorUserId:auth.userId,organizationId:org.data,month:q.data.month,branchId:q.data.branch_id??null}));
    if(summary.scope.organization_id!==org.data||summary.scope.branch_id!==(q.data.branch_id??null)||summary.scope.month!==q.data.month)throw new Error("sales tracking monthly summary scope mismatch");
    response.setHeader("Cache-Control","private, no-store");
    response.status(200).json(summary);
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/management/organizations/:organizationId/inventory-items",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const org=organizationIdSchema.safeParse(request.params.organizationId),q=managerInventoryItemsQuerySchema.safeParse(request.query);
    if(!org.success||!q.success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,org.data);
    if(context.must_change_password||!allowed)throw new HttpError(403,"forbidden","Access is denied.");
    if(q.data.branch_id&&!(await auth.userContext.validateActiveBranches(org.data,[q.data.branch_id])))throw new HttpError(403,"forbidden","Access is denied.");
    if(!dependencies.checklistPersistence?.listManagedInventoryItemsReports)throw new HttpError(503,"service_unavailable","The service is unavailable.");
    const reports=managedInventoryItemsSchema.parse(await dependencies.checklistPersistence.listManagedInventoryItemsReports({actorUserId:auth.userId,organizationId:org.data,inventoryMonth:q.data.month??managerInventoryCurrentMonth(),branchId:q.data.branch_id??null}));
    response.setHeader("Cache-Control","private, no-store");
    response.status(200).json(reports);
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.get("/api/v1/management/organizations/:organizationId/reports",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const org=organizationIdSchema.safeParse(request.params.organizationId),q=managerReportQuerySchema.safeParse(request.query);if(!org.success||!q.success)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request);const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,org.data);if(context.must_change_password||!allowed||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    const reportArgs={actor_user_id:auth.userId,target_organization_id:org.data,requested_page:q.data.page,requested_page_size:q.data.page_size,date_from:q.data.date_from??null,date_to:q.data.date_to??null,branch_filter:q.data.branch_id??null,supervisor_filter:q.data.supervisor_user_id??null,status_filter:q.data.status??null,search_term:q.data.search??null};
    let list:SupervisorReportList;
	    if(q.data.checklist_type==="oil_tracking"){
	      if(!dependencies.checklistPersistence.listManagedOilTrackingReports)throw new HttpError(503,"service_unavailable","The service is unavailable.");
	      list=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedOilTrackingReports(reportArgs));
	    }else if(q.data.checklist_type==="cold_storage"){
	      if(!dependencies.checklistPersistence.listManagedColdStorageReports)throw new HttpError(503,"service_unavailable","The service is unavailable.");
	      list=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedColdStorageReports(reportArgs));
	    }else if(q.data.checklist_type==="daily_audit"){
	      if(!dependencies.checklistPersistence.listManagedDailyAuditReports)throw new HttpError(503,"service_unavailable","The service is unavailable.");
	      list=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedDailyAuditReports(reportArgs));
	    }else if(q.data.checklist_type==="financial_closing"){
	      if(!dependencies.checklistPersistence.listManagedFinancialClosingReports)throw new HttpError(503,"service_unavailable","The service is unavailable.");
	      list=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedFinancialClosingReports(reportArgs));
	    }else if(q.data.checklist_type){
	      list=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedReports({...reportArgs,type_filter:q.data.checklist_type}));
	    }else{
	      const fetchSize=Math.min(50,q.data.page*q.data.page_size);
	      const mergedArgs={...reportArgs,requested_page:1,requested_page_size:fetchSize};
	      const base=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedReports({...mergedArgs,type_filter:null}));
	      let oil=emptySupervisorReportList(1,fetchSize),cold=emptySupervisorReportList(1,fetchSize),dailyAudit=emptySupervisorReportList(1,fetchSize),financialClosing=emptySupervisorReportList(1,fetchSize);
      if(dependencies.checklistPersistence.listManagedOilTrackingReports){
        try{oil=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedOilTrackingReports(mergedArgs));}
        catch(error){if(error instanceof ChecklistAccessError)throw error;}
      }
      if(dependencies.checklistPersistence.listManagedColdStorageReports){
        try{cold=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedColdStorageReports(mergedArgs));}
        catch(error){if(error instanceof ChecklistAccessError)throw error;}
      }
	      if(dependencies.checklistPersistence.listManagedDailyAuditReports){
	        try{dailyAudit=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedDailyAuditReports(mergedArgs));}
	        catch(error){throw error;}
	      }
	      if(dependencies.checklistPersistence.listManagedFinancialClosingReports){
	        try{financialClosing=phase4aListSchema.parse(await dependencies.checklistPersistence.listManagedFinancialClosingReports(mergedArgs));}
	        catch(error){if(error instanceof ChecklistAccessError)throw error;}
	      }
	      list=mergeSupervisorReportLists(q.data.page,q.data.page_size,base,oil,cold,dailyAudit,financialClosing);
	    }
    response.setHeader("Cache-Control","private, no-store");response.json(phase4aListSchema.parse(list));
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});
  app.get("/api/v1/management/organizations/:organizationId/reports/:submissionId",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const org=organizationIdSchema.safeParse(request.params.organizationId),id=z.uuid().safeParse(request.params.submissionId);
    if(!org.success||!id.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");
    const auth=requireAuthContext(request),context=await loadActiveUser(request);
    if(context.must_change_password||!context.managed_organizations.some(x=>x.id===org.data)||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    let detail:unknown;
    try{
      const baseDetail=phase4aDetailSchema.parse(await dependencies.checklistPersistence.getReport(auth.userId,id.data,true));
      if(baseDetail.checklist_type==="daily_audit"){
        if(!dependencies.checklistPersistence.getManagedDailyAuditReport)throw new HttpError(503,"service_unavailable","The service is unavailable.");
        detail=await dependencies.checklistPersistence.getManagedDailyAuditReport(auth.userId,org.data,id.data);
      }else detail=baseDetail;
    }
    catch(baseError){
      if(!(baseError instanceof ChecklistAccessError))throw baseError;
      try{
        if(!dependencies.checklistPersistence.getManagedOilTrackingReport)throw baseError;
        detail=oilReportDetailWithItems(phase4aDetailSchema.parse(await dependencies.checklistPersistence.getManagedOilTrackingReport(auth.userId,org.data,id.data)));
      }catch(oilError){
        if(!(oilError instanceof ChecklistAccessError))throw oilError;
        try{
	        if(!dependencies.checklistPersistence.getManagedColdStorageReport)throw oilError;
	        detail=coldStorageReportDetailWithItems(phase4aDetailSchema.parse(await dependencies.checklistPersistence.getManagedColdStorageReport(auth.userId,org.data,id.data)));
	      }catch(coldError){
	          if(!(coldError instanceof ChecklistAccessError))throw coldError;
	          try{
	            if(!dependencies.checklistPersistence.getManagedDailyAuditReport)throw coldError;
	            detail=await dependencies.checklistPersistence.getManagedDailyAuditReport(auth.userId,org.data,id.data);
	          }catch(dailyAuditError){
	            if(!(dailyAuditError instanceof ChecklistAccessError)||!dependencies.checklistPersistence.getManagedFinancialClosingReport)throw dailyAuditError;
	            detail=await dependencies.checklistPersistence.getManagedFinancialClosingReport(auth.userId,org.data,id.data);
	          }
	        }
	      }
	    }
    response.setHeader("Cache-Control","private, no-store");response.json(phase4aDetailSchema.parse(detail));
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});
  app.get("/api/v1/management/organizations/:organizationId/issues",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const org=organizationIdSchema.safeParse(request.params.organizationId),q=managerIssueQuerySchema.safeParse(request.query);if(!org.success||!q.success)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request);const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,org.data);if(context.must_change_password||!allowed||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    const issueArgs={actor_user_id:auth.userId,target_organization_id:org.data,requested_page:q.data.page,requested_page_size:q.data.page_size,date_from:q.data.date_from??null,date_to:q.data.date_to??null,branch_filter:q.data.branch_id??null,supervisor_filter:q.data.supervisor_user_id??null,staff_filter:q.data.staff_id??null,status_filter:q.data.status??null,search_term:q.data.search??null};
    let list:ManagementIssueList;
    if(q.data.checklist_type==="oil_tracking"){
      if(!dependencies.checklistPersistence.listManagedOilTrackingIssues)throw new HttpError(503,"service_unavailable","The service is unavailable.");
      list=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedOilTrackingIssues({...issueArgs,type_filter:"oil_tracking"}));
    }else if(q.data.checklist_type==="cold_storage"){
      if(!dependencies.checklistPersistence.listManagedColdStorageIssues)throw new HttpError(503,"service_unavailable","The service is unavailable.");
      list=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedColdStorageIssues({...issueArgs,type_filter:"cold_storage"}));
    }else if(q.data.checklist_type==="sales_tracking"){
      if(!dependencies.checklistPersistence.listManagedSalesTrackingIssues)throw new HttpError(503,"service_unavailable","The service is unavailable.");
      list=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedSalesTrackingIssues({...issueArgs,type_filter:"sales_tracking"}));
    }else if(q.data.checklist_type){
      list=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedIssues({...issueArgs,type_filter:q.data.checklist_type}));
    }else{
      const fetchSize=Math.min(50,q.data.page*q.data.page_size);
      const mergedArgs={...issueArgs,requested_page:1,requested_page_size:fetchSize};
      const base=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedIssues({...mergedArgs,type_filter:null}));
      let oil=emptyManagementIssueList(1,fetchSize),cold=emptyManagementIssueList(1,fetchSize),sales=emptyManagementIssueList(1,fetchSize);
      if(dependencies.checklistPersistence.listManagedOilTrackingIssues){
        try{oil=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedOilTrackingIssues({...mergedArgs,type_filter:"oil_tracking"}));}
        catch(error){if(error instanceof ChecklistAccessError)throw error;}
      }
      if(dependencies.checklistPersistence.listManagedColdStorageIssues){
        try{cold=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedColdStorageIssues({...mergedArgs,type_filter:"cold_storage"}));}
        catch(error){if(error instanceof ChecklistAccessError)throw error;}
      }
      if(dependencies.checklistPersistence.listManagedSalesTrackingIssues){
        try{sales=phase4aIssueListSchema.parse(await dependencies.checklistPersistence.listManagedSalesTrackingIssues({...mergedArgs,type_filter:"sales_tracking"}));}
        catch(error){if(error instanceof ChecklistAccessError)throw error;}
      }
      list=mergeManagementIssueLists(q.data.page,q.data.page_size,base,oil,cold,sales);
    }
    response.setHeader("Cache-Control","private, no-store");response.json(phase4aIssueListSchema.parse(list));
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});
  app.get("/api/v1/management/organizations/:organizationId/issues/:issueId",protectedRateLimit,authenticate,async(request,response,next)=>{try{
    const org=organizationIdSchema.safeParse(request.params.organizationId),id=uuidLikeSchema.safeParse(request.params.issueId);if(!org.success||!id.success||!emptyQuerySchema.safeParse(request.query).success)throw new HttpError(400,"bad_request","The request is invalid.");const auth=requireAuthContext(request),context=await loadActiveUser(request);const allowed=await auth.userContext.hasOrganizationManagerAccess(auth.userId,org.data);if(context.must_change_password||!allowed||!dependencies.checklistPersistence)throw new HttpError(403,"forbidden","Access is denied.");
    let detail:unknown;
    try{detail=await dependencies.checklistPersistence.getManagedIssue(auth.userId,org.data,id.data);}
    catch(error){
      if(!(error instanceof ChecklistAccessError))throw error;
      try{
        if(!dependencies.checklistPersistence.getManagedOilTrackingIssue)throw error;
        detail=await dependencies.checklistPersistence.getManagedOilTrackingIssue(auth.userId,org.data,id.data);
      }catch(oilError){
        if(!(oilError instanceof ChecklistAccessError))throw oilError;
        try{
          if(!dependencies.checklistPersistence.getManagedColdStorageIssue)throw oilError;
          detail=await dependencies.checklistPersistence.getManagedColdStorageIssue(auth.userId,org.data,id.data);
        }catch(coldError){
          if(!(coldError instanceof ChecklistAccessError)||!dependencies.checklistPersistence.getManagedSalesTrackingIssue)throw coldError;
          detail=await dependencies.checklistPersistence.getManagedSalesTrackingIssue(auth.userId,org.data,id.data);
        }
      }
    }
    response.setHeader("Cache-Control","private, no-store");response.json(phase4aIssueDetailSchema.parse(issueDetailWithSourceMetadata(detail)));
  }catch(error){next(error instanceof HttpError?error:checklistError(error));}});

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
