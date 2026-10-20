import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

const auth = { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false } as const;
const uuid = z.uuid();
const locales = ["en", "ar", "id", "hi", "fil"] as const;
const localizedText = z.object({ en:z.string().min(1),ar:z.string().min(1),id:z.string().min(1),hi:z.string().min(1),fil:z.string().min(1) }).strict();
const localizedContent = z.object({
  en:z.record(z.string(),z.unknown()), ar:z.record(z.string(),z.unknown()), id:z.record(z.string(),z.unknown()),
  hi:z.record(z.string(),z.unknown()), fil:z.record(z.string(),z.unknown()),
}).strict();

const enrollmentRow = z.object({
  id:uuid,organization_id:uuid,employee_id:uuid,course_id:uuid,course_version_id:uuid,
  program_course_id:uuid.nullable(),
  status:z.literal("active"),branch_id_at_enrollment:uuid,branch_name_at_enrollment:z.string(),
  operational_team_id_at_enrollment:uuid,operational_team_name_at_enrollment:z.string(),
  identity_method:z.literal("branch_pin_employee_code"),compliance_identity_verified:z.literal(false),
  enrolled_at:z.string(),started_at:z.string().nullable(),last_accessed_lesson_id:uuid.nullable(),
  last_accessed_at:z.string().nullable(),created_at:z.string(),updated_at:z.string(),
}).strict();
const progressRow = z.object({
  id:uuid,organization_id:uuid,enrollment_id:uuid,employee_id:uuid,course_version_id:uuid,lesson_id:uuid,
  status:z.enum(["in_progress","completed"]),started_at:z.string(),completed_at:z.string().nullable(),
  created_at:z.string(),updated_at:z.string(),
}).strict();
const summaryRow = z.object({
  enrollment_id:uuid,course_id:uuid,course_version_id:uuid,enrollment_status:z.literal("active"),
  enrolled_at:z.string(),started_at:z.string().nullable(),last_accessed_lesson_id:uuid.nullable(),last_accessed_at:z.string().nullable(),
  required_lesson_count:z.number().int().positive(),started_lesson_count:z.number().int().nonnegative(),
  completed_lesson_count:z.number().int().nonnegative(),resume_lesson_id:uuid,
  final_assessment_unlocked:z.boolean(),
}).strict();
const curriculumRow = z.object({
  course_id:uuid,course_key:z.string(),course_version_id:uuid,version_number:z.number().int().positive(),
  version_status:z.literal("published"),revision:z.coerce.number().int().nonnegative(),content_hash:z.string().min(1),
  default_locale:z.literal("en"),supported_locales:z.array(z.string()).length(5),
  course_title_i18n:localizedText,course_description_i18n:localizedText,
  module_id:uuid,module_key:z.string(),module_position:z.number().int().positive(),module_title_i18n:localizedText,module_description_i18n:localizedText,
  lesson_id:uuid,lesson_key:z.string(),lesson_position:z.number().int().positive(),lesson_type:z.enum(["reading","key_points","quiz"]),required:z.literal(true),
  lesson_title_i18n:localizedText,lesson_objective_i18n:localizedText,lesson_content_i18n:localizedContent.nullable(),
  question_count:z.number().int().nullable(),pass_threshold_bps:z.number().int().nullable(),
}).strict();
const imageRow = z.object({
  lesson_id:uuid,asset_key:z.string().min(1),placement:z.string().min(1),slot_position:z.number().int().positive(),
  expected_alt_i18n:localizedText,media_id:uuid,width:z.number().int().positive(),height:z.number().int().positive(),
}).strict();
const lessonProgressRow=z.object({lesson_id:uuid,global_position:z.number().int().min(1).max(18),status:z.enum(["not_started","in_progress","completed"]),started_at:z.string().nullable(),completed_at:z.string().nullable()}).strict();
const storageRow=z.object({storage_bucket:z.literal("training-published-media"),storage_object_path:z.string().regex(/^sha256\/[0-9a-f]{2}\/[0-9a-f]{64}\.webp$/),mime_type:z.literal("image/webp"),sha256:z.string().regex(/^[0-9a-f]{64}$/),integrity_checked_at:z.string()}).strict();
const quizOption=z.object({option_key:z.string().min(1),text:z.string().min(1)}).strict();
const quizQuestion=z.object({question_key:z.string().min(1),prompt:z.string().min(1),options:z.array(quizOption).min(2)}).strict();
const quizAttemptRow=z.object({
  attempt_id:uuid,attempt_number:z.number().int().positive(),status:z.enum(["in_progress","submitted"]),locale:z.enum(locales),
  started_at:z.string(),question_count:z.literal(27),pass_threshold_bps:z.literal(8000),questions:z.array(quizQuestion).length(27),
}).strict();
const assessmentStatusRow=z.object({
  locked:z.boolean(),in_progress_attempt_id:uuid.nullable(),latest_attempt_number:z.number().int().positive().nullable(),
  latest_status:z.enum(["in_progress","submitted"]).nullable(),latest_correct_count:z.number().int().min(0).max(27).nullable(),
  latest_question_count:z.literal(27).nullable(),latest_passed:z.boolean().nullable(),latest_submitted_at:z.string().nullable(),
  completed:z.boolean(),completed_at:z.string().nullable(),
}).strict();
const quizResultRow=z.object({
  attempt_id:uuid,attempt_number:z.number().int().positive(),status:z.literal("submitted"),correct_count:z.number().int().min(0).max(27),
  question_count:z.literal(27),score_bps:z.number().int().min(0).max(10000),passed:z.boolean(),submitted_at:z.string(),
  course_completed:z.boolean(),course_completed_at:z.string().nullable(),
}).strict();
const programCategoryRow=z.object({
  program_id:uuid,program_key:z.literal("restaurant-training"),program_title_i18n:localizedText,program_description_i18n:localizedText,
  program_course_id:uuid,category_position:z.number().int().positive(),category_label_i18n:localizedText,category_required:z.boolean(),
  course_id:uuid,course_key:z.string().min(1),course_available:z.boolean(),locked:z.boolean(),
  lock_reason:z.literal("prerequisite_incomplete").nullable(),category_status:z.enum(["content_unavailable","locked","available","in_progress","completed"]),
  enrollment_id:uuid.nullable(),required_lesson_count:z.number().int().nonnegative(),completed_lesson_count:z.number().int().nonnegative(),
  final_assessment_status:z.enum(["not_configured","locked","available","in_progress","failed","passed"]),
  course_completed:z.boolean(),course_completed_at:z.string().nullable(),
}).strict();
export const trainingProgramResponseSchema=z.object({
  program:z.object({
    id:uuid,key:z.literal("restaurant-training"),title_i18n:localizedText,description_i18n:localizedText,
    categories:z.array(z.object({
      program_course_id:uuid,position:z.number().int().min(1).max(2),label_i18n:localizedText,required:z.boolean(),
      course_id:uuid,course_key:z.enum(["baladiyah-food-safety-hygiene","restaurant-sop"]),course_available:z.boolean(),
      locked:z.boolean(),lock_reason:z.literal("prerequisite_incomplete").nullable(),status:z.enum(["content_unavailable","locked","available","in_progress","completed"]),
      enrollment_id:uuid.nullable(),required_lesson_count:z.number().int().nonnegative(),completed_lesson_count:z.number().int().nonnegative(),
      final_assessment_status:z.enum(["not_configured","locked","available","in_progress","failed","passed"]),
      completed:z.boolean(),completed_at:z.string().nullable(),
    }).strict()).length(2),
  }).strict(),
}).strict();
export type TrainingQuizAnswer={question_key:string;option_key:string};

export type LegacyTrainingIdentity={organizationId:string;branchId:string;employeeId:string};
export type TrainingProgressService={
  initialize(identity:LegacyTrainingIdentity,courseKey:string):Promise<z.infer<typeof enrollmentRow>>;
  initializeProgramCourse(identity:LegacyTrainingIdentity,programCourseId:string):Promise<z.infer<typeof enrollmentRow>>;
  getProgram(identity:LegacyTrainingIdentity):Promise<z.infer<typeof trainingProgramResponseSchema>["program"]>;
  getProgress(identity:LegacyTrainingIdentity,enrollmentId:string):Promise<z.infer<typeof summaryRow>>;
  startLesson(identity:LegacyTrainingIdentity,enrollmentId:string,lessonId:string):Promise<z.infer<typeof progressRow>>;
  completeLesson(identity:LegacyTrainingIdentity,enrollmentId:string,lessonId:string):Promise<z.infer<typeof progressRow>>;
  getCurriculum(identity:LegacyTrainingIdentity,enrollmentId:string):Promise<unknown>;
  authorizeMedia(identity:LegacyTrainingIdentity,enrollmentId:string,mediaId:string):Promise<{signed_url:string;mime_type:"image/webp";expires_in:300}|null>;
  getAssessmentStatus(identity:LegacyTrainingIdentity,enrollmentId:string):Promise<z.infer<typeof assessmentStatusRow>>;
  startQuizAttempt(identity:LegacyTrainingIdentity,enrollmentId:string,locale:string,idempotencyKey:string):Promise<z.infer<typeof quizAttemptRow>>;
  getQuizAttempt(identity:LegacyTrainingIdentity,enrollmentId:string,attemptId:string):Promise<z.infer<typeof quizAttemptRow>>;
  submitQuizAttempt(identity:LegacyTrainingIdentity,enrollmentId:string,attemptId:string,idempotencyKey:string,answers:TrainingQuizAnswer[]):Promise<z.infer<typeof quizResultRow>>;
};

export class TrainingProgressAccessError extends Error{}
export class TrainingProgressNotFoundError extends Error{}
export class TrainingProgressConflictError extends Error{}
export class TrainingProgressUnavailableError extends Error{}

export function createTrainingProgressService(url:string,secretKey:string):TrainingProgressService{
  const client=createClient(url,secretKey,{auth});
  async function rpc(name:string,input:Record<string,unknown>){
    const result=await client.rpc(name,input);
    if(result.error){
      if(result.error.code==="42501")throw new TrainingProgressAccessError();
      if(result.error.code==="P0002")throw new TrainingProgressNotFoundError();
      if(["22023","23503","23505","23514","55000"].includes(result.error.code??""))throw new TrainingProgressConflictError();
      throw new TrainingProgressUnavailableError();
    }
    if(!Array.isArray(result.data))throw new TrainingProgressUnavailableError();
    return result.data;
  }
  const args=(identity:LegacyTrainingIdentity)=>({target_organization_id:identity.organizationId,target_branch_id:identity.branchId,target_employee_id:identity.employeeId});
  const one=<T>(schema:z.ZodType<T>,rows:unknown[])=>{const parsed=z.array(schema).length(1).safeParse(rows);if(!parsed.success)throw new TrainingProgressUnavailableError();return parsed.data[0]!;};
  async function getProgress(identity:LegacyTrainingIdentity,enrollmentId:string){
    uuid.parse(enrollmentId);return one(summaryRow,await rpc("get_training_enrollment_progress",{...args(identity),target_enrollment_id:enrollmentId}));
  }
  async function getAssessmentStatus(identity:LegacyTrainingIdentity,enrollmentId:string){
    uuid.parse(enrollmentId);return one(assessmentStatusRow,await rpc("get_training_final_assessment_status",{...args(identity),target_enrollment_id:enrollmentId}));
  }
  return{
    async initialize(identity,courseKey){
      if(!/^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$/.test(courseKey))throw new TrainingProgressConflictError();
      return one(enrollmentRow,await rpc("initialize_training_enrollment",{...args(identity),target_course_key:courseKey}));
    },
    async initializeProgramCourse(identity,programCourseId){
      uuid.parse(programCourseId);
      return one(enrollmentRow,await rpc("initialize_training_program_enrollment",{...args(identity),target_program_course_id:programCourseId}));
    },
    async getProgram(identity){
      const rows=z.array(programCategoryRow).length(2).parse(await rpc("get_training_program_status",{...args(identity),target_program_key:"restaurant-training"}));
      const ordered=[...rows].sort((left,right)=>left.category_position-right.category_position);
      if(ordered[0]?.category_position!==1||ordered[0].course_key!=="baladiyah-food-safety-hygiene"
        ||ordered[1]?.category_position!==2||ordered[1].course_key!=="restaurant-sop"
        ||new Set(ordered.map(category=>category.program_course_id)).size!==2
        ||ordered.some(category=>category.completed_lesson_count>category.required_lesson_count)
        ||ordered.some(category=>category.locked!==(category.lock_reason==="prerequisite_incomplete")))throw new TrainingProgressConflictError();
      const first=ordered[0];
      return trainingProgramResponseSchema.shape.program.parse({
        id:first.program_id,key:first.program_key,title_i18n:first.program_title_i18n,description_i18n:first.program_description_i18n,
        categories:ordered.map(category=>({
          program_course_id:category.program_course_id,position:category.category_position,label_i18n:category.category_label_i18n,required:category.category_required,
          course_id:category.course_id,course_key:category.course_key,course_available:category.course_available,locked:category.locked,
          lock_reason:category.lock_reason,status:category.category_status,enrollment_id:category.enrollment_id,
          required_lesson_count:category.required_lesson_count,completed_lesson_count:category.completed_lesson_count,
          final_assessment_status:category.final_assessment_status,completed:category.course_completed,completed_at:category.course_completed_at,
        })),
      });
    },
    getProgress,
    getAssessmentStatus,
    async startQuizAttempt(identity,enrollmentId,locale,idempotencyKey){
      uuid.parse(enrollmentId);uuid.parse(idempotencyKey);
      if(!locales.includes(locale as typeof locales[number]))throw new TrainingProgressConflictError();
      return one(quizAttemptRow,await rpc("start_training_final_quiz_attempt",{...args(identity),target_enrollment_id:enrollmentId,target_locale:locale,target_idempotency_key:idempotencyKey}));
    },
    async getQuizAttempt(identity,enrollmentId,attemptId){
      uuid.parse(enrollmentId);uuid.parse(attemptId);
      return one(quizAttemptRow,await rpc("get_training_final_quiz_attempt",{...args(identity),target_enrollment_id:enrollmentId,target_attempt_id:attemptId}));
    },
    async submitQuizAttempt(identity,enrollmentId,attemptId,idempotencyKey,answers){
      uuid.parse(enrollmentId);uuid.parse(attemptId);uuid.parse(idempotencyKey);
      return one(quizResultRow,await rpc("submit_training_final_quiz_attempt",{...args(identity),target_enrollment_id:enrollmentId,target_attempt_id:attemptId,target_idempotency_key:idempotencyKey,target_answers:answers}));
    },
    async startLesson(identity,enrollmentId,lessonId){
      uuid.parse(enrollmentId);uuid.parse(lessonId);return one(progressRow,await rpc("start_training_lesson",{...args(identity),target_enrollment_id:enrollmentId,target_lesson_id:lessonId}));
    },
    async completeLesson(identity,enrollmentId,lessonId){
      uuid.parse(enrollmentId);uuid.parse(lessonId);return one(progressRow,await rpc("complete_training_lesson",{...args(identity),target_enrollment_id:enrollmentId,target_lesson_id:lessonId}));
    },
    async getCurriculum(identity,enrollmentId){
      uuid.parse(enrollmentId);
      const [rawRows,rawImages,progress,rawLessonProgress,assessmentStatus]=await Promise.all([
        rpc("get_training_published_curriculum",{...args(identity),target_enrollment_id:enrollmentId}),
        rpc("list_training_published_image_bindings",{...args(identity),target_enrollment_id:enrollmentId}),
        getProgress(identity,enrollmentId),
        rpc("list_training_lesson_progress",{...args(identity),target_enrollment_id:enrollmentId}),
        getAssessmentStatus(identity,enrollmentId),
      ]);
      const rows=z.array(curriculumRow).length(19).parse(rawRows),images=z.array(imageRow).length(40).parse(rawImages),lessonProgress=z.array(lessonProgressRow).length(18).parse(rawLessonProgress);
      const first=rows[0];if(!first||first.course_key!=="baladiyah-food-safety-hygiene"||first.supported_locales.join(",")!==locales.join(","))throw new TrainingProgressConflictError();
      if(new Set(images.map(image=>image.asset_key)).size!==40)throw new TrainingProgressConflictError();
      const instructionRows=rows.filter(row=>row.lesson_type!=="quiz"),quizRows=rows.filter(row=>row.lesson_type==="quiz");
      if(instructionRows.length!==18||quizRows.length!==1)throw new TrainingProgressConflictError();
      const modules=Array.from(new Map(instructionRows.map(row=>[row.module_id,row])).values()).map(module=>({
        id:module.module_id,stable_key:module.module_key,position:module.module_position,title_i18n:module.module_title_i18n,description_i18n:module.module_description_i18n,
        lessons:instructionRows.filter(row=>row.module_id===module.module_id).map(row=>({
          id:row.lesson_id,stable_key:row.lesson_key,position:row.lesson_position,lesson_type:row.lesson_type,title_i18n:row.lesson_title_i18n,
          objective_i18n:row.lesson_objective_i18n,content_i18n:row.lesson_content_i18n,
          images:images.filter(image=>image.lesson_id===row.lesson_id).map(image=>({...image,src:`/api/training/media/${image.media_id}?enrollment=${enrollmentId}`})),
        })),
      }));
      if(modules.length!==9||modules.some((module,index)=>module.position!==index+1||module.lessons.length!==2))throw new TrainingProgressConflictError();
      const quiz=quizRows[0]!;
      if(quiz.module_key!=="final-assessment"||quiz.lesson_key!=="final-quiz"||quiz.question_count!==27||quiz.pass_threshold_bps!==8000||quiz.lesson_content_i18n!==null)throw new TrainingProgressConflictError();
      return{course:{id:first.course_id,key:first.course_key,version_id:first.course_version_id,version_number:first.version_number,default_locale:first.default_locale,supported_locales:first.supported_locales,title_i18n:first.course_title_i18n,description_i18n:first.course_description_i18n},instructional_modules:modules,progress:{...progress,lessons:lessonProgress},final_assessment:{module_id:quiz.module_id,lesson_id:quiz.lesson_id,title_i18n:quiz.lesson_title_i18n,question_count:27,pass_threshold_bps:8000,minimum_correct_count:22,locked:assessmentStatus.locked,submission_available:!assessmentStatus.locked&&!assessmentStatus.completed,status:assessmentStatus}};
    },
    async authorizeMedia(identity,enrollmentId,mediaId){
      uuid.parse(enrollmentId);uuid.parse(mediaId);const rows=await rpc("authorize_training_published_media_read",{...args(identity),target_enrollment_id:enrollmentId,target_media_id:mediaId});
      const authorized=z.array(storageRow).max(1).parse(rows)[0];if(!authorized)return null;
      const signed=await client.storage.from(authorized.storage_bucket).createSignedUrl(authorized.storage_object_path,300);
      if(signed.error||!signed.data?.signedUrl)throw new TrainingProgressUnavailableError();
      return{signed_url:signed.data.signedUrl,mime_type:"image/webp",expires_in:300};
    },
  };
}
