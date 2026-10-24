import { z } from "zod";

const decimal = z.preprocess(
  (value) => typeof value === "number" ? String(value) : value,
  z.string().regex(/^-?\d+(?:\.\d+)?$/u),
);
const count = z.coerce.number().int().nonnegative();
const currency = z.enum(["SAR", "AED"]);

export const salesTrackingPeriodScopeSchema = z.object({
  organization_id: z.uuid(),
  branch_id: z.uuid().nullable(),
  date_from: z.iso.date(),
  date_to: z.iso.date(),
}).strict();

const providerBreakdownSchema = z.object({
  identity_key: z.string().min(1).max(260),
  provider_key: z.string().min(1).max(120).nullable(),
  normalized_name: z.string().min(1).max(120),
  display_name: z.string().min(1).max(120),
  amount: decimal,
}).strict();

const actualPaymentsSchema = z.object({
  cash: decimal,
  credit: decimal,
  online: decimal,
  total: decimal,
}).strict();

const posReconciliationSchema = z.object({
  cash: decimal,
  credit: decimal,
  online: decimal,
  total: decimal,
  variance: decimal,
}).strict();

const periodMetricsSchema = z.object({
  currency_code: currency,
  submitted_report_count: count,
  submitted_business_day_count: count,
  sales_entry_count: count,
  cash_entry_count: count,
  reports_with_photos_count: count,
  evidence_photo_count: count,
  gross_sales: decimal,
  refund_total: decimal,
  net_sales: decimal,
  actual_payments: actualPaymentsSchema,
  pos_reconciliation: posReconciliationSchema,
  counted_cash_total: decimal,
  balanced_report_count: count,
  variance_report_count: count,
  provider_breakdown: z.array(providerBreakdownSchema).max(500),
  unspecified_online_delivery: decimal,
}).strict();

export const managementSalesTrackingPeriodSummarySchema = z.object({
  generated_at: z.iso.datetime({ offset: true }),
  state: z.enum(["complete", "empty"]),
  scope: salesTrackingPeriodScopeSchema,
  currency_summaries: z.array(periodMetricsSchema.extend({
    submitted_branch_day_count: count,
    reporting_branch_count: count,
  }).strict()).max(2),
  branches: z.array(periodMetricsSchema.extend({
    branch_id: z.uuid(),
    branch_name: z.string().min(1).max(160),
    branch_name_ar: z.string().min(1).max(160).nullable(),
    branch_code: z.string().min(1).max(120),
  }).strict()).max(500),
}).strict();

export const salesTrackingEvidenceAvailabilitySchema = z.enum([
  "available",
  "missing_object",
  "signing_unavailable",
]);

export const managementSalesTrackingEvidencePhotoSchema = z.object({
  attachment_id: z.uuid(),
  report_id: z.uuid(),
  business_date: z.iso.date(),
  display_order: z.number().int().min(1).max(3),
  original_filename: z.string().min(1).max(180),
  mime_type: z.enum(["image/jpeg", "image/png", "image/webp"]),
  size_bytes: z.number().int().positive().max(5 * 1024 * 1024),
  created_at: z.iso.datetime({ offset: true }),
  availability: salesTrackingEvidenceAvailabilitySchema,
  signed_url: z.url().nullable(),
  signed_url_expires_at: z.iso.datetime({ offset: true }).nullable(),
}).strict().superRefine((value, context) => {
  const available = value.availability === "available";
  if (available !== (value.signed_url !== null && value.signed_url_expires_at !== null)) {
    context.addIssue({ code: "custom", message: "Invalid evidence availability." });
  }
});

const evidenceBranchSchema = z.object({
  id: z.uuid(),
  name: z.string().min(1).max(160),
  name_ar: z.string().min(1).max(160).nullable(),
  code: z.string().min(1).max(120),
}).strict();

export const managementSalesTrackingEvidencePageSchema = z.object({
  generated_at: z.iso.datetime({ offset: true }),
  state: z.enum(["complete", "partial", "empty"]),
  empty_reason: z.literal("no_authoritative_photos").nullable(),
  scope: salesTrackingPeriodScopeSchema,
  groups: z.array(z.object({
    business_date: z.iso.date(),
    branches: z.array(z.object({
      branch: evidenceBranchSchema,
      photos: z.array(managementSalesTrackingEvidencePhotoSchema).min(1).max(50),
    }).strict()).min(1).max(50),
  }).strict()).max(50),
  page: z.object({
    page_size: z.number().int().min(1).max(50),
    returned_items: z.number().int().min(0).max(50),
    has_more: z.boolean(),
    next_cursor: z.string().min(1).max(1024).nullable(),
  }).strict(),
  issues: z.object({
    missing_object_count: z.number().int().nonnegative().max(50),
    signing_unavailable_count: z.number().int().nonnegative().max(50),
  }).strict(),
}).strict();

export const managementSalesTrackingEvidenceRenewalItemSchema = z.object({
  attachment_id: z.uuid(),
  availability: z.enum(["available", "missing_object", "signing_unavailable", "not_available"]),
  signed_url: z.url().nullable(),
}).strict().superRefine((value, context) => {
  const available = value.availability === "available";
  if (available !== (value.signed_url !== null)) {
    context.addIssue({ code: "custom", message: "Invalid evidence renewal availability." });
  }
});

export const managementSalesTrackingEvidenceRenewalSchema = z.object({
  generated_at: z.iso.datetime({ offset: true }),
  signed_url_expires_at: z.iso.datetime({ offset: true }),
  results: z.array(managementSalesTrackingEvidenceRenewalItemSchema).min(1).max(50),
}).strict();

export type ManagementSalesTrackingPeriodSummary = z.infer<typeof managementSalesTrackingPeriodSummarySchema>;
export type ManagementSalesTrackingEvidencePage = z.infer<typeof managementSalesTrackingEvidencePageSchema>;
export type ManagementSalesTrackingEvidenceRenewal = z.infer<typeof managementSalesTrackingEvidenceRenewalSchema>;
