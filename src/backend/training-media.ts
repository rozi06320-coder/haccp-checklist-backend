import { createHash, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import sharp from "sharp";
import { z } from "zod";

export const TRAINING_MEDIA_BUCKET = "training-media";
export const MAX_TRAINING_MEDIA_SOURCE_BYTES = 5 * 1024 * 1024;
export const MAX_TRAINING_MEDIA_PIXELS = 40_000_000;
export const TRAINING_MEDIA_SIGNED_URL_SECONDS = 5 * 60;
export const TRAINING_MEDIA_MIN_LONG_EDGE = 1280;
export const TRAINING_MEDIA_MIN_SHORT_EDGE = 720;
const MAX_STORED_LONG_EDGE = 2560;
const locales = ["en", "ar", "id", "hi", "fil"] as const;

const uuid = z.uuid();
const i18n = z.object({ en:z.string().trim().min(1).max(500), ar:z.string().trim().min(1).max(500), id:z.string().trim().min(1).max(500), hi:z.string().trim().min(1).max(500), fil:z.string().trim().min(1).max(500) }).strict();
const trainingContentItemSchema=z.object({
  fact_key:z.string().min(1),presentation:z.enum(["overview","key_point","step","warning","scenario","corrective_action"]),
  position:z.number().int().positive(),text:z.string().trim().min(1),
  provenance_classification:z.enum(["baladiyah_explicit","existing_training_supporting","internal_operational"]),
}).strict();
const trainingContentImageSlotSchema=z.object({asset_key:z.string().min(1),placement:z.string().min(1),slot_position:z.number().int().positive(),label:z.string().trim().min(1)}).strict();
const localizedLessonContentSchema=z.object({
  content_schema_version:z.literal(1),layout:z.literal("photo_first"),mode:z.enum(["reference","procedure"]),
  items:z.array(trainingContentItemSchema),image_slots:z.array(trainingContentImageSlotSchema),
}).strict();
const lessonContentI18nSchema=z.object({en:localizedLessonContentSchema,ar:localizedLessonContentSchema,id:localizedLessonContentSchema,hi:localizedLessonContentSchema,fil:localizedLessonContentSchema}).strict();
export const trainingMediaMetadataSchema = z.object({
  asset_key:z.string().trim().min(1).max(160).regex(/^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$/),
  title_i18n:i18n,
  alt_i18n:i18n,
}).strict();

const mediaRow = z.object({
  id:uuid, asset_key:z.string(), media_type:z.literal("image"), title_i18n:i18n, alt_i18n:i18n,
  mime_type:z.literal("image/webp"), byte_size:z.number().int().positive(), width:z.number().int().positive(),
  height:z.number().int().positive(), approval_status:z.enum(["submitted","approved","rejected"]),
  status:z.enum(["ready","retired"]), created_at:z.string(), updated_at:z.string(),revision:z.number().int().positive(),
  reviewed_at:z.string().nullable(),rejection_reason:z.string().max(500).nullable(),
}).passthrough();
export const trainingImageSlotRowSchema = z.object({
  module_id:uuid,module_key:z.string(),module_position:z.number().int().nonnegative(),module_title_i18n:i18n,
  lesson_id:uuid,lesson_key:z.string(),lesson_position:z.number().int().nonnegative(),lesson_title_i18n:i18n,
  asset_key:z.string(),placement:z.string(),purpose_i18n:i18n,expected_alt_i18n:i18n,media_alt_i18n:i18n.nullable(),
  media_id:uuid.nullable(),media_status:z.enum(["ready","retired"]).nullable(),approval_status:z.enum(["submitted","approved","rejected"]).nullable(),
  width:z.number().int().positive().nullable(),height:z.number().int().positive().nullable(),preview_available:z.boolean(),
  revision:z.number().int().positive().nullable(),reviewed_at:z.string().nullable(),rejection_reason:z.string().max(500).nullable(),
}).strict();
const draftPreviewRowSchema=z.object({
  organization_id:uuid,course_id:uuid,course_key:z.literal("baladiyah-food-safety-hygiene"),course_version_id:uuid,
  version_number:z.literal(1),version_status:z.literal("draft"),revision:z.literal(2),content_hash:z.literal("9bfb8467b8a43dc61db87833d0532403d14ecc6d3f63cb57e37582ea32d634d3"),
  default_locale:z.literal("en"),supported_locales:z.tuple([z.literal("en"),z.literal("ar"),z.literal("id"),z.literal("hi"),z.literal("fil")]),
  course_title_i18n:i18n,course_description_i18n:i18n,module_id:uuid,module_key:z.string().min(1),module_position:z.number().int().positive(),
  module_title_i18n:i18n,module_description_i18n:i18n,lesson_id:uuid,lesson_key:z.string().min(1),lesson_position:z.number().int().positive(),
  lesson_type:z.enum(["reading","key_points","quiz"]),required:z.literal(true),lesson_title_i18n:i18n,lesson_objective_i18n:i18n,
  lesson_content_i18n:lessonContentI18nSchema.nullable(),question_count:z.number().int().positive().nullable(),pass_threshold_bps:z.number().int().nullable(),
}).strict();
const draftVersionRow = z.object({ course_id:uuid,course_key:z.string(),course_version_id:uuid,version_number:z.number().int().positive(),title_i18n:z.record(z.string(),z.unknown()),supported_locales:z.array(z.string()),status:z.literal("draft") }).strict();
const storageRow = z.object({storage_bucket:z.literal(TRAINING_MEDIA_BUCKET),storage_object_path:z.string(),mime_type:z.literal("image/webp")}).strict();
const reviewCandidateRow=z.object({
  storage_bucket:z.literal(TRAINING_MEDIA_BUCKET),storage_object_path:z.string().min(1),mime_type:z.literal("image/webp"),
  byte_size:z.number().int().positive(),width:z.number().int().positive(),height:z.number().int().positive(),sha256:z.string().regex(/^[0-9a-f]{64}$/),
  revision:z.number().int().positive(),approval_status:z.enum(["submitted","approved","rejected"]),status:z.literal("ready"),
}).strict();
const reviewResultRow=z.object({
  id:uuid,approval_status:z.enum(["approved","rejected"]),reviewed_at:z.string(),rejection_reason:z.string().max(500).nullable(),
  revision:z.number().int().positive(),updated_at:z.string(),
}).strict();
const publicationReadinessRow=z.object({
  course_key:z.literal("baladiyah-food-safety-hygiene"),course_title_i18n:i18n,version_number:z.literal(1),version_status:z.literal("draft"),revision:z.literal(2),
  curriculum_valid:z.literal(true),instructional_module_count:z.literal(9),instructional_lesson_count:z.literal(18),final_assessment_count:z.literal(1),final_quiz_count:z.literal(1),quiz_question_count:z.literal(27),pass_threshold_bps:z.literal(8000),
  required_image_count:z.literal(40),uploaded_image_count:z.number().int().min(0).max(40),submitted_image_count:z.number().int().min(0).max(40),approved_image_count:z.number().int().min(0).max(40),rejected_image_count:z.number().int().min(0).max(40),missing_image_count:z.number().int().min(0).max(40),
  image_metadata_valid:z.boolean(),image_database_ready:z.boolean(),locale_structure_complete:z.boolean(),conflicting_published_version:z.boolean(),
  translation_review_status:z.object({en:z.literal("pending"),ar:z.literal("pending"),id:z.literal("pending"),hi:z.literal("pending"),fil:z.literal("pending")}).strict(),
  content_review_status:z.literal("pending"),regulatory_review_status:z.literal("pending"),review_workflow_available:z.literal(false),
}).strict();

export class TrainingMediaAccessError extends Error {}
export class TrainingMediaInputError extends Error {}
export class TrainingMediaConflictError extends Error {}
export class TrainingMediaNotFoundError extends Error {}
export class TrainingMediaUnavailableError extends Error {}

export type TrainingMediaDto = z.infer<typeof mediaRow> & { preview_url:string };
export type TrainingImageSlotDto = z.infer<typeof trainingImageSlotRowSchema> & { preview_url:string|null };
export type TrainingDraftPreviewDto={
  course:{organization_id:string;course_id:string;course_key:"baladiyah-food-safety-hygiene";course_version_id:string;version_number:1;status:"draft";revision:2;content_hash:string;default_locale:"en";supported_locales:["en","ar","id","hi","fil"];title_i18n:z.infer<typeof i18n>;description_i18n:z.infer<typeof i18n>};
  instructional_modules:Array<{id:string;stable_key:string;position:number;title_i18n:z.infer<typeof i18n>;description_i18n:z.infer<typeof i18n>;lessons:Array<{id:string;stable_key:"overview"|"practical-photo-guide";position:1|2;lesson_type:"reading"|"key_points";required:true;title_i18n:z.infer<typeof i18n>;objective_i18n:z.infer<typeof i18n>;content_i18n:z.infer<typeof lessonContentI18nSchema>;images:TrainingImageSlotDto[]}>}>;
  final_assessment:{module_id:string;module_key:"final-assessment";module_position:10;module_title_i18n:z.infer<typeof i18n>;lesson_id:string;lesson_key:"final-quiz";lesson_title_i18n:z.infer<typeof i18n>;question_count:27;pass_threshold_bps:8000;minimum_correct_count:22;locked:true;submission_available:false};
};
export type TrainingPublicationReadinessDto={
  course:{course_key:"baladiyah-food-safety-hygiene";title_i18n:z.infer<typeof i18n>;version_number:1;status:"draft";revision:2};
  curriculum:{valid:true;instructional_modules:9;instructional_lessons:18;final_assessments:1;final_quizzes:1;quiz_questions:27;pass_threshold_bps:8000;locale_structure_complete:boolean;conflicting_published_version:boolean};
  images:{required:40;uploaded:number;submitted:number;approved:number;rejected:number;missing:number;metadata_valid:boolean;database_ready:boolean;storage_verified:number;storage_invalid:number;storage_ready:boolean};
  reviews:{workflow_available:false;translations:{en:"pending";ar:"pending";id:"pending";hi:"pending";fil:"pending"};content:"pending";regulatory:"pending"};
  overall_status:"not_ready"|"ready";
  blockers:Array<{code:string;category:"curriculum"|"images"|"translations"|"content";message:string;href:string}>;
};
type Scope={actorUserId:string;organizationId:string;courseId:string;courseVersionId:string;requestId:string};
export type TrainingMediaService = {
  listDraftVersions(actorUserId:string,organizationId:string):Promise<z.infer<typeof draftVersionRow>[]>;
  list(scope:Omit<Scope,"requestId">):Promise<TrainingMediaDto[]>;
  listSlots(scope:Omit<Scope,"requestId">):Promise<TrainingImageSlotDto[]>;
  getDraftPreview(scope:Omit<Scope,"requestId">):Promise<TrainingDraftPreviewDto>;
  getPublicationReadiness(scope:Omit<Scope,"requestId">):Promise<TrainingPublicationReadinessDto>;
  create(scope:Scope,input:z.infer<typeof trainingMediaMetadataSchema>&{bytes:Buffer;declaredMime:string}):Promise<TrainingMediaDto>;
  replace(scope:Scope,input:z.infer<typeof trainingMediaMetadataSchema>&{assetId:string;bytes:Buffer;declaredMime:string}):Promise<TrainingMediaDto>;
  updateMetadata(scope:Omit<Scope,"requestId">,input:z.infer<typeof trainingMediaMetadataSchema>&{assetId:string}):Promise<TrainingMediaDto>;
  review(scope:Omit<Scope,"requestId">,input:{assetId:string;revision:number;decision:"approved"|"rejected";rejectionReason?:string|null}):Promise<z.infer<typeof reviewResultRow>>;
  retire(scope:Scope,assetId:string):Promise<void>;
  authorizeAdminRead(scope:Omit<Scope,"requestId">,assetId:string):Promise<{signed_url:string;mime_type:"image/webp";expires_in:number}>;
};

type Client={rpc:(name:string,args?:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{code?:string}|null}>;storage:{from:(bucket:string)=>{
  upload:(path:string,bytes:Buffer,options:Record<string,unknown>)=>PromiseLike<{data:unknown;error:unknown}>;
  remove:(paths:string[])=>PromiseLike<{data:unknown;error:unknown}>;
  download:(path:string)=>PromiseLike<{data:Blob|null;error:unknown}>;
  createSignedUrl:(path:string,seconds:number)=>PromiseLike<{data:{signedUrl?:string}|null;error:unknown}>;
}}};
const clientOptions={auth:{autoRefreshToken:false,detectSessionInUrl:false,persistSession:false}} as const;
const hash=(bytes:Buffer)=>createHash("sha256").update(bytes).digest("hex");

async function normalize(bytes:Buffer,declaredMime:string){
  if(bytes.length===0||bytes.length>MAX_TRAINING_MEDIA_SOURCE_BYTES||!(["image/jpeg","image/png","image/webp"] as string[]).includes(declaredMime))throw new TrainingMediaInputError();
  try{
    const decoder=sharp(bytes,{failOn:"error",limitInputPixels:MAX_TRAINING_MEDIA_PIXELS,animated:true});
    const metadata=await decoder.metadata();
    const detected=metadata.format==="jpeg"?"image/jpeg":metadata.format==="png"?"image/png":metadata.format==="webp"?"image/webp":null;
    if(!detected||detected!==declaredMime||!metadata.width||!metadata.height||(metadata.pages??1)>1)throw new TrainingMediaInputError();
    const pixels=metadata.width*metadata.height;
    const long=Math.max(metadata.width,metadata.height),short=Math.min(metadata.width,metadata.height);
    if(pixels>MAX_TRAINING_MEDIA_PIXELS||long<TRAINING_MEDIA_MIN_LONG_EDGE||short<TRAINING_MEDIA_MIN_SHORT_EDGE)throw new TrainingMediaInputError();
    const output=await sharp(bytes,{failOn:"error",limitInputPixels:MAX_TRAINING_MEDIA_PIXELS})
      .rotate().resize({width:MAX_STORED_LONG_EDGE,height:MAX_STORED_LONG_EDGE,fit:"inside",withoutEnlargement:true})
      .webp({quality:83,alphaQuality:90,effort:5}).toBuffer({resolveWithObject:true});
    if(!output.info.width||!output.info.height||output.data.length===0||output.data.length>MAX_TRAINING_MEDIA_SOURCE_BYTES)throw new TrainingMediaInputError();
    return{bytes:output.data,width:output.info.width,height:output.info.height,sha256:hash(output.data),sourceMime:detected,sourceBytes:bytes.length,sourceSha256:hash(bytes)};
  }catch(error){if(error instanceof TrainingMediaInputError)throw error;throw new TrainingMediaInputError();}
}

export function createTrainingMediaService(url:string,secretKey:string){
  return createTrainingMediaServiceFromClient(createClient(url,secretKey,clientOptions) as unknown as Client);
}
export function createTrainingMediaServiceFromClient(client:Client):TrainingMediaService{
  const storage=client.storage.from(TRAINING_MEDIA_BUCKET);
  async function rpc(name:string,args:Record<string,unknown>){const result=await client.rpc(name,args);if(result.error){
    if(result.error.code==="42501")throw new TrainingMediaAccessError();
    if(result.error.code==="22023")throw new TrainingMediaInputError();
    if(result.error.code==="23505"||result.error.code==="40001"||result.error.code==="55000")throw new TrainingMediaConflictError();
    if(result.error.code==="P0002")throw new TrainingMediaNotFoundError();
    throw new TrainingMediaUnavailableError();}return result.data;}
  const args=(scope:Omit<Scope,"requestId">)=>({actor_user_id:scope.actorUserId,target_organization_id:scope.organizationId,target_course_id:scope.courseId,target_course_version_id:scope.courseVersionId});
  const preview=(scope:Omit<Scope,"requestId">,row:z.infer<typeof mediaRow>):TrainingMediaDto=>({...row,preview_url:`/api/internal-admin/training/media/${row.id}?organization=${scope.organizationId}&course=${scope.courseId}&version=${scope.courseVersionId}`});
  const slotPreview=(scope:Omit<Scope,"requestId">,row:z.infer<typeof trainingImageSlotRowSchema>):TrainingImageSlotDto=>({...row,preview_url:row.preview_available&&row.media_id?`/api/internal-admin/training/media/${row.media_id}?organization=${scope.organizationId}&course=${scope.courseId}&version=${scope.courseVersionId}`:null});
  const log=(stage:string,outcome:string,safeCategory:string,sourceMime?:string,sourceBytes?:number,storedBytes?:number)=>console.warn("TRAINING_MEDIA_UPLOAD",{stage,outcome,safeCategory,sourceMime,sourceBytes,storedBytes});
  async function remove(path:string,stage:string){const result=await storage.remove([path]);if(result.error){log("cleanup","failed",stage);return false;}return true;}
  async function upload(scope:Scope,mediaId:string,source:Buffer,declaredMime:string){
    let normalized;try{normalized=await normalize(source,declaredMime);}catch(error){log("decode","rejected","invalid_image",declaredMime,source.length);throw error;}
    const path=`organizations/${scope.organizationId}/courses/${scope.courseId}/versions/${scope.courseVersionId}/assets/${mediaId}/${randomUUID()}.webp`;
    const result=await storage.upload(path,normalized.bytes,{contentType:"image/webp",cacheControl:"300",upsert:false});
    if(result.error){log("storage_upload","failed","storage_unavailable",declaredMime,source.length,normalized.bytes.length);throw new TrainingMediaUnavailableError();}
    return{...normalized,path};
  }
  async function verifyReviewCandidate(candidate:z.infer<typeof reviewCandidateRow>){
    const result=await storage.download(candidate.storage_object_path);
    if(result.error||!result.data)throw new TrainingMediaUnavailableError();
    const bytes=Buffer.from(await result.data.arrayBuffer());
    if(bytes.length!==candidate.byte_size||hash(bytes)!==candidate.sha256)throw new TrainingMediaConflictError();
    try{
      const metadata=await sharp(bytes,{failOn:"error",limitInputPixels:MAX_TRAINING_MEDIA_PIXELS,animated:true}).metadata();
      if(metadata.format!=="webp"||metadata.width!==candidate.width||metadata.height!==candidate.height||(metadata.pages??1)!==1||metadata.exif||metadata.xmp||metadata.icc)throw new TrainingMediaConflictError();
    }catch(error){if(error instanceof TrainingMediaConflictError)throw error;throw new TrainingMediaConflictError();}
  }
  async function withTimeout<T>(work:Promise<T>,milliseconds=5_000):Promise<T>{
    let timer:NodeJS.Timeout|undefined;
    try{return await Promise.race([work,new Promise<T>((_resolve,reject)=>{timer=setTimeout(()=>reject(new TrainingMediaUnavailableError()),milliseconds);})]);}
    finally{if(timer)clearTimeout(timer);}
  }
  return{
    async listDraftVersions(actorUserId,organizationId){return z.array(draftVersionRow).parse(await rpc("list_internal_admin_training_draft_versions",{actor_user_id:actorUserId,target_organization_id:organizationId}));},
    async list(scope){return z.array(mediaRow).parse(await rpc("list_internal_admin_training_media",args(scope))).map(row=>preview(scope,row));},
    async listSlots(scope){return z.array(trainingImageSlotRowSchema).parse(await rpc("list_internal_admin_training_image_slots",args(scope))).map(row=>slotPreview(scope,row));},
    async getDraftPreview(scope){
      const [rawRows,slots]=await Promise.all([
        rpc("get_internal_admin_training_draft_preview",args(scope)),
        this.listSlots(scope),
      ]);
      const rows=z.array(draftPreviewRowSchema).length(19).parse(rawRows);
      if(slots.length!==40||new Set(slots.map(slot=>slot.asset_key)).size!==40)throw new TrainingMediaConflictError();
      const first=rows[0];
      if(!first)throw new TrainingMediaConflictError();
      const instructionalRows=rows.filter(row=>row.module_position<=9);
      const assessmentRows=rows.filter(row=>row.module_position===10);
      if(instructionalRows.length!==18||assessmentRows.length!==1)throw new TrainingMediaConflictError();
      const modules=Array.from(new Map(instructionalRows.map(row=>[row.module_id,row])).values()).map(moduleRow=>{
        const lessons=instructionalRows.filter(row=>row.module_id===moduleRow.module_id);
        if(lessons.length!==2||lessons[0]?.lesson_key!=="overview"||lessons[0]?.lesson_position!==1||lessons[0]?.lesson_type!=="reading"||lessons[1]?.lesson_key!=="practical-photo-guide"||lessons[1]?.lesson_position!==2||lessons[1]?.lesson_type!=="key_points")throw new TrainingMediaConflictError();
        return{id:moduleRow.module_id,stable_key:moduleRow.module_key,position:moduleRow.module_position,title_i18n:moduleRow.module_title_i18n,description_i18n:moduleRow.module_description_i18n,lessons:lessons.map(row=>{
          if(!row.lesson_content_i18n||row.question_count!==null||row.pass_threshold_bps!==null)throw new TrainingMediaConflictError();
          const images=slots.filter(slot=>slot.lesson_id===row.lesson_id);
          const declared=new Set(row.lesson_content_i18n.en.image_slots.map(slot=>slot.asset_key));
          if(images.length!==declared.size||images.some(image=>!declared.has(image.asset_key)))throw new TrainingMediaConflictError();
          return{id:row.lesson_id,stable_key:row.lesson_key as "overview"|"practical-photo-guide",position:row.lesson_position as 1|2,lesson_type:row.lesson_type as "reading"|"key_points",required:true as const,title_i18n:row.lesson_title_i18n,objective_i18n:row.lesson_objective_i18n,content_i18n:row.lesson_content_i18n,images};
        })};
      });
      if(modules.length!==9||modules.some((module,index)=>module.position!==index+1))throw new TrainingMediaConflictError();
      const assessment=assessmentRows[0];
      if(!assessment||assessment.module_key!=="final-assessment"||assessment.lesson_key!=="final-quiz"||assessment.lesson_type!=="quiz"||assessment.lesson_content_i18n!==null||assessment.question_count!==27||assessment.pass_threshold_bps!==8000)throw new TrainingMediaConflictError();
      return{
        course:{organization_id:first.organization_id,course_id:first.course_id,course_key:first.course_key,course_version_id:first.course_version_id,version_number:1,status:"draft",revision:2,content_hash:first.content_hash,default_locale:"en",supported_locales:first.supported_locales,title_i18n:first.course_title_i18n,description_i18n:first.course_description_i18n},
        instructional_modules:modules,
        final_assessment:{module_id:assessment.module_id,module_key:"final-assessment",module_position:10,module_title_i18n:assessment.module_title_i18n,lesson_id:assessment.lesson_id,lesson_key:"final-quiz",lesson_title_i18n:assessment.lesson_title_i18n,question_count:27,pass_threshold_bps:8000,minimum_correct_count:22,locked:true,submission_available:false},
      };
    },
    async getPublicationReadiness(scope){
      const [rawReadiness,slots]=await Promise.all([
        rpc("get_internal_admin_training_publication_readiness",args(scope)),
        this.listSlots(scope),
      ]);
      const rows=z.array(publicationReadinessRow).length(1).parse(rawReadiness),row=rows[0];
      if(!row||slots.length!==40||new Set(slots.map(slot=>slot.asset_key)).size!==40)throw new TrainingMediaConflictError();
      const approvedSlots=slots.filter(slot=>slot.media_status==="ready"&&slot.approval_status==="approved"&&slot.media_id);
      let cursor=0,storageVerified=0,storageInvalid=0;
      const workers=Array.from({length:Math.min(4,approvedSlots.length)},async()=>{
        while(cursor<approvedSlots.length){
          const slot=approvedSlots[cursor++];
          if(!slot?.media_id){storageInvalid+=1;continue;}
          try{
            const candidates=z.array(reviewCandidateRow).length(1).parse(await rpc("get_internal_admin_training_media_review_candidate",{...args(scope),target_media_id:slot.media_id}));
            await withTimeout(verifyReviewCandidate(candidates[0]));storageVerified+=1;
          }catch{storageInvalid+=1;}
        }
      });
      let verificationTimer:NodeJS.Timeout|undefined;
      const verificationCompleted=await Promise.race([
        Promise.all(workers).then(()=>true),
        new Promise<false>(resolve=>{verificationTimer=setTimeout(()=>resolve(false),12_000);}),
      ]);
      if(verificationTimer)clearTimeout(verificationTimer);
      if(!verificationCompleted)storageInvalid=Math.max(storageInvalid,approvedSlots.length-storageVerified);
      const blockers:TrainingPublicationReadinessDto["blockers"]=[];
      if(row.conflicting_published_version)blockers.push({code:"published_version_conflict",category:"curriculum",message:"Another version of this course is already published.",href:"/internal-admin/training"});
      if(row.missing_image_count>0)blockers.push({code:"images_missing",category:"images",message:`${row.missing_image_count} required Training image${row.missing_image_count===1?" is":"s are"} missing.`,href:"/internal-admin/training?tab=library"});
      if(row.submitted_image_count>0)blockers.push({code:"images_awaiting_review",category:"images",message:`${row.submitted_image_count} Training image${row.submitted_image_count===1?" is":"s are"} awaiting review.`,href:"/internal-admin/training?tab=library"});
      if(row.rejected_image_count>0)blockers.push({code:"images_rejected",category:"images",message:`${row.rejected_image_count} Training image${row.rejected_image_count===1?" was":"s were"} rejected.`,href:"/internal-admin/training?tab=library"});
      if(!row.image_metadata_valid)blockers.push({code:"image_metadata_invalid",category:"images",message:"One or more Training image records have invalid publication metadata.",href:"/internal-admin/training?tab=library"});
      if(storageInvalid>0)blockers.push({code:"image_storage_invalid",category:"images",message:`${storageInvalid} approved Training image object${storageInvalid===1?" could":"s could"} not be verified.`,href:"/internal-admin/training?tab=library"});
      for(const locale of ["en","ar","id","hi","fil"] as const)blockers.push({code:`translation_review_${locale}`,category:"translations",message:`${({en:"English",ar:"Arabic",id:"Indonesian",hi:"Hindi",fil:"Filipino"} as const)[locale]} translation review is pending.`,href:"/internal-admin/training/preview"});
      blockers.push({code:"content_review_pending",category:"content",message:"Curriculum content approval is pending; no authoritative review workflow exists yet.",href:"/internal-admin/training/preview"});
      blockers.push({code:"regulatory_review_pending",category:"content",message:"Supporting regulatory content verification is pending.",href:"/internal-admin/training/preview"});
      const storageReady=approvedSlots.length===40&&storageVerified===40&&storageInvalid===0;
      const overallReady=blockers.length===0&&row.image_database_ready&&storageReady;
      return{
        course:{course_key:row.course_key,title_i18n:row.course_title_i18n,version_number:1,status:"draft",revision:2},
        curriculum:{valid:true,instructional_modules:9,instructional_lessons:18,final_assessments:1,final_quizzes:1,quiz_questions:27,pass_threshold_bps:8000,locale_structure_complete:row.locale_structure_complete,conflicting_published_version:row.conflicting_published_version},
        images:{required:40,uploaded:row.uploaded_image_count,submitted:row.submitted_image_count,approved:row.approved_image_count,rejected:row.rejected_image_count,missing:row.missing_image_count,metadata_valid:row.image_metadata_valid,database_ready:row.image_database_ready,storage_verified:storageVerified,storage_invalid:storageInvalid,storage_ready:storageReady},
        reviews:{workflow_available:false,translations:row.translation_review_status,content:row.content_review_status,regulatory:row.regulatory_review_status},
        overall_status:overallReady?"ready":"not_ready",blockers,
      };
    },
    async create(scope,input){
      const metadata=trainingMediaMetadataSchema.parse({asset_key:input.asset_key,title_i18n:input.title_i18n,alt_i18n:input.alt_i18n}),mediaId=randomUUID();const saved=await upload(scope,mediaId,input.bytes,input.declaredMime);
      try{const rows=z.array(mediaRow).max(1).parse(await rpc("register_internal_admin_training_media",{...args(scope),target_media_id:mediaId,target_asset_key:metadata.asset_key,new_title_i18n:metadata.title_i18n,new_alt_i18n:metadata.alt_i18n,new_storage_object_path:saved.path,new_byte_size:saved.bytes.length,new_width:saved.width,new_height:saved.height,new_sha256:saved.sha256,new_source_mime_type:saved.sourceMime,new_source_byte_size:saved.sourceBytes,new_source_sha256:saved.sourceSha256}));if(!rows[0])throw new TrainingMediaUnavailableError();return preview(scope,rows[0]);}
      catch(error){await remove(saved.path,"db_register_compensation");throw error;}
    },
    async replace(scope,input){
      uuid.parse(input.assetId);const metadata=trainingMediaMetadataSchema.parse({asset_key:input.asset_key,title_i18n:input.title_i18n,alt_i18n:input.alt_i18n}),saved=await upload(scope,input.assetId,input.bytes,input.declaredMime);
      try{const rows=z.array(z.object({id:uuid,old_storage_object_path:z.string(),storage_object_path:z.string()}).strict()).max(1).parse(await rpc("replace_internal_admin_training_media",{...args(scope),target_media_id:input.assetId,new_storage_object_path:saved.path,new_title_i18n:metadata.title_i18n,new_alt_i18n:metadata.alt_i18n,new_byte_size:saved.bytes.length,new_width:saved.width,new_height:saved.height,new_sha256:saved.sha256,new_source_mime_type:saved.sourceMime,new_source_byte_size:saved.sourceBytes,new_source_sha256:saved.sourceSha256}));if(!rows[0])throw new TrainingMediaUnavailableError();await remove(rows[0].old_storage_object_path,"replace_old_object");const current=(await this.list(scope)).find(item=>item.id===input.assetId);if(!current)throw new TrainingMediaUnavailableError();return current;}
      catch(error){await remove(saved.path,"replace_compensation");throw error;}
    },
    async updateMetadata(scope,input){uuid.parse(input.assetId);const metadata=trainingMediaMetadataSchema.parse({asset_key:input.asset_key,title_i18n:input.title_i18n,alt_i18n:input.alt_i18n});const rows=z.array(mediaRow).max(1).parse(await rpc("update_internal_admin_training_media_metadata",{...args(scope),target_media_id:input.assetId,new_title_i18n:metadata.title_i18n,new_alt_i18n:metadata.alt_i18n}));if(!rows[0])throw new TrainingMediaNotFoundError();return preview(scope,rows[0]);},
    async review(scope,input){
      uuid.parse(input.assetId);const revision=z.number().int().positive().parse(input.revision);
      const decision=z.enum(["approved","rejected"]).parse(input.decision);
      const rejectionReason=decision==="rejected"?z.string().trim().min(1).max(500).parse(input.rejectionReason):null;
      const candidates=z.array(reviewCandidateRow).max(1).parse(await rpc("get_internal_admin_training_media_review_candidate",{...args(scope),target_media_id:input.assetId}));
      const candidate=candidates[0];if(!candidate)throw new TrainingMediaNotFoundError();
      if(candidate.revision!==revision||candidate.approval_status!=="submitted")throw new TrainingMediaConflictError();
      if(decision==="approved")await verifyReviewCandidate(candidate);
      const reviewed=z.array(reviewResultRow).max(1).parse(await rpc("review_internal_admin_training_media",{...args(scope),target_media_id:input.assetId,expected_revision:revision,review_decision:decision,new_rejection_reason:rejectionReason}));
      if(!reviewed[0])throw new TrainingMediaNotFoundError();return reviewed[0];
    },
    async retire(scope,assetId){uuid.parse(assetId);const rows=z.array(z.object({id:uuid,retired_storage_object_path:z.string()}).strict()).max(1).parse(await rpc("retire_internal_admin_training_media",{...args(scope),target_media_id:assetId}));if(!rows[0])throw new TrainingMediaNotFoundError();await remove(rows[0].retired_storage_object_path,"retire_object");},
    async authorizeAdminRead(scope,assetId){uuid.parse(assetId);const rows=z.array(storageRow).max(1).parse(await rpc("authorize_internal_admin_training_media_read",{...args(scope),target_media_id:assetId}));if(!rows[0])throw new TrainingMediaNotFoundError();const signed=await storage.createSignedUrl(rows[0].storage_object_path,TRAINING_MEDIA_SIGNED_URL_SECONDS);if(signed.error||!signed.data?.signedUrl)throw new TrainingMediaUnavailableError();return{signed_url:signed.data.signedUrl,mime_type:"image/webp",expires_in:TRAINING_MEDIA_SIGNED_URL_SECONDS};},
  };
}

export const TRAINING_MEDIA_LOCALES=locales;
