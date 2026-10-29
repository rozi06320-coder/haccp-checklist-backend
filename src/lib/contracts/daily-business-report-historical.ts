import { z } from "zod";

export const historicalDailyBusinessReportModuleStatusSchema = z.enum(["submitted", "issues_detected", "unknown"]);
export type HistoricalDailyBusinessReportModuleStatus = z.infer<typeof historicalDailyBusinessReportModuleStatusSchema>;

export const historicalDailyBusinessReportModuleSchema = z.object({
  status: historicalDailyBusinessReportModuleStatusSchema,
  verification: z.enum(["evidence", "unverified"]),
  required: z.boolean().nullable(),
  expected_count: z.number().int().nonnegative().nullable(),
  submitted_count: z.number().int().nonnegative(),
  missing_count: z.number().int().nonnegative().nullable(),
  issue_count: z.number().int().nonnegative().nullable(),
  source_report_ids: z.array(z.uuid()),
  detail_paths: z.array(z.string()),
}).strict();

export const historicalDailyBusinessReportModulesSchema = z.object({
  kitchen_opening: historicalDailyBusinessReportModuleSchema,
  foh_opening: historicalDailyBusinessReportModuleSchema,
  staff_hygiene: historicalDailyBusinessReportModuleSchema,
  daily_audit: historicalDailyBusinessReportModuleSchema,
  cold_storage: historicalDailyBusinessReportModuleSchema,
  oil_tracking: historicalDailyBusinessReportModuleSchema,
  sales_tracking: historicalDailyBusinessReportModuleSchema,
}).strict();

export const historicalDailyBusinessReportBranchSchema = z.object({
  branch_id: z.uuid(),
  timezone: z.string().min(1).max(80),
  evidence_basis: z.array(z.enum(["checklist_submission", "cold_storage_submission", "oil_tracking_submission", "sales_tracking_submission"])).min(1),
  modules: historicalDailyBusinessReportModulesSchema,
}).strict();

export const historicalDailyBusinessReportSummarySchema = z.object({
  submitted_count: z.number().int().nonnegative(),
  issues_detected_count: z.number().int().nonnegative(),
  unknown_count: z.number().int().nonnegative(),
  verified_required_count: z.number().int().nonnegative(),
  verified_missing_count: z.number().int().nonnegative(),
}).strict();

export const historicalDailyBusinessReportPreviewSchema = z.object({
  organization_id: z.uuid(),
  business_date: z.iso.date(),
  schema_version: z.literal(1),
  mode: z.literal("historical"),
  compliance_verification: z.literal("unverified"),
  summary: historicalDailyBusinessReportSummarySchema,
  branches: z.array(historicalDailyBusinessReportBranchSchema),
}).strict();

export type HistoricalDailyBusinessReportPreview = z.infer<typeof historicalDailyBusinessReportPreviewSchema>;
