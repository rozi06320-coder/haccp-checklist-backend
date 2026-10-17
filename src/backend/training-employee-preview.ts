import {createClient} from "@supabase/supabase-js";
import {z} from "zod";
import type {LegacyTrainingIdentity} from "./training-progress";

const auth={autoRefreshToken:false,detectSessionInUrl:false,persistSession:false} as const;
const uuid=z.uuid();
const i18n=z.object({en:z.string().min(1),ar:z.string().min(1),id:z.string().min(1),hi:z.string().min(1),fil:z.string().min(1)}).strict();
const item=z.object({fact_key:z.string().min(1),presentation:z.enum(["overview","key_point","step","warning","scenario","corrective_action"]),position:z.number().int().positive(),text:z.string().min(1),provenance_classification:z.enum(["baladiyah_explicit","existing_training_supporting","internal_operational"])}).strict();
const imageSlotContent=z.object({asset_key:z.string().min(1),placement:z.string().min(1),slot_position:z.number().int().positive(),label:z.string().min(1)}).strict();
const localizedContent=z.object({content_schema_version:z.literal(1),layout:z.literal("photo_first"),mode:z.enum(["reference","procedure"]),items:z.array(item),image_slots:z.array(imageSlotContent)}).strict();
const contentI18n=z.object({en:localizedContent,ar:localizedContent,id:localizedContent,hi:localizedContent,fil:localizedContent}).strict();
const image=z.object({asset_key:z.string().min(1),placement:z.string().min(1),slot_position:z.number().int().positive(),expected_alt_i18n:i18n,media_id:uuid.nullable(),width:z.number().int().positive().nullable(),height:z.number().int().positive().nullable()}).strict();
const row=z.object({
  course_id:uuid,course_version_id:uuid,version_number:z.literal(1),version_status:z.literal("draft"),revision:z.coerce.number().int().min(0),default_locale:z.literal("en"),supported_locales:z.tuple([z.literal("en"),z.literal("ar"),z.literal("id"),z.literal("hi"),z.literal("fil")]),course_title_i18n:i18n,course_description_i18n:i18n,
  module_id:uuid,module_key:z.string().min(1),module_position:z.number().int().min(1).max(10),module_title_i18n:i18n,module_description_i18n:i18n,
  lesson_id:uuid,lesson_key:z.string().min(1),lesson_position:z.number().int().positive(),lesson_type:z.enum(["reading","key_points","quiz"]),required:z.literal(true),lesson_title_i18n:i18n,lesson_objective_i18n:i18n,lesson_content_i18n:contentI18n.nullable(),question_count:z.number().int().nullable(),pass_threshold_bps:z.number().int().nullable(),image_slots:z.array(image),
}).strict();
const storage=z.object({storage_bucket:z.literal("training-media"),storage_object_path:z.string().min(1),mime_type:z.literal("image/webp")}).strict();

export type TrainingEmployeePreviewService={
  getPreview(identity:LegacyTrainingIdentity):Promise<unknown>;
  authorizeMedia(identity:LegacyTrainingIdentity,mediaId:string):Promise<{signed_url:string}|null>;
};
export class TrainingEmployeePreviewAccessError extends Error{}
export class TrainingEmployeePreviewNotFoundError extends Error{}
export class TrainingEmployeePreviewConflictError extends Error{}
export class TrainingEmployeePreviewUnavailableError extends Error{}

export function createTrainingEmployeePreviewService(url:string,secretKey:string):TrainingEmployeePreviewService{
  const client=createClient(url,secretKey,{auth});
  async function rpc(name:string,input:Record<string,unknown>){const result=await client.rpc(name,input);if(result.error){if(result.error.code==="42501")throw new TrainingEmployeePreviewAccessError();if(result.error.code==="P0002")throw new TrainingEmployeePreviewNotFoundError();if(result.error.code==="55000")throw new TrainingEmployeePreviewConflictError();throw new TrainingEmployeePreviewUnavailableError();}if(!Array.isArray(result.data))throw new TrainingEmployeePreviewUnavailableError();return result.data;}
  const args=(identity:LegacyTrainingIdentity)=>({target_organization_id:identity.organizationId,target_branch_id:identity.branchId,target_employee_id:identity.employeeId});
  return{
    async getPreview(identity){
      const rows=z.array(row).length(19).parse(await rpc("get_training_employee_baladiyah_draft_preview",args(identity)));
      const first=rows[0];if(!first)throw new TrainingEmployeePreviewConflictError();
      const instructional=rows.filter(value=>value.module_position<=9),assessmentRows=rows.filter(value=>value.module_position===10);
      if(instructional.length!==18||assessmentRows.length!==1)throw new TrainingEmployeePreviewConflictError();
      const modules=Array.from(new Map(instructional.map(value=>[value.module_id,value])).values()).map(module=>{
        const lessons=instructional.filter(value=>value.module_id===module.module_id);
        if(lessons.length!==2||lessons[0]?.lesson_key!=="overview"||lessons[1]?.lesson_key!=="practical-photo-guide")throw new TrainingEmployeePreviewConflictError();
        return{id:module.module_id,stable_key:module.module_key,position:module.module_position,title_i18n:module.module_title_i18n,description_i18n:module.module_description_i18n,lessons:lessons.map(lesson=>{
          if(!lesson.lesson_content_i18n)throw new TrainingEmployeePreviewConflictError();
          const expected=lesson.lesson_content_i18n.en.image_slots.map(slot=>slot.asset_key);
          if(expected.length!==lesson.image_slots.length||expected.some(key=>!lesson.image_slots.some(slot=>slot.asset_key===key)))throw new TrainingEmployeePreviewConflictError();
          return{id:lesson.lesson_id,stable_key:lesson.lesson_key,position:lesson.lesson_position,lesson_type:lesson.lesson_type,title_i18n:lesson.lesson_title_i18n,objective_i18n:lesson.lesson_objective_i18n,content_i18n:lesson.lesson_content_i18n,images:lesson.image_slots.map(slot=>({...slot,src:slot.media_id?`/api/training/preview/media/${slot.media_id}`:null}))};
        })};
      });
      const images=modules.flatMap(module=>module.lessons.flatMap(lesson=>lesson.images));
      if(modules.length!==9||images.length!==40||new Set(images.map(value=>value.asset_key)).size!==40)throw new TrainingEmployeePreviewConflictError();
      const assessment=assessmentRows[0];
      if(!assessment||assessment.lesson_key!=="final-quiz"||assessment.lesson_content_i18n!==null||assessment.question_count!==27||assessment.pass_threshold_bps!==8000||assessment.image_slots.length!==0)throw new TrainingEmployeePreviewConflictError();
      return{preview_only:true,progress_saved:false,course:{course_id:first.course_id,course_version_id:first.course_version_id,version_number:1,status:"draft",revision:first.revision,default_locale:"en",supported_locales:first.supported_locales,title_i18n:first.course_title_i18n,description_i18n:first.course_description_i18n},instructional_modules:modules,final_assessment:{module_id:assessment.module_id,module_key:"final-assessment",module_position:10,module_title_i18n:assessment.module_title_i18n,lesson_id:assessment.lesson_id,lesson_key:"final-quiz",lesson_title_i18n:assessment.lesson_title_i18n,question_count:27,pass_threshold_bps:8000,minimum_correct_count:22,locked:true,submission_available:false}};
    },
    async authorizeMedia(identity,mediaId){
      uuid.parse(mediaId);const rows=z.array(storage).max(1).parse(await rpc("authorize_training_employee_baladiyah_draft_preview_media",{...args(identity),target_media_id:mediaId}));
      const authorized=rows[0];if(!authorized)return null;
      const signed=await client.storage.from(authorized.storage_bucket).createSignedUrl(authorized.storage_object_path,300,{download:false});
      if(signed.error||!signed.data?.signedUrl)throw new TrainingEmployeePreviewUnavailableError();
      return{signed_url:signed.data.signedUrl};
    },
  };
}
