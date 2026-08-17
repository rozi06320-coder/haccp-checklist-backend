import { z } from "zod";

export const annualEvaluationCriterionKeys = [
  "work_rules_procedures","work_methods","required_standard","required_time","work_pressure","discipline",
  "initiative_creativity","works_without_supervision","work_improvement","accepts_direction","cooperation",
  "greater_responsibility","sound_decisions","adaptability","company_loyalty","company_property",
  "company_policies","respect","appearance","personal_behaviour",
] as const;

export const annualEvaluationCriterionSchema = z.enum(annualEvaluationCriterionKeys);
export const annualEvaluationSubjectTypeSchema = z.enum(["supervisor","training_supervisor","employee"]);
export const annualEvaluationStateSchema = z.enum(["draft","submitted"]);
export const annualEvaluationScoreSchema = z.object({
  criterion_key: annualEvaluationCriterionSchema,
  score: z.number().int().min(1).max(5),
}).strict();

export const annualEvaluationDetailSchema = z.object({
  id:z.uuid(),organization_id:z.uuid(),branch_id:z.uuid(),evaluation_year:z.number().int().min(2000).max(2200),
  subject_type:annualEvaluationSubjectTypeSchema,supervisor_user_id:z.uuid().nullable(),operational_staff_id:z.uuid().nullable(),
  state:annualEvaluationStateSchema,revision:z.number().int().nonnegative(),evaluator_user_id:z.uuid(),
  evaluator_name_snapshot:z.string(),subject_name_snapshot:z.string(),subject_role_snapshot:z.string(),
  subject_staff_code_snapshot:z.string().nullable(),branch_name_snapshot:z.string(),total_score:z.number().int().min(20).max(100).nullable(),
  created_at:z.string(),updated_at:z.string(),submitted_at:z.string().nullable(),scores:z.array(annualEvaluationScoreSchema).max(20),
}).strict();

export const annualEvaluationSubjectSchema = z.object({
  subject_type:annualEvaluationSubjectTypeSchema,subject_id:z.uuid(),supervisor_user_id:z.uuid().nullable(),
  operational_staff_id:z.uuid().nullable(),subject_name:z.string(),staff_code:z.string().nullable(),role:z.string(),
  branch_id:z.uuid(),branch_name:z.string(),
  person_code:z.string().nullable().optional(),phone_number:z.string().nullable().optional(),country_code:z.string().nullable().optional(),
  iqama_number:z.string().nullable().optional(),iqama_expiry_date:z.string().nullable().optional(),
}).strict();

export const annualEvaluationHistorySchema = z.object({
  id:z.uuid(),branch_id:z.uuid(),evaluation_year:z.number().int(),subject_type:annualEvaluationSubjectTypeSchema,
  subject_id:z.uuid(),subject_name_snapshot:z.string(),subject_role_snapshot:z.string(),subject_staff_code_snapshot:z.string().nullable(),
  branch_name_snapshot:z.string(),state:annualEvaluationStateSchema,revision:z.number().int().nonnegative(),
  total_score:z.number().int().min(20).max(100).nullable(),evaluator_name_snapshot:z.string(),updated_at:z.string(),submitted_at:z.string().nullable(),
}).strict();

export const annualEvaluationWorkspaceSchema = z.object({
  subjects:z.array(annualEvaluationSubjectSchema).max(1000),
  evaluations:z.array(annualEvaluationHistorySchema).max(500),
  current:annualEvaluationDetailSchema.nullable(),
}).strict();

export type AnnualEvaluationCriterionKey = z.infer<typeof annualEvaluationCriterionSchema>;
export type AnnualEvaluationScore = z.infer<typeof annualEvaluationScoreSchema>;
export type AnnualEvaluationDetail = z.infer<typeof annualEvaluationDetailSchema>;
export type AnnualEvaluationSubject = z.infer<typeof annualEvaluationSubjectSchema>;
export type AnnualEvaluationHistory = z.infer<typeof annualEvaluationHistorySchema>;
export type AnnualEvaluationWorkspace = z.infer<typeof annualEvaluationWorkspaceSchema>;
