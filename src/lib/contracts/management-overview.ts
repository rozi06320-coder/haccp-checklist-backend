import { z } from "zod";

const checklistTypes = ["kitchen_opening", "foh_opening", "staff_hygiene", "oil_tracking", "cold_storage", "sales_tracking", "daily_audit"] as const;
const countKeys = [
  "expected_checks",
  "answered_checks",
  "compliant_checks",
  "issue_checks",
  "pending_checks",
] as const;

const percentage = z.number().int().min(0).max(100).nullable();

export const managementPerformanceCountsSchema = z.object({
  expected_checks: z.number().int().nonnegative(),
  answered_checks: z.number().int().nonnegative(),
  compliant_checks: z.number().int().nonnegative(),
  issue_checks: z.number().int().nonnegative(),
  pending_checks: z.number().int().nonnegative(),
  completion_percentage: percentage,
  compliance_percentage: percentage,
}).strict().superRefine((value, context) => {
  if (value.answered_checks !== value.compliant_checks + value.issue_checks) {
    context.addIssue({ code: "custom", message: "Answered checks do not reconcile." });
  }
  if (value.pending_checks !== value.expected_checks - value.answered_checks) {
    context.addIssue({ code: "custom", message: "Pending checks do not reconcile." });
  }
  const completion = value.expected_checks === 0
    ? null
    : Math.round(value.answered_checks * 100 / value.expected_checks);
  const compliance = value.answered_checks === 0
    ? null
    : Math.round(value.compliant_checks * 100 / value.answered_checks);
  if (value.completion_percentage !== completion) {
    context.addIssue({ code: "custom", message: "Completion percentage is invalid." });
  }
  if (value.compliance_percentage !== compliance) {
    context.addIssue({ code: "custom", message: "Compliance percentage is invalid." });
  }
});

const teamStatesSchema = z.object({
  not_started: z.number().int().nonnegative(),
  draft: z.number().int().nonnegative(),
  submitted: z.number().int().nonnegative(),
}).strict();

const checklistSchema = managementPerformanceCountsSchema.extend({
  checklist_type: z.enum(checklistTypes),
  team_states: teamStatesSchema,
}).strict();

const branchSchema = z.object({
  branch_id: z.uuid(),
  branch_name: z.string().trim().min(1).max(200),
  branch_code: z.string().trim().min(1).max(120),
  timezone: z.string().trim().min(1).max(120),
  business_date: z.iso.date(),
  status: z.enum(["ready", "no_active_team"]),
  active_team_count: z.number().int().nonnegative(),
  totals: managementPerformanceCountsSchema,
  checklists: z.array(checklistSchema).length(7),
}).strict().superRefine((value, context) => {
  const types = value.checklists.map((checklist) => checklist.checklist_type);
  if (new Set(types).size !== checklistTypes.length
    || !checklistTypes.every((type) => types.includes(type))) {
    context.addIssue({ code: "custom", message: "Branch checklist set is invalid." });
  }
  for (const key of countKeys) {
    const expected = value.checklists.reduce((sum, checklist) => sum + checklist[key], 0);
    if (value.totals[key] !== expected) {
      context.addIssue({ code: "custom", message: `Branch ${key} does not reconcile.` });
    }
  }
  if ((value.active_team_count === 0) !== (value.status === "no_active_team")) {
    context.addIssue({ code: "custom", message: "Branch team status is invalid." });
  }
});

export const managementOverviewSchema = z.object({
  organization: z.object({ id: z.uuid(), name: z.string().trim().min(1).max(200) }).strict(),
  generated_at: z.iso.datetime({ offset: true }),
  date_context: z.literal("current_branch_local_business_day"),
  summary: z.object({
    active_branch_count: z.number().int().nonnegative().max(200),
    active_team_count: z.number().int().nonnegative(),
    active_supervisor_account_count: z.number().int().nonnegative(),
    active_operational_staff_count: z.number().int().nonnegative(),
  }).strict(),
  totals: managementPerformanceCountsSchema,
  local_dates: z.array(z.object({
    business_date: z.iso.date(),
    branch_count: z.number().int().positive().max(200),
  }).strict()).max(200),
  branches: z.array(branchSchema).max(200),
}).strict().superRefine((value, context) => {
  if (value.summary.active_branch_count !== value.branches.length) {
    context.addIssue({ code: "custom", message: "Active branch count is invalid." });
  }
  if (new Set(value.branches.map((branch) => branch.branch_id)).size !== value.branches.length) {
    context.addIssue({ code: "custom", message: "Duplicate branch ID." });
  }
  if (new Set(value.local_dates.map((date) => date.business_date)).size !== value.local_dates.length) {
    context.addIssue({ code: "custom", message: "Duplicate local business date." });
  }
  for (let index = 1; index < value.local_dates.length; index += 1) {
    if (value.local_dates[index - 1].business_date >= value.local_dates[index].business_date) {
      context.addIssue({ code: "custom", message: "Local business dates are not ordered." });
    }
  }
  const dateCounts = new Map<string, number>();
  for (const branch of value.branches) {
    dateCounts.set(branch.business_date, (dateCounts.get(branch.business_date) ?? 0) + 1);
  }
  for (const date of value.local_dates) {
    if (dateCounts.get(date.business_date) !== date.branch_count) {
      context.addIssue({ code: "custom", message: "Local business date count is invalid." });
    }
  }
  if ([...dateCounts.keys()].some((date) => !value.local_dates.some((row) => row.business_date === date))) {
    context.addIssue({ code: "custom", message: "A branch local business date is missing." });
  }
  for (const key of countKeys) {
    const expected = value.branches.reduce((sum, branch) => sum + branch.totals[key], 0);
    if (value.totals[key] !== expected) {
      context.addIssue({ code: "custom", message: `Organization ${key} does not reconcile.` });
    }
  }
});

export type ManagementPerformanceCounts = z.infer<typeof managementPerformanceCountsSchema>;
export type ManagementOverview = z.infer<typeof managementOverviewSchema>;
export type ManagementOverviewBranch = ManagementOverview["branches"][number];
