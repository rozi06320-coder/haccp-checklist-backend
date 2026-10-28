import { z } from "zod";
import { managementSalesTrackingPeriodSummarySchema } from "./management-sales-tracking-period";

export const dailyBusinessReportModuleKeySchema = z.enum([
  "kitchen_opening",
  "foh_opening",
  "staff_hygiene",
  "daily_audit",
  "cold_storage",
  "oil_tracking",
  "sales_tracking",
]);
export type DailyBusinessReportModuleKey = z.infer<typeof dailyBusinessReportModuleKeySchema>;

export const dailyBusinessReportModuleStatusSchema = z.enum([
  "submitted",
  "missing",
  "issues_detected",
  "not_applicable",
  "unavailable",
]);
export type DailyBusinessReportModuleStatus = z.infer<typeof dailyBusinessReportModuleStatusSchema>;

export const dailyBusinessReportRequirementBasisSchema = z.enum([
  "static",
  "eligible_operational_staff",
  "eligible_cold_storage_equipment",
  "eligible_oil_tracking_fryers",
]);
export type DailyBusinessReportRequirementBasis = z.infer<typeof dailyBusinessReportRequirementBasisSchema>;

export const dailyBusinessReportModuleItemSchema = z.object({
  status: dailyBusinessReportModuleStatusSchema,
  required: z.boolean(),
  requirement_basis: z.string().min(1).max(80),
  expected_count: z.number().int().nonnegative(),
  submitted_count: z.number().int().nonnegative(),
  missing_count: z.number().int().nonnegative(),
  issue_count: z.number().int().nonnegative(),
  source_report_ids: z.array(z.uuid()),
  detail_path: z.string().nullable(),
}).strict();
export type DailyBusinessReportModuleItem = z.infer<typeof dailyBusinessReportModuleItemSchema>;

export const dailyBusinessReportSalesTrackingModuleItemSchema = dailyBusinessReportModuleItemSchema.extend({
  cash_monitoring_source_report_id: z.uuid().nullable(),
}).strict();
export type DailyBusinessReportSalesTrackingModuleItem = z.infer<typeof dailyBusinessReportSalesTrackingModuleItemSchema>;

export const dailyBusinessReportBranchModulesSchema = z.object({
  kitchen_opening: dailyBusinessReportModuleItemSchema,
  foh_opening: dailyBusinessReportModuleItemSchema,
  staff_hygiene: dailyBusinessReportModuleItemSchema,
  daily_audit: dailyBusinessReportModuleItemSchema,
  cold_storage: dailyBusinessReportModuleItemSchema,
  oil_tracking: dailyBusinessReportModuleItemSchema,
  sales_tracking: dailyBusinessReportSalesTrackingModuleItemSchema,
}).strict();
export type DailyBusinessReportBranchModules = z.infer<typeof dailyBusinessReportBranchModulesSchema>;

export const dailyBusinessReportBranchSchema = z.object({
  branch_id: z.uuid(),
  modules: dailyBusinessReportBranchModulesSchema,
}).strict();
export type DailyBusinessReportBranch = z.infer<typeof dailyBusinessReportBranchSchema>;

export const dailyBusinessReportSummarySchema = z.object({
  required_count: z.number().int().nonnegative(),
  submitted_count: z.number().int().nonnegative(),
  missing_count: z.number().int().nonnegative(),
  issue_count: z.number().int().nonnegative(),
  not_applicable_count: z.number().int().nonnegative(),
  unavailable_count: z.number().int().nonnegative(),
}).strict();
export type DailyBusinessReportSummary = z.infer<typeof dailyBusinessReportSummarySchema>;

export const dailyBusinessReportPayloadSchema = z.object({
  organization_id: z.uuid(),
  business_date: z.iso.date(),
  summary: dailyBusinessReportSummarySchema,
  branches: z.array(dailyBusinessReportBranchSchema),
}).strict();
export type DailyBusinessReportPayload = z.infer<typeof dailyBusinessReportPayloadSchema>;

export const dailyBusinessReportEligibilityModuleSchema = z.object({
  module_key: dailyBusinessReportModuleKeySchema,
  required: z.boolean(),
  requirement_basis: dailyBusinessReportRequirementBasisSchema,
}).strict();

export const dailyBusinessReportEligibilityBranchSchema = z.object({
  branch_id: z.uuid(),
  timezone: z.string().min(1).max(80),
  close_at: z.string().min(1),
  modules: z.array(dailyBusinessReportEligibilityModuleSchema),
}).strict();

export const dailyBusinessReportEligibilitySnapshotSchema = z.object({
  policy_version: z.string().min(1),
  branches: z.array(dailyBusinessReportEligibilityBranchSchema),
}).strict();
export type DailyBusinessReportEligibilitySnapshot = z.infer<typeof dailyBusinessReportEligibilitySnapshotSchema>;

export const dailyBusinessReportMaintenanceItemSchema = z.object({
  id: z.uuid(),
  branch_id: z.uuid(),
  title: z.string().min(1).max(200),
  category: z.string().min(1).max(80),
  priority: z.string().min(1).max(40),
  status: z.string().min(1).max(40),
  created_at: z.string().min(1),
}).strict();
export type DailyBusinessReportMaintenanceItem = z.infer<typeof dailyBusinessReportMaintenanceItemSchema>;

export const dailyBusinessReportMaintenanceSummarySchema = z.object({
  total_issues: z.number().int().nonnegative(),
  urgent_count: z.number().int().nonnegative(),
  high_count: z.number().int().nonnegative(),
  medium_count: z.number().int().nonnegative(),
  low_count: z.number().int().nonnegative(),
  in_progress_count: z.number().int().nonnegative(),
  resolved_count: z.number().int().nonnegative(),
  items: z.array(dailyBusinessReportMaintenanceItemSchema),
}).strict();
export type DailyBusinessReportMaintenanceSummary = z.infer<typeof dailyBusinessReportMaintenanceSummarySchema>;

export const dailyBusinessReportPreviewSchema = z.object({
  organization_id: z.uuid(),
  business_date: z.iso.date(),
  schema_version: z.literal(1),
  is_closed: z.boolean(),
  earliest_open_branch_close_at: z.string().nullable(),
  payload: dailyBusinessReportPayloadSchema,
  sales_summary: managementSalesTrackingPeriodSummarySchema,
  maintenance_summary: dailyBusinessReportMaintenanceSummarySchema,
}).strict();
export type DailyBusinessReportPreview = z.infer<typeof dailyBusinessReportPreviewSchema>;

export const dailyBusinessReportRecordSchema = z.object({
  report_id: z.uuid(),
  revision_id: z.uuid(),
  organization_id: z.uuid(),
  business_date: z.iso.date(),
  schema_version: z.literal(1),
  revision: z.number().int().positive(),
  source_cutoff_at: z.string(),
  eligibility_snapshot: dailyBusinessReportEligibilitySnapshotSchema,
  payload: dailyBusinessReportPayloadSchema,
  canonical_payload_hash: z.string().regex(/^[0-9a-f]{64}$/),
  source_watermark: z.string().min(1).max(500),
  generation_reason: z.enum(["initial", "late_submission", "authoritative_report_changed", "source_correction"]),
  generated_at: z.string(),
  finalized_at: z.string(),
  sales_summary: managementSalesTrackingPeriodSummarySchema.optional(),
  maintenance_summary: dailyBusinessReportMaintenanceSummarySchema.optional(),
}).strict();
export type DailyBusinessReportRecord = z.infer<typeof dailyBusinessReportRecordSchema>;

export const dailyBusinessReportQuerySchema = z.object({
  business_date: z.iso.date(),
  revision: z.coerce.number().int().positive().optional(),
}).strict();
export type DailyBusinessReportQuery = z.infer<typeof dailyBusinessReportQuerySchema>;
