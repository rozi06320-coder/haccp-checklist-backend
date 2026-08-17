import { z } from "zod";

const decimal = z.string().regex(/^-?\d+(?:\.\d+)?$/);
const nonnegativeCount = z.number().int().nonnegative();

const paymentBreakdownSchema = z.object({
  actual_cash: decimal,
  actual_credit: decimal,
  online_delivery: decimal,
  pos_cash: decimal,
  pos_credit: decimal,
}).strict();

const onlineProviderBreakdownSchema = z.object({
  provider_id: z.uuid().nullable().optional(),
  provider_key: z.string().nullable().optional(),
  provider_name: z.string().min(1),
  amount: decimal,
}).strict();

const monthlyMetricsSchema = z.object({
  submitted_report_count: nonnegativeCount,
  submitted_day_count: nonnegativeCount,
  sales_entry_count: nonnegativeCount,
  cash_entry_count: nonnegativeCount,
  total_sales: decimal,
  total_cash_collected: decimal,
  total_variance: decimal,
  balanced_sales_report_count: nonnegativeCount,
  variance_sales_report_count: nonnegativeCount,
  payment_breakdown: paymentBreakdownSchema,
  online_provider_breakdown: z.array(onlineProviderBreakdownSchema).default([]),
  legacy_online_delivery: decimal.default("0"),
}).strict();

export const managementSalesTrackingMonthlySummarySchema = z.object({
  generated_at: z.iso.datetime({ offset: true }),
  scope: z.object({
    organization_id: z.uuid(),
    branch_id: z.uuid().nullable(),
    month: z.string().regex(/^\d{4}-(?:0[1-9]|1[0-2])$/),
    date_from: z.iso.date(),
    date_to: z.iso.date(),
  }).strict(),
  totals: monthlyMetricsSchema.extend({
    submitted_branch_day_count: nonnegativeCount,
    reporting_branch_count: nonnegativeCount,
  }).omit({ submitted_day_count: true }).strict(),
  branches: z.array(monthlyMetricsSchema.extend({
    branch_id: z.uuid(),
    branch_name: z.string().min(1),
    branch_name_ar: z.string().nullable(),
    branch_code: z.string().min(1),
  }).strict()).max(500),
}).strict();

export type ManagementSalesTrackingMonthlySummary = z.infer<typeof managementSalesTrackingMonthlySummarySchema>;
