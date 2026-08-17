import { z } from "zod";

const decimal = z.string().regex(/^\d+(?:\.\d+)?$/);
const availability = z.enum(["ready", "unavailable"]);

export const managementOperationsSummarySchema = z.object({
  generated_at: z.iso.datetime({ offset: true }),
  scope: z.object({
    organization_id: z.uuid(),
    branch_id: z.uuid().nullable(),
    month: z.string().regex(/^\d{4}-(?:0[1-9]|1[0-2])$/),
  }).strict(),
  purchase_logs: z.object({
    unpaid_count: z.number().int().nonnegative(),
    unpaid_amount: decimal,
    total_amount: decimal,
  }).strict(),
  supplier_receivings: z.object({
    entry_count: z.number().int().nonnegative(),
    branch_count: z.number().int().nonnegative(),
  }).strict(),
  maintenance_issues: z.object({
    open_count: z.number().int().nonnegative(),
    urgent_high_count: z.number().int().nonnegative(),
  }).strict(),
  maintenance_purchases: z.object({
    purchase_count: z.number().int().nonnegative(),
    total_amount: decimal,
    unpaid_count: z.number().int().nonnegative(),
    unpaid_amount: decimal,
  }).strict(),
  inventory: z.object({
    active_branch_count: z.number().int().nonnegative(),
    reported_branch_count: z.number().int().nonnegative(),
    submitted_branch_count: z.number().int().nonnegative(),
    beef_row_count: z.number().int().nonnegative(),
    item_usage_row_count: z.number().int().nonnegative(),
  }).strict(),
  staff: z.object({
    active_count: z.number().int().nonnegative(),
    inactive_count: z.number().int().nonnegative(),
  }).strict(),
  availability: z.object({
    purchase_logs: availability,
    supplier_receivings: availability,
    maintenance_issues: availability,
    maintenance_purchases: availability,
    inventory: availability,
    staff: availability,
  }).strict(),
}).strict();

export type ManagementOperationsSummary = z.infer<typeof managementOperationsSummarySchema>;
