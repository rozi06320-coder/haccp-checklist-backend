import { z } from "zod";

const uuid = z.uuid();
const decimal = z.union([z.number(), z.string()]).transform(Number).pipe(z.number().finite());

export const monthlySupervisorEvaluationSubjectTypeSchema = z.enum(["supervisor", "training_supervisor"]);
export const monthlySupervisorEvaluationStatusSchema = z.enum(["draft", "submitted"]);
export const monthlySupervisorEvaluationScoreInputSchema = z.object({
  criterion_key: z.string().min(1).max(80),
  rating: z.number().int().min(1).max(5).nullable(),
}).strict();

export const monthlySupervisorEvaluationCriterionSchema = z.object({
  criterion_key: z.string(),
  title_en: z.string(),
  title_ar: z.string(),
  weight: decimal,
  max_score: decimal,
  display_order: z.number().int().positive(),
  active: z.boolean(),
}).strict();

export const monthlySupervisorEvaluationTemplateSchema = z.object({
  version: z.number().int().positive(),
  name: z.string(),
  effective_from: z.iso.date(),
  effective_to: z.iso.date().nullable(),
  criteria: z.array(monthlySupervisorEvaluationCriterionSchema).max(100),
}).strict();

const branchSchema = z.object({ id: uuid, name: z.string() }).strict();

export const monthlySupervisorEvaluationSubjectSchema = z.object({
  supervisor_user_id: uuid,
  subject_type: monthlySupervisorEvaluationSubjectTypeSchema,
  name: z.string(),
  role: z.string(),
  branch: branchSchema.nullable(),
  eligible: z.boolean(),
  ineligibility_reason: z.enum(["ambiguous_branch_history", "historical_branch_unavailable"]).nullable(),
}).strict();

export const monthlySupervisorEvaluationScoreSchema = z.object({
  criterion_key: z.string(),
  title_en: z.string(),
  title_ar: z.string(),
  max_score: decimal,
  weight: decimal,
  rating: z.number().int().min(1).max(5).nullable(),
}).strict();

export const monthlySupervisorEvaluationDetailSchema = z.object({
  id: uuid,
  organization_id: uuid,
  supervisor_user_id: uuid,
  subject_type: monthlySupervisorEvaluationSubjectTypeSchema,
  evaluation_month: z.iso.date(),
  branch: branchSchema,
  supervisor: z.object({ id: uuid, name: z.string(), role: z.string(), subject_type: monthlySupervisorEvaluationSubjectTypeSchema }).strict(),
  evaluator: z.object({ id: uuid, name: z.string() }).strict(),
  status: monthlySupervisorEvaluationStatusSchema,
  revision: z.number().int().nonnegative(),
  template_version: z.number().int().positive(),
  total_score: decimal.nullable(),
  max_score: decimal.nullable(),
  percentage: decimal.nullable(),
  created_at: z.string(),
  updated_at: z.string(),
  submitted_at: z.string().nullable(),
  scores: z.array(monthlySupervisorEvaluationScoreSchema).max(100),
}).strict();

export const monthlySupervisorEvaluationHistorySchema = z.object({
  id: uuid,
  supervisor_user_id: uuid,
  subject_type: monthlySupervisorEvaluationSubjectTypeSchema,
  supervisor_name: z.string(),
  supervisor_role: z.string(),
  branch: branchSchema,
  status: monthlySupervisorEvaluationStatusSchema,
  revision: z.number().int().nonnegative(),
  total_score: decimal.nullable(),
  max_score: decimal.nullable(),
  percentage: decimal.nullable(),
  updated_at: z.string(),
  submitted_at: z.string().nullable(),
}).strict();

export const monthlySupervisorEvaluationSummarySchema = z.object({
  supervisors_total: z.number().int().nonnegative(),
  evaluated_count: z.number().int().nonnegative(),
  pending_count: z.number().int().nonnegative(),
  average_percentage: decimal.nullable(),
}).strict();

export const monthlySupervisorEvaluationWorkspaceSchema = z.object({
  evaluation_month: z.iso.date(),
  template: monthlySupervisorEvaluationTemplateSchema,
  subjects: z.array(monthlySupervisorEvaluationSubjectSchema).max(1000),
  evaluations: z.array(monthlySupervisorEvaluationHistorySchema).max(1000),
  summary: monthlySupervisorEvaluationSummarySchema,
}).strict();

export type MonthlySupervisorEvaluationCriterion = z.infer<typeof monthlySupervisorEvaluationCriterionSchema>;
export type MonthlySupervisorEvaluationScoreInput = z.infer<typeof monthlySupervisorEvaluationScoreInputSchema>;
export type MonthlySupervisorEvaluationSubject = z.infer<typeof monthlySupervisorEvaluationSubjectSchema>;
export type MonthlySupervisorEvaluationSummary = z.infer<typeof monthlySupervisorEvaluationSummarySchema>;
export type MonthlySupervisorEvaluationDetail = z.infer<typeof monthlySupervisorEvaluationDetailSchema>;
export type MonthlySupervisorEvaluationWorkspace = z.infer<typeof monthlySupervisorEvaluationWorkspaceSchema>;
